# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# No default `core.CollectionView`: registering a doctype creates **zero**
# collection views, and the boot seed never creates or resurrects one.
#
# A new doctype starts viewless; the frontend listing renders a starter
# screen that offers to create a view, and `Doctype::Check` reports an
# `:info` notice for the viewless state. Views are always user-authored:
# created from the starter, via REST, or by an agent.
#
# Covers:
#   - `Doctype::Create.call` creates no CollectionView child
#   - `Doctype::Seed.seed` creates no views for viewless doctypes
#   - a user-created view survives a re-seed
#   - deleting the last view stays deleted across a re-seed
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

private def fetch_views(doctype_id : String) : Array(JSON::Any)
  with_db do |db|
    db.query_all(
      "SELECT content FROM projections
       WHERE domain = 'core' AND doc_type = 'CollectionView'
         AND meta->>'parent_id' = $1 AND deleted_at IS NULL",
      doctype_id,
      as: JSON::Any,
    )
  end
end

describe "No default CollectionView seed" do
  it "creates no CollectionView child alongside the doctype" do
    doctype_id = create_simple_doctype("WidgetA", {"title" => "string", "notes" => "longtext"})
    fetch_views(doctype_id).should be_empty
  end

  it "creates no views for viewless doctypes on re-seed" do
    doctype_id = create_simple_doctype("WidgetB", {"name" => "string"})

    with_db do |db|
      Facet::Doctype::Seed.seed(db)
    end

    fetch_views(doctype_id).should be_empty
  end

  it "keeps a user-created view across a re-seed" do
    doctype_id = create_simple_doctype("WidgetC", {"name" => "string"})

    with_db do |db|
      Facet::Mutation::Client.create(
        db, "core", "CollectionView",
        content: %({"name": "Mine", "surface": "table", "config": {"columns": [{"key": "name"}]}}),
        meta: %({"parent_id": #{doctype_id.to_json}}),
        actioner_id: "system",
      )
      Facet::Doctype::Seed.seed(db)
    end

    views = fetch_views(doctype_id)
    views.size.should eq(1)
    views.first["name"].as_s.should eq("Mine")
  end

  it "never resurrects the last deleted view" do
    doctype_id = create_simple_doctype("WidgetD", {"name" => "string"})

    with_db do |db|
      Facet::Mutation::Client.create(
        db, "core", "CollectionView",
        content: %({"name": "Doomed", "surface": "table", "config": {"columns": [{"key": "name"}]}}),
        meta: %({"parent_id": #{doctype_id.to_json}}),
        actioner_id: "system",
      )
    end

    with_db do |db|
      # Simulate the user deleting the only view, then a reboot re-seed.
      db.exec(
        "UPDATE projections SET deleted_at = now()
         WHERE domain = 'core' AND doc_type = 'CollectionView'
           AND meta->>'parent_id' = $1",
        doctype_id,
      )
      Facet::Doctype::Seed.seed(db)
    end

    fetch_views(doctype_id).should be_empty
  end
end
