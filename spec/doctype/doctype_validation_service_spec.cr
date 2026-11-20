# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

# Builds an aggregate-root definition body with caller-chosen fields.
# File-owned helper for the reference-target qualification specs.
private def ref_target_defn_json(fields : String) : String
  %({"doctype": "WorkOrder", "domain": "production", "search": "{{ display_name }}", "aggregate_root": true, "fields": #{fields}})
end

module Facet::Doctype
  describe Validation do
    # ── Valid definitions ────────────────────────────────────────────

    it "returns empty errors for a valid minimal definition" do
      # An aggregate root must declare a label or a search template
      # (B-296); `search` alone is enough — it defaults to the label.
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ display_name }}"
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "returns empty errors for a full valid definition" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 3,
        "aggregate_root": true,
        "display_name": "{{ code }}",
        "fields": {
          "code":   { "type": "string", "required": true },
          "status": { "type": "enum", "values": ["open", "closed"] }
        },

        "actions": {
          "release": { "args": {} },
          "complete": { "args": {} }
        },
        "script": "local export = {}; function export.release(args) end; function export.complete(args) end; return export"
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Templates present (B-296) ────────────────────────────────

    it "rejects a create of an aggregate root with neither template" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true,
        "fields": {"code": {"type": "string"}}
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.message.should contain("neither a display_name nor a search template")
      errors.first.message.should contain("search defaults to it")
    end

    it "accepts a create when only the search template is declared" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {"code": {"type": "string"}}
      })
      Validation.validate(DoctypeDefinition.from_json(json)).should be_empty
    end

    it "accepts a create when only the display_name template is declared" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ code }}",
        "fields": {"code": {"type": "string"}}
      })
      Validation.validate(DoctypeDefinition.from_json(json)).should be_empty
    end

    it "treats a whitespace-only template as absent" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true,
        "display_name": "   ",
        "fields": {"code": {"type": "string"}}
      })
      errors = Validation.validate(DoctypeDefinition.from_json(json))
      errors.any?(&.message.includes?("neither a display_name nor a search template")).should be_true
    end

    it "exempts an owned child from the template gate" do
      json = %({
        "doctype": "LineItem",
        "domain": "production",
        "member_of": "WorkOrder",
        "fields": {"label": {"type": "string"}}
      })
      Validation.validate(DoctypeDefinition.from_json(json)).should be_empty
    end

    it "exempts a doctype that is neither an aggregate root nor an owned child" do
      # `aggregate_root: false` and no `member_of` is not a root; the runtime
      # never surfaces it through the cross-doctype search, so the label gate
      # does not apply. `Doctype::Check` reports the missing root declaration.
      json = %({
        "doctype": "Lookup",
        "domain": "production",
        "aggregate_root": false,
        "fields": {"label": {"type": "string"}}
      })
      Validation.validate(DoctypeDefinition.from_json(json)).should be_empty
    end

    it "skips the template gate on the update door" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true,
        "fields": {"code": {"type": "string"}}
      })
      Validation.validate(DoctypeDefinition.from_json(json), creation: false).should be_empty
    end

    it "skips the template gate in draft mode" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "_draft01",
        "aggregate_root": true,
        "fields": {"code": {"type": "string"}}
      })
      Validation.validate_draft(DoctypeDefinition.from_json(json)).should be_empty
    end

    # ── Actions without a script (B-299) ────────────────────────────

    it "rejects declared actions when no script is defined" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {"code": {"type": "string"}},
        "actions": {"release": {"args": {}}}
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.message.includes?("no script is defined").should be_true
    end

    it "rejects declared actions when the script is empty" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {"code": {"type": "string"}},
        "actions": {"release": {"args": {}}},
        "script": ""
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any?(&.message.includes?("no script is defined")).should be_true
    end

    it "accepts an empty script when no actions are declared" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {"code": {"type": "string"}},
        "script": ""
      })
      defn = DoctypeDefinition.from_json(json)
      Validation.validate(defn).should be_empty
    end

    # ── Computed fields without a script (B-274) ────────────────────

    it "rejects a computed field when no script is defined" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {
          "code":    { "type": "string" },
          "progress": { "type": "data", "compute": "wo_progress" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.message.includes?("no script is defined").should be_true
      errors.first.message.includes?("computed fields").should be_true
    end

    it "rejects a computed field when the script is empty" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {
          "code":    { "type": "string" },
          "progress": { "type": "data", "compute": "wo_progress" }
        },
        "script": ""
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("computed fields are declared but no script is defined") }.should be_true
    end

    it "accepts a doctype without computed fields and without a script" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {"code": {"type": "string"}}
      })
      defn = DoctypeDefinition.from_json(json)
      Validation.validate(defn).should be_empty
    end

    # ── Field tag validation ─────────────────────────────────────

    it "rejects an empty tag string in a field's tags" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "salary": { "type": "money", "tags": ["confidential", ""] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any?(&.message.includes?("empty tags entry")).should be_true
    end

    it "accepts free-form tags and passes a definition without tags" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ code }}",
        "fields": {
          "salary": { "type": "money", "tags": ["pii", "confidential"] },
          "code":   { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      Validation.validate(defn).should be_empty
    end

    # ── Field name validation ────────────────────────────────────────

    it "rejects empty field name" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("empty") || e.message.includes?("not a valid identifier") }.should be_true
    end

    it "rejects field name with spaces" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "my field": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "my field" }.should be_true
    end

    it "rejects field name starting with uppercase" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "Code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "Code" }.should be_true
    end

    it "rejects field name starting with a digit" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "1st_field": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "1st_field" }.should be_true
    end

    it "accepts lower_case_with_underscores field names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ my_field_name }}",
        "fields": {
          "my_field_name": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts camelCase field names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ myFieldName }}",
        "fields": {
          "myFieldName": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Reserved actions ────────────────────────────────────────────

    it "rejects reserved action 'validate'" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        actions: {"validate" => ActionDefinition.new}
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("validate") }.should be_true
    end

    it "rejects reserved action 'create'" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        actions: {"create" => ActionDefinition.new}
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("create") }.should be_true
    end

    it "rejects reserved action 'update'" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        actions: {"update" => ActionDefinition.new}
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("update") }.should be_true
    end

    # ── schema_version ──────────────────────────────────────────────

    it "rejects schema_version < 1" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "production", schema_version: 0)
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("schema_version") && e.message.includes?("0") }.should be_true
    end

    # ── domain name ───────────────────────────────────────────────

    it "accepts a domain with dashes" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "hr-ops")
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("domain") }.should be_false
    end

    it "rejects a domain containing underscores" do
      # Underscores are reserved for other identifier kinds (role slugs,
      # field names). Live domain names use dashes only.
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "hr_ops")
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("domain") && e.message.includes?("hr_ops") }.should be_true
    end

    it "rejects a domain starting with a digit" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "2orders")
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("domain") && e.message.includes?("2orders") }.should be_true
    end

    it "validates a draft domain name with an underscore prefix and dashes" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "_0001abcd-ef")
      errors = Validation.validate_draft(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("domain") }.should be_false
    end

    it "rejects a draft domain name whose body contains underscores" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "_0001abcd_ef")
      errors = Validation.validate_draft(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("domain") && e.message.includes?("_0001abcd_ef") }.should be_true
    end

    # ── member_of ───────────────────────────────────────────────────

    it "rejects member_of with wrong format (lowercase start)" do
      defn = DoctypeDefinition.new(doctype: "Operation", domain: "production", member_of: "workOrder")
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("member_of") && e.message.includes?("workOrder") }.should be_true
    end

    it "rejects empty member_of" do
      defn = DoctypeDefinition.new(doctype: "Operation", domain: "production", member_of: "")
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("member_of") }.should be_true
    end

    it "accepts valid camelCase member_of" do
      defn = DoctypeDefinition.new(doctype: "Operation", domain: "production", member_of: "WorkOrder")
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── aggregate_root / member_of exclusivity ──────────────────────

    it "rejects aggregate_root: true together with member_of" do
      defn = DoctypeDefinition.new(
        doctype: "Operation", domain: "production",
        aggregate_root: true, member_of: "WorkOrder",
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("either an aggregate root or a member") }.should be_true
    end

    # ── Multiple errors ─────────────────────────────────────────────

    it "returns multiple errors for multiple issues" do
      field = FieldDefinition.new
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 0,
        fields: {"" => field},
        actions: {
          "validate" => ActionDefinition.new,
          "release"  => ActionDefinition.new,
        }
      )
      errors = Validation.validate(defn)
      errors.size.should be >= 2
    end

    # ── Array field validation ──────────────────────────────────────

    it "rejects array field without items" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "tags": { "type": "array" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "tags" && e.message.includes?("items") }.should be_true
    end

    it "accepts array field with items" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ tags }}",
        "fields": {
          "tags": { "type": "array", "items": { "type": "string" } }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Object field with properties ────────────────────────────────

    it "accepts object field with properties" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ address }}",
        "fields": {
          "address": { "type": "object", "properties": { "street": { "type": "string" } } }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Dictionary field validation ─────────────────────────────────

    it "rejects dictionary field without values" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "metadata": { "type": "dictionary" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "metadata" && e.message.includes?("values") }.should be_true
    end

    it "accepts dictionary field with values" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ metadata }}",
        "fields": {
          "metadata": { "type": "dictionary", "values": { "type": "string" } }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── read_only / write_only conflict ─────────────────────────────

    it "rejects a field that is both read_only and write_only" do
      field = FieldDefinition.new(read_only: true, write_only: true)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {"name" => field}
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "name" && e.message.includes?("read_only") && e.message.includes?("write_only") }.should be_true
    end

    it "accepts exclusive read_only" do
      field = FieldDefinition.new(read_only: true, write_only: false)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        search: "{{ display_name }}",
        fields: {"name" => field}
      )
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts exclusive write_only" do
      field = FieldDefinition.new(read_only: false, write_only: true)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        search: "{{ display_name }}",
        fields: {"name" => field}
      )
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts neither read_only nor write_only" do
      field = FieldDefinition.new(read_only: false, write_only: false)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        search: "{{ display_name }}",
        fields: {"name" => field}
      )
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Replicate field schema validation ────────────────────────

    it "accepts a valid replicate configuration" do
      rep_config = ReplicateConfig.new(via: "person", field: "full_name")
      person_field = FieldDefinition.new(type: FieldType.parse("reference"), doctype: "identity.Person")
      name_field = FieldDefinition.new(type: FieldType.parse("string"), replicate: rep_config)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        search: "{{ person_name }}",
        fields: {
          "person"      => person_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects on_source_delete with invalid value" do
      rep_config = ReplicateConfig.new(via: "person", field: "full_name")
      person_field = FieldDefinition.new(type: FieldType.parse("reference"), doctype: "identity.Person")
      name_field = FieldDefinition.new(
        type: FieldType.parse("string"),
        replicate: rep_config,
        on_source_delete: "delete"
      )
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "person"      => person_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("on_source_delete") }.should be_true
    end

    # B-45: `on_source_delete` is read only from the field that carries the
    # `replicate` config. Declaring it on a plain reference field stored the
    # value and silently ignored it — the author believed the source-delete
    # policy was armed and it never fired.
    it "rejects on_source_delete on a field without a replicate config (B-45)" do
      person_field = FieldDefinition.new(
        type: FieldType.parse("reference"),
        doctype: "identity.Person",
        on_source_delete: "unset"
      )
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {"person" => person_field}
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person" && e.message.includes?("on_source_delete") }.should be_true
    end

    it "rejects a field that is both computed and replicated" do
      rep_config = ReplicateConfig.new(via: "person", field: "full_name")
      person_field = FieldDefinition.new(type: FieldType.parse("reference"), doctype: "identity.Person")
      name_field = FieldDefinition.new(
        type: FieldType.parse("data"),
        compute: "some_func",
        replicate: rep_config
      )
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "person"      => person_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("computed") && e.message.includes?("replicated") }.should be_true
    end

    it "rejects a replicated field that is required" do
      rep_config = ReplicateConfig.new(via: "person", field: "full_name")
      person_field = FieldDefinition.new(type: FieldType.parse("reference"), doctype: "identity.Person")
      name_field = FieldDefinition.new(
        type: FieldType.parse("string"),
        required: true,
        replicate: rep_config
      )
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "person"      => person_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("required") }.should be_true
    end

    it "rejects a replicated field that is unique" do
      rep_config = ReplicateConfig.new(via: "person", field: "full_name")
      person_field = FieldDefinition.new(type: FieldType.parse("reference"), doctype: "identity.Person")
      name_field = FieldDefinition.new(
        type: FieldType.parse("string"),
        unique: true,
        replicate: rep_config
      )
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "person"      => person_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("unique") }.should be_true
    end

    it "rejects when via field does not exist on the doctype" do
      rep_config = ReplicateConfig.new(via: "nonexistent", field: "full_name")
      name_field = FieldDefinition.new(type: FieldType.parse("string"), replicate: rep_config)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("via") && e.message.includes?("nonexistent") }.should be_true
    end

    it "rejects when via field is not a reference" do
      rep_config = ReplicateConfig.new(via: "title", field: "full_name")
      title_field = FieldDefinition.new(type: FieldType.parse("string"))
      name_field = FieldDefinition.new(type: FieldType.parse("string"), replicate: rep_config)
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        fields: {
          "title"       => title_field,
          "person_name" => name_field,
        }
      )
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "person_name" && e.message.includes?("must be a reference") }.should be_true
    end
  end

  # ── Filter-capability / field-type compatibility ────────────────────

  describe "filter capability / field-type compatibility" do
    it "rejects the interval capability on a string field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string", "filters": ["interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "name" && e.message.includes?("interval") }.should be_true
    end

    it "rejects the interval capability on an integer field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "age": { "type": "integer", "filters": ["interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "age" && e.message.includes?("interval") }.should be_true
    end

    it "rejects the interval capability on a date field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "hire_date": { "type": "date", "filters": ["interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "hire_date" && e.message.includes?("interval") }.should be_true
    end

    it "rejects the comparison capability on a period field (misleading semantics)" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "tenure": { "type": "period", "filters": ["comparison"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "tenure" && e.message.includes?("comparison") }.should be_true
    end

    it "accepts a fully valid period field with equality + interval" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ tenure }}",
        "fields": {
          "tenure": { "type": "period", "filters": ["equality", "interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts a valid date field with comparison" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ hire_date }}",
        "fields": {
          "hire_date": { "type": "date", "filters": ["comparison"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects the comparison capability on a dateperiod field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "calendar": { "type": "dateperiod", "filters": ["comparison", "interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "calendar" && e.message.includes?("comparison") }.should be_true
    end

    it "accepts a valid duration field with comparison" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ sla }}",
        "fields": {
          "sla": { "type": "duration", "filters": ["comparison"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects the interval capability on a duration field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "sla": { "type": "duration", "filters": ["interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "sla" && e.message.includes?("interval") && e.message.includes?("duration") }.should be_true
    end

    # ── Money capability compatibility ──────────────────────────────────
    #
    # `currency` is money-specific; `comparison` / `equality` operate on
    # the numeric value via `facet_money_value_as_numeric`. `interval` and
    # `membership` are rejected on money (no range or container semantics).

    it "accepts a money field with comparison + currency" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ price }}",
        "fields": {
          "price": { "type": "money", "filters": ["comparison", "currency"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts a money field with the currency capability alone" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ price }}",
        "fields": {
          "price": { "type": "money", "filters": ["currency"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects the currency capability on a string field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string", "filters": ["currency"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "name" && e.message.includes?("currency") }.should be_true
    end

    it "rejects the currency capability on an integer field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "age": { "type": "integer", "filters": ["currency"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "age" && e.message.includes?("currency") }.should be_true
    end

    it "rejects the currency capability on a period field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "tenure": { "type": "period", "filters": ["currency"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "tenure" && e.message.includes?("currency") }.should be_true
    end

    it "rejects the interval capability on a money field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "price": { "type": "money", "filters": ["interval"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "price" && e.message.includes?("interval") }.should be_true
    end

    # ── Array / dictionary membership ───────────────────────────────────
    #
    # `membership` is the array-containment capability. It is accepted on
    # `array` and rejected on `dictionary` (dictionaries are out of scope
    # for this iteration).

    it "accepts the membership capability on an array field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ tags }}",
        "fields": {
          "tags": { "type": "array", "items": { "type": "string" }, "filters": ["membership"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects the membership capability on a dictionary field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "props": { "type": "dictionary", "values": { "type": "string" }, "filters": ["membership"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "props" && e.message.includes?("membership") }.should be_true
    end

    it "rejects the membership capability on a scalar field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string", "filters": ["membership"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "name" && e.message.includes?("membership") }.should be_true
    end
  end

  # ── search ────────────────────────────────────────────────────────

  describe "search validation" do
    it "accepts the reserved display_name variable alongside a real field" do
      # The write path binds the document's display label for the reserved
      # variable, so a search template may reference it without the field
      # existing (B-115).
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ display_name }} {{ code }}",
        "fields": {
          "code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects an unknown root variable that is not the reserved one" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ display_name }} {{ unknown }}",
        "fields": {
          "code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("search") && e.message.includes?("unknown") }.should be_true
    end
  end

  # ── display_name ────────────────────────────────────────────────────

  describe "display_name validation" do
    it "accepts a template with existing root field variables" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ code }} - {{ status }}",
        "fields": {
          "code":   { "type": "string" },
          "status": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts a template with nested paths whose root segment is a field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ address.city }}",
        "fields": {
          "address": { "type": "object" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "accepts a reference-field variable without resolving the target" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ owner_id }}",
        "fields": {
          "owner_id": { "type": "reference", "doctype": "iam.Account" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects a variable whose root field does not exist" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ code }} - {{ unknown }}",
        "fields": {
          "code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("display_name") && e.message.includes?("unknown") }.should be_true
    end

    it "rejects a self-reference to the display_name column" do
      # The self-reference would read the value the same write is
      # computing — the validator rejects it at authoring time.
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ display_name }} {{ code }}",
        "fields": {
          "code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message == "display_name template must not reference the display_name column" }.should be_true
    end

    # ── sidecar flag ────────────────────────────────────────────────

    it "rejects sidecar with no target field" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "body": { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.code == "schema" && e.message.includes?("field named 'target'") }.should be_true
    end

    it "rejects sidecar whose target field is not a reference" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "target": { "type": "string", "required": true, "read_only": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("'target' field of a sidecar doctype must be of type 'reference'") }.should be_true
    end

    it "rejects sidecar with a nullable target field" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "read_only": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("'target' field of a sidecar doctype must be required") }.should be_true
    end

    it "rejects sidecar whose target field has a default" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true, "default": "abc" },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("'target' field of a sidecar doctype must not have a default") }.should be_true
    end

    it "rejects sidecar whose target field is not read_only" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("'target' field of a sidecar doctype must be read_only") }.should be_true
    end

    it "accepts a sidecar with a target reference plus a non-target author reference" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "search": "{{ body }}",
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "author": { "type": "reference", "doctype": "iam.Account", "read_only": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects sidecar in a non-core domain" do
      json = %({
        "doctype": "Comment",
        "domain": "crm",
        "sidecar": true,
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("sidecar doctypes must live in the 'core' domain") }.should be_true
    end

    it "accepts a valid sidecar in core with a single required read_only target reference" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "search": "{{ body }}",
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "rejects a sidecar segment colliding with a children key" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "children": {
          "notes": { "doctype": "Note" }
        },
        "sidecars": {
          "notes": { "doctype": "core.Note" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("sidecar segment 'notes' collides") }.should be_true
    end

    it "rejects a sidecar segment containing uppercase" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": {
          "Comments": { "doctype": "core.Comment" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("sidecar segment 'Comments' is not a valid identifier") }.should be_true
    end

    it "accepts a sidecar entry whose column is omitted (defaults to target)" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "search": "{{ name }}",
        "fields": { "name": { "type": "string" } },
        "sidecars": {
          "comments": { "doctype": "core.Comment" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    # ── Compute keys on non-data fields (B-274) ──────────────────────

    it "rejects compute on a field that is not a data field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "price": { "type": "money", "compute": "price" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "price" && e.message.includes?("'compute' applies only to a data field") }.should be_true
    end

    it "rejects compute_when without compute on a field that is not a data field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name":  { "type": "string" },
          "price": { "type": "money", "compute_when": ["name"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "price" && e.message.includes?("'compute_when' applies only to a data field") }.should be_true
    end

    it "accepts compute and compute_when on a data field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "{{ name }}",
        "fields": {
          "name":  { "type": "string" },
          "total": { "type": "data", "compute": "total", "compute_when": ["name"] }
        },
        "script": "local export = {}\\nfunction export.compute_total(ctx) return 0 end\\nreturn export"
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.should be_empty
    end

    it "keeps the secret-specific message for compute on a secret field" do
      # A `secret` field cannot ride a search template (the corpus would
      # stage the plaintext), so this aggregate root declares neither
      # template: the run carries the secret compute error plus the B-296
      # gate error.
      json = %({
        "doctype": "Vault",
        "domain": "secretpage",
        "aggregate_root": true,
        "fields": {
          "cred": { "type": "secret", "mode": "hash", "compute": "return 1" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.size.should eq(2)
      secret_error = errors.find! { |e| e.field == "cred" }
      secret_error.message.should eq("secret field cannot declare compute/compute_when")
      errors.any?(&.message.includes?("neither a display_name nor a search template")).should be_true
    end
  end

  # ── sidecar surface field ─────────────────────────────────────────

  describe "surface validation" do
    it "accepts a valid lowercase surface on a sidecar doctype" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "surface": "comment",
        "search": "{{ body }}",
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext", "required": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      Validation.validate(defn).should be_empty
    end

    it "rejects a surface that is not a lowercase identifier" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "surface": "Comment Thread",
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext", "required": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("surface 'Comment Thread' is not a valid lowercase identifier") }.should be_true
    end

    it "rejects a surface on a doctype that is not a sidecar" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "surface": "comment"
      })
      defn = DoctypeDefinition.from_json(json)
      errors = Validation.validate(defn)
      errors.any? { |e| e.message.includes?("surface is only meaningful on a sidecar doctype") }.should be_true
    end
  end

  # ── reference target qualification (F02-01) ──────────────────────

  describe "reference target qualification" do
    it "rejects a bare reference target" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"brand": {"type": "reference", "doctype": "Brand"}})))
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      err = errors.first
      err.field.should eq("brand")
      err.code.should eq("schema")
      err.message.should contain("bare reference target 'Brand'")
      err.message.should contain("qualified '{domain}.{Doctype}'")
      err.message.should contain("identity.Person")
    end

    it "accepts a qualified reference target" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"brand": {"type": "reference", "doctype": "shop.Brand"}})))
      Validation.validate(defn).should be_empty
    end

    it "accepts a polymorphic reference (no doctype declared)" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"target": {"type": "reference", "dangling": true}})))
      Validation.validate(defn).should be_empty
    end

    it "rejects a bare target nested in array items" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"payrolls": {"type": "array", "items": {"type": "reference", "doctype": "Payroll"}}})))
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.field.should eq("payrolls.items")
      errors.first.message.should contain("bare reference target 'Payroll'")
    end

    it "rejects a bare target nested in object properties" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"meta": {"type": "object", "properties": {"owner": {"type": "reference", "doctype": "Owner"}}}})))
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.field.should eq("meta.owner")
    end

    it "rejects a bare target nested in dictionary values" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"ext": {"type": "dictionary", "values": {"type": "reference", "doctype": "Extra"}}})))
      errors = Validation.validate(defn)
      errors.size.should eq(1)
      errors.first.field.should eq("ext.values")
    end

    it "rejects an implicit reference (doctype without type) with a bare target" do
      defn = DoctypeDefinition.from_json(ref_target_defn_json(%({"brand": {"doctype": "Brand"}})))
      errors = Validation.validate(defn)
      errors.any? { |e| e.field == "brand" && e.message.includes?("bare reference target 'Brand'") }.should be_true
    end
  end
end
