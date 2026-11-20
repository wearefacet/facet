# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe DoctypeDefinition do
    # ── Migrations field: JSON parse ──────────────────────────────────

    it "parses a definition without migrations" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations.should be_empty
    end

    it "parses a definition with empty migrations" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "migrations": {}
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations.should be_empty
    end

    it "parses migrations from JSON" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 3,
        "migrations": {
          "1": "migrate_from_1",
          "2": "migrate_from_2"
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations.size.should eq(2)
      defn.migrations["1"].should eq("migrate_from_1")
      defn.migrations["2"].should eq("migrate_from_2")
    end

    it "parses migrations with string version keys" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 2,
        "migrations": {
          "1": "migrate_from_1"
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations.keys.should contain("1")
      defn.migrations["1"].should eq("migrate_from_1")
    end

    it "parses migrations alongside fields, actions, and script" do
      json = %({
        "doctype": "Order",
        "domain": "shop",
        "schema_version": 2,
        "fields": {
          "title": { "type": "string", "required": true },
          "status": { "type": "string" }
        },
        "actions": {
          "ship": { "args": {} }
        },
        "migrations": {
          "1": "migrate_from_1"
        },
        "script": "local export = {}; function export.migrate_from_1(ctx) end; return export"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations.size.should eq(1)
      defn.migrations["1"].should eq("migrate_from_1")
      defn.fields.size.should eq(2)
      defn.actions.size.should eq(1)
      defn.script.should_not be_nil
    end

    # ── Migrations field: JSON serialize ──────────────────────────────

    it "serializes to JSON without migrations when empty" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production"
      )
      json = defn.to_json
      parsed = JSON.parse(json)
      parsed["migrations"]?.should be_nil
    end

    it "serializes migrations to JSON" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      json = defn.to_json
      parsed = JSON.parse(json)
      migrations = parsed["migrations"]
      migrations.should be_a(JSON::Any)
      migrations["1"].as_s.should eq("migrate_from_1")
      migrations["2"].as_s.should eq("migrate_from_2")
    end

    it "does not emit migrations field when empty (avoids clutter)" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder",
        domain: "production",
        schema_version: 2,
        migrations: {} of String => String
      )
      json = defn.to_json
      parsed = JSON.parse(json)
      parsed["migrations"]?.should be_nil
    end

    # ── Round trip ───────────────────────────────────────────────────

    it "round-trips migrations through JSON parse/serialize" do
      original = DoctypeDefinition.new(
        doctype: "Article",
        domain: "blog",
        schema_version: 3,
        migrations: {"1" => "migrate_from_1", "2" => "migrate_from_2"}
      )
      json = original.to_json
      restored = DoctypeDefinition.from_json(json)
      restored.migrations.should eq(original.migrations)
      restored.schema_version.should eq(original.schema_version)
    end

    it "round-trips a full definition with migrations, fields, actions, and script" do
      script = "local export = {}; function export.migrate_from_1(ctx) end; return export"
      original = DoctypeDefinition.new(
        doctype: "Task",
        domain: "work",
        schema_version: 2,
        fields: {"title" => FieldDefinition.new(type: FieldType.parse("string"))},
        actions: {"complete" => ActionDefinition.new},
        migrations: {"1" => "migrate_from_1"},
        script: script
      )
      json = original.to_json
      restored = DoctypeDefinition.from_json(json)
      restored.doctype.should eq("Task")
      restored.schema_version.should eq(2)
      restored.migrations.should eq({"1" => "migrate_from_1"})
      restored.fields.size.should eq(1)
      restored.actions.size.should eq(1)
      restored.script.should eq(script)
    end

    # ── Edge cases ───────────────────────────────────────────────────

    it "handles migration function names with underscores and digits" do
      json = %({
        "doctype": "Item",
        "domain": "inventory",
        "schema_version": 4,
        "migrations": {
          "1": "migrate_from_v1",
          "2": "migrate_from_v2_to_v3",
          "3": "step_3"
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.migrations["1"].should eq("migrate_from_v1")
      defn.migrations["2"].should eq("migrate_from_v2_to_v3")
      defn.migrations["3"].should eq("step_3")
    end

    it "rejects non-string migration function values at parse time" do
      json = %({
        "doctype": "Item",
        "domain": "inventory",
        "migrations": {
          "1": 42
        }
      })
      expect_raises(Exception) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "initializes migrations via constructor" do
      defn = DoctypeDefinition.new(
        doctype: "Note",
        domain: "app",
        migrations: {"1" => "migrate_from_1"}
      )
      defn.migrations.should eq({"1" => "migrate_from_1"})
    end

    it "defaults migrations to empty hash" do
      defn = DoctypeDefinition.new(
        doctype: "Note",
        domain: "app"
      )
      defn.migrations.should be_empty
    end
  end
end
