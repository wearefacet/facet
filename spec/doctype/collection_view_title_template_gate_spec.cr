# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/document"
require "../../src/rbac"
require "../../src/mutation/client"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# Write-path gate for the calendar `title_template` on `core.CollectionView`:
#
#   - create with a template referencing an unknown field → 422 `template`
#   - create with a syntactically broken template → 422 `template`
#   - create with a valid template → saved
#   - update touching `config` with a now-invalid template → 422
#   - update that only renames the view keeps working on a stale template
#
# The view is created as a child of a real `core.DocType` row, so the gate
# resolves the parent definition the same way the API does.
# ─────────────────────────────────────────────────────────────────────────────

private def build_doctype_raw(name : String, fields : Hash(String, String)) : JSON::Any
  fields_json = {} of String => JSON::Any
  fields.each do |k, type|
    fields_json[k] = JSON.parse(%({"type":"#{type}"}))
  end
  JSON::Any.new({
    "doctype"        => JSON::Any.new(name),
    "domain"         => JSON::Any.new("core"),
    "fields"         => JSON::Any.new(fields_json),
    "aggregate_root" => JSON::Any.new(true),
    "search"         => JSON::Any.new("{{ display_name }}"),
    "schema_version" => JSON::Any.new(1),
  }.transform_values &.as(JSON::Any))
end

# Creates the parent `core.DocType` and returns its projection id (the same
# id a `collection_view` child carries as `parent_id`).
private def create_parent_doctype(name : String, fields : Hash(String, String)) : String
  with_db do |db|
    restore_seeded_baseline(db)
    defn = Facet::Doctype::DoctypeDefinition.from_json(build_doctype_raw(name, fields).to_json)
    result = Facet::Document::Create.call(db, "core", "DocType", defn.to_json, Facet::RBAC::AuthContext.system)
    case result
    when Facet::Document::Create::Result
      result.projection.id
    else
      raise "Doctype creation failed: #{result}"
    end
  end
end

private def view_content(name : String, title_template : String) : String
  {
    "name"    => name,
    "surface" => "calendar",
    "config"  => {
      "calendar" => {
        "discriminator"  => "due",
        "title_template" => title_template,
        "week_start"     => "monday",
      },
    },
  }.to_json
end

private def create_view(parent_id : String, name : String, title_template : String)
  with_db do |db|
    Facet::Document::Create.call(
      db, "core", "CollectionView", view_content(name, title_template),
      Facet::RBAC::AuthContext.system,
      meta_overrides: {"parent_id" => JSON::Any.new(parent_id)},
    )
  end
end

private def update_view(doc_id : String, patch : String)
  with_db do |db|
    Facet::Document::Update.call(db, "core", "CollectionView", doc_id, patch, Facet::RBAC::AuthContext.system)
  end
end

# A create result or an explicit test failure.
private def created_id(result : Facet::Document::Create::Result | Facet::ServiceError) : String
  case result
  when Facet::Document::Create::Result
    result.projection.id
  else
    fail "expected the create to succeed: #{result}"
  end
end

describe "CollectionView title template write gate" do
  it "rejects a create whose template references an unknown field" do
    parent_id = create_parent_doctype("GateDealA", {"name" => "string", "due" => "date"})
    result = create_view(parent_id, "Broken", "{{ ghost }}")
    case result
    when Facet::ServiceError
      result.status.should eq(422)
      result.details.not_nil!.first.code.should eq("template")
    else
      fail "expected the create to be rejected"
    end
  end

  it "rejects a create whose template has a syntax error" do
    parent_id = create_parent_doctype("GateDealB", {"name" => "string", "due" => "date"})
    result = create_view(parent_id, "Broken syntax", "{% if name %}")
    case result
    when Facet::ServiceError
      result.status.should eq(422)
      result.details.not_nil!.first.code.should eq("template")
    else
      fail "expected the create to be rejected"
    end
  end

  it "saves a create with a valid template" do
    parent_id = create_parent_doctype("GateDealC", {"name" => "string", "due" => "date"})
    result = create_view(parent_id, "Timeline", "{{ name }}")
    created_id(result).should_not be_empty
  end

  it "rejects a config-touching update whose template references an unknown field" do
    parent_id = create_parent_doctype("GateDealD", {"name" => "string", "due" => "date"})
    doc_id = created_id(create_view(parent_id, "ConfigEdit", "{{ name }}"))

    result = update_view(doc_id, %({"config": {"calendar": {"title_template": "{{ ghost }}"}}}))
    case result
    when Facet::ServiceError
      result.status.should eq(422)
      result.details.not_nil!.first.code.should eq("template")
    else
      fail "expected the update to be rejected"
    end
  end

  it "lets a rename-only patch through on a stale template" do
    parent_id = create_parent_doctype("GateDealE", {"name" => "string", "due" => "date"})
    doc_id = created_id(create_view(parent_id, "RenameOnly", "{{ name }}"))

    # Simulate the stranded state a parent-doctype field removal produces:
    # the stored template now references a field the definition no longer
    # declares. Rewriting the stored content directly stands in for that
    # removal — doctype rows are immutable in the fixtures.
    with_db do |db|
      db.exec(
        "UPDATE projections SET content = jsonb_set(content, '{config,calendar,title_template}', to_jsonb('{{ removed_field }}'::text)) WHERE id = $1",
        doc_id,
      )
    end

    result = update_view(doc_id, %({"name": "Renamed"}))
    case result
    when Facet::Document::Update::Result
      # The rename passed.
    else
      fail "expected the rename-only patch to succeed: #{result}"
    end
  end
end
