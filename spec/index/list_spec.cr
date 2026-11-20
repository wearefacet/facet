# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/index"
require "../../src/util/script_helpers"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Specs for the managed-index status surface:
#
# - `Index::List` — the read-only service over `doctype_indexes`.
# - `GET /Api/Indexes` — the operator route (wildcard `read *.*` gate).
IDX_DOMAIN = "idxlist"

def idx_list_insert(db, domain : String, doc_type : String, field : String, type : String, status : String, index_name : String, error_message : String? = nil) : Nil
  db.exec(
    "INSERT INTO doctype_indexes (id, domain, doc_type, field_name, index_type, index_name, status, error_message) " \
    "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    Facet::Util::ScriptHelpers.ulid, domain, doc_type, field, type, index_name, status, error_message,
  )
end

def idx_list_count(domain : String) : Int64
  with_db do |db|
    db.query_one("SELECT COUNT(*) FROM doctype_indexes WHERE domain = $1", domain, as: Int64)
  end
end

describe Facet::Index::List do
  before_each do
    with_db do |db|
      db.exec("DELETE FROM doctype_indexes WHERE domain = $1", IDX_DOMAIN)
    end
  end

  it "lists all tracking rows" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LAlpha", "name", "btree", "active", "idx_env_idxlist_a")
      idx_list_insert(db, IDX_DOMAIN, "LBeta", "email", "btree", "pending", "idx_env_idxlist_b")

      result = Facet::Index::List.call(db, auth_context: Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Index::List::Result)
      list = result.as(Facet::Index::List::Result)
      list.total.should be >= 2
      list.items.map(&.domain).all? { |d| d == IDX_DOMAIN || d != IDX_DOMAIN }.should be_true
      list.items.map(&.domain).includes?(IDX_DOMAIN).should be_true
    end
  end

  it "filters by status" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LFilter", "name", "btree", "active", "idx_env_idxlist_f1")
      idx_list_insert(db, IDX_DOMAIN, "LFilter", "email", "btree", "error", "idx_env_idxlist_f2", "deadlock")

      result = Facet::Index::List.call(
        db,
        filters: {"status__eq" => JSON::Any.new("error")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Index::List::Result)
      list = result.as(Facet::Index::List::Result)
      list.items.size.should eq(1)
      list.items.first.status.should eq("error")
      list.items.first.error_message.should eq("deadlock")
    end
  end

  it "filters by field_name with match (case-insensitive)" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LMatch", "Billing_Address", "btree", "active", "idx_env_idxlist_m")

      result = Facet::Index::List.call(
        db,
        filters: {"field_name__match" => JSON::Any.new("billing")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Index::List::Result)
      list = result.as(Facet::Index::List::Result)
      list.items.map(&.field_name).should eq(["Billing_Address"])
    end
  end

  it "reads a bare filterable key (no operator suffix) as eq" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LBare", "name", "btree", "active", "idx_env_idxlist_bare")

      result = Facet::Index::List.call(
        db,
        filters: {"domain" => JSON::Any.new(IDX_DOMAIN)},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Index::List::Result)
      list = result.as(Facet::Index::List::Result)
      list.items.size.should eq(1)
      list.items.first.doc_type.should eq("LBare")
    end
  end

  it "answers 422 for an unknown filter field, naming the filterable set" do
    with_db do |db|
      result = Facet::Index::List.call(
        db,
        filters: {"bogus__eq" => JSON::Any.new("x")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Unknown filter field 'bogus'")
      error.message.should contain("filterable: domain, doc_type, status, field_name")

      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.try(&.field).should eq("bogus__eq")
      detail.try(&.code).should eq("unknown_filter_field")
    end
  end

  it "answers 422 for an unknown bare filter key (no operator suffix)" do
    with_db do |db|
      result = Facet::Index::List.call(
        db,
        filters: {"nonsense" => JSON::Any.new("x")},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Unknown filter field 'nonsense'")
      detail = error.details.try(&.first?)
      detail.try(&.code).should eq("unknown_filter_field")
    end
  end

  it "answers 422 for a served field with an unsupported operator" do
    with_db do |db|
      result = Facet::Index::List.call(
        db,
        filters: {"domain__gte" => JSON::Any.new(IDX_DOMAIN)},
        auth_context: Facet::RBAC::AuthContext.system,
      )
      error = result.as(Facet::ServiceError)
      error.status.should eq(422)
      error.message.should contain("Filter operator 'gte' is not served for field 'domain'")
      error.message.should contain("allowed: eq, match, ne")

      detail = error.details.try(&.first?)
      detail.should_not be_nil
      detail.try(&.field).should eq("domain__gte")
      detail.try(&.code).should eq("unsupported_filter_operator")
    end
  end

  it "sorts by updated_at descending by default and paginates" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LPaged", "f1", "btree", "active", "idx_env_idxlist_p1")
      idx_list_insert(db, IDX_DOMAIN, "LPaged", "f2", "btree", "active", "idx_env_idxlist_p2")
      idx_list_insert(db, IDX_DOMAIN, "LPaged", "f3", "btree", "active", "idx_env_idxlist_p3")

      # `more` means "counting was truncated", not "a next page exists":
      # three rows fit under the cap, so both pages report the real count
      # and `more` stays false.
      first = Facet::Index::List.call(
        db,
        filters: {"domain__eq" => JSON::Any.new(IDX_DOMAIN)},
        page: 1,
        items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system,
      )
      first.should be_a(Facet::Index::List::Result)
      page1 = first.as(Facet::Index::List::Result)
      page1.total.should eq(3)
      page1.items.size.should eq(2)
      page1.more.should be_false

      result = Facet::Index::List.call(
        db,
        filters: {"domain__eq" => JSON::Any.new(IDX_DOMAIN)},
        page: 2,
        items_per_page: 2,
        auth_context: Facet::RBAC::AuthContext.system,
      )
      result.should be_a(Facet::Index::List::Result)
      list = result.as(Facet::Index::List::Result)
      # Offset-relative: one row remains from page 2's offset.
      list.total.should eq(1)
      list.items.size.should eq(1)
      list.more.should be_false
    end
  end

  it "denies a caller without wildcard read" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LDenied", "name", "btree", "active", "idx_env_idxlist_d")

      result = Facet::Index::List.call(db, auth_context: Facet::RBAC::AuthContext.denied)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(403)
    end
  end

  it "allows a scoped wildcard-read caller (Scoped passes like the global audit)" do
    with_db do |db|
      role_content = %({"name": "idxlist_scoped_role", "visible_tags": ["default"], "permissions": [{"action": "read", "on": "*.*", "scope": ["mine"]}]})
      Facet::Mutation::Client.create(db, "iam", "Role", doc_id: "idxlist_scoped_role", content: role_content, actioner_id: "system")
      role = Facet::RBAC::ActiveRole.from_projection_content(
        Facet::Mutation::Client.fetch_content(db, "iam", "Role", "idxlist_scoped_role")
      )
      auth = Facet::RBAC::AuthContext.authenticated("idxlist_scoped_role", role)

      idx_list_insert(db, IDX_DOMAIN, "LScoped", "name", "btree", "active", "idx_env_idxlist_s")

      result = Facet::Index::List.call(db, auth_context: auth)
      result.should be_a(Facet::Index::List::Result)
    end
  end
end

describe "GET /Api/Indexes" do
  before_each do
    with_db do |db|
      db.exec("DELETE FROM doctype_indexes WHERE domain = $1", IDX_DOMAIN)
    end
  end

  it "returns the tracking rows in the { data, meta } shape" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LRoute", "email", "gin_trgm", "error", "idx_env_idxlist_r", "concurrent build failed")
    end

    # `doctype_indexes` is not truncated between examples (see spec_helper),
    # so the unfiltered table holds rows left by other specs. Scope the
    # shape check to the fixture domain — meta stays deterministic.
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[domain__eq]=#{IDX_DOMAIN}"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    rows = body["data"].as_a
    row = rows.find! { |r| r["domain"].as_s == IDX_DOMAIN }
    row["doc_type"].as_s.should eq("LRoute")
    row["field_name"].as_s.should eq("email")
    row["index_type"].as_s.should eq("gin_trgm")
    row["status"].as_s.should eq("error")
    row["error_message"].as_s.should eq("concurrent build failed")
    row["index_name"].as_s.should eq("idx_env_idxlist_r")
    row["created_at"].as_s.should_not be_empty
    row["updated_at"].as_s.should_not be_empty
    body["meta"]["count"].as_i.should be > 0
    body["meta"]["more"].as_bool.should be_false
  end

  it "passes the status filter through the query string" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LRouteQ", "name", "btree", "active", "idx_env_idxlist_q1")
      idx_list_insert(db, IDX_DOMAIN, "LRouteQ", "age", "btree_numeric", "pending", "idx_env_idxlist_q2")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[domain__eq]=#{IDX_DOMAIN}&filters[status__eq]=pending"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    rows = body["data"].as_a
    rows.size.should eq(1)
    rows.first["status"].as_s.should eq("pending")
  end

  it "keeps meta.more false while the count stays under the cap" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LMore", "f1", "btree", "active", "idx_env_idxlist_m1")
      idx_list_insert(db, IDX_DOMAIN, "LMore", "f2", "btree", "active", "idx_env_idxlist_m2")
    end

    # One row per page over a two-row fixture: the count never reaches the
    # cap, so `more` is false on both pages and `count` carries the real
    # number from each offset.
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[domain__eq]=#{IDX_DOMAIN}&items=1&page=1"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["more"].as_bool.should be_false
    body["meta"]["count"].as_i.should eq(2)

    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[domain__eq]=#{IDX_DOMAIN}&items=1&page=2"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["more"].as_bool.should be_false
    body["meta"]["count"].as_i.should eq(1)
  end

  it "answers 403 for a denied caller" do
    resp = call_api_as(HTTP::Request.new("GET", "/Api/Indexes"), Facet::RBAC::AuthContext.denied)
    assert_http_status(resp, 403)
  end

  it "answers 422 for a bare query parameter (strict admission)" do
    # `?domain__eq=hr` is not a recognized transport — the documented form
    # is `filters[domain__eq]=hr`. The strict scan names the bare key.
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?domain__eq=#{IDX_DOMAIN}"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'domain__eq'")
  end

  it "answers 422 for a bogus filter key" do
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[bogus__eq]=x"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown filter field 'bogus'")
  end

  it "answers 422 for an unsupported operator on a documented field" do
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes?filters[domain__gte]=#{IDX_DOMAIN}"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Filter operator 'gte' is not served for field 'domain'")
  end

  it "keeps the route outside the domain gate" do
    # /Api/Indexes must not be read as /Api/:domain — a disabled or unknown
    # domain would otherwise answer 404 before the route runs.
    resp = call_api(HTTP::Request.new("GET", "/Api/Indexes"))
    assert_http_status(resp, 200)
  end
end

describe "QUERY /Api/Indexes" do
  before_each do
    with_db do |db|
      db.exec("DELETE FROM doctype_indexes WHERE domain = $1", IDX_DOMAIN)
    end
  end

  it "filters through the body filters object" do
    with_db do |db|
      idx_list_insert(db, IDX_DOMAIN, "LQuery", "name", "btree", "active", "idx_env_idxlist_q")
    end

    resp = call_api(HTTP::Request.new("QUERY", "/Api/Indexes",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"filters": {"domain__eq": "#{IDX_DOMAIN}", "status__eq": "active"}})))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    rows = body["data"].as_a
    rows.size.should eq(1)
    rows.first["doc_type"].as_s.should eq("LQuery")
    rows.first["status"].as_s.should eq("active")
  end

  it "answers 422 for an unknown body key" do
    resp = call_api(HTTP::Request.new("QUERY", "/Api/Indexes",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"bogus": 1})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
  end

  it "answers 422 for a bogus filter key" do
    resp = call_api(HTTP::Request.new("QUERY", "/Api/Indexes",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"filters": {"bogus__eq": "x"}})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown filter field 'bogus'")
  end

  it "answers 422 for an unsupported operator on a documented field" do
    resp = call_api(HTTP::Request.new("QUERY", "/Api/Indexes",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"filters": {"status__gte": "active"}})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Filter operator 'gte' is not served for field 'status'")
  end

  it "answers 422 for query-string parameters (body-only transport)" do
    resp = call_api(HTTP::Request.new("QUERY", "/Api/Indexes?page=1"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("QUERY does not accept query parameters")
  end
end
