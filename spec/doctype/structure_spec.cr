# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"

# Helper: build a `DoctypeDefinition` from a JSON string. The doctype /
# domain / schema_version are structurally irrelevant to `Structure.equal?`
# (only fields, children, actions are compared), so defaults are fine.
def structure_defn(json : String) : Facet::Doctype::DoctypeDefinition
  Facet::Doctype::DoctypeDefinition.from_json(json)
end

module Facet::Doctype
  describe Structure do
    # ── Non-structural edits: equal ────────────────────────────────────

    it "treats an operators change as non-structural" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "filters": ["comparison"]}}}))
      Structure.equal?(live, draft).should be_true
    end

    it "treats title / description / default / tags / compute edits as non-structural" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({
        "doctype": "T", "domain": "d", "schema_version": 1,
        "fields": {"name": {"type": "string", "title": "Name", "description": "n", "default": "x", "tags": ["a"], "compute": "fn"}}
      }))
      Structure.equal?(live, draft).should be_true
    end

    it "treats enum label / color edits as non-structural (keys unchanged)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a", "label": "A", "color": "#111"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a", "label": "Alpha", "color": "#222"}]}}}))
      Structure.equal?(live, draft).should be_true
    end

    it "treats a reordered field set as identical" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"b": {"type": "integer"}, "a": {"type": "string"}}}))
      Structure.equal?(live, draft).should be_true
    end

    # ── Structural edits: different ────────────────────────────────────

    it "flags a type change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "integer"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a required change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "required": true}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a unique change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "unique": true}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a min / max change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"age": {"type": "integer", "min": 0, "max": 100}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"age": {"type": "integer", "min": 0, "max": 200}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a pattern change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"code": {"type": "string", "pattern": "^[a-z]+$"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"code": {"type": "string", "pattern": "^[A-Z]+$"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a pattern_flags change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"code": {"type": "string", "pattern": "x", "pattern_flags": "i"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"code": {"type": "string", "pattern": "x", "pattern_flags": "m"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags an enum key change (renaming a key)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "b"}]}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags an enum key count change (adding a value)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a reference doctype target change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Contractor"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags an owned change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "owned": false}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "owned": true}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a collection change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "collection": false}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "collection": true}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a replicate config change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "replicate": {"via": "ref_id", "field": "full_name"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "replicate": {"via": "ref_id", "field": "last_name"}}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags an on_source_delete change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "replicate": {"via": "ref_id", "field": "full_name"}, "on_source_delete": "keep"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "replicate": {"via": "ref_id", "field": "full_name"}, "on_source_delete": "unset"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a reference filter change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "filter": {"status_eq": "active"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "filter": {"status_eq": "inactive"}}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags an added field" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "flags a removed field" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      Structure.equal?(live, draft).should be_false
    end

    # ── Recursive (nested sub-schemas) ─────────────────────────────────

    it "recurses into array `items` — non-structural edit is equal" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array", "items": {"type": "string"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array", "items": {"type": "string", "title": "Tag"}}}}))
      Structure.equal?(live, draft).should be_true
    end

    it "recurses into array `items` — structural edit is different" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array", "items": {"type": "string"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array", "items": {"type": "integer"}}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "recurses into object `properties` — non-structural edit is equal" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string", "title": "City"}}}}}))
      Structure.equal?(live, draft).should be_true
    end

    it "recurses into object `properties` — structural edit is different" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string", "required": true}}}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "recurses into dictionary `values` — structural edit is different" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"meta": {"type": "dictionary", "values": {"type": "string"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"meta": {"type": "dictionary", "values": {"type": "integer"}}}}))
      Structure.equal?(live, draft).should be_false
    end

    # ── children / actions ────────────────────────────────────────────

    it "flags a children doctype change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Activity"}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "treats identical children / actions as equal regardless of field presentation noise" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}, "actions": {"go": {}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string", "filters": ["equality"]}}, "actions": {"go": {}}}))
      Structure.equal?(live, draft).should be_true
    end

    # ── Data-shape diff API: additive changes ──────────────────────────

    it "reports a field addition as an additive change" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer", "required": true}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.size.should eq(1)
      changes[0].kind.should eq(:field)
      changes[0].label.should eq("field 'b' added")
      changes[0].additive.should be_true
      Structure.data_shape_changes?(live, draft).should be_false
      Structure.data_shape_equal?(live, draft).should be_true
    end

    it "treats a nested property addition as additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}, "zip": {"type": "string", "required": true}}}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'addr' property 'zip' added"])
      changes.all?(&.additive).should be_true
    end

    it "treats a new property map on a previously free-form object as additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}}}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'addr' property 'city' added"])
      changes.all?(&.additive).should be_true
    end

    it "treats a pure enum key addition as additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'status' enum keys added"])
      changes.all?(&.additive).should be_true
    end

    it "treats a new children entry as additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event"}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["children: entry 'events' added"])
      changes.map(&.kind).should eq([:children])
      changes.all?(&.additive).should be_true
    end

    it "reports no data-shape changes when fields are reordered" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"b": {"type": "integer"}, "a": {"type": "string"}}}))
      Structure.data_shape_changes(live, draft).should be_empty
    end

    # ── Data-shape diff API: non-additive changes ──────────────────────

    it "reports a field removal as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "integer"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'b' removed"])
      changes.map(&.additive).should eq([false])
      Structure.data_shape_changes?(live, draft).should be_true
    end

    it "reports a type change with the source and target type names" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"x": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"x": {"type": "integer"}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["field 'x' type string → integer"])
    end

    it "reports required / unique / collection flips as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"x": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"x": {"type": "string", "required": true, "unique": true, "collection": true}}}))
      labels = Structure.data_shape_changes(live, draft).map(&.label)
      labels.should contain("field 'x' required false → true")
      labels.should contain("field 'x' unique false → true")
      labels.should contain("field 'x' collection false → true")
    end

    it "reports a min/max/pattern change with the combined label" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"age": {"type": "integer", "min": 0, "max": 100}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"age": {"type": "integer", "min": 0, "max": 200}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["field 'age' min/max/pattern changed"])
    end

    it "reports an enum key removal as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}]}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'status' enum keys changed"])
      changes.map(&.additive).should eq([false])
    end

    it "reports an enum key reorder as non-additive (not a pure addition)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "a"}, {"key": "b"}]}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"status": {"type": "enum", "values": [{"key": "b"}, {"key": "a"}]}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'status' enum keys changed"])
      changes.map(&.additive).should eq([false])
    end

    it "reports a reference target change with its own label" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Contractor"}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["field 'ref' reference target hr.Employee → hr.Contractor"])
    end

    it "reports owned / on_source_delete / replicate / filter edits with the combined label" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "owned": true, "on_source_delete": "keep", "replicate": {"via": "ref_id", "field": "full_name"}, "filter": {"status_eq": "active"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"ref": {"type": "reference", "doctype": "hr.Employee", "owned": false, "on_source_delete": "unset", "replicate": {"via": "ref_id", "field": "last_name"}, "filter": {"status_eq": "inactive"}}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.size.should eq(1)
      changes[0].label.should eq("field 'ref' owned / on_source_delete / replicate / filter changed")
      changes[0].additive.should be_false
    end

    it "reports a nested property removal and type change with the nested path" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "string"}, "zip": {"type": "string"}}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"addr": {"type": "object", "properties": {"city": {"type": "integer"}}}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["field 'addr' property 'city' type string → integer", "field 'addr' property 'zip' removed"])
      changes.all? { |c| !c.additive }.should be_true
    end

    it "reports array items appearing as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"tags": {"type": "array", "items": {"type": "integer"}}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["field 'tags' items changed"])
    end

    it "reports a dictionary value type change with the nested path" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"meta": {"type": "dictionary", "values": {"type": "string"}}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"meta": {"type": "dictionary", "values": {"type": "integer"}}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["field 'meta' dictionary value type string → integer"])
    end

    it "reports a children entry removal and retarget as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event"}, "logs": {"doctype": "Log"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Activity"}}}))
      changes = Structure.data_shape_changes(live, draft)
      changes.map(&.label).should eq(["children: entry 'events' changed", "children: entry 'logs' removed"])
      changes.map(&.kind).should eq([:children, :children])
      changes.all? { |c| !c.additive }.should be_true
    end

    it "reports a children collection flip as non-additive" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event", "collection": false}}}))
      Structure.data_shape_changes(live, draft).map(&.label).should eq(["children: entry 'events' changed"])
    end

    it "reports a member_of change in both directions as non-additive" do
      plain = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}}))
      member = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "member_of": "Company"}))
      Structure.data_shape_changes(plain, member).map(&.label).should eq(["member_of: none → Company"])
      Structure.data_shape_changes(member, plain).map(&.label).should eq(["member_of: Company → none"])
      Structure.data_shape_changes?(plain, member).should be_true
    end

    # ── Data-shape diff API: ignored edits ─────────────────────────────

    it "ignores a children description edit (presentation)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "children": {"events": {"doctype": "Event", "description": "Career events"}}}))
      Structure.data_shape_changes(live, draft).should be_empty
      Structure.equal?(live, draft).should be_true
    end

    it "ignores search paths and the display_name template (derived surface)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"name": {"type": "string"}}, "search": "{{ name }}", "display_name": "{{ name }}"}))
      Structure.data_shape_changes(live, draft).should be_empty
      Structure.data_shape_equal?(live, draft).should be_true
    end

    # ── Recomposed publish equality ────────────────────────────────────

    it "equal? is false when only an additive field addition exists (publish bumps on any data-shape edit)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}, "b": {"type": "string"}}}))
      Structure.data_shape_equal?(live, draft).should be_true
      Structure.equal?(live, draft).should be_false
    end

    it "equal? is false on a member_of change (now part of the publish gate)" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {}, "member_of": "Company"}))
      Structure.equal?(live, draft).should be_false
    end

    it "equal? is false when only actions changed" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}, "actions": {"go": {}}}))
      Structure.equal?(live, draft).should be_false
    end

    it "equal? is true when fields, children structure, member_of, and actions are identical" do
      live = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string"}}, "children": {"events": {"doctype": "Event"}}, "member_of": "Company", "actions": {"go": {}}}))
      draft = structure_defn(%({"doctype": "T", "domain": "d", "schema_version": 1, "fields": {"a": {"type": "string", "title": "A"}}, "children": {"events": {"doctype": "Event", "description": "d"}}, "member_of": "Company", "actions": {"go": {}}}))
      Structure.equal?(live, draft).should be_true
    end
  end
end
