# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# ── Helpers (top-level, like doctype_helper.cr) ───────────────────────

# Creates a doctype at version 1 (returns its qualified id).
def create_v1_doctype(db, domain, dt, script = nil)
  fields_json = %({"title": {"type": "string", "required": true}})
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ title }}", "fields": #{fields_json}})

  if script
    body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ title }}", "fields": #{fields_json}, "script": #{script.to_json}})
  end

  ensure_domain(db, domain)
  defn = Facet::Doctype::DoctypeDefinition.from_json(body)
  result = Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Doctype::Create::Result)
  "#{domain}.#{dt}"
end

# Returns a v2 definition JSON string for update.
def v2_defn_json(domain, dt, script = nil, migrations = nil)
  fields_json = %({"title": {"type": "string", "required": true}, "priority": {"type": "string"}})
  mig_json = (migrations || {"1" => "migrate_from_1"}).to_json
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "migrations": #{mig_json}})

  if script
    body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ title }}", "fields": #{fields_json}, "migrations": #{mig_json}, "script": #{script.to_json}})
  end
  body
end

# Creates a v1 doctype with caller-chosen fields (and optional extra JSON
# members such as `children` / `member_of`). Returns its qualified id.
def create_v1_fields_doctype(db, domain, dt, fields_json, extra = "")
  ensure_domain(db, domain)
  body = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": #{fields_json}#{extra}})
  defn = Facet::Doctype::DoctypeDefinition.from_json(body)
  result = Facet::Doctype::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Doctype::Create::Result)
  "#{domain}.#{dt}"
end

# Builds a same-version (still v1) update body with caller-chosen fields.
def same_v1_body(domain, dt, fields_json, extra = "")
  %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": #{fields_json}#{extra}})
end

# Asserts the generic same-version data-shape rejection naming `label`.
def assert_shape_rejection(result, label)
  case result
  in Facet::ServiceError
    result.status.should eq(422)
    result.message.should contain("data shape")
    result.message.should contain(label)
  in Facet::Doctype::Update::Result
    fail "Expected data-shape rejection but got success"
  end
end

# Asserts a successful update and returns the mutation id.
def assert_update_ok(result) : String
  case result
  in Facet::Doctype::Update::Result
    result.mutation_id.should be_a(String)
    result.mutation_id
  in Facet::ServiceError
    fail "Update failed: #{result.message}"
  end
end

# Seeds a draft domain row (`draft: true`, `_`-prefixed id) and one doctype
# in it, written directly — the same shape `Domain::Draft.create` and the
# builder editor's nested create produce. Returns the qualified doctype id.
def seed_b93_draft_doctype(db, dt) : String
  draft = "_#{unique_suffix(12)}"
  Facet::Mutation::Client.create(
    db, "core", "Domain", doc_id: draft, content: %({"draft": true}),
    actioner_id: "system:test",
  )
  doctype_id = "#{draft}.#{dt}"
  Facet::Mutation::Client.create(
    db, "core", "DocType", doc_id: doctype_id,
    content: %({"doctype": "#{dt}", "domain": "#{draft}", "schema_version": 1, "search": "{{ display_name }}", "fields": {"label": {"type": "string", "required": true}}}),
    actioner_id: "system:test",
  )
  Facet::Doctype::DefinitionStore.invalidate(doctype_id)
  doctype_id
end

# Builds the editor's GET→PUT round-trip body: the stored definition with
# one added field, `domain` and `doctype` echoed unchanged.
def b93_round_trip_body(db, doctype_id) : String
  stored = Facet::Mutation::Client.fetch_content(db, "core", "DocType", doctype_id)
  h = stored.as_h.dup
  fields = h["fields"].as_h.dup
  fields["title"] = JSON.parse(%({"type": "string"}))
  h["fields"] = JSON::Any.new(fields)
  JSON::Any.new(h).to_json
end

# Bumps a doctype to v2 with a migration entry and returns its id.
def bump_to_v2_with_migration(db, domain, dt)
  doctype_id = create_v1_doctype(db, domain, dt)
  script = <<-LUA
    local export = {}
    function export.create(ctx) end
    function export.migrate_from_1(ctx)
      ctx.root.priority = ctx.root.priority or 'normal'
    end
    return export
  LUA
  v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}, "priority": {"type": "string"}}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})
  Facet::Doctype::Update.call(db, doctype_id, v2, Facet::RBAC::AuthContext.system).should be_a(Facet::Doctype::Update::Result)
  doctype_id
end

module Facet::Doctype
  describe Update do
    # ── Happy path ────────────────────────────────────────────────────

    it "updates a doctype from v1 to v2 with a migration entry" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          return export
        LUA

        new_defn = v2_defn_json(domain, dt, script)

        result = Update.call(db, doctype_id, new_defn, Facet::RBAC::AuthContext.system)

        case result
        in Update::Result
          result.mutation_id.should be_a(String)
          result.mutation_id.should_not be_empty
        in Facet::ServiceError
          fail "Update failed: #{result.message} (#{result.details.not_nil!.map(&.message).join("; ")})"
        end
      end
    end

    it "updates a doctype and the stored content reflects the new version" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          return export
        LUA

        new_defn = v2_defn_json(domain, dt, script)
        result = Update.call(db, doctype_id, new_defn, Facet::RBAC::AuthContext.system)
        result.should be_a(Update::Result)

        # Verify the stored content was updated
        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.schema_version.should eq(2)
        stored_defn.migrations.should eq({"1" => "migrate_from_1"})
        stored_defn.fields.keys.should contain("priority")
      end
    end

    # ── Error: doctype does not exist ─────────────────────────────────

    it "answers 200 with the unchanged projection when the body matches the stored definition (F03-03)" do
      with_temp_doctype("noop") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)
        stored = Facet::Mutation::Client.fetch_content(db, "core", "DocType", doctype_id)

        result = Update.call(db, doctype_id, stored.to_json, Facet::RBAC::AuthContext.system)
        case result
        in Update::Result
          result.unchanged.should be_true
          # The row's current `state` — the same ETag validator a GET serves.
          state = db.query_one("SELECT state FROM projections WHERE id = $1", doctype_id, as: String)
          result.mutation_id.should eq(state)
        in Facet::ServiceError
          fail "Expected an idempotent success but got #{result.status}: #{result.message}"
        end

        # No mutation row was written — an idempotent re-save is not an event.
        mutation_count = db.scalar("SELECT count(*) FROM mutations WHERE doc_id = $1", doctype_id).as(Int64)
        mutation_count.should eq(1) # only the create
      end
    end

    it "returns 404 when the doctype does not exist" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = "#{domain}.#{dt}"
        # Valid JSON body but doctype does not exist
        result = Update.call(db, doctype_id, %({"doctype": "#{dt}", "domain": "#{domain}"}), Facet::RBAC::AuthContext.system)

        case result
        in Facet::ServiceError
          result.status.should eq(404)
          result.message.should contain("not found")
        in Update::Result
          fail "Expected error but got success"
        end
      end
    end

    # ── Same-version update (non-breaking) ────────────────────────────

    it "allows a same-version update without migrations (non-breaking edit)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version 1, just add a description field
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        same_v1 = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {
            "title": {"type": "string", "required": true},
            "description": {"type": "longtext"}
          },
          "script": #{script.to_json}
        })

        result = Update.call(db, doctype_id, same_v1, Facet::RBAC::AuthContext.system)
        case result
        in Update::Result
          result.mutation_id.should be_a(String)
          result.mutation_id.should_not be_empty
        in Facet::ServiceError
          fail "Update failed: #{result.message}"
        end

        # Verify stored schema_version is still 1
        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.schema_version.should eq(1)
        stored_defn.fields.keys.should contain("description")
      end
    end

    it "rejects same-version update that removes a field (without $force)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version but removes the 'title' field
        no_title = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {}
        })

        result = Update.call(db, doctype_id, no_title, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("remove fields")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    it "allows same-version update that removes a field with $force: true" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version, removes title field, with $force
        no_title_force = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {},
          "$force": true
        })

        result = Update.call(db, doctype_id, no_title_force, Facet::RBAC::AuthContext.system)
        case result
        in Update::Result
          result.mutation_id.should be_a(String)
        in Facet::ServiceError
          fail "Update failed: #{result.message}"
        end
      end
    end

    it "rejects same-version update that changes a field type (without $force)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version but title changed from string to integer
        type_change = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {"title": {"type": "integer"}}
        })

        result = Update.call(db, doctype_id, type_change, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("change type of field")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    it "allows same-version update with $force bypasses field removal guard and type change guard" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version, removes title, adds priority as integer, with $force
        force_update = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {"priority": {"type": "integer"}},
          "$force": true
        })

        result = Update.call(db, doctype_id, force_update, Facet::RBAC::AuthContext.system)
        case result
        in Update::Result
          result.mutation_id.should be_a(String)
        in Facet::ServiceError
          fail "Update failed: #{result.message}"
        end

        # Verify the stored definition reflects the change
        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.schema_version.should eq(1)
        stored_defn.fields.keys.should eq(["priority"])
      end
    end

    it "rejects same-version update with migrations" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Same version but includes migrations — contradictory
        same_v1_with_mig = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 1,
          "search": "{{ display_name }}",
          "fields": {"title": {"type": "string", "required": true}},
          "migrations": {"1": "migrate_from_1"}
        })

        result = Update.call(db, doctype_id, same_v1_with_mig, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("Non-breaking update")
          result.message.should contain("migrations")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Stored migration map survives a same-version PUT (B-301) ──────

    it "carries the stored migrations across a same-version update (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = bump_to_v2_with_migration(db, domain, dt)

        # The editor's PUT body: same version, migrations omitted (the
        # guard forbids them), script and fields echoed in full.
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx)
            ctx.root.priority = ctx.root.priority or 'normal'
          end
          return export
        LUA
        same_v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}, "priority": {"type": "string"}, "note": {"type": "string"}}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, same_v2, Facet::RBAC::AuthContext.system)
        assert_update_ok(result)

        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.schema_version.should eq(2)
        stored_defn.migrations.should eq({"1" => "migrate_from_1"})
        stored_defn.script.should_not be_nil
        stored_defn.fields.keys.should contain("note")
      end
    end

    it "rejects a same-version update that drops the script while migrations are carried (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = bump_to_v2_with_migration(db, domain, dt)

        same_v2_no_script = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}, "priority": {"type": "string"}}})

        result = Update.call(db, doctype_id, same_v2_no_script, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.details.not_nil!.map(&.message).join("; ").should contain("migrations are declared but no script is defined")
        in Update::Result
          fail "Expected 422 but got success"
        end

        # The stored definition keeps its script.
        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        DoctypeDefinition.from_json(proj.content).script.should_not be_nil
      end
    end

    it "rejects a same-version script edit that removes a carried migration function (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = bump_to_v2_with_migration(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        same_v2 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}, "priority": {"type": "string"}}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, same_v2, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.details.not_nil!.map(&.message).join("; ").should contain("expects function 'migrate_from_1'")
        in Update::Result
          fail "Expected 422 but got success"
        end
      end
    end

    it "keeps the stored migration entries a breaking bump omits (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = bump_to_v2_with_migration(db, domain, dt)

        # v2 → v3 carrying only the new gap entry; "1" comes from the merge.
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          function export.migrate_from_2(ctx)
            ctx.root.version_tag = 'v3'
          end
          return export
        LUA
        v3 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}, "priority": {"type": "string"}}, "migrations": {"2": "migrate_from_2"}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, v3, Facet::RBAC::AuthContext.system)
        assert_update_ok(result)

        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.schema_version.should eq(3)
        stored_defn.migrations.should eq({"1" => "migrate_from_1", "2" => "migrate_from_2"})
      end
    end

    it "lets a $force same-version update drop the stored migration map (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = bump_to_v2_with_migration(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        forced = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "script": #{script.to_json}, "$force": true})

        result = Update.call(db, doctype_id, forced, Facet::RBAC::AuthContext.system)
        assert_update_ok(result)

        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored_defn = DoctypeDefinition.from_json(proj.content)
        stored_defn.migrations.should be_empty
      end
    end

    # ── Same-version data-shape gate (generic catch-all) ─────────────

    it "rejects a same-version nested property removal" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"meta": {"type": "object", "properties": {"city": {"type": "string"}}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"meta": {"type": "object", "properties": {}}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'meta' property 'city' removed")
      end
    end

    it "rejects a same-version nested property type change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"meta": {"type": "object", "properties": {"city": {"type": "string"}}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"meta": {"type": "object", "properties": {"city": {"type": "integer"}}}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'meta' property 'city' type string → integer")
      end
    end

    it "rejects a same-version collection flip" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"tag": {"type": "string", "collection": false}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"tag": {"type": "string", "collection": true}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'tag' collection false → true")
      end
    end

    it "rejects a same-version required tighten" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"name": {"type": "string"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"name": {"type": "string", "required": true}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'name' required false → true")
      end
    end

    it "rejects a same-version required loosen (symmetric add rule)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"name": {"type": "string", "required": true}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"name": {"type": "string"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'name' required true → false")
      end
    end

    it "rejects a same-version unique add" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"name": {"type": "string"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"name": {"type": "string", "unique": true}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'name' unique false → true")
      end
    end

    it "rejects a same-version min change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"age": {"type": "integer", "min": 0}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"age": {"type": "integer", "min": 18}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'age' min/max/pattern changed")
      end
    end

    it "rejects a same-version max change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"age": {"type": "integer", "max": 100}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"age": {"type": "integer", "max": 200}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'age' min/max/pattern changed")
      end
    end

    it "rejects a same-version pattern change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"code": {"type": "string", "pattern": "^[a-z]+$"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"code": {"type": "string", "pattern": "^[A-Z]+$"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'code' min/max/pattern changed")
      end
    end

    it "rejects a same-version pattern_flags change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"code": {"type": "string", "pattern": "x", "pattern_flags": "i"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"code": {"type": "string", "pattern": "x", "pattern_flags": "m"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'code' min/max/pattern changed")
      end
    end

    it "rejects a same-version enum key removal" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"status": {"type": "enum", "values": [{"key": "a"}]}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'status' enum keys changed")
      end
    end

    it "rejects a same-version reference target change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Contractor"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'owner' reference target hr.Employee → hr.Contractor")
      end
    end

    it "rejects a same-version owned change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee", "owned": true}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'owner' owned / on_source_delete / replicate / filter changed")
      end
    end

    it "rejects a same-version on_source_delete change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "name"}, "on_source_delete": "keep"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "name"}, "on_source_delete": "unset"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'owner_name' owned / on_source_delete / replicate / filter changed")
      end
    end

    it "rejects a same-version replicate change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "name"}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "surname"}}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'owner_name' owned / on_source_delete / replicate / filter changed")
      end
    end

    it "rejects a same-version reference filter change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee", "filter": {"status_eq": "active"}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee", "filter": {"status_eq": "inactive"}}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "field 'owner' owned / on_source_delete / replicate / filter changed")
      end
    end

    it "rejects a same-version children entry removal" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "children: entry 'events' removed")
      end
    end

    it "rejects a same-version children retarget" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Activity"}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "children: entry 'events' changed")
      end
    end

    it "rejects a same-version children collection flip" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event", "collection": false}})), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "children: entry 'events' changed")
      end
    end

    it "rejects a same-version member_of change" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({}),
          %(, "member_of": "Company")), Facet::RBAC::AuthContext.system)
        assert_shape_rejection(result, "member_of: none → Company")
      end
    end

    # Additive same-version edits stay legal without $force.

    it "allows a same-version enum key addition" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"status": {"type": "enum", "values": [{"key": "a"}]}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}})), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)
      end
    end

    it "allows a same-version nested property addition" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"addr": {"type": "object", "properties": {"city": {"type": "string"}}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"addr": {"type": "object", "properties": {"city": {"type": "string"}, "zip": {"type": "string"}}}})), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)
      end
    end

    it "allows a same-version children entry addition" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event"}})), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)
      end
    end

    # $force skips every same-version data-shape rejection.

    it "permits each non-reference data-shape class with $force: true" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"x": {"type": "string"}, "meta": {"type": "object", "properties": {"city": {"type": "string"}}}, "status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}),
          %(, "children": {"events": {"doctype": "Event"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"x": {"type": "string", "required": true, "collection": true}, "meta": {"type": "object", "properties": {}}, "status": {"type": "enum", "values": [{"key": "a"}]}}),
          %(, "member_of": "Company", "$force": true)), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)

        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        stored = DoctypeDefinition.from_json(proj.content)
        stored.schema_version.should eq(1)
        stored.member_of.should eq("Company")
      end
    end

    it "permits each reference-surface attribute change with $force: true" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Employee"}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "name"}}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt,
          %({"owner": {"type": "reference", "doctype": "hr.Contractor", "owned": true, "filter": {"status_eq": "active"}}, "owner_name": {"type": "string", "replicate": {"via": "owner", "field": "surname"}, "on_source_delete": "unset"}}),
          %(, "$force": true)), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)
      end
    end

    it "permits a children retarget and collection flip with $force: true" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_fields_doctype(db, domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Event"}}))
        result = Update.call(db, doctype_id, same_v1_body(domain, dt, %({}),
          %(, "children": {"events": {"doctype": "Activity", "collection": false}}, "$force": true)), Facet::RBAC::AuthContext.system)
        assert_update_ok(result)
      end
    end

    # ── Error: version cannot decrease ────────────────────────────────

    it "returns 422 when schema_version decreases" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Version 1, but existing is also 1 — wait, we need a scenario where
        # the new version is lower than the current. Let's create a v2 doctype first.
        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          return export
        LUA
        v2 = %({
          "doctype": "#{dt}",
          "domain": "#{domain}",
          "schema_version": 2,
          "search": "{{ display_name }}",
          "fields": {"title": {"type": "string", "required": true}},
          "migrations": {"1": "migrate_from_1"},
          "script": #{script.to_json}
        })
        Update.call(db, doctype_id, v2, Facet::RBAC::AuthContext.system).should be_a(Update::Result)

        # Now try to set version back to 1
        back_to_1 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 1, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}})

        result = Update.call(db, doctype_id, back_to_1, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("cannot decrease")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    it "returns 422 when schema_version jumps by more than 1" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        v3 = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 3, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "migrations": {"1": "migrate_from_1", "2": "migrate_from_2"}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, v3, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("schema_version must be exactly")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Error: doctype identity mismatch ──────────────────────────────

    it "returns 422 when doctype name is changed" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          return export
        LUA
        wrong_name = %({"doctype": "DifferentDoc", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, wrong_name, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("doctype and domain cannot be changed")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    it "returns 422 when domain is changed" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        script = <<-LUA
          local export = {}
          function export.create(ctx) end
          function export.migrate_from_1(ctx) end
          return export
        LUA
        wrong_domain = %({"doctype": "#{dt}", "domain": "xdomain", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "migrations": {"1": "migrate_from_1"}, "script": #{script.to_json}})

        result = Update.call(db, doctype_id, wrong_domain, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("doctype and domain cannot be changed")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Error: missing migration ──────────────────────────────────────

    it "returns 422 when migration from v1 is missing" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # v2 definition without migrations
        no_mig = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}})

        result = Update.call(db, doctype_id, no_mig, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.details.should be_a(Array(Facet::ValidationError))
          details = result.details.not_nil!
          details.any? { |e| e.code == "schema" && e.message.includes?("Migration") && e.message.includes?("v1") }.should be_true
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Error: invalid JSON body ──────────────────────────────────────

    it "returns 422 for unparseable JSON body" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)
        result = Update.call(db, doctype_id, "this is not json", Facet::RBAC::AuthContext.system)

        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("Invalid JSON body")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # F09-01 — the `$force` probe indexes the parsed body. A body that
    # parses but is not an object must answer `422`, not the `500` the
    # probe raises on the wrapped value.
    it "returns 422 for a JSON body that is not an object (F09-01)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)
        result = Update.call(db, doctype_id, %("x"), Facet::RBAC::AuthContext.system)

        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should eq("Invalid JSON body — the request body must be a JSON object")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    it "returns 422 for a JSON array body (F09-01)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)
        result = Update.call(db, doctype_id, %([1, 2]), Facet::RBAC::AuthContext.system)

        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should eq("Invalid JSON body — the request body must be a JSON object")
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Error: validation fails at script level ───────────────────────

    it "returns 422 when the script fails validation (missing migration function)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # Script that declares migrate_from_1 in migrations but doesn't define the function
        bad_script = <<-LUA
          local export = {}
          function export.create(ctx) end
          return export
        LUA
        bad_defn = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "migrations": {"1": "migrate_from_1"}, "script": #{bad_script.to_json}})

        result = Update.call(db, doctype_id, bad_defn, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.message.should contain("Doctype validation failed")
          details = result.details.not_nil!
          details.any?(&.message.includes?("migrate_from_1")).should be_true
        in Update::Result
          fail "Expected error"
        end
      end
    end

    # ── Error: no script but migrations declared ──────────────────────

    it "returns 422 when migrations are declared but no script is present (B-301)" do
      with_temp_doctype("mig") do |db, domain, dt|
        doctype_id = create_v1_doctype(db, domain, dt)

        # A migration function runs only through the doctype's Lua script.
        # The lazy migration engine refuses to run without one, so a
        # definition that declares migrations and no script would strand
        # every document below the schema version.
        no_script = %({"doctype": "#{dt}", "domain": "#{domain}", "schema_version": 2, "search": "{{ display_name }}", "fields": {"title": {"type": "string", "required": true}}, "migrations": {"1": "migrate_from_1"}})

        result = Update.call(db, doctype_id, no_script, Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.details.not_nil!.map(&.message).join("; ").should contain("migrations are declared but no script is defined")
        in Update::Result
          fail "Expected 422 but got success"
        end
      end
    end

    # ── Draft domains (B-93) ──────────────────────────────────────────

    it "updates a draft doctype keeping its _-prefixed domain (GET→PUT round trip)" do
      with_db do |db|
        doctype_id = seed_b93_draft_doctype(db, "Widget#{unique_suffix(4)}")
        draft = doctype_id.split('.')[0]

        result = Update.call(db, doctype_id, b93_round_trip_body(db, doctype_id), Facet::RBAC::AuthContext.system)
        case result
        in Update::Result
          result.mutation_id.should be_a(String)
        in Facet::ServiceError
          fail "Draft update failed: #{result.message} (#{result.details.try(&.map(&.message).join("; "))})"
        end

        # The stored definition keeps the draft domain, echoed unchanged.
        proj = Mutation::Client.fetch_projection(db, "core", "DocType", doctype_id)
        proj.content["domain"].as_s.should eq(draft)
        proj.content["fields"].as_h.has_key?("title").should be_true
      end
    end

    it "returns 422 when a live doctype update carries a _-prefixed domain" do
      with_db do |db|
        # A Domain row WITHOUT the draft flag takes the strict path even
        # though its name carries the `_` prefix.
        rogue = "_#{unique_suffix(12)}"
        Facet::Mutation::Client.create(
          db, "core", "Domain", doc_id: rogue, content: %({}),
          actioner_id: "system:test",
        )
        dt = "Widget#{unique_suffix(4)}"
        doctype_id = "#{rogue}.#{dt}"
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: doctype_id,
          content: %({"doctype": "#{dt}", "domain": "#{rogue}", "schema_version": 1, "search": "{{ display_name }}", "fields": {"label": {"type": "string", "required": true}}}),
          actioner_id: "system:test",
        )
        Facet::Doctype::DefinitionStore.invalidate(doctype_id)

        result = Update.call(db, doctype_id, b93_round_trip_body(db, doctype_id), Facet::RBAC::AuthContext.system)
        case result
        in Facet::ServiceError
          result.status.should eq(422)
          result.details.should be_a(Array(Facet::ValidationError))
          result.details.not_nil!.any? { |e| e.code == "schema" && e.message.includes?("domain") && e.message.includes?(rogue) }.should be_true
        in Update::Result
          fail "Expected the strict live-domain rejection"
        end
      end
    end
  end
end
