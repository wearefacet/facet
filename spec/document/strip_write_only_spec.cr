# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/document/strip_write_only"

describe Facet::Document::StripWriteOnly do
  it "strips write_only fields from the document" do
    document = JSON.parse(%({"title": "Hello", "password": "secret123"}))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {
        "title"    => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string")),
        "password" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"), write_only: true),
      },
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result["title"].as_s.should eq("Hello")
    result["password"]?.should be_nil
  end

  it "passes through documents with no write_only fields" do
    document = JSON.parse(%({"title": "Hello", "body": "World"}))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {
        "title" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string")),
        "body"  => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string")),
      },
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result["title"].as_s.should eq("Hello")
    result["body"].as_s.should eq("World")
  end

  it "returns the original document unchanged when there are no write_only fields even if input has extras" do
    document = JSON.parse(%({"title": "Hello", "extra": "value"}))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {
        "title" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string")),
      },
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result["extra"].as_s.should eq("value")
  end

  it "strips multiple write_only fields" do
    document = JSON.parse(%({"title": "Hello", "password": "secret", "token": "abc123"}))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {
        "title"    => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string")),
        "password" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"), write_only: true),
        "token"    => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"), write_only: true),
      },
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result["password"]?.should be_nil
    result["token"]?.should be_nil
    result["title"].as_s.should eq("Hello")
  end

  it "handles empty document" do
    document = JSON.parse(%({}))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {"title" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"))},
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result.as_h.size.should eq(0)
  end

  it "handles non-hash document (primitives pass through)" do
    document = JSON.parse(%("just a string"))
    definition = Facet::Doctype::DoctypeDefinition.new(
      doctype: "TestDoc",
      domain: "test",
      fields: {"password" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("string"), write_only: true)},
    )

    result = Facet::Document::StripWriteOnly.call(document, definition)
    result.as_s.should eq("just a string")
  end
end
