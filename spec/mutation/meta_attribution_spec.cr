# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/mutation/client"
require "../../src/mutation/provenance"
require "../../src/util/script_helpers"

# Mutation attribution metadata.
#
# The typed provenance columns on `mutations` carry two structured groups:
# - `channel` (+ `app` / `api_key` / `acting_role`) — how the request
#   authenticated, derived from the request's `AuthContext`.
# - `cause_*` — the direct trigger (kind/name/event/source/parent/trace).
#
# These specs pin the column values at the `Mutation::Client` boundary.
private def mcp_wildcard_role
  permission = Facet::RBAC::Permission.new(action: "*", domain: "*", path: ["*"], scope: [] of String)
  Facet::RBAC::ActiveRole.new(
    role_id: "iam.Roles.editor",
    visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
    permissions: [permission],
  )
end

describe "Mutation::Client meta attribution" do
  it "persists channel=mcp with acting_role and a request cause" do
    with_db do |db|
      mut_id = Facet::Mutation::Client.create(
        db, "crm", "Contact",
        content: %({"name": "Alice"}),
        actioner_id: "account_123",
        provenance: Facet::Mutation::Provenance.from(
          Facet::RBAC::AuthContext.mcp("account_123", mcp_wildcard_role, "iam.Roles.editor")
        ),
      )
      mut_id.should_not be_empty

      row = db.query_one(
        "SELECT channel, acting_role, cause_kind, cause_trace FROM mutations WHERE id = $1", mut_id, as: {String, String?, String, String}
      )
      row[0].should eq("mcp")
      row[1].should eq("iam.Roles.editor")
      row[2].should eq("request")
      row[3].should eq(mut_id)
    end
  end

  it "stamps every mutation with channel and cause trace (no empty meta)" do
    with_db do |db|
      mut_id = Facet::Mutation::Client.create(db, "crm", "Contact")
      row = db.query_one(
        "SELECT channel, cause_kind, cause_trace FROM mutations WHERE id = $1", mut_id, as: {String, String, String}
      )
      row[0].should eq("internal")
      row[1].should eq("request")
      row[2].should eq(mut_id)
    end
  end

  it "persists app and api_key together on the app_api_key channel" do
    with_db do |db|
      doc_id = Facet::Mutation::Client.create(db, "crm", "Contact", content: %({"name": "Carol"}))
      mut_id = Facet::Mutation::Client.update(
        db, "crm", "Contact", doc_id,
        diff_json: %({"set": [{"path": ["name"], "value": "Carla"}], "unset": []}),
        actioner_id: "account_123",
        provenance: Facet::Mutation::Provenance.new(
          Facet::Mutation::Channel::AppApiKey, app: "app_456", api_key: "01JKEY"),
        cause: Facet::Mutation::Cause.root(Facet::Mutation::CauseKind::Request, event: "patched"),
      )
      row = db.query_one(
        "SELECT channel, app, api_key, cause_event FROM mutations WHERE id = $1", mut_id, as: {String, String?, String?, String?}
      )
      row[0].should eq("app_api_key")
      row[1].should eq("app_456")
      row[2].should eq("01JKEY")
      row[3].should eq("patched")
    end
  end

  it "pins an explicit mutation id and links a child cause to it" do
    with_db do |db|
      parent_id = Facet::Util::ScriptHelpers.ulid
      mut_id = Facet::Mutation::Client.create(
        db, "crm", "Contact",
        content: %({"name": "Nested"}),
        cause: Facet::Mutation::Cause.new(
          kind: Facet::Mutation::CauseKind::Action,
          name: "hire", event: "hired",
          parent: parent_id, trace: parent_id,
        ),
        mutation_id: parent_id,
      )
      mut_id.should eq(parent_id)

      row = db.query_one(
        "SELECT cause_kind, cause_parent, cause_trace FROM mutations WHERE id = $1", mut_id, as: {String, String?, String}
      )
      row[0].should eq("action")
      row[1].should eq(parent_id)
      row[2].should eq(parent_id)
    end
  end
end
