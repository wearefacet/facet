# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document"
require "../../src/doctype"
require "../../src/rbac"
require "json"

# MCP mutation attribution — the one-role-per-session audit invariant.
#
# The MCP dispatch chain builds `AuthContext.mcp`, which carries the
# URL-pinned role as `acting_role`. The document services derive the
# provenance from the auth context, so a mutation written through an MCP
# context stamps `mutations.channel = "mcp"` plus `acting_role`.
# These specs pin the stamps at the service boundary: a context built by
# `AuthContext.mcp` must land both keys on the mutation rows. Every
# authenticated channel stamps `acting_role` (the elected role — see
# `spec/mutation/provenance_spec.cr`); the MCP-specific part is the
# `channel = "mcp"` stamp with the authorize-time elected role.

# A role whose wildcard permission authorizes every action on every
# doctype — the role-only RBAC enforcement MCP relies on. `role_id` is
# the role content's bare `name` (the `ActiveRole` contract).
private def mcp_active_role : Facet::RBAC::ActiveRole
  permission = Facet::RBAC::Permission.new(action: "*", domain: "*", path: ["*"], scope: [] of String)
  Facet::RBAC::ActiveRole.new(
    role_id: "editor",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [permission],
  )
end

# Reads `(channel, acting_role)` from the mutation's provenance columns.
private def mutation_channel_role(db : DB::Connection, mutation_id : String) : {String, String?}
  db.query_one("SELECT channel, acting_role FROM mutations WHERE id = $1", mutation_id, as: {String, String?})
end

describe "MCP mutation attribution" do
  # ── AuthContext construction ───────────────────────────────────────

  it "carries the acting role on an MCP context" do
    auth = Facet::RBAC::AuthContext.mcp("acct_test", mcp_active_role, "iam.Roles.editor")
    auth.acting_role.should eq("iam.Roles.editor")
    auth.app_id.should be_nil
    auth.app_grant.should be_nil
  end

  it "leaves acting_role nil on ordinary contexts" do
    auth = Facet::RBAC::AuthContext.authenticated("acct_test", mcp_active_role)
    auth.acting_role.should be_nil
  end

  it "rejects a system principal carrying an acting role" do
    expect_raises(ArgumentError) do
      Facet::RBAC::AuthContext.new(Facet::RBAC::Principal::System.new("system"), nil, nil, "iam.Roles.editor")
    end
  end

  it "rejects an empty acting role" do
    expect_raises(ArgumentError, /empty/) do
      Facet::RBAC::AuthContext.mcp("acct_test", mcp_active_role, "")
    end
  end

  # ── Service stamping ───────────────────────────────────────────────

  it "stamps acting_role and channel=mcp on a create mutation" do
    with_temp_doctype("mcpattr") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)

      auth = Facet::RBAC::AuthContext.mcp("acct_test", mcp_active_role, "iam.Roles.editor")
      result = Facet::Document::Create.call(db, domain, doctype, %({"title": "From MCP"}), auth)
      mut_id = result.as(Facet::Document::Create::Result).mutation_id

      channel, acting_role = mutation_channel_role(db, mut_id)
      acting_role.should eq("iam.Roles.editor")
      channel.should eq("mcp")
    end
  end

  it "stamps acting_role and channel=mcp on an update mutation" do
    with_temp_doctype("mcpattrupd") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)

      auth = Facet::RBAC::AuthContext.mcp("acct_test", mcp_active_role, "iam.Roles.editor")
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Before"}), auth)
      doc_id = doc_res.as(Facet::Document::Create::Result).projection.id

      upd_res = Facet::Document::Update.call(db, domain, doctype, doc_id, %({"title": "After"}), auth)
      mut_id = upd_res.as(Facet::Document::Update::Result).mutation_id

      channel, acting_role = mutation_channel_role(db, mut_id)
      acting_role.should eq("iam.Roles.editor")
      channel.should eq("mcp")
    end
  end

  it "stamps acting_role and channel=mcp on a delete mutation" do
    with_temp_doctype("mcpattrdel") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)

      auth = Facet::RBAC::AuthContext.mcp("acct_test", mcp_active_role, "iam.Roles.editor")
      doc_res = Facet::Document::Create.call(db, domain, doctype, %({"title": "Gone"}), auth)
      doc_id = doc_res.as(Facet::Document::Create::Result).projection.id

      del_res = Facet::Document::Delete.call(db, domain, doctype, doc_id, auth)
      mut_id = del_res.as(Facet::Document::Delete::Result).mutation_id

      channel, acting_role = mutation_channel_role(db, mut_id)
      acting_role.should eq("iam.Roles.editor")
      channel.should eq("mcp")
    end
  end

  it "stamps the elected role on a session mutation" do
    with_temp_doctype("mcpattrnone") do |db, domain, doctype|
      ensure_domain(db, domain)
      schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string"}}})
      Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)

      auth = Facet::RBAC::AuthContext.authenticated("acct_test", mcp_active_role)
      result = Facet::Document::Create.call(db, domain, doctype, %({"title": "Plain"}), auth)
      mut_id = result.as(Facet::Document::Create::Result).mutation_id

      channel, acting_role = mutation_channel_role(db, mut_id)
      acting_role.should eq("iam.Roles.editor")
      channel.should eq("session")
    end
  end
end
