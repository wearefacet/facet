# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

# B-143 follow-up — the HTTP restore/rollback 200 body carries the
# service's `cascade_restored` field. The fixture mirrors the composition
# trio of `spec/audit/rollback_meta_spec.cr`: deleting the parent
# cascade-tombstones the child and the grandchild, and the restore brings
# both back. These specs pin the HTTP surface:
#
# - Restore of a cascade-deleted composition parent → 200 with the
#   existing `{data, meta}` shape plus a non-empty `cascade_restored`
#   array that carries the child ids.
# - A plain rollback → 200 with `cascade_restored: []`, even when the
#   document owns composition children.

CAS_DOMAIN = "audit"

# Builds the composition doctype trio: parent (aggregate root) → child →
# grandchild. Every link is a `member_of` ownership, so deleting the
# parent cascades a tombstone onto both levels. Returns the doctype names.
private def cas_build_trio(db)
  restore_seeded_baseline(db)
  ensure_domain(db, CAS_DOMAIN)

  suffix = unique_suffix(6)
  parent_dt = "CasPar#{suffix}"
  child_dt = "CasChd#{suffix}"
  grand_dt = "CasGrd#{suffix}"

  parent_defn = %({"doctype": "#{parent_dt}", "domain": "#{CAS_DOMAIN}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  child_defn = %({"doctype": "#{child_dt}", "domain": "#{CAS_DOMAIN}", "member_of": "#{parent_dt}", "fields": {"label": {"type": "string"}}, "children": {"items": {"doctype": "#{grand_dt}", "collection": true}}})
  result = Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  grand_defn = %({"doctype": "#{grand_dt}", "domain": "#{CAS_DOMAIN}", "member_of": "#{child_dt}", "fields": {"label": {"type": "string"}}})
  result = Facet::Document::Create.call(db, "core", "DocType", grand_defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)

  {parent_dt, child_dt, grand_dt}
end

private def cas_create(db, doctype, content, parent_id = nil)
  overrides = parent_id ? {"parent_id" => JSON::Any.new(parent_id)} : nil
  result = Facet::Document::Create.call(db, CAS_DOMAIN, doctype, content, Facet::RBAC::AuthContext.system, meta_overrides: overrides)
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result)
end

private def cas_delete(db, doctype, doc_id) : Nil
  result = Facet::Document::Delete.call(db, CAS_DOMAIN, doctype, doc_id, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Delete::Result)
end

private def cas_post_restore(domain : String, doctype : String, doc_id : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("POST", "/Api/#{domain}/#{doctype}/#{doc_id}/restore"))
end

describe "Audit cascade_restored HTTP response field" do
  it "restore of a cascade-deleted composition parent returns 200 with cascade_restored entries" do
    parent_dt = ""
    child_dt = ""
    grand_dt = ""
    parent_id = ""
    child_id = ""
    grand_id = ""
    with_db do |db|
      parent_dt, child_dt, grand_dt = cas_build_trio(db)
      parent = cas_create(db, parent_dt, %({"name": "P"}))
      child = cas_create(db, child_dt, %({"label": "C"}), parent.projection.id)
      grand = cas_create(db, grand_dt, %({"label": "G"}), child.projection.id)
      cas_delete(db, parent_dt, parent.projection.id)
      parent_id = parent.projection.id
      child_id = child.projection.id
      grand_id = grand.projection.id
    end

    resp = cas_post_restore(CAS_DOMAIN, parent_dt, parent_id)
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    # The existing single-document shape stays intact.
    body["data"]["name"].as_s.should eq("P")
    body["meta"]["id"].as_s.should eq(parent_id)
    body["meta"]["mid"].as_s.empty?.should be_false

    # The additive field: both cascade-restored children, each with its
    # own snapshot mutation id.
    entries = body["cascade_restored"].as_a
    entries.size.should eq(2)
    doc_ids = entries.map(&.["doc_id"].as_s)
    doc_ids.should contain(child_id)
    doc_ids.should contain(grand_id)
    entry = entries.find { |e| e["doc_id"].as_s == child_id } || raise "missing child entry"
    entry["domain"].as_s.should eq(CAS_DOMAIN)
    entry["doc_type"].as_s.should eq(child_dt)
    entry["mut_id"].as_s.empty?.should be_false
  end

  it "plain rollback returns cascade_restored: []" do
    parent_dt = ""
    parent_id = ""
    create_mid = ""
    with_db do |db|
      parent_dt, _child_dt, _grand_dt = cas_build_trio(db)
      parent = cas_create(db, parent_dt, %({"name": "P"}))
      parent_id = parent.projection.id
      create_mid = parent.mutation_id
    end

    request = HTTP::Request.new(
      "POST",
      "/Api/#{CAS_DOMAIN}/#{parent_dt}/#{parent_id}/rollback",
      HTTP::Headers{"Content-Type" => "application/json"},
      body: %({"mutation_id": "#{create_mid}"}),
    )
    resp = call_api(request)
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["data"]["name"].as_s.should eq("P")
    body["meta"]["id"].as_s.should eq(parent_id)
    body["cascade_restored"].as_a.should be_empty
  end
end
