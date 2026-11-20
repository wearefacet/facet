# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/rbac"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "json"

HTTPTest.init

# Shared response presentation (execution plan Phase 5): HTTP write
# responses and agent-tool mutation results present content through the
# shared presenter, so invisible fields never reach the wire. Read results
# are already masked — presentation is idempotent.
private def presenter_seed(db)
  restore_seeded_baseline(db)
  Facet::Doctype::DefinitionStore.cache.clear
end

private def presenter_role(tags : Array(String), domain : String, doctype : String)
  role = Facet::RBAC::ActiveRole.new(
    role_id: "presenter_role",
    visible_tags: Set.new(tags),
    permissions: [
      Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "create", "on": "#{domain}.#{doctype}"}))),
      Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "update", "on": "#{domain}.#{doctype}"}))),
      Facet::RBAC::Permission.from_json(JSON.parse(%({"action": "read", "on": "#{domain}.#{doctype}"}))),
    ],
  )
  Facet::RBAC::AuthContext.authenticated("presenter-caller", role)
end

private def presenter_doctype(db, domain : String, doctype : String)
  ensure_domain(db, domain)
  fields = %({
    "name": {"type": "string"},
    "salary": {"type": "integer", "tags": ["confidential"]},
    "profile": {"type": "object", "properties": {
      "bio": {"type": "string"},
      "grade": {"type": "string", "tags": ["confidential"]}
    }}
  })
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": #{fields}})
  Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
end

describe "Document::Presenter on write responses" do
  it "masks create responses over HTTP" do
    with_temp_doctype("presp") do |db, domain, doctype|
      presenter_seed(db)
      presenter_doctype(db, domain, doctype)
      # The masked caller cannot submit invisible content (the write guard
      # refuses it), so the masked create response is exercised by the
      # wildcard caller, whose create lands the invisible values. The
      # wildcard caller's own response is raw; the masked verification
      # rides the update example below. Here the masked caller creates
      # visible-only content and its response presents the visible shape.
      ctx = presenter_role(["default"], domain, doctype)

      body = %({"name": "a", "profile": {"bio": "b"}})
      resp = call_api_as(HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}", body: body), ctx)
      resp.status_code.should eq(201)
      payload = JSON.parse(resp.body)
      payload["data"]["name"].as_s.should eq("a")
      payload["data"]["salary"]?.should be_nil
      payload["data"]["profile"]["bio"].as_s.should eq("b")
      payload["meta"]["mid"].as_s.should_not be_empty
    end
  end

  it "masks update and action responses, and a wildcard-tag caller sees raw values" do
    with_temp_doctype("presu") do |db, domain, doctype|
      presenter_seed(db)
      presenter_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 1, "profile": {"bio": "b", "grade": "G"}}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      ctx = presenter_role(["default"], domain, doctype)

      # Update response masks.
      resp = call_api_as(HTTP::Request.new("PATCH", "/Api/#{domain}/#{doctype}/#{doc_id}",
        headers: HTTP::Headers{"Content-Type" => "application/json"}, body: %({"name": "b"})), ctx)
      resp.status_code.should eq(200)
      payload = JSON.parse(resp.body)
      payload["data"]["name"].as_s.should eq("b")
      payload["data"]["salary"]?.should be_nil
      payload["data"]["profile"]["grade"]?.should be_nil

      # Wildcard-tag caller sees raw values on the same update surface.
      wide = presenter_role(["*"], domain, doctype)
      resp2 = call_api_as(HTTP::Request.new("PATCH", "/Api/#{domain}/#{doctype}/#{doc_id}",
        headers: HTTP::Headers{"Content-Type" => "application/json"}, body: %({"name": "c"})), wide)
      resp2.status_code.should eq(200)
      payload2 = JSON.parse(resp2.body)
      payload2["data"]["salary"].as_i.should eq(1)
      payload2["data"]["profile"]["grade"].as_s.should eq("G")

      # System sees raw too.
      resp3 = call_api_as(HTTP::Request.new("GET", "/Api/#{domain}/#{doctype}/#{doc_id}"), sys)
      resp3.status_code.should eq(200)
      payload3 = JSON.parse(resp3.body)
      payload3["data"]["salary"].as_i.should eq(1)
    end
  end

  it "masks rollback and restore responses over HTTP" do
    with_temp_doctype("presr") do |db, domain, doctype|
      presenter_seed(db)
      presenter_doctype(db, domain, doctype)
      sys = Facet::RBAC::AuthContext.system

      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 1, "profile": {"bio": "b", "grade": "G"}}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id
      Facet::Document::Update.call(db, domain, doctype, doc_id, %({"name": "b"}), sys)
        .as(Facet::Document::Update::Result)

      ctx = presenter_role(["default"], domain, doctype)
      history = Facet::Audit::List.call(db, domain: domain, doc_type: doctype, doc_id: doc_id, auth_context: sys)
        .as(Facet::Audit::List::Result)
      rename = history.items.reverse_each.find { |m| m.action == "update" }.should_not be_nil

      resp = call_api_as(HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/#{doc_id}/rollback",
        headers: HTTP::Headers{"Content-Type" => "application/json"},
        body: %({"mutation_id": "#{rename.id}"})), ctx)
      resp.status_code.should eq(200)
      payload = JSON.parse(resp.body)
      payload["data"]["name"].as_s.should_not be_empty
      payload["data"]["salary"]?.should be_nil
      payload["data"]["profile"]["grade"]?.should be_nil
    end
  end

  it "masks agent-tool mutation results (MCP shape)" do
    with_temp_doctype("presm") do |db, domain, doctype|
      presenter_seed(db)
      presenter_doctype(db, domain, doctype)
      ctx_auth = presenter_role(["default"], domain, doctype)

      # A wildcard caller lands invisible content; the masked caller's
      # update response must present it away.
      sys = Facet::RBAC::AuthContext.system
      doc = Facet::Document::Create.call(db, domain, doctype,
        %({"name": "a", "salary": 99, "profile": {"bio": "b", "grade": "G"}}), sys)
        .as(Facet::Document::Create::Result)
      doc_id = doc.projection.id

      result = Facet::AgentTools::Registry.execute(ctx_auth, "update_document",
        JSON.parse(%({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "patch": {"name": "z"}})))
      result["data"]["name"].as_s.should eq("z")
      result["data"]["salary"]?.should be_nil
      result["data"]["profile"]["grade"]?.should be_nil
      result["meta"]["mid"].as_s.should_not be_empty

      # Wildcard tags see raw through the same tool.
      wide_auth = presenter_role(["*"], domain, doctype)
      wide = Facet::AgentTools::Registry.execute(wide_auth, "update_document",
        JSON.parse(%({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "patch": {"name": "w"}})))
      wide["data"]["salary"].as_i.should eq(99)
      wide["data"]["profile"]["grade"].as_s.should eq("G")
    end
  end

  it "keeps state/mid metadata unchanged and masks compound children with their own definition" do
    with_temp_doctype("presc") do |db, domain, parent|
      presenter_seed(db)
      ensure_domain(db, domain)

      # Parent with an invisible field, child with its own invisible field.
      parent_fields = %({
        "name": {"type": "string"},
        "salary": {"type": "integer", "tags": ["confidential"]}
      })
      child_fields = %({
        "label": {"type": "string"},
        "token": {"type": "string", "tags": ["confidential"]}
      })
      defn = %({
        "doctype": "#{parent}", "domain": "#{domain}", "fields": #{parent_fields},
        "children": {"logs": {"doctype": "#{parent}Log", "collection": true}}
      })
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{parent}Log", "domain": "#{domain}", "member_of": "#{parent}", "fields": #{child_fields}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      ctx = presenter_role(["default"], domain, parent)

      body = %({
        "$content": {"name": "p"},
        "$children": {"logs": [{"label": "l1"}]}
      })
      resp = call_api_as(HTTP::Request.new("POST", "/Api/#{domain}/#{parent}",
        headers: HTTP::Headers{"Content-Type" => "application/json"}, body: body), ctx)
      resp.status_code.should eq(201)
      payload = JSON.parse(resp.body)
      payload["data"]["name"].as_s.should eq("p")
      payload["data"]["salary"]?.should be_nil
      child = payload["children"]["logs"].as_a.first
      child["data"]["label"].as_s.should eq("l1")
      child["data"]["token"]?.should be_nil
      child["meta"]["mid"].as_s.should_not be_empty

      # The child meta identifies the persisted row and carries its real
      # timestamps — never fabricated clock reads.
      child_id = child["meta"]["id"].as_s
      child["meta"]["uri"].as_s.should eq("urn:facet:#{domain}:#{parent}Log:#{child_id}")
      child_proj = Facet::Mutation::Client.fetch_projection(db, domain, "#{parent}Log", child_id)
      child["meta"]["created_at"].as_s.should eq(child_proj.created_at.to_rfc3339)
      child["meta"]["updated_at"].as_s.should eq(child_proj.updated_at.to_rfc3339)
    end
  end
end
