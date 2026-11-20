# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/util/money"
require "../../src/config"
require "../../src/document"
require "../../src/doctype"
require "../support/money_helper"

module Facet::Doctype
  # Helper to build a definition from a field map
  def self.make_definition(domain = "production", doctype = "WorkOrder", fields = {} of String => String, references = {} of String => String, **opts)
    parts = [] of String
    parts << "\"doctype\": \"#{doctype}\""
    parts << "\"domain\": \"#{domain}\""
    opts.each do |k, v|
      parts << "\"#{k}\": #{v}"
    end

    unless fields.empty?
      field_entries = fields.map do |name, type_def|
        "\"#{name}\": #{type_def}"
      end
      parts << "\"fields\": {#{field_entries.join(",")}}"
    end

    unless references.empty?
      ref_entries = references.map do |name, ref_def|
        "\"#{name}\": #{ref_def}"
      end
      parts << "\"references\": {#{ref_entries.join(",")}}"
    end

    DoctypeDefinition.from_json("{#{parts.join(",")}}")
  end
end

module Facet::Document
  describe Validation do
    # Money field validation requires a populated currency registry so
    # `MoneyType#validate` recognises tickers like USD. `before_each` (not
    # `before_all`) per the spec-helper rule.
    before_each do
      Facet::Config.reset!
      Facet::Config.instance
      register_seed_currencies
    end

    # ── Basic validation ─────────────────────────────────────────────

    it "validates a document with all required fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string", "required": true}),
        "age"  => %({"type": "integer"}),
      })
      doc = JSON.parse(%({"name": "Alice", "age": 30}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    it "rejects a non-object document" do
      defn = Facet::Doctype.make_definition
      doc = JSON.parse(%("just a string"))
      errors = Validation.validate(doc, defn)
      errors.map(&.message).should eq(["Document must be a JSON object"])
    end

    # ── Required fields ──────────────────────────────────────────────

    it "rejects missing required field" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string", "required": true}),
      })
      doc = JSON.parse(%({}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "name" && e.code == "required" }.should be_true
      errors.first.message.should contain("missing")
    end

    it "accepts missing non-required field" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })
      doc = JSON.parse(%({}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    # ── Unknown fields ───────────────────────────────────────────────

    it "rejects unknown fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })
      doc = JSON.parse(%({"name": "Alice", "unknown_field": "value"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "unknown_field" && e.code == "unknown_field" }.should be_true
    end

    it "names the wrapped-body fix for a lone content wrapper (F03-5)" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })

      # Wrapped body: the only unknown key is `content` with an object
      # value — the message must tell the caller how to fix it.
      doc = JSON.parse(%({"content": {"name": "Alice"}}))
      errors = Validation.validate(doc, defn)
      errors.size.should eq(1)
      errors.first.field.should eq("content")
      errors.first.message.should eq(
        "is not a defined field — this looks like a wrapped body: send the fields at the top level; there is no content wrapper"
      )

      # The `data` wrapper gets the same hint.
      data_doc = JSON.parse(%({"data": {"name": "Alice"}}))
      data_errors = Validation.validate(data_doc, defn)
      data_errors.size.should eq(1)
      data_errors.first.message.should contain("wrapped body")

      # A wrapper with a non-object value, and a mixed unknown set, keep
      # the plain message.
      plain = JSON.parse(%({"content": "not-an-object"}))
      Validation.validate(plain, defn).first.message.should eq("is not a defined field")
      mixed = JSON.parse(%({"content": {"name": "Alice"}, "bogus": 1}))
      mixed_errors = Validation.validate(mixed, defn)
      mixed_errors.any?(&.message.includes?("wrapped body")).should be_false
    end

    it "rejects server-owned keys as stray content fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })
      doc = JSON.parse(%({
        "name": "Alice",
        "id": "123",
        "doctype": "WorkOrder",
        "domain": "production",
        "created_at": "2024-01-01T00:00:00Z",
        "updated_at": "2024-01-02T00:00:00Z"
      }))
      errors = Validation.validate(doc, defn)
      errors.map(&.field).compact_map { |f| f }.sort!.should eq([
        "created_at", "doctype", "domain", "id", "updated_at",
      ])
      errors.each(&.code.should(eq("reserved")))
    end

    it "rejects server-owned keys on a patch" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })
      patch = JSON.parse(%({"name": "Alice", "id": "123"}))
      errors = Validation.validate_update(patch, defn)
      errors.size.should eq(1)
      errors.first.field.should eq("id")
      errors.first.code.should eq("reserved")
    end

    it "accepts server-owned key names the doctype declares as fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "id"   => %({"type": "string"}),
        "name" => %({"type": "string"}),
      })
      doc = JSON.parse(%({"name": "Alice", "id": "kept"}))
      Validation.validate(doc, defn).should be_empty
    end

    # ── Type validation ──────────────────────────────────────────────

    it "validates string field" do
      defn = Facet::Doctype.make_definition(fields: {"name" => %({"type": "string"})})
      doc = JSON.parse(%({"name": "Alice"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"name": 42}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "name" && e.message.includes?("must be a string") }.should be_true
    end

    it "validates integer field" do
      defn = Facet::Doctype.make_definition(fields: {"age" => %({"type": "integer"})})
      doc = JSON.parse(%({"age": 30}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"age": "thirty"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "age" && e.message.includes?("must be an integer") }.should be_true
    end

    it "validates boolean field" do
      defn = Facet::Doctype.make_definition(fields: {"active" => %({"type": "boolean"})})
      doc = JSON.parse(%({"active": true}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"active": "yes"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "active" && e.message.includes?("must be a boolean") }.should be_true
    end

    it "validates datetime field" do
      defn = Facet::Doctype.make_definition(fields: {"due_at" => %({"type": "datetime"})})
      doc = JSON.parse(%({"due_at": "2024-06-01T12:00:00Z"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"due_at": "not-a-date"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "due_at" && e.message.includes?("valid ISO 8601") }.should be_true
    end

    it "validates money field" do
      defn = Facet::Doctype.make_definition(fields: {"cost" => %({"type": "money"})})
      doc = JSON.parse(%({"cost": #{money_json("12.34", "USD")}}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"cost": #{money_json("100", "USD")}}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"cost": "not-money"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "cost" && e.message.includes?("money") }.should be_true

      # Bare numbers / decimal strings are rejected — `money` is always an object.
      errors = Validation.validate(JSON.parse(%({"cost": 100})), defn)
      errors.any? { |e| e.field == "cost" && e.message.includes?("money") }.should be_true
      errors = Validation.validate(JSON.parse(%({"cost": "9.99"})), defn)
      errors.any? { |e| e.field == "cost" && e.message.includes?("money") }.should be_true
    end

    it "validates money field rejects an unregistered currency" do
      defn = Facet::Doctype.make_definition(fields: {"cost" => %({"type": "money"})})
      doc = JSON.parse(%({"cost": #{money_json("100", "XYZ")}}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "cost.currency" && e.message.includes?("registered currency") }.should be_true
    end

    it "validates money field rejects an object missing value or currency" do
      defn = Facet::Doctype.make_definition(fields: {"cost" => %({"type": "money"})})
      errors = Validation.validate(JSON.parse(%({"cost": {"value": "100"}})), defn)
      errors.any? { |e| e.field == "cost.currency" }.should be_true
      errors = Validation.validate(JSON.parse(%({"cost": {"currency": "USD"}})), defn)
      errors.any? { |e| e.field == "cost.value" }.should be_true
    end

    it "validates object field" do
      defn = Facet::Doctype.make_definition(fields: {"specs" => %({"type": "object"})})
      doc = JSON.parse(%({"specs": {"key": "value"}}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"specs": "not-an-object"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "specs" && e.message.includes?("must be an object") }.should be_true
    end

    # ── Enum validation ──────────────────────────────────────────────

    it "validates enum field with allowed values" do
      defn = Facet::Doctype.make_definition(fields: {
        "status" => %({"type": "enum", "values": ["open", "closed", "pending"]}),
      })
      doc = JSON.parse(%({"status": "open"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"status": "invalid_status"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "status" && e.message.includes?("invalid enum") }.should be_true
    end

    it "rejects enum field with non-string value" do
      defn = Facet::Doctype.make_definition(fields: {
        "status" => %({"type": "enum", "values": ["open", "closed"]}),
      })
      doc = JSON.parse(%({"status": 42}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "status" && e.message.includes?("must be a string (enum)") }.should be_true
    end

    # ── Reference validation ──────────────────────────────────────────

    it "validates reference field (qualified ID)" do
      defn = Facet::Doctype.make_definition(fields: {
        "product" => %({"doctype": "catalog.Product"}),
      })
      doc = JSON.parse(%({"product": "catalog.Product.prod-123"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"product": null}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"product": 42}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "product" && e.message.includes?("must be a string") }.should be_true
    end

    it "rejects a bare reference id (normalize must run before validate)" do
      defn = Facet::Doctype.make_definition(fields: {
        "product" => %({"doctype": "catalog.Product"}),
      })
      doc = JSON.parse(%({"product": "prod-123"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "product" && e.code == "invalid_reference_format" }.should be_true
    end

    it "rejects a reference whose prefix does not match the declared doctype" do
      defn = Facet::Doctype.make_definition(fields: {
        "product" => %({"doctype": "catalog.Product"}),
      })
      doc = JSON.parse(%({"product": "hr.Employee.prod-123"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "product" && e.code == "reference_doctype_mismatch" }.should be_true
    end

    # A `collection: true` reference field carries a JSON array of qualified
    # ids; each element is validated in turn. Mirrors the collection handling
    # in `ReferenceCheck`, `Links`, and the CSV serializer.
    it "validates a collection reference field from an array of qualified ids" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": ["hr.Employee.01AAA", "hr.Employee.01BBB"]}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    it "rejects a scalar value on a collection reference field" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": "hr.Employee.01AAA"}))
      errors = Validation.validate(doc, defn)
      errors.map(&.message).should eq(["must be an array"])
    end

    it "reports an invalid collection reference element at its indexed path" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": ["hr.Employee.01AAA", 42]}))
      errors = Validation.validate(doc, defn)
      errors.map(&.field).should eq(["assignees.1"])
    end

    it "skips null elements in a collection reference field" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": [null, "hr.Employee.01AAA"]}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    # A repeated target renders one capsule per token against a keyed
    # each-block whose key is the token, so the render throws (F10-A). The
    # write path rejects the value; it never dedupes stored content.
    it "rejects a collection reference that repeats the same target (F10-A)" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": ["hr.Employee.01AAA", "hr.Employee.01BBB", "hr.Employee.01AAA"]}))
      errors = Validation.validate(doc, defn)
      errors.size.should eq(1)
      errors.first.field.should eq("assignees")
      errors.first.code.should eq("duplicate_reference_target")
      errors.first.message.should contain("repeats the reference target 'hr.Employee.01AAA'")
    end

    it "rejects a duplicated target spelled as bare ids once normalized (pipeline order)" do
      defn = Facet::Doctype.make_definition(fields: {
        "assignees" => %({"doctype": "hr.Employee", "collection": true}),
      })
      doc = JSON.parse(%({"assignees": ["01AAA", "hr.Employee.01AAA"]}))
      normalized = Normalize.call(doc, defn)
      errors = Validation.validate(normalized, defn)
      errors.any? { |e| e.code == "duplicate_reference_target" }.should be_true
    end

    # ── Read‑only field ───────────────────────────────────────────────

    it "rejects input for read_only fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "slug" => %({"type": "string", "read_only": true}),
      })
      doc = JSON.parse(%({"slug": "my-doc"}))
      errors = Validation.validate(doc, defn)
      errors.map(&.message).should eq(["is read-only and should not be set"])
      errors.first.try(&.field).should eq("slug")
    end

    it "allows read_only field to be absent" do
      defn = Facet::Doctype.make_definition(fields: {
        "slug" => %({"type": "string", "read_only": true}),
      })
      doc = JSON.parse(%({}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    it "type-checks write_only field like normal" do
      defn = Facet::Doctype.make_definition(fields: {
        "password" => %({"type": "string", "write_only": true}),
      })
      doc = JSON.parse(%({"password": "secret"}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty

      doc = JSON.parse(%({"password": 42}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "password" && e.message.includes?("must be a string") }.should be_true
    end

    # ── Data (computed) field ─────────────────────────────────────────

    it "rejects input for computed (data) fields" do
      defn = Facet::Doctype.make_definition(fields: {
        "progress" => %({"type": "data", "compute": "wo_progress"}),
      })
      doc = JSON.parse(%({"progress": "some_value"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "progress" && e.code == "read_only" && e.message.includes?("computed") }.should be_true
    end

    it "allows computed field to be absent" do
      defn = Facet::Doctype.make_definition(fields: {
        "progress" => %({"type": "data", "compute": "wo_progress"}),
      })
      doc = JSON.parse(%({}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    # ── Multiple errors ──────────────────────────────────────────────

    it "returns multiple errors for multiple field violations" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string", "required": true}),
        "age"  => %({"type": "integer", "required": true}),
      })
      doc = JSON.parse(%({"name": 42, "age": "old"}))
      errors = Validation.validate(doc, defn)
      errors.size.should be >= 2
    end

    # ── Implicit reference ───────────────────────────────────────

    it "validates implicit reference (doctype without type)" do
      defn = Facet::Doctype.make_definition(fields: {
        "product" => %({"doctype": "catalog.Product"}),
      })
      doc = JSON.parse(%({"product": "catalog.Product.prod-001"}))
      errors = Validation.validate(doc, defn)
      errors.should be_empty
    end

    # ── LongText validation ───────────────────────────────────────────

    it "validates longtext field as a string" do
      defn = Facet::Doctype.make_definition(fields: {
        "description" => %({"type": "longtext"}),
      })
      doc = JSON.parse(%({"description": "a long description"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"description": 42}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "description" && e.message.includes?("must be a string") }.should be_true
    end

    # ── Pattern validation ────────────────────────────────────────────

    it "validates string matches pattern" do
      defn = Facet::Doctype.make_definition(fields: {
        "code" => %({"type": "string", "pattern": "^WO-[0-9]{4}$"}),
      })
      doc = JSON.parse(%({"code": "WO-1234"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"code": "invalid"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "code" && e.message.includes?("does not match pattern") }.should be_true
    end

    it "validates longtext matches pattern" do
      defn = Facet::Doctype.make_definition(fields: {
        "bio" => %({"type": "longtext", "pattern": "^[A-Z]"}),
      })
      doc = JSON.parse(%({"bio": "Hello world"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"bio": "hello world"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "bio" && e.message.includes?("does not match pattern") }.should be_true
    end

    it "applies case-insensitive pattern via pattern_flags" do
      defn = Facet::Doctype.make_definition(fields: {
        "email" => %({"type": "string", "pattern": "^[a-z]+@example.com$", "pattern_flags": "i"}),
      })
      doc = JSON.parse(%({"email": "User@example.com"}))
      Validation.validate(doc, defn).should be_empty

      doc = JSON.parse(%({"email": "user@other.com"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "email" && e.message.includes?("does not match pattern") }.should be_true
    end

    it "skips pattern validation when pattern is not set" do
      defn = Facet::Doctype.make_definition(fields: {
        "name" => %({"type": "string"}),
      })
      doc = JSON.parse(%({"name": "anything goes here"}))
      Validation.validate(doc, defn).should be_empty
    end

    it "skips pattern validation for null values" do
      defn = Facet::Doctype.make_definition(fields: {
        "code" => %({"type": "string", "pattern": "^WO-[0-9]{4}$"}),
      })
      doc = JSON.parse(%({"code": null}))
      Validation.validate(doc, defn).should be_empty
    end

    it "returns error for invalid pattern regex" do
      defn = Facet::Doctype.make_definition(fields: {
        "code" => %({"type": "string", "pattern": "[invalid"}),
      })
      doc = JSON.parse(%({"code": "test"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "code" && (e.message.includes?("invalid pattern") || e.message.includes?("Regex")) }.should be_true
    end

    # ── Array field validation ────────────────────────────────────────────

    describe "Array field validation" do
      it "accepts array of strings" do
        defn = Facet::Doctype.make_definition(fields: {
          "tags" => %({"type": "array", "items": {"type": "string"}}),
        })
        doc = JSON.parse(%({"tags": ["hello", "world"]}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "rejects non-array value" do
        defn = Facet::Doctype.make_definition(fields: {
          "tags" => %({"type": "array", "items": {"type": "string"}}),
        })
        doc = JSON.parse(%({"tags": "not-an-array"}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "tags" && e.message.includes?("must be an array") }.should be_true
      end

      it "validates element types" do
        defn = Facet::Doctype.make_definition(fields: {
          "scores" => %({"type": "array", "items": {"type": "integer"}}),
        })
        doc = JSON.parse(%({"scores": [1, "two", 3]}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "scores.1" && e.message.includes?("must be an integer") }.should be_true
      end

      it "accepts empty array" do
        defn = Facet::Doctype.make_definition(fields: {
          "tags" => %({"type": "array", "items": {"type": "string"}}),
        })
        doc = JSON.parse(%({"tags": []}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "accepts null value" do
        defn = Facet::Doctype.make_definition(fields: {
          "tags" => %({"type": "array", "items": {"type": "string"}}),
        })
        doc = JSON.parse(%({"tags": null}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "validates array of objects with properties" do
        defn = Facet::Doctype.make_definition(fields: {
          "items" => %({"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string", "required": true}, "qty": {"type": "integer"}}}}),
        })
        doc = JSON.parse(%({"items": [{"name": "foo", "qty": 2}, {"name": "bar"}]}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "validates array of enums" do
        defn = Facet::Doctype.make_definition(fields: {
          "sizes" => %({"type": "array", "items": {"type": "enum", "values": ["small", "medium", "large"]}}),
        })
        doc = JSON.parse(%({"sizes": ["small", "large"]}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty

        doc = JSON.parse(%({"sizes": ["small", "xlarge"]}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "sizes.1" && e.message.includes?("invalid enum") }.should be_true
      end
    end

    # ── Object field with properties ──────────────────────────────────────

    describe "Object field with properties" do
      it "accepts a valid object with matching sub-fields" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string", "required": true}, "city": {"type": "string"}}}),
        })
        doc = JSON.parse(%({"address": {"street": "123 Main", "city": "Springfield"}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "rejects non-object value" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string"}}}),
        })
        doc = JSON.parse(%({"address": "not-an-obj"}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "address" && e.message.includes?("must be an object") }.should be_true
      end

      it "requires required sub-fields" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string", "required": true}, "city": {"type": "string"}}}),
        })
        doc = JSON.parse(%({"address": {"city": "Springfield"}}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "address.street" && e.code == "required" }.should be_true
      end

      it "rejects unknown sub-fields" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string"}}}),
        })
        doc = JSON.parse(%({"address": {"street": "123 Main", "unknown": "value"}}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "address.unknown" && e.code == "unknown_field" }.should be_true
      end

      it "validates sub-field types" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string"}, "zip": {"type": "integer"}}}),
        })
        doc = JSON.parse(%({"address": {"street": 42, "zip": "wrong"}}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "address.street" && e.message.includes?("must be a string") }.should be_true
        errors.any? { |e| e.field == "address.zip" && e.message.includes?("must be an integer") }.should be_true
      end

      it "allows null values for non-required sub-fields" do
        defn = Facet::Doctype.make_definition(fields: {
          "address" => %({"type": "object", "properties": {"street": {"type": "string"}, "zip": {"type": "integer"}}}),
        })
        doc = JSON.parse(%({"address": {"street": "123 Main", "zip": null}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end
    end

    # ── Dictionary field validation ───────────────────────────────────────

    describe "Dictionary field validation" do
      it "accepts valid dictionary" do
        defn = Facet::Doctype.make_definition(fields: {
          "metadata" => %({"type": "dictionary", "values": {"type": "string"}}),
        })
        doc = JSON.parse(%({"metadata": {"env": "prod", "region": "us-east"}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "rejects non-object value" do
        defn = Facet::Doctype.make_definition(fields: {
          "metadata" => %({"type": "dictionary", "values": {"type": "string"}}),
        })
        doc = JSON.parse(%({"metadata": "not-an-obj"}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "metadata" && e.message.includes?("must be an object") }.should be_true
      end

      it "validates value types" do
        defn = Facet::Doctype.make_definition(fields: {
          "metadata" => %({"type": "dictionary", "values": {"type": "string"}}),
        })
        doc = JSON.parse(%({"metadata": {"env": "prod", "count": 42}}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "metadata.count" && e.message.includes?("must be a string") }.should be_true
      end

      it "accepts empty object" do
        defn = Facet::Doctype.make_definition(fields: {
          "metadata" => %({"type": "dictionary", "values": {"type": "string"}}),
        })
        doc = JSON.parse(%({"metadata": {}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end

      it "validates dictionary with integer values" do
        defn = Facet::Doctype.make_definition(fields: {
          "counts" => %({"type": "dictionary", "values": {"type": "integer"}}),
        })
        doc = JSON.parse(%({"counts": {"a": 1, "b": 2}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty

        doc = JSON.parse(%({"counts": {"a": "one", "b": 2}}))
        errors = Validation.validate(doc, defn)
        errors.any? { |e| e.field == "counts.a" && e.message.includes?("must be an integer") }.should be_true
      end

      it "accepts null values" do
        defn = Facet::Doctype.make_definition(fields: {
          "metadata" => %({"type": "dictionary", "values": {"type": "string"}}),
        })
        doc = JSON.parse(%({"metadata": {"env": "prod", "notes": null}}))
        errors = Validation.validate(doc, defn)
        errors.should be_empty
      end
    end

    # ── System writes (allow_system_writes) ─────────────────────────

    it "rejects a read_only field in a user create body" do
      defn = Facet::Doctype.make_definition(fields: {
        "slug" => %({"type": "string", "read_only": true}),
      })
      doc = JSON.parse(%({"slug": "my-doc"}))
      errors = Validation.validate(doc, defn)
      errors.any? { |e| e.field == "slug" && e.code == "read_only" }.should be_true
    end

    it "rejects a read_only field in a user update patch" do
      defn = Facet::Doctype.make_definition(fields: {
        "slug" => %({"type": "string", "read_only": true}),
      })
      patch = JSON.parse(%({"slug": "my-doc"}))
      errors = Validation.validate_update(patch, defn)
      errors.any? { |e| e.field == "slug" && e.code == "read_only" }.should be_true
    end

    it "rejects a replicated field in a user update patch" do
      defn = Facet::Doctype.make_definition(fields: {
        "remote_status" => %({"type": "string", "replicate": {"via": "target", "field": "status"}}),
      })
      patch = JSON.parse(%({"remote_status": "open"}))
      errors = Validation.validate_update(patch, defn)
      errors.any? { |e| e.field == "remote_status" && e.code == "read_only" }.should be_true
    end

    it "accepts a read_only field when allow_system_writes is true" do
      defn = Facet::Doctype.make_definition(fields: {
        "slug" => %({"type": "string", "read_only": true}),
      })
      doc = JSON.parse(%({"slug": "my-doc"}))
      errors = Validation.validate(doc, defn, allow_system_writes: true)
      errors.should be_empty

      patch = JSON.parse(%({"slug": "my-doc"}))
      errors = Validation.validate_update(patch, defn, allow_system_writes: true)
      errors.should be_empty
    end

    it "accepts a replicated field when allow_system_writes is true" do
      defn = Facet::Doctype.make_definition(fields: {
        "remote_status" => %({"type": "string", "replicate": {"via": "target", "field": "status"}}),
      })
      patch = JSON.parse(%({"remote_status": "open"}))
      errors = Validation.validate_update(patch, defn, allow_system_writes: true)
      errors.should be_empty
    end
  end
end
