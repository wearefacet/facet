# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Doctype definition helpers ────────────────────────────────────────────
#
# Helpers for loading, building, and persisting doctype definitions in tests.
# These are top-level functions available in every spec.
#
# Doctype definitions are stored inside portable-domain bundles at
# `data/fixtures/{domain}.facet-domain/doctypes/{Qualified}.yml`. The Lua
# `script` is either embedded in the doctype's `content` or pulled in from a
# co-located `doctypes/{Qualified}.lua` via the `!read_file` directive (see
# `Facet::Util::YamlInclude`). Either way the parsed definition carries the
# script; callers that pass a `script_path` to `build_doctype_definition` are
# silently ignored — the script already rides along inside the definition.

require "../../src/document"
require "../../src/mutation/client"
require "../../src/mutation/json_diff"
require "../../src/rbac"
require "../../src/util/yaml_include"

# Resolves a path relative to the fixtures directory (`data/fixtures/`).
def data_path(relative_path : String) : String
  File.join(__DIR__, "..", "..", "data", "fixtures", relative_path)
end

# Parses a doctype definition from a bundle entry file.
#
# `relative_path` accepts the legacy per-doctype form
# `"{domain}.{Doctype}/definition.yml"` for backward compatibility with spec
# call sites written before the bundle migration — it is rewritten to the
# bundle path `data/fixtures/{domain}.facet-domain/doctypes/{domain}.{Doctype}.yml`.
# A direct bundle-relative path (e.g. `"crm.facet-domain/doctypes/crm.Deal.yml"`)
# is also accepted verbatim.
def load_doctype_schema(relative_path : String) : Facet::Doctype::DoctypeDefinition
  path = resolve_doctype_path(relative_path)
  case File.extname(path)
  when ".yml", ".yaml"
    # Bundle entries are `{ content, meta }`; the definition IS the content.
    # Parsing goes through `Util::YamlInclude.parse_file` so the `!read_file`
    # directive used by doctype fixture scripts resolves against the entry
    # file's own directory (jail-restricted to that directory).
    entry = Facet::Util::YamlInclude.parse_file(path, [Facet::Util::YamlTag::ReadFileTag.new])
    content_json = entry["content"]?.try(&.to_json) || File.read(path)
    Facet::Doctype::DoctypeDefinition.from_json(content_json)
  else
    Facet::Doctype::DoctypeDefinition.from_json(File.read(path))
  end
end

# `load_doctype_script` is kept for backward compatibility with older spec
# call sites. In the bundle format the Lua script rides along inside the
# doctype definition (either inline or via `!read_file` of a co-located
# `doctypes/{Qualified}.lua` file) — there is no separate `script.lua` to
# load — so this helper returns an empty string. The definition returned by
# `load_doctype_schema` already carries the script.
def load_doctype_script(relative_path : String) : String
  ""
end

# Builds a doctype definition. In the bundle format the Lua `script` rides
# along inside the doctype's `content` (inline or via `!read_file`), so the
# `script_path` argument is accepted but ignored — the returned definition
# carries the script straight from the bundle entry, and every field
# round-trips intact.
def build_doctype_definition(schema_path : String, script_path : String? = nil) : Facet::Doctype::DoctypeDefinition
  load_doctype_schema(schema_path)
end

# Ensures a core.DomainGrant document exists under the producer domain,
# admitting the consumer on the given resources. `resources_json` is a JSON
# array of `{doctype, tags}` entries — tag grain, matched against producer
# field tags (untagged fields carry `default`). Idempotent per (producer,
# consumer): an existing grant is patched to the new resources; a missing
# one is created with the parent link set. `active` follows the D11
# publisher semantics — default `true` (the admin-publisher shortcut).
# Marks the grants registry stale so a subsequent read rebuilds.
def upsert_grant(db, producer, consumer, resources_json, active = true)
  exists_row = db.query_one?("SELECT id FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant' AND deleted_at IS NULL AND meta->>'parent_id' = $1", producer) do |rs|
    rs.read(String)
  end

  content = %({"consumer_domain": "core.Domain.#{consumer}", "resources": #{resources_json}, "active": #{active}})

  if exists_row
    old_content = db.query_one(
      "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant' AND id = $1",
      exists_row,
      as: JSON::Any
    )
    diff = Facet::Mutation::JsonDiff.diff(old_content, JSON.parse(content))
    unless diff.empty?
      Facet::Mutation::Client.update(db, "core", "DomainGrant", exists_row, diff_json: diff.to_json)
      Facet::Event::Publisher.enqueue(
        domain: "core", doc_type: "DomainGrant", doc_id: exists_row,
        event: "updated", actioner_id: "system",
      )
    end
  else
    doc_id = Facet::Util::ScriptHelpers.ulid
    Facet::Mutation::Client.create(
      db, "core", "DomainGrant",
      doc_id: doc_id,
      content: content,
      meta: %({"parent_id": #{producer.to_json}}),
      actioner_id: "system",
    )
    Facet::Event::Publisher.enqueue(
      domain: "core", doc_type: "DomainGrant", doc_id: doc_id,
      event: "created", actioner_id: "system",
    )
  end
  Facet::Grants::Registry.mark_stale
end

# Deletes every `core.DomainGrant` row and marks the grants registry
# stale. Specs that create grants call this in their teardown (the
# per-example truncation already wipes the projections).
def clear_grants(db)
  db.exec("DELETE FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant'")
  Facet::Grants::Registry.mark_stale
end

# Legacy-shape adapter kept for the replication specs' call sites: maps
# the old `[{to, doctype, fields}]` entries onto grant documents — one
# `core.DomainGrant` per entry, tags = the old field list mapped to
# ["default"] coverage. New specs should call `upsert_grant` directly.
def upsert_domain_with_grants(db, domain_name, grants_json)
  entries = Array(JSON::Any).from_json(grants_json)
  entries.group_by(&.["to"].as_s).each do |consumer, group|
    resources = group.map { |e| {doctype: e["doctype"].as_s, tags: ["default"]} }
    upsert_grant(db, domain_name, consumer, resources.to_json)
  end
end

# Ensures a core.Domain document exists for the given domain name.
# This is idempotent — if the domain already exists, it does nothing.
def ensure_domain(db : DB::Connection, domain : String) : Nil
  exists = db.query_one?(
    "SELECT 1 FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL",
    domain,
    as: Int32
  )
  return unless exists.nil?

  Facet::Mutation::Client.create(
    db,
    "core",
    "Domain",
    doc_id: domain,
    content: %({}),
    actioner_id: "system",
  )
end

# Creates a minimal doctype with caller-chosen fields. Returns the created
# doctype id (qualified name).
def create_simple_doctype(db, domain, doctype_name, fields_json)
  # The shared helper always declares a `search` template: the authoring
  # gate refuses an aggregate root with neither template (B-296), and every
  # caller here builds an aggregate root. `display_name` is the reserved
  # template variable, so the corpus compiles without knowing the fields.
  defn_json = %({
    "doctype": "#{doctype_name}",
    "domain": "#{domain}",
    "schema_version": 1,
    "search": "{{ display_name }}",
    "fields": #{fields_json}
  })
  defn = Facet::Doctype::DoctypeDefinition.from_json(defn_json)
  ensure_domain(db, domain)
  result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  expect_create_success(result)
end

# Creates an `identity.Person` document with the given name and a unique
# synthesized email (unless one is passed). Returns the document id.
def create_person(db, full_name = "Alice Liddell", email : String? = nil)
  person_id = Facet::Util::ScriptHelpers.ulid
  actual_email = email || "#{person_id}@example.com"
  Facet::Mutation::Client.create(
    db, "identity", "Person",
    doc_id: person_id,
    content: %({"full_name": "#{full_name}", "email": "#{actual_email}", "date_of_birth": "1990-01-01T00:00:00Z"}),
    actioner_id: "system",
  )
  person_id
end

# Persists a doctype definition via the document create service.
# Automatically ensures the domain exists before creation.
# Returns the result union (Result | Error).
def create_doctype(definition : Facet::Doctype::DoctypeDefinition) : Facet::Document::Create::Result | Facet::ServiceError
  with_db do |db|
    ensure_domain(db, definition.domain)
    Facet::Document::Create.call(db, "core", "DocType", definition.to_json, Facet::RBAC::AuthContext.system)
  end
end

# Convenience: loads, builds (with optional script), and persists a doctype
# in one call. Returns the result union.
def create_doctype_from_data(schema_path : String, script_path : String? = nil) : Facet::Document::Create::Result | Facet::ServiceError
  defn = build_doctype_definition(schema_path, script_path)
  create_doctype(defn)
end

# Creates a doctype with caller-chosen fields and optional named scopes.
# An optional `search` template makes the doctype searchable. When no
# `search` is passed the helper declares `{{ display_name }}` instead: the
# authoring gate refuses an aggregate root with neither template (B-296),
# and `display_name` is the reserved template variable, so the corpus
# compiles without knowing the fields. The doctype name is unique per test
# (`T#{unique_suffix}`). Returns `[domain, doctype]`.
def build_agg_doctype(db, domain : String, fields : String, scopes : String = "{}", search : String? = nil) : {String, String}
  ensure_domain(db, domain)
  doctype = "T#{unique_suffix}"
  se = %("search": #{(search || "{{ display_name }}").to_json}, )
  defn = %({"doctype": "#{doctype}", "domain": "#{domain}", "aggregate_root": true, #{se}"fields": #{fields}, "scopes": #{scopes}})
  Facet::Doctype::DefinitionStore.invalidate("#{domain}.#{doctype}")
  expect_create_success(Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system))
  {domain, doctype}
end

# Builds a doctype that exercises every filter-target family the operator
# validator routes by: a string, an integer (typed), a period (range), a
# money field, an array container, and a reference. The doctype is
# searchable by name, so the bare `search` filter can join combined-filter
# assertions. Used by the agent-tools operator-validation specs so each
# family's accepted operator set can be asserted against.
def build_operator_doctype(db, domain : String) : {String, String}
  fields = %({
    "name":   {"type": "string", "required": true, "filters": ["comparison", "text_search"]},
    "qty":    {"type": "integer", "filters": ["comparison"]},
    "window": {"type": "period", "filters": ["interval"]},
    "price":  {"type": "money", "filters": ["comparison", "currency"]},
    "tags":   {"type": "array", "items": {"type": "string"}, "filters": ["membership"]},
    "owner":  {"type": "reference", "doctype": "iam.Account", "filters": ["equality"]}
  })
  build_agg_doctype(db, domain, fields, search: "{{ name }}")
end

# Builds the backref-fixture doctype trio in one domain: `Team` (the
# backref target), `Project` and `Task` (each with a `team` reference).
# Each declares `search: {{ display_name }}` so the authoring label gate
# (B-296) admits them. Returns `[domain, team_doctype, project_doctype,
# task_doctype]`. Used by the agent-tools get_backrefs specs.
def build_backref_fixture(db) : {String, String, String, String}
  domain = "mcpback"
  ensure_domain(db, domain)
  Facet::Document::Create.call(db, "core", "DocType", %({
    "doctype": "Team", "domain": "#{domain}", "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": {"name": {"type": "string", "required": true}}
  }), Facet::RBAC::AuthContext.system)
  Facet::Document::Create.call(db, "core", "DocType", %({
    "doctype": "Project", "domain": "#{domain}", "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string", "required": true},
      "team": {"type": "reference", "doctype": "#{domain}.Team"}
    }
  }), Facet::RBAC::AuthContext.system)
  Facet::Document::Create.call(db, "core", "DocType", %({
    "doctype": "Task", "domain": "#{domain}", "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": {
      "name": {"type": "string", "required": true},
      "team": {"type": "reference", "doctype": "#{domain}.Team"}
    }
  }), Facet::RBAC::AuthContext.system)
  {domain, "Team", "Project", "Task"}
end

# Builds the scope-fixture doctype: `title` string plus an `owner`
# reference, with a `mine` named scope whose `where` binds `$self`. Used by
# the agent-tools scope-argument specs. Returns `[domain, doctype]`.
def build_scope_fixture(db) : {String, String}
  fields = %({
    "title": {"type": "string", "required": true, "filters": ["equality"]},
    "owner": {"type": "reference", "doctype": "iam.Account"}
  })
  scopes = %({"mine": {"where": {"owner": "$self"}, "description": "Rows owned by the actioner"}})
  build_agg_doctype(db, "mcpscope", fields, scopes)
end

# Builds the expand-fixture pair: `Gadget` (one string field) and `Widget`
# (a reference to Gadget plus a plain string). Both declare a search
# template on `name`, so the search_documents tool can match their rows.
# Returns `[domain, gadget_doctype, widget_doctype]`. Used by the
# agent-tools expand/resolved-map specs.
def build_expand_fixture(db) : {String, String, String}
  domain = "mcpexp"
  ensure_domain(db, domain)
  Facet::Document::Create.call(db, "core", "DocType", %({
    "doctype": "Gadget", "domain": "#{domain}", "aggregate_root": true,
    "search": "{{ name }}",
    "fields": {"name": {"type": "string", "required": true}}
  }), Facet::RBAC::AuthContext.system)
  Facet::Document::Create.call(db, "core", "DocType", %({
    "doctype": "Widget", "domain": "#{domain}", "aggregate_root": true,
    "search": "{{ name }}",
    "fields": {
      "name":   {"type": "string", "required": true},
      "gadget": {"type": "reference", "doctype": "#{domain}.Gadget"},
      "title":  {"type": "string"}
    }
  }), Facet::RBAC::AuthContext.system)
  {domain, "Gadget", "Widget"}
end

# Registers the three HR doctypes (Person, Employee, CareerEvent) in order.
# Returns a named tuple with each result.
def register_hr_doctypes
  person_res = create_doctype_from_data("identity.Person/definition.yml")
  employee_res = create_doctype_from_data("hr.Employee/definition.yml", "hr.Employee/script.lua")
  career_res = create_doctype_from_data("hr.CareerEvent/definition.yml")

  {person: person_res, employee: employee_res, career: career_res}
end

# ── Private helpers ─────────────────────────────────────────────────────────

# Resolves a legacy `{domain}.{Doctype}/definition.yml` path (or any
# `{domain}.{Doctype}/{file}` form) to its bundle entry file
# `data/fixtures/{domain}.facet-domain/doctypes/{domain}.{Doctype}.yml`.
# Direct bundle-relative paths (e.g.
# `"crm.facet-domain/doctypes/crm.Deal.yml"`) are returned verbatim.
private def resolve_doctype_path(relative_path : String) : String
  return data_path(relative_path) if relative_path.includes?(".facet-domain/")

  # Legacy `{domain}.{Doctype}/definition.{yml,yaml,json}` form.
  dir = File.dirname(relative_path)
  ext = File.extname(relative_path)
  return data_path(relative_path) if dir == "." || ext.empty?

  # `dir` is `{domain}.{Doctype}` — split the leading domain segment so the
  # bundle directory (named after the domain) is correct: the bundle for
  # `crm.PipelineStage` is `crm.facet-domain`, not `crm.PipelineStage.facet-domain`.
  # Bundle entries are named after the full qualified doctype.
  domain_segment = dir.split('.', 2)[0]
  bundle_path = "#{domain_segment}.facet-domain/doctypes/#{dir}.yml"
  data_path(bundle_path)
end
