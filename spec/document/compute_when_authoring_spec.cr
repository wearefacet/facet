# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"

# Authoring validation for a computed field's `compute_when` list (B-110
# part 2). Each entry must name a field of the doctype (a value trigger) or
# a key of `children` (a relationship trigger — the field re-runs when that
# relationship's children mutate). Anything else can never fire, so it
# fails at authoring time instead of silently never running.
#
# The same gate rejects `compute` / `compute_when` on a field whose type is
# not `data` (B-274): the compute pass evaluates `data` fields only, so any
# other field type would store the keys and never evaluate them.
describe "Doctype::Validation compute_when authoring" do
  it "accepts an entry that names a field of the doctype" do
    definition = build_definition(
      %({"name": {"type": "string"}, "total": {"type": "data", "compute": "t", "compute_when": ["name"]}}),
    )
    errors = Facet::Doctype::Validation.validate(definition)
    errors.should be_empty
  end

  it "accepts an entry that names a child relationship" do
    definition = build_definition(
      %({"total": {"type": "data", "compute": "t", "compute_when": ["lines"]}}),
      %({"lines": {"doctype": "CwtLine", "collection": true}}),
    )
    errors = Facet::Doctype::Validation.validate(definition)
    errors.should be_empty
  end

  it "accepts a mixed list of a field name and a relationship name" do
    definition = build_definition(
      %({"name": {"type": "string"}, "summary": {"type": "data", "compute": "s", "compute_when": ["name", "lines"]}}),
      %({"lines": {"doctype": "CwtLine", "collection": true}}),
    )
    errors = Facet::Doctype::Validation.validate(definition)
    errors.should be_empty
  end

  it "rejects an entry that names neither a field nor a relationship" do
    definition = build_definition(
      %({"total": {"type": "data", "compute": "t", "compute_when": ["nmae"]}}),
    )
    errors = Facet::Doctype::Validation.validate(definition)
    errors.should_not be_empty
    errors.any?(&.message.includes?("nmae")).should be_true
  end

  it "rejects the entry through the doctype create path with a 422" do
    with_db do |db|
      ensure_domain(db, "doc-test")
      defn = %({
        "doctype": "Cwt#{unique_suffix[0..5]}",
        "domain": "doc-test",
        "aggregate_root": true,
        "fields": {"total": {"type": "data", "compute": "t", "compute_when": ["lines"]}},
        "script": "local export = {}\\nfunction export.compute_t(ctx) return 0 end\\nreturn export"
      })
      result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq 422
      err.details.not_nil!.any? { |e| e.message.includes?("compute_when trigger 'lines'") }.should be_true
    end
  end

  it "rejects compute on a non-data field through the doctype create path with a 422 (B-274)" do
    with_db do |db|
      ensure_domain(db, "doc-test")
      defn = %({
        "doctype": "Cwt#{unique_suffix[0..5]}",
        "domain": "doc-test",
        "aggregate_root": true,
        "fields": {"price": {"type": "money", "compute": "price"}}
      })
      result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq 422
      err.details.not_nil!.any? { |e| e.message.includes?("'compute' applies only to a data field") }.should be_true
    end
  end
end

private def build_definition(fields_json : String, children_json : String? = nil) : Facet::Doctype::DoctypeDefinition
  children = children_json ? %(, "children": #{children_json}) : ""
  # The script gate (B-274) rejects a definition that declares computed
  # fields with no script, so the fixture ships the functions the compute
  # names ('t', 's') resolve to.
  raw = %({
    "doctype": "CwtDoc",
    "domain": "doc-test",
    "aggregate_root": true,
    "search": "{{ display_name }}",
    "fields": #{fields_json}#{children},
    "script": "local export = {}\\nfunction export.compute_t(ctx) return nil end\\nfunction export.compute_s(ctx) return nil end\\nreturn export"
  })
  Facet::Doctype::DoctypeDefinition.from_json(raw)
end
