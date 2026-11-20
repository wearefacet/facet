# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../support/migration_fixtures"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# Specs for `Facet::Doctype::AheadMigration`.
#
# Each spec builds a doctype with a `migrate_from_1` script, creates
# documents at v1, then bumps the definition to v2 — with a working script
# (the happy path) or a `ctx.error` script (the failure path). After
# `AheadMigration.call`, every row must sit at the current version, or keep
# its old version untouched when the migration still fails. The fixture
# builders live in `spec/support/migration_fixtures.cr`.

module Facet::Doctype
  describe AheadMigration do
    it "migrates every v1 document to the current version" do
      with_temp_doctype("aheadok") do |db, domain, dt|
        ids = seed_v1_documents(db, domain, dt, 3)
        bump_to_v2_working(db, domain, dt)

        result = AheadMigration.call(db, "#{domain}.#{dt}")
        result.should be_a(AheadMigration::Result)
        res = result.as(AheadMigration::Result)
        res.total.should eq(3)
        res.stats.migrated.should eq(3)
        res.stats.failed.should eq(0)
        res.stats.superseded.should eq(0)
        res.stats.skipped.should eq(0)
        res.stats.batches.should eq(1)

        ids.each do |id|
          stored = Mutation::Client.fetch_projection(db, domain, dt, id)
          stored.meta["schema_version"].as_i.should eq(2)
          stored.content["priority"].should eq(JSON.parse(%("migrated")))
        end
      end
    end

    it "keeps failing rows untouched and migrates them on the next run" do
      with_temp_doctype("aheadfail") do |db, domain, dt|
        ids = seed_v1_documents(db, domain, dt, 2)
        bump_to_v2(db, domain, dt)

        # First run: both rows fail, nothing is written, no marker created.
        result = AheadMigration.call(db, "#{domain}.#{dt}")
        res = result.as(AheadMigration::Result)
        res.stats.failed.should eq(2)
        res.stats.failed_ids.sort!.should eq(ids.sort)
        res.stats.migrated.should eq(0)

        ids.each do |id|
          stored = Mutation::Client.fetch_projection(db, domain, dt, id)
          stored.meta["schema_version"].as_i.should eq(1)
          stored.meta["migration_error"]?.should be_nil
        end

        # Fix the script and run again: the same rows are picked up.
        fix_v2_script(db, domain, dt)
        result = AheadMigration.call(db, "#{domain}.#{dt}")
        res = result.as(AheadMigration::Result)
        res.stats.migrated.should eq(2)
        res.stats.failed.should eq(0)

        ids.each do |id|
          stored = Mutation::Client.fetch_projection(db, domain, dt, id)
          stored.meta["schema_version"].as_i.should eq(2)
          stored.content["priority"].should eq(JSON.parse(%("migrated")))
        end
      end
    end

    it "retries a row carrying a migration_error marker and clears it on success" do
      with_temp_doctype("aheadmarked") do |db, domain, dt|
        id = seed_v1_documents(db, domain, dt, 1).first
        bump_to_v2(db, domain, dt)

        # The lazy read path writes the marker on failure.
        read = Facet::Document::Read.call(db, domain, dt, id, Facet::RBAC::AuthContext.system)
        read.should be_a(Facet::Document::Read::Result)
        Mutation::Client.fetch_projection(db, domain, dt, id).meta["migration_error"]?.should_not be_nil

        # Fix the script. The ahead run strips the marker in memory,
        # migrates the row, and the persisted meta comes back clean.
        fix_v2_script(db, domain, dt)
        result = AheadMigration.call(db, "#{domain}.#{dt}")
        res = result.as(AheadMigration::Result)
        res.stats.migrated.should eq(1)
        res.stats.failed.should eq(0)

        stored = Mutation::Client.fetch_projection(db, domain, dt, id)
        stored.meta["schema_version"].as_i.should eq(2)
        stored.meta["migration_error"]?.should be_nil
      end
    end

    it "keeps the marker when the retry still fails" do
      with_temp_doctype("aheadmarked2") do |db, domain, dt|
        id = seed_v1_documents(db, domain, dt, 1).first
        bump_to_v2(db, domain, dt)

        read = Facet::Document::Read.call(db, domain, dt, id, Facet::RBAC::AuthContext.system)
        read.should be_a(Facet::Document::Read::Result)

        result = AheadMigration.call(db, "#{domain}.#{dt}")
        res = result.as(AheadMigration::Result)
        res.stats.failed.should eq(1)
        res.stats.failed_ids.should eq([id])

        stored = Mutation::Client.fetch_projection(db, domain, dt, id)
        stored.meta["migration_error"]?.should_not be_nil
        stored.meta["schema_version"].as_i.should eq(1)
      end
    end

    it "is a no-op when every row already sits at the current version" do
      with_temp_doctype("aheadnoop") do |db, domain, dt|
        ids = seed_v1_documents(db, domain, dt, 1)
        bump_to_v2_working(db, domain, dt)

        # Migrate the row through the lazy path first, so the ahead run
        # starts from an already-current corpus.
        read = Facet::Document::Read.call(db, domain, dt, ids.first, Facet::RBAC::AuthContext.system)
        read.should be_a(Facet::Document::Read::Result)

        result = AheadMigration.call(db, "#{domain}.#{dt}")
        res = result.as(AheadMigration::Result)
        res.total.should eq(0)
        res.stats.migrated.should eq(0)
        res.stats.skipped.should eq(0)
      end
    end

    it "returns 404 for an unknown doctype" do
      with_db do |db|
        result = AheadMigration.call(db, "ghost.Missing#{unique_suffix(6)}")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end

    it "returns 400 for a malformed qualified doctype" do
      with_db do |db|
        result = AheadMigration.call(db, "no-dot")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(400)
      end
    end
  end
end
