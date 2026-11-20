# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::AccountCLI do
  before_each do
    # The global per-test TRUNCATE wipes the seeded core doctypes
    # (`core.DocType`, `core.Domain`, `iam.Account`, `iam.Roles`).
    # `Document::List` / `Document::Update` resolve doctype definitions from
    # `core.DocType` projections, so re-ensure them (idempotent, ~10 ms).
    with_db do |db|
      %w[core.DocType core.Domain iam.Account].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  describe ".add_role" do
    it "assigns a role to an account by email" do
      with_db do |db|
        account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

        Facet::IAM::AccountCLI.add_role(["test@example.com", "editor"])

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin", "iam.Roles.editor"])
        content["default_role"]?.try(&.as_s).should eq("iam.Roles.admin")
      end
    end

    it "assigns a role to an account by id" do
      with_db do |db|
        account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

        Facet::IAM::AccountCLI.add_role([account_id, "editor"])

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin", "iam.Roles.editor"])
      end
    end

    it "accepts a qualified role id" do
      with_db do |db|
        account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

        Facet::IAM::AccountCLI.add_role(["test@example.com", "iam.Roles.editor"])

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin", "iam.Roles.editor"])
      end
    end

    it "sets default_role when the account had no roles" do
      with_db do |db|
        account_id = create_test_account(db, roles: [] of String, default_role: nil)

        Facet::IAM::AccountCLI.add_role(["test@example.com", "editor"])

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.editor"])
        content["default_role"]?.try(&.as_s).should eq("iam.Roles.editor")
      end
    end

    it "is a no-op when the role is already assigned" do
      with_db do |db|
        account_id = create_test_account(db, roles: ["iam.Roles.admin", "iam.Roles.editor"], default_role: "iam.Roles.admin")

        Facet::IAM::AccountCLI.add_role(["test@example.com", "editor"])

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin", "iam.Roles.editor"])
      end
    end
  end

  describe ".create_account" do
    it "creates an account with a role, a one-time password, and must_change_pw" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::AccountCLI.create_account(["new@example.com", "--role", "editor", "--name", "New Operator"])
        end
        code.should eq(0)

        account_id = db.query_one(
          "SELECT id FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'new@example.com' AND deleted_at IS NULL",
          as: String
        )
        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: JSON::Any
        )
        content["name"].as_s.should eq("New Operator")
        content["status"].as_s.should eq("pending")
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.editor"])
        content["default_role"].as_s.should eq("iam.Roles.editor")
        content["must_change_pw"].as_bool.should be_true

        # The one-time credential: a bcrypt hash on the `password` slot,
        # minted by the temporary-password bootstrap.
        mode, value = db.query_one(
          "SELECT mode, value FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'password'",
          account_id,
          as: {String, String}
        )
        mode.should eq("hash")
        value.should start_with("$2")

        login_events(db).should contain("temp_password_generated")
      end
    end

    it "defaults the display name to the email and leaves roles empty without --role" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::AccountCLI.create_account(["noreply@example.com"])
        end
        code.should eq(0)

        content = db.query_one(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'noreply@example.com' AND deleted_at IS NULL",
          as: JSON::Any
        )
        content["name"].as_s.should eq("noreply@example.com")
        content["roles"]?.should be_nil
        content["default_role"]?.should be_nil
      end
    end

    it "refuses a duplicate live email" do
      with_db do |db|
        create_test_account(db, email: "dup@example.com")

        code = 0
        silence_stdout do
          code = Facet::IAM::AccountCLI.create_account(["dup@example.com", "--role", "editor"])
        end
        code.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'dup@example.com' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(1)
      end
    end

    it "refuses an unknown role and creates nothing" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::AccountCLI.create_account(["new@example.com", "--role", "nosuchrole"])
        end
        code.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(0)
      end
    end

    it "refuses a missing email" do
      with_db do |_db|
        code = 0
        silence_stdout do
          code = Facet::IAM::AccountCLI.create_account([] of String)
        end
        code.should eq(1)
      end
    end
  end
end
