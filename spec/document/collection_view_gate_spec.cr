# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# Write-path gate for the `core.CollectionView` `config` field
# (`Document::CollectionViewGate`):
#
#   - kanban `mode` outside `{values, custom}` → 422 `config.kanban.mode`
#   - kanban values mode without a `group_by` → 422 `config.kanban.group_by`
#   - kanban values mode with a group_by that cannot serve `eq` → 422
#   - kanban custom mode without lanes → 422 `config.kanban.lanes`
#   - calendar with a discriminator that is not a date field → 422
#   - calendar with a discriminator that serves `gte` + `lte` → saved
#   - table with an unknown column key → 422
#   - grid: columns, Σ aggregates, editability, frozen bounds, filters, sort
#   - update touching `config` validates the submitted config
#
# The view is created as a child of a real `core.DocType` row, so the gate
# resolves the parent definition the same way the API does.
# ─────────────────────────────────────────────────────────────────────────────

private def cv_gate_doctype_raw(name : String, fields : Hash(String, JSON::Any)) : JSON::Any
  fields_json = {} of String => JSON::Any
  fields.each { |k, v| fields_json[k] = v }
  JSON::Any.new({
    "doctype"        => JSON::Any.new(name),
    "domain"         => JSON::Any.new("core"),
    "fields"         => JSON::Any.new(fields_json),
    "aggregate_root" => JSON::Any.new(true),
    "search"         => JSON::Any.new("{{ display_name }}"),
    "schema_version" => JSON::Any.new(1),
  }.transform_values &.as(JSON::Any))
end

# A field descriptor with the given type and optional filter capabilities.
private def cv_gate_field(type : String, filters : Array(String)? = nil) : JSON::Any
  raw = {"type" => JSON::Any.new(type)} of String => JSON::Any
  raw["filters"] = JSON::Any.new(filters.map { |f| JSON::Any.new(f) }) if filters
  JSON::Any.new(raw)
end

private def cv_gate_parent_doctype(name : String, fields : Hash(String, JSON::Any)) : String
  with_db do |db|
    restore_seeded_baseline(db)
    defn = Facet::Doctype::DoctypeDefinition.from_json(cv_gate_doctype_raw(name, fields).to_json)
    result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    case result
    when Facet::Document::Create::Result
      result.projection.id
    else
      raise "Doctype creation failed: #{result}"
    end
  end
end

private def cv_gate_create(parent_id : String, surface : String, config : JSON::Any)
  body = JSON::Any.new({
    "name"    => JSON::Any.new("View"),
    "surface" => JSON::Any.new(surface),
    "config"  => config,
  }.transform_values &.as(JSON::Any)).to_json
  with_db do |db|
    Facet::Document::Create.call(
      db, "core", "CollectionView", body,
      Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    )
  end
end

private def cv_gate_created_id(result : Facet::Document::Create::Result | Facet::ServiceError) : String
  case result
  when Facet::Document::Create::Result
    result.projection.id
  else
    fail "expected the create to succeed: #{result}"
  end
end

private def cv_gate_update(doc_id : String, patch : String)
  with_db do |db|
    Facet::Document::Update.call(db, "core", "CollectionView", doc_id, patch, Facet::RBAC::AuthContext.system)
  end
end

private def cv_gate_expect_422(result, field : String) : Facet::ServiceError
  case result
  when Facet::ServiceError
    result.status.should eq(422)
    details = result.details.not_nil!
    details.any? { |e| e.field == field }.should be_true
    result
  else
    fail "expected the write to be rejected (field #{field})"
  end
end

describe "CollectionView config write gate" do
  # `status` is an enum serving `equality` (the group-by case); `score` is a
  # string with `comparison` (the calendar bad-discriminator case); `due` is
  # a datetime with `comparison` (a valid calendar discriminator); `flag` is
  # a boolean with `equality` (the second group-by type).
  cv_fields = {
    "name"   => cv_gate_field("string", ["equality", "text_search"]),
    "status" => cv_gate_field("enum", ["equality"]),
    "score"  => cv_gate_field("string", ["comparison"]),
    "due"    => cv_gate_field("datetime", ["comparison"]),
    "flag"   => cv_gate_field("boolean", ["equality"]),
  }

  # The grid-rule fields: everything above plus a money field (the
  # aggregate-able case), a read-only string (the non-writable column), and
  # an object (the unsortable sort key).
  cv_grid_fields = begin
    fields = cv_fields.dup
    fields["amount"] = JSON.parse(%({"type": "money", "currency": "USD"}))
    fields["locked"] = JSON.parse(%({"type": "string", "read_only": true}))
    fields["blob"] = JSON.parse(%({"type": "object"}))
    fields
  end

  it "rejects a kanban mode outside values/custom" do
    parent_id = cv_gate_parent_doctype("CvGateKanbanMode", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "bogus"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "kanban", config), "config.kanban.mode")
  end

  it "rejects kanban values mode without a group_by" do
    parent_id = cv_gate_parent_doctype("CvGateKanbanGroup", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "values"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "kanban", config), "config.kanban.group_by")
  end

  it "rejects kanban values mode with a group_by that cannot serve eq" do
    parent_id = cv_gate_parent_doctype("CvGateKanbanCap", cv_fields)
    # `score` is a string: not an enum or boolean, so it never becomes a lane.
    config = JSON.parse(%({"kanban": {"mode": "values", "group_by": "score"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "kanban", config), "config.kanban.group_by")
  end

  it "rejects kanban custom mode without lanes" do
    parent_id = cv_gate_parent_doctype("CvGateKanbanLanes", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "custom", "lanes": []}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "kanban", config), "config.kanban.lanes")
  end

  it "saves a valid kanban values view" do
    parent_id = cv_gate_parent_doctype("CvGateKanbanOk", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "values", "group_by": "status"}}))
    cv_gate_created_id(cv_gate_create(parent_id, "kanban", config)).should_not be_empty
  end

  it "rejects a calendar discriminator that is not a date field" do
    parent_id = cv_gate_parent_doctype("CvGateCalBad", cv_fields)
    config = JSON.parse(%({"calendar": {"discriminator": "score"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "calendar", config), "config.calendar.discriminator")
  end

  it "rejects a calendar discriminator without the window operators" do
    fields = cv_fields.dup
    # A date field with no capability serves neither `gte` nor `lte`.
    fields["started"] = cv_gate_field("date")
    parent_id = cv_gate_parent_doctype("CvGateCalCap", fields)
    config = JSON.parse(%({"calendar": {"discriminator": "started"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "calendar", config), "config.calendar.discriminator")
  end

  it "saves a valid calendar view" do
    parent_id = cv_gate_parent_doctype("CvGateCalOk", cv_fields)
    config = JSON.parse(%({"calendar": {"discriminator": "due"}}))
    cv_gate_created_id(cv_gate_create(parent_id, "calendar", config)).should_not be_empty
  end

  it "rejects a table column key absent from the parent doctype" do
    parent_id = cv_gate_parent_doctype("CvGateTableBad", cv_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}, {"key": "ghost"}]}))
    cv_gate_expect_422(cv_gate_create(parent_id, "table", config), "config.columns.1.key")
  end

  it "rejects a table view with no columns" do
    parent_id = cv_gate_parent_doctype("CvGateTableEmpty", cv_fields)
    config = JSON.parse(%({"columns": []}))
    cv_gate_expect_422(cv_gate_create(parent_id, "table", config), "config.columns")
  end

  it "accepts system timestamp columns" do
    parent_id = cv_gate_parent_doctype("CvGateTableTs", cv_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}, {"key": "created_at"}]}))
    cv_gate_created_id(cv_gate_create(parent_id, "table", config)).should_not be_empty
  end

  it "validates the submitted config on an update" do
    parent_id = cv_gate_parent_doctype("CvGateUpdate", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "values", "group_by": "status"}}))
    doc_id = cv_gate_created_id(cv_gate_create(parent_id, "kanban", config))

    result = cv_gate_update(doc_id, %({"config": {"kanban": {"mode": "bogus"}}}))
    cv_gate_expect_422(result, "config.kanban.mode")
  end

  it "replaces the stored config on write instead of merging it" do
    parent_id = cv_gate_parent_doctype("CvGateReplace", cv_fields)
    config = JSON.parse(%({"kanban": {"mode": "values", "group_by": "status", "page_size": 50}}))
    doc_id = cv_gate_created_id(cv_gate_create(parent_id, "kanban", config))

    result = cv_gate_update(doc_id, %({"config": {"kanban": {"mode": "values", "group_by": "flag"}}}))
    case result
    when Facet::Document::Update::Result
      kanban = result.projection.content["config"]["kanban"]
      kanban["group_by"].as_s.should eq("flag")
      # The stale `page_size` from the previous version is gone, not merged.
      kanban["page_size"]?.should be_nil
    else
      fail "expected the update to succeed: #{result}"
    end
  end

  it "saves a valid grid view" do
    parent_id = cv_gate_parent_doctype("CvGateGridOk", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}, {"key": "amount", "summary": "sum"}, {"key": "created_at"}], "grid": {"frozen": 1, "sort": ["-amount"], "filters": {"name__match": "acme", "search": "deal"}}}))
    cv_gate_created_id(cv_gate_create(parent_id, "grid", config)).should_not be_empty
  end

  it "rejects a grid column key absent from the parent doctype" do
    parent_id = cv_gate_parent_doctype("CvGateGridCol", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}, {"key": "ghost"}]}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.columns.1.key")
  end

  it "rejects a grid view with no columns" do
    parent_id = cv_gate_parent_doctype("CvGateGridEmpty", cv_grid_fields)
    config = JSON.parse(%({"columns": []}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.columns")
  end

  it "rejects an unknown summary aggregate" do
    parent_id = cv_gate_parent_doctype("CvGateGridSum", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "amount", "summary": "median"}]}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.columns.0.summary")
  end

  it "rejects a field aggregate on a non-numeric field" do
    parent_id = cv_gate_parent_doctype("CvGateGridSumType", cv_grid_fields)
    # `name` is a string — the read-time aggregate would answer 422.
    config = JSON.parse(%({"columns": [{"key": "name", "summary": "sum"}]}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.columns.0.summary")
  end

  it "rejects editable true on a non-writable field" do
    parent_id = cv_gate_parent_doctype("CvGateGridEdit", cv_grid_fields)
    # `locked` is read_only in the schema; `created_at` never edits.
    config = JSON.parse(%({"columns": [{"key": "locked", "editable": true}, {"key": "created_at", "editable": true}]}))
    result = cv_gate_create(parent_id, "grid", config)
    err = cv_gate_expect_422(result, "config.columns.0.editable")
    err.details.not_nil!.any? { |e| e.field == "config.columns.1.editable" }.should be_true
  end

  it "accepts editable true on a writable field" do
    parent_id = cv_gate_parent_doctype("CvGateGridEditOk", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name", "editable": true}]}))
    cv_gate_created_id(cv_gate_create(parent_id, "grid", config)).should_not be_empty
  end

  it "rejects a grid.frozen outside 0..columns.length" do
    parent_id = cv_gate_parent_doctype("CvGateGridFrozen", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"frozen": 2}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.grid.frozen")
  end

  it "rejects a non-integer grid.frozen" do
    parent_id = cv_gate_parent_doctype("CvGateGridFrozenType", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"frozen": "1"}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.grid.frozen")
  end

  it "rejects a grid filter that names an unknown field" do
    parent_id = cv_gate_parent_doctype("CvGateGridFilter", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"filters": {"ghost__eq": "x"}}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.grid.filters.ghost__eq")
  end

  it "rejects a grid filter whose operator the field does not serve" do
    parent_id = cv_gate_parent_doctype("CvGateGridFilterOp", cv_grid_fields)
    # `name` serves equality and text_search — not the comparison family.
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"filters": {"name__gte": 1, "created_at__match": "x"}}}))
    result = cv_gate_create(parent_id, "grid", config)
    err = cv_gate_expect_422(result, "config.grid.filters.name__gte")
    err.details.not_nil!.any? { |e| e.field == "config.grid.filters.created_at__match" }.should be_true
  end

  it "rejects a suffixed search filter but accepts the bare key" do
    parent_id = cv_gate_parent_doctype("CvGateGridSearch", cv_grid_fields)
    bad = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"filters": {"search__eq": "x"}}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", bad), "config.grid.filters.search__eq")

    good = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"filters": {"search": "deal"}}}))
    cv_gate_created_id(cv_gate_create(parent_id, "grid", good)).should_not be_empty
  end

  it "rejects an unknown grid sort field" do
    parent_id = cv_gate_parent_doctype("CvGateGridSort", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"sort": ["-ghost"]}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.grid.sort.0")
  end

  it "rejects an unsortable grid sort field" do
    parent_id = cv_gate_parent_doctype("CvGateGridSortType", cv_grid_fields)
    # `blob` is an object — no sort expression exists for it.
    config = JSON.parse(%({"columns": [{"key": "name"}], "grid": {"sort": ["blob"]}}))
    cv_gate_expect_422(cv_gate_create(parent_id, "grid", config), "config.grid.sort.0")
  end

  it "validates a submitted grid config on an update" do
    parent_id = cv_gate_parent_doctype("CvGateGridUpdate", cv_grid_fields)
    config = JSON.parse(%({"columns": [{"key": "name"}]}))
    doc_id = cv_gate_created_id(cv_gate_create(parent_id, "grid", config))

    result = cv_gate_update(doc_id, %({"surface": "grid", "config": {"columns": [{"key": "name"}], "grid": {"frozen": 9}}}))
    cv_gate_expect_422(result, "config.grid.frozen")
  end
end
