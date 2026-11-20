# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# ── Helpers (top-level) ───────────────────────────────────────────────

# Seeds a v1 doctype whose `migrate_from_1` fills `priority`, creates one
# document, and bumps the doctype to a v2 whose migration calls `ctx.error`
# (the B-301 failure shape). Returns the document id.
def seed_blocked_document(db, domain, dt) : String
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'normal'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  ensure_domain(db, domain)
  defn = Facet::Doctype::DoctypeDefinition.from_json(body)
  Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

  doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
  proj = doc_result.as(Facet::Document::Create::Result).projection

  broken_script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.error('boom')
    end
    return export
  LUA
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{broken_script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

  proj.id
end

# Reads a document through the lazy-migration path. Returns the read
# projection (the marker write happens inside `Read.call`).
def read_document(db, domain, dt, doc_id) : Facet::Mutation::Client::Projection
  result = Facet::Document::Read.call(db, domain, dt, doc_id, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Read::Result)
  result.as(Facet::Document::Read::Result).projection
end

# Re-saves the doctype at v2 with a working `migrate_from_1` (B-301 merge
# carries the stored migration map; the PUT body omits it).
def fix_doctype_definition(db, domain, dt) : Nil
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'normal'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
end

module Facet::Doctype
  describe MigrationRetry do
    it "re-runs a blocked migration after the definition is fixed (B-301)" do
      with_temp_doctype("retryok") do |db, domain, dt|
        doc_id = seed_blocked_document(db, domain, dt)
        read_document(db, domain, dt, doc_id).meta["migration_error"]?.should_not be_nil

        fix_doctype_definition(db, domain, dt)

        result = MigrationRetry.call(db, "#{domain}.#{dt}")
        result.should be_a(MigrationRetry::Result)
        stats = result.as(MigrationRetry::Result).stats
        stats.scanned.should eq(1)
        stats.migrated.should eq(1)
        stats.failed.should eq(0)

        stored = Mutation::Client.fetch_projection(db, domain, dt, doc_id)
        stored.meta["migration_error"]?.should be_nil
        stored.meta["schema_version"].as_i.should eq(2)
        stored.content["priority"].should eq(JSON.parse(%("normal")))
      end
    end

    it "keeps the marker and writes nothing when the migration still fails" do
      with_temp_doctype("retrybad") do |db, domain, dt|
        doc_id = seed_blocked_document(db, domain, dt)
        read_document(db, domain, dt, doc_id).meta["migration_error"]?.should_not be_nil

        result = MigrationRetry.call(db, "#{domain}.#{dt}")
        result.should be_a(MigrationRetry::Result)
        stats = result.as(MigrationRetry::Result).stats
        stats.scanned.should eq(1)
        stats.migrated.should eq(0)
        stats.failed.should eq(1)
        stats.failed_ids.should eq([doc_id])

        stored = Mutation::Client.fetch_projection(db, domain, dt, doc_id)
        stored.meta["migration_error"]?.should_not be_nil
        stored.meta["schema_version"].as_i.should eq(1)
      end
    end

    it "drops a stale marker on a document already at the current version" do
      with_temp_doctype("retrystale") do |db, domain, dt|
        doc_id = seed_blocked_document(db, domain, dt)
        fix_doctype_definition(db, domain, dt)

        # Migrate the document to the current version, then plant a stale
        # marker on it — the shape a marker keeps when the version caught up
        # through another path while the marker stayed.
        read_document(db, domain, dt, doc_id).meta["schema_version"].as_i.should eq(2)
        db.exec(
          "UPDATE projections SET meta = jsonb_set(meta, '{migration_error}', $1) WHERE id = $2",
          JSON::Any.new("blocked").to_json, doc_id,
        )
        Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{dt}")

        result = MigrationRetry.call(db, "#{domain}.#{dt}")
        result.should be_a(MigrationRetry::Result)
        stats = result.as(MigrationRetry::Result).stats
        stats.scanned.should eq(1)
        stats.migrated.should eq(1)
        stats.failed.should eq(0)

        stored = Mutation::Client.fetch_projection(db, domain, dt, doc_id)
        stored.meta["migration_error"]?.should be_nil
        stored.content["title"].should eq(JSON.parse(%("my doc")))
      end
    end

    it "returns 404 for an unknown doctype" do
      with_db do |db|
        result = MigrationRetry.call(db, "ghost.Missing#{unique_suffix(6)}")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(404)
      end
    end

    it "returns 400 for a malformed qualified doctype" do
      with_db do |db|
        result = MigrationRetry.call(db, "no-dot")
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(400)
      end
    end
  end
end
