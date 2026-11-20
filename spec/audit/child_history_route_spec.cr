# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-197 — the nested child history route serves the relationship-name
# shape only. The raw `:child` segment resolves through the parent
# definition's `children` map; the child-doctype-name shape and an
# unknown segment both miss the map and answer `404` naming the
# unresolvable segment. Before the fix, an unresolvable segment flowed
# into `Audit::List` as a doctype filter and answered `200` with an
# empty page.

require "../spec_helper"
require "json"
require "../../src/audit"
require "../../src/document"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# Seeds one parent doctype with a `items` child relationship, one parent
# document, and one child document under it. Returns the doctype names
# and the document ids.
private def chr_seed_pair(db, suffix : String)
  ensure_domain(db, "audit")

  parent_dt = "ChrPar#{suffix}"
  child_dt = "ChrChd#{suffix}"

  parent_defn = %({"doctype": "#{parent_dt}", "domain": "audit", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  child_defn = %({"doctype": "#{child_dt}", "domain": "audit", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  parent = Facet::Document::Create.call(db, "audit", parent_dt, %({"name": "P"}), Facet::RBAC::AuthContext.system)
  parent.should be_a(Facet::Document::Create::Result)
  parent_id = parent.as(Facet::Document::Create::Result).projection.id

  child = Facet::Document::Create.call(db, "audit", child_dt, %({"label": "C"}), Facet::RBAC::AuthContext.system,
    meta_overrides: {"parent_id" => JSON::Any.new(parent_id)})
  child.should be_a(Facet::Document::Create::Result)
  child_id = child.as(Facet::Document::Create::Result).projection.id

  {parent_dt, child_dt, parent_id, child_id}
end

private def chr_history(parent_dt : String, parent_id : String, segment : String, child_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/Api/audit/#{parent_dt}/#{parent_id}/#{segment}/#{child_id}/history"))
end

describe "Child history route resolves the relationship name (B-197)" do
  it "returns the child rows for the relationship-name segment" do
    with_db do |db|
      parent_dt, child_dt, parent_id, child_id = chr_seed_pair(db, unique_suffix(6))

      resp = chr_history(parent_dt, parent_id, "items", child_id)
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      rows = body["data"].as_a
      rows.size.should be >= 1
      rows.all? { |r| r["doc_type"].as_s == child_dt }.should be_true
      body["meta"]["count"].as_i.should be >= 1
    end
  end

  it "answers 404 for the child-doctype-name segment" do
    with_db do |db|
      parent_dt, child_dt, parent_id, child_id = chr_seed_pair(db, unique_suffix(6))

      resp = chr_history(parent_dt, parent_id, child_dt, child_id)
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown child '#{child_dt}'")
    end
  end

  it "answers 404 for an unknown segment" do
    with_db do |db|
      parent_dt, _child_dt, parent_id, child_id = chr_seed_pair(db, unique_suffix(6))

      resp = chr_history(parent_dt, parent_id, "nosuchrel", child_id)
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown child 'nosuchrel'")
    end
  end

  it "answers 404 when the parent doctype does not resolve" do
    with_db do |db|
      _parent_dt, _child_dt, _parent_id, child_id = chr_seed_pair(db, unique_suffix(6))

      resp = chr_history("ChrNope", "01AAAAAAAAAAAAAAAAAAAAAAAA", "items", child_id)
      assert_http_status(resp, 404)
      JSON.parse(resp.body)["error"].as_s.should contain("Unknown doctype: audit.ChrNope")
    end
  end
end
