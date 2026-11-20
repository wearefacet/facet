# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/replication"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "./registry_spec" # brings this spec's describe blocks

# ── Module-level helpers ─────────────────────────────────────────────────

# Builds the source Person + consumer Employee (with replicate field).
# Returns the parsed Employee definition for SyncPull tests.
def setup_sync_pull(db)
  register_person_doctype(db)
  ensure_domain(db, "identity")
  ensure_domain(db, "hr")
  upsert_domain_with_grants(db, "identity", %([
    {"to": "hr", "doctype": "Person", "fields": ["full_name", "email"]}
  ]))
  register_employee_with_replicate(db)

  # Fetch the validated Employee definition.
  Facet::Doctype::DefinitionStore.cache.clear
  Facet::Doctype::DefinitionStore.fetch(db, "hr.Employee").not_nil!
end

# Creates a Person and returns its content.
def create_person_doc(db, full_name = "Alice Liddell")
  person_id = create_person(db, full_name)
  content = Facet::Mutation::Client.fetch_content(db, "identity", "Person", person_id)
  {id: person_id, content: content}
end

module Facet::Replication
  describe SyncPull do
    # ── Tests ───────────────────────────────────────────────────────

    it "pulls replica value into consumer content on create (source exists)" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)
        person = create_person_doc(db, "Alice Liddell")

        # Simulate the create path: a document with `person` set, no replica.
        content = JSON.parse(%({"status": "active", "hire_date": "2020-01-01T00:00:00Z", "job_title": "Eng", "person": "identity.Person.#{person[:id]}"}))

        result = SyncPull.call(db, employee_defn, content, changed_via_fields: nil)

        result.as_h["person_full_name"]?.try(&.as_s).should eq("Alice Liddell")
      end
    end

    it "leaves replica null when source is deleted (create path)" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)
        # Use a non-existent source id.
        content = JSON.parse(%({"status": "active", "hire_date": "2020-01-01T00:00:00Z", "job_title": "Eng", "person": "identity.Person.does-not-exist"}))

        result = SyncPull.call(db, employee_defn, content, changed_via_fields: nil)

        # Source not found → replica field left untouched (still absent).
        result.as_h["person_full_name"]?.should be_nil
      end
    end

    it "pulls the new source field value when `via` changed (update path)" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)
        # Create the original source then a second source; the update
        # path will re-point the `via` field at the second source.
        create_person_doc(db, "Alice Liddell")
        person_b = create_person_doc(db, "Bob Builder")

        # Original content references person_a; the replica is already pulled.
        # Update: change `person` to point at person_b.
        merged = JSON.parse(%({"person": "identity.Person.#{person_b[:id]}", "person_full_name": "Alice Liddell"}))

        # Only `person` (the via) changed → SyncPull should re-pull.
        result = SyncPull.call(db, employee_defn, merged, changed_via_fields: Set{"person"})

        result.as_h["person_full_name"]?.try(&.as_s).should eq("Bob Builder")
      end
    end

    it "does not touch replica when unrelated `via` field changed" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)
        person = create_person_doc(db, "Alice Liddell")

        # Content already has the replica pulled; an unrelated field changed.
        merged = JSON.parse(%({"person": "identity.Person.#{person[:id]}", "person_full_name": "Alice Liddell", "job_title": "Senior Eng"}))

        # `person` did not change → no `via` field in changed_via_fields.
        result = SyncPull.call(db, employee_defn, merged, changed_via_fields: Set{"job_title"})

        # Replica untouched — same value as before.
        result.as_h["person_full_name"]?.try(&.as_s).should eq("Alice Liddell")
      end
    end

    it "leaves replica untouched when via value is null" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)

        content = JSON.parse(%({"status": "active", "hire_date": "2020-01-01T00:00:00Z", "job_title": "Eng", "person": null}))

        result = SyncPull.call(db, employee_defn, content, changed_via_fields: nil)

        # via value is null → replica left null/absent.
        result.as_h["person_full_name"]?.should be_nil
      end
    end

    it "leaves replica null when the source field is no longer declared" do
      with_db do |db|
        employee_defn = setup_sync_pull(db)
        # Create the source while `full_name` is still declared, so the
        # stored projection carries a value.
        person = create_person_doc(db, "Alice Liddell")

        # Remove `full_name` from the source doctype (destructive edit →
        # `$force`). The stored projection keeps the old value — the
        # declaration gate must stop SyncPull from copying it.
        remove_source_field = %({
          "$force": true,
          "doctype": "Person",
          "domain": "identity",
          "schema_version": 1,
          "fields": {
            "email": {"type": "string", "required": true},
            "date_of_birth": {"type": "datetime", "required": true}
          }
        })
        res = Facet::Doctype::Update.call(db, "identity.Person", remove_source_field, Facet::RBAC::AuthContext.system)
        res.should be_a(Facet::Doctype::Update::Result)

        content = JSON.parse(%({"status": "active", "hire_date": "2020-01-01T00:00:00Z", "job_title": "Eng", "person": "identity.Person.#{person[:id]}"}))
        result = SyncPull.call(db, employee_defn, content, changed_via_fields: nil)

        # Source field no longer declared → replica left null/absent.
        result.as_h["person_full_name"]?.should be_nil
      end
    end

    it "leaves replica null when the source field is a secret (B-164)" do
      with_db do |db|
        # Source doctype whose token field is a secret.
        create_simple_doctype(db, "identity", "Vault", %({
          "token": {"type": "secret", "mode": "hash"}
        }))

        # The consumer replicates from the secret. Registered through the
        # raw mutation path — the authoring gate (Doctype::Create) would
        # refuse this shape, and the ordering hole this pin covers is the
        # consumer that landed before the source field existed.
        badge_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Badge",
          "domain": "identity",
          "schema_version": 1,
          "fields": {
            "vault": {"type": "reference", "doctype": "identity.Vault"},
            "vault_token": {
              "type": "string",
              "replicate": {"via": "vault", "field": "token"}
            }
          }
        }))
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "identity.Badge",
          content: badge_defn.to_json,
          actioner_id: "system",
        )
        Facet::Doctype::DefinitionStore.cache.clear

        # A source document with a stored marker. The raw write bypasses
        # the field write gate, so the marker object lands in the content
        # — exactly what a secret-less pull would copy.
        Facet::Mutation::Client.create(
          db, "identity", "Vault",
          doc_id: "identity.Vault.v1",
          content: %({"token": {"mode": "hash", "version": 1, "set_at": "2026-01-01T00:00:00Z"}}),
          actioner_id: "system",
        )
        db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'identity' AND doc_type = 'Vault' AND id = 'identity.Vault.v1'",
          as: Int64
        ).should eq(1)

        content = JSON.parse(%({"vault": "identity.Vault.v1"}))
        result = SyncPull.call(db, badge_defn, content, changed_via_fields: nil)

        # Secret source field → replica left null/absent.
        result.as_h["vault_token"]?.should be_nil
      end
    end
  end
end
