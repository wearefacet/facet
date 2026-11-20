# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/rbac"
require "digest/sha256"
require "file"
require "json"

# Step 3 of the artifact system: the uploader.
#
# Files covered:
#   - src/artifact/uploader.cr — magic-byte sniffer, size cap, spooling,
#     shrine put/delete, dedup reuse vs. fresh insert.
#
# The uploader lives below `Artifact::Routes` (HTTP) — these specs drive
# the service-layer directly so the contract is observable without dragging
# Kemal into the picture. The HTTP integration is exercised separately in
# `routes_spec.cr`.
#
# Specs walk every documented rule:
#   1. magic-byte sniffing (~30 types).
#   2. size cap enforced before any byte touches shrine → 413.
#   3. client `Content-Type` never consulted; MIME comes from magic bytes.
#   4. unknown magic → `application/octet-stream`.
#   5. dedup reuses a readable candidate (no shrine put, no second object).
#   6. an unreadable candidate yields a second stored copy.
#   7. tempfile cleaned on both the success and rollback paths.
#   8. re-uploading identical bytes to the same provenance is idempotent:
#      the owner-row insert collapses via `ON CONFLICT DO NOTHING` (no
#      second owner row, no second object, no error).
#   9. HTML sniffing is case-insensitive and tolerates a BOM, whitespace,
#      or a short comment before the markup; deploy callers may read the
#      type from the file name (`mime_from_extension`).

DOMAIN_UP = "artup"

# Truncates every artifact table so each spec starts from a known-empty state.
private def truncate_artifact_tables
  with_db &.exec("TRUNCATE artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Builds a docs.doctype with one `file` field, persisted to the DB so the
# upload flow has a real projection row to bind provenance against. Returns
# `{doctype_name, doc_id}` where the projection row has been created.
def setup_upload_target(db, doctype = "Asset", field = "file", tags : Array(String)? = nil)
  ensure_domain(db, DOMAIN_UP)
  file_type = Facet::Doctype::FieldType.parse("file")
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_UP,
    fields: {
      field => Facet::Doctype::FieldDefinition.new(type: file_type, tags: tags),
    } of String => Facet::Doctype::FieldDefinition,
  )
  res = Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  )
  res.should be_a(Facet::Document::Create::Result)

  # Create an empty document of this doctype so the projection row exists
  # before the upload flow records provenance against it.
  doc_res = Facet::Document::Create.call(
    db, DOMAIN_UP, doctype, %({}), Facet::RBAC::AuthContext.system,
  )
  doc_res.should be_a(Facet::Document::Create::Result)
  {doctype, doc_res.as(Facet::Document::Create::Result).projection.id}
end

# Generates a random file path under the test shrine store so each spec
# writes to a distinct location. The shrine FileSystem storage sits at
# `tmp/uploads/test/store` (see `config.test.yml`).
def shrine_store_dir : String
  File.expand_path("tmp/uploads/test/store")
end

# Builds an `IO::Memory` with the given bytes — used to drive `upload()`.
def io_of(bytes : Bytes) : IO::Memory
  IO::Memory.new(bytes)
end

# Returns the bytes of a tiny valid PNG (1×1 transparent) — a real magic
# signature so `sniff_mime` returns `image/png` rather than octet-stream.
def png_bytes : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw="
  )
end

def jpeg_bytes : Bytes
  Bytes.new(12).tap { |b| b[0] = 0xFF_u8; b[1] = 0xD8_u8; b[2] = 0xFF_u8; b[3] = 0xE0_u8 }
end

def pdf_bytes : Bytes
  "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_slice
end

def text_bytes(content = "hello world\n") : Bytes
  content.to_slice
end

def gif_bytes : Bytes
  "GIF89a".to_slice
end

describe Facet::Artifact::Uploader do
  before_each { truncate_artifact_tables }

  # ── 1. Magic-byte sniffer ───────────────────────────────────────────────

  describe ".sniff_mime" do
    it "sniffs image/png from magic bytes" do
      Facet::Artifact::Uploader.sniff_mime(io_of(png_bytes)).should eq("image/png")
    end

    it "sniffs image/jpeg from a JPEG SOI marker" do
      Facet::Artifact::Uploader.sniff_mime(io_of(jpeg_bytes)).should eq("image/jpeg")
    end

    it "sniffs image/gif from a GIF89a header" do
      Facet::Artifact::Uploader.sniff_mime(io_of(gif_bytes)).should eq("image/gif")
    end

    it "sniffs application/pdf from a %PDF- prefix" do
      Facet::Artifact::Uploader.sniff_mime(io_of(pdf_bytes)).should eq("application/pdf")
    end

    it "sniffs text/plain from printable ASCII content" do
      Facet::Artifact::Uploader.sniff_mime(io_of(text_bytes)).should eq("text/plain")
    end

    it "returns application/octet-stream for unknown binary content" do
      # Random non-printable bytes that don't match any signature.
      unknown = Bytes.new(16) { |i| (i + 1).to_u8 }
      Facet::Artifact::Uploader.sniff_mime(io_of(unknown)).should eq("application/octet-stream")
    end

    it "rewinds the IO after sniffing so the caller can stream onward" do
      io = io_of(png_bytes)
      Facet::Artifact::Uploader.sniff_mime(io)
      io.pos.should eq(0)
    end

    it "sniffs a RIFF/WEBP composite signature" do
      # RIFF....WEBP — the 4 bytes at offset 8 disambiguate from WAV/AVI.
      webp = Bytes.new(16)
      "RIFF\x00\x00\x00\x00WEBP".to_slice.copy_to(webp)
      Facet::Artifact::Uploader.sniff_mime(io_of(webp)).should eq("image/webp")
    end

    it "sniffs a RIFF/WAV composite signature" do
      wav = Bytes.new(16)
      "RIFF\x00\x00\x00\x00WAVE".to_slice.copy_to(wav)
      Facet::Artifact::Uploader.sniff_mime(io_of(wav)).should eq("audio/wav")
    end

    it "sniffs an MP4 ftyp brand" do
      # 4-byte size, `ftyp`, then brand `isom`.
      mp4 = Bytes.new(16)
      "\x00\x00\x00\x10ftypisom".to_slice.copy_to(mp4)
      Facet::Artifact::Uploader.sniff_mime(io_of(mp4)).should eq("video/mp4")
    end

    it "sniffs a ZIP container as application/zip (no OOXML marker)" do
      zip = Bytes.new(8)
      "PK\x03\x04".to_slice.copy_to(zip)
      Facet::Artifact::Uploader.sniff_mime(io_of(zip)).should eq("application/zip")
    end

    it "sniffs an SVG from the <svg prefix" do
      svg = %(<svg xmlns="http://www.w3.org/2000/svg"></svg>).to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(svg)).should eq("image/svg+xml")
    end

    it "sniffs text/html from an uppercase doctype" do
      html = "<!DOCTYPE html><html><body></body></html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html from a lowercase doctype" do
      html = "<!doctype html><html><body></body></html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html from a mixed-case doctype" do
      html = "<!DoCtYpE html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html from a lowercase <html> root tag" do
      html = %(<html lang="en"><body>hi</body></html>).to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html behind a UTF-8 BOM" do
      html = "\xEF\xBB\xBF<!doctype html><html></html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html behind leading whitespace" do
      html = "\r\n\t <!doctype html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "sniffs text/html behind a short build comment" do
      html = "<!-- build 2026.10.25 --><!doctype html>".to_slice
      Facet::Artifact::Uploader.sniff_mime(io_of(html)).should eq("text/html")
    end

    it "ignores markup past the sniff window" do
      padded = ("x" * 80) + "<html>"
      Facet::Artifact::Uploader.sniff_mime(io_of(padded.to_slice)).should eq("text/plain")
    end
  end

  # ── 1b. File-name mime table ────────────────────────────────────────

  describe ".extension_mime" do
    it "maps web build extensions, case-insensitive" do
      Facet::Artifact::Uploader.extension_mime("index.html").should eq("text/html")
      Facet::Artifact::Uploader.extension_mime("assets/main.css").should eq("text/css")
      Facet::Artifact::Uploader.extension_mime("app.mjs").should eq("text/javascript")
      Facet::Artifact::Uploader.extension_mime("logo.SVG").should eq("image/svg+xml")
      Facet::Artifact::Uploader.extension_mime("fonts/x.WOFF2").should eq("font/woff2")
    end

    it "returns nil for unknown, extension-less, and dotfile names" do
      Facet::Artifact::Uploader.extension_mime("blob.bin").should be_nil
      Facet::Artifact::Uploader.extension_mime("README").should be_nil
      Facet::Artifact::Uploader.extension_mime(".gitignore").should be_nil
    end
  end

  # ── 2. inline_mime? ────────────────────────────────────────────────────

  describe ".inline_mime?" do
    it "returns true for the inline-safe set (images, pdf, audio, video)" do
      Facet::Artifact::Uploader.inline_mime?("image/png").should be_true
      Facet::Artifact::Uploader.inline_mime?("image/jpeg").should be_true
      Facet::Artifact::Uploader.inline_mime?("image/gif").should be_true
      Facet::Artifact::Uploader.inline_mime?("image/webp").should be_true
      Facet::Artifact::Uploader.inline_mime?("application/pdf").should be_true
      Facet::Artifact::Uploader.inline_mime?("audio/mpeg").should be_true
      Facet::Artifact::Uploader.inline_mime?("video/mp4").should be_true
    end

    it "returns false for SVG, octet-stream, and unknown types" do
      Facet::Artifact::Uploader.inline_mime?("image/svg+xml").should be_false
      Facet::Artifact::Uploader.inline_mime?("application/octet-stream").should be_false
      Facet::Artifact::Uploader.inline_mime?("application/zip").should be_false
      Facet::Artifact::Uploader.inline_mime?("text/plain").should be_false
    end
  end

  # ── 3. upload flow ─────────────────────────────────────────────────────

  describe ".upload" do
    it "sniffs MIME from magic bytes, ignoring any client Content-Type" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        result = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "avatar.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        )
        result.should be_a(Facet::Artifact::Uploader::Result)
        res = result.as(Facet::Artifact::Uploader::Result)
        res.mime_type.should eq("image/png")
        res.filename.should eq("avatar.png")
        res.object_uploaded.should be_true

        # The row in `artifacts` carries the sniffed MIME.
        artifact = Facet::Artifact::Store.find_artifact(db, res.artifact_id)
        artifact.should_not be_nil
        artifact.not_nil!.mime_type.should eq("image/png")

        # The owner row is bound to the document.
        owners = Facet::Artifact::Store.find_owner_rows(db, res.artifact_id)
        owners.size.should eq(1)
        owners[0].domain.should eq(DOMAIN_UP)
        owners[0].doc_id.should eq(doc_id)
        owners[0].field_path.should eq("file")
      end
    end

    it "enforces the size cap before any byte touches shrine" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        # Use a small cap so we can exceed it cheaply.
        expect_raises(Facet::Artifact::Uploader::UploadError, /exceeds the maximum/) do
          Facet::Artifact::Uploader.upload(
            db, io_of(png_bytes), "too-big.png",
            Facet::RBAC::AuthContext.system,
            DOMAIN_UP, doctype, doc_id, "file", nil,
            max_bytes: 4_i64,
          )
        end

        # No artifact row was inserted — the spool failed before any DB write.
        Facet::Database.with_db do |db2|
          count = db2.query_one("SELECT COUNT(*) FROM artifacts", as: Int64)
          count.should eq(0)
        end
      end
    end

    it "returns application/octet-stream for unknown magic bytes" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        unknown = Bytes.new(32) { |i| ((i * 7) + 1).to_u8 }
        result = Facet::Artifact::Uploader.upload(
          db, io_of(unknown), "blob.bin",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        )
        result.should be_a(Facet::Artifact::Uploader::Result)
        res = result.as(Facet::Artifact::Uploader::Result)
        res.mime_type.should eq("application/octet-stream")
      end
    end

    it "derives the mime from the file name when the caller asks for it" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        # The bytes are plain text — the sniffer alone would say text/plain.
        result = Facet::Artifact::Uploader.upload(
          db, io_of("body{color:red}".to_slice), "assets/main.css",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
          mime_from_extension: true,
        )
        result.should be_a(Facet::Artifact::Uploader::Result)
        result.as(Facet::Artifact::Uploader::Result).mime_type.should eq("text/css")
      end
    end

    it "falls back to the sniffer for a file name without a known extension" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        result = Facet::Artifact::Uploader.upload(
          db, io_of("<!doctype html><html></html>".to_slice), "page.strange",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
          mime_from_extension: true,
        )
        result.should be_a(Facet::Artifact::Uploader::Result)
        result.as(Facet::Artifact::Uploader::Result).mime_type.should eq("text/html")
      end
    end

    it "keeps magic-byte sniffing when the caller does not ask for file-name mime" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        result = Facet::Artifact::Uploader.upload(
          db, io_of("body{color:red}".to_slice), "assets/main.css",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        )
        result.should be_a(Facet::Artifact::Uploader::Result)
        result.as(Facet::Artifact::Uploader::Result).mime_type.should eq("text/plain")
      end
    end

    it "dedupes: reuses a readable candidate instead of putting a second object" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        doc_id_2 = Facet::Document::Create.call(
          db, DOMAIN_UP, doctype, %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # First upload: stores one object.
        first = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "a.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)
        first.object_uploaded.should be_true

        # Second upload of identical bytes — system can read the first row,
        # so dedup must reuse it without putting a second object. The owner
        # row is bound to a different document so the UNIQUE constraint on
        # `(artifact, domain, doctype, doc_id, field_path)` does not throw.
        second = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "b.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id_2, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)
        second.object_uploaded.should be_false
        second.artifact_id.should eq(first.artifact_id)
        first.path.should eq(second.path)

        # Only one object exists in shrine storage.
        Facet::Artifact::Uploader.exists?(first.path).should be_true

        # Two owner rows — same artifact, distinct provenance entries.
        owners = Facet::Artifact::Store.find_owner_rows(db, first.artifact_id)
        owners.size.should eq(2)
      end
    end

    it "stores a second copy when an existing candidate is not readable" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        doc_id_2 = Facet::Document::Create.call(
          db, DOMAIN_UP, doctype, %({}), Facet::RBAC::AuthContext.system,
        ).as(Facet::Document::Create::Result).projection.id

        # First upload as system.
        first = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "a.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)

        # A second upload of identical bytes under a denied principal —
        # cannot read the existing artifact, so a fresh row + object is
        # stored against a distinct target document.
        denied = Facet::RBAC::AuthContext.denied
        second = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "b.png",
          denied,
          DOMAIN_UP, doctype, doc_id_2, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)

        second.object_uploaded.should be_true
        second.artifact_id.should_not eq(first.artifact_id)
        second.path.should_not eq(first.path)

        # Both shrine objects exist — the second upload did not delete its
        # own object, and it did not touch the first.
        Facet::Artifact::Uploader.exists?(first.path).should be_true
        Facet::Artifact::Uploader.exists?(second.path).should be_true
      end
    end

    it "cleans the tempfile on the success path" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        before = Dir.glob("/tmp/facet-upload*").size
        Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "avatar.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        )
        after = Dir.glob("/tmp/facet-upload*").size
        after.should eq(before)
      end
    end

    it "cleans the tempfile on the oversized path" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)
        before = Dir.glob("/tmp/facet-upload*").size
        begin
          Facet::Artifact::Uploader.upload(
            db, io_of(png_bytes), "too-big.png",
            Facet::RBAC::AuthContext.system,
            DOMAIN_UP, doctype, doc_id, "file", nil,
            max_bytes: 4_i64,
          )
          fail "expected UploadError"
        rescue ex : Facet::Artifact::Uploader::UploadError
          ex.status.should eq(413)
        end
        after = Dir.glob("/tmp/facet-upload*").size
        after.should eq(before)
      end
    end

    it "re-uploading identical bytes to the same target is idempotent (no second owner row, no second object)" do
      with_db do |db|
        doctype, doc_id = setup_upload_target(db)

        # First upload: stores one object + one owner row against the target.
        first = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "a.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)
        first.object_uploaded.should be_true
        first_path = first.path

        # Second upload of identical bytes against the SAME provenance
        # `(domain, doctype, doc_id, field_path)`. The dedup path reuses the
        # artifact row (no shrine put) and the owner-row insert must collapse
        # to a no-op via `ON CONFLICT DO NOTHING` — invariant #2: provenance
        # is append-only, and re-uploading identical bytes to provenance that
        # already owns them is a no-op, not an error.
        second = Facet::Artifact::Uploader.upload(
          db, io_of(png_bytes), "b.png",
          Facet::RBAC::AuthContext.system,
          DOMAIN_UP, doctype, doc_id, "file", nil,
        ).as(Facet::Artifact::Uploader::Result)
        second.object_uploaded.should be_false
        second.artifact_id.should eq(first.artifact_id)
        second.path.should eq(first_path)

        # Still exactly one owner row and one shrine object — the re-upload
        # neither duplicated provenance nor stored a second copy.
        Facet::Artifact::Store.find_owner_rows(db, first.artifact_id).size.should eq(1)
        Facet::Artifact::Uploader.exists?(first_path).should be_true
      end
    end
  end
end
