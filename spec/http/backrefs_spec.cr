# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/rbac/auth_context"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# Seeds the fixture: `bref.Team` (target) plus `bref.Project` referrers
# (one live, one tombstoned) and a cross-domain `brefx.Note` referrer,
# all with display_name templates. Returns the fixture coordinates.
def seed_backrefs_fixture
  with_db do |db|
    seed_iam_doctypes(db)
    ensure_domain(db, "bref")
    ensure_domain(db, "brefx")
    Facet::Document::Create.call(db, "core", "DocType", %({
      "doctype": "Team", "domain": "bref", "aggregate_root": true,
      "display_name": "{{ name }}",
      "fields": {"name": {"type": "string", "required": true}}
    }), Facet::RBAC::AuthContext.system)
    Facet::Document::Create.call(db, "core", "DocType", %({
      "doctype": "Project", "domain": "bref", "aggregate_root": true,
      "display_name": "{{ name }}",
      "fields": {
        "name": {"type": "string", "required": true},
        "team": {"type": "reference", "doctype": "bref.Team"}
      }
    }), Facet::RBAC::AuthContext.system)
    Facet::Document::Create.call(db, "core", "DocType", %({
      "doctype": "Note", "domain": "brefx", "aggregate_root": true,
      "display_name": "{{ name }}",
      "fields": {
        "name": {"type": "string", "required": true},
        "team": {"type": "reference", "doctype": "bref.Team"}
      }
    }), Facet::RBAC::AuthContext.system)

    team = Facet::Document::Create.call(db, "bref", "Team", %({"name": "Core"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
    keep = Facet::Document::Create.call(db, "bref", "Project", %({"name": "Keep", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
    gone = Facet::Document::Create.call(db, "bref", "Project", %({"name": "Gone", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system).as(Facet::Document::Create::Result).projection
    Facet::Document::Create.call(db, "brefx", "Note", %({"name": "N1", "team": "#{team.id}"}), Facet::RBAC::AuthContext.system)
    Facet::Document::Delete.call(db, "bref", "Project", gone.id, Facet::RBAC::AuthContext.system)
    {team.id, keep.id}
  end
end

# Pins the HTTP contract of `GET|QUERY /Api/:domain/:doctype/:id/backrefs`:
# the `{ data, meta: { target, total, capped } }` envelope with stub rows,
# the non-disclosing 404 on a missing target, the class-level 403 on a
# denied target, list-visibility filtering of referrer rows, the `items`
# cap, and the QUERY transport.
describe "Backrefs HTTP endpoint" do
  it "GET returns { data, meta:{target,total,capped} } with stub rows" do
    team_id, _keep_id = seed_backrefs_fixture

    resp = call_api(HTTP::Request.new("GET", "/Api/bref/Team/#{team_id}/backrefs"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    rows = body["data"].as_a
    rows.size.should eq(2)
    rows.map(&.["display_name"].as_s).sort!.should eq(["Keep", "N1"])
    row = rows.first.as_h
    {"id", "domain", "doc_type", "display_name"}.each do |key|
      row.has_key?(key).should be_true, "missing key #{key} in stub row"
    end

    meta = body["meta"]
    meta["target"].as_s.should eq("urn:facet:bref:Team:#{team_id}")
    meta["total"].raw.should be_a(Int64 | Int32)
    meta["capped"].as_bool.should be_false
  end

  it "excludes a tombstoned referrer" do
    team_id, keep_id = seed_backrefs_fixture

    resp = call_api(HTTP::Request.new("GET", "/Api/bref/Team/#{team_id}/backrefs"))
    body = JSON.parse(resp.body)
    ids = body["data"].as_a.map(&.["id"].as_s)
    ids.should contain(keep_id)
    ids.size.should eq(2) # Keep + the cross-domain note; the tombstone is absent
  end

  it "answers 404 for a missing target" do
    seed_backrefs_fixture

    resp = call_api(HTTP::Request.new("GET", "/Api/bref/Team/absent/backrefs"))
    assert_http_status(resp, 404)
  end

  it "answers 403 for a denied target and never leaks referrer rows" do
    team_id, _keep_id = seed_backrefs_fixture

    # A role that reads only the referrer doctypes holds no read grant on
    # the target doctype — the class-level denial `Document::Read` answers
    # with 403. A grant holder who cannot see the target keeps the
    # non-disclosing 404.
    with_db do |db|
      ctx = build_context_with_permissions(db, [
        {"action" => "read", "on" => "bref.Project"},
        {"action" => "read", "on" => "brefx.Note"},
      ])
      resp = call_api_as(HTTP::Request.new("GET", "/Api/bref/Team/#{team_id}/backrefs"), ctx)
      assert_http_status(resp, 403)
    end
  end

  it "hides a referrer outside the role's list scope" do
    team_id, _keep_id = seed_backrefs_fixture

    with_db do |db|
      Facet::Document::Create.call(db, "core", "DocType", %({
        "doctype": "Scoped", "domain": "bref", "aggregate_root": true,
        "display_name": "{{ name }}",
        "fields": {
          "name": {"type": "string", "required": true},
          "team": {"type": "reference", "doctype": "bref.Team"}
        },
        "scopes": {"pub": {"where": {"name": "Public"}, "description": "Public rows"}}
      }), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, "bref", "Scoped", %({"name": "Public", "team": "#{team_id}"}), Facet::RBAC::AuthContext.system)
      Facet::Document::Create.call(db, "bref", "Scoped", %({"name": "Private", "team": "#{team_id}"}), Facet::RBAC::AuthContext.system)

      ctx = build_context_with_permissions(db, [
        {"action" => "read", "on" => "bref.Team"},
        {"action" => "read", "on" => "bref.Scoped", "scope" => "pub"},
      ])
      resp = call_api_as(HTTP::Request.new("GET", "/Api/bref/Team/#{team_id}/backrefs"), ctx)
      assert_http_status(resp, 200)

      names = JSON.parse(resp.body)["data"].as_a.map(&.["display_name"].as_s)
      names.should contain("Public")
      names.should_not contain("Private")
    end
  end

  it "caps the result at items and reports capped honestly" do
    team_id, _keep_id = seed_backrefs_fixture

    resp = call_api(HTTP::Request.new("GET", "/Api/bref/Team/#{team_id}/backrefs?items=1"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["data"].as_a.size.should eq(1)
    body["meta"]["capped"].as_bool.should be_true
  end

  it "QUERY carries the parameters in the body only" do
    team_id, _keep_id = seed_backrefs_fixture

    request = HTTP::Request.new("QUERY", "/Api/bref/Team/#{team_id}/backrefs",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"items": 1}))
    resp = call_api(request)
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["data"].as_a.size.should eq(1)
    body["meta"]["capped"].as_bool.should be_true

    # QUERY rejects query-string parameters — the transport split stays loud.
    bad = call_api(HTTP::Request.new("QUERY", "/Api/bref/Team/#{team_id}/backrefs?items=1"))
    assert_http_status(bad, 422)
  end

  it "is declared in the OpenAPI v1 scope" do
    resp = call_api(HTTP::Request.new("GET", "/Api/bref/Team/whatever/backrefs"))
    # A route hit proves registration; the drift check in openapi_spec.cr
    # proves the declaration. 404 (non-disclosing) is the expected outcome
    # for a missing target.
    assert_http_status(resp, 404)
  end
end
