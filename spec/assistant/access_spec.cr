# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/assistant/access"

# Availability gate for the workspace assistant (`Assistant::Access`).
#
# Access rides the one active role: the auth-context gate reads
# `assistant_access` off `principal.active_role` alone — a role merely
# held by the account never enables the assistant. The budget stays the
# one account-wide aggregation (MAX over held enabling roles, unset =
# unlimited). Roles and accounts come in through the mutation client —
# the same path `seed_test_roles` uses. `id` is the bare role name; the
# document id becomes the qualified `iam.Roles.<id>`. The per-example
# truncation wipes every projection, so the seed case re-runs
# `Doctype::Seed.seed` itself.

# Inserts an `iam.Roles` document directly through the mutation client.
private def create_access_role(db, id : String, extra : Hash(String, JSON::Any)) : Nil
  permissions = JSON::Any.new([
    JSON::Any.new({"action" => JSON::Any.new("read"), "on" => JSON::Any.new("*.*")}),
  ])
  content : Hash(String, JSON::Any) = {
    "name"        => JSON::Any.new(id),
    "description" => JSON::Any.new("Test role #{id}"),
    "permissions" => permissions,
  }
  extra.each { |k, v| content[k] = v }
  Facet::Mutation::Client.create(
    db, "iam", "Roles",
    doc_id: "iam.Roles.#{id}",
    content: content.to_json,
    actioner_id: "system",
  )
end

# Creates a bare `iam.Account` projection holding the given role ids
# (qualified `iam.Roles.<name>` form) plus an optional `default_role`.
private def create_access_account(db, role_ids : Array(String), default_role : String? = nil) : String
  content : Hash(String, JSON::Any) = {"roles" => JSON::Any.new(role_ids.map { |r| JSON::Any.new(r) })}
  content["default_role"] = JSON::Any.new(default_role) if default_role
  doc_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: doc_id,
    content: content.to_json,
    actioner_id: "system",
  )
  doc_id
end

# A `Principal::Real` whose active role names `role_id` — the shape every
# authenticated request carries. `ActiveRole.role_id` holds the bare role
# name (what `ActiveRole.from_projection_content` builds in production);
# the gate qualifies it to the `iam.Roles.<name>` projection id.
private def principal_as(account_id : String, role_id : String) : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: role_id,
    visible_tags: Set{"default"},
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe Facet::Assistant::Access do
  describe "allowed_for_role?" do
    it "reads the channel list off the named role" do
      with_db do |db|
        create_access_role(db, "on", {"connectivity" => JSON.parse(%(["mcp", "assistant"]))})
        create_access_role(db, "off", {"connectivity" => JSON.parse(%([]))})
        create_access_role(db, "absent", {} of String => JSON::Any)

        Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.on").should be_true
        Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.off").should be_false
        # A role without the field — or with an empty list — reads as off.
        Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.absent").should be_false
      end
    end

    it "fails closed on a missing role projection" do
      with_db do |db|
        Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.gone").should be_false
      end
    end
  end

  describe "allowed? by auth context" do
    it "allows the system bypass" do
      with_db do |db|
        Facet::Assistant::Access.allowed?(db, Facet::RBAC::AuthContext.system).should be_true
      end
    end

    it "follows the active role" do
      with_db do |db|
        create_access_role(db, "held", {"connectivity" => JSON.parse(%(["assistant"]))})
        account_id = create_access_account(db, ["iam.Roles.held"])

        Facet::Assistant::Access.allowed?(db, principal_as(account_id, "held")).should be_true
      end
    end

    it "denies when only a non-active held role enables the assistant" do
      with_db do |db|
        create_access_role(db, "inactive_on", {"connectivity" => JSON.parse(%(["assistant"]))})
        create_access_role(db, "active_off", {"connectivity" => JSON.parse(%([]))})
        account_id = create_access_account(db, ["iam.Roles.inactive_on", "iam.Roles.active_off"])

        # The enabling role is held but not active — roles never merge.
        Facet::Assistant::Access.allowed?(db, principal_as(account_id, "active_off")).should be_false
      end
    end

    it "fails closed on a dangling active role" do
      with_db do |db|
        account_id = create_access_account(db, [] of String)
        Facet::Assistant::Access.allowed?(db, principal_as(account_id, "gone")).should be_false
      end
    end

    it "fails closed on the anonymous principal" do
      with_db do |db|
        Facet::Assistant::Access.allowed?(db, Facet::RBAC::AuthContext.denied).should be_false
      end
    end

    it "fails closed on a preview principal (no active role loaded)" do
      with_db do |db|
        Facet::Assistant::Access.allowed?(
          db, Facet::RBAC::AuthContext.preview("acct_preview", "_draft")
        ).should be_false
      end
    end
  end

  describe "effective_budget" do
    it "takes the maximum budget among enabling roles" do
      with_db do |db|
        create_access_role(db, "b0", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(0_i64),
        })
        create_access_role(db, "b5000", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(5000_i64),
        })
        account_id = create_access_account(db, ["iam.Roles.b5000", "iam.Roles.b0"])

        Facet::Assistant::Access.effective_budget(db, account_id).should eq(5000)
      end
    end

    it "treats a zero budget as a real value, not as unset" do
      with_db do |db|
        create_access_role(db, "zero", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(0_i64),
        })
        account_id = create_access_account(db, ["iam.Roles.zero"])

        Facet::Assistant::Access.effective_budget(db, account_id).should eq(0)
      end
    end

    it "goes unlimited when an enabling role has an unset budget" do
      with_db do |db|
        create_access_role(db, "budgeted", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(5000_i64),
        })
        create_access_role(db, "unset", {"connectivity" => JSON.parse(%(["assistant"]))})
        account_id = create_access_account(db, ["iam.Roles.budgeted", "iam.Roles.unset"])

        Facet::Assistant::Access.effective_budget(db, account_id).should be_nil
      end
    end

    it "ignores budgets of non-enabling roles" do
      with_db do |db|
        create_access_role(db, "off_rich", {
          "connectivity"           => JSON.parse(%([])),
          "assistant_token_budget" => JSON::Any.new(999999_i64),
        })
        create_access_role(db, "on_100", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(100_i64),
        })

        account_id = create_access_account(db, ["iam.Roles.off_rich", "iam.Roles.on_100"])
        Facet::Assistant::Access.effective_budget(db, account_id).should eq(100)
      end
    end

    it "aggregates over the roles array plus default_role" do
      with_db do |db|
        create_access_role(db, "defgen", {
          "connectivity"           => JSON.parse(%(["assistant"])),
          "assistant_token_budget" => JSON::Any.new(250_i64),
        })
        account_id = create_access_account(db, [] of String, default_role: "iam.Roles.defgen")

        Facet::Assistant::Access.effective_budget(db, account_id).should eq(250)
      end
    end

    it "returns nil for an account that holds no roles" do
      with_db do |db|
        account_id = create_access_account(db, [] of String)

        Facet::Assistant::Access.effective_budget(db, account_id).should be_nil
      end
    end

    it "treats a dangling role reference as contributing nothing" do
      with_db do |db|
        account_id = create_access_account(db, ["iam.Roles.gone"])

        Facet::Assistant::Access.effective_budget(db, account_id).should be_nil
      end
    end
  end

  it "sees the production seed roles: admin on, viewer on through connectivity" do
    with_db do |db|
      # The per-example truncation wipes every projection; re-seed the
      # production documents (including `iam.Roles` with the connectivity
      # lists from `data/seeds/iam.Roles/documents.yml`).
      restore_seeded_baseline(db)

      admin_found = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin")
      admin_found.should_not be_nil
      if admin_content = admin_found
        channels = admin_content["connectivity"].as_a.map(&.as_s)
        channels.should contain("assistant")
      end

      Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.admin").should be_true
      Facet::Assistant::Access.allowed_for_role?(db, "iam.Roles.viewer").should be_true
    end
  end
end
