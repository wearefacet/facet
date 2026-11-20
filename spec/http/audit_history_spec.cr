# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Pin the HTTP-level response shape of the audit-history endpoints.
#
# These endpoints (`GET /Api/:domain/:doctype/:id/history` and the global
# `GET /Api/Audit`) share the same `{ data: [...], meta: { count, more } }`
# facet as document lists — the frontend's History view reads
# `history.data`. These specs guard the contract.
describe "Audit history HTTP response shape" do
  before_each do
    # Seed the `identity.Person` doctype (also used by server_spec.cr) so a
    # backing document exists to query history for.
    with_db do |db|
      ensure_domain(db, "identity")
      defn = load_doctype_schema("identity.Person/definition.yml")
      create_doctype(defn)
    end
  end

  it "GET /Api/:domain/:doctype/:id/history returns { data, meta:{count,more} }" do
    doc_id = create_doc_id_http(
      "identity", "Person",
      %({"full_name": "Audit Shape", "email": "auditshape@test.com", "date_of_birth": "1990-01-01"})
    )

    resp = call_api(HTTP::Request.new("GET", "/Api/identity/Person/#{doc_id}/history?items=50&sort=-emitted_at"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["data"].as_a.empty?.should be_false
    record = body["data"].as_a.first
    {"id", "domain", "doc_type", "doc_id", "idx", "action", "actioner_id",
     "arguments", "channel", "cause_kind", "emitted_at"}.each do |key|
      record.as_h.has_key?(key).should be_true, "missing key #{key} in mutation record"
    end
    record["action"].as_s.should eq("create")
    record["doc_id"].as_s.should eq(doc_id)

    body["meta"]["count"].raw.should be_a(Int64 | Int32)
    body["meta"]["more"].as_bool.should be_false
    # The legacy `{ items, total }` shape must NOT be returned.
    body.as_h.has_key?("items").should be_false
    body.as_h.has_key?("total").should be_false
  end

  it "GET /Api/Audit returns the same { data, meta:{count,more} } facet" do
    # Ensure at least one mutation exists globally.
    create_doc_id_http(
      "identity", "Person",
      %({"full_name": "Global Audit", "email": "globalaudit@test.com", "date_of_birth": "1990-01-01"})
    )

    resp = call_api(HTTP::Request.new("GET", "/Api/Audit?items=1"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    # `items=1` paginates to a single row; the full mutation set for this
    # session exceeds one row, so `data` is capped to one entry.
    body["data"].as_a.size.should eq(1)
    body["meta"]["count"].raw.should be_a(Int64 | Int32)
    # `more` means "counting was truncated": the session's mutation set sits
    # far below the 1000 cap, so the count is exact and the flag is false.
    body["meta"]["more"].as_bool.should be_false

    body.as_h.has_key?("items").should be_false
    body.as_h.has_key?("total").should be_false
  end
end

# ── Aggregate history (include=children) ────────────────────────────────
#
# `?include=children` merges the readable child timelines into the parent
# history. The HTTP surface stays the same { data, meta:{count,more} }
# facet, with the count taken across both branches (parent rows + child
# rows, each counted once) and the 1000 cap applied over the merged set.
describe "Audit history aggregate (include=children)" do
  # Registers one parent + one child doctype pair through the services and
  # seeds a parent document plus one child (nested-route style). Doctypes
  # carry a display_name template so labels land on the projection rows.
  before_each do
    with_db do |db|
      ensure_domain(db, "histcap")
      parent = "HP#{unique_suffix}"
      child = "HC#{unique_suffix}"
      parent_defn = %({"doctype": "#{parent}", "domain": "histcap", "aggregate_root": true, "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child}", "collection": true}}})
      child_defn = %({"doctype": "#{child}", "domain": "histcap", "aggregate_root": false, "member_of": "#{parent}", "display_name": "{{ name }}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system).should be_a(Facet::Document::Create::Result)

      parent_res = Facet::Document::Create.call(db, "histcap", parent, %({"name": "root"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result)
      Facet::Document::Create.call(
        db, "histcap", child, %({"name": "kid"}), Facet::RBAC::AuthContext.system,
        meta_overrides: {"parent_id" => JSON::Any.new(parent_res.projection.id)},
      ).should be_a(Facet::Document::Create::Result)
    end
  end

  it "merges child rows into the parent history over HTTP" do
    parent_dt = ""
    parent_id = ""
    child_dt = ""
    with_db do |db|
      parent_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HP%' LIMIT 1", as: String)
      parent_id = db.query_one("SELECT id FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HP%' AND deleted_at IS NULL LIMIT 1", as: String)
      child_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HC%' LIMIT 1", as: String)
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/histcap/#{parent_dt}/#{parent_id}/history?include=children"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    doc_types = body["data"].as_a.map(&.["doc_type"].as_s).uniq!
    doc_types.should contain(parent_dt)
    doc_types.should contain(child_dt)
    # Labels ride the aggregate rows (D6).
    body["data"].as_a.map(&.["display_name"]).should contain("kid")
    body["meta"]["count"].raw.should be_a(Int64 | Int32)
  end

  it "caps the aggregate count at 1000 with more=true across both branches" do
    parent_dt = ""
    parent_id = ""
    child_dt = ""
    child_id = ""
    with_db do |db|
      parent_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HP%' LIMIT 1", as: String)
      parent_id = db.query_one("SELECT id FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HP%' AND deleted_at IS NULL LIMIT 1", as: String)
      child_dt = db.query_one("SELECT DISTINCT doc_type FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HC%' LIMIT 1", as: String)
      child_id = db.query_one("SELECT id FROM projections WHERE domain = 'histcap' AND doc_type LIKE 'HC%' AND deleted_at IS NULL LIMIT 1", as: String)

      # Bulk rows through the real trigger: 600 parent updates + 401 child
      # updates = 1001 aggregate rows. The BEFORE trigger stamps idx and
      # parent_doc_id; the AFTER trigger upserts the projections.
      db.exec(<<-SQL, parent_id)
        INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
        SELECT 'histcap', '#{parent_dt}', ulid(), $1, 'update', 'spec-runner', '{}'::jsonb, 'internal', 'request', ulid()
        FROM generate_series(1, 600)
      SQL
      db.exec(<<-SQL, child_id)
        INSERT INTO mutations (domain, doc_type, id, doc_id, action, actioner_id, arguments, channel, cause_kind, cause_trace)
        SELECT 'histcap', '#{child_dt}', ulid(), $1, 'update', 'spec-runner', '{}'::jsonb, 'internal', 'request', ulid()
        FROM generate_series(1, 401)
      SQL
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/histcap/#{parent_dt}/#{parent_id}/history?include=children&items=50"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["meta"]["count"].as_i.should eq(1000)
    body["meta"]["more"].as_bool.should be_true
    body["data"].as_a.size.should eq(50)

    # Without the flag the count covers the parent branch only. The exact
    # row counts come from the DB — the periodic_snapshot trigger adds a
    # row every 10th idx, so the totals exceed the raw insert counts.
    parent_rows = 0_i64
    child_rows = 0_i64
    with_db do |db|
      parent_rows = db.query_one("SELECT COUNT(*) FROM mutations WHERE domain = 'histcap' AND doc_type = $1 AND doc_id = $2", parent_dt, parent_id, as: Int64)
      child_rows = db.query_one("SELECT COUNT(*) FROM mutations WHERE domain = 'histcap' AND doc_type = $1 AND doc_id = $2", child_dt, child_id, as: Int64)
    end
    (parent_rows + child_rows).should be > 1000

    plain = call_api(HTTP::Request.new("GET", "/Api/histcap/#{parent_dt}/#{parent_id}/history"))
    assert_http_status(plain, 200)
    plain_body = JSON.parse(plain.body)
    plain_body["meta"]["count"].as_i.should eq(parent_rows)
    # The parent branch alone carries ~660 rows — under the cap, so the
    # count is exact and `more` is false.
    plain_body["meta"]["more"].as_bool.should be_false
  end
end
