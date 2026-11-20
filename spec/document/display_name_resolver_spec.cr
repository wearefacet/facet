# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/document/display_name"
require "../../src/mutation/client"
require "../../spec/mutation/mutations_spec"

# Integration specs for `Document::DisplayName::DatabaseReferenceResolver`.
#
# Uses the real `projections` table so the resolver's SQL, column list, and
# tombstone-preservation behaviour are exercised end-to-end. Each test seeds
# its own projection rows via raw SQL so the spec is self-contained.
module Facet::Document::DisplayNameResolver
  def self.with_db(&)
    database_url = ENV.fetch("DATABASE_URL") { abort("DATABASE_URL is required") }
    DB.open(database_url) do |db|
      yield db
    end
  end

  def self.seed_projection(db, domain, doc_type, id, display_name : String?, deleted = false) : Nil
    deleted_at = deleted ? "now()" : "NULL"
    db.exec(
      <<-SQL,
        INSERT INTO projections
          (domain, doc_type, id, content, version, links, meta, state, search, display_name, deleted_at, updated_at, created_at)
        VALUES
          ($1, $2, $3, '{}'::jsonb, 1, '[]'::jsonb, '{}'::jsonb, $4, NULL, $5, #{deleted_at}, now(), now())
      SQL
      domain, doc_type, id, "mut-seed-#{id}", display_name
    )
  end

  describe Facet::Document::DisplayName::DatabaseReferenceResolver do
    it "resolves the stored display_name of a live projection" do
      with_db do |db|
        Facet::Mutations.with_db do |mut_db|
          doc_id = Facet::Util::ScriptHelpers.ulid
          seed_projection(mut_db, "test", "Company", doc_id, "Acme Inc.")

          resolver = Facet::Document::DisplayName::DatabaseReferenceResolver.new(db)
          resolver.resolve("test.Company", doc_id).should eq("Acme Inc.")
        end
      end
    end

    it "returns nil when the target id does not exist" do
      with_db do |db|
        resolver = Facet::Document::DisplayName::DatabaseReferenceResolver.new(db)
        resolver.resolve("test.Company", "DOES-NOT-EXIST-#{Facet::Util::ScriptHelpers.ulid}").should be_nil
      end
    end

    it "returns nil when the projection has no display_name stored" do
      Facet::Mutations.with_db do |mut_db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        seed_projection(mut_db, "test", "Company", doc_id, nil)

        with_db do |db|
          resolver = Facet::Document::DisplayName::DatabaseReferenceResolver.new(db)
          resolver.resolve("test.Company", doc_id).should be_nil
        end
      end
    end

    it "resolves from tombstoned rows (display_name is preserved on delete)" do
      Facet::Mutations.with_db do |mut_db|
        doc_id = Facet::Util::ScriptHelpers.ulid
        seed_projection(mut_db, "test", "Company", doc_id, "Tombstoned Inc.", deleted: true)

        with_db do |db|
          resolver = Facet::Document::DisplayName::DatabaseReferenceResolver.new(db)
          # Critical assertion: deletes do NOT clear display_name, so the
          # referencing side still sees a meaningful label after the target
          # is soft-deleted.
          resolver.resolve("test.Company", doc_id).should eq("Tombstoned Inc.")
        end
      end
    end

    it "returns nil when the qualified doctype has no domain prefix" do
      with_db do |db|
        resolver = Facet::Document::DisplayName::DatabaseReferenceResolver.new(db)
        resolver.resolve("Company", "any-id").should be_nil
      end
    end
  end
end
