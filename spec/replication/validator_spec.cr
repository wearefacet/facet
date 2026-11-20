# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/grants"
require "../../src/replication"
require "../../src/rbac"

# `upsert_grant`, `upsert_domain_with_grants` and `create_simple_doctype`
# live in `spec/support/doctype_helper.cr` (single shared definition; the
# spec-defs gate forbids a second public copy).

module Facet::Replication
  describe Validator do
    # ── Success cases ────────────────────────────────────────────

    it "passes validation for a valid replicate field with grant" do
      with_db do |db|
        register_hr_doctypes
        # `full_name` carries no tags — the grant covers it via `default`.
        upsert_grant(db, "identity", "hr", %([
          {"doctype": "Person", "tags": ["default"]}
        ]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "status":     {"type": "enum", "values": ["active", "on_leave", "terminated"]},
            "hire_date":  {"type": "datetime", "required": true},
            "job_title":  {"type": "string", "required": true},
            "department": {"type": "string"},
            "salary":     {"type": "money"},
            "remote":     {"type": "boolean"},
            "person":     {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.should be_empty
      end
    end

    it "passes validation when the grant names a tag the field carries" do
      with_db do |db|
        # A dedicated source doctype whose field carries a tag.
        create_simple_doctype(db, "idtag", "Contact", %({
          "full_name": {"type": "string", "required": true, "tags": ["contact"]},
          "email":     {"type": "string", "required": true}
        }))
        upsert_grant(db, "idtag", "hr", %([
          {"doctype": "Contact", "tags": ["contact"]}
        ]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "contact": {"type": "reference", "doctype": "idtag.Contact", "required": true},
            "contact_name": {
              "type": "string",
              "tags": ["contact"],
              "replicate": {"via": "contact", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.should be_empty
      end
    end

    it "passes validation for a same-domain replicate field without any grant" do
      with_db do |db|
        # Consumer and producer are the same bounded context — no self-grant
        # is needed. The hr domain carries NO grants here.
        create_simple_doctype(db, "hr", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "status":     {"type": "enum", "values": ["active", "on_leave", "terminated"]},
            "hire_date":  {"type": "datetime", "required": true},
            "job_title":  {"type": "string", "required": true},
            "person":     {"type": "reference", "doctype": "hr.Person", "required": true},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.should be_empty
      end
    end

    # ── Failure cases ────────────────────────────────────────────

    it "rejects when via field does not exist" do
      with_db do |db|
        register_hr_doctypes

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person_name": {
              "type": "string",
              "replicate": {"via": "nonexistent", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("nonexistent") }.should be_true
      end
    end

    it "rejects when via field is not a reference" do
      with_db do |db|
        register_hr_doctypes

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "status": {"type": "enum", "values": ["active", "on_leave", "terminated"]},
            "hire_date": {"type": "datetime", "required": true},
            "job_title": {"type": "string", "required": true},
            "status_name": {
              "type": "string",
              "replicate": {"via": "status", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("status_name") && e.includes?("must be a reference") }.should be_true
      end
    end

    it "rejects when source field does not exist on source doctype" do
      with_db do |db|
        register_hr_doctypes
        upsert_grant(db, "identity", "hr", %([{"doctype": "Person", "tags": ["default"]}]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_nonexistent": {
              "type": "string",
              "replicate": {"via": "person", "field": "nonexistent_field"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_nonexistent") && e.includes?("nonexistent_field") }.should be_true
      end
    end

    it "rejects when source field is itself a replicated field" do
      with_db do |db|
        # Create a source doctype via raw mutation (bypassing validation)
        # so we can inject a replicate field without triggering resolution.
        ensure_domain(db, "source")
        source_defn = Doctype::DoctypeDefinition.from_json(%({
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
        Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "source.ExternalData",
          content: source_defn.to_json,
          actioner_id: "system",
        )

        ensure_domain(db, "target")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("is itself a replicated field") }.should be_true
      end
    end

    it "rejects type mismatch between consumer and source field" do
      with_db do |db|
        register_hr_doctypes
        upsert_grant(db, "identity", "hr", %([{"doctype": "Person", "tags": ["default"]}]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_name": {
              "type": "integer",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("type mismatch") }.should be_true
      end
    end

    it "rejects when no grant exists for the consumer domain" do
      with_db do |db|
        register_hr_doctypes
        clear_grants(db)

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("no core.DomainGrant") }.should be_true
      end
    end

    it "rejects when the grant is inactive (filed, awaiting acceptance)" do
      with_db do |db|
        register_hr_doctypes
        upsert_grant(db, "identity", "hr", "[{\"doctype\": \"Person\", \"tags\": [\"default\"]}]", active: false)

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("inactive") }.should be_true
      end
    end

    it "rejects when the active grant does not name the source doctype" do
      with_db do |db|
        register_hr_doctypes
        upsert_grant(db, "identity", "hr", %([{"doctype": "CareerEvent", "tags": ["default"]}]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "identity.Person", "required": true},
            "person_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("does not name doctype 'Person'") }.should be_true
      end
    end

    it "rejects when the field's tags are not covered by the granted tags" do
      with_db do |db|
        # A source field tagged `pii` — a grant naming only `default` does
        # not reach it.
        create_simple_doctype(db, "idtag", "Contact", %({
          "full_name": {"type": "string", "required": true, "tags": ["pii"]},
          "email":     {"type": "string", "required": true}
        }))
        upsert_grant(db, "idtag", "hr", %([{"doctype": "Contact", "tags": ["default"]}]))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "contact": {"type": "reference", "doctype": "idtag.Contact", "required": true},
            "contact_name": {
              "type": "string",
              "replicate": {"via": "contact", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("contact_name") && e.includes?("are not covered") }.should be_true
      end
    end

    it "rejects when the replica field does not carry a tag of the source field" do
      with_db do |db|
        # Same-domain edge — the grant diagnostic stays out of the
        # assertion, so the tag-coverage diagnostic must fire on its own.
        create_simple_doctype(db, "hr", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))

        defn_json = %({
          "doctype": "Employee",
          "domain": "hr",
          "schema_version": 1,
          "fields": {
            "person": {"type": "reference", "doctype": "hr.Person", "required": true},
            "person_full_name": {
              "type": "string",
              "replicate": {"via": "person", "field": "full_name"}
            }
          }
        })
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate(defn, db)
        errors.any? { |e| e.includes?("person_full_name") && e.includes?("pay") }.should be_true
      end
    end
  end

  # ── Hard invariants (authoring-time gate) ────────────────────────────
  #
  # `validate_invariants` backs the create/update 422 gate. It covers only
  # the self-contained hard invariants; the advisory grant/existence checks
  # stay in `validate` (asserted above).
  describe "Validator.validate_invariants" do
    it "returns no errors for a valid replicate field" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))
        ensure_domain(db, "hr")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        Validator.validate_invariants(defn, db).should be_empty
      end
    end

    it "flags a source field that is a secret field" do
      with_db do |db|
        create_simple_doctype(db, "idsec", "Vault", %({
          "token": {"type": "secret", "mode": "hash"}
        }))

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate_invariants(defn, db)
        errors.any? { |e| e.includes?("vault_token") && e.includes?("secret") }.should be_true
      end
    end

    it "flags a source field that is itself a replica" do
      with_db do |db|
        # Inject the source doctype via raw mutation so its replicate field
        # lands without the authoring-time gate (the gate would not reject
        # this shape anyway — the source's own edge is valid).
        ensure_domain(db, "source")
        source_defn = Doctype::DoctypeDefinition.from_json(%({
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
        Mutation::Client.create(
          db, "core", "DocType",
          doc_id: "source.ExternalData",
          content: source_defn.to_json,
          actioner_id: "system",
        )

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate_invariants(defn, db)
        errors.any? { |e| e.includes?("person_name") && e.includes?("is itself a replicated field") }.should be_true
      end
    end

    it "flags a via field that is itself a replica" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true}
        }))
        ensure_domain(db, "hr")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate_invariants(defn, db)
        errors.any? { |e| e.includes?("name") && e.includes?("'via' field 'person_alias' is itself a replicated field") }.should be_true
      end
    end

    # ── B-271: tag escape through a tag-less replica ──────────────────

    it "flags a replica field that does not carry a tag of the source field" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))
        ensure_domain(db, "hr")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate_invariants(defn, db)
        errors.any? { |e| e.includes?("person_full_name") && e.includes?("pay") }.should be_true
      end
    end

    it "names each source tag the replica field misses" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay", "pii"]}
        }))
        ensure_domain(db, "hr")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        errors = Validator.validate_invariants(defn, db)
        errors.any? { |e| e.includes?("person_full_name") && e.includes?("pii") }.should be_true
      end
    end

    it "passes when the replica field carries every tag of the source field" do
      with_db do |db|
        create_simple_doctype(db, "identity", "Person", %({
          "full_name": {"type": "string", "required": true, "tags": ["pay"]}
        }))
        ensure_domain(db, "hr")

        defn_json = %({
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
        defn = Doctype::DoctypeDefinition.from_json(defn_json)
        Validator.validate_invariants(defn, db).should be_empty
      end
    end
  end
end
