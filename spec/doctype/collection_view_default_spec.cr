# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# Seeded default `core.CollectionView` ("All Records"): every doctype
# registered via `Doctype::Create.call` (and every pre-existing doctype at
# `Doctype::Seed.seed` boot time) gets one general, pinnable default view
# whose columns come from the doctype's first eight scalar fields
# (excluding `longtext` and non-scalar types).
#
# Covers:
#   - `CollectionView::Defaults.columns_for` / `build_content` (the rule)
#   - `Doctype::Create` seeds the view atomically with the doctype
#   - `Doctype::Seed.seed` is idempotent across re-runs
#   - `longtext`, `object`, `array`, `child`, `data` fields are excluded
#   - already-managed doctypes (a view already exists) are not re-seeded
# ─────────────────────────────────────────────────────────────────────────────

private def build_simple_doctype(name : String, fields : Hash(String, String)) : Facet::Doctype::DoctypeDefinition
  fields_json = {} of String => JSON::Any
  fields.each do |k, type|
    fields_json[k] = JSON.parse(%({"type":"#{type}"}))
  end
  raw = JSON::Any.new({
    "doctype"        => JSON::Any.new(name),
    "domain"         => JSON::Any.new("core"),
    "fields"         => JSON::Any.new(fields_json),
    "aggregate_root" => JSON::Any.new(true),
    "search"         => JSON::Any.new("{{ display_name }}"),
    "schema_version" => JSON::Any.new(1),
  }.transform_values &.as(JSON::Any))
  Facet::Doctype::DoctypeDefinition.from_json(raw.to_json)
end

private def create_simple_doctype(name : String, fields : Hash(String, String)) : String
  with_db do |db|
    restore_seeded_baseline(db)
    defn = build_simple_doctype(name, fields)
    result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    case result
    when Facet::Document::Create::Result
      result.projection.id
    else
      raise "Doctype creation failed: #{result}"
    end
  end
end

private def fetch_default_view(doctype_id : String) : JSON::Any?
  with_db do |db|
    rows = db.query_all(
      "SELECT content FROM projections
       WHERE domain = 'core' AND doc_type = 'CollectionView'
         AND meta->>'parent_id' = $1 AND deleted_at IS NULL
         AND content->>'name' = 'All Records'",
      doctype_id,
      as: JSON::Any,
    )
    rows.first?
  end
end

describe "Default CollectionView seed" do
  describe "CollectionView::Defaults" do
    it "excludes longtext from the default columns" do
      defn = build_simple_doctype("Widget", {
        "title"  => "string",
        "notes"  => "longtext",
        "status" => "enum",
        "body"   => "longtext",
      })
      cols = Facet::Doctype::CollectionView::Defaults.columns_for(defn)
      keys = cols.map(&.key)
      keys.should contain("title")
      keys.should contain("status")
      keys.should_not contain("notes")
      keys.should_not contain("body")
    end

    it "excludes object, array, dictionary, child, data, file, any fields" do
      defn = build_simple_doctype("KitchenSink", {
        "name"    => "string",
        "payload" => "object",
        "tags"    => "array",
        "audit"   => "data",
        "wild"    => "any",
        "active"  => "boolean",
      })
      cols = Facet::Doctype::CollectionView::Defaults.columns_for(defn)
      keys = cols.map(&.key)
      keys.should eq(["name", "active"])
    end

    it "keeps reference and other scalar primitives in declaration order" do
      defn = build_simple_doctype("RefExample", {
        "owner"     => "reference",
        "price"     => "money",
        "count"     => "integer",
        "color"     => "color",
        "due_date"  => "date",
        "closed_at" => "datetime",
      })
      cols = Facet::Doctype::CollectionView::Defaults.columns_for(defn)
      cols.map(&.key).should eq(%w[owner price count color due_date closed_at])
    end

    it "caps the column list at eight" do
      fields = (1..12).map { |i| {"f#{i}", "string"} }.to_h
      defn = build_simple_doctype("ManyFields", fields)
      cols = Facet::Doctype::CollectionView::Defaults.columns_for(defn)
      cols.size.should eq(8)
    end

    it "marks boolean columns editable and read_only booleans not" do
      fields_json = {
        "name"   => JSON.parse(%({"type":"string"})),
        "active" => JSON.parse(%({"type":"boolean"})),
        "locked" => JSON.parse(%({"type":"boolean","read_only":true})),
      } of String => JSON::Any
      raw = JSON::Any.new({
        "doctype"        => JSON::Any.new("EditableBools"),
        "domain"         => JSON::Any.new("core"),
        "fields"         => JSON::Any.new(fields_json),
        "aggregate_root" => JSON::Any.new(true),
        "schema_version" => JSON::Any.new(1),
      }.transform_values &.as(JSON::Any))
      defn = Facet::Doctype::DoctypeDefinition.from_json(raw.to_json)
      cols = Facet::Doctype::CollectionView::Defaults.columns_for(defn)
      cols.find! { |c| c.key == "active" }.editable.should be_true
      cols.find! { |c| c.key == "locked" }.editable.should be_false
      cols.find! { |c| c.key == "name" }.editable.should be_false
    end

    it "includes the field title when present" do
      fields_json = {
        "name" => JSON.parse(%({"type":"string","title":"Display Name"})),
      } of String => JSON::Any
      raw = JSON::Any.new({
        "doctype"        => JSON::Any.new("Titled"),
        "domain"         => JSON::Any.new("core"),
        "fields"         => JSON::Any.new(fields_json),
        "aggregate_root" => JSON::Any.new(true),
        "schema_version" => JSON::Any.new(1),
      }.transform_values &.as(JSON::Any))
      defn = Facet::Doctype::DoctypeDefinition.from_json(raw.to_json)
      content = Facet::Doctype::CollectionView::Defaults.build_content(defn)
      content["name"].as_s.should eq("All Records")
      content["surface"].as_s.should eq("table")
      cols = content["config"]["columns"].as_a
      cols.first["key"].as_s.should eq("name")
      cols.first["label"]?.try(&.as_s).should eq("Display Name")
      # Non-boolean columns never carry the editable flag.
      cols.first.as_h.has_key?("editable").should be_false
      # owner_id is absent so the view is general (shared).
      content.as_h.has_key?("owner_id").should be_false
    end

    it "emits editable: true on boolean columns only" do
      fields_json = {
        "name"   => JSON.parse(%({"type":"string"})),
        "active" => JSON.parse(%({"type":"boolean"})),
      } of String => JSON::Any
      raw = JSON::Any.new({
        "doctype"        => JSON::Any.new("BoolContent"),
        "domain"         => JSON::Any.new("core"),
        "fields"         => JSON::Any.new(fields_json),
        "aggregate_root" => JSON::Any.new(true),
        "schema_version" => JSON::Any.new(1),
      }.transform_values &.as(JSON::Any))
      defn = Facet::Doctype::DoctypeDefinition.from_json(raw.to_json)
      content = Facet::Doctype::CollectionView::Defaults.build_content(defn)
      cols = content["config"]["columns"].as_a
      active = cols.find! { |c| c["key"].as_s == "active" }
      active["editable"]?.try(&.as_bool).should be_true
      name_col = cols.find! { |c| c["key"].as_s == "name" }
      name_col.as_h.has_key?("editable").should be_false
    end
  end

  describe "Doctype::Create seeds the default view" do
    it "creates an 'All Records' general view alongside the doctype" do
      doctype_id = create_simple_doctype("WidgetA", {"title" => "string", "notes" => "longtext"})
      view = fetch_default_view(doctype_id)
      view.should_not be_nil
      view.not_nil!["name"].as_s.should eq("All Records")
      view.not_nil!["surface"].as_s.should eq("table")
      cols = view.not_nil!["config"]["columns"].as_a.map(&.["key"].as_s)
      cols.should contain("title")
      cols.should_not contain("notes")
    end

    it "does not seed twice on re-seed (idempotent)" do
      doctype_id = create_simple_doctype("WidgetB", {"name" => "string"})

      # Re-running the seed second-pass must not create a duplicate view.
      with_db do |db|
        Facet::Doctype::Seed.seed(db)
      end

      with_db do |db|
        count = db.query_one(
          "SELECT count(*)::int FROM projections
           WHERE domain = 'core' AND doc_type = 'CollectionView'
             AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
          doctype_id,
          as: Int32,
        )
        count.should eq(1)
      end
    end

    it "re-seeds when the previous default was deleted" do
      doctype_id = create_simple_doctype("WidgetC", {"name" => "string"})

      with_db do |db|
        # Delete every existing view to simulate the "user nuked all views"
        # recovery path. The seed second-pass must resurrect one.
        db.exec(
          "UPDATE projections SET deleted_at = now()
           WHERE domain = 'core' AND doc_type = 'CollectionView'
             AND meta->>'parent_id' = $1",
          doctype_id,
        )
        Facet::Doctype::Seed.seed(db)
      end

      view = fetch_default_view(doctype_id)
      view.should_not be_nil
    end
  end
end
