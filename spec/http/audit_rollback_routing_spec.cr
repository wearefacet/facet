# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# B-149 — audit rollback routing + mutation-id shape contract.
#
# Two layers:
#
# 1. Routing: `POST /Api/Audit/<mutation_id>/rollback` reaches the audit
#    route. A deeper path under /Api/Audit (5+ segments) matches no audit
#    route — the REST catch-all must not claim it and answer
#    "Unknown doctype: Audit.<id>"; the reserved virtual namespace answers
#    a plain 404 "Not found" instead.
# 2. Shape: a malformed (non-ULID) mutation id answers `422` with a clear
#    message from every audit write handler — global rollback, document
#    rollback, child rollback, restore. The check lives at the route
#    layer; `Audit::Rollback.call` keeps receiving trusted ids.
describe "Audit rollback routing (B-149)" do
  it "routes a malformed mutation id to the audit route (422, not the catch-all)" do
    # 26 characters, but not a ULID: a lowercase letter and a symbol are
    # both outside the Crockford base32 alphabet.
    resp = call_api(HTTP::Request.new("POST", "/Api/Audit/01bad*id0000000000000000z/rollback"))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("mutation_id must be a ULID")
  end

  it "routes a deep path under /Api/Audit to the reserved-namespace 404, never the catch-all" do
    # One segment more than the global rollback route: the audit route
    # tree has nothing here, and the catch-all must not read "Audit" as a
    # document domain (it answered 404 "Unknown doctype: Audit.<id>").
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/Audit/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback/extra",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "01AAAAAAAAAAAAAAAAAAAAAAAA"}),
    ))
    assert_http_status(resp, 404)
    resp.body.should eq({"error" => "Not found"}.to_json)
  end

  it "keeps GET /Api/Audit on the audit list route" do
    resp = call_api(HTTP::Request.new("GET", "/Api/Audit"))
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"].as_a.size.should eq(0)
  end

  it "answers a well-formed but nonexistent ULID from the audit route (404, no doctype noise)" do
    id = "01" + "A" * 24
    resp = call_api(HTTP::Request.new("POST", "/Api/Audit/#{id}/rollback"))
    assert_http_status(resp, 404)
    # Route marker: the audit route answered. The body of this 404 is
    # owned by another fix — assert only that it is not the catch-all's
    # doctype-not-found answer.
    resp.body.should_not contain("Unknown doctype")
    resp.body.should_not contain("Nested path is empty")
  end
end

# Spec infrastructure for the body-id shape contract: one seeded doctype,
# one live document, one deleted document (a tombstone to restore).
def rollback_route_seed_doctype(db, doctype : String) : Nil
  ensure_domain(db, "rollbackroute")
  defn_json = %({
    "doctype": "#{doctype}",
    "domain": "rollbackroute",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string"},
      "department": {"type": "string"}
    }
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

describe "Audit mutation-id shape contract (B-149)" do
  before_each do
    with_db do |db|
      rollback_route_seed_doctype(db, "Task")
    end
  end

  it "document rollback rejects a malformed mutation_id with 422" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))

    request = HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "not-a-ulid"}),
    )
    resp = call_api(request)
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("mutation_id must be a ULID")
  end

  it "document rollback rejects a non-string mutation_id with 422 (no 500)" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))

    request = HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": 12345}),
    )
    resp = call_api(request)
    assert_http_status(resp, 422)
  end

  it "child rollback rejects a malformed mutation_id with 422" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))

    request = HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/Child/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "not-a-ulid"}),
    )
    resp = call_api(request)
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("mutation_id must be a ULID")
  end

  it "restore still resolves its internally resolved target through the ULID contract" do
    # The restore target is a database-owned ULID — the check is a
    # defensive pass-through here. Pin the happy path: a delete→restore
    # round trip still answers 200.
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "doomed", "department": "eng"}))
    delete_document_http("rollbackroute", "Task", doc_id)

    resp = call_api(HTTP::Request.new("POST", "/Api/rollbackroute/Task/#{doc_id}/restore"))
    assert_http_status(resp, 200)
    JSON.parse(resp.body)["data"]["name"].as_s.should eq("doomed")
  end
end

# F09-01 — a body that parses as JSON but is not an object must answer
# `422`, never the `500` the body probes raise on the wrapped value.
# The guard covers all three rollback handlers: global, document, child.
describe "Audit rollback rejects a non-object JSON body (F09-01)" do
  before_each do
    with_db do |db|
      rollback_route_seed_doctype(db, "Task")
    end
  end

  it "global rollback answers 422 for a scalar body" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/Audit/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %("x"),
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Invalid JSON body — the request body must be a JSON object")
  end

  it "global rollback answers 422 for an array body" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/Audit/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %([1, 2]),
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Invalid JSON body — the request body must be a JSON object")
  end

  it "document rollback answers 422 for a scalar body" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %("x"),
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Invalid JSON body — the request body must be a JSON object")
  end

  it "child rollback answers 422 for a scalar body" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/Child/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %("x"),
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("Invalid JSON body — the request body must be a JSON object")
  end

  it "global rollback answers 422 for a non-string scope value" do
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/Audit/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"scope": 5}),
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should eq("scope must be 'document' or 'cluster'")
  end

  it "still accepts an object body and reaches the rollback service (happy path)" do
    # A well-formed ULID that no mutation holds: the shape gate passes,
    # `scope` resolves, and the service answers its own 404.
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/Audit/01AAAAAAAAAAAAAAAAAAAAAAAA/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"scope": "cluster"}),
    ))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("not found")
  end
end

# B-146 — the 404 body for a well-formed but unknown mutation id names the
# retention window in force, so a caller can tell "my target is older than
# the window" from "my id is wrong" without confirming that the id ever
# existed (one status for all three causes: unknown, compacted, folded).
# The window resolves exactly as compaction resolves it (`Mutation::Retention`).
describe "Audit rollback 404 body names the retention window (B-146)" do
  before_each do
    with_db do |db|
      rollback_route_seed_doctype(db, "Task")
    end
  end

  it "document rollback 404 names the doctype window" do
    doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))
    unknown = "01" + "B" * 24

    request = HTTP::Request.new(
      "POST",
      "/Api/rollbackroute/Task/#{doc_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "#{unknown}"}),
    )
    resp = call_api(request)
    assert_http_status(resp, 404)
    body = JSON.parse(resp.body)["error"].as_s
    body.should start_with("Mutation #{unknown} not found")
    expected = with_db { |db| Facet::Mutation::Retention.effective_days(db, "rollbackroute", "Task") }
    body.should contain("retention window (#{expected} days for rollbackroute.Task)")
    body.should contain("folded by coalescing")
  end

  it "global rollback 404 names the base window (no doctype known)" do
    unknown = "01" + "C" * 24

    resp = call_api(HTTP::Request.new("POST", "/Api/Audit/#{unknown}/rollback"))
    assert_http_status(resp, 404)
    body = JSON.parse(resp.body)["error"].as_s
    body.should start_with("Mutation #{unknown} not found")
    expected = with_db { |db| Facet::Mutation::Retention.base_days(db) }
    body.should contain("retention window (#{expected} days), or folded")
    # The global route does not know the target's doctype — no target clause.
    body.should_not contain(" days for ")
  end

  it "per-doctype override wins in the document rollback 404" do
    cfg = Facet::Config.instance
    cfg.mutations.retention_overrides["rollbackroute.Task"] = 7
    begin
      doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))
      unknown = "01" + "D" * 24

      request = HTTP::Request.new(
        "POST",
        "/Api/rollbackroute/Task/#{doc_id}/rollback",
        HTTP::Headers{"Content-Type" => "application/json"},
        body: %({"mutation_id": "#{unknown}"}),
      )
      resp = call_api(request)
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should contain("retention window (7 days for rollbackroute.Task)")
    ensure
      cfg.mutations.retention_overrides.delete("rollbackroute.Task")
    end
  end

  it "a runtime pin replaces the file window in the document rollback 404" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"mutations": {"retention_days": 5}}))
      begin
        doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))
        unknown = "01" + "E" * 24

        request = HTTP::Request.new(
          "POST",
          "/Api/rollbackroute/Task/#{doc_id}/rollback",
          HTTP::Headers{"Content-Type" => "application/json"},
          body: %({"mutation_id": "#{unknown}"}),
        )
        resp = call_api(request)
        assert_http_status(resp, 404)
        JSON.parse(resp.body)["error"].as_s.should contain("retention window (5 days for rollbackroute.Task)")
      ensure
        pin_settings(db, %({"mutations": {"retention_days": null}}))
      end
    end
  end

  it "a window of 0 (keep forever) drops the window clause from the 404" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"mutations": {"retention_days": 0}}))
      begin
        doc_id = create_doc_id_http("rollbackroute", "Task", %({"name": "live", "department": "eng"}))
        unknown = "01" + "F" * 24

        request = HTTP::Request.new(
          "POST",
          "/Api/rollbackroute/Task/#{doc_id}/rollback",
          HTTP::Headers{"Content-Type" => "application/json"},
          body: %({"mutation_id": "#{unknown}"}),
        )
        resp = call_api(request)
        assert_http_status(resp, 404)
        body = JSON.parse(resp.body)["error"].as_s
        body.should start_with("Mutation #{unknown} not found")
        body.should contain("folded by coalescing")
        body.should_not contain("retention window")
      ensure
        pin_settings(db, %({"mutations": {"retention_days": null}}))
      end
    end
  end
end
