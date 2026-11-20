# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "spec"
require "../spec_helper"
require "../support/db_helper"

# Tests for Document::ReferenceCheck
#
# These tests verify that the reference filter check works correctly.
# They use the shared test database environment (see spec_helper.cr) with
# seeded `core.DocType` projections so that `Document::List` can find
# the target doctype definitions.
# ── Helpers ──────────────────────────────────────────────────────────

# Creates a `core.DocType` projection for the target doctype so that
# `Document::List` can resolve the definition.
def seed_doctype(db, qualified_id, fields_def)
  domain, doc_type = qualified_id.split('.', 2)
  # fields_def is a Hash(String, String) where values are JSON strings;
  # build a proper JSON object so field definitions are real JSON, not
  # double-encoded strings.
  content_json = JSON.build do |builder|
    builder.object do
      builder.field("doctype", doc_type)
      builder.field("domain", domain)
      builder.field("fields") do
        builder.object do
          fields_def.each do |k, v|
            # v is a JSON string — emit it raw (already valid JSON)
            builder.field(k) { builder.raw(v) }
          end
        end
      end
      builder.field("schema_version", 1)
    end
  end

  db.exec(
    <<-SQL,
      INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, search, display_name, deleted_at, updated_at, created_at)
      VALUES ('core', 'DocType', $1, $2::jsonb, 1, '[]'::jsonb, '{}'::jsonb, 'state', NULL, NULL, NULL, now(), now())
      ON CONFLICT (domain, doc_type, id) DO UPDATE SET content = $2::jsonb, deleted_at = NULL
    SQL
    qualified_id, content_json
  )
end

# Creates a document projection for the target doctype (the referenced document).
def seed_target_document(db, domain, doc_type, id, content)
  content_json = content.to_json

  db.exec(
    <<-SQL,
      INSERT INTO projections (domain, doc_type, id, content, version, links, meta, state, search, display_name, deleted_at, updated_at, created_at)
      VALUES ($1, $2, $3, $4::jsonb, 1, '[]'::jsonb, '{}'::jsonb, 'state', NULL, NULL, NULL, now(), now())
      ON CONFLICT (domain, doc_type, id) DO UPDATE SET content = $4::jsonb, deleted_at = NULL
    SQL
    domain, doc_type, id, content_json
  )
end

module Facet
  describe Document::ReferenceCheck do
    describe ".check" do
      it "passes when there are no reference fields with filters" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "title" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
            },
          )
          doc = JSON.parse(%({"title": "hello"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "passes when the referenced document matches the filter" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          seed_target_document(conn, "test", "Company", "company_01", {"status" => "active"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"company": "company_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "fails when the referenced document does not match the filter" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          seed_target_document(conn, "test", "Company", "company_01", {"status" => "inactive"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"company": "company_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should_not be_empty
          errors.first.code.should eq("reference_filter_mismatch")
        end
      end

      it "passes when the reference value is null (skipped)" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"company": null}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "passes when the reference field is absent" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "fails when the target doctype is not registered" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Unknown",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"company": "unknown_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should_not be_empty
          errors.first.code.should eq("reference_target_not_found")
        end
      end

      it "passes for collection references when all elements match the filter" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          seed_target_document(conn, "test", "Company", "c1", {"status" => "active"})
          seed_target_document(conn, "test", "Company", "c2", {"status" => "active"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "companies" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                collection: true,
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"companies": ["c1", "c2"]}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "fails for collection references when one element does not match the filter" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          seed_target_document(conn, "test", "Company", "c1", {"status" => "active"})
          seed_target_document(conn, "test", "Company", "c2", {"status" => "inactive"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "companies" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                collection: true,
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )
          doc = JSON.parse(%({"companies": ["c1", "c2"]}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should_not be_empty
          errors.first.code.should eq("reference_filter_mismatch")
        end
      end

      it "uses the composite filter (id_eq + declared filter)" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {
            "status" => {
              "type"   => "enum",
              "values" => ["active", "inactive"],
            }.to_json,
          })

          # Two documents with the same status; we want to ensure the id_eq
          # part of the filter is also applied (not just the declared filter).
          seed_target_document(conn, "test", "Company", "company_a", {"status" => "active"})
          seed_target_document(conn, "test", "Company", "company_b", {"status" => "active"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
                filter: {"status__eq" => JSON::Any.new("active")},
              ),
            },
          )

          # Reference company_b — should pass because it's active
          doc = JSON.parse(%({"company": "company_b"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      # ── Unfiltered references ─────────────────────────────────────
      #
      # Every reference with a declared target is existence-checked,
      # with or without a `filter`. The composite filter degrades to a
      # bare `id__eq` lookup when no filter is declared.

      it "passes when an unfiltered reference points at an existing document" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {} of String => String)
          seed_target_document(conn, "test", "Company", "company_01", {"name" => "Acme"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
              ),
            },
          )
          doc = JSON.parse(%({"company": "company_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      it "rejects when an unfiltered reference points at a missing document" do
        with_db do |conn|
          seed_doctype(conn, "test.Company", {} of String => String)

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Company",
              ),
            },
          )
          doc = JSON.parse(%({"company": "unknown_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should_not be_empty
          errors.first.code.should eq("reference_filter_mismatch")
        end
      end

      it "rejects when the target doctype of an unfiltered reference is not registered" do
        with_db do |conn|
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Missing",
              ),
            },
          )
          doc = JSON.parse(%({"company": "company_01"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should_not be_empty
          errors.first.code.should eq("reference_target_not_found")
        end
      end

      it "skips the existence check when the field declares dangling: true" do
        with_db do |conn|
          # No doctype and no target document are seeded on purpose — the
          # dangling opt-out skips the whole reference lookup, including
          # target-doctype registration.
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Task",
            domain: "test",
            fields: {
              "company" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "test.Missing",
                dangling: true,
              ),
            },
          )
          doc = JSON.parse(%({"company": "not_yet_created"}))

          errors = Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system)
          errors.should be_empty
        end
      end

      # ── Caller-scoped existence check (B-356) ────────────────────
      #
      # The lookup runs under the caller's context. A target the caller
      # cannot read answers the same `reference_filter_mismatch` code as a
      # missing target, so the check never reveals that the row exists.

      it "refuses a readable-by-system target to a caller with no read grant on the target doctype" do
        with_db do |conn|
          seed_doctype(conn, "pay.Payroll", {} of String => String)
          seed_target_document(conn, "pay", "Payroll", "pay_01", {"name" => "March"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Employee",
            domain: "hr",
            fields: {
              "payroll" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "pay.Payroll",
              ),
            },
          )
          doc = JSON.parse(%({"payroll": "pay.Payroll.pay_01"}))

          # The target exists — the system caller sees it.
          Document::ReferenceCheck.check(conn, defn, doc, RBAC::AuthContext.system).should be_empty

          # An hr-only caller cannot read pay.Payroll. The answer is the
          # same non-disclosing 422 code as a missing target — never a pass,
          # never a 403.
          role = Facet::RBAC::ActiveRole.new(
            role_id: "hr_editor",
            visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
            permissions: [Facet::RBAC::Permission.new(action: "update", domain: "hr", path: ["Employee"])],
          )
          caller = Facet::RBAC::AuthContext.authenticated("hr_editor_account", role)

          errors = Document::ReferenceCheck.check(conn, defn, doc, caller)
          errors.should_not be_empty
          errors.first.code.should eq("reference_filter_mismatch")
          errors.first.message.should_not contain("Forbidden")
        end
      end

      it "passes for a caller that holds a read grant on the target doctype" do
        with_db do |conn|
          seed_doctype(conn, "pay.Payroll", {} of String => String)
          seed_target_document(conn, "pay", "Payroll", "pay_01", {"name" => "March"})

          defn = Doctype::DoctypeDefinition.new(
            doctype: "Employee",
            domain: "hr",
            fields: {
              "payroll" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "pay.Payroll",
              ),
            },
          )
          doc = JSON.parse(%({"payroll": "pay.Payroll.pay_01"}))

          role = Facet::RBAC::ActiveRole.new(
            role_id: "hr_reader_with_pay",
            visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
            permissions: [
              Facet::RBAC::Permission.new(action: "read", domain: "pay", path: ["Payroll"]),
            ],
          )
          caller = Facet::RBAC::AuthContext.authenticated("hr_reader_account", role)

          Document::ReferenceCheck.check(conn, defn, doc, caller).should be_empty
        end
      end

      it "accepts a cross-domain target for a caller without grants when the field declares dangling: true" do
        with_db do |conn|
          # No pay doctype and no target document are seeded: the dangling
          # opt-out skips registration, existence, filter, and RBAC alike.
          defn = Doctype::DoctypeDefinition.new(
            doctype: "Employee",
            domain: "hr",
            fields: {
              "payroll" => Doctype::FieldDefinition.new(
                type: Doctype::FieldType.parse("reference"),
                doctype: "pay.Payroll",
                dangling: true,
              ),
            },
          )
          doc = JSON.parse(%({"payroll": "pay.Payroll.unknown_id"}))

          role = Facet::RBAC::ActiveRole.new(
            role_id: "hr_only",
            visible_tags: Facet::RBAC::ActiveRole::DEFAULT_VISIBLE_TAGS,
            permissions: [Facet::RBAC::Permission.new(action: "update", domain: "hr", path: ["Employee"])],
          )
          caller = Facet::RBAC::AuthContext.authenticated("hr_only_account", role)

          Document::ReferenceCheck.check(conn, defn, doc, caller).should be_empty
        end
      end
    end
  end
end
