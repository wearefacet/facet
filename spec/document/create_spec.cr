# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "pg"
require "../../src/doctype"
require "../../src/rbac"

module Facet::Document
  describe Create do
    # ── core.DocType delegation ─────────────────────────────────────────

    describe "core.DocType delegation" do
      it "creates a doctype definition via the general Document::Create" do
        with_temp_doctype("delegation") do |db, domain, doctype|
          ensure_domain(db, domain)
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
          result = Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          proj = expect_create_success(result).projection
          proj.domain.should eq("core")
          proj.doc_type.should eq("DocType")
          proj.id.should eq("#{domain}.#{doctype}")
          proj.content["doctype"].should eq(JSON.parse(%("#{doctype}")))
          proj.deleted_at.should be_nil
        end
      end

      it "returns an error for invalid core.DocType definitions" do
        with_temp_doctype("delegation") do |db, domain, doctype|
          ensure_domain(db, domain)
          # Empty field name → Doctype::Validation error
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"": {"type": "string"}}})
          result = Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("Doctype validation failed")
          err.details.should be_a(Array(Facet::ValidationError))
          err.details.try &.should_not be_empty
        end
      end

      it "returns an error for malformed JSON in core.DocType" do
        with_temp_doctype("delegation") do |db, _, _|
          result = Create.call(db, "core", "DocType", "this is not json", Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("Invalid doctype definition")
        end
      end

      it "returns an error when the domain does not exist" do
        with_temp_doctype("delegation") do |db, _, doctype|
          json = %({"doctype": "#{doctype}", "domain": "nonexistent", "fields": {"title": {"type": "string", "required": true}}})
          result = Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("Domain 'nonexistent' does not exist")
        end
      end
    end

    # ── General document creation ───────────────────────────────────────

    describe "general document creation" do
      it "returns 404 when the doctype definition does not exist" do
        with_temp_doctype("gen") do |db, domain, _|
          result = Create.call(db, domain, "UnknownDoctype", %({"title": "foo"}), Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 404)
          err.message.should contain("Unknown doctype")
          err.message.should contain("#{domain}.UnknownDoctype")
        end
      end

      it "returns 422 for invalid JSON body" do
        with_temp_doctype("gen") do |db, domain, doctype|
          # First create the doctype definition
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          # Then try to create a document with malformed JSON
          result = Create.call(db, domain, doctype, "not valid json", Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("Invalid JSON body")
        end
      end

      # B-59: a body that parses but is not a JSON object used to escape as
      # a 500 Crystal type error (`Expected Hash for #[]?`); it must answer
      # the same 422 channel the update/doctype/action paths use.
      it "returns 422 for a non-object JSON body on document create (B-59)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %("x"), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should eq("Body must be a JSON object (got string)")

          result = Create.call(db, domain, doctype, %([1,2]), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should eq("Body must be a JSON object (got array)")
        end
      end

      it "returns 422 for a non-object JSON body on core.Domain create (B-59)" do
        with_temp_doctype("gen") do |db, _, _|
          result = Create.call(db, "core", "Domain", %("x"), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.message.should eq("Body must be a JSON object (got string)")
        end
      end

      it "creates a document when the body passes validation" do
        with_temp_doctype("gen") do |db, domain, doctype|
          # First create the doctype definition
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          # Then create a document of that doctype
          result = Create.call(db, domain, doctype, %({"title": "My first task"}), Facet::RBAC::AuthContext.system)

          proj = expect_create_success(result).projection
          proj.domain.should eq(domain)
          proj.doc_type.should eq(doctype)
          proj.content["title"].should eq(JSON.parse(%("My first task")))
          proj.deleted_at.should be_nil
          proj.version.should eq(1)
          proj.id.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
        end
      end

      it "returns field-level errors when document validation fails" do
        with_temp_doctype("gen") do |db, domain, doctype|
          # First create the doctype definition
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {"title": {"type": "string", "required": true}}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          # Missing required field
          result = Create.call(db, domain, doctype, %({"description": "no title"}), Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("Document validation failed")
          err.details.should be_a(Array(Facet::ValidationError))

          details = err.details.not_nil!
          details.any? { |e| e.field == "title" && e.code == "required" }.should be_true
        end
      end

      it "returns multiple field-level errors for multiple violations" do
        with_temp_doctype("gen") do |db, domain, doctype|
          # Define a doctype with two required fields of different types
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "age": {"type": "integer", "required": true}
          }})
          ensure_domain(db, domain)
          Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          # Both fields wrong: name missing, age wrong type, unknown field
          result = Create.call(db, domain, doctype, %({"age": "not-a-number", "extra": "surprise"}), Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          details = err.details.not_nil!
          details.any? { |e| e.field == "name" && e.code == "required" }.should be_true
          details.any? { |e| e.field == "age" && e.code == "invalid_type" }.should be_true
          details.any? { |e| e.field == "extra" && e.code == "unknown_field" }.should be_true
        end
      end

      it "rejects an explicit null on a required field with a 422 (not a 500)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          # `subject` is required; the other fields are optional.
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "subject": {"type": "string", "required": true},
            "description": {"type": "string"}
          }})
          ensure_domain(db, domain)
          Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          # Frontend-style payload: every blank field sent as `null`.
          result = Create.call(db, domain, doctype, %({"subject": null, "description": null}), Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          details = err.details.not_nil!
          # The required field is rejected with a clear, field-named message.
          details.any? { |e| e.field == "subject" && e.code == "required" }.should be_true
          # The optional field's null is accepted (= unset), not flagged.
          details.any? { |e| e.field == "description" }.should be_false
        end
      end

      it "allows null on optional fields (treated as unset)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "note": {"type": "string"}
          }})
          ensure_domain(db, domain)
          Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          result = Create.call(db, domain, doctype, %({"name": "Alice", "note": null}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["name"].should eq(JSON.parse(%("Alice")))
          # Optional field sent as null is stored as null (unset).
          proj.content["note"]?.try(&.raw.nil?).should be_true
        end
      end

      # B-298: a required field with a declared default is satisfiable by
      # omission — defaults apply before validation, mirroring the B-57 fix
      # on the action-args path.
      it "fills a required field's declared default when the body omits it (B-298)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "subject": {"type": "string", "required": true},
            "status": {"type": "string", "required": true, "default": "open"}
          }})
          ensure_domain(db, domain)
          Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          # Omission is filled with the declared default.
          result = Create.call(db, domain, doctype, %({"subject": "Task"}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["status"].should eq(JSON.parse(%("open")))

          # An explicit value still wins over the default.
          result = Create.call(db, domain, doctype, %({"subject": "Task", "status": "done"}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["status"].should eq(JSON.parse(%("done")))
        end
      end

      # F10-A: a repeated target in one collection reference renders two
      # identical keyed capsules and crashes the table, so the write path
      # rejects the value instead of storing it. The field is `dangling` so
      # the example needs no target documents — the duplicate rule runs in
      # the field-type validation, before the existence check.
      it "rejects a collection reference that repeats a target with a 422 naming the field (F10-A)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "watchers": {"type": "reference", "doctype": "hr.Employee", "collection": true, "dangling": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "T", "watchers": ["01AAA", "01BBB", "01AAA"]}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          details = err.details.not_nil!
          details.any? { |e| e.field == "watchers" && e.code == "duplicate_reference_target" }.should be_true
        end
      end

      it "creates a document with distinct and single-element collection references (F10-A)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "watchers": {"type": "reference", "doctype": "hr.Employee", "collection": true, "dangling": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "T", "watchers": ["01AAA", "01BBB"]}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["watchers"].as_a.map(&.as_s).should eq(["hr.Employee.01AAA", "hr.Employee.01BBB"])

          result = Create.call(db, domain, doctype, %({"name": "T2", "watchers": ["01CCC"]}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["watchers"].as_a.map(&.as_s).should eq(["hr.Employee.01CCC"])
        end
      end

      # The materialized default follows the same rules as a submitted
      # value: it is normalized and type-validated before the mutation lands.
      it "type-validates a declared default like a submitted value (B-298)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          json = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "subject": {"type": "string", "required": true},
            "count": {"type": "integer", "required": true, "default": "not-a-number"}
          }})
          ensure_domain(db, domain)
          Create.call(db, "core", "DocType", json, Facet::RBAC::AuthContext.system)

          result = Create.call(db, domain, doctype, %({"subject": "Task"}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          details = err.details.not_nil!
          details.any? { |e| e.field == "count" && e.code == "invalid_type" }.should be_true
        end
      end

      # ── write_only field stripping ───────────────────────────────────

      it "strips write_only fields from the persisted document" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "password": {"type": "string", "write_only": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "Alice", "password": "secret123"}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["name"].should eq(JSON.parse(%("Alice")))
          proj.content["password"]?.should be_nil
        end
      end

      it "keeps write_only fields available to the script during create" do
        with_temp_doctype("gen") do |db, domain, doctype|
          script = <<-LUA
            local export = {}
            function export.create(ctx)
              ctx.root.password_hash = ctx.root.password .. "_hashed"
            end
            return export
          LUA
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "password": {"type": "string", "write_only": true},
            "password_hash": {"type": "string", "read_only": true}
          }, "script": #{script.to_json}})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "Alice", "password": "secret123"}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["name"].should eq(JSON.parse(%("Alice")))
          proj.content["password"]?.should be_nil
          proj.content["password_hash"].should eq(JSON.parse(%("secret123_hashed")))
        end
      end

      it "rejects read_only fields in user input" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "slug": {"type": "string", "read_only": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "Alice", "slug": "alice"}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.details.not_nil!.any? { |e| e.field == "slug" && e.code == "read_only" }.should be_true
        end
      end

      # B-349: the read-only caller-write gate runs on the raw caller body,
      # before defaults are applied. `ApplyDefaults` fills a missing
      # read-only field with its declared default after the gate, so a
      # create that omits the field succeeds and stores the default. An
      # explicit caller value still answers 422.
      it "creates with a read_only default applied when the caller omits the field (B-349)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "active": {"type": "boolean", "default": false, "read_only": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
          proj = expect_create_success(result).projection
          proj.content["active"].as_bool.should be_false
        end
      end

      it "rejects an explicit read_only field that carries a default (B-349)" do
        with_temp_doctype("gen") do |db, domain, doctype|
          defn_schema = %({"doctype": "#{doctype}", "domain": "#{domain}", "fields": {
            "name": {"type": "string", "required": true},
            "active": {"type": "boolean", "default": false, "read_only": true}
          }})
          create_doctype(Facet::Doctype::DoctypeDefinition.from_json(defn_schema))

          result = Create.call(db, domain, doctype, %({"name": "Alice", "active": true}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          err.details.not_nil!.any? { |e| e.field == "active" && e.code == "read_only" }.should be_true
        end
      end
    end

    # ── core.Domain context set validation ──────────────────────────────────

    describe "iam.Account named id" do
      it "derives the document id from the lowercased email" do
        with_temp_doctype("named-id") do |db, _, _|
          ensure_account_doctype(db)
          result = Create.call(db, "iam", "Account",
            %({"email": "  Mixed.Case@Example.COM ", "name": "Mixed"}),
            Facet::RBAC::AuthContext.system)

          proj = expect_create_success(result).projection
          proj.id.should eq("mixed.case@example.com")
          # The stored email equals the id — the create hook normalizes.
          proj.content["email"].as_s.should eq("mixed.case@example.com")
        end
      end

      it "answers 409 when an account with the email already exists" do
        with_temp_doctype("named-id") do |db, _, _|
          ensure_account_doctype(db)
          first = Create.call(db, "iam", "Account",
            %({"email": "taken@example.com", "name": "First"}),
            Facet::RBAC::AuthContext.system)
          expect_create_success(first)

          second = Create.call(db, "iam", "Account",
            %({"email": "TAKEN@example.com", "name": "Second"}),
            Facet::RBAC::AuthContext.system)
          err = expect_create_error(second, status: 409)
          err.message.should contain("taken@example.com")
        end
      end

      it "answers 422 when the account carries no email" do
        with_temp_doctype("named-id") do |db, _, _|
          ensure_account_doctype(db)
          result = Create.call(db, "iam", "Account",
            %({"name": "No Email"}), Facet::RBAC::AuthContext.system)
          err = expect_create_error(result, status: 422)
          # The definition's required check names the field; the named-id
          # branch is the backstop for a create that reaches it without one.
          err.details.not_nil!.any? { |d| d.field == "email" }.should be_true
        end
      end
    end

    describe "core.Domain context set validation" do
      it "creates a domain with valid context sets" do
        with_db do |db|
          domain = "ctx_valid_#{unique_suffix}"
          body = %({
            "id": "#{domain}",
            "context_sets": {
              "my_teams": {
                "from": "TeamMembership",
                "select": "team",
                "where": {"account": "$self"}
              }
            }
          })
          result = Create.call(db, "core", "Domain", body, Facet::RBAC::AuthContext.system)

          proj = expect_create_success(result).projection
          proj.id.should eq(domain)
        end
      end

      it "rejects a SQL injection select field" do
        with_db do |db|
          domain = "ctx_inj_#{unique_suffix}"
          body = %({
            "id": "#{domain}",
            "context_sets": {
              "mine": {
                "from": "Thing",
                "select": "x' UNION SELECT password_hash FROM auth_secrets --",
                "where": {"account": "$self"}
              }
            }
          })
          result = Create.call(db, "core", "Domain", body, Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("RBAC context set validation failed")
          err.details.not_nil!.any? { |e| e.code == "context_set" && e.message.includes?("select") && e.message.includes?("mine") }.should be_true
        end
      end

      it "rejects a SQL injection where field" do
        with_db do |db|
          domain = "ctx_inj2_#{unique_suffix}"
          body = %({
            "id": "#{domain}",
            "context_sets": {
              "mine": {
                "from": "Thing",
                "select": "id",
                "where": {"x' UNION SELECT 1 --": "$self"}
              }
            }
          })
          result = Create.call(db, "core", "Domain", body, Facet::RBAC::AuthContext.system)

          err = expect_create_error(result, status: 422)
          err.message.should contain("RBAC context set validation failed")
          err.details.not_nil!.any? { |e| e.code == "context_set" && e.message.includes?("where") && e.message.includes?("mine") }.should be_true
        end
      end
    end
  end
end

# Ensures the account + role doctype definitions the named-id specs need
# (truncation wipes them). The production role corpus would fail here —
# its scoped permissions need the registered core doctypes — so only the
# definitions are ensured. File-scoped private def — see the
# top-level-defs rule in doc/backend/workflow.md.
private def ensure_account_doctype(db) : Nil
  Facet::Doctype::Seed.ensure_doctype_definition(db, "iam", "Account")
  Facet::Doctype::Seed.ensure_doctype_definition(db, "iam", "Roles")
end
