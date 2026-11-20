# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "json"

# ─────────────────────────────────────────────────────────────────────────────
# `CollectionView::TitleTemplate.validate` — authoring-time validation of the
# calendar `title_template` on a `core.CollectionView` against the parent
# doctype's definition.
#
# Covers:
#   - nil / blank templates pass (the view falls back to the display name)
#   - a template that compiles with declared-field roots passes
#   - the reserved `content` root and the system timestamps pass
#   - Jinja syntax errors are reported with the `template` code
#   - unknown roots are reported against the parent doctype
#   - the `display_name` root is rejected with its own message
# ─────────────────────────────────────────────────────────────────────────────

private def build_definition(fields : Hash(String, String)) : Facet::Doctype::DoctypeDefinition
  fields_json = {} of String => JSON::Any
  fields.each do |k, type|
    fields_json[k] = JSON.parse(%({"type":"#{type}"}))
  end
  raw = JSON::Any.new({
    "doctype"        => JSON::Any.new("Deal"),
    "domain"         => JSON::Any.new("crm"),
    "fields"         => JSON::Any.new(fields_json),
    "aggregate_root" => JSON::Any.new(true),
    "schema_version" => JSON::Any.new(1),
  }.transform_values &.as(JSON::Any))
  Facet::Doctype::DoctypeDefinition.from_json(raw.to_json)
end

private def validate(template : String?, fields : Hash(String, String) = {"name" => "string", "amount" => "money"}) : Array(Facet::ValidationError)
  Facet::Doctype::CollectionView::TitleTemplate.validate(template, build_definition(fields))
end

describe "Facet::Doctype::CollectionView::TitleTemplate" do
  it "passes a nil template" do
    validate(nil).should be_empty
  end

  it "passes a blank template" do
    validate("   ").should be_empty
  end

  it "passes a template whose roots are declared fields" do
    validate("{{ name }} — {{ amount }}").should be_empty
  end

  it "passes dotted paths over declared object fields" do
    validate("{{ address.city }}", {"address" => "object"}).should be_empty
  end

  it "passes the reserved content root" do
    validate("{{ content.name }}").should be_empty
  end

  it "passes the system timestamp roots" do
    validate("{{ created_at }} {{ updated_at }}").should be_empty
  end

  it "rejects a template with a syntax error" do
    errors = validate("{% if name %}")
    errors.size.should eq(1)
    errors[0].field.should eq("config.calendar.title_template")
    errors[0].code.should eq("template")
  end

  it "rejects an unknown root" do
    errors = validate("{{ ghost }}")
    errors.size.should eq(1)
    errors[0].field.should eq("config.calendar.title_template")
    errors[0].code.should eq("template")
    errors[0].message.should contain("ghost")
  end

  it "rejects the display_name root with its own message" do
    errors = validate("{{ display_name }}")
    errors.size.should eq(1)
    errors[0].code.should eq("template")
    errors[0].message.should contain("display_name")
    errors[0].message.should contain("falls back")
  end

  it "rejects every unknown root of a multi-root template" do
    errors = validate("{{ name }} {{ ghost }} {{ phantom }}")
    errors.map(&.message).join(" ").should contain("ghost")
    errors.map(&.message).join(" ").should contain("phantom")
    errors.map(&.message).join(" ").should_not contain("name")
  end
end
