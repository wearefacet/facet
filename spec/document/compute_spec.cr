# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/doctype"
require "../../src/document"

module Facet::Document
  describe Compute do
    it "runs all computed fields when changed_fields is nil (create scenario)" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "test",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_test(ctx)
            return "computed:" .. (ctx.root.name or "none")
          end
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello"}))
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: nil,
        actioner_id: "test",
      )

      errors.should be_empty
      result["name"].as_s.should eq("hello")
      result["computed_field"]?.should_not be_nil
      result["computed_field"].as_s.should eq("computed:hello")
    end

    it "honours a ctx.root write when the compute function returns nil" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "test",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_test(ctx)
            ctx.root.computed_field = "mutated:" .. (ctx.root.name or "none")
          end
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello"}))
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: nil,
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"].as_s.should eq("mutated:hello")
    end

    it "lets the returned value win over a ctx.root write" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "test",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_test(ctx)
            ctx.root.computed_field = "mutated"
            return "returned"
          end
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello"}))
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: nil,
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"].as_s.should eq("returned")
    end

    it "keeps a nil return clearing the field when the function does not write ctx.root" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "test",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_test(ctx)
            if ctx.root.name then
              return "computed:" .. ctx.root.name
            end
            return nil
          end
          return export
        LUA
      )

      # The document carries a stale computed value from a previous write;
      # the recompute (name now gone) must clear it, not keep the stale
      # value the fresh ctx.root still holds.
      document = JSON.parse(%({"computed_field": "computed:hello"}))
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: Set{"name"},
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"]?.should be_nil
    end

    it "runs computed fields only when compute_when intersects changed_fields" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "email"          => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "test",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_test(ctx)
            return "computed:" .. (ctx.root.name or "none")
          end
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello", "email": "a@b.com"}))

      # When changed_fields only contains "email", the compute should NOT run
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: Set{"email"},
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"]?.should be_nil

      # When changed_fields contains "name", the compute SHOULD run
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: Set{"name"},
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"].as_s.should eq("computed:hello")
    end

    it "skips compute when the Lua function is not defined" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "missing_fn",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello"}))
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: Set{"name"},
        actioner_id: "test",
      )

      errors.should be_empty
      result["computed_field"]?.should be_nil
    end

    it "reports errors when a compute function raises a Lua error" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"           => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "computed_field" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "bad",
            compute_when: ["name"]
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_bad(ctx)
            error("something went wrong")
          end
          return export
        LUA
      )

      document = JSON.parse(%({"name": "hello"}))
      _, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        document,
        changed_fields: Set{"name"},
        actioner_id: "test",
      )

      errors.should_not be_empty
      errors.any?(&.message.includes?("something went wrong")).should be_true
    end

    it "returns no errors when no computed fields are defined" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {"name" => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string"))},
        script: nil
      )

      document = JSON.parse(%({"name": "hello"}))
      result, errors = Compute.call(
        "local export = {} return export",
        definition,
        document,
        changed_fields: nil,
        actioner_id: "test",
      )

      errors.should be_empty
      result["name"].as_s.should eq("hello")
    end
  end

  # ── Read-only `document` global (B-110 part 1) ──────────────────

  describe "read-only document global" do
    it "reads through document.get and document.list when db and domain are supplied" do
      with_temp_doctype do |db, domain, doctype|
        ensure_domain(db, domain)
        script = <<-LUA
          local export = {}
          function export.compute_mirror(ctx)
            local ok, doc = pcall(document.get, "#{doctype}", ctx.root.source_id)
            if not ok then return nil end
            return util.json_decode(doc.content).name
          end
          function export.compute_count(ctx)
            local ok, res = pcall(document.list, "#{doctype}")
            if not ok then return -1 end
            return res.total
          end
          return export
        LUA
        definition = create_compute_doctype(db, domain, doctype, script, {
          "mirror" => {"mirror", ["name"]},
          "count"  => {"count", ["name"]},
        })

        created = Facet::Document::Create.call(db, domain, doctype,
          %({"name": "source doc"}), Facet::RBAC::AuthContext.system)
        created.should be_a(Facet::Document::Create::Result)
        source_id = created.as(Facet::Document::Create::Result).projection.id

        result, errors = Compute.call(
          script,
          definition,
          JSON.parse(%({"name": "reader", "source_id": "#{source_id}"})),
          changed_fields: nil,
          actioner_id: "test",
          db: db,
          domain: domain,
        )

        errors.should be_empty
        result["mirror"].as_s.should eq("source doc")
        # The reader document itself is not persisted yet — only the source
        # document is live at this point.
        result["count"].as_i64.should eq(1)
      end
    end

    it "refuses document.create, document.update and document.delete with a clear error" do
      with_temp_doctype do |db, domain, doctype|
        ensure_domain(db, domain)
        script = <<-LUA
          local export = {}
          function export.compute_try_writes(ctx)
            local out = {}
            local ok1, err1 = pcall(document.create, "#{doctype}", '{"name": "nope"}')
            table.insert(out, ok1 and "create-succeeded" or tostring(err1))
            local ok2, err2 = pcall(document.update, "#{doctype}", "abc", '{"name": "nope"}')
            table.insert(out, ok2 and "update-succeeded" or tostring(err2))
            local ok3, err3 = pcall(document.delete, "#{doctype}", "abc")
            table.insert(out, ok3 and "delete-succeeded" or tostring(err3))
            return table.concat(out, "|")
          end
          return export
        LUA
        definition = create_compute_doctype(db, domain, doctype, script, {
          "try_writes" => {"try_writes", ["name"]},
        })

        result, errors = Compute.call(
          script,
          definition,
          JSON.parse(%({"name": "x"})),
          changed_fields: nil,
          actioner_id: "test",
          db: db,
          domain: domain,
        )

        errors.should be_empty
        verdict = result["try_writes"].as_s
        verdict.should contain "computed fields must not write — use an action or a hook"
        verdict.should_not contain "succeeded"
      end
    end

    it "exposes the staged children through ctx.children" do
      definition = Doctype::DoctypeDefinition.new(
        doctype: "TestDoc",
        domain: "test",
        fields: {
          "name"  => Doctype::FieldDefinition.new(type: Doctype::FieldType.parse("string")),
          "total" => Doctype::FieldDefinition.new(
            type: Doctype::FieldType.parse("data"),
            compute: "total",
            compute_when: ["lines"],
          ),
        },
        script: <<-LUA
          local export = {}
          function export.compute_total(ctx)
            local total = 0
            for _, line in ipairs((ctx.children or {}).lines or {}) do
              total = total + (line.qty or 0)
            end
            return total
          end
          return export
        LUA
      )

      staged = {
        "lines" => [JSON.parse(%({"qty": 2})), JSON.parse(%({"qty": 3}))] of JSON::Any,
      }
      result, errors = Compute.call(
        definition.script.not_nil!,
        definition,
        JSON.parse(%({"name": "order"})),
        changed_fields: Set{"lines"},
        actioner_id: "test",
        children: staged,
      )

      errors.should be_empty
      result["total"].as_i64.should eq(5)
    end
  end
end

# Registers a compute-only doctype through the authoring path and returns
# the stored definition. `fields` maps computed field name to its compute
# suffix and compute_when list; a `name` string field is always present as
# a trigger.
private def create_compute_doctype(
  db : DB::Connection,
  domain : String,
  doctype : String,
  script : String,
  fields : Hash(String, Tuple(String, Array(String))),
) : Facet::Doctype::DoctypeDefinition
  fields_def = {"name" => JSON.parse(%({"type": "string"}))} of String => JSON::Any
  fields.each do |name, spec|
    compute, compute_when = spec
    fields_def[name] = JSON.parse(%({"type": "data", "compute": "#{compute}", "compute_when": #{compute_when.to_json}}))
  end
  defn = {
    "doctype" => doctype,
    "domain" => domain,
    "aggregate_root" => true, "search" => "{{ display_name }}",
    "fields" => fields_def,
    "script" => script,
  }.to_json
  result = Facet::Document::Create.call(db, "core", "DocType", defn, Facet::RBAC::AuthContext.system)
  result.should be_a(Facet::Document::Create::Result)
  Facet::Doctype::DefinitionStore.fetch!(db, "#{domain}.#{doctype}").as(Facet::Doctype::DoctypeDefinition)
end
