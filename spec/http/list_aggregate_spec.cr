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

# Seeds the doctype used by the count specs. Reuses `identity.Person` so the
# shape is identical to the ETag collection spec (same.Column) — this keeps
# the test surface area small while still exercising a real projection row.
def seed_count_doctype : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(defn)
  end
end

private def create_person(full_name : String, email : String) : String
  create_doc_id_http("identity", "Person", %({"full_name": "#{full_name}", "email": "#{email}", "date_of_birth": "1990-01-01"}))
end

describe "HTTP aggregate=count" do
  before_each { seed_count_doctype }

  it "returns an empty data array with the capped total" do
    create_person("Count One", "count-1@test.com")
    create_person("Count Two", "count-2@test.com")

    resp = list_documents_http("identity", "Person", "aggregate=count")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.should be_empty
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end

  it "respects filters the same as a normal list" do
    create_person("Filter Match", "filter-1@test.com")
    create_person("Filter Skip", "filter-2@test.com")

    resp = list_documents_http("identity", "Person", "aggregate=count&filters[full_name__match]=Match")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.should be_empty
    body["meta"]["count"].as_i.should eq(1)
  end

  it "returns 422 for an unknown aggregate value" do
    resp = list_documents_http("identity", "Person", "aggregate=median")
    assert_http_status(resp, 422)
    body = parse_body(resp)
    body["error"].as_s.should contain("Unknown aggregate")
  end

  # The two requests below use the same filters and would otherwise share an
  # ETag. The `aggregate` parameter is part of the request fingerprint, so a
  # count request and a data request never alias.
  it "uses a distinct ETag from a non-aggregate list with the same filters" do
    create_person("Etag Count Distinct", "etag-count-1@test.com")

    data_resp = list_documents_http("identity", "Person")
    assert_http_status(data_resp, 200)
    data_resp.headers["ETag"]?.should_not be_nil

    count_resp = list_documents_http("identity", "Person", "aggregate=count")
    assert_http_status(count_resp, 200)
    count_resp.headers["ETag"]?.should_not be_nil

    data_resp.headers["ETag"].should_not eq(count_resp.headers["ETag"])
  end

  it "serves 304 on a count request re-validated with the count ETag" do
    create_person("Etag Count 304", "etag-count-2@test.com")
    first = list_documents_http("identity", "Person", "aggregate=count")
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    second = get_with_headers("/Api/identity/Person?aggregate=count", {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "does NOT serve 304 when a count ETag is presented for a data request" do
    create_person("Etag Count Cross", "etag-count-3@test.com")
    count_resp = list_documents_http("identity", "Person", "aggregate=count")
    assert_http_status(count_resp, 200)
    count_etag = count_resp.headers["ETag"]

    # Send the count request's ETag against a non-aggregate data request.
    # This must NOT 304, because the data request has a different fingerprint
    # (`aggregate` is part of the digest).
    data_resp = get_with_headers("/Api/identity/Person", {"If-None-Match" => count_etag})
    assert_http_status(data_resp, 200)
    data_resp.body.size.should be > 0
  end
end

describe "HTTP list pagination count/more" do
  before_each { seed_count_doctype }

  it "reports the real count and more=false when the set fits under the cap" do
    create_person("Page One", "page-more-1@test.com")
    create_person("Page Two", "page-more-2@test.com")
    create_person("Page Three", "page-more-3@test.com")

    resp = list_documents_http("identity", "Person", "items=2")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(2)
    body["meta"]["count"].as_i.should eq(3)
    body["meta"]["more"].as_bool.should be_false
  end

  it "reports the offset-relative count on the last page" do
    create_person("Page One", "page-last-1@test.com")
    create_person("Page Two", "page-last-2@test.com")
    create_person("Page Three", "page-last-3@test.com")

    resp = list_documents_http("identity", "Person", "items=2&page=2")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(1)
    body["meta"]["count"].as_i.should eq(1)
    body["meta"]["more"].as_bool.should be_false
  end

  it "sets more=false when the result set fits the page exactly" do
    create_person("Fit One", "page-fit-1@test.com")
    create_person("Fit Two", "page-fit-2@test.com")

    resp = list_documents_http("identity", "Person", "items=2")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(2)
    body["meta"]["count"].as_i.should eq(2)
    body["meta"]["more"].as_bool.should be_false
  end
end
