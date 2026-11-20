# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# ── Helpers (top-level) ───────────────────────────────────────────────

# Creates a v1 doctype with migration script, returns the definition.
def create_migratable_doctype_v1(db, domain, dt)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'normal'
    end
    return export
  LUA

  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})

  ensure_domain(db, domain)
  defn = Facet::Doctype::DoctypeDefinition.from_json(body)
  result = Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Doctype::Create::Result)
  defn
end

# Updates doctype from v1 to v2, returns the v2 definition.
def update_doctype_to_v2(db, domain, dt)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'normal'
    end
    return export
  LUA

  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})

  doctype_id = "#{domain}.#{dt}"
  result = Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Doctype::Update::Result)

  proj = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
  Facet::Doctype::DoctypeDefinition.from_json(proj.content)
end

# Creates a document and returns its projection.
def create_test_document(db, domain, dt)
  result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
  result.should be_a(Facet::Document::Create::Result)
  result.as(Facet::Document::Create::Result).projection
end

module Facet::Document
  describe Migrate do
    describe ".call" do
      it "returns the same projection when schema_version is already current" do
        with_temp_doctype("migtest") do |db, domain, dt|
          defn = create_migratable_doctype_v1(db, domain, dt)
          proj = create_test_document(db, domain, dt)

          result = Migrate.call(db, defn, proj)
          result.should be_a(Migrate::Result)

          res = result.as(Migrate::Result)
          res.migration_ids.should be_empty
          res.projection.content["title"].should eq(JSON.parse(%("my doc")))
        end
      end

      it "migrates a document from v1 to current v2" do
        with_temp_doctype("migtest") do |db, domain, dt|
          _defn = create_migratable_doctype_v1(db, domain, dt)
          proj = create_test_document(db, domain, dt)

          v2_defn = update_doctype_to_v2(db, domain, dt)

          result = Migrate.call(db, v2_defn, proj)
          result.should be_a(Migrate::Result)

          res = result.as(Migrate::Result)
          res.migration_ids.should_not be_empty
          res.migration_ids.size.should eq(1)

          migrated_proj = res.projection
          migrated_proj.content["title"].should eq(JSON.parse(%("my doc")))
          migrated_proj.content["priority"].should eq(JSON.parse(%("normal")))
        end
      end

      it "persists the migrated document as a snapshot mutation" do
        with_temp_doctype("migtest") do |db, domain, dt|
          _defn = create_migratable_doctype_v1(db, domain, dt)
          proj = create_test_document(db, domain, dt)

          v2_defn = update_doctype_to_v2(db, domain, dt)
          result = Migrate.call(db, v2_defn, proj)
          result.should be_a(Migrate::Result)

          stored = Mutation::Client.fetch_projection(db, domain, dt, proj.id)
          stored.content["priority"].should eq(JSON.parse(%("normal")))
          stored.meta["schema_version"].as_i.should eq(2)
        end
      end

      it "returns error when doctype has no script" do
        with_temp_doctype("migtest") do |db, domain, dt|
          # Create v1 without script
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string", "required": true}}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          v2_no_script = Facet::Doctype::DoctypeDefinition.new(
            doctype: dt,
            domain: domain,
            schema_version: 2,
            migrations: {"1" => "migrate_from_1"},
            script: nil
          )

          result = Migrate.call(db, v2_no_script, proj)
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(500)
          err.message.should contain("no script")
        end
      end

      it "returns error when migration entry is missing" do
        with_temp_doctype("migtest") do |db, domain, dt|
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            return export
          LUA
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          v2_no_mig = Facet::Doctype::DoctypeDefinition.new(
            doctype: dt,
            domain: domain,
            schema_version: 2,
            fields: {"title" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"), required: true)},
            script: script,
            migrations: {} of String => String
          )

          result = Migrate.call(db, v2_no_mig, proj)
          result.should be_a(Facet::ServiceError)
        end
      end

      it "migrates from v1 to v3 through two migration steps" do
        with_temp_doctype("migtest") do |db, domain, dt|
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.priority = ctx.root.priority or 'normal'
            end
            function export.migrate_from_2(ctx)
              ctx.root.version_tag = 'v2-migrated'
            end
            return export
          LUA
          fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          # Update v1 → v2 first, then v2 → v3 (sequential bumps)
          v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
          doctype_id = "#{domain}.#{dt}"
          upd1 = Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system)
          upd1.should be_a(Facet::Doctype::Update::Result)

          v3_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})
          upd2 = Facet::Doctype::Update.call(db, doctype_id, v3_schema, Facet::RBAC::AuthContext.system)
          upd2.should be_a(Facet::Doctype::Update::Result)

          v3_proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v3_defn = Facet::Doctype::DoctypeDefinition.from_json(v3_proj.content)

          result = Migrate.call(db, v3_defn, proj)
          result.should be_a(Migrate::Result)
          res = result.as(Migrate::Result)

          res.migration_ids.size.should eq(1)

          migrated = res.projection
          migrated.content["priority"].should eq(JSON.parse(%("normal")))
          migrated.content["version_tag"].should eq(JSON.parse(%("v2-migrated")))
          migrated.meta["schema_version"].as_i.should eq(3)
        end
      end

      it "handles double migration: migrate only new steps on second read" do
        with_temp_doctype("migtest") do |db, domain, dt|
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.priority = ctx.root.priority or 'normal'
            end
            function export.migrate_from_2(ctx)
              ctx.root.version_tag = 'v2-migrated'
            end
            return export
          LUA
          fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          # Update to v2 first
          v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
          doctype_id = "#{domain}.#{dt}"
          upd_result = Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system)
          upd_result.should be_a(Facet::Doctype::Update::Result)

          v2_proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v2_defn = Facet::Doctype::DoctypeDefinition.from_json(v2_proj.content)

          # Migrate v1→v2
          result1 = Migrate.call(db, v2_defn, proj)
          result1.should be_a(Migrate::Result)
          res1 = result1.as(Migrate::Result)
          res1.projection.content["priority"].should eq(JSON.parse(%("normal")))
          res1.projection.meta["schema_version"].as_i.should eq(2)

          # Update to v3
          v3_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})
          upd_result2 = Facet::Doctype::Update.call(db, doctype_id, v3_schema, Facet::RBAC::AuthContext.system)
          upd_result2.should be_a(Facet::Doctype::Update::Result)

          v3_proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v3_defn = Facet::Doctype::DoctypeDefinition.from_json(v3_proj.content)

          # Migrate v2→v3 — only runs migrate_from_2
          result2 = Migrate.call(db, v3_defn, res1.projection)
          result2.should be_a(Migrate::Result)
          res2 = result2.as(Migrate::Result)
          res2.projection.content["version_tag"].should eq(JSON.parse(%("v2-migrated")))
          res2.projection.meta["schema_version"].as_i.should eq(3)
        end
      end

      it "returns 422 on Lua runtime error during Migrate.call" do
        with_temp_doctype("migtest") do |db, domain, dt|
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.error('something went wrong')
            end
            return export
          LUA
          fields_json = %({"title": {"type": "string", "required": true}})
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          v2_fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
          v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{v2_fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
          doctype_id = "#{domain}.#{dt}"
          Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

          v2_proj = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v2_defn = Facet::Doctype::DoctypeDefinition.from_json(v2_proj.content)

          result = Facet::Document::Migrate.call(db, v2_defn, proj)
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("Migration from v1 failed")
          err.details.not_nil!.map(&.message).should contain("something went wrong")
        end
      end

      it "returns 422 when a migration function raises a Lua runtime error" do
        with_temp_doctype("migtest") do |db, domain, dt|
          # A genuine runtime exception (indexing a nil value), not the
          # sandbox `ctx.error` collector — a runtime exception unwinds
          # as `ScriptContext::Error` and used to escape `Migrate.call`.
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.metadata.tags = 'x'
            end
            return export
          LUA
          fields_json = %({"title": {"type": "string", "required": true}})
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection

          v2_fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
          v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{v2_fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
          doctype_id = "#{domain}.#{dt}"
          Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

          v2_proj = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v2_defn = Facet::Doctype::DoctypeDefinition.from_json(v2_proj.content)

          result = Facet::Document::Migrate.call(db, v2_defn, proj)
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("Migration from v1 raised")
          err.message.should contain("attempt to index a nil value")
          # No structured details: the message already carries the Lua
          # reason, and joined details would duplicate it on the marker.
          err.details.should be_nil

          # Nothing persisted: no marker, no version bump — the marker is
          # written by the read/list call sites, not by `Migrate.call`.
          stored = Facet::Mutation::Client.fetch_projection(db, domain, dt, proj.id)
          stored.meta["migration_error"]?.should be_nil
          stored.meta["schema_version"]?.try(&.as_i).should eq(1)
        end
      end

      it "returns error on multi-hop partial failure and does not persist partial migration" do
        with_temp_doctype("migtest") do |db, domain, dt|
          script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.priority = 'normal'
            end
            function export.migrate_from_2(ctx)
              ctx.error('second step failed')
            end
            return export
          LUA
          fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
          body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
          defn = Facet::Doctype::DoctypeDefinition.from_json(body)
          ensure_domain(db, domain)
          Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

          doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "my doc"}))
          proj = doc_result.as(Facet::Document::Create::Result).projection
          doc_id = proj.id

          doctype_id = "#{domain}.#{dt}"
          v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
          Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

          v3_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})
          Facet::Doctype::Update.call(db, doctype_id, v3_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

          v3_proj = Facet::Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
          v3_defn = Facet::Doctype::DoctypeDefinition.from_json(v3_proj.content)

          result = Facet::Document::Migrate.call(db, v3_defn, proj)
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(422)
          err.message.should contain("Migration from v2 failed")
          err.details.not_nil!.map(&.message).should contain("second step failed")

          stored = Facet::Mutation::Client.fetch_projection(db, domain, dt, doc_id)
          stored.meta["schema_version"]?.try(&.as_i).should eq(1)
        end
      end
    end
  end

  # ── Document::Read integration ──────────────────────────────────────

  describe Read do
    it "reads a document (no migration needed)" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        result = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result.should be_a(Read::Result)
        read_res = result.as(Read::Result)
        read_res.migrated.should be_false
        read_res.projection.content["title"].should eq(JSON.parse(%("hello")))
      end
    end

    it "reads and migrates a stale document" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.root.priority = ctx.root.priority or 'normal'
          end
          return export
        LUA
        fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection
        proj.meta["schema_version"].as_i.should eq(1)

        update_doctype_to_v2(db, domain, dt)

        result = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result.should be_a(Read::Result)
        read_res = result.as(Read::Result)

        read_res.migrated.should be_true
        read_res.projection.content["title"].should eq(JSON.parse(%("hello")))
        read_res.projection.content["priority"].should eq(JSON.parse(%("normal")))
        read_res.projection.meta["schema_version"].as_i.should eq(2)
      end
    end

    it "serves stale data with migration_error marker when migration fails" do
      with_temp_doctype("readtest") do |db, domain, dt|
        # Script that has migrate_from_1 but it calls ctx.error (simulates failure)
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.error('migration failed')
          end
          return export
        LUA
        fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        # Update to v2 via Doctype::Update (validates properly)
        v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
        doctype_id = "#{domain}.#{dt}"
        upd_result = Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system)
        upd_result.should be_a(Facet::Doctype::Update::Result)

        # Read — migration failure returns stale data with migration_error marker
        result = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result.should be_a(Read::Result)
        read_res = result.as(Read::Result)
        read_res.migrated.should be_false
        # The marker preserves the Lua `ctx.error` text so operators can see why.
        read_res.projection.meta["migration_error"].as_s.should contain("migration failed")
      end
    end

    it "serves stale data with a marker when the migration raises a runtime error" do
      with_temp_doctype("readtest") do |db, domain, dt|
        # A genuine runtime exception (indexing a nil value), not the
        # sandbox `ctx.error` collector — before the rescue in
        # `Migrate.call`, this exception 500'd the whole read.
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.root.metadata.tags = 'x'
          end
          return export
        LUA
        fields_json = %({"title": {"type": "string", "required": true}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        doctype_id = "#{domain}.#{dt}"
        v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        # Read — the raised migration comes back as a marker + stale data,
        # the same branch the `ctx.error` path takes (never an exception).
        result = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result.should be_a(Read::Result)
        read_res = result.as(Read::Result)
        read_res.migrated.should be_false
        marker = read_res.projection.meta["migration_error"].as_s
        marker.should contain("Migration from v1 raised")
        marker.should contain("attempt to index a nil value")
        # Stale content, still at the old schema version.
        read_res.projection.content["title"].should eq(JSON.parse(%("hello")))
        read_res.projection.meta["schema_version"].as_i.should eq(1)
      end
    end

    it "does not retry migration after a previous failure" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.error('migration failed')
          end
          return export
        LUA
        fields_json = %({"title": {"type": "string", "required": true}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        doctype_id = "#{domain}.#{dt}"
        v2_fields = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{v2_fields}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        # First read — fails, marks migration_error
        result1 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result1.should be_a(Read::Result)
        read1 = result1.as(Read::Result)
        read1.migrated.should be_false
        read1.projection.meta["migration_error"]?.should_not be_nil

        # Second read — should NOT attempt migration again, returns same stale data
        result2 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result2.should be_a(Read::Result)
        read2 = result2.as(Read::Result)
        read2.migrated.should be_false
        # The persisted marker still carries the Lua reason after retry-blocking.
        read2.projection.meta["migration_error"].as_s.should contain("migration failed")
      end
    end

    it "returns 404 for unknown doctype" do
      with_temp_doctype("readtest") do |db, domain, dt|
        result = Read.call(db, domain, dt, "some-nonexistent-id", Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(404)
        err.message.should contain("Unknown doctype")
      end
    end

    it "returns 404 for nonexistent document" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        result = Read.call(db, domain, dt, "#{domain}.#{dt}.nonexistent", Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(404)
      end
    end

    it "does not migrate a document that is already at current version" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        result1 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result1.should be_a(Read::Result)
        result1.as(Read::Result).migrated.should be_false

        result2 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result2.should be_a(Read::Result)
        result2.as(Read::Result).migrated.should be_false
      end
    end

    it "reads a document that was already migrated (no double migration)" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.root.priority = ctx.root.priority or 'normal'
          end
          return export
        LUA
        fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        update_doctype_to_v2(db, domain, dt)

        result1 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result1.should be_a(Read::Result)
        read1 = result1.as(Read::Result)
        read1.migrated.should be_true
        read1.projection.meta["schema_version"].as_i.should eq(2)

        result2 = Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result2.should be_a(Read::Result)
        read2 = result2.as(Read::Result)
        read2.migrated.should be_false
        read2.projection.meta["schema_version"].as_i.should eq(2)
      end
    end

    it "reads and migrates a document from v1 to v3 (multi-hop through Read)" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.priority = ctx.root.priority or 'normal'
            end
            function export.migrate_from_2(ctx)
              ctx.root.version_tag = 'v2-migrated'
            end
            return export
          LUA
        fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection
        proj.meta["schema_version"].as_i.should eq(1)

        doctype_id = "#{domain}.#{dt}"
        v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        v3_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v3_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        result = Facet::Document::Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Document::Read::Result)
        read_res = result.as(Facet::Document::Read::Result)
        read_res.migrated.should be_true
        read_res.projection.content["priority"].should eq(JSON.parse(%("normal")))
        read_res.projection.content["version_tag"].should eq(JSON.parse(%("v2-migrated")))
        read_res.projection.meta["schema_version"].as_i.should eq(3)
      end
    end

    it "reads a document twice with multi-hop: first v1→v3, then v3→v4" do
      with_temp_doctype("readtest") do |db, domain, dt|
        script = <<-LUA
            local export = {}
            function export.create(ctx) end
            function export.migrate_from_1(ctx)
              ctx.root.priority = ctx.root.priority or 'normal'
            end
            function export.migrate_from_2(ctx)
              ctx.root.version_tag = 'v2-migrated'
            end
            function export.migrate_from_3(ctx)
              ctx.root.finalized = true
            end
            return export
          LUA
        fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
        body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "fields": #{fields_json}, "script": #{script.to_json}})
        defn = Facet::Doctype::DoctypeDefinition.from_json(body)
        ensure_domain(db, domain)
        Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json).should be_a(Facet::Doctype::Create::Result)

        doc_result = Facet::Document::Create.call(db, domain, dt, %({"title": "hello"}))
        proj = doc_result.as(Facet::Document::Create::Result).projection

        doctype_id = "#{domain}.#{dt}"
        v2_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v2_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        v3_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v3_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        result1 = Facet::Document::Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result1.should be_a(Facet::Document::Read::Result)
        read1 = result1.as(Facet::Document::Read::Result)
        read1.migrated.should be_true
        read1.projection.meta["schema_version"].as_i.should eq(3)

        v4_schema = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 4, "fields": #{fields_json}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2", "3": "migrate_from_3"}, "script": #{script.to_json}})
        Facet::Doctype::Update.call(db, doctype_id, v4_schema, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)

        result2 = Facet::Document::Read.call(db, domain, dt, proj.id, Facet::RBAC::AuthContext.system)
        result2.should be_a(Facet::Document::Read::Result)
        read2 = result2.as(Facet::Document::Read::Result)
        read2.migrated.should be_true
        read2.projection.content["finalized"].should eq(JSON.parse(%(true)))
        read2.projection.content["priority"].should eq(JSON.parse(%("normal")))
        read2.projection.content["version_tag"].should eq(JSON.parse(%("v2-migrated")))
        read2.projection.meta["schema_version"].as_i.should eq(4)
      end
    end
  end
end
