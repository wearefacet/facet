# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

describe Facet::Document::CreateWithChildren do
  it "creates a parent document with children atomically" do
    with_temp_doctype("cwcbasic") do |db, domain, doctype|
      ensure_domain(db, domain)

      # Create parent doctype with a child relationship
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)

      # Create child doctype
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      # Compound create
      body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Child A"}, {"label": "Child B"}]}})
      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::CreateWithChildren::Result)
      cwc = result.as(Facet::Document::CreateWithChildren::Result)

      cwc.projection.content["name"].as_s.should eq("Parent")
      cwc.children.keys.should contain("items")
      cwc.children["items"].size.should eq(2)
      cwc.children["items"][0].doc_type.should eq(child_dt)
      cwc.children["items"][1].doc_type.should eq(child_dt)

      # The child result carries the identity and timestamps of the
      # persisted projection — the responder echoes them verbatim.
      cwc.children["items"].each do |child|
        proj = Facet::Mutation::Client.fetch_projection(db, domain, child_dt, child.id)
        child.created_at.should eq(proj.created_at)
        child.updated_at.should eq(proj.updated_at)
      end
    end
  end

  it "creates a plain document when body has no $content key (backward compat)" do
    with_temp_doctype("cwcplain") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, %({"name": "Plain"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::Document::CreateWithChildren::Result)
      cwc = result.as(Facet::Document::CreateWithChildren::Result)
      cwc.projection.content["name"].as_s.should eq("Plain")
      cwc.children.should be_empty
    end
  end

  it "returns 422 for invalid JSON body" do
    with_temp_doctype("cwcjson") do |db, domain, doctype|
      ensure_domain(db, domain)
      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, "not json", Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Invalid JSON")
    end
  end

  it "returns 422 when $content is not a JSON object" do
    with_temp_doctype("cwccont") do |db, domain, doctype|
      ensure_domain(db, domain)
      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, %({"$content": "not-an-object"}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("'$content' must be a JSON object")
    end
  end

  it "returns 422 for unknown child relationship" do
    with_temp_doctype("cwcunk") do |db, domain, doctype|
      ensure_domain(db, domain)
      defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"name": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)

      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, %({"$content": {"name": "P"}, "$children": {"unknown_rel": [{"label": "X"}]}}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Unknown child relationship")
    end
  end

  it "returns 422 when a child body is not a JSON object" do
    with_temp_doctype("cwcchild") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, %({"$content": {"name": "P"}, "$children": {"items": ["not-an-object"]}}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("must be a JSON object")
    end
  end

  it "returns 422 when $children value is not an array" do
    with_temp_doctype("cwcrel") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, %({"$content": {"name": "P"}, "$children": {"items": "not-an-array"}}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("must be an array")
    end
  end

  it "returns 404 when the parent doctype does not exist" do
    with_db do |db|
      result = Facet::Document::CreateWithChildren.call(db, "nonexistent", "Unknown", %({"$content": {"name": "P"}}), Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(404)
      err.message.should contain("Unknown doctype")
    end
  end

  it "returns error when a child fails validation" do
    with_temp_doctype("cwcroll") do |db, domain, doctype|
      ensure_domain(db, domain)
      child_dt = "#{doctype}Child"
      parent_defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, "search": "{{ display_name }}", "fields": {"name": {"type": "string"}}, "children": {"items": {"doctype": "#{child_dt}", "collection": true}}})
      Facet::Document::Create.call(db, "core", "DocType", parent_defn, Facet::RBAC::AuthContext.system)

      # Child doctype with a required field
      child_defn = %({"doctype": "#{child_dt}", "domain": "#{domain}", "member_of": "#{doctype}", "fields": {"label": {"type": "string", "required": true}}})
      Facet::Document::Create.call(db, "core", "DocType", child_defn, Facet::RBAC::AuthContext.system)

      # Second child is missing required field — should error
      body = %({"$content": {"name": "Parent"}, "$children": {"items": [{"label": "Valid"}, {"label_missing": true}]}})
      result = Facet::Document::CreateWithChildren.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(422)
      err.message.should contain("Failed to create child")
    end
  end
end
