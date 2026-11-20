# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/rbac/auth_context"
require "../../src/agent_tools"
require "../support/doctype_helper"
require "../support/iam_helper"
require "../support/agent_tools_helper"
require "../support/oauth_helper"

# MCP tool registry (`doc/backend/mcp.md`).
#
# Acceptance:
# - `tools/list` is role-filtered through `list_for`.
# - A system principal never receives a listing (D6 — fail closed).
# - `mark_stale` bumps the generation; dispatch observes the bump and can
#   signal `list_changed` to open sessions.
# - `ping` executes under a Real principal and reports the mounted role.
# - No catalogue entry takes the `read_skill` name — every surface's
#   tools/call intercepts it before the registry (see mcp.md).
describe "AgentTools" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "lists tools for an authenticated context" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

      tools = Facet::AgentTools.list_for(ctx)
      names = tools.map(&.name)
      names.should contain("ping")
    end
  end

  it "shows call_action to a role holding only the wildcard action line" do
    with_db do |db|
      # Enforcement accepts `*` for named actions; the listing gate must
      # agree (visibility that contradicts enforcement hides a usable tool).
      ctx = build_context_with_permissions(db, [{"action" => "*", "on" => "*.*"}])
      names = Facet::AgentTools.list_for(ctx).map(&.name)
      names.should contain("call_action")
    end
  end

  it "reports the caller's identity, manifest, and tags on whoami" do
    with_db do |db|
      # viewer: read-only manifest, default tags.
      viewer = build_context(db, "iam.Roles.viewer")
      result = Facet::AgentTools.call(viewer, "whoami", JSON.parse("{}"))
      result.as_h["account"].as_h["id"].as_s.should eq(viewer.account_id)
      result.as_h["account"].as_h["display_name"].as_s.should_not be_empty
      result.as_h["role"].as_s.should eq("viewer")
      perms = result.as_h["permissions"].as_h
      perms["*.*"].as_a.map(&.as_s).should contain("read")
      result.as_h["visible_tags"].as_a.map(&.as_s).should eq(["default"])

      # admin: wildcard permissions, the all-seeing tag.
      admin = build_context(db, "iam.Roles.admin")
      result = Facet::AgentTools.call(admin, "whoami", JSON.parse("{}"))
      result.as_h["role"].as_s.should eq("admin")
      result.as_h["permissions"].as_h["*.*"].as_a.map(&.as_s).should contain("*")
      result.as_h["visible_tags"].as_a.map(&.as_s).should eq(["*"])
    end
  end

  it "returns no tools for a system principal (fail closed)" do
    ctx = Facet::RBAC::AuthContext.system
    Facet::AgentTools.list_for(ctx).should be_empty
  end

  it "bumps the generation on mark_stale so dispatch can emit list_changed" do
    before = Facet::AgentTools.current_generation
    Facet::AgentTools.mark_stale
    Facet::AgentTools.current_generation.should be > before
  end

  it "executes ping with the mounted role and acting account" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

      result = Facet::AgentTools.call(ctx, "ping", JSON.parse("{}"))
      # `ActiveRole#role_id` is the role's bare `name` (see
      # `from_projection_content`); the qualified projection id is what the
      # URL pins and the token claims.
      result.as_h["role"].as_s.should eq("editor")
      result.as_h["account"].as_s.should eq(account_id)
      result.as_h["server"].as_s.should eq("facet")
    end
  end

  it "reserves the read_skill name for the per-surface skill loader" do
    # Every surface's tools/call intercepts `read_skill` before the
    # registry (the surface is a property of the mount, see mcp.md); a
    # catalogue entry with that name would be silently unreachable.
    Facet::AgentTools::Registry.entries.map(&.name).should_not contain("read_skill")
  end

  it "raises ToolError for an unknown tool" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.editor").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

      ex = expect_raises(Facet::AgentTools::ToolError, /Unknown tool/) do
        Facet::AgentTools.call(ctx, "delete_everything", JSON.parse("{}"))
      end
      # Every raise site carries a machine-readable data payload — unknown
      # tools included.
      ex.data.not_nil!.as_h["reason"].as_s.should eq("unknown_tool")
      ex.data.not_nil!.as_h["tool"].as_s.should eq("delete_everything")
    end
  end

  it "rejects unknown argument keys on every tool" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

      # One bogus key per registered entry — every tool rejects a key its
      # handler does not read, before dispatch, on every surface.
      Facet::AgentTools::Registry.entries.each do |entry|
        ex = expect_raises(Facet::AgentTools::InvalidParams, /bogus/) do
          Facet::AgentTools.call(ctx, entry.name, JSON.parse(%({"bogus_key": 1})))
        end
        ex.message.not_nil!.should contain("bogus_key")
        ex.message.not_nil!.should contain(entry.name)
      end
    end
  end

  it "serves the fields argument once it is real (Step 9 regression)" do
    with_db do |db|
      ctx = build_context(db, "iam.Roles.viewer")

      # `fields` is now a read argument; a bogus key still raises.
      ex = expect_raises(Facet::AgentTools::InvalidParams, /'bogus'/) do
        Facet::AgentTools.call(ctx, "list_documents", JSON.parse(%({"domain": "x", "doctype": "Y", "bogus": 1})))
      end
      ex.message.not_nil!.should contain("domain")
      ex.data.not_nil!.as_h["reason"].as_s.should eq("unknown_argument")
      ex.data.not_nil!.as_h["argument"].as_s.should eq("bogus")
    end
  end

  it "advertises every tool definition with name, description, and input schema" do
    with_db do |db|
      account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")
      role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
      active_role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
      ctx = Facet::RBAC::AuthContext.authenticated(account_id, active_role)

      Facet::AgentTools.list_for(ctx).each do |tool|
        tool.name.should_not be_empty
        tool.description.should_not be_empty
        tool.input_schema.as_h["type"].as_s.should eq("object")
      end
    end
  end
end
