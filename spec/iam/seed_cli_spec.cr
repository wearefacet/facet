# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::SeedCLI do
  before_each do
    # The global per-test TRUNCATE wipes the seeded core doctypes. The CLI
    # reads the `iam.Account` definition for the email check, so re-ensure
    # the definitions it needs (idempotent, ~10 ms) — the same setup
    # spec/iam/seed_spec.cr uses.
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
    it "creates the first admin from a valid email argument" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["bootstrap@example.com"])
        end
        code.should eq(0)

        content = db.query_one(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'bootstrap@example.com' AND deleted_at IS NULL",
          as: JSON::Any
        )
        content["status"].as_s.should eq("active")
      end
    end

    it "lowercases the email to the stored form" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["Mixed@Example.COM"])
        end
        code.should eq(0)

        # The login lookup compares LOWER(content->>'email'); the raw write
        # path must land the same lowercase form the pipeline's create hook
        # produces.
        content = db.query_one(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND content->>'email' = 'mixed@example.com' AND deleted_at IS NULL",
          as: JSON::Any
        )
        content["email"].as_s.should eq("mixed@example.com")
      end
    end

    it "refuses an unknown flag and creates nothing" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["admin@example.com", "--name", "Operator"])
        end
        code.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(0)
      end
    end

    it "refuses a second positional argument" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["one@example.com", "two@example.com"])
        end
        code.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(0)
      end
    end

    it "refuses an email the iam.Account pattern rejects and creates nothing" do
      with_db do |db|
        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["not-an-email"])
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
      previous = ENV["SEED_ADMIN_EMAIL"]?
      ENV.delete("SEED_ADMIN_EMAIL")
      code = 0
      begin
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin([] of String)
        end
      ensure
        ENV["SEED_ADMIN_EMAIL"] = previous if previous
      end
      code.should eq(1)
    end

    it "refuses when the iam.Account definition is absent (fail closed)" do
      with_db do |db|
        db.exec("DELETE FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'iam.Account'")
        Facet::Doctype::DefinitionStore.cache.clear

        code = 0
        silence_stdout do
          code = Facet::IAM::SeedCLI.seed_admin(["bootstrap@example.com"])
        end
        code.should eq(1)

        count = db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL",
          as: Int64
        )
        count.should eq(0)
      end
    end
  end
end
