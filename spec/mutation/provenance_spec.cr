# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

# Provenance + cause — the audit metadata stored on the typed provenance
# columns of the `mutations` table.
#
# `Mutation::Provenance` derives the channel (session / oauth_app /
# app_api_key / api_key / mcp / internal) from the request's `AuthContext`.
# `Mutation::Cause` describes the direct trigger, one hop per row, with
# `parent` linking to the causing mutation and `trace` grouping the whole
# causal cluster.

private def wildcard_role : Facet::RBAC::ActiveRole
  permission = Facet::RBAC::Permission.new(action: "*", domain: "*", path: ["*"], scope: [] of String)
  Facet::RBAC::ActiveRole.new(
    role_id: "member",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [permission],
  )
end

describe Facet::Mutation::Provenance do
  # ── Channel derivation ────────────────────────────────────────────────

  it "derives internal for a system principal" do
    prov = Facet::Mutation::Provenance.from(Facet::RBAC::AuthContext.system)
    prov.channel.should eq(Facet::Mutation::Channel::Internal)
    prov.app.should be_nil
    prov.api_key.should be_nil
    prov.acting_role.should be_nil
  end

  it "derives session for a plain authenticated principal" do
    prov = Facet::Mutation::Provenance.from(Facet::RBAC::AuthContext.authenticated("acct_1", wildcard_role))
    prov.channel.should eq(Facet::Mutation::Channel::Session)
    prov.acting_role.should eq("iam.Roles.member")
  end

  it "stamps no acting role for a synthetic marker role" do
    prov = Facet::Mutation::Provenance.from(Facet::RBAC::AuthContext.denied)
    prov.channel.should eq(Facet::Mutation::Channel::Session)
    prov.acting_role.should be_nil
  end

  it "derives oauth_app for an app-scoped context without a key" do
    grant = app_grant
    prov = Facet::Mutation::Provenance.from(
      Facet::RBAC::AuthContext.app_scoped("acct_1", wildcard_role, grant, "app.App.01J")
    )
    prov.channel.should eq(Facet::Mutation::Channel::OauthApp)
    prov.app.should eq("app.App.01J")
    prov.api_key.should be_nil
    prov.acting_role.should eq("iam.Roles.member")
  end

  it "derives app_api_key for an app-owned key (app id + key id)" do
    grant = app_grant
    prov = Facet::Mutation::Provenance.from(
      Facet::RBAC::AuthContext.app_scoped("acct_1", wildcard_role, grant, "app.App.01J", "01JKEY")
    )
    prov.channel.should eq(Facet::Mutation::Channel::AppApiKey)
    prov.app.should eq("app.App.01J")
    prov.api_key.should eq("01JKEY")
    prov.acting_role.should eq("iam.Roles.member")
  end

  it "derives api_key for a self-service key" do
    prov = Facet::Mutation::Provenance.from(
      Facet::RBAC::AuthContext.api_key("acct_1", wildcard_role, "01JKEY")
    )
    prov.channel.should eq(Facet::Mutation::Channel::ApiKey)
    prov.api_key.should eq("01JKEY")
    prov.app.should be_nil
    prov.acting_role.should eq("iam.Roles.member")
  end

  it "derives mcp for an MCP context" do
    prov = Facet::Mutation::Provenance.from(
      Facet::RBAC::AuthContext.mcp("acct_1", wildcard_role, "iam.Roles.editor")
    )
    prov.channel.should eq(Facet::Mutation::Channel::Mcp)
    prov.acting_role.should eq("iam.Roles.editor")
  end

  it "maps the channel to its stored label" do
    prov = Facet::Mutation::Provenance.from(
      Facet::RBAC::AuthContext.api_key("acct_1", wildcard_role, "01JKEY")
    )
    prov.channel.json_value.should eq("api_key")
    Facet::Mutation::Channel::OauthApp.json_value.should eq("oauth_app")
    Facet::Mutation::Channel::AppApiKey.json_value.should eq("app_api_key")
  end

  # ── AuthContext exclusivity ───────────────────────────────────────────

  it "rejects an api key combined with an acting role" do
    expect_raises(ArgumentError) do
      Facet::RBAC::AuthContext.new(
        Facet::RBAC::Principal::Real.new("acct_1", wildcard_role),
        nil, nil, "iam.Roles.editor", "01JKEY",
      )
    end
  end

  # ── Cause ─────────────────────────────────────────────────────────────

  it "resolves a nil trace to the mutation's own id" do
    cause = Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Action, name: "hire")
    resolved = cause.resolve("01JMUT")
    resolved.trace.should eq("01JMUT")
    resolved.parent.should be_nil
  end

  it "keeps an inherited trace through resolve" do
    cause = Facet::Mutation::Cause.new(
      kind: Facet::Mutation::CauseKind::Action, name: "hire", trace: "01JROOT",
    )
    cause.resolve("01JMUT").trace.should eq("01JROOT")
  end

  it "binds parent and inherits trace for a child cause" do
    root = Facet::Mutation::Cause.root(
      Facet::Mutation::CauseKind::Action,
      name: "hire", event: "hired", source: "crm.Employee:01JDOC",
    ).resolve("01JROOT")
    child = root.child_of("01JROOT")

    child.kind.should eq(root.kind)
    child.name.should eq(root.name)
    child.event.should eq(root.event)
    child.source.should eq(root.source)
    child.parent.should eq("01JROOT")
    child.trace.should eq("01JROOT")
  end

  it "builds a shared trace for a nested service under a nested cause" do
    # A create driven by an action's Lua: the cause already carries the
    # action trace; the nested create's own writes inherit that trace and
    # point at the nested create's own mutation id.
    nested = Facet::Mutation::Cause.new(
      kind: Facet::Mutation::CauseKind::Action,
      name: "hire", event: "hired",
      parent: "01JROOT", trace: "01JROOT",
    )
    grandchild = nested.child_of("01JNESTED")
    grandchild.trace.should eq("01JROOT")
    grandchild.parent.should eq("01JNESTED")
  end

  it "serializes the cause with nil keys omitted" do
    cause = Facet::Mutation::Cause.root(
      Facet::Mutation::CauseKind::Action, name: "hire", event: "hired").resolve("01JMUT")
    json = cause.to_json_any.as_h
    json["kind"].as_s.should eq("action")
    json["name"].as_s.should eq("hire")
    json["event"].as_s.should eq("hired")
    json["source"]?.should be_nil
    json["parent"]?.should be_nil
    json["trace"].as_s.should eq("01JMUT")
  end

  it "serializes an assistant cause with kind 'assistant'" do
    cause = Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Assistant).resolve("01JMUT")
    json = cause.to_json_any.as_h
    json["kind"].as_s.should eq("assistant")
    json["name"]?.should be_nil
    json["trace"].as_s.should eq("01JMUT")
  end

  it "refuses to serialize an unresolved cause" do
    cause = Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Request)
    expect_raises(ArgumentError) { cause.to_json_any }
  end

  it "round-trips every cause kind through from_json_value" do
    kinds = {
      Facet::Mutation::CauseKind::Request, Facet::Mutation::CauseKind::Action,
      Facet::Mutation::CauseKind::HookEvent, Facet::Mutation::CauseKind::HookSchedule,
      Facet::Mutation::CauseKind::Replication, Facet::Mutation::CauseKind::Cascade,
      Facet::Mutation::CauseKind::Rollback, Facet::Mutation::CauseKind::Migration,
      Facet::Mutation::CauseKind::PeriodicSnapshot, Facet::Mutation::CauseKind::WebhookTest,
      Facet::Mutation::CauseKind::Assistant, Facet::Mutation::CauseKind::Compaction,
    }
    kinds.each do |kind|
      parsed = Facet::Mutation::CauseKind.from_json_value(kind.json_value)
      parsed.should eq(kind), "expected #{kind.json_value} to round-trip"
    end
  end

  it "returns nil from from_json_value on an unknown value" do
    Facet::Mutation::CauseKind.from_json_value("nonsense").should be_nil
  end
end

# Builds an empty-but-valid EffectiveScope (no grants to resolve).
private def app_grant : Facet::RBAC::EffectiveScope
  scope = Facet::RBAC::AppScope.from_content(
    "app.App.01J",
    JSON.parse(%({"id": "app.App.01J", "grants": []})),
  )
  Facet::RBAC::GrantResolver.resolve(scope, wildcard_role)
end
