# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Performs a GET with arbitrary request headers — mirrors the helper in
# `etag_spec.cr` for `If-None-Match` revalidation.
private def get_with_headers(path : String, headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers.new
  headers.each { |k, v| h[k] = v }
  request = HTTP::Request.new("GET", path, headers: h)
  call_api(request)
end

# Seeds a doctype whose definition declares one named scope (`emea`) over a
# scalar field, plus an integer field for the aggregate case.
def seed_scope_doctype : Nil
  with_db do |db|
    ensure_domain(db, "scopetest")
  end
  body = %({
    "doctype": "Region",
    "domain": "scopetest",
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "region": {"type": "string"},
      "amount": {"type": "integer"}
    },
    "scopes": {
      "emea": {"description": "EMEA rows", "where": {"region": "emea"}}
    }
  })
  resp = create_doctype_http(body)
  assert_http_status(resp, 201)
end

private def create_region_doc(region : String, amount : Int32) : String
  create_doc_id_http("scopetest", "Region", %({"region": "#{region}", "amount": #{amount}}))
end

describe "HTTP scope parameter" do
  before_each { seed_scope_doctype }

  it "narrows the list to the scope's rows" do
    create_region_doc("emea", 10)
    create_region_doc("emea", 20)
    create_region_doc("apac", 40)

    resp = list_documents_http("scopetest", "Region", "scope=emea")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    rows = body["data"].as_a
    rows.size.should eq(2)
    rows.all? { |r| r["data"]["region"].as_s == "emea" }.should be_true
  end

  it "composes scope with a field aggregate" do
    create_region_doc("emea", 10)
    create_region_doc("emea", 20)
    create_region_doc("apac", 40)

    resp = list_documents_http("scopetest", "Region", "aggregate=sum&field=amount&scope=emea")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"]["value"].as_i.should eq(30)
    body["meta"]["count"].as_i.should eq(2)
  end

  it "answers 422 for an unknown scope name" do
    create_region_doc("emea", 10)

    resp = list_documents_http("scopetest", "Region", "scope=nope")
    assert_http_status(resp, 422)
    body = parse_body(resp)
    body["error"].as_s.should contain("Unknown scope")
  end

  it "keeps the unscoped list intact when scope is absent" do
    create_region_doc("emea", 10)
    create_region_doc("apac", 40)

    resp = list_documents_http("scopetest", "Region")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(2)
  end

  it "uses a distinct ETag for a scoped request" do
    create_region_doc("emea", 10)
    create_region_doc("apac", 40)

    unscoped = list_documents_http("scopetest", "Region")
    assert_http_status(unscoped, 200)
    scoped = list_documents_http("scopetest", "Region", "scope=emea")
    assert_http_status(scoped, 200)
    unscoped.headers["ETag"]?.should_not be_nil
    unscoped.headers["ETag"].should_not eq(scoped.headers["ETag"])

    # A scoped request revalidated with its own ETag hits; revalidated with
    # the unscoped ETag it must not (the scoped result is a strict subset).
    etag = scoped.headers["ETag"]
    hit = get_with_headers("/Api/scopetest/Region?scope=emea", {"If-None-Match" => etag})
    assert_http_status(hit, 304)
    miss = get_with_headers("/Api/scopetest/Region?scope=emea", {"If-None-Match" => unscoped.headers["ETag"]})
    assert_http_status(miss, 200)
    miss.body.size.should be > 0
  end

  it "accepts scope through the QUERY body" do
    create_region_doc("emea", 10)
    create_region_doc("apac", 40)

    request = HTTP::Request.new("QUERY", "/Api/scopetest/Region",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"scope": "emea"}))
    resp = call_api(request)
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(1)
  end
end
