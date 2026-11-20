# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"
require "file"
require "log"
require "json"
require "shrine"
require "shrine/storage/file_system"
require "shrine/storage/s3"
require "../config"
require "../util/script_helpers"
require "../rbac"
require "./store"
require "./access"

module Facet
  module Artifact
    # Shrine-based uploader for artifact bytes.
    #
    # Implements the flow documented in `doc/backend/artifact.md`:
    #
    #   1. Spool the request body to a tempfile, enforcing `max_upload_bytes`
    #      before any byte touches shrine. An oversized upload yields `413`
    #      without spooling the tempfile to disk (the reshold is the first
    #      thing checked against an in-memory read of the first chunk).
    #   2. Compute the SHA-256 of the spooled bytes.
    #   3. Decide the MIME type on the server, never from the client's
    #      `Content-Type` header. The magic-byte sniffer is the default.
    #      Deploy callers may pass `mime_from_extension`: static build
    #      assets (html, css, js) are all text, so the file name decides
    #      the type and the sniffer stays the fallback.
    #   4. Look up candidate `artifacts` rows by `signature_sha256` and
    #      reuse the first one the caller can read (skip the shrine put).
    #      When no candidate is readable, shrine puts a fresh object keyed
    #      at `{sha256}/{ulid}` and stores a second `artifacts` row.
    #
    # The store / dedup / owner-row decisions happen in a transaction; shrine
    # puts happen outside it (S3 cannot roll back). On any error after a
    # successful put, the uploader deletes the object it wrote (best-effort)
    # before re-raising. When a candidate was reused there is nothing of
    # ours to clean up.
    #
    # The `Artifact::Routes` HTTP layer calls this service; copying flows
    # (`Document::Copy`, `Domain::Publish`, cross-domain replication) append
    # an `artifact_owners` row without re-uploading — see `Artifact::Store`.
    class Uploader
      # Result of an upload. Carries enough to materialise an `artifact_owners`
      # row and to schedule a best-effort cleanup on a rolled-back transaction.
      record Result,
        artifact_id : String,
        path : String,
        filename : String,
        mime_type : String,
        size : Int64,
        signature_sha256 : String,
        # `true` when this request shrine-put a new object. `false` when the
        # request reused an existing `artifacts` row via dedup. Callers MUST
        # NOT schedule shrine cleanup on the reuse path.
        object_uploaded : Bool

      # MIME type returned when the magic-byte sniffer has no match.
      UNKNOWN_MIME = "application/octet-stream"

      # Authoritative MIME types recognised as inline-safe on the serve route.
      # SVG is deliberately excluded (served as attachment) even though the
      # sniffer normalises it to `image/svg+xml`.
      INLINE_MIME_PREFIXES = {"audio/", "video/"}
      INLINE_MIME_EXACT    = {"image/png", "image/jpeg", "image/gif",
                              "image/webp", "application/pdf"}

      # Sniffs a MIME type from the first bytes of `io`. Returns
      # `UNKNOWN_MIME` when no signature matches. The IO is rewound after
      # sniffing so the caller can stream the bytes onward.
      def self.sniff_mime(io : IO) : String
        # Read the first 8 KB once — enough for every signature we ship.
        buf_size = 8192
        buf = Bytes.new(buf_size)
        read = io.read(buf)
        io.rewind
        sniff_buffer(buf[0, read])
      end

      # Returns true when `mime_type` is on the inline-allowlist. Used by the
      # serve route to gate `Content-Disposition: inline`. SVG and unknown
      # types are always attachments.
      def self.inline_mime?(mime_type : String) : Bool
        return true if INLINE_MIME_EXACT.includes?(mime_type)
        INLINE_MIME_PREFIXES.any? { |p| mime_type.starts_with?(p) }
      end

      # ── Signature table ────────────────────────────────────────────────

      # A signature entry: a magic prefix and the MIME it yields. The list is
      # ordered longest-match-first (no overlapping entries by design — the
      # longest unambiguous prefix always wins). See `signatures` below.
      private record Signature, magic : Bytes, mime : String

      # Magic-byte signatures. Ordered by descending ambiguity: any prefix
      # that is a *prefix* of another comes after the longer one. ZIP-based
      # OOXML subtypes probe the central directory for their unique marker.
      #
      # ~30 types. The fallback for a printable-only buffer is plain text;
      # everything else yields `application/octet-stream`.
      private def self.signatures : Array(Signature)
        # Bytes literal helper for compact signature spelling.
        sig = ->(s : String) { s.to_slice }

        # clang-format off
        [
          # ── Images ─────────────────────────────────────────────────────
          Signature.new(sig.call("\x89PNG\r\n\x1a\n"), "image/png"),
          Signature.new(sig.call("\xFF\xD8\xFF"), "image/jpeg"),
          Signature.new(sig.call("GIF87a"), "image/gif"),
          Signature.new(sig.call("GIF89a"), "image/gif"),
          Signature.new(sig.call("BM"), "image/bmp"),
          Signature.new(sig.call("II*\x00"), "image/tiff"),
          Signature.new(sig.call("MM\x00*"), "image/tiff"),

          # ── Audio / Video ─────────────────────────────────────────────
          # RIFF, EBML, MP4 ftyp, and ZIP (PK..) are composite-only — the
          # disambiguating bytes sit deeper in the header. See
          # `sniff_composite`.
          Signature.new(sig.call("ID3"), "audio/mpeg"),          # MP3 (ID3v2)
          Signature.new(sig.call("\xFB\xD3\xD3"), "audio/mpeg"), # MP3 frame sync
          Signature.new(sig.call("fLaC"), "audio/flac"),
          Signature.new(sig.call("OggS"), "audio/ogg"), # generic Ogg; refined below
          Signature.new(sig.call("\x00\x00\x01\xBA"), "video/mpeg"),

          # ── Documents / archives ──────────────────────────────────────
          Signature.new(sig.call("%PDF-"), "application/pdf"),
          Signature.new(sig.call("\x1F\x8B"), "application/gzip"),
          Signature.new(sig.call("\xFD7zXZ\x00"), "application/x-xz"),
          Signature.new(sig.call("BZh"), "application/x-bzip2"),
          Signature.new(sig.call("7z\xBC\xAF\x27\x1C"), "application/x-7z-compressed"),
          Signature.new(sig.call("Rar!\x1A\x07"), "application/x-rar"),
          Signature.new(sig.call("MZ"), "application/x-msdownload"),

          # ── Executables ───────────────────────────────────────────────
          Signature.new(sig.call("\x7FELF"), "application/x-elf"),
          Signature.new(sig.call("\xFE\xED\xFA\xCE"), "application/x-mach-o"),
          Signature.new(sig.call("\xFE\xED\xFA\xCF"), "application/x-mach-o"),
          Signature.new(sig.call("\xCE\xFA\xED\xFE"), "application/x-mach-o"),
          Signature.new(sig.call("\xCF\xFA\xED\xFE"), "application/x-mach-o"),

          # ── Text-shaped (sniff from the leading bytes) ────────────────
          # HTML is also matched case-insensitively behind a BOM,
          # whitespace, or a short comment — see `sniff_markup`.
          Signature.new(sig.call("<?xml"), "application/xml"),
          Signature.new(sig.call("<!DOCTYPE"), "text/html"),
          Signature.new(sig.call("<html"), "text/html"),
          Signature.new(sig.call("<svg"), "image/svg+xml"),
        ]
        # clang-format on
      end

      # Probes a magic-byte buffer and returns the MIME type. The buffer
      # carries at most the first 8 KB of the upload.
      private def self.sniff_buffer(buf : Bytes) : String
        # Pass 1 — exact prefix matches against a single magic.
        # The signature list is ordered longest-first, so the first prefix
        # match wins. Returns `application/octet-stream` for any buffer that
        # doesn't start with a known prefix.
        signatures.each do |entry|
          return entry.mime if bytes_start_with?(buf, entry.magic)
        end

        # Pass 2 — markup. HTML is case-insensitive and often opens with
        # a BOM, whitespace, or a short comment before the doctype. See
        # `sniff_markup`.
        markup = sniff_markup(buf)
        return markup if markup

        # Pass 3 — composite signatures requiring multiple probes.
        # Keep this short — the goal is correctness, not completeness.
        # New composite cases go here.
        composite = sniff_composite(buf)
        return composite if composite

        # Pass 4 — heuristic plain-text detection. A buffer full of
        # printable ASCII / common whitespace is treated as `text/plain`.
        # Anything else (binary, partial UTF-8 etc.) decays to octet-stream.
        return "text/plain" if looks_like_text?(buf)

        UNKNOWN_MIME
      end

      # Returns true when `buf` starts with the byte sequence `prefix`. Used
      # by the signature-table pass since `Slice` lacks `starts_with?`.
      private def self.bytes_start_with?(buf : Bytes, prefix : Bytes) : Bool
        return false if buf.size < prefix.size
        buf[0, prefix.size] == prefix
      end

      # ── Markup sniffing ────────────────────────────────────────────────

      # Lowercase probes for `sniff_markup`; the compare folds A–Z.
      MARKUP_DOCTYPE_PROBE = "<!doctype".to_slice
      MARKUP_HTML_PROBE    = "<html".to_slice

      # How far into the buffer `sniff_markup` looks for the probes.
      # Bounded on purpose: a match deep in the file would mislabel text
      # that only mentions HTML.
      MARKUP_SNIFF_WINDOW = 64

      # HTML detection for the buffers the signature table missed. Real
      # HTML opens with a lowercase `<!doctype html>` as often as upper,
      # and editors or build tools add a UTF-8 BOM, whitespace, or a short
      # comment first. The pass scans the first window for a case-insensitive
      # `<!doctype` or `<html`.
      #
      # The scan works on bytes only — no string is built — so a binary
      # buffer cannot break it. Returns `nil` when no probe matches, so
      # `sniff_buffer` falls through to the composite and text passes.
      private def self.sniff_markup(buf : Bytes) : String?
        limit = Math.min(buf.size, MARKUP_SNIFF_WINDOW)

        offset = 0
        while offset < limit
          return "text/html" if ascii_ci_prefix?(buf, offset, MARKUP_DOCTYPE_PROBE)
          return "text/html" if ascii_ci_prefix?(buf, offset, MARKUP_HTML_PROBE)
          offset += 1
        end
        nil
      end

      # True when the bytes at `offset` equal `prefix` in ASCII
      # case-insensitive terms. Only A–Z folds; every other byte compares
      # verbatim, so binary buffers stay opaque.
      private def self.ascii_ci_prefix?(buf : Bytes, offset : Int32, prefix : Bytes) : Bool
        return false if offset + prefix.size > buf.size
        prefix.each_with_index do |p, i|
          b = buf[offset + i]
          b += 0x20 if b >= 0x41 && b <= 0x5A # 'A'..'Z' folds to 'a'..'z'
          return false if b != p
        end
        true
      end

      # Composite signatures — requiring more than a single magic prefix to
      # disambiguate the format. Returns `nil` when no composite matches,
      # so `sniff_buffer` falls through to the text/octet-stream tail.
      private def self.sniff_composite(buf : Bytes) : String?
        if bytes_start_with?(buf, "RIFF".to_slice)
          # RIFF → check the four bytes at offset 8: "WEBP", "WAVE", "AVI ".
          # If the marker is missing, decay to a generic RIFF container.
          marker = buf_at(buf, 8, 4)
          return "image/webp" if marker == "WEBP"
          return "audio/wav" if marker == "WAVE"
          return "video/x-msvideo" if marker == "AVI "
          return UNKNOWN_MIME
        end

        if bytes_start_with?(buf, "\x1A\x45\xDF\xA3".to_slice)
          # EBML → probe the doctype element for "matroska" or "webm".
          return sniff_ebml_doctype(buf)
        end

        if bytes_start_with?(buf, "\x00\x00\x00".to_slice) && buf.size >= 12 &&
           buf_at(buf, 4, 4) == "ftyp"
          return sniff_mp4_brand(buf)
        end

        if bytes_start_with?(buf, "PK\x03\x04".to_slice)
          # ZIP — peek for OOXML subtypes by scanning the first 4 KB for the
          # `[Content_Types].xml` magic that uniquely identifies Office
          # Open XML packages. Falls back to `application/zip` otherwise.
          return sniff_ooxml(buf)
        end

        nil
      end

      # Probes an MP4 `ftyp` brand at offset 8. Returns `audio/mp4` for the
      # M4A/M4B/M4P family, `video/mp4` for the common video brands, and
      # `video/mp4` as the default (octet-stream bars browsers from inline
      # playback).
      private def self.sniff_mp4_brand(buf : Bytes) : String
        brand = String.new(buf[8, 4])
        return "audio/mp4" if brand.in?("M4A ", "M4B ", "M4P ")
        return "video/mp4" if brand.in?("mp42", "isom", "avc1", "qt  ", "MSNV", "mp41")
        "video/mp4"
      end

      # Reads up to `length` bytes at offset `offset` from `buf`, padding
      # with NUL when the buffer is shorter. Used for composite probes.
      private def self.buf_at(buf : Bytes, offset : Int32, length : Int32) : String
        return "" if offset >= buf.size
        avail = Math.min(length, buf.size - offset)
        String.new(buf[offset, avail])
      end

      # Probes an EBML header for the doctype element to disambiguate
      # WebM from generic Matroska. Returns `video/webm` for a `webm`
      # doctype, `video/x-matroska` for `matroska`, otherwise `UNKNOWN_MIME`.
      private def self.sniff_ebml_doctype(buf : Bytes) : String
        # Locate the literal "webm" / "matroska" doctype string anywhere in
        # the first 64 bytes of the EBML header. The element encoding uses
        # variable-width integers; a string probe is the cheapest heuristic
        # against the first element body.
        window = buf[0, Math.min(buf.size, 64)]
        str = String.new(window)
        return "video/webm" if str.includes?("webm")
        return "video/x-matroska" if str.includes?("matroska")
        UNKNOWN_MIME
      end

      # Sniffs an OOXML package's `[Content_Types].xml` for the document's
      # override mime. Returns `application/zip` when no override is found.
      private def self.sniff_ooxml(buf : Bytes) : String
        # The `Content_Types` overrides carry document-type defaults for each
        # part; we look for the ones that distinguish the four major package
        # kinds (Word, Excel, PowerPoint, Visio). The marker is the part
        # name matched against the `PartName="…"` attribute inside the
        # package's content-types stream. To avoid a full XML parse we look
        # for the unique constants that identify each kind.
        window = String.new(buf[0, Math.min(buf.size, 8192)])
        return "application/vnd.openxmlformats-officedocument.wordprocessingml.document" if window.includes?("wordprocessingml.document.main+xml")
        return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" if window.includes?("spreadsheetml.sheet")
        return "application/vnd.openxmlformats-officedocument.presentationml.presentation" if window.includes?("presentationml.presentation.main+xml")
        "application/zip"
      end

      # Heuristic: returns true when at least 80% of the buffer bytes are
      # printable ASCII (0x20..0x7E), newline (0x0A), tab (0x09), or
      # carriage return (0x0D), AND the buffer is non-empty. Trailing NUL
      # padding from the read buffer is excluded.
      private def self.looks_like_text?(buf : Bytes) : Bool
        return false if buf.empty?
        printable = 0
        total = 0
        buf.each do |b|
          # Skip trailing zero padding from the read target.
          break if b == 0 && total + printable >= buf.size
          total += 1
          printable += 1 if (0x20 <= b <= 0x7E) || b == 0x0A || b == 0x09 || b == 0x0D
        end
        return false if total == 0
        (printable.to_f / total.to_f) >= 0.8
      end

      # ── File-name mime ─────────────────────────────────────────────────

      # Extension → MIME table for deployed app builds. Static build assets
      # are mostly text — html, css, js, svg all decay to `text/plain`
      # under the sniffer — so the deploy route reads the type from the
      # file name and falls back to the sniffer. The runtime image ships
      # no system mime database, so the table is static and small.
      EXTENSION_MIMES = {
        ".avif"        => "image/avif",
        ".css"         => "text/css",
        ".csv"         => "text/csv",
        ".eot"         => "application/vnd.ms-fontobject",
        ".gif"         => "image/gif",
        ".gz"          => "application/gzip",
        ".htm"         => "text/html",
        ".html"        => "text/html",
        ".ico"         => "image/x-icon",
        ".jpeg"        => "image/jpeg",
        ".jpg"         => "image/jpeg",
        ".js"          => "text/javascript",
        ".json"        => "application/json",
        ".map"         => "application/json",
        ".mjs"         => "text/javascript",
        ".mp3"         => "audio/mpeg",
        ".mp4"         => "video/mp4",
        ".otf"         => "font/otf",
        ".pdf"         => "application/pdf",
        ".png"         => "image/png",
        ".svg"         => "image/svg+xml",
        ".ttf"         => "font/ttf",
        ".txt"         => "text/plain",
        ".wasm"        => "application/wasm",
        ".wav"         => "audio/wav",
        ".webm"        => "video/webm",
        ".webmanifest" => "application/manifest+json",
        ".webp"        => "image/webp",
        ".woff"        => "font/woff",
        ".woff2"       => "font/woff2",
        ".xml"         => "application/xml",
      }

      # Returns the MIME registered for `filename`'s extension, or `nil`
      # when the name carries none the table knows. The lookup is
      # case-insensitive. A leading dot (`.gitignore`) is a dotfile, not
      # an extension.
      def self.extension_mime(filename : String) : String?
        dot = filename.rindex('.')
        return nil if dot.nil? || dot.zero?
        EXTENSION_MIMES[filename[dot..].downcase]?
      end

      # ── Storage access ────────────────────────────────────────────────

      # The shrine storage key artifact bytes live under. There is exactly
      # one storage — `artifact.storage` in the config — so the key is a
      # constant.
      private STORAGE_KEY = "store"

      # Configures the shrine storage from the application config
      # (idempotent). Used by the uploader and the serve route to resolve
      # the storage object for put / open / delete. The storage entry is
      # validated at config load (`Artifact::Config.from_yaml`); the
      # unknown-type guard below only covers storages built in code.
      def self.configure_storages! : Nil
        return if shrine_configured?

        sc = ::Facet::Config.instance.artifact.storage

        Shrine.configure do |c|
          case sc.type
          when "filesystem"
            dir = File.expand_path(sc.directory)
            c.storages[STORAGE_KEY] = Shrine::Storage::FileSystem.new(dir)
          when "s3"
            c.storages[STORAGE_KEY] = Shrine::Storage::S3.new(
              bucket: sc.bucket.as(String),
              client: build_s3_client(sc),
              prefix: sc.directory,
            )
          else
            raise "Unknown artifact.storage type: #{sc.type}"
          end
        end
      end

      # Returns true once the shrine storage has been wired.
      private def self.shrine_configured? : Bool
        Shrine.settings.storages.any?
      end

      # Builds an Awscr::S3 client. Passes the endpoint when set so
      # S3-compatible backends (MinIO, R2, Backblaze) work.
      private def self.build_s3_client(sc : ::Facet::Artifact::Config::Storage) : Awscr::S3::Client
        Awscr::S3::Client.new(
          sc.region.as(String),
          sc.access_key_id.as(String),
          sc.secret_access_key.as(String),
          endpoint: sc.endpoint,
        )
      end

      # Resolves the shrine storage, configuring it on first access.
      private def self.find_storage(key : String) : Shrine::Storage::Base
        configure_storages! unless shrine_configured?
        Shrine.find_storage(key)
      end

      # Returns the shrine key the uploader uses for new puts. Tests
      # override via `storage_key=` on the request.
      def self.primary_storage_key : String
        STORAGE_KEY
      end

      # Returns the shrine Storage object that holds artifact objects.
      def self.storage : Shrine::Storage::Base
        find_storage(primary_storage_key)
      end

      # Opens an artifact's IO for reading. The caller is responsible for
      # closing the returned IO once streaming is done.
      def self.open(path : String) : IO
        storage.open(path)
      end

      # Deletes an artifact object from shrine storage. Best-effort —
      # failures are swallowed and logged. A cleanup miss is swept by the
      # reconcile CLI (see `bin/facet artifacts:reconcile`).
      def self.delete(path : String) : Nil
        storage.delete(path)
      rescue ex
        # The shrine storage surfaced a storage error. Log and swallow so
        # the caller's transaction semantics aren't broken by a leaked
        # object — manual reconcile handles the cleanup.
        ::Log.for("facet.artifact.uploader").warn { "shrine.delete failed for #{path}: #{ex.message}" }
      end

      # Returns true when an object exists at the given path. Used by tests
      # to assert the cleanup contract.
      def self.exists?(path : String) : Bool
        storage.exists?(path)
      end

      # Yields `(key, last_modified)` for every object in the primary
      # storage, where `key` is the shrine key (the value stored in
      # `artifacts.path`). Used by `artifacts:reconcile` to find orphaned
      # objects — the shrine `Storage::Base` has no listing primitive, so
      # this is the storage-aware enumeration the reconcile CLI needs.
      def self.each_object(& : String, Time ->) : Nil
        storage = self.storage
        case storage
        when Shrine::Storage::FileSystem
          each_fs_object(storage) { |key, mtime| yield key, mtime }
        when Shrine::Storage::S3
          each_s3_object(storage) { |key, mtime| yield key, mtime }
        else
          raise "Unsupported storage for reconcile: #{storage.class}"
        end
      end

      # Walks the filesystem storage directory recursively, yielding each
      # file's shrine key (relative to the storage root) and modification
      # time.
      private def self.each_fs_object(storage : Shrine::Storage::FileSystem, & : String, Time ->) : Nil
        root = storage.expanded_directory
        return unless Dir.exists?(root)
        Dir.glob(File.join(root, "**", "*")).each do |full|
          next unless File.file?(full)
          yield full[root.size + 1..], File.info(full).modification_time
        end
      end

      # Lists the S3 bucket via `list_objects`, yielding each object's
      # shrine key (the bucket key with the storage prefix stripped) and
      # last-modified time.
      private def self.each_s3_object(storage : Shrine::Storage::S3, & : String, Time ->) : Nil
        client = storage.client
        bucket = storage.bucket
        prefix = storage.object_key("").chomp("/")
        client.list_objects(bucket, prefix: prefix).each do |response|
          response.contents.each do |obj|
            key = obj.key
            if !prefix.empty? && key.starts_with?(prefix + "/")
              key = key[prefix.size + 1..]
            end
            yield key, obj.last_modified
          end
        end
      end

      # ── Full upload flow ───────────────────────────────────────────────

      # Drives the dedup + shrine-put + owner-row insert flow inside a
      # transaction. Returns a `Result` when the artifact is persisted
      # (and the caller can hand the id to whoever asked for an upload) or
      # an `UploadError` for `413` (oversized) or `422` (no owner context).
      #
      # The caller MUST supply `(domain, doc_type, doc_id, field_path)`
      # so we can materialise the `artifact_owners` row in the same
      # transaction as the upload. The standalone `POST /Api/core/artifacts`
      # route returns 404-with-guidance precisely because it has no target
      # document to record provenance against (see `doc/backend/artifact.md`).
      #
      # Cleanup discipline: on any error *after* a successful shrine put,
      # the put is undone best-effort via `delete(path)` (failures swallowed,
      # logged — `artifacts:reconcile` sweeps misses). The tempfile is
      # always deleted in an `ensure`.
      def self.upload(
        db : DB::Connection,
        io : IO,
        filename : String,
        auth_context : ::Facet::RBAC::AuthContext,
        domain : String,
        doc_type : String,
        doc_id : String,
        field_path : String,
        view_tag : Array(String)?,
        max_bytes : Int64 = ::Facet::Config.instance.artifact.max_upload_bytes,
        storage_key : String? = nil,
        mime_from_extension : Bool = false,
      ) : Result | UploadError
        key = storage_key || primary_storage_key
        configure_storages! unless shrine_configured?

        # 1. Spool the body to a tempfile while enforcing the size cap.
        #    An oversized upload raises before any byte is shrine-put —
        #    the error carries a `413` so the route can return it directly.
        tempfile = File.tempfile("facet-upload")
        path_uploaded : String? = nil

        begin
          size = spool_with_size_cap(io, tempfile, max_bytes)
          tempfile.flush
          tempfile.rewind

          # 2. SHA-256 of the spooled bytes.
          sha256 = ::Digest::SHA256.hexdigest(tempfile.gets_to_end)
          tempfile.rewind

          # 3. MIME type. Deploy uploads read it from the file name —
          #    static build assets (html, css, js) are all text, so the
          #    bytes cannot tell them apart — and fall back to the
          #    sniffer. Every other caller sniffs the magic bytes only.
          mime = if mime_from_extension
                   extension_mime(filename) || sniff_mime(tempfile)
                 else
                   sniff_mime(tempfile)
                 end
          tempfile.rewind

          # 4. Look up candidate rows by sha256. The first row the caller
          #    can read is reused, skipping the shrine put entirely.
          candidates = ::Facet::Artifact::Store.find_candidates_by_sha256(db, sha256)
          reuse_id = candidates.find do |candidate|
            ::Facet::Artifact::Access.can_read?(db, auth_context, candidate.id)
          end

          if reuse = reuse_id
            # Reuse path: no shrine put, no object of ours to clean up.
            # The owner-row insert happens inside the same transaction as
            # the dedup decision so a rollback undoes both.
            kind = Store::PersistKind::ReuseCandidate
            artifact_id = reuse.id
            object_path = reuse.path
            reuse_artifact_id = reuse.id
            object_uploaded = false
          else
            # No readable candidate — shrine put a fresh object keyed at
            # `{sha256}/{ulid}`. Mint the ULID here so the shrine path matches
            # the `artifacts.id` the persist step will insert under (the two
            # must agree because the path is the shrine object key but `id`
            # is the database PK, and FK rows reference the PK).
            new_artifact_id = ::Facet::Util::ScriptHelpers.ulid
            new_path = "#{sha256}/#{new_artifact_id}"

            shrine_io = File.open(tempfile.path, "rb")
            begin
              uploaded = Shrine.upload(shrine_io, key, location: new_path)
              path_uploaded = uploaded.id
            ensure
              shrine_io.close
            end

            kind = Store::PersistKind::InsertFresh
            artifact_id = new_artifact_id
            object_path = new_path
            reuse_artifact_id = ""
            object_uploaded = true
          end

          begin
            payload = Store::UploadPayload.new(
              kind: kind,
              id: artifact_id,
              filename: filename,
              mime_type: mime,
              size: size,
              signature_sha256: sha256,
              path: object_path,
              domain: domain,
              doc_type: doc_type,
              doc_id: doc_id,
              field_path: field_path,
              view_tag: view_tag,
              created_by: auth_context.account_id,
              reuse_artifact_id: reuse_artifact_id,
            )
            ::Facet::Artifact::Store.persist_uploaded(db, payload)

            Result.new(
              artifact_id: artifact_id,
              path: object_path,
              filename: filename,
              mime_type: mime,
              size: size,
              signature_sha256: sha256,
              object_uploaded: object_uploaded,
            )
          rescue ex
            # The transaction rolled back, leaving a hanging shrine object.
            # Delete it best-effort; swallow failures (reconcile sweeps).
            # On the reuse path `path_uploaded` is still nil, so this is a
            # no-op and the exception propagates untouched.
            delete(object_path) if path_uploaded
            raise ex
          end
        ensure
          tempfile.close
          File.delete?(tempfile.path)
        end
      end

      # Spools `io` to `dest`, raising `UploadError.payload_too_large`
      # once the total bytes exceed `max_bytes`. Returns the total bytes
      # written. The size cap is enforced *before* any byte touches shrine —
      # the tempfile is written in 4 KB chunks and checked after each write,
      # so an oversized upload returns `413` without spooling the whole body.
      private def self.spool_with_size_cap(io : IO, dest : IO::FileDescriptor, max_bytes : Int64) : Int64
        chunk = Bytes.new(4096)
        total : Int64 = 0
        loop do
          read = io.read(chunk)
          break if read == 0
          total += read.to_i64
          if total > max_bytes
            raise UploadError.payload_too_large(max_bytes)
          end
          dest.write(chunk[0, read])
        end
        total
      end

      # Upload path error. `PayloadTooLarge` carries a meaningful HTTP status.
      class UploadError < ::Exception
        getter status : Int32

        def initialize(@status : Int32, message : String)
          super(message)
        end

        def self.payload_too_large(max_bytes : Int64)
          new(413, "Upload exceeds the maximum allowed size (#{max_bytes} bytes)")
        end
      end
    end
  end
end
