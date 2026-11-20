# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "yaml"
require "../../src/http/server"
require "../../src/doctype/yaml_helper"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# ── Helpers ──────────────────────────────────────────────────────────────
#
# All helpers carry the `rest_etag_` prefix — spec files compile into one
# binary, so top-level names must not collide with the other spec files
# (this file must also stay runnable on its own via
# `crystal spec spec/http/rest_etag_spec.cr`).

# Performs a GET with optional request headers (used to send `If-None-Match`).
def rest_etag_get(path : String, headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  call_api(HTTP::Request.new("GET", path, headers: h))
end

def rest_etag_patch_nested(domain : String, root_doctype : String, root_id : String, rel_name : String, child_id : String, json_body : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("PATCH", "/Api/#{domain}/#{root_doctype}/#{root_id}/#{rel_name}/#{child_id}", body: json_body))
end

def rest_etag_delete_nested(domain : String, root_doctype : String, root_id : String, rel_name : String, child_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("DELETE", "/Api/#{domain}/#{root_doctype}/#{root_id}/#{rel_name}/#{child_id}"))
end

# Seeds the `etagrest` domain plus a `Customer` aggregate root with a
# `contacts` children relationship and its `member_of` child `Contact`.
def rest_etag_seed_customer_contact! : Nil
  resp = create_domain_http("etagrest")
  assert_http_status(resp, 201)

  parent = %({
    "doctype": "Customer",
    "domain": "etagrest",
    "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": { "name": { "type": "string" } },
    "children": { "contacts": { "doctype": "Contact", "collection": true } }
  })
  assert_http_status(create_doctype_http(parent), 201)

  child = %({
    "doctype": "Contact",
    "domain": "etagrest",
    "aggregate_root": false,
    "member_of": "Customer",
    "fields": { "name": { "type": "string" } }
  })
  assert_http_status(create_doctype_http(child), 201)
end

def rest_etag_create_customer!(name : String) : String
  create_doc_id_http("etagrest", "Customer", %({"name": #{name.to_json}}))
end

def rest_etag_create_contact!(customer_id : String, name : String) : String
  create_child_doc_id_http("etagrest", "Customer", customer_id, "contacts", %({"name": #{name.to_json}}))
end

# Parses a seed directory's `definition.yml` and injects a co-located
# `script.lua` as the definition's `script` field — the same step the seed
# runner performs. Returns the JSON string to persist as the `core.DocType`
# content.
def rest_etag_seed_definition_with_script(dir : String) : String
  yaml = YAML.parse(File.read(File.join(dir, "definition.yml")))
  parsed = Facet::Doctype::YamlHelper.to_json_any(yaml)
  script_path = File.join(dir, "script.lua")
  parsed.as_h["script"] = JSON::Any.new(File.read(script_path)) if File.exists?(script_path)
  parsed.to_json
end

# Registers the production-seeded `core.Comment` sidecar doctype (with its
# Lua `create` hook). The per-test TRUNCATE wipes `core.DocType`, so the
# seed runs in every example that needs it.
def rest_etag_seed_comment_doctype! : Nil
  with_db do |db|
    ensure_domain(db, "core")
    dir = File.join(__DIR__, "..", "..", "data", "seeds", "core.Comment")
    Facet::Doctype::DefinitionStore.cache.clear
    result = Facet::Document::Create.call(db, "core", "DocType", rest_etag_seed_definition_with_script(dir), Facet::RBAC::AuthContext.system)
    raise "sidecar doctype seed failed: #{result}" unless result.is_a?(Facet::Document::Create::Result)
  end
end

# Seeds an `etagrest.Note` host doctype declaring the `comments` sidecar
# (target reference column), plus the `etagrest` domain it lives in.
def rest_etag_seed_note_host! : Nil
  resp = create_domain_http("etagrest")
  assert_http_status(resp, 201)
  body = %({
    "doctype": "Note",
    "domain": "etagrest",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": { "name": { "type": "string" } },
    "sidecars": { "comments": { "doctype": "core.Comment", "column": "target" } }
  })
  assert_http_status(create_doctype_http(body), 201)
end

def rest_etag_create_note!(name : String) : String
  create_doc_id_http("etagrest", "Note", %({"name": #{name.to_json}}))
end

# An authenticated context whose role holds no permissions at all — every
# gate denies, so the request must surface the non-disclosing 404.
def rest_etag_no_access_ctx : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "rest_etag_no_access",
    visible_tags: Set{"default"},
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated("01RESTETAGNOACCESS", role)
end

# ── Tests ────────────────────────────────────────────────────────────────

describe "HTTP ETag — nested child single reads" do
  before_each do
    rest_etag_seed_customer_contact!
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "emits an ETag header on 200, equal to the mutation ULID" do
    customer_id = rest_etag_create_customer!("EtagCust1")
    contact_id = rest_etag_create_contact!(customer_id, "EtagContact1")

    resp = read_nested_http("etagrest", "Customer", customer_id, "contacts", contact_id)
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    etag.as(String).starts_with?('"').should be_true

    body = JSON.parse(resp.body)
    quoted = "\"#{body["meta"]["mid"].as_s}\""
    etag.should eq(quoted)
  end

  it "returns 304 on matching If-None-Match (empty body, ETag re-emitted)" do
    customer_id = rest_etag_create_customer!("EtagCust2")
    contact_id = rest_etag_create_contact!(customer_id, "EtagContact2")

    first = read_nested_http("etagrest", "Customer", customer_id, "contacts", contact_id)
    etag = first.headers["ETag"]

    second = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts/#{contact_id}", {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
    second.headers["X-Document-Migrated"]?.should_not be_nil
  end

  it "returns 200 with body on a stale If-None-Match" do
    customer_id = rest_etag_create_customer!("EtagCust3")
    contact_id = rest_etag_create_contact!(customer_id, "EtagContact3")

    resp = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts/#{contact_id}", {"If-None-Match" => "\"stale-value\""})
    assert_http_status(resp, 200)
    resp.body.size.should be > 0
  end

  it "changes the ETag after a nested PATCH" do
    customer_id = rest_etag_create_customer!("EtagCust4")
    contact_id = rest_etag_create_contact!(customer_id, "EtagContact4")

    before = read_nested_http("etagrest", "Customer", customer_id, "contacts", contact_id)
    etag_before = before.headers["ETag"]

    patched = rest_etag_patch_nested("etagrest", "Customer", customer_id, "contacts", contact_id, %({"name": "EtagContact4Patched"}))
    assert_http_status(patched, 200)

    after = read_nested_http("etagrest", "Customer", customer_id, "contacts", contact_id)
    assert_http_status(after, 200)
    after.headers["ETag"].should_not eq(etag_before)
  end

  it "accepts a weak validator (W/ prefix) from the client" do
    customer_id = rest_etag_create_customer!("EtagCust5")
    contact_id = rest_etag_create_contact!(customer_id, "EtagContact5")

    first = read_nested_http("etagrest", "Customer", customer_id, "contacts", contact_id)
    raw = first.headers["ETag"].gsub(/^"|"$/, "")
    weak = "W/\"#{raw}\""

    second = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts/#{contact_id}", {"If-None-Match" => weak})
    assert_http_status(second, 304)
  end
end

describe "HTTP ETag — nested child collection reads" do
  before_each do
    rest_etag_seed_customer_contact!
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "emits a three-part ETag header on 200" do
    customer_id = rest_etag_create_customer!("EtagListCust1")
    rest_etag_create_contact!(customer_id, "EtagListContact1")

    resp = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    # `<role>:<request_digest>:<version_tag>` — three colon-separated parts.
    etag.as(String).gsub(/^"|"$/, "").split(':').size.should be >= 3
  end

  it "returns 304 on matching If-None-Match (empty body, ETag re-emitted)" do
    customer_id = rest_etag_create_customer!("EtagListCust2")
    rest_etag_create_contact!(customer_id, "EtagListContact2")

    first = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    etag = first.headers["ETag"]

    second = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts", {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "returns 304 for an empty child collection" do
    customer_id = rest_etag_create_customer!("EtagListCustEmpty")

    first = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    second = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts", {"If-None-Match" => etag})
    assert_http_status(second, 304)
  end

  it "bumps the ETag when a child is created" do
    customer_id = rest_etag_create_customer!("EtagListCust3")
    rest_etag_create_contact!(customer_id, "EtagListContact3a")

    first = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    etag_before = first.headers["ETag"]

    rest_etag_create_contact!(customer_id, "EtagListContact3b")
    second = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "bumps the ETag when a child is updated" do
    customer_id = rest_etag_create_customer!("EtagListCust4")
    contact_id = rest_etag_create_contact!(customer_id, "EtagListContact4")

    first = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    etag_before = first.headers["ETag"]

    assert_http_status(rest_etag_patch_nested("etagrest", "Customer", customer_id, "contacts", contact_id, %({"name": "patched"})), 200)
    second = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "bumps the ETag when a child is soft-deleted (tombstone keeps parent_id)" do
    customer_id = rest_etag_create_customer!("EtagListCust5")
    contact_id = rest_etag_create_contact!(customer_id, "EtagListContact5")

    first = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    etag_before = first.headers["ETag"]

    assert_http_status(rest_etag_delete_nested("etagrest", "Customer", customer_id, "contacts", contact_id), 204)
    second = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "does not serve parent A's ETag for parent B's list of the same child doctype" do
    customer_a = rest_etag_create_customer!("EtagListCustA")
    customer_b = rest_etag_create_customer!("EtagListCustB")
    rest_etag_create_contact!(customer_a, "EtagContactA")
    rest_etag_create_contact!(customer_b, "EtagContactB")

    etag_a = list_nested_http("etagrest", "Customer", customer_a, "contacts").headers["ETag"]

    resp_b = rest_etag_get("/Api/etagrest/Customer/#{customer_b}/contacts", {"If-None-Match" => etag_a})
    assert_http_status(resp_b, 200)
    resp_b.body.size.should be > 0
  end

  it "keeps aggregate=count distinct from the data list" do
    customer_id = rest_etag_create_customer!("EtagListCust6")
    rest_etag_create_contact!(customer_id, "EtagListContact6")

    data_resp = list_nested_http("etagrest", "Customer", customer_id, "contacts")
    assert_http_status(data_resp, 200)
    data_resp.headers["ETag"]?.should_not be_nil

    count_resp = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts?aggregate=count")
    assert_http_status(count_resp, 200)
    count_resp.headers["ETag"]?.should_not be_nil
    data_resp.headers["ETag"].should_not eq(count_resp.headers["ETag"])

    # The count ETag revalidates a count request but not a data request.
    again = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts?aggregate=count", {"If-None-Match" => count_resp.headers["ETag"]})
    assert_http_status(again, 304)
    cross = rest_etag_get("/Api/etagrest/Customer/#{customer_id}/contacts", {"If-None-Match" => count_resp.headers["ETag"]})
    assert_http_status(cross, 200)
  end
end

describe "HTTP ETag — sidecar collection reads" do
  before_each do
    rest_etag_seed_comment_doctype!
    rest_etag_seed_note_host!
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "emits a three-part ETag header on 200" do
    note_id = rest_etag_create_note!("EtagNote1")
    create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "hi"}))

    resp = list_nested_http("etagrest", "Note", note_id, "comments")
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    etag.as(String).gsub(/^"|"$/, "").split(':').size.should be >= 3
  end

  it "returns 304 on matching If-None-Match (empty body, ETag re-emitted)" do
    note_id = rest_etag_create_note!("EtagNote2")
    create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "hi"}))

    first = list_nested_http("etagrest", "Note", note_id, "comments")
    etag = first.headers["ETag"]

    second = rest_etag_get("/Api/etagrest/Note/#{note_id}/comments", {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "bumps the ETag when a sidecar is created" do
    note_id = rest_etag_create_note!("EtagNote3")
    create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "first"}))

    first = list_nested_http("etagrest", "Note", note_id, "comments")
    etag_before = first.headers["ETag"]

    create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "second"}))
    second = list_nested_http("etagrest", "Note", note_id, "comments")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "bumps the ETag when a sidecar is updated" do
    note_id = rest_etag_create_note!("EtagNote4")
    comment_id = create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "before"}))

    first = list_nested_http("etagrest", "Note", note_id, "comments")
    etag_before = first.headers["ETag"]

    assert_http_status(patch_document_http("core", "Comment", comment_id, %({"body": "after"})), 200)
    second = list_nested_http("etagrest", "Note", note_id, "comments")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "bumps the ETag when a sidecar is soft-deleted (tombstone union)" do
    note_id = rest_etag_create_note!("EtagNote5")
    comment_id = create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "doomed"}))

    first = list_nested_http("etagrest", "Note", note_id, "comments")
    etag_before = first.headers["ETag"]

    assert_http_status(delete_document_http("core", "Comment", comment_id), 204)
    second = list_nested_http("etagrest", "Note", note_id, "comments")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "does not serve host A's ETag for host B's sidecar list" do
    note_a = rest_etag_create_note!("EtagNoteA")
    note_b = rest_etag_create_note!("EtagNoteB")
    create_child_doc_id_http("etagrest", "Note", note_a, "comments", %({"body": "on A"}))
    create_child_doc_id_http("etagrest", "Note", note_b, "comments", %({"body": "on B"}))

    etag_a = list_nested_http("etagrest", "Note", note_a, "comments").headers["ETag"]

    resp_b = rest_etag_get("/Api/etagrest/Note/#{note_b}/comments", {"If-None-Match" => etag_a})
    assert_http_status(resp_b, 200)
    resp_b.body.size.should be > 0
  end

  it "serves the class-level 403 — never a 304 — to a caller without access" do
    note_id = rest_etag_create_note!("EtagNote6")
    create_child_doc_id_http("etagrest", "Note", note_id, "comments", %({"body": "hi"}))

    first = list_nested_http("etagrest", "Note", note_id, "comments")
    assert_http_status(first, 200)

    # A permissionless caller must hit the authorization gates before any
    # cache short-circuit — `If-None-Match: *` must not buy a 304. No read
    # permission on the host doctype at all answers the class-level 403.
    Fiber.current.auth_context = rest_etag_no_access_ctx
    denied = rest_etag_get("/Api/etagrest/Note/#{note_id}/comments", {"If-None-Match" => "*"})
    assert_http_status(denied, 403)
  end
end
