# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype/doctype_definition"
require "../../src/document/display_name"

# Stub resolver for unit tests: maps `qualified_target_doctype` + `doc_id` to
# a pre-registered display_name, or returns nil for unregistered pairs.
class StubResolver < Facet::Document::DisplayName::ReferenceResolver
  getter calls : Array({qualified: String, doc_id: String}) = [] of {qualified: String, doc_id: String}
  @lookup : Hash({String, String}, String?)

  def initialize(lookup : Hash({String, String}, String?))
    @lookup = lookup
  end

  def resolve(qualified_target_doctype : String, doc_id : String) : String?
    @calls << {qualified: qualified_target_doctype, doc_id: doc_id}
    @lookup[{qualified_target_doctype, doc_id}]?
  end
end

def build_definition(display_name : String? = nil, **fields)
  field_json = {} of String => JSON::Any
  fields.each do |name, type_or_obj|
    field_json[name.to_s] = type_or_obj.is_a?(JSON::Any) ? type_or_obj : JSON.parse(type_or_obj.as(String))
  end
  raw = JSON::Any.new({
    "doctype"      => JSON::Any.new("Widget"),
    "domain"       => JSON::Any.new("test"),
    "fields"       => JSON::Any.new(field_json),
    "display_name" => display_name ? JSON::Any.new(display_name) : JSON::Any.new(nil),
  }.transform_values &.as(JSON::Any))
  # `display_name` key shouldn't be nil — drop it when not provided.
  hash = raw.as_h
  hash.delete("display_name") if display_name.nil?
  raw = JSON::Any.new(hash)
  Facet::Doctype::DoctypeDefinition.from_json(raw)
end

describe Facet::Document::DisplayName do
  describe ".compute" do
    it "returns nil when no template is set" do
      defn = build_definition doctype: {"type" => "string"}.to_json
      resolver = StubResolver.new({} of {String, String} => String?)
      Facet::Document::DisplayName.compute(defn, JSON.parse(%({"doctype": "Widget"})), resolver).should be_nil
    end

    it "returns nil for an empty template" do
      defn = build_definition("", doctype: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      Facet::Document::DisplayName.compute(defn, JSON.parse(%({"doctype": "Widget"})), resolver).should be_nil
    end

    it "renders a plain top-level field variable" do
      defn = build_definition("{{ title }}", title: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"title": "Hello"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Hello")
    end

    it "renders a nested dot-path variable" do
      defn = build_definition("{{ address.city }}", address: {"type" => "object"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"address": {"city": "Paris"}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Paris")
    end

    it "renders a nested path through the reserved content variable" do
      defn = build_definition("{{ content.address.city }}", address: {"type" => "object"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"address": {"city": "Paris"}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Paris")
    end

    it "renders a missing field as empty" do
      defn = build_definition("{{ a }} - {{ b }}", a: {"type" => "string"}.to_json, b: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"a": "X"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("X - ")
    end

    it "renders a nested path over a missing parent field as empty" do
      defn = build_definition("{{ address.city }}", address: {"type" => "object"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "renders a nested path over a missing member as empty" do
      defn = build_definition("{{ address.city.zip }}", address: {"type" => "object"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"address": {"other": 1}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "applies Jinja filters" do
      defn = build_definition("{{ title | upper }}", title: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"title": "hello"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("HELLO")
    end

    it "supports control flow on an absent field" do
      defn = build_definition("{% if nick %}{{ nick }}{% else %}{{ name }}{% endif %}",
        name: {"type" => "string"}.to_json, nick: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"name": "Ada"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Ada")
    end

    # Crinja treats an empty string as truthy — a deviation from Jinja2's
    # Python truthiness. Templates that need the empty check must compare
    # explicitly (e.g. `{{ nick == '' }}`). This spec pins the behaviour.
    it "treats an empty string as truthy (Crinja deviation from Jinja2)" do
      defn = build_definition("{% if nick %}set{% else %}unset{% endif %}",
        nick: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"nick": ""}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("set")
    end

    it "stringifies numeric and boolean values" do
      defn = build_definition("{{ n }} - {{ b }}", n: {"type" => "integer"}.to_json, b: {"type" => "boolean"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"n": 42, "b": true}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("42 - true")
    end

    it "renders array values via the join filter" do
      defn = build_definition("{{ tags | join(', ') }}", tags: {"type" => "array"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"tags": ["alpha", "beta"]}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("alpha, beta")
    end

    it "resolves a reference variable to the target's stored display_name" do
      defn = build_definition("{{ company_id }}", company_id: %({"type": "reference", "doctype": "crm.Company"}))
      lookup = {} of {String, String} => String?
      lookup[{"crm.Company", "C1"}] = "Acme Inc."
      resolver = StubResolver.new(lookup)
      content = JSON.parse(%({"company_id": "C1"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Acme Inc.")
      resolver.calls.should eq([{qualified: "crm.Company", doc_id: "C1"}])
    end

    it "qualifies a same-domain reference with the source domain when resolving" do
      defn = build_definition("{{ company_id }}", company_id: %({"type": "reference", "doctype": "Company"}))
      # Source doctype lives in `test`; the bare `Company` must be qualified as `test.Company`.
      lookup = {} of {String, String} => String?
      lookup[{"test.Company", "C9"}] = "Local Inc."
      resolver = StubResolver.new(lookup)
      content = JSON.parse(%({"company_id": "C9"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Local Inc.")
      resolver.calls.should eq([{qualified: "test.Company", doc_id: "C9"}])
    end

    it "falls back to the target doctype's name when the reference is unresolved" do
      defn = build_definition("{{ company_id }}", company_id: %({"type": "reference", "doctype": "crm.Company"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"company_id": "MISSING"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Company")
    end

    it "falls back to the target doctype's name when the reference value is empty" do
      defn = build_definition("{{ company_id }}", company_id: %({"type": "reference", "doctype": "crm.Company"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Company")
      resolver.calls.should be_empty
    end

    it "resolves the first element of a collection reference" do
      defn = build_definition("{{ contact_ids }}",
        contact_ids: %({"type": "reference", "doctype": "crm.Contact", "collection": true}))
      lookup = {} of {String, String} => String?
      lookup[{"crm.Contact", "C1"}] = "Alice"
      lookup[{"crm.Contact", "C2"}] = "Bob"
      resolver = StubResolver.new(lookup)
      content = JSON.parse(%({"contact_ids": ["C1", "C2"]}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Alice")
    end

    # ── Money field formatting ──────────────────────────────────────────
    #
    # A money field renders as `"<currency> <value>"` — currency first,
    # then the decimal amount. The raw `{value,currency}` object is NOT
    # JSON-dumped into the display_name.

    it "formats a money field as '<currency> <value>'" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"price": #{money_json("120000", "USD")}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("USD 120000")
    end

    it "composes a money field with other variables in the template" do
      defn = build_definition("{{ title }} - {{ price }}",
        title: %({"type": "string"}),
        price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"title": "Big Deal", "price": #{money_json("45", "EUR")}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("Big Deal - EUR 45")
    end

    it "formats a nested money value by shape" do
      defn = build_definition("{{ deal.price }}", deal: %({"type": "object"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"deal": {"price": #{money_json("99.95", "GBP")}}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("GBP 99.95")
    end

    it "formats a money field with a zero amount" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"price": #{money_json("0", "JPY")}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("JPY 0")
    end

    it "renders empty for a money object whose value member is missing" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      # Reachable only via direct snapshot writes; the validator rejects
      # incomplete money objects at write time.
      content = JSON.parse(%({"price": {"currency": "USD"}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "renders empty for a money object whose currency member is missing" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"price": {"value": "100"}}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "renders empty when a money field stores a non-object value" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"price": "not-a-money"}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "renders empty when the money field is absent from the content" do
      defn = build_definition("{{ price }}", price: %({"type": "money"}))
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({}))
      Facet::Document::DisplayName.compute(defn, content, resolver).should eq("")
    end

    it "truncates to 255 characters with ellipsis" do
      defn = build_definition("{{ long }}", long: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      big = "x" * 300
      content = JSON.parse(%({"long": "#{big}"}))
      result = Facet::Document::DisplayName.compute(defn, content, resolver).not_nil!
      result.size.should eq(255)
      result.should end_with("...")
    end

    it "handles mixed template text and multiple variables" do
      field_json = {
        "title"      => JSON.parse(%({"type": "string"})),
        "company_id" => JSON.parse(%({"type": "reference", "doctype": "crm.Company"})),
        "amount"     => JSON.parse(%({"type": "integer"})),
      }
      hash = {
        "doctype"      => "Widget",
        "domain"       => "test",
        "fields"       => field_json,
        "display_name" => "{{ title }} - {{ company_id }} - {{ amount }}",
      }
      defn = Facet::Doctype::DoctypeDefinition.from_json(JSON.parse(hash.to_json))
      lookup = {} of {String, String} => String?
      lookup[{"crm.Company", "ACME"}] = "Acme"
      resolver = StubResolver.new(lookup)
      content = JSON.parse(%({"title": "Big Deal", "company_id": "ACME", "amount": 1500}))
      result = Facet::Document::DisplayName.compute(defn, content, resolver).not_nil!
      result.should eq("Big Deal - Acme - 1500")
    end

    it "raises Templating::Error when the template fails to render" do
      defn = build_definition("{{ title.foo() }}", title: {"type" => "string"}.to_json)
      resolver = StubResolver.new({} of {String, String} => String?)
      content = JSON.parse(%({"title": "Hello"}))
      expect_raises(Facet::Templating::Error) do
        Facet::Document::DisplayName.compute(defn, content, resolver)
      end
    end
  end
end
