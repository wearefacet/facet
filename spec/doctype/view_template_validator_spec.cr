# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

# A Widget-shaped definition: a nested
# object field, array fields (string / integer items / object items), a
# dictionary and a computed field.
private def binding_definition
  Facet::Doctype::DoctypeDefinition.from_json(%({
    "doctype": "Widget",
    "domain": "test-domain",
    "schema_version": 1,
    "fields": {
      "title": {"type": "string", "required": true},
      "priority": {"type": "integer"},
      "status": {"type": "enum", "values": [{"key": "draft"}, {"key": "active"}]},
      "due_date": {"type": "date"},
      "window": {"type": "period"},
      "days": {"type": "dateperiod"},
      "owner_id": {"type": "reference", "doctype": "iam.Account"},
      "cost": {"type": "money"},
      "description": {"type": "longtext"},
      "is_remote": {"type": "boolean"},
      "tags": {"type": "array", "items": {"type": "string"}},
      "scores": {"type": "array", "items": {"type": "integer"}},
      "members": {"type": "array", "items": {"type": "object", "properties": {
        "name": {"type": "string"}
      }}},
      "config": {"type": "object", "properties": {
        "enabled": {"type": "boolean"},
        "version": {"type": "string"}
      }},
      "metadata": {"type": "dictionary", "values": {"type": "string"}},
      "computed": {"type": "data", "compute": "build"},
      "manual": {"type": "file"},
      "website": {"type": "url"},
      "readonly_note": {"type": "string", "read_only": true}
    }
  }))
end

module Facet::Doctype
  describe ViewTemplateValidator do
    # ── Trivial inputs ────────────────────────────────────────────────

    it "returns no issues for nil (the template field is optional)" do
      ViewTemplateValidator.validate(nil).should be_empty
    end

    it "returns no issues for a valid tree" do
      template = JSON.parse(%({
        "type": "tabs",
        "tabs": [
          { "type": "tab", "label": "Identity", "children": [
            { "type": "section", "label": "Name", "children": [
              { "type": "field", "label": "Full name", "value": "$full_name" },
              { "type": "capsule", "value": "$status" }
            ]}
          ]}
        ]
      }))
      ViewTemplateValidator.validate(template).should be_empty
    end

    # ── Node-level structure ──────────────────────────────────────────

    it "errors on a node that is not an object" do
      issues = ViewTemplateValidator.validate(JSON.parse(%([1, 2])))
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
    end

    it "errors on a node without a type discriminator" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"label": "no type"})))
      issues.first.severity.should eq(:error)
      issues.first.path.should eq("template.type")
      # The message names the keys the node actually carried — a truncated
      # or mis-shaped payload is diagnosable from the error alone.
      issues.first.message.should contain("received keys: label")
    end

    it "names an empty node in the discriminator error" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({})))
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("the node is empty")
    end

    it "warns on an unknown node type" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "marquee", "value": "x"})))
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.message.should contain("unknown template node type 'marquee'")
    end

    it "errors on an input node missing its field binding" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "label": "Broken" }
        ]
      })))
      field_issues = issues.select { |i| i.path == "template.children.0.field" }
      field_issues.size.should eq(1)
      field_issues.first.severity.should eq(:error)
      field_issues.first.message.should contain("'input-text' node is missing required 'field'")
    end

    it "errors on a col without children" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "col"})))
      issues.size.should eq(1)
      issues.first.path.should eq("template.children")
    end

    it "accepts a markdown node bound to a field" do
      template = JSON.parse(%({
        "type": "section",
        "label": "Body",
        "children": [
          { "type": "markdown", "field": "description" }
        ]
      }))
      ViewTemplateValidator.validate(template).should be_empty
    end

    it "errors on a markdown node missing its field binding" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "markdown"})))
      issues.size.should eq(1)
      issues.first.path.should eq("template.field")
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("'markdown' node is missing required 'field'")
    end

    it "errors on a required string property of the wrong shape" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "title", "value": 42})))
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("'value' must be a non-empty string")
    end

    # ── Recursion ─────────────────────────────────────────────────────

    it "walks nested children and reports deep paths" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "grid",
        "layout": "1 1",
        "children": [
          { "type": "col", "children": [
            { "type": "if", "field": "status", "children": [
              { "type": "label" }
            ]}
          ]}
        ]
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.children.0.children.0.children.0.value")
      issues.first.severity.should eq(:error)
    end

    it "walks the else branch of an if node" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "if",
        "field": "active",
        "children": [{ "type": "label", "value": "yes" }],
        "else": [{ "type": "capsule" }]
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.else.0.value")
    end

    it "walks optional field children" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "field",
        "label": "Email",
        "value": "$email",
        "children": [{ "type": "email", "href": "$email" }]
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.children.0.label")
    end

    # ── Tabs ──────────────────────────────────────────────────────────

    it "errors on a tab entry missing a label" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "tabs",
        "tabs": [{ "type": "tab", "children": [] }]
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.tabs.0.label")
    end

    it "errors on a non-array tabs property" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "tabs", "tabs": "main"})))
      issues.size.should eq(1)
      issues.first.message.should contain("'tabs' must be an array")
    end

    it "warns on an unknown array layout value" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "array", "field": "tags", "layout": "grid",
        "children": [{ "type": "label", "value": "$value" }]
      })))
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.layout")
    end

    it "accepts the known array layout values" do
      {"inline", "stack"}.each do |layout|
        issues = ViewTemplateValidator.validate(JSON.parse(%({
          "type": "array", "field": "tags", "layout": "#{layout}",
          "children": [{ "type": "label", "value": "$value" }]
        })))
        issues.select(&.severity.==(:error)).empty?.should be_true
        issues.map(&.path).should_not contain("template.layout")
      end
    end

    # ── input-select options ──────────────────────────────────────────

    it "errors on input-select without options" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "input-select", "field": "status", "label": "Status"
      })))
      issues.map(&.path).should contain("template.options")
    end

    it "warns on an empty options array" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "input-select", "field": "status", "label": "Status", "options": []
      })))
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
    end

    it "errors on an option entry missing value or label" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "input-select", "field": "status", "label": "Status",
        "options": [{ "value": "open" }, { "value": "closed", "label": "Closed" }]
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.options.0.label")
    end

    # ── relation ──────────────────────────────────────────────────────

    it "errors on a relation source of unknown kind" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "magic" }
      })))
      issues.size.should eq(1)
      issues.first.path.should eq("template.source.kind")
    end

    it "errors on a children source without rel" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children" }
      })))
      issues.first.path.should eq("template.source.rel")
    end

    it "errors on a filter source without field" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "filter" }
      })))
      issues.first.path.should eq("template.source.field")
    end

    it "warns on an unknown relation view" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "carousel"
      })))
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.view")
    end

    it "warns when a dotted relation column is marked editable" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "table",
        "columns": [
          { "key": "contact.primary_flag", "label": "Primary", "editable": true },
          { "key": "stage_done", "label": "Done", "editable": true }
        ]
      })))
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.columns.0.editable")
    end

    it "errors on a string relation column (B-114)" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "table",
        "columns": ["stage"]
      })))
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.path.should eq("template.columns.0")
      issues.first.message.should eq("column must be an object with 'key'")
    end

    it "errors on a relation column without a non-empty key (B-114)" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "table",
        "columns": [
          { "label": "No key" },
          { "key": "", "label": "Empty key" }
        ]
      })))
      issues.size.should eq(2)
      issues.all?(&.severity.==(:error)).should be_true
      issues[0].path.should eq("template.columns.0.key")
      issues[1].path.should eq("template.columns.1.key")
    end

    it "passes a valid relation table through the column checks (B-114)" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "table",
        "columns": [
          { "key": "stage", "label": "Stage" },
          { "key": "contact.name", "label": "Contact" }
        ]
      })))
      issues.size.should eq(0)
    end

    it "warns on duplicate relation column keys (F10-M)" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "relation", "label": "Deals", "doctype": "crm.Deal",
        "source": { "kind": "children", "rel": "deals" },
        "view": "table",
        "columns": [
          { "key": "stage", "label": "Stage" },
          { "key": "stage", "label": "Stage again" },
          { "key": "stage", "label": "Stage once more" },
          { "key": "owner", "label": "Owner" }
        ]
      })))
      issues.size.should eq(2)
      issues.all?(&.severity.==(:warning)).should be_true
      issues[0].path.should eq("template.columns.1.key")
      issues[0].message.should contain("duplicate relation column 'stage'")
      issues[0].message.should contain("collapses duplicates to the first occurrence")
      issues[1].path.should eq("template.columns.2.key")
    end

    # ── errors helper ─────────────────────────────────────────────────

    it ".errors keeps only :error issues" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "label": "Broken" },
          { "type": "marquee", "value": "x" }
        ]
      })))
      errors = ViewTemplateValidator.errors(issues)
      errors.size.should eq(1)
      errors.first.path.should eq("template.children.0.field")
    end

    # ── Definition-aware binding checks ───────────────────────────

    it "accepts a form bound to defined fields (object wrapper, bare sub-fields, input-list)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "field": "title", "label": "Title" },
          { "type": "input-list", "field": "tags", "label": "Tags" },
          { "type": "object", "field": "config", "children": [
            { "type": "input-toggle", "field": "enabled", "label": "Enabled" },
            { "type": "input-text", "field": "version", "label": "Version" }
          ]}
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    # ── Auto `input` node ─────────────────────────────────────────────

    it "accepts an auto input node bound to scalar fields (label optional, derives)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input", "field": "title" },
          { "type": "input", "field": "status", "label": "Status", "helper": "Workflow state" }
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "errors on an auto input node missing its field binding" do
      issues = ViewTemplateValidator.validate(JSON.parse(%({"type": "input"})))
      issues.size.should eq(1)
      issues.first.path.should eq("template.field")
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("'input' node is missing required 'field'")
    end

    it "errors on an auto input node with a dotted binding" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input", "field": "config.enabled" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("dotted field paths are not supported")
    end

    it "errors on an auto input node bound to an unknown field" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input", "field": "nope" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("not a defined field")
    end

    it "errors on an auto input node bound to each container type" do
      {"tags" => "array", "config" => "object", "metadata" => "dictionary", "computed" => "data"}.each do |field, type_name|
        template = JSON.parse(%({
          "type": "col",
          "children": [
            { "type": "input", "field": "#{field}" }
          ]
        }))
        issues = ViewTemplateValidator.validate(template, binding_definition)
        issues.size.should eq(1), "#{type_name}: expected one issue"
        issues.first.severity.should eq(:error), "#{type_name}: expected an error"
        issues.first.message.should contain("'input' node cannot bind '#{field}'"), type_name
      end
    end

    it "warns on any input node bound to a read_only field" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input", "field": "readonly_note", "label": "Note" },
          { "type": "input-text", "field": "readonly_note", "label": "Note" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(2)
      issues.all?(&.severity.==(:warning)).should be_true
      issues.map(&.message).join(' ').should contain("read_only")
    end

    it "errors on a dotted input binding (the config.enabled authoring bug)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-toggle", "field": "config.enabled", "label": "Enabled" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.path.should eq("template.children.0.field")
      issues.first.message.should contain("dotted field paths are not supported")
    end

    it "errors on an input bound to an unknown field" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "field": "nope", "label": "Nope" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("not a defined field")
    end

    it "errors on a scalar input bound to an array field (the tags authoring bug)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "field": "tags", "label": "Tags" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("'input-list'")
    end

    it "errors on a scalar input bound to a computed (data) field" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-text", "field": "computed", "label": "Computed" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:error)
      issues.first.message.should contain("read-only")
    end

    it "warns on an input/field-type affinity mismatch with a suggestion" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-toggle", "field": "status", "label": "Status" },
          { "type": "input-money", "field": "title", "label": "Title" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(2)
      issues.all?(&.severity.==(:warning)).should be_true
      # Suggestions point at the auto node first; the specialized node names
      # the control the override forces.
      issues.map(&.message).join(' ').should contain("use 'input' — it renders 'input-select' for this field type")
      issues.map(&.message).join(' ').should contain("use 'input' — it renders 'input-text' for this field type")
    end

    it "warns on input-list bound to a non-array or to object-item arrays" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-list", "field": "title", "label": "Title as list" },
          { "type": "input-list", "field": "scores", "label": "Scores" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(2)
      issues.all?(&.severity.==(:warning)).should be_true
    end

    # ── Date / range inputs ──────────────────────────────────────

    it "accepts the date and range input nodes bound to their field types" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-date", "field": "due_date", "label": "Due date" },
          { "type": "input-period", "field": "window", "label": "Window" },
          { "type": "input-dateperiod", "field": "days", "label": "Days" }
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "errors on the date and range input nodes missing their label" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-date", "field": "due_date" },
          { "type": "input-period", "field": "window" },
          { "type": "input-dateperiod", "field": "days" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(3)
      issues.all?(&.severity.==(:error)).should be_true
    end

    it "warns on input-datetime bound to a date field (the picker cannot save YYYY-MM-DD)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-datetime", "field": "due_date", "label": "Due date" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.message.should contain("it renders 'input-date' for this field type")
    end

    it "warns on range inputs bound to the wrong range or scalar types" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-period", "field": "days", "label": "Period over dateperiod" },
          { "type": "input-dateperiod", "field": "window", "label": "Dateperiod over period" },
          { "type": "input-date", "field": "computed", "label": "Date over computed" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      # The computed binding is a container/computed `:error`; the two range
      # mismatches are affinity `:warning`s.
      issues.size.should eq(3)
      warnings = issues.select(&.severity.==(:warning))
      warnings.map(&.message).join(' ').should contain("it renders 'input-dateperiod' for this field type")
      warnings.map(&.message).join(' ').should contain("it renders 'input-period' for this field type")
    end

    it "warns on input bindings inside a scalar-array scope instead of erroring" do
      # Inside an array node the scope shifts to the (scalar) items —
      # bindings there cannot be validated and must stay unchecked.
      template = JSON.parse(%({
        "type": "array", "field": "tags", "children": [
          { "type": "label", "value": "$value" }
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "accepts an if node over any resolvable field type" do
      # `if` tests truthiness or equality — it does not iterate, so any
      # field type (boolean, array, object) is a legitimate conditional.
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "if", "field": "is_remote", "children": [
            { "type": "label", "value": "on" }
          ]},
          { "type": "if", "field": "tags", "children": [
            { "type": "label", "value": "some" }
          ]},
          { "type": "if", "field": "config", "children": [
            { "type": "label", "value": "set" }
          ]}
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "accepts bare input bindings inside an object wrapper and array item scope" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "object", "field": "config", "children": [
            { "type": "input-text", "field": "version", "label": "Version" }
          ]},
          { "type": "array", "field": "members", "children": [
            { "type": "input-text", "field": "name", "label": "Name" }
          ]}
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "warns on object/array/dict/if wrappers targeting unknown fields" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "object", "field": "nope", "children": [
            { "type": "input-text", "field": "version", "label": "Version" }
          ]},
          { "type": "array", "field": "missing", "children": [
            { "type": "label", "value": "$value" }
          ]},
          { "type": "dict", "field": "absent", "children": [
            { "type": "label", "value": "$key" }
          ]},
          { "type": "if", "field": "ghost", "children": [
            { "type": "label", "value": "x" }
          ]}
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(4)
      issues.all?(&.severity.==(:warning)).should be_true
      issues.map(&.path).should eq([
        "template.children.0.field",
        "template.children.1.field",
        "template.children.2.field",
        "template.children.3.field",
      ])
    end

    it "warns on wrappers targeting the wrong shape (object over scalar, array over object)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "object", "field": "title", "children": [
            { "type": "label", "value": "$x" }
          ]},
          { "type": "array", "field": "config", "children": [
            { "type": "label", "value": "$x" }
          ]},
          { "type": "dict", "field": "status", "children": [
            { "type": "label", "value": "$key" }
          ]}
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(3)
      issues.all?(&.severity.==(:warning)).should be_true
    end

    it "does not flag dotted bindings without a definition (structural-only call)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "input-toggle", "field": "config.enabled", "label": "Enabled" }
        ]
      }))
      ViewTemplateValidator.validate(template).should be_empty
    end

    it "warns on a link node interpolating a file field into href" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "link", "href": "$manual", "label": "Open the manual" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.children.0.href")
      issues.first.message.should contain("artifact id, not a URL")
      issues.first.message.should contain("image-artifact")
    end

    it "warns on an image node interpolating a file field into src" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "image", "src": "$manual", "alt": "Manual cover" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.children.0.src")
    end

    it "warns on an email node interpolating a file field into href" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "email", "href": "$manual", "label": "Email" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.severity.should eq(:warning)
      issues.first.path.should eq("template.children.0.href")
    end

    it "warns once when a url prop interpolates several file fields" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "link", "href": "/files/$manual/$website", "label": "Docs" }
        ]
      }))
      issues = ViewTemplateValidator.validate(template, binding_definition)
      issues.size.should eq(1)
      issues.first.message.should contain("'manual'")
    end

    it "accepts a link interpolating a url field" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "link", "href": "$website", "label": "Website" }
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end

    it "does not flag url interpolations without a definition (structural-only call)" do
      template = JSON.parse(%({
        "type": "col",
        "children": [
          { "type": "link", "href": "$manual", "label": "Open the manual" },
          { "type": "image", "src": "$manual", "alt": "Manual cover" }
        ]
      }))
      ViewTemplateValidator.validate(template).should be_empty
    end

    it "resolves dotted scope targets through nested object properties" do
      template = JSON.parse(%({
        "type": "object", "field": "config", "children": [
          { "type": "label", "value": "$version" }
        ]
      }))
      ViewTemplateValidator.validate(template, binding_definition).should be_empty
    end
  end
end
