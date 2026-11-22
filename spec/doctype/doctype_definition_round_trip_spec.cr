# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-101ext round-trip guard. A document GET masks every content key the
# doctype schema does not declare, so a GET → PUT round-trip of a doctype
# definition used to delete the definition keys the `core.DocType` seed
# schema did not declare (sidecar, sidecars, surface, scopes, identifier).
# These specs author doctypes with every declarable definition key set,
# drive the HTTP GET → PUT round-trip as a Real principal — the only
# principal the mask applies to; System and Preview see raw content — and
# compare the stored definition through `DefinitionStore`. No key lost.
#
# The mask walks the seed schema's NESTED declarations too: the last spec
# covers the entry keys one level down (a secret field's `mode`, an
# action's `description` — B-124, B-125). `core_doctype_seed_keys_guard_spec.cr`
# guards every nested level against the entry parsers' KNOWN_KEYS, so a
# new definition key added to `FieldDefinition` etc. must also be declared
# in `data/seeds/core.DocType/definition.yml` or the guard fails.
#
# `search` rides the full-definition fixture: the seed schema declares it
# (see the note in `core_doctype_seed_keys_guard_spec.cr`), so the mask
# keeps the template and the round-trip carries it.
#
# `migrations` needs no round-trip of its own: a same-version edit that
# carries `migrations` is refused by the version gate (never bypassed,
# even under `$force`), and a version-bump PUT must carry the migration
# entries the gaps demand. The gate, not the mask, protects the key; the
# bump leg below stores it.

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

# A Real principal with the seeded admin role: the wildcard permission line
# passes the read and write gates, and the wildcard visible tag keeps every
# declared field visible. Undeclared keys still drop for Real principals —
# exactly the bug surface.
private def round_trip_admin_context(db) : Facet::RBAC::AuthContext
  seed_test_roles(db)
  role_content = Facet::IAM::Helpers.find_role_content(db, "iam.Roles.admin").not_nil!
  role = Facet::RBAC::ActiveRole.from_projection_content(role_content)
  Facet::RBAC::AuthContext.authenticated("roundtrip_#{unique_suffix(6)}", role)
end

# Lua script for the fixtures: one export per declared action and, on the
# bump body, one per declared migration (ScriptValidator).
private def round_trip_script(with_migrations : Bool) : String
  migrate = with_migrations ? "function export.migrate_from_1(doc) return doc end" : ""
  <<-LUA
  local export = {}
  function export.rename(ctx, args) return {} end
  #{migrate}
  return export
  LUA
end

# A definition body that sets every declarable definition key.
# `member_of` is absent on purpose: it is mutually exclusive with
# `aggregate_root: true`, and a `member_of` child cannot ride the flat
# create route. `surface` rides only on the sidecar fixture (it is refused
# without `sidecar: true`).
private def full_definition_body(suffix : String) : String
  script = round_trip_script(with_migrations: false)
  %({"doctype": "Gadget#{suffix}", "domain": "rt#{suffix}", "schema_version": 1,
     "aggregate_root": true, "description": "Round-trip fixture doctype.",
     "label": "Gadgets", "icon": "box", "color": "#1565C0", "plural_label": "gadgets",
     "sensitive": true, "nav_visible": true,
     "display_name": "{{ title }}",
     "search": "{{ title }}",
     "fields": {"title": {"type": "string", "required": true, "title": "Title"}},
     "actions": {"rename": {"args": {"new_title": {"type": "string", "required": true}}}},
     "children": {"parts": {"doctype": "Part#{suffix}", "collection": true, "description": "Owned parts."}},
     "sidecars": {"notes": {"doctype": "core.Comment", "column": "target", "order": 1, "label": "Notes"}},
     "scopes": {"mine": {"description": "Rows whose title matches the actioner", "where": {"title": "$self"}}},
     "identifier": {"template": "GDG-#{suffix}-####", "genonly": true},
     "script": #{script.to_json}})
end

private def sidecar_definition_body(suffix : String) : String
  %({"doctype": "Note#{suffix}", "domain": "core", "schema_version": 1,
     "aggregate_root": true, "sidecar": true, "surface": "note",
     "description": "Sidecar round-trip fixture.",
     "display_name": "{{ body }}",
     "fields": {
       "target": {"type": "reference", "required": true, "read_only": true},
       "body": {"type": "longtext", "required": true}
     }})
end

# The B-124 / B-125 fixture: a secret field (whose `mode` the GET mask used
# to drop) and an action carrying a `description` (dropped the same way).
# Both keys sit one level below the ones the top-level B-101ext guard
# covers — the mask walks the seed schema's nested `fields.values.properties`
# and `fields.actions.values.properties` declarations.
private def secret_definition_body(suffix : String) : String
  script = round_trip_script(with_migrations: false)
  %({"doctype": "Vault#{suffix}", "domain": "rt#{suffix}", "schema_version": 1,
     "aggregate_root": true,
     "display_name": "{{ title }}",
     "search": "{{ title }}",
     "fields": {"title": {"type": "string", "required": true},
                "salary": {"type": "secret", "mode": "sealed", "tags": ["pay"], "title": "Salary"}},
     "actions": {"rename": {"args": {"new_title": {"type": "string", "required": true}},
                            "description": "Renames the record.",
                            "event_name": "record_renamed"}},
     "script": #{script.to_json}})
end

private def create_fixture_doctype(body : String) : String
  resp = create_doctype_http(body)
  assert_http_status(resp, 201)
  JSON.parse(resp.body)["meta"]["id"].as_s
end

# An array-of-reference field: the reference target lives on the `items`
# sub-definition, not on the parent. `refs` targets a doctype the same
# domain declares, so the authoring gate accepts the qualified form.
private def array_of_reference_definition_body(suffix : String) : String
  %({"doctype": "Specimen#{suffix}", "domain": "rt#{suffix}", "schema_version": 1,
     "aggregate_root": true,
     "display_name": "{{ title }}",
     "search": "{{ title }}",
     "fields": {
       "title": {"type": "string", "required": true},
       "refs": {"type": "array", "items": {"type": "reference", "doctype": "rt#{suffix}.Partner"}}
     }})
end

private def get_definition(doctype_id : String, ctx : Facet::RBAC::AuthContext) : JSON::Any
  Fiber.current.auth_context = ctx
  resp = get_document_http("core", "DocType", doctype_id)
  Fiber.current.auth_context = nil
  assert_http_status(resp, 200)
  JSON.parse(resp.body)["data"]
end

private def put_definition(doctype_id : String, body : String, ctx : Facet::RBAC::AuthContext) : HTTP::Client::Response
  request = HTTP::Request.new("PUT", "/Api/core/DocType/#{doctype_id}", body: body)
  call_api_as(request, ctx)
end

# The editor's PUT body for the bump leg: the GET body, one deliberate
# edit, and a legal breaking change (schema_version +1 with the migration
# entry and its Lua export). The replace actually writes.
private def bump_put_body(get_data : JSON::Any, suffix : String, new_description : String) : String
  h = get_data.as_h.dup
  h["description"] = JSON::Any.new(new_description)
  h["schema_version"] = JSON::Any.new(2_i64)
  h["migrations"] = JSON.parse(%({"1": "migrate_from_1"}))
  h["script"] = JSON::Any.new(round_trip_script(with_migrations: true))
  JSON::Any.new(h).to_json
end

# The typed read of the stored definition. `fetch_uncached` bypasses the
# request cache; the raw read proves the row exists.
private def stored_definition(db, doctype_id : String) : Facet::Doctype::DoctypeDefinition
  raw = Facet::Doctype::DefinitionStore.fetch_raw(db, doctype_id)
  raw.should_not be_nil, "stored definition row missing for #{doctype_id}"
  defn = Facet::Doctype::DefinitionStore.fetch_uncached(db, doctype_id)
  defn.should_not be_nil, "stored definition unparseable for #{doctype_id}"
  defn.not_nil!
end

describe "Doctype definition GET → PUT round-trip (B-101ext)" do
  it "keeps every definition key through a GET → PUT replace that bumps the version" do
    suffix = unique_suffix(6)
    with_db do |db|
      ensure_domain(db, "core")
      ensure_domain(db, "rt#{suffix}")
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")

      doctype_id = create_fixture_doctype(full_definition_body(suffix))
      ctx = round_trip_admin_context(db)

      get_data = get_definition(doctype_id, ctx)
      new_description = "Round-trip fixture doctype, edited once."

      put_resp = put_definition(doctype_id, bump_put_body(get_data, suffix, new_description), ctx)
      assert_http_status(put_resp, 200)

      # The stored definition keeps the exact key set the GET returned,
      # plus the `migrations` entry the bump leg adds.
      raw = Facet::Doctype::DefinitionStore.fetch_raw(db, doctype_id).not_nil!
      content, _meta = raw
      expected_keys = get_data.as_h.keys + ["migrations"]
      content.as_h.keys.sort!.should eq(expected_keys.sort!)

      defn = stored_definition(db, doctype_id)
      # The edit landed — the replace actually wrote.
      defn.description.should eq(new_description)

      # The keys the mask used to drop carry their values.
      defn.sidecars["notes"].doctype.should eq("core.Comment")
      defn.sidecars["notes"].column.should eq("target")
      defn.sidecars["notes"].order.should eq(1)
      defn.sidecars["notes"].label.should eq("Notes")
      defn.scopes["mine"].where.should eq({"title" => "$self"})
      identifier = defn.identifier
      identifier.should_not be_nil
      identifier.not_nil!.template.should eq("GDG-#{suffix}-####")
      identifier.not_nil!.genonly?.should be_true

      # The rest of the definition round-trips too.
      defn.actions.has_key?("rename").should be_true
      defn.children.has_key?("parts").should be_true
      defn.migrations.should eq({"1" => "migrate_from_1"})
      defn.display_name.should eq("{{ title }}")
      defn.search.should eq("{{ title }}")
      defn.script.should eq(round_trip_script(with_migrations: true))
      defn.schema_version.should eq(2)
      defn.aggregate_root.should be_true
      defn.sensitive.should be_true
      defn.nav_visible.should be_true
      defn.plural_label.should eq("gadgets")
      defn.label.should eq("Gadgets")
      defn.icon.should eq("box")
      defn.color.should eq("#1565C0")
      defn.fields.has_key?("title").should be_true

      # A second GET still returns the previously-masked keys.
      get_data2 = get_definition(doctype_id, ctx)
      %w[search sidecars scopes identifier migrations label].each do |key|
        get_data2.as_h.has_key?(key).should be_true, "GET response lost '#{key}' after the round-trip"
      end

      # The definition row's projection label prefers the label over the
      # bare doctype name (the stored core.DocType display template), and
      # the corpus carries the label ahead of the qualified id.
      row = db.query_one(
        "SELECT search, display_name FROM projections WHERE id = $1",
        doctype_id, as: {search: String?, display_name: String?}
      )
      row[:display_name].should eq("Gadgets")
      row[:search].should_not be_nil
      row[:search].not_nil!.should contain("gadgets")
      row[:search].not_nil!.should contain("rt#{suffix}.gadget#{suffix}".downcase)
    end
  end

  it "answers 200 with the unchanged projection when the unmodified GET body is PUT back" do
    # The mask must return the complete stored definition: any dropped key
    # would make the PUT a real change, and the replace would delete it.
    # An idempotent re-save is a success, not a caller error.
    suffix = unique_suffix(6)
    with_db do |db|
      ensure_domain(db, "core")
      ensure_domain(db, "rt#{suffix}")
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")

      doctype_id = create_fixture_doctype(full_definition_body(suffix))
      ctx = round_trip_admin_context(db)

      get_data = get_definition(doctype_id, ctx)

      put_resp = put_definition(doctype_id, get_data.to_json, ctx)
      assert_http_status(put_resp, 200)

      defn = stored_definition(db, doctype_id)
      defn.sidecars.has_key?("notes").should be_true
      defn.scopes.has_key?("mine").should be_true
      defn.identifier.should_not be_nil
    end
  end

  it "accepts a GET → PUT round-trip of an array-of-reference field (F10-04)" do
    # The GET response presents the array item's full definition, target
    # included; a faithful round-trip is therefore accepted — the data-shape
    # guard never sees a dropped reference target.
    suffix = unique_suffix(6)
    with_db do |db|
      ensure_domain(db, "core")
      ensure_domain(db, "rt#{suffix}")
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")

      doctype_id = create_fixture_doctype(array_of_reference_definition_body(suffix))
      ctx = round_trip_admin_context(db)

      get_data = get_definition(doctype_id, ctx)
      refs = get_data.as_h["fields"].as_h["refs"].as_h
      items = refs["items"].as_h
      items["type"].as_s.should eq("reference")
      items["doctype"].as_s.should eq("rt#{suffix}.Partner"),
        "GET dropped the array item's reference target — a GET → PUT round-trip is refused"

      # A faithful round-trip (no edit) is a 200 no-op.
      put_resp = put_definition(doctype_id, get_data.to_json, ctx)
      assert_http_status(put_resp, 200)

      defn = stored_definition(db, doctype_id)
      defn.fields["refs"].items.not_nil!.doctype.should eq("rt#{suffix}.Partner")
    end
  end

  it "keeps the sidecar and surface keys on a sidecar doctype round-trip" do
    suffix = unique_suffix(6)
    with_db do |db|
      ensure_domain(db, "core")
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")

      doctype_id = create_fixture_doctype(sidecar_definition_body(suffix))
      ctx = round_trip_admin_context(db)

      get_data = get_definition(doctype_id, ctx)
      get_data.as_h.has_key?("sidecar").should be_true
      get_data.as_h.has_key?("surface").should be_true

      h = get_data.as_h.dup
      h["description"] = JSON::Any.new("Sidecar fixture, edited once.")
      put_resp = put_definition(doctype_id, JSON::Any.new(h).to_json, ctx)
      assert_http_status(put_resp, 200)

      defn = stored_definition(db, doctype_id)
      defn.sidecar.should be_true
      defn.surface.should eq("note")
      defn.description.should eq("Sidecar fixture, edited once.")
    end
  end

  it "keeps a secret field's mode and an action's description on the GET body (B-124, B-125)" do
    suffix = unique_suffix(6)
    with_db do |db|
      ensure_domain(db, "core")
      ensure_domain(db, "rt#{suffix}")
      Facet::Doctype::Seed.ensure_doctype_definition(db, "core", "DocType")

      doctype_id = create_fixture_doctype(secret_definition_body(suffix))
      ctx = round_trip_admin_context(db)

      get_data = get_definition(doctype_id, ctx)
      salary = get_data.as_h["fields"].as_h["salary"].as_h
      salary.has_key?("mode").should be_true,
        "GET dropped the secret field's 'mode' (B-124) — a verbatim GET → PUT round-trip fails or corrupts"
      salary["mode"].as_s.should eq("sealed")
      rename = get_data.as_h["actions"].as_h["rename"].as_h
      rename.has_key?("description").should be_true,
        "GET dropped the action's 'description' (B-125) — a verbatim GET → PUT round-trip silently deletes it"
      rename["description"].as_s.should eq("Renames the record.")

      # The mask must return the complete stored definition: any dropped key
      # would make the PUT a real change, and the replace would delete it.
      put_resp = put_definition(doctype_id, get_data.to_json, ctx)
      assert_http_status(put_resp, 200)

      defn = stored_definition(db, doctype_id)
      defn.fields["salary"].mode.should eq("sealed")
      defn.actions["rename"].description.should eq("Renames the record.")
    end
  end
end
