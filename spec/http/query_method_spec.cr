# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/domain/portable"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# HTTP contract of the QUERY method (RFC 10008) on the list surfaces.
#
# QUERY is a safe, cacheable GET whose parameters ride the body. The
# transport rules under test:
#
# - Body-only: query-string parameters are rejected with 422.
# - Empty body → list defaults (same as GET with no parameters).
# - A present body must be a JSON object (422) with a JSON media type
#   (415); Kemal rejects a body with no Content-Type at all (400).
# - Cache rules match GET: the collection ETag is transport-independent,
#   so the same parameters via GET-body and QUERY share one validator.
# - Unregistered QUERY paths answer 405 with `Allow`.
def seed_query_doctype : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(defn)
  end
end

private def create_person(full_name : String, email : String) : String
  create_doc_id_http("identity", "Person", %({"full_name": "#{full_name}", "email": "#{email}", "date_of_birth": "1990-01-01"}))
end

private def query_http(path : String, body : String? = nil, content_type : String? = "application/json", headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers.new
  h["Content-Type"] = content_type if content_type
  headers.each { |k, v| h[k] = v }
  request = HTTP::Request.new("QUERY", path, headers: h, body: body)
  call_api(request)
end

private def get_with_body(path : String, body : String, headers : Hash(String, String) = {} of String => String) : HTTP::Client::Response
  h = HTTP::Headers{"Content-Type" => "application/json"}
  headers.each { |k, v| h[k] = v }
  request = HTTP::Request.new("GET", path, headers: h, body: body)
  call_api(request)
end

describe "HTTP QUERY method — document collection list" do
  before_each { seed_query_doctype }

  it "filters with the JSON body" do
    create_person("Query Match", "query-match@test.com")
    create_person("Query Other", "query-other@test.com")

    resp = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Match"}}))
    assert_http_status(resp, 200)

    body = parse_body(resp)
    names = body["data"].as_a.map(&.["data"].["full_name"].as_s)
    names.should contain("Query Match")
    names.should_not contain("Query Other")
  end

  # B-100: a parseable body with a wrong `sort` / `select` shape is a
  # caller error — 422 through the parser's ServiceError, never a 500.
  it "answers 422 when sort is a string (B-100)" do
    resp = query_http("/Api/identity/Person", %({"sort": "full_name"}))
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("sort must be an array of strings")
  end

  it "answers 422 when select is a string (B-100)" do
    resp = query_http("/Api/identity/Person", %({"select": "full_name"}))
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("select must be an array of strings")
  end

  it "answers 200 with an array sort and keeps the default when sort is absent (B-100)" do
    create_person("Sort Array", "sort-array@test.com")
    query_http("/Api/identity/Person", %({"sort": ["full_name"]})).status_code.should eq(200)
    query_http("/Api/identity/Person", %({"page": 1})).status_code.should eq(200)
  end

  it "answers 422 when the GET body carries a string sort (B-100)" do
    resp = get_with_body("/Api/identity/Person", %({"sort": "full_name"}))
    assert_http_status(resp, 422)
  end

  # Enum set membership (`__in`): the filter bar's multi-select emits the
  # JSON-encoded array form on the query string, and the QUERY body carries
  # the array natively. The stored enum key is matched exactly.
  it "filters an enum field with a JSON-encoded __in array (enum in)" do
    create_doc_id_http("identity", "Person", %({"full_name": "In Internal", "email": "in-internal@test.com", "date_of_birth": "1990-01-01", "kind": "internal"}))
    create_doc_id_http("identity", "Person", %({"full_name": "In External", "email": "in-external@test.com", "date_of_birth": "1990-01-02", "kind": "external"}))

    payload = URI.encode_path(["internal"].to_json)
    resp = list_documents_http("identity", "Person", "filters[kind__in]=#{payload}")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    names = body["data"].as_a.map(&.["data"].["full_name"].as_s)
    names.should eq(["In Internal"])
  end

  it "filters an enum field with a native __in array on the QUERY body" do
    create_doc_id_http("identity", "Person", %({"full_name": "Query In A", "email": "query-in-a@test.com", "date_of_birth": "1990-01-03", "kind": "internal"}))
    create_doc_id_http("identity", "Person", %({"full_name": "Query In B", "email": "query-in-b@test.com", "date_of_birth": "1990-01-04", "kind": "external"}))
    create_doc_id_http("identity", "Person", %({"full_name": "Query In C", "email": "query-in-c@test.com", "date_of_birth": "1990-01-05", "kind": "external"}))

    resp = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Query In", "kind__in": ["internal"]}}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    names = body["data"].as_a.map(&.["data"].["full_name"].as_s)
    names.should eq(["Query In A"])
  end

  it "answers 422 for a scalar value on an enum __in" do
    resp = list_documents_http("identity", "Person", "filters[kind__in]=internal")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("kind__in")
  end

  it "uses defaults on an empty body" do
    create_person("Query Empty Body", "query-empty@test.com")

    resp = query_http("/Api/identity/Person", "")
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["meta"]["count"].raw.should be_a(Int64 | Int32)
    body["data"].as_a.size.should be >= 1
  end

  it "rejects query-string parameters with 422" do
    resp = query_http("/Api/identity/Person?page=2", %({"items": 10}))
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("query parameters")
  end

  it "rejects an invalid JSON body with 422" do
    resp = query_http("/Api/identity/Person", %({"page": ))
    assert_http_status(resp, 422)
  end

  it "rejects a non-object JSON body with 422" do
    resp = query_http("/Api/identity/Person", %([1, 2]))
    assert_http_status(resp, 422)
  end

  it "rejects a non-JSON content type with 415" do
    resp = query_http("/Api/identity/Person", %({"page": 1}), content_type: "text/plain")
    assert_http_status(resp, 415)
  end

  it "rejects a body without a Content-Type header with 400 (Kemal, RFC 10008)" do
    resp = query_http("/Api/identity/Person", %({"page": 1}), content_type: nil)
    assert_http_status(resp, 400)
    parse_body(resp)["error"].as_s.should contain("Content-Type")
  end

  it "accepts a structured JSON suffix media type" do
    create_person("Query Suffix CT", "query-suffix@test.com")

    resp = query_http("/Api/identity/Person", %({"filters": {"full_name__eq": "Query Suffix CT"}}), content_type: "application/vnd.facet.query+json")
    assert_http_status(resp, 200)
    parse_body(resp)["data"].as_a.size.should eq(1)
  end

  it "answers 405 with Allow on a path without a QUERY route" do
    doc_id = create_person("Query Wrong Path", "query-wrong@test.com")

    resp = query_http("/Api/identity/Person/#{doc_id}", %({"select": ["full_name"]}))
    assert_http_status(resp, 405)
    allow = resp.headers["Allow"]?
    allow.should_not be_nil
    allow.as(String).should contain("GET")
  end

  it "advertises the query format via Accept-Query on GET and QUERY" do
    resp_get = list_documents_http("identity", "Person")
    assert_http_status(resp_get, 200)
    resp_get.headers["Accept-Query"]?.should eq("application/json")

    resp_query = query_http("/Api/identity/Person", "")
    assert_http_status(resp_query, 200)
    resp_query.headers["Accept-Query"]?.should eq("application/json")
  end

  it "switches to the trash listing via the body flag" do
    doc_id = create_person("Query Trash", "query-trash@test.com")
    delete_document_http("identity", "Person", doc_id)

    live = query_http("/Api/identity/Person", "")
    assert_http_status(live, 200)
    parse_body(live)["data"].as_a.map(&.["meta"]["id"].as_s).should_not contain(doc_id)

    trash = query_http("/Api/identity/Person", %({"deleted": true}))
    assert_http_status(trash, 200)
    parse_body(trash)["data"].as_a.map(&.["meta"]["id"].as_s).should contain(doc_id)
  end

  it "keeps the GET body+query merge working (backward compatibility)" do
    create_person("Query Backcompat", "query-backcompat@test.com")

    resp = get_with_body("/Api/identity/Person?items=1", %({"filters": {"full_name__match": "Backcompat"}}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(1)
  end

  # The GET body rides the same shape gate as every body-consuming route
  # (B-59): before the gate, a non-object body escaped the parser as a 500
  # (run-24 finding B-80).
  it "answers 422 on a GET list body that is not a JSON object" do
    resp = get_with_body("/Api/identity/Person", "[1]")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should eq("Body must be a JSON object (got array)")

    resp = get_with_body("/Api/identity/Person", "=")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("Invalid JSON body")
  end

  # B-160: the read route parses its optional body through the same gate —
  # before it, a malformed body escaped as a 500 (a JSON string body) and a
  # non-object body was silently ignored (a JSON array answered 200).
  it "answers 422 on a read body that is not a JSON object (B-160)" do
    doc_id = create_person("Read Body Gate", "read-body-gate@test.com")

    resp = get_with_body("/Api/identity/Person/#{doc_id}", "hello")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should contain("Invalid JSON body")

    resp = get_with_body("/Api/identity/Person/#{doc_id}", "[1]")
    assert_http_status(resp, 422)
    parse_body(resp)["error"].as_s.should eq("Body must be a JSON object (got array)")
  end

  it "keeps the read body working when it is a valid JSON object (B-160)" do
    doc_id = create_person("Read Body Select", "read-body-select@test.com")

    resp = get_with_body("/Api/identity/Person/#{doc_id}", %({"select": ["full_name"]}))
    assert_http_status(resp, 200)
    body = parse_body(resp)["data"].as_h
    body["full_name"].as_s.should eq("Read Body Select")
    body["email"]?.should be_nil
  end
end

describe "HTTP QUERY method — cache rules match GET" do
  before_each { seed_query_doctype }

  it "shares the collection ETag with a GET body request of the same parameters" do
    create_person("Query Etag Share", "query-etag1@test.com")

    from_get = get_with_body("/Api/identity/Person", %({"filters": {"full_name__match": "Etag Share"}}))
    assert_http_status(from_get, 200)
    from_query = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Etag Share"}}))
    assert_http_status(from_query, 200)

    from_get.headers["ETag"].should eq(from_query.headers["ETag"])
  end

  it "serves 304 on a matching If-None-Match" do
    create_person("Query Etag 304", "query-etag2@test.com")

    first = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Etag 304"}}))
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    second = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Etag 304"}}), headers: {"If-None-Match" => etag})
    assert_http_status(second, 304)
    second.body.should eq("")
    second.headers["ETag"]?.should eq(etag)
  end

  it "does not serve 304 across different parameters" do
    create_person("Query Etag Distinct", "query-etag3@test.com")

    first = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "Etag Distinct"}}))
    assert_http_status(first, 200)

    other = query_http("/Api/identity/Person", %({"filters": {"full_name__match": "No Such Name"}}), headers: {"If-None-Match" => first.headers["ETag"]})
    assert_http_status(other, 200)
  end

  it "bumps the validator after a mutation" do
    doc_id = create_person("Query Etag Bump", "query-etag4@test.com")

    first = query_http("/Api/identity/Person", "")
    assert_http_status(first, 200)
    etag = first.headers["ETag"]

    patch_document_http("identity", "Person", doc_id, %({"full_name": "Query Etag Bump II"}))

    second = query_http("/Api/identity/Person", "", headers: {"If-None-Match" => etag})
    assert_http_status(second, 200)
    second.headers["ETag"].should_not eq(etag)
  end
end

describe "HTTP QUERY method — audit surfaces" do
  before_each do
    with_db do |db|
      ensure_domain(db, "identity")
      defn = load_doctype_schema("identity.Person/definition.yml")
      create_doctype(defn)
    end
  end

  it "lists the global audit log from the body" do
    create_person("Query Audit", "query-audit@test.com")

    resp = query_http("/Api/Audit", %({"items": 1}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.size.should eq(1)
    body["meta"]["count"].raw.should be_a(Int64 | Int32)
  end

  it "rejects query-string parameters on the global audit log" do
    resp = query_http("/Api/Audit?items=5", "")
    assert_http_status(resp, 422)
  end

  it "lists document history from the body" do
    doc_id = create_person("Query History", "query-history@test.com")

    resp = query_http("/Api/identity/Person/#{doc_id}/history", %({"items": 50}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.empty?.should be_false
    body["data"].as_a.first["action"].as_s.should eq("create")
  end

  it "reads the include=children flag from the history body" do
    with_db do |db|
      ensure_domain(db, "histq")
      parent = "QP#{unique_suffix}"
      child = "QC#{unique_suffix}"
      parent_defn = %({"doctype": "#{parent}", "domain": "histq", "aggregate_root": true, "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
      child_defn = %({"doctype": "#{child}", "domain": "histq", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)

      parent_res = Facet::Document::Create.call(db, "histq", parent, %({"name": "root"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result)
      Facet::Document::Create.call(
        db, "histq", child, %({"name": "kid"}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(parent_res.projection.id)},
      ).should be_a(Facet::Document::Create::Result)
    end

    parent_dt = ""
    parent_id = ""
    with_db do |db|
      parent_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histq' AND doc_type LIKE 'QP%' LIMIT 1", as: String)
      parent_id = db.query_one("SELECT id FROM projections WHERE domain = 'histq' AND doc_type LIKE 'QP%' AND deleted_at IS NULL LIMIT 1", as: String)
    end

    flat = query_http("/Api/histq/#{parent_dt}/#{parent_id}/history", %({}))
    assert_http_status(flat, 200)
    flat_count = parse_body(flat)["meta"]["count"].as_i

    merged = query_http("/Api/histq/#{parent_dt}/#{parent_id}/history", %({"include": "children"}))
    assert_http_status(merged, 200)
    merged_count = parse_body(merged)["meta"]["count"].as_i
    merged_count.should be > flat_count
  end

  it "ignores an unknown include value like GET does" do
    doc_id = create_person("Query Include Junk", "query-include-junk@test.com")

    resp = query_http("/Api/identity/Person/#{doc_id}/history", %({"include": "everything"}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.empty?.should be_false
    body["data"].as_a.first["doc_id"].as_s.should eq(doc_id)
  end

  it "lists child history from the body" do
    with_db do |db|
      ensure_domain(db, "histq2")
      parent = "QP#{unique_suffix}"
      child = "QC#{unique_suffix}"
      parent_defn = %({"doctype": "#{parent}", "domain": "histq2", "aggregate_root": true, "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
      child_defn = %({"doctype": "#{child}", "domain": "histq2", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)

      parent_res = Facet::Document::Create.call(db, "histq2", parent, %({"name": "root"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result)
      Facet::Document::Create.call(
        db, "histq2", child, %({"name": "kid"}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(parent_res.projection.id)},
      ).should be_a(Facet::Document::Create::Result)
    end

    parent_dt = ""
    parent_id = ""
    child_dt = ""
    child_id = ""
    with_db do |db|
      parent_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histq2' AND doc_type LIKE 'QP%' LIMIT 1", as: String)
      parent_id = db.query_one("SELECT id FROM projections WHERE domain = 'histq2' AND doc_type LIKE 'QP%' AND deleted_at IS NULL LIMIT 1", as: String)
      child_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histq2' AND doc_type LIKE 'QC%' LIMIT 1", as: String)
      child_id = db.query_one("SELECT id FROM projections WHERE domain = 'histq2' AND doc_type LIKE 'QC%' AND deleted_at IS NULL LIMIT 1", as: String)
    end

    resp = query_http("/Api/histq2/#{parent_dt}/#{parent_id}/items/#{child_id}/history", %({}))
    assert_http_status(resp, 200)
    body = parse_body(resp)
    body["data"].as_a.empty?.should be_false
    body["data"].as_a.first["doc_id"].as_s.should eq(child_id)
    # The nested `:child` segment is the relationship name (B-197); the
    # rows name the child doctype the relationship resolves to.
    body["data"].as_a.first["doc_type"].as_s.should eq(child_dt)
  end
end
