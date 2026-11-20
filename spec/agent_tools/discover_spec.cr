# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# Discover tool group (MCP tools plan, step 2).
#
# Acceptance:
# - `list_domains` returns live domains, excludes drafts.
# - `list_doctypes` lists one domain's doctypes; unknown domain → NotFound.
# - `get_schema` returns fields, actions with typed args, children, scopes;
#   unknown doctype → NotFound.
# - Missing/invalid arguments → InvalidParams with the argument named.
describe "AgentTools::Discover" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "lists live domains" do
    with_db do |db|
      ensure_domain(db, "crm")
      ctx = build_context(db)

      result = call_tool(ctx, "list_domains", "{}")
      names = result.as_h["domains"].as_a.map(&.as_h["name"].as_s)
      names.should contain("crm")
    end
  end

  it "excludes draft domains from list_domains" do
    with_db do |db|
      Facet::Mutation::Client.create(db, "core", "Domain", doc_id: "_draft_x", content: %({"draft": true}), actioner_id: "system")
      ctx = build_context(db)

      result = call_tool(ctx, "list_domains", "{}")
      names = result.as_h["domains"].as_a.map(&.as_h["name"].as_s)
      names.should_not contain("_draft_x")
    end
  end

  it "lists doctypes of a domain" do
    with_db do |db|
      create_doctype_from_data("crm.facet-domain/doctypes/crm.Deal.yml")
      ctx = build_context(db)

      result = call_tool(ctx, "list_doctypes", %({"domain": "crm"}))
      names = result.as_h["doctypes"].as_a.map(&.as_h["name"].as_s)
      names.should contain("crm.Deal")
    end
  end

  it "raises NotFound for an unknown domain in list_doctypes" do
    with_db do |db|
      ctx = build_context(db)
      ex = expect_raises(Facet::AgentTools::NotFound, /Unknown domain/) do
        call_tool(ctx, "list_doctypes", %({"domain": "nope"}))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("not_found")
    end
  end

  it "raises InvalidParams naming the missing argument" do
    with_db do |db|
      ctx = build_context(db)
      expect_raises(Facet::AgentTools::InvalidParams, /'domain'/) do
        call_tool(ctx, "list_doctypes", "{}")
      end
    end
  end

  it "returns the full schema with fields and actions" do
    with_db do |db|
      create_doctype_from_data("hr.facet-domain/doctypes/hr.Employee.yml")
      ctx = build_context(db)

      result = call_tool(ctx, "get_schema", %({"domain": "hr", "doctype": "Employee"}))
      schema = result.as_h
      schema["domain"].as_s.should eq("hr")
      schema["doctype"].as_s.should eq("Employee")
      schema["fields"].as_h.should_not be_empty
    end
  end

  it "exposes named actions with typed args in get_schema" do
    with_db do |db|
      create_doctype_from_data("hr.facet-domain/doctypes/hr.Employee.yml")
      ctx = build_context(db)

      result = call_tool(ctx, "get_schema", %({"domain": "hr", "doctype": "Employee"}))
      actions = result.as_h["actions"].as_h
      actions.should_not be_empty
      # Every action exposes its `args` map (possibly empty).
      actions.each_value do |action|
        action.as_h.has_key?("args").should be_true
      end
    end
  end

  it "exposes member_of on the child side and omits it on the parent side" do
    with_db do |db|
      domain, parent, child = build_parent_child_doctypes(db, "mcpread")
      ctx = build_context(db)

      child_schema = call_tool(ctx, "get_schema", %({"domain": "#{domain}", "doctype": "#{child}"})).as_h
      child_schema["member_of"].as_s.should eq(parent)

      parent_schema = call_tool(ctx, "get_schema", %({"domain": "#{domain}", "doctype": "#{parent}"})).as_h
      parent_schema.has_key?("member_of").should be_false
    end
  end

  it "raises NotFound for an unknown doctype in get_schema" do
    with_db do |db|
      ctx = build_context(db)
      expect_raises(Facet::AgentTools::NotFound, /Unknown doctype/) do
        call_tool(ctx, "get_schema", %({"domain": "hr", "doctype": "Ghost"}))
      end
    end
  end
end
