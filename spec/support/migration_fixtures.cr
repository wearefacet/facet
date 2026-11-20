# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Fixture builders for the migration tests (`AheadMigration`, the
# maintenance job handlers, the maintenance HTTP routes). Each fixture
# builds a v1 doctype with a `migrate_from_1` script, so a spec can bump
# the definition to v2 — with a working script (the happy path) or a
# `ctx.error` script (the failure path) — and drive the migration
# machinery over a real corpus.

# Seeds a v1 doctype whose `migrate_from_1` fills `priority`, creates
# *count* documents, and returns their ids. The definition stays at v1 —
# the caller bumps it to the v2 shape it needs.
def seed_v1_documents(db, domain, dt, count) : Array(String)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = 'migrated'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  ensure_domain(db, domain)
  Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Create::Result)

  ids = [] of String
  count.times do |i|
    r = Facet::Document::Create.call(db, domain, dt, %({"title": "doc #{i}"}), Facet::RBAC::AuthContext.system)
    ids << r.as(Facet::Document::Create::Result).projection.id
  end
  ids
end

# Bumps the doctype to v2 with a failing migration body (the broken shape
# every failure-path spec starts from). Includes the `migrations` map — a
# version-bumping update may carry one.
def bump_to_v2(db, domain, dt) : Nil
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.error('boom')
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{dt}")
end

# Bumps the doctype to v2 with a working `migrate_from_1` — the happy-path
# shape. Includes the `migrations` map.
def bump_to_v2_working(db, domain, dt) : Nil
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = 'migrated'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{dt}")
end

# Re-saves the doctype at v2 with a working `migrate_from_1`. The body
# omits the `migrations` map — a same-version (non-breaking) update must
# not carry one; the stored map survives the merge.
def fix_v2_script(db, domain, dt) : Nil
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = 'migrated'
    end
    return export
  LUA
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, "#{domain}.#{dt}", v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{dt}")
end
