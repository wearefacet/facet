# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/event"
require "../../src/replication"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/artifact/store"
require "./registry_spec" # brings this spec's describe blocks

# ── Module-level helpers ─────────────────────────────────────────────────

# Builds the source Person + consumer Employee doctypes plus grants, then
# builds and returns a fresh Registry over them.
def setup_handler_pair(db, *, on_source_delete : String = "keep")
  setup_replicate_pair(db, on_source_delete: on_source_delete)
  registry = Facet::Replication::Registry.new(domain_enabled: ->(_d : String) { true })
  registry.build(db)
  registry
end

# Creates an Employee document referencing a Person id (via the `person`
# field) and returns the new Employee doc_id. `Mutation::Client.create`
# is called with an explicit `doc_id` because its return value is the
# mutation ULID, not the projection id we hand it.
def create_employee(db, person_id, *, full_name_replica = nil)
  content = if full_name_replica
              %({
                 "status": "active",
                 "hire_date": "2020-01-01T00:00:00Z",
                 "job_title": "Eng",
                 "person": "identity.Person.#{person_id}",
                 "person_full_name": "#{full_name_replica}"
               })
            else
              %({
                 "status": "active",
                 "hire_date": "2020-01-01T00:00:00Z",
                 "job_title": "Eng",
                 "person": "identity.Person.#{person_id}"
               })
            end
  employee_id = Facet::Util::ScriptHelpers.ulid
  Facet::Mutation::Client.create(
    db, "hr", "Employee",
    doc_id: employee_id,
    content: content,
    actioner_id: "system",
  )
  employee_id
end

# Fetches the current replica field value (`person_full_name`) of an Employee.
def employee_full_name(db, employee_id) : JSON::Any?
  Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id)
    .as_h["person_full_name"]?
end

# Builds a synthetic Message for a source doctype event.
def source_message(domain, doc_type, event_name, source_id, *, reentrant = false) : Facet::Event::Message
  headers = {
    "domain"   => JSON::Any.new(domain),
    "doc_type" => JSON::Any.new(doc_type),
    "event"    => JSON::Any.new(event_name),
  }
  headers["reentrant"] = JSON::Any.new(true) if reentrant
  Facet::Event::Message.new(
    content: JSON::Any.new({"id" => JSON::Any.new(source_id)}),
    headers: headers,
  )
end

module Facet::Replication
  describe Handler do
    # ── Async propagation (plan tests 5 & 6) ───────────────────────────

    it "updates consumer replica when source field changes" do
      with_db do |db|
        registry = setup_handler_pair(db)
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        # Source: update Person.full_name → "Alicia Liddell".
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alicia Liddell"}]}),
        )

        handler.call(source_message("identity", "Person", "updated", person_id))

        employee_full_name(db, employee_id).try(&.as_s).should eq("Alicia Liddell")
      end
    end

    it "does not update consumer when source update touches an unrelated field" do
      with_db do |db|
        registry = setup_handler_pair(db)
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        # Source: update Person.email (not the replicated full_name).
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["email"], "value": "alice@new.example"}]}),
        )

        handler.call(source_message("identity", "Person", "updated", person_id))

        # Replica is unchanged — empty-diff suppression / pre-check kicked in.
        employee_full_name(db, employee_id).try(&.as_s).should eq("Alice Liddell")
      end
    end

    # ── Deletion policy (plan tests 9 & 10) ───────────────────────────

    it "keeps replica value and via id on source deletion when on_source_delete=keep" do
      with_db do |db|
        registry = setup_handler_pair(db, on_source_delete: "keep")
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        Facet::Mutation::Client.delete(db, "identity", "Person", person_id)
        handler.call(source_message("identity", "Person", "deleted", person_id))

        content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id).as_h
        content["person_full_name"]?.try(&.as_s).should eq("Alice Liddell")
        content["person"]?.try(&.as_s).should eq("identity.Person.#{person_id}")
      end
    end

    it "unsets replica field but keeps via id on source deletion when on_source_delete=unset" do
      with_db do |db|
        registry = setup_handler_pair(db, on_source_delete: "unset")
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        Facet::Mutation::Client.delete(db, "identity", "Person", person_id)
        handler.call(source_message("identity", "Person", "deleted", person_id))

        content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id).as_h
        # Replica field is unset via a partial-patch body `{"<replica_field>": null}`
        # routed through `Document::Update`. The projection content then contains
        # a JSON null for the replica field (the service layer surfaces null as
        # `set [field] = null`, not a true key removal).
        replica = content["person_full_name"]?
        if replica
          replica.raw.nil?.should be_true
        end
        # The `via` reference value is preserved (dangling id is a true fact).
        content["person"]?.try(&.as_s).should eq("identity.Person.#{person_id}")
      end
    end

    # ── Fail-closed (plan test 11) ─────────────────────────────────────

    it "skips the binding when grant is missing at registry build time" do
      with_db do |db|
        # Person + Employee doctypes exist, but no domain grant from
        # identity to hr → fail-closed.
        register_person_doctype(db)
        register_employee_with_replicate(db)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)

        registry.bindings_for("identity.Person").should be_empty

        # No bindings ⇒ handler is a no-op even if Person mutates.
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: nil)

        handler = Handler.new(registry)
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alicia Liddell"}]}),
        )
        handler.call(source_message("identity", "Person", "updated", person_id))

        # Replica was never populated.
        employee_full_name(db, employee_id).should be_nil
      end
    end

    # ── Reentrancy (plan test 7) ──────────────────────────────────────

    it "skips reentrant source events (one-hop guarantee)" do
      with_db do |db|
        registry = setup_handler_pair(db)
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        # A reentrant event arrives (e.g. emitted by an upstream consumer in
        # the same replication chain). The handler MUST skip — the one-hop
        # guarantee prevents A → B → C cascades.
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alicia Liddell"}]}),
        )

        handler.call(source_message("identity", "Person", "updated", person_id, reentrant: true))

        # Consumer untouched.
        employee_full_name(db, employee_id).try(&.as_s).should eq("Alice Liddell")
      end
    end

    # ── Mutation-log visibility (per user concern #2) ─────────────────

    it "persists a real mutation row on the consumer when replicating" do
      with_db do |db|
        registry = setup_handler_pair(db)
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        handler = Handler.new(registry)

        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alicia Liddell"}]}),
        )

        before_count = db.query_one(
          "SELECT count(*) FROM mutations WHERE doc_id = $1",
          employee_id,
          as: Int64
        )
        handler.call(source_message("identity", "Person", "updated", person_id))
        after_count = db.query_one(
          "SELECT count(*) FROM mutations WHERE doc_id = $1",
          employee_id,
          as: Int64
        )

        (after_count - before_count).should eq(1)

        # The mutation row is an `update` action whose `actioner_id` reflects
        # the `AuthContext.system` principal ("system"). `idx` is the
        # sequential mutation counter per document, so `ORDER BY idx DESC`
        # returns the most recent mutation.
        row = db.query_one(
          "SELECT action, actioner_id FROM mutations WHERE doc_id = $1 ORDER BY idx DESC LIMIT 1",
          employee_id,
          as: {String, String}
        )
        row[0].should eq("update")
        row[1].should eq("system")
      end
    end

    # ── Artifact owner-append on replicated file fields ────────────────

    it "appends an owner row for a replicated file field in the consumer domain" do
      with_db do |db|
        # Source Person carries a `file` field; consumer Employee replicates
        # it. Grants allow identity→hr for the file field.
        ensure_domain(db, "identity")
        ensure_domain(db, "hr")
        upsert_domain_with_grants(db, "identity", %([
          {"to": "hr", "doctype": "Person", "fields": ["full_name", "email", "avatar"]}
        ]))
        upsert_domain_with_grants(db, "hr", %([
          {"to": "identity", "doctype": "Person", "fields": ["full_name"]}
        ]))

        person_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Person",
          "domain": "identity",
          "schema_version": 1,
          "aggregate_root": false,
          "fields": {
            "full_name": {"type": "string", "required": true},
            "email":     {"type": "string", "required": true},
            "date_of_birth": {"type": "datetime", "required": true},
            "avatar":    {"type": "file"}
          }
        }))
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "identity.Person",
          content: person_defn.to_json, actioner_id: "system",
        )

        employee_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "aggregate_root": true, "search": "{{ display_name }}",
          "fields": {
            "status":      {"type": "enum", "values": ["active", "on_leave", "terminated"]},
            "hire_date":   {"type": "datetime", "required": true},
            "job_title":   {"type": "string", "required": true},
            "person":      {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_avatar": {
              "type": "file",
              "replicate": {"via": "person", "field": "avatar"},
              "on_source_delete": "keep"
            }
          }
        }))
        errors = Facet::Replication::Validator.validate(employee_defn, db)
        raise "Invalid test doctype: #{errors.join(", ")}" unless errors.empty?
        Facet::Mutation::Client.create(
          db, "core", "DocType", doc_id: "hr.Employee",
          content: employee_defn.to_json, actioner_id: "system",
        )

        registry = Facet::Replication::Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        handler = Handler.new(registry)

        # Upload an artifact against the source Person's avatar field.
        avatar_id = Facet::Util::ScriptHelpers.ulid
        db.exec(<<-SQL, avatar_id, avatar_id)
          INSERT INTO artifacts (id, filename, mime_type, size, signature_sha256, path)
          VALUES ($1, 'a.png', 'image/png', 4, $2, $2 || '/' || $1)
        SQL

        person_id = create_person(db, "Alice Liddell")
        # Set the source Person's avatar to the artifact id.
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["avatar"], "value": "#{avatar_id}"}]}),
        )

        # Consumer Employee references the Person.
        employee_id = create_employee(db, person_id)

        # Replicate: source avatar → consumer person_avatar.
        handler.call(source_message("identity", "Person", "updated", person_id))

        # The consumer's replicated file field holds the artifact id.
        content = Facet::Mutation::Client.fetch_content(db, "hr", "Employee", employee_id).as_h
        content["person_avatar"]?.try(&.as_s).should eq(avatar_id)

        # An owner row now exists for the artifact against the consumer doc.
        owners = Facet::Artifact::Store.find_owner_rows(db, avatar_id)
        consumer_owner = owners.find { |o| o.domain == "hr" && o.doc_id == employee_id }
        consumer_owner.should_not be_nil
        consumer_owner.not_nil!.field_path.should eq("person_avatar")
      end
    end

    # ── Aggregate child_changed frames ───────────────────────────

    it "acks and returns on an aggregate child_changed frame (no replica write)" do
      with_db do |db|
        registry = setup_handler_pair(db)
        person_id = create_person(db, "Alice Liddell")
        employee_id = create_employee(db, person_id, full_name_replica: "Alice Liddell")

        # The replicated field HAS changed — an `updated` frame would sync
        # it (the happy-path test above proves that). The aggregate child
        # frame must not.
        Facet::Mutation::Client.update(
          db, "identity", "Person", person_id,
          diff_json: %({"set": [{"path": ["full_name"], "value": "Alicia Liddell"}]}),
        )

        handler = Handler.new(registry)
        msg = Facet::Event::Message.new(
          content: JSON::Any.new({
            "id"     => JSON::Any.new(person_id),
            "action" => JSON::Any.new("updated"),
            "child"  => JSON::Any.new({
              "doc_type" => JSON::Any.new("Note"),
              "doc_id"   => JSON::Any.new("note-1"),
            } of String => JSON::Any),
            "parent" => JSON::Any.new({
              "doc_type" => JSON::Any.new("Person"),
              "doc_id"   => JSON::Any.new(person_id),
            } of String => JSON::Any),
          } of String => JSON::Any),
          headers: {
            "domain"   => JSON::Any.new("identity"),
            "doc_type" => JSON::Any.new("Person"),
            "event"    => JSON::Any.new(Facet::Event::CHILD_CHANGED),
          },
        )
        handler.call(msg)

        # The replica is unchanged — the handler ACKed and returned.
        employee_full_name(db, employee_id).try(&.as_s).should eq("Alice Liddell")
      end
    end
  end
end
