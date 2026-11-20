# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/rbac"
require "../../src/mutation/client"

# ── Helpers ────────────────────────────────────────────────────────────────

def create_account_loader_account(db, account_id, role_ids)
  content = JSON::Any.new({
    "roles" => JSON::Any.new(role_ids.map { |r| JSON::Any.new(r) }),
  })
  Facet::Mutation::Client.create(
    db, "iam", "Account",
    doc_id: account_id,
    content: content.to_json,
    actioner_id: "system",
  )
end

module Facet::RBAC
  describe AccountLoader do
    # ── load_role_ids ──────────────────────────────────────────────────────

    describe ".load_role_ids" do
      it "returns role IDs for an existing account" do
        with_db do |db|
          create_account_loader_account(db, "account_1", ["iam.Roles.admin", "iam.Roles.editor"])
          role_ids = AccountLoader.load_role_ids(db, "account_1")
          role_ids.should_not be_nil
          role_ids.should eq(["iam.Roles.admin", "iam.Roles.editor"])
        end
      end

      it "returns nil for a non-existent account" do
        with_db do |db|
          AccountLoader.load_role_ids(db, "nonexistent").should be_nil
        end
      end

      it "returns nil for an account with no roles field" do
        with_db do |db|
          content = JSON::Any.new({"name" => JSON::Any.new("no_roles")})
          Facet::Mutation::Client.create(
            db, "iam", "Account",
            doc_id: "no_roles_account",
            content: content.to_json,
            actioner_id: "system",
          )
          AccountLoader.load_role_ids(db, "no_roles_account").should be_nil
        end
      end

      it "returns empty array for an account with empty roles array" do
        with_db do |db|
          create_account_loader_account(db, "empty_roles", [] of String)
          role_ids = AccountLoader.load_role_ids(db, "empty_roles")
          role_ids.should_not be_nil
          role_ids.try(&.should be_empty)
        end
      end
    end

    # ── role_assigned? ─────────────────────────────────────────────────────

    describe ".role_assigned?" do
      it "returns true when role is in the account's roles" do
        with_db do |db|
          create_account_loader_account(db, "account_2", ["iam.Roles.admin", "iam.Roles.editor"])
          AccountLoader.role_assigned?(db, "account_2", "iam.Roles.admin").should be_true
        end
      end

      it "returns false when role is not in the account's roles" do
        with_db do |db|
          create_account_loader_account(db, "account_3", ["iam.Roles.editor"])
          AccountLoader.role_assigned?(db, "account_3", "iam.Roles.admin").should be_false
        end
      end

      it "returns false when account does not exist" do
        with_db do |db|
          AccountLoader.role_assigned?(db, "nonexistent", "iam.Roles.admin").should be_false
        end
      end
    end
  end
end
