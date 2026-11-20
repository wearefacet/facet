# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/agent_tools_helper"

# `call_action` tool (MCP tools plan, step 5 — write group).
#
# Acceptance:
# - Happy path: executes a named action and returns the updated document.
# - Unknown action → NotFound (the doctype definition has no such action).
# - Bad args → InvalidParams with the action's arg diagnostics.
# - RBAC denial on a missing named-action permission → RbacDenied.
# - `call_action` is visible only when the role holds a named-action grant.
describe "AgentTools::CallAction" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "executes a named action and returns the updated document" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpact")
      ctx = build_context(db, "iam.Roles.admin")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      result = call_tool(ctx, "call_action", %({
        "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}",
        "action": "promote", "args": {"new_title": "Globex"}
      }))
      result.as_h["data"].as_h["name"].as_s.should eq("Globex")
      result.as_h["meta"].as_h["mid"].as_s.should_not be_empty
    end
  end

  it "raises NotFound for an unknown action" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpact")
      ctx = build_context(db, "iam.Roles.admin")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      ex = expect_raises(Facet::AgentTools::NotFound, /ghost_action/) do
        call_tool(ctx, "call_action", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "action": "ghost_action"
        }))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("not_found")
    end
  end

  it "raises InvalidParams when a required action arg is missing" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpact")
      ctx = build_context(db, "iam.Roles.admin")

      created = call_tool(ctx, "create_document", %({"domain": "#{domain}", "doctype": "#{doctype}", "content": {"name": "Acme"}}))
      doc_id = created.as_h["meta"].as_h["id"].as_s

      # `promote` requires `new_title` — omit it.
      ex = expect_raises(Facet::AgentTools::InvalidParams) do
        call_tool(ctx, "call_action", %({"domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}", "action": "promote", "args": {}}))
      end
      # Surface the per-arg diagnostic.
      details = ex.data.not_nil!.as_h["details"].as_a
      details.any? { |d| d.as_h["field"].as_s == "new_title" }.should be_true
    end
  end

  it "raises RbacDenied when the role has no named-action permission" do
    with_db do |db|
      domain, doctype = build_simple_doctype(db, "mcpact")
      # viewer holds only `read` — no named-action permission line at all,
      # so `call_action` is hidden from `tools/list` and the WriteEnforcer
      # authorizer rejects the action call with 403.
      ctx = build_context(db, "iam.Roles.viewer")

      # Pre-create the document as system — the viewer can read it but cannot
      # act on it.
      doc_id = create_doc_via_service(db, domain, doctype, %({"name": "Acme"}))

      ex = expect_raises(Facet::AgentTools::RbacDenied) do
        call_tool(ctx, "call_action", %({
          "domain": "#{domain}", "doctype": "#{doctype}", "doc_id": "#{doc_id}",
          "action": "promote", "args": {"new_title": "Globex"}
        }))
      end
      ex.data.not_nil!.as_h["reason"].as_s.should eq("rbac_denied")
    end
  end

  it "is hidden from a role with no named-action grant" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer") # read-only, no named actions
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should_not contain("call_action")
    end
  end

  it "is visible to a role holding a named-action permission" do
    with_db do |db|
      # admin holds `*` on `*.*` plus `mfa_disable` on `iam.Account` — both
      # lines satisfy the action gate (the wildcard line alone already does;
      # the `mfa_disable` line is not what unlocks the tool).
      ctx = build_context(db, "iam.Roles.admin")
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should contain("call_action")
    end
  end

  it "is visible to a role holding only the wildcard action line" do
    with_db do |db|
      # Enforcement (Permission#matches_action?) accepts `*` for any named
      # action, so a role whose single permission is {"action": "*",
      # "on": "*.*"} can execute every action — the listing must agree and
      # show the tool.
      ctx = build_context_with_permissions(db, [{"action" => "*", "on" => "*.*"}])
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should contain("call_action")
    end
  end

  it "is hidden from a role holding only a reserved CRUD action" do
    with_db do |db|
      # A role with only `read` (no named action, no `*`) still cannot see
      # the tool — the wildcard never widens the gate to CRUD-only roles.
      ctx = build_context_with_permissions(db, [{"action" => "read", "on" => "*.*"}])
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should_not contain("call_action")
    end
  end
end
