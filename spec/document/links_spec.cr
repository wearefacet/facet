# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../spec_helper"
require "../../src/document/links"
require "../../src/doctype/doctype_definition"

# Test doctypes are constructed directly via `DoctypeDefinition.new` — no DB
# access needed. Each test builds a definition matching the document content
# shape, then asserts `Links.extract_from_content` returns the expected URN
# array.
# A minimal definition with one longtext field — the subject of the
# longtext extraction cases below.
private def longtext_defn
  Facet::Doctype::DoctypeDefinition.new(
    domain: "notes",
    doctype: "Note",
    fields: {
      "body" => Facet::Doctype::FieldDefinition.new(type: Facet::Doctype::FieldType.parse("longtext")),
    },
  )
end

describe Facet::Document::Links do
  ref_type = Facet::Doctype::FieldType.parse("reference")
  longtext_type = Facet::Doctype::FieldType.parse("longtext")
  array_type = Facet::Doctype::FieldType.parse("array")
  object_type = Facet::Doctype::FieldType.parse("object")
  dict_type = Facet::Doctype::FieldType.parse("dictionary")
  string_type = Facet::Doctype::FieldType.parse("string")

  describe ".extract_from_content with reference fields" do
    it "extracts a single reference value as a canonical URN" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "production",
        doctype: "WorkOrder",
        fields: {
          "assignee" => Facet::Doctype::FieldDefinition.new(
            type: ref_type, doctype: "hr.Employee",
          ),
        },
      )
      content = JSON.parse(%({"assignee": "hr.Employee.01J5X2ABC"}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01J5X2ABC"])
    end

    it "canonicalizes a bare ULID reference using the field's doctype" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "production",
        doctype: "WorkOrder",
        fields: {
          "assignee" => Facet::Doctype::FieldDefinition.new(
            type: ref_type, doctype: "hr.Employee",
          ),
        },
      )
      # `Document::Normalize` runs before `Links` in the create/update flow,
      # qualifying the stored value. `Links` therefore receives the qualified
      # form and extracts the opaque id via `DocURI.from_projection_id`.
      content = JSON.parse(%({"assignee": "hr.Employee.01J5X2ABC"}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01J5X2ABC"])
    end

    it "extracts a collection reference as multiple URNs" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "production",
        doctype: "WorkOrder",
        fields: {
          "assignees" => Facet::Doctype::FieldDefinition.new(
            type: ref_type, doctype: "hr.Employee", collection: true,
          ),
        },
      )
      content = JSON.parse(%({"assignees": ["hr.Employee.01AAA", "hr.Employee.01BBB"]}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA", "urn:facet:hr:Employee:01BBB"])
    end

    it "skips a null reference value" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "production",
        doctype: "WorkOrder",
        fields: {
          "assignee" => Facet::Doctype::FieldDefinition.new(
            type: ref_type, doctype: "hr.Employee",
          ),
        },
      )
      content = JSON.parse(%({"assignee": null}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should be_empty
    end
  end

  describe ".extract_from_content with longtext fields" do
    it "extracts URNs from markdown inline links" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "notes",
        doctype: "Note",
        fields: {
          "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
        },
      )
      content = JSON.parse(%({"body": "See [Alice](urn:facet:hr:Employee:01AAA) and [Bob](urn:facet:hr:Employee:01BBB)."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA", "urn:facet:hr:Employee:01BBB"])
    end

    it "ignores non-URN URLs in markdown links" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "notes",
        doctype: "Note",
        fields: {
          "body" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
        },
      )
      content = JSON.parse(%({"body": "See [docs](https://example.com/page) and [Alice](urn:facet:hr:Employee:01AAA)."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA"])
    end

    it "handles longtext with no links" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "Just plain prose, no links here."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should be_empty
    end

    it "still extracts the dotted inline URL form" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "See [Alice](hr.Employee.01BBB)."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "extracts a bare URN mention in prose" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "Reach out to urn:facet:hr:Employee:01BBB for the details."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "trims a trailing sentence period from a bare URN" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "See urn:facet:hr:Employee:01BBB."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "extracts an autolink" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "See <urn:facet:hr:Employee:01BBB> for details."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "extracts a reference-style link definition" do
      defn = longtext_defn
      body = "See [Alice] later.\n\n[Alice]: urn:facet:hr:Employee:01BBB"
      content = JSON.parse({body: body}.to_json)

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "extracts the URN when the link label contains a `]`" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "[Unit [A]](urn:facet:hr:Employee:01BBB)"}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "extracts the URN from a link with a title" do
      defn = longtext_defn
      body = "[Alice](urn:facet:hr:Employee:01BBB \"team lead\")"
      content = JSON.parse({body: body}.to_json)

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB"])
    end

    it "preserves a state-pinned bare URN as a distinct reference" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "History: urn:facet:hr:Employee:01BBB?state=01ABCDEV0000000000000000"}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01BBB?state=01ABCDEV0000000000000000"])
    end

    it "ignores a truncated URN token" do
      defn = longtext_defn
      content = JSON.parse(%({"body": "The prefix urn:facet: alone is not a reference."}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should be_empty
    end
  end

  describe ".extract_from_content with nested schemas" do
    it "recurses into object properties for reference fields" do
      # address is an object with a `region_manager` reference field.
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "sales",
        doctype: "Account",
        fields: {
          "address" => Facet::Doctype::FieldDefinition.new(
            type: object_type,
            properties: {
              "city"           => Facet::Doctype::FieldDefinition.new(type: string_type),
              "region_manager" => Facet::Doctype::FieldDefinition.new(
                type: ref_type, doctype: "hr.Employee",
              ),
            },
          ),
        },
      )
      content = JSON.parse(%({"address": {"city": "Lyon", "region_manager": "hr.Employee.01AAA"}}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA"])
    end

    it "recurses into array of objects" do
      # reviews is an array of objects, each with an `author` reference.
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "sales",
        doctype: "Account",
        fields: {
          "reviews" => Facet::Doctype::FieldDefinition.new(
            type: array_type,
            items: Facet::Doctype::FieldDefinition.new(
              type: object_type,
              properties: {
                "author" => Facet::Doctype::FieldDefinition.new(
                  type: ref_type, doctype: "hr.Employee",
                ),
              },
            ),
          ),
        },
      )
      content = JSON.parse(%({"reviews": [{"author": "hr.Employee.01AAA"}, {"author": "hr.Employee.01BBB"}]}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA", "urn:facet:hr:Employee:01BBB"])
    end

    it "recurses into dictionary typed values" do
      # reviewers is a dictionary mapping string keys to Employee references.
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "sales",
        doctype: "Account",
        fields: {
          "reviewers" => Facet::Doctype::FieldDefinition.new(
            type: dict_type,
            dictionary_value: Facet::Doctype::FieldDefinition.new(
              type: ref_type, doctype: "hr.Employee",
            ),
          ),
        },
      )
      content = JSON.parse(%({"reviewers": {"primary": "hr.Employee.01AAA", "backup": "hr.Employee.01BBB"}}))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA", "urn:facet:hr:Employee:01BBB"])
    end
  end

  describe ".extract_from_content deduplication" do
    it "deduplicates URNs from reference and longtext sources" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        domain: "production",
        doctype: "WorkOrder",
        fields: {
          "assignee" => Facet::Doctype::FieldDefinition.new(
            type: ref_type, doctype: "hr.Employee",
          ),
          "notes" => Facet::Doctype::FieldDefinition.new(type: longtext_type),
        },
      )
      content = JSON.parse(%({
        "assignee": "hr.Employee.01AAA",
        "notes": "Reached out to [Alice](urn:facet:hr:Employee:01AAA)."
      }))

      urns = Facet::Document::Links.extract_from_content(content, defn)
      urns.should eq(["urn:facet:hr:Employee:01AAA"])
    end
  end

  describe ".to_guc_value" do
    it "serializes the URN array as JSON" do
      urns = ["urn:facet:hr:Employee:01AAA", "urn:facet:hr:Employee:01BBB"]
      Facet::Document::Links.to_guc_value(urns).should eq(%(["urn:facet:hr:Employee:01AAA","urn:facet:hr:Employee:01BBB"]))
    end

    it "serializes an empty array as []" do
      Facet::Document::Links.to_guc_value([] of String).should eq("[]")
    end
  end
end
