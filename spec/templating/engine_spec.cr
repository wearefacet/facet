# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/templating"

describe Facet::Templating::Engine do
  describe ".render" do
    it "renders a simple substitution" do
      bindings = Crinja::Variables.new
      bindings["name"] = Crinja::Value.new("Ada")
      Facet::Templating::Engine.render("Hello {{ name }}", bindings).should eq("Hello Ada")
    end

    # Regression: Crinja 0.9.0's `config.autoescape = Bool` setter is
    # inverted, so the engine must assign `Autoescape::DISABLED` directly.
    # With autoescape on, every string printed from a template goes through
    # `HTML.escape` and stored labels carry entities (`'` → `&#39;`).
    it "renders HTML-special characters verbatim (autoescape off)" do
      bindings = Crinja::Variables.new
      bindings["label"] = Crinja::Value.new(%(Meuleuse d'angle & "tronçonnage" <A>))
      Facet::Templating::Engine.render("{{ label }}", bindings)
        .should eq(%(Meuleuse d'angle & "tronçonnage" <A>))
    end

    it "raises Templating::Error on invalid syntax" do
      expect_raises(Facet::Templating::Error, "Invalid template") do
        Facet::Templating::Engine.compile("{{ unclosed")
      end
    end

    it "raises Templating::Error on a runtime failure" do
      bindings = Crinja::Variables.new
      bindings["n"] = Crinja::Value.new(5)
      expect_raises(Facet::Templating::Error) do
        Facet::Templating::Engine.render("{{ n.foo() }}", bindings)
      end
    end

    it "caches compiled templates" do
      Facet::Templating::Engine.compile("{{ a }}").should be(
        Facet::Templating::Engine.compile("{{ a }}")
      )
    end
  end

  describe ".roots" do
    it "collects root variables from output expressions" do
      Facet::Templating::Engine.roots("{{ a }} {{ b.c }} {{ d['e'] }}").should eq(["a", "b", "d"])
    end

    it "collects a root once" do
      Facet::Templating::Engine.roots("{{ a }} {{ a | upper }}").should eq(["a"])
    end

    it "excludes filter, test, and function names" do
      Facet::Templating::Engine.roots("{{ a | upper }} {{ range(3) }}").should eq(["a"])
    end

    it "collects roots from tag bodies" do
      Facet::Templating::Engine.roots("{% if flag %}{{ name }}{% endif %}").should eq(["name"])
    end

    it "returns an empty list for a static template" do
      Facet::Templating::Engine.roots("plain text").should be_empty
    end
  end
end

describe Facet::Templating::Context do
  it "binds every declared field, blank for missing ones" do
    defn = build_templating_defn({
      "present" => templating_field("string"),
      "absent"  => templating_field("string"),
    })
    bindings = Facet::Templating::Context.build(defn, JSON.parse(%({"present": "x"})))
    bindings.has_key?("present").should be_true
    bindings.has_key?("absent").should be_true
    bindings.has_key?("content").should be_true
  end

  it "renders blank nodes as empty and keeps nested paths safe" do
    defn = build_templating_defn({"a" => templating_field("object"), "b" => templating_field("object")})
    bindings = Facet::Templating::Context.build(defn, JSON.parse(%({"a": {"x": 1}})))
    Facet::Templating::Engine.render("[{{ a.x }}][{{ b.y.z }}]", bindings).should eq("[1][]")
  end

  it "formats money objects by shape" do
    defn = build_templating_defn({"obj" => templating_field("object")})
    bindings = Facet::Templating::Context.build(
      defn,
      JSON.parse(%({"obj": {"price": {"value": "10", "currency": "USD"}}})),
    )
    Facet::Templating::Engine.render("{{ obj.price }}", bindings).should eq("USD 10")
  end

  it "resolves reference fields through the resolver" do
    defn = build_templating_defn({"company_id" => JSON.parse(%({"type": "reference", "doctype": "crm.Company"}))})
    resolver = TemplatingStubResolver.new({} of {String, String} => String?)
    bindings = Facet::Templating::Context.build(defn, JSON.parse(%({})), resolver)
    Facet::Templating::Engine.render("{{ company_id }}", bindings).should eq("Company")
  end

  it "binds the reserved display_name variable when the caller supplies it" do
    defn = build_templating_defn({"name" => templating_field("string")})
    bindings = Facet::Templating::Context.build(defn, JSON.parse(%({"name": "x"})), nil, "Ada Lovelace")
    Facet::Templating::Engine.render("{{ display_name }}", bindings).should eq("Ada Lovelace")
  end

  it "binds a blank display_name when the caller supplies none" do
    defn = build_templating_defn({"name" => templating_field("string")})
    bindings = Facet::Templating::Context.build(defn, JSON.parse(%({"name": "x"})))
    Facet::Templating::Engine.render("[{{ display_name }}]", bindings).should eq("[]")
  end

  it "lets the reserved display_name variable win over a same-named field" do
    defn = build_templating_defn({"display_name" => templating_field("string")})
    content = JSON.parse(%({"display_name": "from field"}))

    supplied = Facet::Templating::Context.build(defn, content, nil, "from caller")
    Facet::Templating::Engine.render("{{ display_name }}", supplied).should eq("from caller")

    # Even a nil value overrides the field binding — reserved variables
    # bind after the field loop, the same precedence `content` has.
    unsupplied = Facet::Templating::Context.build(defn, content)
    Facet::Templating::Engine.render("[{{ display_name }}]", unsupplied).should eq("[]")
  end
end

class TemplatingStubResolver < Facet::Templating::ReferenceResolver
  @lookup : Hash({String, String}, String?)

  def initialize(lookup : Hash({String, String}, String?))
    @lookup = lookup
  end

  def resolve(qualified_target_doctype : String, doc_id : String) : String?
    @lookup[{qualified_target_doctype, doc_id}]?
  end
end

def templating_field(type : String)
  JSON.parse(%({"type": "#{type}"}))
end

def build_templating_defn(fields : Hash(String, JSON::Any), domain = "test")
  raw = {
    "doctype" => "Widget",
    "domain"  => domain,
    "fields"  => fields,
  }
  Facet::Doctype::DoctypeDefinition.from_json(JSON.parse(raw.to_json))
end
