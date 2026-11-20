# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype/doctype_definition"
require "../../src/document/search"

class SearchStubResolver < Facet::Templating::ReferenceResolver
  @lookup : Hash({String, String}, String?)

  def initialize(lookup : Hash({String, String}, String?))
    @lookup = lookup
  end

  def resolve(qualified_target_doctype : String, doc_id : String) : String?
    @lookup[{qualified_target_doctype, doc_id}]?
  end
end

def build_search_definition(search : String?, **fields)
  field_json = {} of String => JSON::Any
  fields.each do |name, type|
    field_json[name.to_s] = JSON.parse(%({"type": "#{type}"}))
  end
  raw = {
    "doctype" => JSON::Any.new("Widget"),
    "domain"  => JSON::Any.new("test"),
    "fields"  => JSON::Any.new(field_json),
  }
  raw["search"] = JSON::Any.new(search) if search
  Facet::Doctype::DoctypeDefinition.from_json(JSON::Any.new(raw))
end

describe Facet::Document::Search do
  describe ".compute" do
    it "renders the search template" do
      defn = build_search_definition("{{ first_name }} {{ last_name }}",
        first_name: "string", last_name: "string")
      content = JSON.parse(%({"first_name": "Ada", "last_name": "Lovelace"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should eq("ada lovelace")
    end

    it "accent-folds the rendered corpus" do
      defn = build_search_definition("{{ first_name }} {{ last_name }}",
        first_name: "string", last_name: "string")
      content = JSON.parse(%({"first_name": "José", "last_name": "García"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should eq("jose garcia")
    end

    it "folds before truncation — the cap applies to the stored length" do
      # Case folding grows the string (ß -> ss): 300 ß fold to 600 s, so a
      # fold after the 256-char truncate would keep two extra characters.
      defn = build_search_definition("{{ long }}", long: "string")
      content = JSON.parse(%({"long": "#{("ß" * 300)}"}))
      result = Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?)).not_nil!
      result.size.should eq(256)
      result.should eq("s" * 256)
    end

    it "collapses whitespace runs and strips the corpus" do
      defn = build_search_definition("{{ a }}   {{ b }}  ", a: "string", b: "string")
      content = JSON.parse(%({"a": "x"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should eq("x")
    end

    it "returns nil when the rendered corpus is empty" do
      defn = build_search_definition("{{ a }} {{ b }}", a: "string", b: "string")
      content = JSON.parse(%({}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should be_nil
    end

    it "returns nil when the doctype declares no template and no display_name" do
      # No template and no display_name value: nothing to stage, the GUC
      # goes empty and the trigger stores NULL.
      defn = build_search_definition(nil, name: "string")
      content = JSON.parse(%({"name": "x"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should be_nil
    end

    it "falls back to the folded display_name when the doctype declares no template (B-115)" do
      # The template-less corpus is the display_name through the same
      # normalise → fold → truncate pipeline, so the bare `search` filter
      # matches the folded label like every templated doctype.
      defn = build_search_definition(nil, name: "string")
      content = JSON.parse(%({"name": "x"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?), "  Crème   café  ")
        .should eq("creme cafe")
    end

    it "returns nil for a blank display_name on a template-less doctype" do
      defn = build_search_definition(nil, name: "string")
      content = JSON.parse(%({"name": "x"}))
      resolver = SearchStubResolver.new({} of {String, String} => String?)
      Facet::Document::Search.compute(defn, content, resolver, "").should be_nil
      Facet::Document::Search.compute(defn, content, resolver, nil).should be_nil
    end

    it "treats an empty template like a missing one" do
      defn = build_search_definition("", name: "string")
      content = JSON.parse(%({"name": "x"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
        .should be_nil
    end

    it "renders the reserved display_name variable inside a search template" do
      defn = build_search_definition("{{ display_name }} — {{ name }}", name: "string")
      content = JSON.parse(%({"name": "Ada"}))
      Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?), "Ada Lovelace")
        .should eq("ada lovelace — ada")
    end

    it "applies the same fold-then-truncate cap to the fallback corpus" do
      # Case folding grows the string (ß -> ss): the fallback corpus must
      # fold before truncation exactly like the template path.
      defn = build_search_definition(nil, name: "string")
      content = JSON.parse(%({"name": "x"}))
      result = Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?), "ß" * 300).not_nil!
      result.size.should eq(256)
      result.should eq("s" * 256)
    end

    it "truncates the corpus to 256 characters" do
      defn = build_search_definition("{{ long }}", long: "string")
      content = JSON.parse(%({"long": "#{("x" * 300)}"}))
      result = Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?)).not_nil!
      result.size.should eq(256)
    end

    it "raises Templating::Error when the template fails to render" do
      defn = build_search_definition("{{ a.foo() }}", a: "string")
      content = JSON.parse(%({"a": "x"}))
      expect_raises(Facet::Templating::Error) do
        Facet::Document::Search.compute(defn, content, SearchStubResolver.new({} of {String, String} => String?))
      end
    end
  end

  describe ".set_guc" do
    it "stages an empty GUC when the doctype declares no template and no display_name" do
      # The trigger turns the empty string into a NULL search column
      # (NULLIF on the GUC read).
      with_db do |db|
        defn = build_search_definition(nil, name: "string")
        db.transaction do |tx|
          conn = tx.connection
          Facet::Document::Search.set_guc(conn, defn, JSON.parse(%({"name": "x"})), nil)
          value = conn.query_one("SELECT current_setting('harness.mutation_search', true)", as: String?)
          value.should eq("")
        end
      end
    end

    it "stages the folded display_name as the fallback corpus (B-115)" do
      with_db do |db|
        defn = build_search_definition(nil, name: "string")
        db.transaction do |tx|
          conn = tx.connection
          Facet::Document::Search.set_guc(conn, defn, JSON.parse(%({"name": "x"})), "Crème café")
          value = conn.query_one("SELECT current_setting('harness.mutation_search', true)", as: String?)
          value.should eq("creme cafe")
        end
      end
    end
  end
end
