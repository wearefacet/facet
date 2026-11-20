# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/document"
require "../../src/replication"
require "../../src/rbac"

# Authoring-time enforcement of the hard replication invariants (B-127,
# B-128). `Replication::Validator.validate_invariants` runs on doctype
# create and update and rejects a violation with a 422 — the advisory
# grant/existence diagnostics stay on `/check`.
module Facet::Replication
  describe "replication invariants at authoring time" do
    # ── B-127: secret source field ───────────────────────────────────

    it "rejects create of a doctype replicating from a secret field with 422" do
      with_db do |db|
        create_simple_doctype(db, "idsec", "Vault", %({
          "token": {"type": "secret", "mode": "hash"}
        }))
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "vault": {"type": "reference", "doctype": "idsec.Vault"},
            "vault_token": {
              "type": "string",
              "replicate": {"via": "vault", "field": "token"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
        err.details.not_nil!.any? { |d| d.message.includes?("vault_token") && d.message.includes?("secret") }.should be_true
      end
    end

    it "rejects update that introduces a replicate from a secret field with 422" do
      with_db do |db|
        create_simple_doctype(db, "idsec", "Vault", %({
          "token": {"type": "secret", "mode": "hash"}
        }))
        # v1 without the replicate field.
        create_simple_doctype(db, "hr", "Employee", %({
          "vault": {"type": "reference", "doctype": "idsec.Vault"}
        }))

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "vault": {"type": "reference", "doctype": "idsec.Vault"},
            "vault_token": {
              "type": "string",
              "replicate": {"via": "vault", "field": "token"}
            }
          }
        })

        result = Facet::Doctype::Update.call(db, "hr.Employee", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
      end
    end

    # ── F09-02: unqualified `via` target ─────────────────────────────

    it "rejects create when the via reference target is unqualified (422)" do
      with_db do |db|
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "vault": {"type": "reference", "doctype": "Vault"},
            "stolen": {"type": "string", "replicate": {"via": "vault", "field": "api_key"}}
          }
        })

        # The schema gate runs first: a bare reference target is refused
        # at authoring (F02-01) — `qualified_doctype` never expands it, so
        # the field would refuse every value at write time.
        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Doctype validation failed")
        err.details.not_nil!.any? { |d| d.message.includes?("bare reference target 'Vault'") }.should be_true

        # The authoring door refused it — nothing landed.
        db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'hr.Employee'",
          as: Int64
        ).should eq(0)

        # Behind the schema gate, the replication invariant stays armed
        # (defense in depth — publish re-runs it over the whole set): an
        # unqualified `via` target can never resolve a source, so the
        # invariant fails closed instead of skipping the secret check.
        defn = Doctype::DoctypeDefinition.from_json(body)
        invariant_errors = Validator.validate_invariants(defn, db)
        invariant_errors.any? { |e| e.includes?("invalid source doctype 'Vault'") }.should be_true
      end
    end

    # ── B-271: tag escape through a tag-less replica ─────────────────

    it "rejects create of a doctype replicating from a tagged field into an untagged replica with 422" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person"},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
        err.details.not_nil!.any? { |d| d.message.includes?("person_full_name") && d.message.includes?("pay") }.should be_true

        # The authoring door refused it — nothing landed.
        db.query_one(
          "SELECT count(*) FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = 'hr.Employee'",
          as: Int64
        ).should eq(0)
      end
    end

    it "rejects update that introduces an untagged replica of a tagged field with 422" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))
        # v1 without the replicate field.
        create_simple_doctype(db, "hr", "Employee", %({
          "person": {"type": "reference", "doctype": "identity.Person"}
        }))

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person"},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })

        result = Facet::Doctype::Update.call(db, "hr.Employee", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
      end
    end

    it "still creates a doctype when the replica carries the source field's tags" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person"},
            "person_full_name": {
              "type": "string",
              "tags": ["pay"],
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Doctype::Create::Result)
      end
    end

    # ── B-128: replica-of-replica ────────────────────────────────────

    it "rejects create of a doctype replicating from a replica with 422" do
      with_db do |db|
        # Source doctype whose `replicated_name` is itself a replica.
        ensure_domain(db, "source")
        source_defn = Facet::Doctype::DoctypeDefinition.from_json(%({
          "doctype": "ExternalData",
          "domain": "source",
          "schema_version": 1,
          "fields": {
            "full_name": {"type": "string"},
            "source_ref": {"type": "reference", "doctype": "source.ExternalData"},
            "replicated_name": {
              "type": "string",
              "replicate": {"via": "source_ref", "field": "full_name"}
            }
          }
        }))
        Facet::Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "source.ExternalData",
          content: source_defn.to_json,
          actioner_id: "system",
        )
        ensure_domain(db, "target")

        body = %({
          "doctype": "Employee",
          "domain": "target",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "source.ExternalData"},
            "person_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "replicated_name"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
        err.details.not_nil!.any? { |d| d.message.includes?("person_name") && d.message.includes?("is itself a replicated field") }.should be_true
      end
    end

    it "rejects create when the via field is itself a replica with 422" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person"},
            "person_alias": {
              "type": "reference",
              "doctype": "identity.Person",
              "replicate": {"via": "person", "field": "full_name"}
            },
            "name": {
              "type": "string",
              "replicate": {"via": "person_alias", "field": "full_name"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should contain("Replication validation failed")
      end
    end

    # ── B-164: ordering hole closed at runtime ────────────────────────

    it "registers the binding only after its source doctype lands (ordering recovery)" do
      with_db do |db|
        ensure_domain(db, "hr")

        # Consumer first — the authoring gate accepts the definition
        # because the source is unresolvable and left to the advisory
        # diagnostics (B-127 invariants skip it silently).
        body = %({
          "doctype": "Badge",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "holder": {"type": "reference", "doctype": "hr.Person"},
            "holder_name": {
              "type": "string",
              "replicate": {"via": "holder", "field": "full_name"}
            }
          }
        })
        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Doctype::Create::Result)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        # Source missing → fail-closed skip.
        registry.bindings_for("hr.Person").should be_empty

        # The producer lands later, with a plain string field. The next
        # rebuild resolves the source and registers the edge.
        create_simple_doctype(db, "hr", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))
        Facet::Doctype::DefinitionStore.cache.clear

        registry.build(db)
        registry.bindings_for("hr.Person").size.should eq(1)
      end
    end

    it "keeps the binding dropped when the source lands with a secret field" do
      with_db do |db|
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Badge",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "holder": {"type": "reference", "doctype": "hr.Person"},
            "holder_token": {
              "type": "string",
              "replicate": {"via": "holder", "field": "token"}
            }
          }
        })
        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Doctype::Create::Result)

        registry = Registry.new(domain_enabled: ->(_d : String) { true })
        registry.build(db)
        registry.bindings_for("hr.Person").should be_empty

        # The producer lands later, carrying a secret field. Nothing
        # re-checks the inbound consumer at authoring time — the registry
        # must still refuse the edge, or the handler would copy the
        # secret's marker object into the public replica field.
        create_simple_doctype(db, "hr", "Person", %({
          "token": {"type": "secret", "mode": "hash"}
        }))
        Facet::Doctype::DefinitionStore.cache.clear

        registry.build(db)
        registry.bindings_for("hr.Person").should be_empty
        registry.source_doctypes.should be_empty
      end
    end

    # ── Valid replicate still creates ────────────────────────────────

    it "still creates a doctype with a valid replicate field" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))
        ensure_domain(db, "hr")

        body = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person"},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })

        result = Facet::Doctype::Create.call(db, "core", "DocType", body, Facet::RBAC::AuthContext.system)
        result.should be_a(Facet::Doctype::Create::Result)
      end
    end
  end
end
