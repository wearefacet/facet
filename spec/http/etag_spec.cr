# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/doctype"
require "../../src/mutation/client"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Seeds the doctypes used by the ETag specs — mirrors `server_spec.cr`'s helper
# but kept local so this file is self-contained.
def seed_etag_doctypes : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(defn)
  end
end

# Performs a GET with optional request headers (used to send `If-None-Match`).
private def get_with_headers(path : String, headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  request = HTTP::Request.new("GET", path, headers: h)
  call_api(request)
end

# Creates a Person via HTTP and returns its meta.id.
def create_person_id(full_name : String, email : String) : String
  create_doc_id_http("identity", "Person", %({"full_name": "#{full_name}", "email": "#{email}", "date_of_birth": "1990-01-01"}))
end

describe "HTTP ETag — single-document reads" do
  before_each { seed_etag_doctypes }

  it "emits an ETag header on 200" do
    doc_id = create_person_id("EtagOne", "etag-one@test.com")
    resp = get_document_http("identity", "Person", doc_id)
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    etag.as(String).starts_with?('"').should be_true

    # The ETag value must equal the body's `meta.mid` (the projection state).
    body = JSON.parse(resp.body)
    quoted = "\"#{body["meta"]["mid"].as_s}\""
    etag.should eq(quoted)
  end

  it "returns 304 on matching If-None-Match" do
    doc_id = create_person_id("EtagTwo", "etag-two@test.com")
    first = get_document_http("identity", "Person", doc_id)
    etag = first.headers["ETag"]

    second = get_with_headers("/Api/identity/Person/#{doc_id}", {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    # 304 still re-emits the ETag so clients see the validator that produced it.
    second.headers["ETag"]?.should eq(etag)
  end

  it "returns 200 with body on non-matching If-None-Match" do
    doc_id = create_person_id("EtagThree", "etag-three@test.com")
    resp = get_with_headers("/Api/identity/Person/#{doc_id}", {"If-None-Match" => "\"stale-value\""})
    assert_http_status(resp, 200)
    resp.body.size.should be > 0
  end

  it "returns 304 on If-None-Match: *" do
    doc_id = create_person_id("EtagFour", "etag-four@test.com")
    resp = get_with_headers("/Api/identity/Person/#{doc_id}", {"If-None-Match" => "*"})
    assert_http_status(resp, 304)
  end

  it "changes the ETag after a mutation (PATCH)" do
    doc_id = create_person_id("EtagFive", "etag-five@test.com")
    before = get_document_http("identity", "Person", doc_id)
    etag_before = before.headers["ETag"]

    patch_document_http("identity", "Person", doc_id, %({"full_name": "EtagFivePatched"}))

    after = get_document_http("identity", "Person", doc_id)
    assert_http_status(after, 200)
    after.headers["ETag"].should_not eq(etag_before)
  end

  it "accepts a weak validator (W/ prefix) from the client" do
    doc_id = create_person_id("EtagSix", "etag-six@test.com")
    first = get_document_http("identity", "Person", doc_id)
    # Pull the unquoted validator and re-serialize as a weak ETag.
    raw = first.headers["ETag"].gsub(/^"|"$/, "")
    weak = "W/\"#{raw}\""

    second = get_with_headers("/Api/identity/Person/#{doc_id}", {"If-None-Match" => weak})
    assert_http_status(second, 304)
  end
end

# ── Write responses ────────────────────────────────────────────────────
#
# A write produces a new projection `state`, so the write response must
# carry the fresh validator. The header matches the `meta.mid` in the
# body and the ETag the next GET returns.

# Seeds `identity.EtagOrder` — an aggregate root with an `items` child and
# one `touch` action. One doctype exercises every document write branch of
# `write_result` over the API: flat create, compound create, PATCH, action.
private def seed_etag_write_doctypes : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    Facet::Doctype::DefinitionStore.cache.clear
    script = <<-LUA
      local export = {}
      function export.create(ctx) end
      function export.touch(ctx, args)
        ctx.root.note = args.note
      end
      return export
    LUA
    parent = %({"doctype": "EtagOrder", "domain": "identity", "aggregate_root": true, "search": "{{ display_name }}",
                "fields": {"name": {"type": "string"}, "note": {"type": "string"}},
                "children": {"items": {"doctype": "EtagItem", "collection": true}},
                "actions": {"touch": {"args": {"note": {"type": "string", "required": true}}}},
                "script": #{script.to_json}})
    result = Facet::Document::Create.call(db, "core", "DocType", parent, Facet::RBAC::AuthContext.system)
    result.should be_a(Facet::Document::Create::Result)
    child = %({"doctype": "EtagItem", "domain": "identity", "aggregate_root": false, "member_of": "EtagOrder",
               "fields": {"label": {"type": "string"}}})
    result = Facet::Document::Create.call(db, "core", "DocType", child, Facet::RBAC::AuthContext.system)
    result.should be_a(Facet::Document::Create::Result)
  end
end

describe "HTTP ETag — write responses" do
  before_each do
    seed_etag_write_doctypes
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system
  end

  it "carries an ETag on a create response, equal to meta.mid" do
    resp = create_document_http("identity", "EtagOrder", %({"name": "Order1"}))
    assert_http_status(resp, 201)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    body = JSON.parse(resp.body)
    etag.should eq("\"#{body["meta"]["mid"].as_s}\"")
  end

  it "carries an ETag on a compound create response, equal to meta.mid" do
    body = %({"$content": {"name": "Order2"}, "$children": {"items": [{"label": "A"}]}})
    resp = create_document_http("identity", "EtagOrder", body)
    assert_http_status(resp, 201)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    parsed = JSON.parse(resp.body)
    etag.should eq("\"#{parsed["meta"]["mid"].as_s}\"")
  end

  it "carries an ETag on a PATCH response, equal to meta.mid and the next GET's validator" do
    doc_id = create_doc_id_http("identity", "EtagOrder", %({"name": "Order3"}))

    patched = patch_document_http("identity", "EtagOrder", doc_id, %({"name": "Order3Patched"}))
    assert_http_status(patched, 200)
    etag = patched.headers["ETag"]?
    etag.should_not be_nil
    body = JSON.parse(patched.body)
    etag.should eq("\"#{body["meta"]["mid"].as_s}\"")

    after = get_document_http("identity", "EtagOrder", doc_id)
    assert_http_status(after, 200)
    after.headers["ETag"].should eq(etag)
  end

  it "carries an ETag on an action response, equal to meta.mid and the next GET's validator" do
    doc_id = create_doc_id_http("identity", "EtagOrder", %({"name": "Order4"}))

    resp = execute_action_http("identity", "EtagOrder", doc_id, "touch", %({"note": "touched"}))
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    body = JSON.parse(resp.body)
    etag.should eq("\"#{body["meta"]["mid"].as_s}\"")

    after = get_document_http("identity", "EtagOrder", doc_id)
    assert_http_status(after, 200)
    after.headers["ETag"].should eq(etag)
  end

  it "carries an ETag on a doctype PUT response, equal to mid and the next GET's validator" do
    with_db do |db|
      ensure_domain(db, "identity")
      # The flat document routes resolve the container doctype definition;
      # this spec's other examples never touch core.DocType, so the suite's
      # baseline does not guarantee it is seeded here.
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")
    end
    body = %({"doctype": "EtagDef", "domain": "identity", "schema_version": 1,
              "aggregate_root": true, "search": "{{ display_name }}",
              "fields": {"name": {"type": "string"}}})
    created = create_doctype_http(body)
    assert_http_status(created, 201)
    doctype_id = JSON.parse(created.body)["meta"]["id"].as_s

    updated = call_api(HTTP::Request.new("PUT", "/Api/core/DocType/#{doctype_id}", body: %({"doctype": "EtagDef", "domain": "identity", "schema_version": 1,
              "aggregate_root": true, "search": "{{ display_name }}",
              "fields": {"name": {"type": "string"}, "note": {"type": "string"}}})))
    assert_http_status(updated, 200)
    etag = updated.headers["ETag"]?
    etag.should_not be_nil
    etag.should eq("\"#{JSON.parse(updated.body)["mid"].as_s}\"")

    after = get_document_http("core", "DocType", doctype_id)
    assert_http_status(after, 200)
    after.headers["ETag"].should eq(etag)
  end
end

describe "HTTP ETag — collection reads" do
  before_each { seed_etag_doctypes }

  it "emits an ETag header on 200" do
    create_person_id("ListEtag1", "list-etag-1@test.com")
    create_person_id("ListEtag2", "list-etag-2@test.com")

    resp = list_documents_http("identity", "Person")
    assert_http_status(resp, 200)
    etag = resp.headers["ETag"]?
    etag.should_not be_nil
    # Collection ETag is `<role>:<request_digest>:<version_tag>` — three colon-separated parts.
    etag.as(String).gsub(/^"|"$/, "").split(':').size.should be >= 3
  end

  it "returns 304 on matching If-None-Match (skips body)" do
    create_person_id("ListEtag3", "list-etag-3@test.com")
    first = list_documents_http("identity", "Person")
    etag = first.headers["ETag"]

    second = list_with_if_none_match("identity", "Person", etag)
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "returns 304 on If-None-Match: *" do
    create_person_id("ListEtag4", "list-etag-4@test.com")
    resp = get_with_headers("/Api/identity/Person", {"If-None-Match" => "*"})
    assert_http_status(resp, 304)
  end

  it "changes the ETag after a document is created" do
    create_person_id("ListEtag5", "list-etag-5@test.com")
    first = list_documents_http("identity", "Person")
    etag_before = first.headers["ETag"]

    create_person_id("ListEtag6", "list-etag-6@test.com")
    second = list_documents_http("identity", "Person")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "changes the ETag after a document is updated" do
    doc_id = create_person_id("ListEtag7", "list-etag-7@test.com")
    first = list_documents_http("identity", "Person")
    etag_before = first.headers["ETag"]

    patch_document_http("identity", "Person", doc_id, %({"full_name": "ListEtag7Patched"}))
    second = list_documents_http("identity", "Person")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "changes the ETag after a document is soft-deleted (tombstone path)" do
    doc_id = create_person_id("ListEtag8", "list-etag-8@test.com")
    first = list_documents_http("identity", "Person")
    etag_before = first.headers["ETag"]

    delete_document_http("identity", "Person", doc_id)
    second = list_documents_http("identity", "Person")
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag_before)
  end

  it "produces a different ETag for different page/items parameters" do
    create_person_id("ListEtag9a", "list-etag-9a@test.com")
    create_person_id("ListEtag9b", "list-etag-9b@test.com")

    page1 = list_documents_http("identity", "Person", "page=1&items=1")
    page2 = list_documents_http("identity", "Person", "page=2&items=1")
    assert_http_status(page1, 200)
    assert_http_status(page2, 200)
    page1.headers["ETag"].should_not eq(page2.headers["ETag"])
  end

  it "produces the same ETag for equivalent filter sets sent in different key orders" do
    create_person_id("ListEtag10a", "list-etag-10a@test.com")
    create_person_id("ListEtag10b", "list-etag-10b@test.com")

    # The inverted filter order is what we want to test — a stable request digest
    # must collapse both into the same ETag (the URL's query string preserves
    # the order it arrived in, so we exercise the same path twice with different
    # orders).
    resp_ab = list_documents_http("identity", "Person", "filters[full_name__match]=Etag10&sort=full_name")
    resp_ba = list_documents_http("identity", "Person", "sort=full_name&filters[full_name__match]=Etag10")
    assert_http_status(resp_ab, 200)
    assert_http_status(resp_ba, 200)
    resp_ab.headers["ETag"].should eq(resp_ba.headers["ETag"])
  end
end

describe "HTTP error responses — cache headers" do
  before_each { seed_etag_doctypes }

  # Browsers may store a 404/410 response without any explicit header
  # (RFC 9111 — both are cacheable by default), so every error response
  # must carry `Cache-Control: no-store` — a cached tombstone would
  # outlive the data behind it.
  it "sets Cache-Control: no-store on a tombstone 410 (read route)" do
    doc_id = create_person_id("CacheGone", "cache-gone@test.com")
    delete_document_http("identity", "Person", doc_id)

    resp = get_document_http("identity", "Person", doc_id)
    assert_http_status(resp, 410)
    resp.headers["Cache-Control"]?.should eq("no-store")
    resp.headers["X-Document-Deleted"]?.should eq("true")

    # The tombstone body carries the surviving label and deletion timestamp
    # so the UI renders the deleted reference by name instead of id.
    body = JSON.parse(resp.body)
    body["display_name"].as_s.should eq("CacheGone")
    body["deleted_at"].as_s.should_not be_nil
  end

  it "sets Cache-Control: no-store on a 404 (read route)" do
    resp = get_document_http("identity", "Person", "identity.Person.cache404")
    assert_http_status(resp, 404)
    resp.headers["Cache-Control"]?.should eq("no-store")
  end

  it "sets Cache-Control: no-store on an unmatched route" do
    # A path no route matches falls through to the JSON 404 handler; it
    # must not be cacheable either.
    resp = get_with_headers("/definitely-not-a-route")
    assert_http_status(resp, 404)
    resp.headers["Cache-Control"]?.should eq("no-store")
  end
end

describe "HTTP ETag — collection reads in preview mode" do
  # Regression: a preview principal reaching the collection list route used
  # to raise TypeCastError in `Caching.role_fingerprint` (cast to
  # `Principal::Real`). The fingerprint must cover the preview variant so
  # the list renders and the validator round-trips to a 304.
  it "serves a collection list to a preview principal and 304s on the same capability" do
    draft = seed_preview_etag_draft

    first = call_api_as(
      HTTP::Request.new("GET", "/Api/#{draft}/Widget"),
      Facet::RBAC::AuthContext.preview("account_preview", draft),
    )
    assert_http_status(first, 200)
    etag = first.headers["ETag"]?
    etag.should_not be_nil

    second = call_api_as(
      HTTP::Request.new("GET", "/Api/#{draft}/Widget", headers: HTTP::Headers{"If-None-Match" => etag.not_nil!}),
      Facet::RBAC::AuthContext.preview("account_preview", draft),
    )
    assert_http_status(second, 304)
    second.headers["ETag"]?.should eq(etag)
  end

  # The fingerprint exists so a body cached under one caller is never
  # 304-served to a different caller — two preview accounts bound to the
  # same draft must not share a validator either.
  it "does not serve a preview 304 to a different preview account" do
    draft = seed_preview_etag_draft

    first = call_api_as(
      HTTP::Request.new("GET", "/Api/#{draft}/Widget"),
      Facet::RBAC::AuthContext.preview("account_a", draft),
    )
    assert_http_status(first, 200)

    other = call_api_as(
      HTTP::Request.new("GET", "/Api/#{draft}/Widget", headers: HTTP::Headers{"If-None-Match" => first.headers["ETag"]}),
      Facet::RBAC::AuthContext.preview("account_b", draft),
    )
    assert_http_status(other, 200)
  end
end

# ── Internal helpers ─────────────────────────────────────────────────

def list_with_if_none_match(domain : String, doc_type : String, etag : String) : HTTP::Client::Response
  get_with_headers("/Api/#{domain}/#{doc_type}", {"If-None-Match" => etag})
end

# Seeds the core doctype definitions, an empty draft domain, a Widget
# doctype under the draft, and one Widget document. Returns the draft
# domain id — the value a preview-session token carries as
# `preview_domain`.
def seed_preview_etag_draft : String
  with_db do |db|
    restore_seeded_baseline(db)
  end
  draft = create_draft_via_api
  with_db do |db|
    # The draft's doctype definition is written directly via
    # `Mutation::Client` — the same pattern the draft-domain specs use,
    # because the draft domain's `_` prefix fails `Doctype::Create`'s
    # domain-name regex.
    Facet::Mutation::Client.create(
      db, "core", "DocType",
      doc_id: "#{draft}.Widget",
      content: %({"doctype": "Widget", "domain": "#{draft}", "schema_version": 1, "fields": {"name": {"type": "string"}}}),
      actioner_id: "system:test",
    )
    Facet::Doctype::DefinitionStore.invalidate("#{draft}.Widget")
  end
  create_doc_id_http(draft, "Widget", %({"name": "w1"}))
  draft
end
