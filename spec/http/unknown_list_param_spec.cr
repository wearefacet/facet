# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-169 remainder — the document list surfaces answer `422` for a query
# parameter (or body key) outside the list grammar, naming it; a
# misspelled parameter must not vanish into a `200`. Strict admission is
# opt-in. The audit list surfaces hold the same contract (B-279): the
# global audit GET, the document-history and child-history GETs, and the
# webhook-calls GET parse with `strict: true` and admit their one
# handler-contract key as `extra_query_keys` (`include` on the document
# history, `status` on the webhook-calls list). The QUERY forms stay
# body-only and parse leniently, so a body `include` / `status` keeps
# working there.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/http/list_request"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/webhook_helper"

HTTPTest.init

private def ulp_seed_person_doctype : Nil
  with_db do |db|
    ensure_domain(db, "identity")
    defn = load_doctype_schema("identity.Person/definition.yml")
    create_doctype(defn)
  end
end

# Seeds a parent doctype with an `items` child relationship plus one
# parent and one child document — the nested child-list surface.
private def ulp_seed_pair(db, suffix : String)
  ensure_domain(db, "ulpdom")

  parent_dt = "UlpPar#{suffix}"
  child_dt = "UlpChd#{suffix}"

  parent_defn = %({"doctype": "#{parent_dt}", "domain": "ulpdom", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  child_defn = %({"doctype": "#{child_dt}", "domain": "ulpdom", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string", "filters": ["equality"]}}})
  result = Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  parent = Facet::Document::Create.call(db, "ulpdom", parent_dt, %({"name": "P"}), Facet::RBAC::AuthContext.system)
  parent.should be_a(Facet::Document::Create::Result)
  parent_id = parent.as(Facet::Document::Create::Result).projection.id

  child = Facet::Document::Create.call(db, "ulpdom", child_dt, %({"label": "C"}), Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_id)})
  child.should be_a(Facet::Document::Create::Result)

  {parent_dt, parent_id}
end

# Seeds a webhook with one recorded call — the webhook-calls list
# surface. The route reads `status` from the query string outside the
# list grammar, so the strict scan admits it as an extra key.
private def ulp_seed_webhook(db) : Nil
  # webhook_calls and background_jobs sit outside the global truncation;
  # clear the rows this helper owns so repeated seeds stay idempotent.
  db.exec("DELETE FROM webhook_calls WHERE webhook_id = 'ulp-wh'")
  db.exec("DELETE FROM background_jobs WHERE id LIKE 'ulp-%'")
  seed_webhook_source(db)
  role_id = seed_role(db, "ulp_wh_reader", [{"action" => "read", "on" => "sales.Invoice"}])
  account_id = create_test_account(db, roles: [role_id], default_role: role_id)
  create_bound_webhook(db, "ulp-wh", "sales.Invoice", account_id, role_id)
  sql = <<-SQL
  INSERT INTO webhook_calls (id, webhook_id, job_id, event, source_doc_id, mutation_id,
                             attempt, status, http_status, error, response_body, duration_ms,
                             created_at, updated_at)
  VALUES ('ulp-c-1', 'ulp-wh', 'ulp-job-1', 'updated', 'inv-1', 'mut-1', 1, 'failed', 500,
          'receiver exploded', 'body', 12, now(), now())
  SQL
  db.exec(sql)
end

describe "Unknown list parameters (B-169 remainder)" do
  # ── Parser level ─────────────────────────────────────────────────────

  it "from_query strict answers 422 for an unknown parameter" do
    err = Facet::HTTP::ListRequest.from_query(URI::Params.parse("bogus=1"), strict: true).as(Facet::ServiceError)
    err.status.should eq(422)
    err.message.should contain("Unknown parameter 'bogus'")
  end

  # B-308 — the 422 names the accepted key set, mirroring the
  # filter-grammar 422 on the same surfaces.
  it "names the accepted keys in the strict query 422" do
    err = Facet::HTTP::ListRequest.from_query(URI::Params.parse("limit=2"), strict: true).as(Facet::ServiceError)
    err.message.should contain("Unknown parameter 'limit' (accepted: ")
    err.message.should contain("items")
  end

  it "names the route's extra keys in the accepted set" do
    err = Facet::HTTP::ListRequest
      .from_query(URI::Params.parse("limit=2"), strict: true, extra_query_keys: Set{"include"})
      .as(Facet::ServiceError)
    err.message.should contain("(accepted: ")
    err.message.should contain("include")
  end

  it "names the accepted keys in the strict body 422" do
    err = Facet::HTTP::ListRequest.from_json(%({"limit": 2}), strict: true).as(Facet::ServiceError)
    err.message.should contain("Unknown parameter 'limit' (accepted: ")
    err.message.should contain("filters")
  end

  it "from_query strict admits the known parameters and the filters shape" do
    params = URI::Params.parse("page=2&items=10&sort=-id&select=full_name&aggregate=count&field=age&scope=emea&deleted=true&filters[age__gt]=18")
    Facet::HTTP::ListRequest.from_query(params, strict: true).should be_a(Facet::HTTP::ListRequest)
  end

  it "from_query stays lenient by default" do
    Facet::HTTP::ListRequest.from_query(URI::Params.parse("include=children&status=failed"))
      .should be_a(Facet::HTTP::ListRequest)
  end

  it "from_query strict admits the extra keys the handler names" do
    params = URI::Params.parse("include=children&status=failed&page=1")
    req = Facet::HTTP::ListRequest.from_query(params, strict: true, extra_query_keys: Set{"include", "status"})
    req.should be_a(Facet::HTTP::ListRequest)
    req.as(Facet::HTTP::ListRequest).page.should eq(1)
  end

  it "from_query strict still rejects an unnamed key beside admitted extras" do
    err = Facet::HTTP::ListRequest
      .from_query(URI::Params.parse("include=children&bogus=1"), strict: true, extra_query_keys: Set{"include"})
      .as(Facet::ServiceError)
    err.status.should eq(422)
    err.message.should contain("Unknown parameter 'bogus'")
  end

  it "from_json strict answers 422 for an unknown body key" do
    err = Facet::HTTP::ListRequest.from_json(%({"bogus": 1}), strict: true).as(Facet::ServiceError)
    err.status.should eq(422)
    err.message.should contain("Unknown parameter 'bogus'")
  end

  # F07-03: `admitted_keys` narrows the grammar to the keys the route reads.
  it "from_query strict rejects a grammar key outside admitted_keys" do
    admitted = Set{"page", "items", "sort", "filters"}
    err = Facet::HTTP::ListRequest
      .from_query(URI::Params.parse("select=zzz"), strict: true, admitted_keys: admitted)
      .as(Facet::ServiceError)
    err.status.should eq(422)
    err.message.should contain("Unknown parameter 'select'")
  end

  it "from_query strict admits the keys inside admitted_keys" do
    admitted = Set{"page", "items", "sort", "filters"}
    params = URI::Params.parse("page=2&items=10&sort=-id&filters[doc_type__eq]=Person")
    Facet::HTTP::ListRequest.from_query(params, strict: true, admitted_keys: admitted)
      .should be_a(Facet::HTTP::ListRequest)
  end

  it "from_json strict rejects a grammar key outside admitted_keys" do
    err = Facet::HTTP::ListRequest
      .from_json(%({"field": "doc_id"}), strict: true, admitted_keys: Set{"page", "items", "sort", "filters"})
      .as(Facet::ServiceError)
    err.status.should eq(422)
    err.message.should contain("Unknown parameter 'field'")
  end

  it "from_json strict admits the known keys and stays lenient by default" do
    body = %({"page": 1, "items": 10, "sort": ["id"], "filters": {"age__gt": 18}, "select": ["full_name"], "aggregate": "count", "field": "age", "scope": "emea", "deleted": true})
    Facet::HTTP::ListRequest.from_json(body, strict: true).should be_a(Facet::HTTP::ListRequest)
    Facet::HTTP::ListRequest.from_json(%({"include": "children"})).should be_a(Facet::HTTP::ListRequest)
  end

  # ── Document collection list (strict) ────────────────────────────────

  it "answers 422 on the GET list for an unknown parameter" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Ulp One", "email": "ulp-one@test.com", "date_of_birth": "1990-01-01"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person?bogus=1"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
  end

  it "answers 200 on the GET list for known parameters" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Ulp Two", "email": "ulp-two@test.com", "date_of_birth": "1990-01-02"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person?page=1&items=10&sort=-full_name"))
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"].as_a.size.should eq(1)
  end

  it "answers 422 on the GET list body for an unknown key" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"bogus": 1})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
  end

  it "answers 422 on the QUERY list for an unknown body key" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("QUERY", "/Api/identity/Person",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"bogus": 1})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
  end

  it "answers 200 on the QUERY list for known keys" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Ulp Three", "email": "ulp-three@test.com", "date_of_birth": "1990-01-03"}))

    resp = call_api(HTTP::Request.new("QUERY", "/Api/identity/Person",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"filters": {"full_name__match": "Ulp Three"}})))
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"].as_a.size.should eq(1)
  end

  # ── Nested child list (strict) ───────────────────────────────────────

  it "answers 422 on the child list for an unknown parameter" do
    with_db do |db|
      parent_dt, parent_id = ulp_seed_pair(db, unique_suffix(6))

      resp = call_api(HTTP::Request.new("GET", "/Api/ulpdom/#{parent_dt}/#{parent_id}/items?bogus=1"))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
    end
  end

  it "answers 200 on the child list for the forwarded parameters" do
    with_db do |db|
      parent_dt, parent_id = ulp_seed_pair(db, unique_suffix(6))

      resp = call_api(HTTP::Request.new("GET", "/Api/ulpdom/#{parent_dt}/#{parent_id}/items?filters[label__eq]=C"))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["data"].as_a.size.should eq(1)

      counted = call_api(HTTP::Request.new("GET", "/Api/ulpdom/#{parent_dt}/#{parent_id}/items?aggregate=count"))
      assert_http_status(counted, 200)
    end
  end

  # ── Audit and webhook lists (strict, with handler keys, B-279) ─────

  it "answers 422 on the global audit list for a bare unknown key" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Ulp Audit", "email": "ulp-audit@test.com", "date_of_birth": "1990-01-05"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/Audit?doc_type=Person"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'doc_type'")
  end

  it "answers 422 on the global audit list for limit" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("GET", "/Api/Audit?limit=2"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'limit'")
  end

  # F07-03: the global audit list reads only `page`, `items`, `sort`, and
  # `filters`. The grammar keys it drops answer 422 instead of vanishing
  # into an unfiltered 200.
  it "answers 422 on the global audit list for a grammar key it does not read" do
    ulp_seed_person_doctype

    ["field=doc_id:eq:x", "select=zzz", "aggregate=count", "scope=emea", "deleted=true"].each do |qs|
      resp = call_api(HTTP::Request.new("GET", "/Api/Audit?#{qs}"))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter")
    end
  end

  it "answers 422 on the global audit QUERY for a body key it does not read" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("QUERY", "/Api/Audit",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"select": ["zzz"]})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'select'")
  end

  it "filters the global audit list through the bracket form" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Ulp Filter", "email": "ulp-filter@test.com", "date_of_birth": "1990-01-06"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/Audit?filters[doc_type__eq]=Person"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    rows = body["data"].as_a
    rows.size.should be >= 1
    rows.map(&.["doc_type"].as_s).uniq!.should eq(["Person"])
  end

  it "answers 422 on the document history GET for an unknown parameter" do
    ulp_seed_person_doctype
    doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Ulp Hist Strict", "email": "ulp-hist-strict@test.com", "date_of_birth": "1990-01-07"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person/#{doc_id}/history?limit=2"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'limit'")
  end

  it "keeps include=children working on the document history GET" do
    ulp_seed_person_doctype
    doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Ulp Hist", "email": "ulp-hist@test.com", "date_of_birth": "1990-01-04"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person/#{doc_id}/history?include=children"))
    assert_http_status(resp, 200)
  end

  it "keeps the include body key working on the document history QUERY" do
    ulp_seed_person_doctype
    doc_id = create_doc_id_http("identity", "Person", %({"full_name": "Ulp Hist Query", "email": "ulp-hist-query@test.com", "date_of_birth": "1990-01-08"}))

    resp = call_api(HTTP::Request.new("QUERY", "/Api/identity/Person/#{doc_id}/history",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"include": "children"})))
    assert_http_status(resp, 200)
  end

  it "answers 422 on the child history GET for an unknown parameter" do
    with_db do |db|
      parent_dt, parent_id = ulp_seed_pair(db, unique_suffix(6))
      child_id = db.query_one("SELECT id FROM projections WHERE domain = 'ulpdom' AND doc_type LIKE 'UlpChd%' LIMIT 1", as: String)

      resp = call_api(HTTP::Request.new("GET", "/Api/ulpdom/#{parent_dt}/#{parent_id}/items/#{child_id}/history?bogus=1"))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
    end
  end

  it "answers 422 on the webhook-calls GET for an unknown parameter" do
    with_db do |db|
      ulp_seed_webhook(db)

      resp = call_api(HTTP::Request.new("GET", "/Api/core/Webhook/ulp-wh/calls?bogus=1"))
      assert_http_status(resp, 422)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown parameter 'bogus'")
    end
  end

  it "keeps status working on the webhook-calls GET" do
    with_db do |db|
      ulp_seed_webhook(db)

      resp = call_api(HTTP::Request.new("GET", "/Api/core/Webhook/ulp-wh/calls?status=failed"))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"].as_a.size.should eq(1)
      body["data"][0]["id"].as_s.should eq("ulp-c-1")
    end
  end

  it "keeps the status body key working on the webhook-calls QUERY" do
    with_db do |db|
      ulp_seed_webhook(db)

      resp = call_api(HTTP::Request.new("QUERY", "/Api/core/Webhook/ulp-wh/calls",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: %({"status": "failed"})))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["data"].as_a.size.should eq(1)
      body["data"][0]["id"].as_s.should eq("ulp-c-1")
    end
  end
end

describe "List doctype pre-check and admitted-param shapes (B-366 / B-358)" do
  # ── Unknown doctype answers 404 before the strict parse (B-366) ─

  it "answers 404 for an unknown doctype with garbage parameters" do
    resp = call_api(HTTP::Request.new("GET", "/Api/b366dom/NoSuchDoctype?bogus=1"))
    assert_http_status(resp, 404)
    error = JSON.parse(resp.body)["error"].as_s
    error.should contain("Unknown doctype: b366dom.NoSuchDoctype")
    error.should_not contain("Unknown parameter")
  end

  it "answers 404 for an unknown doctype with clean parameters" do
    resp = call_api(HTTP::Request.new("GET", "/Api/b366dom/NoSuchDoctype?page=1&items=10"))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown doctype: b366dom.NoSuchDoctype")
  end

  it "answers 404 on the QUERY door for an unknown doctype with an unknown body key" do
    resp = call_api(HTTP::Request.new("QUERY", "/Api/b366dom/NoSuchDoctype",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"bogus": 1})))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown doctype: b366dom.NoSuchDoctype")
  end

  # The nested catch-all list door resolves its path before its strict
  # scan — these two pin that ordering.
  it "answers 404 on the nested child list for an unknown root doctype with garbage parameters" do
    resp = call_api(HTTP::Request.new("GET", "/Api/b366dom/NoSuchDoctype/some-id/items?bogus=1"))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown doctype: b366dom.NoSuchDoctype")
  end

  it "answers 404 on the nested child list for an unknown child relationship with garbage parameters" do
    with_db do |db|
      parent_dt, parent_id = ulp_seed_pair(db, unique_suffix(6))

      resp = call_api(HTTP::Request.new("GET", "/Api/ulpdom/#{parent_dt}/#{parent_id}/ghost?bogus=1"))
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown child relationship 'ghost'")
    end
  end

  # ── `field` without a field aggregate answers 422 (B-358) ──────

  it "answers 422 on the GET list when field rides without an aggregate" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person?field=full_name"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("field=full_name requires an aggregate parameter")
  end

  # ── `select` keys validate against the declared fields (B-358) ─

  it "answers 422 on the GET list for an unknown select key" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person?select=ghost"))
    assert_http_status(resp, 422)
    error = JSON.parse(resp.body)["error"].as_s
    error.should contain("Unknown select key 'ghost'")
    error.should contain("full_name")
  end

  it "answers 422 on the QUERY list for an unknown select key in the body" do
    ulp_seed_person_doctype

    resp = call_api(HTTP::Request.new("QUERY", "/Api/identity/Person",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"select": ["ghost"]})))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("Unknown select key 'ghost'")
  end

  it "keeps a valid select working on the GET list" do
    ulp_seed_person_doctype
    create_doc_id_http("identity", "Person", %({"full_name": "Sel One", "email": "sel-one@test.com", "date_of_birth": "1990-01-01"}))

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person?select=full_name"))
    assert_http_status(resp, 200)
    rows = JSON.parse(resp.body)["data"].as_a
    rows.size.should eq(1)
    row = rows[0]["data"].as_h
    row["full_name"].as_s.should eq("Sel One")
    row.has_key?("email").should be_false
    # System identity stays in meta, untouched by the projection.
    rows[0]["meta"]["id"].as_s.should_not be_empty
  end
end
