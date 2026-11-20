# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/index"
require "../../src/doctype"

# Helper: creates a simple field definition for testing. The `operators`
# argument is the *legacy* operator-string list (e.g. `["eq", "gte"]`);
# it is translated to `FilterCapability` values via `caps_for` so existing
# call sites stay readable.
private def make_field(type_name : String, operators : Array(String)? = nil, unique : Bool = false, write_only : Bool = false, read_only : Bool = false)
  type = Facet::Doctype::FieldType.parse(type_name)
  caps = operators.try { |arr| caps_for(type.type_name, arr) }
  Facet::Doctype::FieldDefinition.new(
    type: type,
    filters: caps,
    unique: unique,
    write_only: write_only,
    read_only: read_only,
  )
end

# Translates a legacy operator-string list into `FilterCapability` values
# for the given field type. Mirrors the rules in
# `tmp/migrate_operators_to_filters.rb` (kept here so spec fixtures can
# stay written in the concise operator form).
private def caps_for(type_name : String, ops : Array(String)) : Array(Facet::Doctype::FilterCapability)?
  range_ops = !(ops & ["gt", "gte", "lt", "lte", "between"]).empty?
  has = ->(op : String) { ops.includes?(op) }
  any_of = ->(list : Array(String)) { !(ops & list).empty? }
  chars = [] of Facet::Doctype::FilterCapability
  if type_name == "period" || type_name == "dateperiod"
    chars << Facet::Doctype::FilterCapability::Equality if has.call("eq")
    chars << Facet::Doctype::FilterCapability::Interval if any_of.call(["contains", "overlaps", "within"])
  elsif type_name == "money"
    caps_for_money(chars, range_ops, has)
  elsif type_name == "array"
    chars << Facet::Doctype::FilterCapability::Membership if any_of.call(["eq", "contains", "overlaps"])
  else
    caps_for_scalar(chars, range_ops, has)
  end
  chars.empty? ? nil : chars
end

# Value part of the `money` branch of `caps_for`, split out to keep the
# cyclomatic complexity of both methods low.
private def caps_for_money(chars : Array(Facet::Doctype::FilterCapability), range_ops : Bool, has : (String -> Bool)) : Nil
  if has.call("eq") || range_ops
    chars << (range_ops ? Facet::Doctype::FilterCapability::Comparison : Facet::Doctype::FilterCapability::Equality)
  end
  chars << Facet::Doctype::FilterCapability::Currency if has.call("currency")
end

# Value part of the default branch of `caps_for`, split out to keep the
# cyclomatic complexity of both methods low.
private def caps_for_scalar(chars : Array(Facet::Doctype::FilterCapability), range_ops : Bool, has : (String -> Bool)) : Nil
  chars << Facet::Doctype::FilterCapability::Comparison if range_ops
  chars << Facet::Doctype::FilterCapability::Equality if !range_ops && has.call("eq")
  chars << Facet::Doctype::FilterCapability::TextSearch if has.call("match")
end

describe Facet::Index::Planner do
  describe ".compute_desired" do
    it "returns empty set for a doctype with no fields" do
      defn = Facet::Doctype::DoctypeDefinition.new(doctype: "Empty", domain: "test", fields: {} of String => Facet::Doctype::FieldDefinition)
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "generates btree index for a string field with eq operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"email" => make_field("string", ["eq"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.field_name.should eq("email")
      idx.index_type.should eq("btree")
    end

    it "generates btree + gin_trgm for a string field with eq and match operators" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"name" => make_field("string", ["eq", "match"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(2)
      types = desired.map(&.index_type).to_set
      types.should contain("btree")
      types.should contain("gin_trgm")
    end

    it "generates btree index for a datetime field with between operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"due_at" => make_field("datetime", ["between"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.field_name.should eq("due_at")
      idx.index_type.should eq("btree")
    end

    it "generates unique_btree for a field with unique: true" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"email" => make_field("string", unique: true)}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.any? { |i| i.field_name == "email" && i.index_type == "unique_btree" }.should be_true
    end

    it "generates gin_jsonb for array fields with the membership capability" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"tags" => make_field("array", ["eq"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.index_type.should eq("gin_jsonb")
    end

    it "does not generate gin_jsonb for an array field without membership" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        # No filters declared — no index emitted (the old "any non-empty
        # operators" heuristic is gone).
        fields: {"tags" => make_field("array")}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "does not generate any index for a dictionary field (membership is not supported)" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"metadata" => make_field("dictionary", ["eq"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "recurse into object properties when present" do
      props = {
        "city" => make_field("string", ["eq"]),
        "zip"  => make_field("string", ["eq"]),
      }
      object_field = Facet::Doctype::FieldDefinition.new(
        type: Facet::Doctype::FieldType.parse("object"),
        properties: props,
      )
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"address" => object_field}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(2)
      desired.any? { |i| i.field_name == "address.city" }.should be_true
      desired.any? { |i| i.field_name == "address.zip" }.should be_true
    end

    it "skips data (computed) fields" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {
          "computed" => make_field("data"),
        }
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "indexes every reference field with a btree index" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {
          "ref" => make_field("reference"),
        }
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.field_name.should eq("ref")
      idx.index_type.should eq("btree")
    end

    it "skips write_only fields" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"secret" => make_field("string", ["eq"], write_only: true)}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "skips read_only fields" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"slug" => make_field("string", ["eq"], read_only: true)}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "skips free-form object fields (no properties)" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"data" => make_field("object")}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "generates no index when no operators are specified" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"name" => make_field("string")}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "generates btree for datetime, boolean, enum, longtext with eq op" do
      %w[datetime boolean enum longtext].each do |type_name|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "Doc", domain: "test",
          fields: {"f" => make_field(type_name, ["eq"])}
        )
        desired = Facet::Index::Planner.compute_desired(defn)
        desired.size.should eq(1), "Expected btree index for #{type_name}"
        desired.first.index_type.should eq("btree")
      end
    end

    it "generates btree_numeric for integer and duration with eq op" do
      %w[integer duration].each do |type_name|
        defn = Facet::Doctype::DoctypeDefinition.new(
          doctype: "Doc", domain: "test",
          fields: {"f" => make_field(type_name, ["eq"])}
        )
        desired = Facet::Index::Planner.compute_desired(defn)
        desired.size.should eq(1), "Expected btree_numeric index for #{type_name}"
        desired.first.index_type.should eq("btree_numeric")
      end
    end

    it "generates gin_trgm for longtext field with match operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"bio" => make_field("longtext", ["match"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      desired.first.index_type.should eq("gin_trgm")
    end

    it "generates a single gist_tstzrange index for a period field with contains operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"tenure" => make_field("period", ["contains"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.field_name.should eq("tenure")
      idx.index_type.should eq("gist_tstzrange")
    end

    it "emits one GiST range index for a period field with multiple range operators" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"tenure" => make_field("period", ["eq", "contains", "overlaps", "within"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      desired.first.index_type.should eq("gist_tstzrange")
    end

    it "generates a gist_daterange index for a dateperiod field with overlaps operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"calendar" => make_field("dateperiod", ["overlaps"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      idx = desired.first
      idx.field_name.should eq("calendar")
      idx.index_type.should eq("gist_daterange")
    end

    it "emits no index for a period field with no operators" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"tenure" => make_field("period")}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end

    it "treats the `date` field type as a scalar btree-indexed field" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"hire_date" => make_field("date", ["eq", "gte", "lte"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.size.should eq(1)
      desired.first.index_type.should eq("btree")
    end

    # ── Money field: own category, composite btree_money index ──────────
    #
    # Money fields do not route through `compute_scalar_desired` (or the
    # `btree_numeric` path). They emit a composite `btree_money` index
    # (`(numeric_value, currency_text)`) and a `btree_money_currency` index
    # on the currency text extract (`doc/backend/index-management.md`).

    it "emits both btree_money and btree_money_currency for a money field with value operators" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"price" => make_field("money", ["gte", "lte", "between"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      types = desired.map(&.index_type).to_set
      types.should contain("btree_money")
      types.should contain("btree_money_currency")
      types.size.should eq(2)
    end

    it "emits btree_money_currency for a money field with only the currency operator" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"price" => make_field("money", ["currency"])}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      types = desired.map(&.index_type).to_set
      types.should contain("btree_money_currency")
      # Both indexes are emitted whenever any money operator is
      # declared — the composite value index is kept as a cheap secondary.
      types.should contain("btree_money")
    end

    it "emits unique_btree for a money field with unique: true" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"price" => make_field("money", ["eq"], unique: true)}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      types = desired.map(&.index_type).to_set
      types.should contain("unique_btree")
      types.should contain("btree_money")
      types.should contain("btree_money_currency")
    end

    it "emits no index for a money field with no operators and not unique" do
      defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "Doc", domain: "test",
        fields: {"price" => make_field("money")}
      )
      desired = Facet::Index::Planner.compute_desired(defn)
      desired.should be_empty
    end
  end
end
