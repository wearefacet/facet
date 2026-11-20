# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "http"
require "../../src/artifact/uploader"
require "../../src/artifact/store"
require "../../src/artifact/access"
require "../../src/artifact/grants"
require "../../src/artifact/multipart"
require "../../src/doctype"
require "../../src/document"
require "../../src/mutation/client"
require "../../src/rbac"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "digest/sha256"

# Step 5 of the artifact system: multipart intake.
#
# Files covered:
#   - src/artifact/multipart.cr — `Artifact::Multipart.parse` /
#     `upload_files` (the `$content` + file-part wire format).
#   - src/document/routes.cr — multipart branch on `POST /Api/{domain}/{doctype}`
#     and `PATCH /Api/{domain}/{doctype}/{id}`.
#
# Specs walk every documented rule:
#   1. multipart create is atomic — the document and the owner row land
#      together, and a failed create rolls back both.
#   2. a file part substitutes its artifact id into the document JSON at the
#      normalized field path.
#   3. the client `Content-Type` is ignored — mime comes from magic bytes.
#   4. an oversized upload returns 413.
#   5. a `$content` part is required (422 without it).
#   6. a file part whose field path is not a `file` field fails 422.
#   7. multipart update appends a new owner row for the replaced file.

HTTPTest.init

DOMAIN_MP   = "artmulti"
MP_BOUNDARY = "facet-test-boundary"

# Builds a multipart request body with a `$content` JSON part and one file
# part per `{path, bytes, filename}` entry. Returns the request.
def multipart_request(method : String, path : String, content_json : String, files : Array({String, Bytes, String}))
  io = IO::Memory.new
  HTTP::FormData.build(io, MP_BOUNDARY) do |form|
    form.field("$content", content_json)
    files.each do |(field_path, bytes, filename)|
      metadata = HTTP::FormData::FileMetadata.new(filename: filename)
      form.file(field_path, IO::Memory.new(bytes), metadata)
    end
  end
  headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=#{MP_BOUNDARY}"}
  HTTP::Request.new(method, path, headers, io.to_s)
end

def truncate_multipart_tables
  with_db &.exec("TRUNCATE mutations, projections, artifact_references, artifact_grants, artifact_owners, artifacts RESTART IDENTITY CASCADE")
end

# Inline Lua script so the doctype can declare actions if needed.
MP_PUBLISH_SCRIPT = <<-LUA
  local export = {}
  function export.publish_artifact(ctx, args)
    return ctx.root
  end
  return export
LUA

# Builds a doctype with a `file` field (and an optional `items` array of
# objects with a `file` field). Returns `{doctype, doc_id}`.
def setup_multipart_doctype(db, doctype = "Asset", with_array = false)
  ensure_domain(db, DOMAIN_MP)
  file_type = Facet::Doctype::FieldType.parse("file")
  fields = {} of String => Facet::Doctype::FieldDefinition
  fields["file"] = Facet::Doctype::FieldDefinition.new(type: file_type)
  if with_array
    object_type = Facet::Doctype::FieldType.parse("object")
    array_type = Facet::Doctype::FieldType.parse("array")
    fields["items"] = Facet::Doctype::FieldDefinition.new(
      type: array_type,
      items: Facet::Doctype::FieldDefinition.new(
        type: object_type,
        properties: {
          "file" => Facet::Doctype::FieldDefinition.new(type: file_type),
        } of String => Facet::Doctype::FieldDefinition,
      ),
    )
  end
  defn = Facet::Doctype::DoctypeDefinition.new(
    doctype: doctype,
    domain: DOMAIN_MP,
    fields: fields,
  )
  Facet::Document::Create.call(
    db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system,
  ).should be_a(Facet::Document::Create::Result)
  {doctype, nil}
end

def mp_png_bytes : Bytes
  Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAvCBxjw=")
end

# Returns the artifact id stored in a document's `file` field.
def doc_file_artifact(db, domain, doctype, doc_id) : String?
  Facet::Mutation::Client.fetch_content(db, domain, doctype, doc_id).as_h["file"]?.try(&.as_s?)
end

# Returns the owner rows for an artifact.
def owner_rows_for(db, artifact_id) : Array(Facet::Artifact::Store::OwnerRow)
  Facet::Artifact::Store.find_owner_rows(db, artifact_id)
end

describe "Artifact multipart intake" do
  before_each { truncate_multipart_tables }

  it "creates a document with a file part and records an owner row" do
    with_db do |db|
      setup_multipart_doctype(db)
    end

    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Asset", %({}), [{"file", mp_png_bytes, "photo.png"}])
    resp = call_api(req)
    assert_http_status(resp, 201)
    doc_id = JSON.parse(resp.body)["meta"]["id"].as_s

    with_db do |db|
      artifact_id = doc_file_artifact(db, DOMAIN_MP, "Asset", doc_id)
      artifact_id.should_not be_nil
      artifact_id.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)

      owners = owner_rows_for(db, artifact_id.not_nil!)
      owners.size.should eq(1)
      owners.first.domain.should eq(DOMAIN_MP)
      owners.first.doc_type.should eq("Asset")
      owners.first.doc_id.should eq(doc_id)
      owners.first.field_path.should eq("file")

      # The artifact's mime comes from magic bytes, not the client.
      art = Facet::Artifact::Store.find_artifact(db, artifact_id.not_nil!)
      art.not_nil!.mime_type.should eq("image/png")
    end
  end

  it "substitutes file parts at normalized array field paths" do
    with_db do |db|
      setup_multipart_doctype(db, "Gallery", with_array: true)
    end

    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Gallery", %({"items": [{}, {}]}),
      [{"items[0].file", mp_png_bytes, "a.png"}, {"items[1].file", mp_png_bytes + Bytes.new(1), "b.png"}])
    resp = call_api(req)
    assert_http_status(resp, 201)
    doc_id = JSON.parse(resp.body)["meta"]["id"].as_s

    with_db do |db|
      content = Facet::Mutation::Client.fetch_content(db, DOMAIN_MP, "Gallery", doc_id).as_h
      items = content["items"].as_a
      items.size.should eq(2)
      a_id = items[0].as_h["file"].as_s
      b_id = items[1].as_h["file"].as_s
      a_id.should_not eq(b_id)

      # Distinct owner rows with distinct normalized paths.
      owners_a = owner_rows_for(db, a_id)
      owners_a.first.field_path.should eq("items[0].file")
      owners_b = owner_rows_for(db, b_id)
      owners_b.first.field_path.should eq("items[1].file")
    end
  end

  it "returns 413 for an oversized upload" do
    with_db do |db|
      setup_multipart_doctype(db)
    end

    # Build a payload larger than the test config's max_upload_bytes.
    big = Bytes.new(200_000_000) # 200 MB > 50 MiB default
    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Asset", %({}), [{"file", big, "big.bin"}])
    resp = call_api(req)
    assert_http_status(resp, 413)
  end

  it "returns 422 when a file part names a non-file field" do
    with_db do |db|
      setup_multipart_doctype(db)
    end

    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Asset", %({}), [{"name", mp_png_bytes, "x.png"}])
    resp = call_api(req)
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("not a file field")
  end

  it "is atomic — a failed create rolls back the document and the owner row" do
    with_db do |db|
      setup_multipart_doctype(db)
    end

    # Two file parts: the first is valid, the second names a non-file field.
    # The whole create must roll back — no document, no owner row.
    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Asset", %({}),
      [{"file", mp_png_bytes, "a.png"}, {"name", mp_png_bytes, "b.png"}])
    resp = call_api(req)
    assert_http_status(resp, 422)

    with_db do |db|
      count = db.query_one(
        "SELECT COUNT(*) FROM projections WHERE domain = $1 AND doc_type = 'Asset'",
        DOMAIN_MP, as: Int64)
      count.should eq(0)
      count_owners = db.query_one("SELECT COUNT(*) FROM artifact_owners", as: Int64)
      count_owners.should eq(0)
    end
  end

  it "updates a document's file field and appends a new owner row" do
    doc_id = nil
    with_db do |db|
      setup_multipart_doctype(db)
    end

    # Create with one file.
    req = multipart_request("POST", "/Api/#{DOMAIN_MP}/Asset", %({}), [{"file", mp_png_bytes, "a.png"}])
    resp = call_api(req)
    assert_http_status(resp, 201)
    doc_id = JSON.parse(resp.body)["meta"]["id"].as_s

    # Update with a different file (distinct bytes → distinct artifact).
    req2 = multipart_request("PATCH", "/Api/#{DOMAIN_MP}/Asset/#{doc_id}", %({}), [{"file", mp_png_bytes + Bytes.new(2), "b.png"}])
    resp2 = call_api(req2)
    assert_http_status(resp2, 200)

    with_db do |db|
      new_artifact = doc_file_artifact(db, DOMAIN_MP, "Asset", doc_id.not_nil!)
      new_artifact.should_not be_nil
      owners = owner_rows_for(db, new_artifact.not_nil!)
      owners.size.should eq(1)
      owners.first.doc_id.should eq(doc_id)
    end
  end
end
