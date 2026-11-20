# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# Specs for the wrong-type contract on the definition grammar: every
# scalar key answers 422 (`DefinitionError`) when it carries the wrong
# JSON type — never a raised cast (`TypeCastError`), which the
# create/update services do not rescue, so it surfaced as an HTTP 500
# (the B-12 class). One case per guarded key.

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe "definition grammar wrong-type contract" do
    # ── FieldDefinition scalars ──────────────────────────────────────

    it "rejects a non-boolean required" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "required": 42}))
      end
      ex.message.should contain("'required' must be a boolean (got number)")
    end

    it "accepts a legitimate false for required (the Crystal truthiness trap)" do
      fd = FieldDefinition.from_json(%({"type": "string", "required": false}))
      fd.required.should be_false
    end

    it "rejects a non-boolean unique" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "unique": "yes"}))
      end
      ex.message.should contain("'unique' must be a boolean (got string)")
    end

    it "rejects a non-boolean collection" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "collection": 1}))
      end
      ex.message.should contain("'collection' must be a boolean (got number)")
    end

    it "rejects a non-boolean write_only" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "write_only": "x"}))
      end
      ex.message.should contain("'write_only' must be a boolean (got string)")
    end

    it "rejects a non-boolean read_only" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "read_only": 0}))
      end
      ex.message.should contain("'read_only' must be a boolean (got number)")
    end

    it "rejects a non-boolean dangling" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "reference", "dangling": "x"}))
      end
      ex.message.should contain("'dangling' must be a boolean (got string)")
    end

    it "rejects a non-boolean owned" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "reference", "owned": "x"}))
      end
      ex.message.should contain("'owned' must be a boolean (got string)")
    end

    it "rejects a non-integer min" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "integer", "min": "5"}))
      end
      ex.message.should contain("'min' must be an integer (got string)")
    end

    it "rejects a non-integer max" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "integer", "max": []}))
      end
      ex.message.should contain("'max' must be an integer (got array)")
    end

    it "rejects a non-integer ttl_seconds" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "secret", "mode": "token", "ttl_seconds": "x"}))
      end
      ex.message.should contain("'ttl_seconds' must be an integer (got string)")
    end

    it "rejects a non-array compute_when" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "data", "compute": "f", "compute_when": "x"}))
      end
      ex.message.should contain("'compute_when' must be an array of strings (got string)")
    end

    it "rejects a non-string entry inside compute_when" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "data", "compute": "f", "compute_when": [42]}))
      end
      ex.message.should contain("'compute_when' must contain only strings (got number)")
    end

    it "rejects a non-array accept" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "file", "accept": 42}))
      end
      ex.message.should contain("'accept' must be an array of strings (got number)")
    end

    it "rejects a non-array tags" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "tags": {}}))
      end
      ex.message.should contain("'tags' must be an array of strings (got object)")
    end

    it "rejects a non-string entry inside tags" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "string", "tags": [42]}))
      end
      ex.message.should contain("'tags' must contain only strings (got number)")
    end

    it "rejects a non-object filter" do
      ex = expect_raises(DefinitionError) do
        FieldDefinition.from_json(%({"type": "reference", "doctype": "x.Thing", "filter": []}))
      end
      ex.message.should contain("'filter' must be an object (got array)")
    end

    # ── ActionDefinition / ActionArgDefinition ───────────────────────

    it "rejects a non-string event_name" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"event_name": 42})), "action 'a'")
      end
      ex.message.should contain("'event_name' must be a string (got number)")
    end

    it "rejects a non-string action description" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"description": 42})), "action 'a'")
      end
      ex.message.should contain("'description' must be a string (got number)")
    end

    it "rejects a non-boolean arg required" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "string", "required": "x"}}})), "action 'a'")
      end
      ex.message.should contain("'required' must be a boolean (got string)")
    end

    it "rejects a non-boolean arg collection" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "string", "collection": 42}}})), "action 'a'")
      end
      ex.message.should contain("'collection' must be a boolean (got number)")
    end

    it "rejects a non-array arg values" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "enum", "values": 42}}})), "action 'a'")
      end
      ex.message.should contain("'values' must be an array of strings (got number)")
    end

    it "rejects a non-string entry inside arg values" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "enum", "values": [42]}}})), "action 'a'")
      end
      ex.message.should contain("'values' must contain only strings (got number)")
    end

    it "rejects a non-integer arg min" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "integer", "min": "x"}}})), "action 'a'")
      end
      ex.message.should contain("'min' must be an integer (got string)")
    end

    it "rejects a non-string arg doctype" do
      ex = expect_raises(DefinitionError) do
        ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "reference", "doctype": 42}}})), "action 'a'")
      end
      ex.message.should contain("'doctype' must be a string (got number)")
    end

    # ── ChildrenDefinition ───────────────────────────────────────────

    it "rejects a non-string child doctype" do
      ex = expect_raises(DefinitionError) do
        ChildrenDefinition.from_json(JSON.parse(%({"doctype": 42})), "child 'c'")
      end
      ex.message.should contain("'doctype' must be a string (got number)")
    end

    it "rejects a non-boolean child collection" do
      ex = expect_raises(DefinitionError) do
        ChildrenDefinition.from_json(JSON.parse(%({"doctype": "Thing", "collection": "x"})), "child 'c'")
      end
      ex.message.should contain("'collection' must be a boolean (got string)")
    end

    it "rejects a non-string child description" do
      ex = expect_raises(DefinitionError) do
        ChildrenDefinition.from_json(JSON.parse(%({"doctype": "Thing", "description": 42})), "child 'c'")
      end
      ex.message.should contain("'description' must be a string (got number)")
    end

    # ── NamedScope ───────────────────────────────────────────────────

    it "rejects a non-string scope description" do
      ex = expect_raises(DefinitionError) do
        NamedScope.from_json("s", JSON.parse(%({"description": 42})))
      end
      ex.message.should contain("'description' must be a string (got number)")
    end

    # ── SidecarRef ───────────────────────────────────────────────────

    it "rejects a non-string sidecar doctype" do
      ex = expect_raises(DefinitionError) do
        SidecarRef.from_json(JSON.parse(%({"doctype": 42})), "sidecar 's'")
      end
      ex.message.should contain("'doctype' must be a string (got number)")
    end

    it "rejects a non-string sidecar column" do
      ex = expect_raises(DefinitionError) do
        SidecarRef.from_json(JSON.parse(%({"doctype": "core.Comment", "column": 42})), "sidecar 's'")
      end
      ex.message.should contain("'column' must be a string (got number)")
    end

    it "rejects a non-integer sidecar order" do
      ex = expect_raises(DefinitionError) do
        SidecarRef.from_json(JSON.parse(%({"doctype": "core.Comment", "order": "x"})), "sidecar 's'")
      end
      ex.message.should contain("'order' must be an integer (got string)")
    end

    it "rejects a non-string sidecar label" do
      ex = expect_raises(DefinitionError) do
        SidecarRef.from_json(JSON.parse(%({"doctype": "core.Comment", "label": 42})), "sidecar 's'")
      end
      ex.message.should contain("'label' must be a string (got number)")
    end

    # ── Empty string is an absent string (newly covered keys) ────────

    it "normalizes an empty action event_name and description to nil" do
      a = ActionDefinition.from_json(JSON.parse(%({"event_name": "", "description": ""})), "action 'a'")
      a.event_name.should be_nil
      a.description.should be_nil
    end

    it "normalizes an empty arg doctype to nil" do
      a = ActionDefinition.from_json(JSON.parse(%({"args": {"n": {"type": "reference", "doctype": ""}}})), "action 'a'")
      a.args["n"].doctype.should be_nil
    end

    it "normalizes an empty child description to nil" do
      c = ChildrenDefinition.from_json(JSON.parse(%({"doctype": "Thing", "description": ""})), "child 'c'")
      c.description.should be_nil
    end

    it "normalizes an empty scope description to nil" do
      s = NamedScope.from_json("s", JSON.parse(%({"description": ""})))
      s.description.should be_nil
    end

    it "normalizes an empty sidecar column to the target default and an empty label to nil" do
      s = SidecarRef.from_json(JSON.parse(%({"doctype": "core.Comment", "column": "", "label": ""})), "sidecar 's'")
      s.column.should eq("target")
      s.label.should be_nil
    end
  end
end
