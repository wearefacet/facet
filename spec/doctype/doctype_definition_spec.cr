# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "json"
require "../../src/doctype"

module Facet::Doctype
  describe DoctypeDefinition do
    # ── Identity validation ───────────────────────────────────────────

    it "parses a minimal root doctype definition" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.doctype.should eq("WorkOrder")
      defn.domain.should eq("production")
      defn.schema_version.should eq(1)
      defn.aggregate_root.should be_false
      defn.member_of.should be_nil
      defn.description.should be_nil
      defn.icon.should be_nil
      defn.fields.should be_empty
      defn.actions.should be_empty
      defn.qualified_name.should eq("production.WorkOrder")
    end

    it "rejects doctype starting with a digit" do
      json = %({ "doctype": "1BadOrder", "domain": "production" })
      expect_raises(JSON::ParseException, /CamelCase/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects doctype with lowercase start" do
      json = %({ "doctype": "workOrder", "domain": "production" })
      expect_raises(JSON::ParseException, /CamelCase/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects domain starting with uppercase" do
      json = %({ "doctype": "WorkOrder", "domain": "Production" })
      expect_raises(JSON::ParseException, /lowercase/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects missing doctype" do
      json = %({ "domain": "production" })
      expect_raises(JSON::ParseException, /Missing required field 'doctype'/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects missing domain" do
      json = %({ "doctype": "WorkOrder" })
      expect_raises(JSON::ParseException, /Missing required field 'domain'/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects invalid schema_version" do
      json = %({ "doctype": "WorkOrder", "domain": "production", "schema_version": 0 })
      expect_raises(JSON::ParseException, />= 1/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── aggregate_root / member_of ──────────────────────────────────

    it "parses an aggregate_root doctype" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true
      })
      defn = DoctypeDefinition.from_json(json)
      defn.aggregate_root.should be_true
      defn.child_doctype?.should be_false
    end

    it "parses a child doctype with member_of" do
      json = %({
        "doctype": "Operation",
        "domain": "production",
        "aggregate_root": false,
        "member_of": "WorkOrder"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.aggregate_root.should be_false
      defn.member_of.should eq("WorkOrder")
      defn.child_doctype?.should be_true
    end

    it "rejects invalid member_of format" do
      json = %({ "doctype": "Operation", "domain": "production", "member_of": "workOrder" })
      expect_raises(JSON::ParseException, /CamelCase/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── Empty string is an absent string ────────────────────────────

    it "normalizes an empty optional string to nil (script, label, description)" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "label": "",
        "description": "",
        "script": ""
      })
      defn = DoctypeDefinition.from_json(json)
      defn.label.should be_nil
      defn.description.should be_nil
      defn.script.should be_nil
      defn.script?.should be_false
    end

    it "normalizes an empty template or metadata string to nil (search, display_name, color, icon, plural_label, surface)" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "search": "",
        "display_name": "",
        "color": "",
        "icon": "",
        "plural_label": "",
        "surface": ""
      })
      defn = DoctypeDefinition.from_json(json)
      defn.search.should be_nil
      defn.display_name.should be_nil
      defn.color.should be_nil
      defn.icon.should be_nil
      defn.plural_label.should be_nil
      defn.surface.should be_nil
    end

    it "still answers 422 when an optional string carries the wrong type" do
      json = %({ "doctype": "WorkOrder", "domain": "production", "icon": 42 })
      expect_raises(JSON::ParseException, /'icon' must be a string/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── Actions ─────────────────────────────────────────────────────

    it "parses actions" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "actions": {
          "release": {
            "args": {
              "comment": { "type": "string" }
            }
          },
          "start": {
            "args": {}
          },
          "complete": {
            "args": {}
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.actions.size.should eq(3)
      defn.actions.keys.should contain("release")
      defn.actions.keys.should contain("start")
      defn.actions.keys.should contain("complete")
      defn.actions.keys.should contain("release")
      defn.actions["release"].args.size.should eq(1)
      defn.actions["release"].args["comment"].type.type_name.should eq("string")
    end

    it "rejects reserved action names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "actions": {
          "validate": { "args": {} }
        }
      })
      expect_raises(JSON::ParseException, /reserved/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects create action" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "actions": {
          "create": { "args": {} }
        }
      })
      expect_raises(JSON::ParseException, /reserved/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects update action" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "actions": {
          "update": { "args": {} }
        }
      })
      expect_raises(JSON::ParseException, /reserved/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── Display / icon ────────────────────────────────────────────────

    it "parses an optional label" do
      json = %({
        "doctype": "CompanyMembership",
        "domain": "crm",
        "label": "Membership"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.label.should eq("Membership")
    end

    it "round-trips label through to_json when present" do
      json = %({
        "doctype": "CompanyMembership",
        "domain": "crm",
        "label": "Membership"
      })
      defn = DoctypeDefinition.from_json(json)
      serialized = defn.to_json
      serialized.should contain("\"label\":\"Membership\"")
    end

    it "omits label from to_json when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.to_json.should_not contain("\"label\"")
    end

    it "rejects a non-string label" do
      json = %({ "doctype": "WorkOrder", "domain": "production", "label": 5 })
      expect_raises(JSON::ParseException, /'label' must be a string/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "parses an optional icon identifier" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "icon": "wrench"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.icon.should eq("wrench")
    end

    it "round-trips icon through to_json when present" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "icon": "building-2"
      })
      defn = DoctypeDefinition.from_json(json)
      serialized = defn.to_json
      serialized.should contain("\"icon\":\"building-2\"")
    end

    it "omits icon from to_json when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.to_json.should_not contain("\"icon\"")
    end

    # ── plural_label / sensitive ──────────────────────────────────────

    it "parses an optional plural_label" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "plural_label": "contacts"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.plural_label.should eq("contacts")
    end

    it "round-trips plural_label through to_json when present" do
      json = %({
        "doctype": "CompanyMembership",
        "domain": "crm",
        "plural_label": "company memberships"
      })
      defn = DoctypeDefinition.from_json(json)
      serialized = defn.to_json
      serialized.should contain("\"plural_label\":\"company memberships\"")
    end

    it "omits plural_label from to_json when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.to_json.should_not contain("\"plural_label\"")
    end

    # ── doctype-level color ─────────────────────────────────────────

    it "parses a doctype-level color" do
      json = %({
        "doctype": "DocType",
        "domain": "core",
        "color": "#1565C0"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.color.should eq("#1565C0")
    end

    it "round-trips a doctype-level color through to_json" do
      json = %({
        "doctype": "DocType",
        "domain": "core",
        "color": "#1565C0"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.to_json.should contain("\"color\":\"#1565C0\"")
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.color.should eq("#1565C0")
    end

    it "omits doctype color from to_json when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.color.should be_nil
      defn.to_json.should_not contain("\"color\"")
    end

    it "rejects a non-string doctype color" do
      json = %({ "doctype": "WorkOrder", "domain": "production", "color": 5 })
      expect_raises(JSON::ParseException, /color must be a string/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "defaults sensitive to false when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.sensitive.should be_false
      defn.to_json.should_not contain("\"sensitive\"")
    end

    it "omits field tags from to_json when unset" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "code": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["code"].tags.should be_nil
      defn.to_json.should_not contain("\"tags\"")
    end

    it "round-trips field tags through to_json when present" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "salary": { "type": "money", "tags": ["confidential"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["salary"].tags.should eq(["confidential"])
      defn.to_json.should contain("\"tags\":[\"confidential\"]")
    end

    it "parses and round-trips sensitive when true" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sensitive": true
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sensitive.should be_true
      serialized = defn.to_json
      serialized.should contain("\"sensitive\":true")
    end

    it "treats sensitive: false as absent on the wire" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sensitive": false
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sensitive.should be_false
      defn.to_json.should_not contain("\"sensitive\"")
    end

    # ── nav_visible ──────────────────────────────────────────────────

    it "defaults nav_visible to false when absent" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.nav_visible.should be_false
      defn.to_json.should_not contain("\"nav_visible\"")
    end

    it "parses and round-trips nav_visible when true" do
      json = %({
        "doctype": "CompanyMembership",
        "domain": "crm",
        "member_of": "Company",
        "nav_visible": true
      })
      defn = DoctypeDefinition.from_json(json)
      defn.nav_visible.should be_true
      serialized = defn.to_json
      serialized.should contain("\"nav_visible\":true")
    end

    # ── Fields ──────────────────────────────────────────────────────

    it "parses a string field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "code": { "type": "string", "required": true, "unique": true, "filters": ["equality", "text_search"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["code"]
      field.type.not_nil!.type_name.should eq("string")
      field.required.should be_true
      field.unique.should be_true
      field.operators.should eq([Operator::Eq, Operator::Match, Operator::StartsWith])
    end

    it "parses an enum field with values and default" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "status": {
            "type": "enum",
            "values": ["planned", "released", "in_progress", "done", "cancelled"],
            "default": "planned",
            "filters": ["equality"]
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["status"]
      field.type.not_nil!.type_name.should eq("enum")
      field.values.should be_a(Array(Facet::Doctype::EnumValue))
      keys = field.values.not_nil!.map(&.key)
      keys.should eq(["planned", "released", "in_progress", "done", "cancelled"])
      field.default.should eq(JSON::Any.new("planned"))
      field.operators.should eq([Operator::Eq, Operator::In])
    end

    it "parses an enum field with object values" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "status": {
            "type": "enum",
            "values": [
              {"key": "planned", "label": "Planned", "color": "#E91E63"},
              {"key": "in_progress"}
            ],
            "default": "planned",
            "filters": ["equality"]
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["status"]
      field.type.not_nil!.type_name.should eq("enum")
      evs = field.values.not_nil!
      evs.size.should eq(2)
      evs[0].key.should eq("planned")
      evs[0].label.should eq("Planned")
      evs[0].color.should eq("#E91E63")
      evs[1].key.should eq("in_progress")
      evs[1].label.should be_nil
      field.default.should eq(JSON::Any.new("planned"))
      field.operators.should eq([Operator::Eq, Operator::In])
    end

    it "round-trips custom enum label and color through to_json" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "status": {
            "type": "enum",
            "values": [
              { "key": "in_progress", "label": "Currently In Progress", "color": "#FF8800" }
            ]
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      serialized = defn.to_json
      serialized.should contain("\"label\":\"Currently In Progress\"")
      serialized.should contain("\"color\":\"#FF8800\"")

      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      ev = roundtrip.fields["status"].values.not_nil![0]
      ev.label.should eq("Currently In Progress")
      ev.color.should eq("#FF8800")
    end

    # ── Derived operator metadata: the type-specific supplements ────

    # `in` is the set-membership form of equality on an enum field, and
    # `ne` is the "is not" half of equality on a boolean / reference
    # field. Both ride the same btree as `eq`, so the derived metadata
    # advertises them whenever `eq` is declared — the frontend filter bar
    # mirrors exactly this set.
    describe "derived operators" do
      it "advertises in on an enum field and keeps the declaration order" do
        fd = FieldDefinition.from_json(
          %({"type": "enum", "values": ["a", "b"], "filters": ["comparison", "text_search"]}))
        fd.operators.should eq([
          Operator::Eq, Operator::Ne, Operator::Gt, Operator::Gte,
          Operator::Lt, Operator::Lte, Operator::Between, Operator::In,
          Operator::Match, Operator::StartsWith,
        ])
      end

      it "advertises in on an enum field that declares equality" do
        fd = FieldDefinition.from_json(
          %({"type": "enum", "values": ["a", "b"], "filters": ["equality"]}))
        fd.operators.should eq([Operator::Eq, Operator::In])
      end

      it "advertises ne on boolean and reference fields that declare equality" do
        boolean_fd = FieldDefinition.from_json(%({"type": "boolean", "filters": ["equality"]}))
        boolean_fd.operators.should eq([Operator::Eq, Operator::Ne])

        reference_fd = FieldDefinition.from_json(
          %({"type": "reference", "doctype": "iam.Account", "filters": ["equality"]}))
        reference_fd.operators.should eq([Operator::Eq, Operator::Ne])
      end

      it "does not advertise in on other field types" do
        string_fd = FieldDefinition.from_json(
          %({"type": "string", "filters": ["comparison", "text_search"]}))
        string_fd.operators.should_not contain(Operator::In)

        integer_fd = FieldDefinition.from_json(%({"type": "integer", "filters": ["comparison"]}))
        integer_fd.operators.should_not contain(Operator::In)

        money_fd = FieldDefinition.from_json(%({"type": "money", "filters": ["comparison", "currency"]}))
        money_fd.operators.should_not contain(Operator::In)
      end

      it "keeps the empty set for a field with no declared filters" do
        fd = FieldDefinition.from_json(%({"type": "enum", "values": ["a"]}))
        fd.operators.should be_empty
      end

      it "parses the in suffix" do
        Operator.parse_suffix("__in").should eq(Operator::In)
        Operator.parse("in").should eq(Operator::In)
        Operator::In.suffix.should eq("__in")
      end

      it "stamps in onto raw definition content like the struct derivation" do
        raw = JSON.parse(%({
          "doctype": "WorkOrder",
          "domain": "production",
          "fields": {
            "status": {"type": "enum", "values": ["a"], "filters": ["equality"]},
            "name": {"type": "string", "filters": ["equality", "text_search"]}
          }
        }))
        stamped = DerivedOperators.apply(raw)
        status_ops = stamped["fields"]["status"]["operators"].as_a.map(&.as_s)
        status_ops.should eq(["eq", "in"])
        name_ops = stamped["fields"]["name"]["operators"].as_a.map(&.as_s)
        name_ops.should eq(["eq", "match", "starts_with"])
      end
    end

    it "omits enum label and color equal to the derived defaults" do
      ev = EnumValue.new(key: "planned", label: "Planned", color: Util::Color.hash_color("planned"))
      ev.to_json.should_not contain("\"label\"")
      ev.to_json.should_not contain("\"color\"")
      # The derived default still resolves on read.
      parsed = EnumValue.from_json(ev.to_json)
      parsed.effective_label.should eq("Planned")
      parsed.effective_color.should eq(Util::Color.hash_color("planned"))
    end

    it "parses an integer field with min constraint" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "quantity": { "type": "integer", "required": true, "min": 1 }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["quantity"]
      field.type.not_nil!.type_name.should eq("integer")
      field.required.should be_true
      field.min.should eq(1_i64)
    end

    it "parses a datetime field and derives the comparison operator family" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "due_at": { "type": "datetime", "filters": ["comparison"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["due_at"]
      field.type.not_nil!.type_name.should eq("datetime")
      # `comparison` fans out to the full filter family.
      field.operators.should eq([Operator::Eq, Operator::Ne, Operator::Gt, Operator::Gte, Operator::Lt, Operator::Lte, Operator::Between])
    end

    it "parses a datetime field and derives the between operator from comparison" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "due_at": { "type": "datetime", "filters": ["comparison"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["due_at"]
      # `comparison` includes `between` in its derived family.
      field.operators.should contain(Operator::Between)
    end

    it "parses a money field with confidential view" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "est_cost": { "type": "money", "tags": ["confidential"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["est_cost"]
      field.type.not_nil!.type_name.should eq("money")
      field.tags.should eq(["confidential"])
    end

    it "parses a boolean field with default" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "is_rework": { "type": "boolean", "default": false }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["is_rework"]
      field.type.not_nil!.type_name.should eq("boolean")
      field.default.should eq(JSON::Any.new(false))
    end

    it "parses an object field (free-form jsonb)" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "specs": { "type": "object" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["specs"]
      field.type.not_nil!.type_name.should eq("object")
    end

    it "parses children section" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "children": {
          "operations": { "doctype": "Operation", "collection": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.children.size.should eq(1)
      child = defn.children["operations"]
      child.doctype.should eq("Operation")
      child.collection?.should be_true
    end

    it "defaults children to empty" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.children.should be_empty
    end

    it "parses an inline reference field (implicit and explicit)" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "product":     { "doctype": "catalog.Product", "required": true },
          "assignee":    { "type": "reference", "doctype": "hr.Employee" }
        }
      })
      defn = DoctypeDefinition.from_json(json)

      # Implicit reference (doctype without type)
      product = defn.fields["product"]
      product.type.not_nil!.type_name.should eq("reference")
      product.doctype.should eq("catalog.Product")
      product.required.should be_true
      product.reference?.should be_true

      # Explicit reference
      assignee = defn.fields["assignee"]
      assignee.type.not_nil!.type_name.should eq("reference")
      assignee.doctype.should eq("hr.Employee")
      assignee.reference?.should be_true
    end

    it "parses a computed data field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "progress": {
            "type": "data",
            "compute": "wo_progress",
            "compute_when": ["operations"]
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["progress"]
      field.type.not_nil!.type_name.should eq("data")
      field.compute.should eq("wo_progress")
      field.compute_when.should eq(["operations"])
      field.computed?.should be_true
    end

    # ── Query helpers ────────────────────────────────────────────────

    it "returns reference field names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "product":  { "doctype": "catalog.Product" },
          "assignee": { "doctype": "hr.Employee" },
          "name":     { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.reference_field_names.should contain("product")
      defn.reference_field_names.should contain("assignee")
      defn.reference_field_names.should_not contain("name")
    end

    it "returns child relationship names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "children": {
          "operations": { "doctype": "Operation", "collection": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.child_field_names.should eq(["operations"])
    end

    it "returns computed field names" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "progress": { "type": "data", "compute": "wo_progress", "compute_when": ["operations"] },
          "name":     { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.computed_field_names.should eq(["progress"])
    end

    # ── Full example ─────────────────────────────────────────────────

    it "parses the full WorkOrder example from the specification" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 3,
        "aggregate_root": true,
        "fields": {
          "code":      { "type": "string",  "required": true, "unique": true, "filters": ["equality","text_search"] },
          "status":    { "type": "enum", "values": ["planned","released","in_progress","done","cancelled"],
                         "default": "planned", "filters": ["equality"] },
          "quantity":  { "type": "integer", "required": true, "min": 1 },
          "due_at":    { "type": "datetime", "filters": ["comparison"] },
          "priority":  { "type": "enum", "values": ["low","normal","high"], "default": "normal" },
          "est_cost":  { "type": "money", "tags": ["confidential"] },
          "is_rework": { "type": "boolean", "default": false },
          "specs":     { "type": "object" },
          "product": { "doctype": "catalog.Product", "required": true },
          "assignee":     { "doctype": "hr.Employee" },
          "parent_order": { "doctype": "WorkOrder" },
          "progress":  { "type": "data", "compute": "wo_progress", "compute_when": ["operations"] }
        },
        "children": {
          "operations": { "doctype": "Operation", "collection": true }
        },
        "actions": {
          "release":  { "args": {} },
          "start":    { "args": {} },
          "complete": { "args": {} }
        }
      })

      defn = DoctypeDefinition.from_json(json)

      # Identity
      defn.doctype.should eq("WorkOrder")
      defn.domain.should eq("production")
      defn.schema_version.should eq(3)
      defn.aggregate_root.should be_true
      defn.member_of.should be_nil
      defn.qualified_name.should eq("production.WorkOrder")

      # Fields
      defn.fields.size.should eq(12)
      defn.fields["code"].type.not_nil!.type_name.should eq("string")
      defn.fields["status"].type.not_nil!.type_name.should eq("enum")
      defn.fields["quantity"].type.not_nil!.type_name.should eq("integer")
      defn.fields["due_at"].type.not_nil!.type_name.should eq("datetime")
      defn.fields["priority"].type.not_nil!.type_name.should eq("enum")
      defn.fields["est_cost"].type.not_nil!.type_name.should eq("money")
      defn.fields["is_rework"].type.not_nil!.type_name.should eq("boolean")
      defn.fields["specs"].type.not_nil!.type_name.should eq("object")
      defn.fields["product"].type.not_nil!.type_name.should eq("reference")
      defn.fields["assignee"].type.not_nil!.type_name.should eq("reference")
      defn.fields["parent_order"].type.not_nil!.type_name.should eq("reference")
      defn.fields["progress"].type.not_nil!.type_name.should eq("data")
      defn.fields["progress"].compute.should eq("wo_progress")

      # Children
      defn.children.size.should eq(1)
      defn.children["operations"].doctype.should eq("Operation")
      defn.children["operations"].collection?.should be_true

      # Actions
      defn.actions.size.should eq(3)
      defn.actions.keys.should contain("release")
      defn.actions.keys.should contain("start")
      defn.actions.keys.should contain("complete")
    end

    it "parses the nested Operation doctype example" do
      json = %({
        "doctype": "Operation",
        "domain": "production",
        "aggregate_root": false,
        "member_of": "WorkOrder",
        "fields": {
          "seq":     { "type": "integer", "required": true, "filters": ["equality"] },
          "name":    { "type": "string",  "required": true },
          "state":   { "type": "enum", "values": ["pending","done"], "default": "pending", "filters": ["equality"] },
          "minutes": { "type": "integer" },
          "station": { "type": "reference", "doctype": "Workstation" }
        }
      })

      defn = DoctypeDefinition.from_json(json)

      defn.doctype.should eq("Operation")
      defn.domain.should eq("production")
      defn.aggregate_root.should be_false
      defn.member_of.should eq("WorkOrder")
      defn.child_doctype?.should be_true

      defn.fields.size.should eq(5)
      defn.fields["seq"].type.not_nil!.type_name.should eq("integer")
      defn.fields["station"].type.not_nil!.type_name.should eq("reference")
      defn.fields["station"].doctype.should eq("Workstation")
    end

    # ── Description ──────────────────────────────────────────────────

    it "parses description field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "description": "A work order document for tracking jobs."
      })
      defn = DoctypeDefinition.from_json(json)
      defn.description.should eq("A work order document for tracking jobs.")
    end

    it "serializes and deserializes description" do
      defn = DoctypeDefinition.new(
        doctype: "WorkOrder", domain: "production",
        description: "Some description"
      )
      parsed = DoctypeDefinition.from_json(defn.to_json)
      parsed.description.should eq("Some description")
    end

    it "allows description to be absent" do
      defn = DoctypeDefinition.new(doctype: "WorkOrder", domain: "production")
      defn.description.should be_nil
    end

    # ── longtext field type ──────────────────────────────────────────

    it "parses longtext field type" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "description": { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["description"]
      field.type.not_nil!.type_name.should eq("longtext")
    end

    it "serializes and deserializes longtext field type" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "body": { "type": "longtext" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.fields["body"].type.not_nil!.type_name.should eq("longtext")
    end

    # ── Unknown top-level keys ──────────────────────────────────────

    it "rejects unknown top-level keys" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "colour": "#1565C0"
      })
      ex = expect_raises(JSON::ParseException, /Unknown key\(s\) in doctype definition/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'colour'")
    end

    it "names every unknown top-level key in the rejection" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "totally_bogus_key": 1,
        "colour": "#1565C0"
      })
      ex = expect_raises(JSON::ParseException, /Unknown key/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'colour'")
      ex.message.not_nil!.should contain("'totally_bogus_key'")
    end

    it "rejects unknown top-level keys before any value parsing" do
      # A typo'd key must surface as unknown-key, not as a downstream
      # type error on the value it carries.
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "sensative": "yes"
      })
      ex = expect_raises(JSON::ParseException, /'sensative'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("Unknown key")
    end

    # ── Unknown nested keys (B-13) ──────────────────────────────────

    it "rejects an unknown key inside a field definition, naming the field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string", "reqired": true }
        }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in field 'name'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'reqired'")
      ex.message.not_nil!.should contain("(did you mean 'required'?)")
    end

    it "names the nested property path inside a field definition" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "address": {
            "type": "object",
            "properties": {
              "city": { "type": "string", "requird": true }
            }
          }
        }
      })
      ex = expect_raises(DefinitionError, /field 'address\.properties\.city'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'requird'")
    end

    it "names the items path for unknown keys inside an array field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "tags": { "type": "array", "items": { "type": "string", "unique_key": true } }
        }
      })
      ex = expect_raises(DefinitionError, /field 'tags\.items'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'unique_key'")
    end

    it "names the values path for unknown keys inside a dictionary field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "prices": { "type": "dictionary", "values": { "type": "money", "curncy": "EUR" } }
        }
      })
      ex = expect_raises(DefinitionError, /field 'prices\.values'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'curncy'")
      ex.message.not_nil!.should contain("(did you mean 'currency'?)")
    end

    it "rejects a non-object nested container with a definition error, not a crash" do
      # `items` of a scalar shape would otherwise surface as a bare
      # RuntimeError / TypeCastError — an HTTP 500.
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "tags": { "type": "array", "items": "string" }
        }
      })
      ex = expect_raises(DefinitionError, /field 'tags\.items' must be a JSON object/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("string")
    end

    it "rejects an unknown key inside an enum value entry" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "status": {
            "type": "enum",
            "values": [
              { "key": "open", "colour": "#FF0000" },
              { "key": "closed" }
            ]
          }
        }
      })
      ex = expect_raises(DefinitionError, /field 'status'\.values\[0\]/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'colour'")
    end

    it "rejects an unknown key inside an action definition, naming the action" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "name": { "type": "string" } },
        "actions": {
          "approve": { "args": {}, "when": "always" }
        }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in action 'approve'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'when'")
    end

    it "rejects an unknown key inside an action argument, naming the path" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "name": { "type": "string" } },
        "actions": {
          "approve": { "args": { "note": { "type": "string", "reqired": true } } }
        }
      })
      ex = expect_raises(DefinitionError, /action 'approve'\.args\.note/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'reqired'")
    end

    it "rejects a non-object args container with a definition error, not a crash" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "name": { "type": "string" } },
        "actions": {
          "approve": { "args": ["note"] }
        }
      })
      expect_raises(DefinitionError, /action 'approve'\.args must be an object/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects an unknown key inside a named scope" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "owner_id": { "type": "reference", "doctype": "iam.Account" } },
        "scopes": {
          "mine": { "where": { "owner_id": "$self" }, "filter": "x" }
        }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in scope 'mine'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'filter'")
    end

    it "rejects an unknown key inside a children entry" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true,
        "fields": { "name": { "type": "string" } },
        "children": {
          "operations": { "doctype": "Operation", "on_delete": "cascade" }
        }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in child 'operations'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'on_delete'")
    end

    it "rejects an unknown key inside a sidecar entry" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": true,
        "fields": { "name": { "type": "string" } },
        "sidecars": {
          "comments": { "doctype": "core.Comment", "colum": "target" }
        }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in sidecar 'comments'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'colum'")
      ex.message.not_nil!.should contain("(did you mean 'column'?)")
    end

    it "rejects an unknown key inside a replicate config" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "customer_name": {
            "type": "string",
            "replicate": { "via": "customer_id", "feild": "full_name" }
          },
          "customer_id": { "type": "reference", "doctype": "crm.Customer" }
        }
      })
      ex = expect_raises(DefinitionError, /field 'customer_name'\.replicate/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'feild'")
      ex.message.not_nil!.should contain("(did you mean 'field'?)")
    end

    it "rejects an unknown key inside the identifier block" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "identifier": { "template": "WO-####", "gen_only": true }
      })
      ex = expect_raises(DefinitionError, /Unknown key\(s\) in identifier/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("'gen_only'")
      ex.message.not_nil!.should contain("(did you mean 'genonly'?)")
    end

    it "rejects a non-integer precision" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "revenue": { "type": "money", "precision": "2" }
        }
      })
      expect_raises(DefinitionError, /'precision' must be an integer/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a negative precision" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "revenue": { "type": "money", "precision": -1 }
        }
      })
      expect_raises(DefinitionError, /'precision' must be >= 0/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "round-trips precision and action description" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "revenue": { "type": "money", "currency": "USD", "precision": 0 }
        },
        "actions": {
          "approve": { "args": {}, "description": "Approve the order" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["revenue"].precision.should eq(0)
      defn.actions["approve"].description.should eq("Approve the order")
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.fields["revenue"].precision.should eq(0)
      roundtrip.actions["approve"].description.should eq("Approve the order")
    end

    it "re-parses round-tripped content carrying the derived operators member" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "status": { "type": "string", "filters": ["equality"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      # The struct writer emits the derived `operators` member next to
      # `filters`; the strict parser must accept it and re-derive.
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.fields["status"].operators.should eq(defn.fields["status"].operators)
      roundtrip.fields["status"].operators.should_not be_empty
    end

    # ── Named scopes ────────────────────────────────────────────────────

    it "parses named scopes declared on the definition" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "owner_id": { "type": "string" },
          "status": { "type": "string" }
        },
        "scopes": {
          "mine": {
            "description": "Mine",
            "where": { "owner_id": "$self" }
          },
          "active": { "where": { "status": "open" } }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.scopes.size.should eq(2)
      defn.scopes["mine"].where.should eq({"owner_id" => "$self"})
      defn.scopes["mine"].description.should eq("Mine")
      defn.scopes["active"].where.should eq({"status" => "open"})
      defn.scopes["active"].description.should be_nil
    end

    it "round-trips named scopes through serialisation" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "owner_id": { "type": "string" } },
        "scopes": { "mine": { "where": { "owner_id": "$self" } } }
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.scopes.size.should eq(1)
      roundtrip.scopes["mine"].where.should eq({"owner_id" => "$self"})
    end

    it "defaults to an empty scopes map when none declared" do
      json = %({ "doctype": "WorkOrder", "domain": "production" })
      defn = DoctypeDefinition.from_json(json)
      defn.scopes.should be_empty
    end

    it "coerces numeric and boolean where values to their string form" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "level": { "type": "integer" },
          "ratio": { "type": "money" },
          "active": { "type": "boolean" },
          "owner_id": { "type": "string" }
        },
        "scopes": {
          "tiers": {
            "where": { "level": 3, "ratio": 1.5, "active": true, "owner_id": "$self" }
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.scopes["tiers"].where.should eq({
        "level"    => "3",
        "ratio"    => "1.5",
        "active"   => "true",
        "owner_id" => "$self",
      })

      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.scopes["tiers"].where.should eq(defn.scopes["tiers"].where)
    end

    it "rejects an array value in a where map, naming the scope and the key" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "owner_id": { "type": "string" } },
        "scopes": {
          "mine": { "where": { "owner_id": ["a", "b"] } }
        }
      })
      ex = expect_raises(JSON::ParseException, /Named scope 'mine'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("owner_id")
      ex.message.not_nil!.should contain("array")
    end

    it "rejects an object value in a where map, naming the scope and the key" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "owner_id": { "type": "string" } },
        "scopes": {
          "mine": { "where": { "owner_id": { "id": "x" } } }
        }
      })
      ex = expect_raises(JSON::ParseException, /Named scope 'mine'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("owner_id")
      ex.message.not_nil!.should contain("object")
    end

    it "rejects a null value in a where map, naming the scope and the key" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "owner_id": { "type": "string" } },
        "scopes": {
          "mine": { "where": { "owner_id": null } }
        }
      })
      ex = expect_raises(JSON::ParseException, /Named scope 'mine'/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("owner_id")
      ex.message.not_nil!.should contain("null")
    end

    it "rejects a where section that is not an object" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "scopes": {
          "mine": { "where": ["owner_id"] }
        }
      })
      expect_raises(JSON::ParseException, /Named scope 'mine': 'where' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a scope entry that is not an object" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "scopes": {
          "mine": "owner_id = me"
        }
      })
      expect_raises(JSON::ParseException, /'scopes' entry 'mine' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── Pattern field attribute ────────────────────────────────────────

    it "parses pattern and pattern_flags on a field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "code": { "type": "string", "pattern": "^WO-[0-9]+$", "pattern_flags": "i" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["code"]
      field.pattern.should eq("^WO-[0-9]+$")
      field.pattern_flags.should eq("i")
    end

    it "serializes and deserializes pattern attribute" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "code": { "type": "string", "pattern": "^WO-[0-9]+$" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.fields["code"].pattern.should eq("^WO-[0-9]+$")
    end

    it "allows pattern to be absent" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["name"].pattern.should be_nil
    end

    it "serializes and deserializes accept attribute on file fields" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "logo": { "type": "file", "accept": ["image/*", "application/pdf"] }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.fields["logo"].accept.should eq(["image/*", "application/pdf"])
    end

    it "allows accept to be absent on a file field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "logo": { "type": "file" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["logo"].accept.should be_nil
    end

    # ── JSON roundtrip with new fields ───────────────────────────────

    it "roundtrips a full definition with description, longtext, and pattern" do
      json = %({
        "doctype": "Operation",
        "domain": "production",
        "schema_version": 3,
        "aggregate_root": false,
        "member_of": "WorkOrder",
        "description": "A production step on a work order",
        "fields": {
          "code":   { "type": "string", "required": true, "pattern": "^WO-" },
          "body":   { "type": "longtext" },
          "status": { "type": "enum", "values": ["open", "closed"] }
        },
        "actions": {
          "release": { "args": {} }
        },
        "script": "-- minimal"
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.doctype.should eq(defn.doctype)
      roundtrip.domain.should eq(defn.domain)
      roundtrip.schema_version.should eq(defn.schema_version)
      roundtrip.aggregate_root.should eq(defn.aggregate_root)
      roundtrip.member_of.should eq(defn.member_of)
      roundtrip.description.should eq(defn.description)
      roundtrip.fields.size.should eq(defn.fields.size)
      roundtrip.fields["code"].pattern.should eq("^WO-")
      roundtrip.fields["body"].type.not_nil!.type_name.should eq("longtext")
      roundtrip.actions.size.should eq(defn.actions.size)
      roundtrip.script.should eq(defn.script)
    end

    # ── Title / description / write_only / read_only field attributes ──

    it "parses title and description on a field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "password": {
            "type": "string",
            "title": "Password",
            "description": "The user's login password"
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["password"]
      field.title.should eq("Password")
      field.description.should eq("The user's login password")
    end

    it "allows title and description to be absent" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["name"]
      field.title.should be_nil
      field.description.should be_nil
    end

    it "parses write_only and read_only on a field" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "password": { "type": "string", "write_only": true },
          "slug":     { "type": "string", "read_only": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.fields["password"].write_only?.should be_true
      defn.fields["password"].read_only?.should be_false
      defn.fields["slug"].read_only?.should be_true
      defn.fields["slug"].write_only?.should be_false
    end

    it "defaults write_only and read_only to false" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "name": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      field = defn.fields["name"]
      field.write_only?.should be_false
      field.read_only?.should be_false
    end

    it "serializes and deserializes title, description, write_only, read_only" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": {
          "password": {
            "type": "string",
            "title": "Password",
            "description": "User password",
            "write_only": true
          },
          "slug": {
            "type": "string",
            "title": "Slug",
            "read_only": true
          }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      roundtrip = DoctypeDefinition.from_json(defn.to_json)

      pwd = roundtrip.fields["password"]
      pwd.title.should eq("Password")
      pwd.description.should eq("User password")
      pwd.write_only?.should be_true
      pwd.read_only?.should be_false

      slug = roundtrip.fields["slug"]
      slug.title.should eq("Slug")
      slug.read_only?.should be_true
      slug.write_only?.should be_false
    end

    # ── display_name ─────────────────────────────────────────────────

    it "parses a display_name template and round-trips it" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "display_name": "{{ code }} - {{ status }}",
        "fields": {
          "code":   { "type": "string" },
          "status": { "type": "string" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.display_name.should eq("{{ code }} - {{ status }}")
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.display_name.should eq("{{ code }} - {{ status }}")
    end

    it "defaults display_name to nil when absent" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": { "code": { "type": "string" } }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.display_name.should be_nil
      # Round-trip does not introduce a stray `display_name` key.
      defn.to_json.should_not contain("\"display_name\"")
    end

    # ── sidecar / sidecars ─────────────────────────────────────────

    it "defaults sidecar to false and sidecars to empty when absent" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production"
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sidecar.should be_false
      defn.sidecars.should be_empty
      defn.to_json.should_not contain("\"sidecar\"")
      defn.to_json.should_not contain("\"sidecars\"")
    end

    it "round-trips a sidecar doctype with a target reference field" do
      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext", "required": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sidecar.should be_true
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.sidecar.should be_true
      roundtrip.to_json.should contain("\"sidecar\":true")
    end

    it "round-trips a sidecars map on a host doctype" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": {
          "comments": { "doctype": "core.Comment" },
          "ratings":  { "doctype": "core.Rating", "column": "subject" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sidecars.size.should eq(2)
      defn.sidecars["comments"].doctype.should eq("core.Comment")
      defn.sidecars["comments"].column.should eq("target")
      defn.sidecars["ratings"].column.should eq("subject")

      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.sidecars.size.should eq(2)
      roundtrip.sidecars["comments"].doctype.should eq("core.Comment")
      roundtrip.sidecars["comments"].column.should eq("target")
      roundtrip.sidecars["ratings"].column.should eq("subject")
    end

    it "defaults sidecar order to 0 and label to nil when absent" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": {
          "comments": { "doctype": "core.Comment" }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      ref = defn.sidecars["comments"]
      ref.order.should eq(0)
      ref.label.should be_nil
      ref.sort_key("comments").should eq({0, "comments"})
      # Absent order/label are not emitted on the wire.
      defn.to_json.should_not contain("\"order\"")
      defn.to_json.should_not contain("\"label\"")
    end

    it "round-trips order and label on a sidecar entry" do
      json = %({
        "doctype": "Deal",
        "domain": "crm",
        "sidecars": {
          "notes":     { "doctype": "core.Comment", "order": 2, "label": "Notes" },
          "comments":  { "doctype": "core.Comment", "order": 1 }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.sidecars["notes"].order.should eq(2)
      defn.sidecars["notes"].label.should eq("Notes")
      defn.sidecars["comments"].label.should be_nil

      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.sidecars["notes"].order.should eq(2)
      roundtrip.sidecars["notes"].label.should eq("Notes")
      roundtrip.sidecars["comments"].order.should eq(1)
      roundtrip.sidecars["comments"].label.should be_nil
      roundtrip.to_json.should contain("\"label\":\"Notes\"")
    end

    it "defaults surface to nil when absent and round-trips it when set" do
      absent = DoctypeDefinition.from_json(%({
        "doctype": "Contact",
        "domain": "crm"
      }))
      absent.surface.should be_nil
      absent.to_json.should_not contain("\"surface\"")

      json = %({
        "doctype": "Comment",
        "domain": "core",
        "sidecar": true,
        "surface": "comment",
        "fields": {
          "target": { "type": "reference", "doctype": "crm.Contact", "required": true, "read_only": true },
          "body":   { "type": "longtext", "required": true }
        }
      })
      defn = DoctypeDefinition.from_json(json)
      defn.surface.should eq("comment")
      roundtrip = DoctypeDefinition.from_json(defn.to_json)
      roundtrip.surface.should eq("comment")
    end

    it "rejects a sidecar entry with an unqualified doctype" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": {
          "comments": { "doctype": "Comment" }
        }
      })
      expect_raises(JSON::ParseException, /qualified/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a sidecar entry with a missing doctype" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": {
          "comments": { "column": "target" }
        }
      })
      expect_raises(JSON::ParseException, /Missing 'doctype' in sidecar entry/) do
        DoctypeDefinition.from_json(json)
      end
    end

    # ── Container-key type errors (B-12) ────────────────────────────
    #
    # A definition key of the wrong JSON type must raise the definition
    # error the create/update services rescue into a 422 — naming the key
    # and the got-type — never an uncaught cast error that surfaces as an
    # HTTP 500 with a compiler path in the body.

    it "rejects fields as an array, naming the key and the got type" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": [{ "fieldname": "name", "type": "string" }]
      })
      ex = expect_raises(JSON::ParseException, /'fields' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("array")
      ex.message.not_nil!.should_not contain(" at line")
    end

    it "rejects fields as a scalar" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "fields": "name"
      })
      ex = expect_raises(JSON::ParseException, /'fields' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("string")
    end

    it "rejects scopes as an array" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "scopes": ["mine"]
      })
      expect_raises(JSON::ParseException, /'scopes' must be an object keyed by name \(got array\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects children as an array" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "children": ["operations"]
      })
      expect_raises(JSON::ParseException, /'children' must be an object keyed by name \(got array\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects sidecars as an array" do
      json = %({
        "doctype": "Contact",
        "domain": "crm",
        "sidecars": ["comments"]
      })
      expect_raises(JSON::ParseException, /'sidecars' must be an object keyed by name \(got array\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects actions as an array" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "actions": ["release"]
      })
      expect_raises(JSON::ParseException, /'actions' must be an object keyed by action name \(got array\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects migrations as an array" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 2,
        "migrations": ["migrate_from_1"]
      })
      expect_raises(JSON::ParseException, /'migrations' must be an object mapping schema version to Lua function name \(got array\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects migrations as a scalar" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 2,
        "migrations": "migrate_from_1"
      })
      expect_raises(JSON::ParseException, /'migrations' must be an object mapping schema version to Lua function name \(got string\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a non-string migrations value, naming the version" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": 2,
        "migrations": { "1": 42 }
      })
      ex = expect_raises(JSON::ParseException, /'migrations' entry for version '1' must be a string/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("number")
    end

    it "rejects a scalar entry in a named map, naming key, entry and got type" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "children": { "operations": "Operation" }
      })
      ex = expect_raises(JSON::ParseException, /'children' entry 'operations' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
      ex.message.not_nil!.should contain("string")
    end

    it "rejects a non-object identifier block" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "identifier": "WO-1"
      })
      expect_raises(JSON::ParseException, /'identifier' must be an object/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a whole-body array" do
      ex = expect_raises(JSON::ParseException, /doctype definition must be a JSON object/) do
        DoctypeDefinition.from_json("[{\"doctype\": \"WorkOrder\"}]")
      end
      ex.message.not_nil!.should contain("array")
    end

    it "rejects a non-boolean aggregate_root" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "aggregate_root": "true"
      })
      expect_raises(JSON::ParseException, /'aggregate_root' must be a boolean \(got string\)/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a non-integer schema_version" do
      json = %({
        "doctype": "WorkOrder",
        "domain": "production",
        "schema_version": "2"
      })
      expect_raises(JSON::ParseException, /'schema_version' must be an integer/) do
        DoctypeDefinition.from_json(json)
      end
    end

    it "rejects a non-string doctype" do
      json = %({ "doctype": 42, "domain": "production" })
      expect_raises(JSON::ParseException, /'doctype' must be a string.*\(got number\)/) do
        DoctypeDefinition.from_json(json)
      end
    end
  end
end
