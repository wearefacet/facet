# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/doctype"
require "../../src/doctype/script_validator"

# Builds an action definition whose args are all plain strings. File-scoped
# helper for the B-117 arg-lint examples.
private def arg_action(*names : String)
  args = {} of String => Facet::Doctype::ActionArgDefinition
  names.each { |n| args[n] = Facet::Doctype::ActionArgDefinition.new(type: Facet::Doctype::FieldType.parse("string")) }
  Facet::Doctype::ActionDefinition.new(args: args)
end

module Facet::Doctype
  describe ScriptValidator do
    it "passes when script has no actions defined" do
      defn = DoctypeDefinition.new(doctype: "Noop", domain: "test")
      errors = ScriptValidator.validate("local export = {}; return export", defn)
      errors.should be_empty
    end

    it "passes when script exports all required action functions" do
      defn = DoctypeDefinition.new(
        doctype: "Employee",
        domain: "hr",
        actions: {
          "promote" => ActionDefinition.new,
          "hire"    => ActionDefinition.new,
        }
      )
      script = <<-LUA
        local export = {}
        function export.promote(ctx, args) end
        function export.hire(ctx, args) end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.should be_empty
    end

    it "reports error when an action function is missing from the export" do
      defn = DoctypeDefinition.new(
        doctype: "Employee",
        domain: "hr",
        actions: {
          "promote"   => ActionDefinition.new,
          "terminate" => ActionDefinition.new,
        }
      )
      script = <<-LUA
        local export = {}
        function export.promote(ctx, args) end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("terminate")
    end

    it "reports error when the script does not return a table" do
      defn = DoctypeDefinition.new(doctype: "Noop", domain: "test")
      errors = ScriptValidator.validate("return 42", defn)
      errors.size.should eq(1)
      errors[0].message.should contain("must return a Lua table")
    end

    it "reports syntax errors" do
      defn = DoctypeDefinition.new(doctype: "Noop", domain: "test")
      errors = ScriptValidator.validate("this is not lua", defn)
      errors.size.should eq(1)
      errors[0].message.should contain("syntax")
    end

    it "labels a runtime failure as a script error, not a syntax error" do
      defn = DoctypeDefinition.new(doctype: "Noop", domain: "test")
      errors = ScriptValidator.validate("function export.promote(ctx) end", defn)
      errors.size.should eq(1)
      errors[0].message.should contain("Script error:")
      errors[0].message.should_not contain("syntax")
    end

    it "looks up the action function by the action name in the export table" do
      defn = DoctypeDefinition.new(
        doctype: "Order",
        domain: "shop",
        actions: {
          "ship" => ActionDefinition.new,
        }
      )
      script = <<-LUA
        local export = {}
        function export.ship(ctx, args) end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.should be_empty
    end

    it "reports error if an export key is not a function" do
      defn = DoctypeDefinition.new(
        doctype: "Order",
        domain: "shop",
        actions: {
          "ship" => ActionDefinition.new,
        }
      )
      script = <<-LUA
        local export = { ship = "not a function" }
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("must be a function")
    end

    # ── Computed fields ──────────────────────────────────────────────────

    it "passes when script exports all compute functions" do
      defn = DoctypeDefinition.new(
        doctype: "Invoice",
        domain: "billing",
        fields: {
          "fullName"  => FieldDefinition.new(type: FieldType.parse("data"), compute: "fullName"),
          "total"     => FieldDefinition.new(type: FieldType.parse("data"), compute: "total"),
          "firstName" => FieldDefinition.new(type: FieldType.parse("string")),
          "lastName"  => FieldDefinition.new(type: FieldType.parse("string")),
        }
      )
      script = <<-LUA
        local export = {}
        function export.compute_fullName(ctx) return "" end
        function export.compute_total(ctx) return 0 end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.should be_empty
    end

    it "reports error when a compute function is missing from the export" do
      defn = DoctypeDefinition.new(
        doctype: "Invoice",
        domain: "billing",
        fields: {
          "total"    => FieldDefinition.new(type: FieldType.parse("data"), compute: "total"),
          "discount" => FieldDefinition.new(type: FieldType.parse("data"), compute: "discount"),
        }
      )
      script = <<-LUA
        local export = {}
        function export.compute_total(ctx) return 0 end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("discount")
      errors[0].message.should contain("compute_discount")
    end

    it "reports error when a compute export is not a function" do
      defn = DoctypeDefinition.new(
        doctype: "Invoice",
        domain: "billing",
        fields: {
          "total" => FieldDefinition.new(type: FieldType.parse("data"), compute: "total"),
        }
      )
      script = <<-LUA
        local export = { compute_total = "not a function" }
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("compute_total")
      errors[0].message.should contain("must be a function")
    end

    it "reports error when a data field has no compute value" do
      defn = DoctypeDefinition.new(
        doctype: "Invoice",
        domain: "billing",
        fields: {
          "total" => FieldDefinition.new(type: FieldType.parse("data"), compute: nil),
        }
      )
      script = <<-LUA
        local export = {}
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("missing a 'compute' value")
    end

    # ── Action arg lint (B-117) ────────────────────────────────────

    it "reports an undeclared args read with the arg name (B-117)" do
      defn = DoctypeDefinition.new(
        doctype: "Order",
        domain: "shop",
        actions: {
          "ship" => arg_action("note"),
        }
      )
      script = <<-LUA
        local export = {}
        function export.ship(ctx, args)
          return args.tracking_id
        end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.size.should eq(1)
      errors[0].message.should contain("ship")
      errors[0].message.should contain("tracking_id")
    end

    it "passes when every args read is declared (B-117)" do
      defn = DoctypeDefinition.new(
        doctype: "Order",
        domain: "shop",
        actions: {
          "ship" => arg_action("note", "tracking_id"),
        }
      )
      script = <<-LUA
        local export = {}
        function export.ship(ctx, args)
          local note = args.note
          return note .. tostring(args["tracking_id"])
        end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.should be_empty
    end

    it "passes a dynamic args read — the documented lint limit (B-117)" do
      defn = DoctypeDefinition.new(
        doctype: "Order",
        domain: "shop",
        actions: {
          "ship" => ActionDefinition.new,
        }
      )
      script = <<-LUA
        local export = {}
        function export.ship(ctx, args)
          local key = "note"
          return args[key]
        end
        return export
      LUA
      errors = ScriptValidator.validate(script, defn)
      errors.should be_empty
    end
  end
end
