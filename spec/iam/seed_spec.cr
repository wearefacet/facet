# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::Seed do
  before_each do
    # The global per-test TRUNCATE wipes the seeded core doctypes
    # (`core.DocType`, `core.Domain`, `iam.Account`, `iam.Roles`).
    # `seed_admin` writes through the document pipeline, so re-ensure the
    # definitions it needs (idempotent, ~10 ms) instead of a full-corpus
    # re-seed.
    with_db do |db|
      %w[core.DocType core.Domain iam.Account].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  describe ".seed_admin" do
    it "creates the first admin with a one-time password and must_change_pw" do
      with_db do |db|
        admin = Facet::IAM::Seed.seed_admin(db, "bootstrap@example.com")
        admin = admin.as(Facet::IAM::Seed::Admin)

        content = db.query_one(
          "SELECT content FROM projections WHERE id = $1 AND deleted_at IS NULL",
          admin.id,
          as: JSON::Any
        )
        content["email"].as_s.should eq("bootstrap@example.com")
        content["status"].as_s.should eq("active")
        content["must_change_pw"].as_bool.should be_true
        content["roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin"])
        content["default_role"].as_s.should eq("iam.Roles.admin")

        # The returned plaintext verifies against the stored hash and has
        # the shared one-time-credential shape (4 dashed groups of 4 over
        # the 30-symbol alphabet — see Invite.generate_password).
        admin.password.should match(/^[2-9A-HJKMNP-TV-Z]{4}(-[2-9A-HJKMNP-TV-Z]{4}){3}$/)
        Facet::Secrets.verify(db, "iam.Account.#{admin.id}", "password", admin.password).should be_true
      end
    end

    it "returns nil for an email that already exists and creates no duplicate" do
      with_db do |db|
        Facet::IAM::Seed.seed_admin(db, "bootstrap@example.com")

        second = Facet::IAM::Seed.seed_admin(db, "bootstrap@example.com")
        second.should be_nil

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'bootstrap@example.com' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(1)
      end
    end

    it "bootstraps a second admin for a different email" do
      with_db do |db|
        first = Facet::IAM::Seed.seed_admin(db, "one@example.com").not_nil!
        second = Facet::IAM::Seed.seed_admin(db, "two@example.com").not_nil!

        first.id.should_not eq(second.id)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(2)
      end
    end

    it "never writes the plaintext password to the login events" do
      with_db do |db|
        admin = Facet::IAM::Seed.seed_admin(db, "bootstrap@example.com").not_nil!

        events = db.query_all(
          "SELECT content::text FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
          as: String
        )
        events.each do |content|
          content.should_not contain(admin.password)
        end
      end
    end
  end

  describe ".dev_seed_refusal" do
    it "allows the dev seed outside production" do
      Facet::IAM::Seed.dev_seed_refusal.should be_nil
      Facet::IAM::Seed.dev_seed_refusal("dev").should be_nil
      Facet::IAM::Seed.dev_seed_refusal("e2e").should be_nil
    end

    it "refuses the dev seed in production and names the bootstrap command" do
      refusal = Facet::IAM::Seed.dev_seed_refusal("production").not_nil!
      refusal.should contain("seed:dev")
      refusal.should contain("seed:admin")
      refusal.should contain("must_change_pw")
    end
  end
end
