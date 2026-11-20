# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# QA run 39, finding B-146 — audit error responses must carry a JSON body.
#
# Kemal drops a route's RETURNED body when the status has a registered
# status-level error handler (the no-op `error 404` in `src/http/server.cr`).
# The audit result writers therefore print their error bodies with
# `HTTP::Helpers.error_response` (see `src/http/responders.cr`). These
# specs pin the contract:
#
# - `POST /Api/Audit/:mutation_id/rollback` with an unknown ULID → 404
#   with a non-empty JSON error body.
# - Document rollback with an unknown `mutation_id` → 404 with a non-empty
#   JSON error body.
# - A denied scoped document history read (non-disclosing) → 404 with a
#   non-empty JSON error body.
# - `POST …/restore` on a live document → 409, body present and unchanged
#   (guard: the fix must not change the statuses that already worked).

AUDIT_ERR_UNKNOWN_ULID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

private def audit_err_create_doctype(db, doctype : String) : Nil
  ensure_domain(db, "auditerr")
  defn_json = %({
    "doctype": "#{doctype}",
    "domain": "auditerr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string"},
      "department": {"type": "string"}
    },
    "scopes": {"eng": {"where": {"department": "eng"}}}
  })
  result = Facet::Document::Create.call(db, "core", "DocType", defn_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
end

private def audit_err_scoped_role(db, role_id : String, permissions_json : String) : Facet::RBAC::AuthContext
  content = %({"name": "#{role_id}", "visible_tags": ["default"], "permissions": [#{permissions_json}]})
  Facet::Mutation::Client.create(db, "iam", "Role", doc_id: role_id, content: content, actioner_id: "system")
  role = Facet::RBAC::ActiveRole.from_projection_content(
    Facet::Mutation::Client.fetch_content(db, "iam", "Role", role_id)
  )
  Facet::RBAC::AuthContext.authenticated(role_id, role)
end

# Asserts a non-empty JSON error body with an `error` message and the JSON
# content type. Returns the parsed body.
private def assert_audit_error_body(resp : HTTP::Client::Response) : JSON::Any
  resp.body.empty?.should be_false
  resp.headers["Content-Type"]?.try(&.starts_with?("application/json")).should be_true
  body = JSON.parse(resp.body)
  body["error"].as_s.empty?.should be_false
  body
end

describe "Audit error response bodies (B-146)" do
  before_each do
    with_db do |db|
      audit_err_create_doctype(db, "Ticket")
    end
  end

  it "POST /Api/Audit/:mutation_id/rollback with an unknown ULID returns 404 with a JSON error body" do
    resp = call_api(HTTP::Request.new("POST", "/Api/Audit/#{AUDIT_ERR_UNKNOWN_ULID}/rollback"))
    assert_http_status(resp, 404)
    assert_audit_error_body(resp)
  end

  it "POST document rollback with an unknown mutation_id returns 404 with a JSON error body" do
    doc_id = create_doc_id_http("auditerr", "Ticket", %({"name": "live", "department": "eng"}))

    request = HTTP::Request.new(
      "POST",
      "/Api/auditerr/Ticket/#{doc_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "#{AUDIT_ERR_UNKNOWN_ULID}"}),
    )
    resp = call_api(request)
    assert_http_status(resp, 404)
    assert_audit_error_body(resp)
  end

  it "denied scoped document history read returns 404 with a JSON error body" do
    doc_id = create_doc_id_http("auditerr", "Ticket", %({"name": "mkt doc", "department": "mkt"}))

    auth = nil
    with_db do |db|
      auth = audit_err_scoped_role(
        db, "auditerr_history_reader",
        %({"action": "read", "on": "auditerr.Ticket", "scope": "$eng"}),
      )
    end

    request = HTTP::Request.new("GET", "/Api/auditerr/Ticket/#{doc_id}/history")
    resp = call_api_as(request, auth)
    assert_http_status(resp, 404)
    assert_audit_error_body(resp)
  end

  it "POST restore on a live document keeps its 409 body (guard)" do
    doc_id = create_doc_id_http("auditerr", "Ticket", %({"name": "live", "department": "eng"}))

    resp = call_api(HTTP::Request.new("POST", "/Api/auditerr/Ticket/#{doc_id}/restore"))
    assert_http_status(resp, 409)
    body = assert_audit_error_body(resp)
    body["error"].as_s.should eq("Document is not deleted")
  end
end
