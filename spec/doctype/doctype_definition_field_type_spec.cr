# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the field-type lookup hardening in the definition parser (B-37).
# An unknown type name, a non-string `type` value, a junk dictionary
# `values` descriptor, and a junk `operators` list were all accepted (or
# escaped as a 500 `ArgumentError`) at registration time, producing a
# doctype whose field no document could ever satisfy. Each shape now
# raises `DefinitionError` — the 422 channel — naming the offender.

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe FieldDefinition do
    # ── Unknown type name ─────────────────────────────────────────────

    it "rejects an unknown type name at the top level" do
      expect_raises(DefinitionError, /Unknown field type: "int"/) do
        FieldDefinition.from_json(%({"type": "int"}))
      end
    end

    it "rejects an unknown type name inside a nested items descriptor" do
      expect_raises(DefinitionError, /field 'items': Unknown field type: "int"/) do
        FieldDefinition.from_json(%({"type": "array", "items": {"type": "int"}}))
      end
    end

    it "rejects an unknown type name inside an object property" do
      expect_raises(DefinitionError, /field 'properties\.n': Unknown field type: "int"/) do
        FieldDefinition.from_json(%({"type": "object", "properties": {"n": {"type": "int"}}}))
      end
    end

    it "names the known types in the unknown-type message" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "int"}))
      end
      ex.message.should contain("known types:")
      ex.message.should contain("string")
    end

    # ── Non-string type value ─────────────────────────────────────────

    it "rejects a non-string type value at the top level" do
      expect_raises(DefinitionError, /'type' must be a string type name \(got number\)/) do
        FieldDefinition.from_json(%({"type": 123}))
      end
    end

    it "rejects a non-string type value inside a nested items descriptor" do
      expect_raises(DefinitionError, /field 'items': 'type' must be a string type name/) do
        FieldDefinition.from_json(%({"type": "array", "items": {"type": 123}}))
      end
    end

    # ── Junk dictionary values descriptor ─────────────────────────────

    it "rejects a dictionary values descriptor with a non-string type" do
      expect_raises(DefinitionError, /field 'values': 'type' must be a string type name/) do
        FieldDefinition.from_json(%({"type": "dictionary", "values": {"type": 123}}))
      end
    end

    it "rejects a dictionary values descriptor with an unknown type" do
      expect_raises(DefinitionError, /field 'values': Unknown field type: "int"/) do
        FieldDefinition.from_json(%({"type": "dictionary", "values": {"type": "int"}}))
      end
    end

    # ── Junk operators list ───────────────────────────────────────────

    it "rejects an operators list with an unknown entry" do
      expect_raises(DefinitionError, /\.operators: unknown operator "bogus"/) do
        FieldDefinition.from_json(%({"type": "string", "operators": ["bogus"]}))
      end
    end

    it "rejects an operators list with a non-string entry" do
      expect_raises(DefinitionError, /\.operators: unknown operator 7/) do
        FieldDefinition.from_json(%({"type": "string", "operators": [7]}))
      end
    end

    it "rejects a non-array operators value" do
      expect_raises(DefinitionError, /\.operators must be an array of operator names/) do
        FieldDefinition.from_json(%({"type": "string", "operators": "eq"}))
      end
    end

    # ── Happy paths ───────────────────────────────────────────────────

    it "parses a field with a known type and valid filter capabilities" do
      fd = FieldDefinition.from_json(%({"type": "string", "filters": ["equality", "text_search"]}))
      fd.type.try(&.type_name).should eq("string")
      fd.filters.not_nil!.size.should eq(2)
      fd.operators.should contain(Operator::Eq)
      fd.operators.should contain(Operator::Match)
    end

    it "re-parses round-tripped content that carries the derived operators member" do
      fd = FieldDefinition.from_json(%({"type": "string", "filters": ["equality"]}))
      json = JSON.parse(fd.to_json).to_json
      round_tripped = FieldDefinition.from_json(json)
      round_tripped.type.try(&.type_name).should eq("string")
      round_tripped.operators.should contain(Operator::Eq)
    end
  end

  # ── Action arguments (B-58) ────────────────────────────────────────
  #
  # The action-arg parser shares the type registry with fields but
  # missed the B-37 wrapper, so an unknown type name escaped the
  # authoring paths as a 500 `ArgumentError`. It must answer the 422
  # channel (`DefinitionError`) naming the action, the argument and the
  # path, like the field cases above.

  describe ActionArgDefinition do
    it "rejects an unknown type name, naming the action, the argument and the path" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(
          JSON.parse(%({"args": {"amount": {"type": "number"}}})),
          "action 'release'"
        )
      end
      ex.message.should contain("Unknown field type")
      ex.message.should contain(%("number"))
      ex.message.should contain("action 'release'.args.amount")
    end

    it "rejects a non-string type value, naming the action, the argument and the path" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(
          JSON.parse(%({"args": {"amount": {"type": 123}}})),
          "action 'release'"
        )
      end
      ex.message.should contain("'type' must be a string type name")
      ex.message.should contain("action 'release'.args.amount")
    end
  end

  # ── Empty string is an absent string ─────────────────────────────
  #
  # The same doctrine as the definition level: an empty optional string
  # on a field normalizes to nil, and a wrong type answers the 422
  # channel instead of silently dropping the attribute (or escaping as
  # a 500 TypeCastError).

  describe "empty optional strings normalize to nil" do
    it "normalizes empty title, description, compute, pattern, pattern_flags, currency, and mode" do
      fd = FieldDefinition.from_json(%({
        "type": "string",
        "title": "",
        "description": "",
        "pattern": "",
        "pattern_flags": "",
        "currency": "",
        "mode": ""
      }))
      fd.title.should be_nil
      fd.description.should be_nil
      fd.pattern.should be_nil
      fd.pattern_flags.should be_nil
      fd.currency.should be_nil
      fd.mode.should be_nil
    end

    it "normalizes an empty compute on a data field (the validator still rejects it)" do
      fd = FieldDefinition.from_json(%({"type": "data", "compute": ""}))
      fd.compute.should be_nil
      fd.computed?.should be_true
    end

    it "defaults an empty on_source_delete to keep" do
      fd = FieldDefinition.from_json(%({
        "type": "string",
        "replicate": {"via": "r", "field": "f"},
        "on_source_delete": ""
      }))
      fd.on_source_delete.should eq("keep")
    end

    it "treats an empty reference doctype as no declared target (polymorphic)" do
      fd = FieldDefinition.from_json(%({"type": "reference", "doctype": ""}))
      fd.type.try(&.type_name).should eq("reference")
      fd.doctype.should be_nil
    end

    it "rejects a field with neither a type nor a doctype (422 at authoring, not at write)" do
      expect_raises(DefinitionError, /must declare a 'type'/) do
        FieldDefinition.from_json(%({"title": "x"}))
      end
    end

    it "rejects an empty doctype without a type (the implicit-reference escape is gone)" do
      expect_raises(DefinitionError, /must declare a 'type'/) do
        FieldDefinition.from_json(%({"doctype": ""}))
      end
    end
  end

  describe "wrong-typed optional strings answer 422" do
    it "rejects a non-string title" do
      expect_raises(DefinitionError, /field definition: 'title' must be a string \(got number\)/) do
        FieldDefinition.from_json(%({"type": "string", "title": 42}))
      end
    end

    it "rejects a non-string compute, naming the field path" do
      expect_raises(DefinitionError, /field 'n': 'compute' must be a string \(got number\)/) do
        DoctypeDefinition.from_json(%({
          "doctype": "Thing",
          "domain": "fgrammar",
          "fields": {"n": {"type": "data", "compute": 42}}
        }))
      end
    end

    it "rejects a non-string on_source_delete instead of defaulting to keep" do
      expect_raises(DefinitionError, /'on_source_delete' must be a string \(got number\)/) do
        FieldDefinition.from_json(%({
          "type": "string",
          "replicate": {"via": "r", "field": "f"},
          "on_source_delete": 42
        }))
      end
    end
  end

  # ── Enum entries ──────────────────────────────────────────────────

  describe "enum value entries" do
    it "rejects a non-string legacy entry (422, never a TypeCastError)" do
      expect_raises(DefinitionError, /values\[0\] must be a string key or an object entry \(got number\)/) do
        FieldDefinition.from_json(%({"type": "enum", "values": [42]}))
      end
    end

    it "rejects an empty legacy key" do
      expect_raises(DefinitionError, /values\[0\] must be a non-empty string key/) do
        FieldDefinition.from_json(%({"type": "enum", "values": [""]}))
      end
    end

    it "rejects a missing key on an object entry" do
      expect_raises(DefinitionError, /Missing required field 'key'/) do
        FieldDefinition.from_json(%({"type": "enum", "values": [{}]}))
      end
    end

    it "rejects a non-string key on an object entry" do
      expect_raises(DefinitionError, /'key' must be a string \(got number\)/) do
        FieldDefinition.from_json(%({"type": "enum", "values": [{"key": 42}]}))
      end
    end

    it "rejects an empty key on an object entry" do
      expect_raises(DefinitionError, /'key' must be a non-empty string/) do
        FieldDefinition.from_json(%({"type": "enum", "values": [{"key": ""}]}))
      end
    end

    it "falls back to the derived label and color for an empty label or color" do
      fd = FieldDefinition.from_json(%({"type": "enum", "values": [{"key": "active", "label": "", "color": ""}]}))
      value = fd.values.not_nil!.first
      value.effective_label.should eq("Active")
      value.effective_color.should eq(Util::Color.hash_color("active"))
    end
  end

  # ── Replicate config ──────────────────────────────────────────

  describe "replicate config" do
    it "rejects a non-string via (422, never a TypeCastError)" do
      expect_raises(DefinitionError, /'via' must be a string \(got number\)/) do
        FieldDefinition.from_json(%({
          "type": "string",
          "replicate": {"via": 42, "field": "f"}
        }))
      end
    end

    it "rejects an empty via" do
      expect_raises(DefinitionError, /'via' must be a non-empty string/) do
        FieldDefinition.from_json(%({
          "type": "string",
          "replicate": {"via": "", "field": "f"}
        }))
      end
    end
  end
end
