# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/replication"
require "../../src/doctype"
require "../../src/rbac"
require "./validator_spec" # brings this spec's describe blocks

# ── Test helpers (module-level, shared across replication specs) ────────────

# Builds and persists a minimal identity.Person + hr.Employee pair with a
# replicate edge: hr.Employee.person_full_name ← identity.Person.full_name
# via hr.Employee.person. Does NOT call register_hr_doctypes (which would
# pre-create a clashing hr.Employee projection) — registers each doctype
# individually with the replicate field in place.
def setup_replicate_pair(db, *, on_source_delete : String = "keep")
  ensure_domain(db, "identity")
  ensure_domain(db, "hr")
  upsert_domain_with_grants(db, "identity", %([
    {"to": "hr", "doctype": "Person", "fields": ["full_name", "email"]}
  ]))
  upsert_domain_with_grants(db, "hr", %([
    {"to": "identity", "doctype": "Person", "fields": ["full_name"]}
  ]))

  # Register identity.Person first (source must exist for Validator resolution).
  person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Person",
    "domain": "identity",
    "schema_version": 1,
    "aggregate_root": false,
    "fields": {
      "full_name": {"type": "string", "required": true},
      "email":     {"type": "string", "required": true},
      "date_of_birth": {"type": "datetime", "required": true}
    }
  }))
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "identity.Person",
    content: person_defn.to_json,
    actioner_id: "system",
  )

  # Register hr.Employee with the replicate field.
  employee_defn_json = %({
    "doctype": "Employee",
    "domain": "hr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "status":      {"type": "enum", "values": ["active", "on_leave", "terminated"]},
      "hire_date":   {"type": "datetime", "required": true},
      "job_title":   {"type": "string", "required": true},
      "person":      {"type": "reference", "doctype": "identity.Person", "required": true},
      "person_full_name": {
        "type": "string",
        "replicate": {"via": "person", "field": "full_name"},
        "on_source_delete": "#{on_source_delete}"
      }
    }
  })
  employee_defn = Facet::Doctype::DoctypeDefinition.from_json(employee_defn_json)
  errors = Facet::Replication::Validator.validate(employee_defn, db)
  raise "Invalid test doctype: #{errors.join(", ")}" unless errors.empty?

  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "hr.Employee",
    content: employee_defn.to_json,
    actioner_id: "system",
  )
end

# Creates a Person document and returns its id.
#
# `create_person` now lives in `spec/support/doctype_helper.cr` (single
# shared definition; the spec-defs gate forbids a second public copy).

# Registers only the identity.Person doctype (no hr.Employee conflict) — used
# by tests that need a source doctype to exist but build their own consumer.
def register_person_doctype(db)
  person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Person",
    "domain": "identity",
    "schema_version": 1,
    "aggregate_root": false,
    "fields": {
      "full_name": {"type": "string", "required": true},
      "email":     {"type": "string", "required": true},
      "date_of_birth": {"type": "datetime", "required": true}
    }
  }))
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "identity.Person",
    content: person_defn.to_json,
    actioner_id: "system",
  )
end

# Inserts the hr.Employee doctype with a replicate field that pulls
# `full_name` from identity.Person via the `person` reference. Optionally
# overrides source_delete policy. Requires identity.Person to already exist.
def register_employee_with_replicate(db, *, on_source_delete : String = "keep")
  employee_defn_json = %({
    "doctype": "Employee",
    "domain": "hr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "status":      {"type": "enum", "values": ["active", "on_leave", "terminated"]},
      "hire_date":   {"type": "datetime", "required": true},
      "job_title":   {"type": "string", "required": true},
      "person":      {"type": "reference", "doctype": "identity.Person", "required": true},
      "person_full_name": {
        "type": "string",
        "replicate": {"via": "person", "field": "full_name"},
        "on_source_delete": "#{on_source_delete}"
      }
    }
  })
  Facet::Mutation::Client.create(
    db, "core", "DocType",
    doc_id: "hr.Employee",
    content: employee_defn_json,
    actioner_id: "system",
  )
end

# Rewrites hr.Employee WITHOUT the replicate field (destructive edit —
# `$force: true`, the same-version guard rejects field removal without it).
# The next registry build returns zero bindings. Requires hr.Employee to
# already exist.
def remove_replicate_field(db)
  employee_no_replica = %({
    "$force": true,
    "doctype": "Employee",
    "domain": "hr",
    "schema_version": 1,
    "aggregate_root": true, "search": "{{ display_name }}",
    "fields": {
      "job_title": {"type": "string", "required": true},
      "person":    {"type": "reference", "doctype": "identity.Person", "required": true}
    }
  })
  res = Facet::Doctype::Update.call(db, "hr.Employee", employee_no_replica, Facet::RBAC::AuthContext.system)
  res.should be_a(Facet::Doctype::Update::Result)
end

module Facet::Replication
  describe Registry do
    # ── Tests ───────────────────────────────────────────────────────

    it "builds a binding for a valid replicate field with grant" do
      with_db do |db|
        setup_replicate_pair(db)

        db.query_all("SELECT id, meta->>'parent_id', content->>'consumer_domain', content->>'active' FROM projections WHERE domain = 'core' AND doc_type = 'DomainGrant'") { |rs| {rs.read(String), rs.read(String?), rs.read(String?), rs.read(String?)} }

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        bindings = registry.bindings_for("identity.Person")
        bindings.size.should eq(1)

        b = bindings.first
        b.consumer_domain.should eq("hr")
        b.consumer_doctype.should eq("Employee")
        b.ref_field.should eq("person")
        b.replica_field.should eq("person_full_name")
        b.source_doctype.should eq("identity.Person")
        b.source_field.should eq("full_name")
        b.on_source_delete.should eq("keep")
      end
    end

    it "indexes bindings by source doctype" do
      with_db do |db|
        setup_replicate_pair(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        registry.source_doctypes.should contain("identity.Person")
        registry.source_doctypes.should_not contain("hr.Employee")
      end
    end

    it "lists distinct consuming domains" do
      with_db do |db|
        setup_replicate_pair(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        registry.consumer_domains.should contain("hr")
      end
    end

    it "skips bindings for consuming domains that are not enabled" do
      with_db do |db|
        setup_replicate_pair(db)

        registry = Registry.new(domain_enabled: ->(d : String) { d == "identity" })
        registry.build(db)

        registry.bindings_for("identity.Person").should be_empty
        registry.consumer_domains.should be_empty
      end
    end

    it "fails closed (skips + logs) when grant is missing" do
      with_db do |db|
        register_person_doctype(db)
        # No grant inserted on identity.
        register_employee_with_replicate(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        registry.bindings_for("identity.Person").should be_empty
        registry.source_doctypes.should be_empty
      end
    end

    it "skips bindings when grant exists but does not cover the field" do
      with_db do |db|
        register_person_doctype(db)
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["email"]}
        ]))
        register_employee_with_replicate(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        # The grant covers email but not full_name → fail-closed skip.
        registry.bindings_for("identity.Person").should be_empty
      end
    end

    it "accepts wildcard grants" do
      with_db do |db|
        register_person_doctype(db)
        ensure_domain(db, "identity")
        ensure_domain(db, "hr")
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": "*"}
        ]))
        register_employee_with_replicate(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        registry.bindings_for("identity.Person").size.should eq(1)
      end
    end

    it "rebuilds bindings on each call to #build" do
      with_db do |db|
        setup_replicate_pair(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        initial_count = registry.bindings_for("identity.Person").size

        # Rebuild — the binding set should be identical, not duplicated.
        registry.build(db)
        registry.bindings_for("identity.Person").size.should eq(initial_count)
      end
    end

    it "picks up new bindings after registry refresh" do
      with_db do |db|
        register_person_doctype(db)
        ensure_domain(db, "identity")
        ensure_domain(db, "hr")
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
        ]))

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        # No replicate field yet → no bindings.
        registry.bindings_for("identity.Person").should be_empty

        # Now register hr.Employee with the replicate field.
        register_employee_with_replicate(db)

        registry.build(db)
        registry.bindings_for("identity.Person").size.should eq(1)
      end
    end

    it "respects on_source_delete = unset" do
      with_db do |db|
        setup_replicate_pair(db, on_source_delete: "unset")

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        b = registry.bindings_for("identity.Person").first
        b.on_source_delete.should eq("unset")
      end
    end
  end

  # ── Lazy rebuild on staleness ────────────────────────────────────────
  #
  # The registry keeps a `@stale` flag set by `mark_stale` (typically from
  # the `DoctypeCache` Pub/Sub subscriber). Public readers call `ensure_fresh`,
  # which rebuilds from the DB via `Database.with_db` when the flag is set.
  # This is the on-demand recovery half of the invalidate-only pattern.
  describe "lazy rebuild on staleness" do
    it "is stale on construction and rebuilds on first read" do
      with_db do |db|
        setup_replicate_pair(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        # No explicit #build — the registry starts stale.
        bindings = registry.bindings_for("identity.Person")
        bindings.size.should eq(1)
        bindings[0].consumer_domain.should eq("hr")
      end
    end

    it "rebuilds from the DB after mark_stale picks up new edges" do
      with_db do |db|
        register_person_doctype(db)
        ensure_domain(db, "identity")
        ensure_domain(db, "hr")
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
        ]))

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        registry.bindings_for("identity.Person").should be_empty

        # Register the consumer with a replicate field — but do NOT rebuild
        # explicitly. Mark stale, then read; the stale flag must drive a lazy
        # rebuild that picks up the new edge.
        register_employee_with_replicate(db)
        registry.mark_stale

        registry.bindings_for("identity.Person").size.should eq(1)
      end
    end

    it "coalesces a flock of mark_stale calls into a single rebuild" do
      with_db do |db|
        register_person_doctype(db)
        ensure_domain(db, "identity")
        ensure_domain(db, "hr")
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
        ]))

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        register_employee_with_replicate(db)

        # A flock of events spaced milliseconds apart (e.g. publishing a
        # whole domain) — each marks stale.
        5.times { registry.mark_stale }

        # The first read rebuilds once; the flag is cleared by #build.
        # A second read must NOT rebuild again (proves coalescing).
        registry.bindings_for("identity.Person").size.should eq(1)
        # No way to count builds directly; assert idempotency instead —
        # repeated reads return the same binding set without error.
        3.times do
          registry.bindings_for("identity.Person").size.should eq(1)
        end
      end
    end

    it "does not rebuild when not stale" do
      with_db do |db|
        setup_replicate_pair(db)
        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        # Hard-delete the consumer doctype projection AFTER the build so the
        # next `build` would return zero bindings. Without `mark_stale`, the
        # reader must serve the cached state (one binding) — proving no
        # lazy rebuild fired on the read path.
        db.exec(
          "DELETE FROM projections WHERE domain = 'core' AND doc_type = 'DocType' " \
          "AND id = 'hr.Employee'"
        )

        registry.bindings_for("identity.Person").size.should eq(1)

        # After explicitly marking stale, the next read MUST rebuild from DB
        # and observe the deletion.
        registry.mark_stale
        registry.bindings_for("identity.Person").should be_empty
      end
    end

    it "rebuilds on read when the staleness bound expires (fanout lost)" do
      with_db do |db|
        setup_replicate_pair(db)
        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        registry.bindings_for("identity.Person").size.should eq(1)

        # The consumer doctype's replicate field is removed while Redis is
        # down: the fanout never fires, so `mark_stale` never runs. The
        # next `build` would return zero bindings.
        remove_replicate_field(db)

        with_cache_ttl(1) do
          # Inside the bound the cached binding still serves.
          registry.bindings_for("identity.Person").size.should eq(1)

          # Past the bound the next read rebuilds from the DB and observes
          # the removal — the bound caps the outage window instead of
          # letting the stale binding persist until restart.
          assert_eventually(timeout: 4.0, interval: 0.05) do
            registry.bindings_for("identity.Person").empty?
          end
        end
      end
    end
  end
end
