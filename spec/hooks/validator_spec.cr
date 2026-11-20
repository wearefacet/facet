# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"

# Builds an array of `Hook` records from raw JSON-like hash entries. This
# exercises the `Definition.parse` path (so definition + validator
# integration is exercised), then extracts the `Array(Hook)` (ignoring
# parse errors — the validator tests construct valid shapes).
def parse_hooks(raw : Array) : Array(Facet::Hooks::Definition::Hook)
  content = JSON.parse({"hooks" => raw}.to_json)
  hooks, _errors = Facet::Hooks::Definition.parse(content)
  hooks
end

def event_script(export_name : String) : String
  <<-LUA
    local export = {}
    function export.#{export_name}(ctx) end
    return export
  LUA
end

def schedule_script(export_name : String) : String
  <<-LUA
    local export = {}
    function export.#{export_name}(ctx) end
    return export
  LUA
end

module Facet::Hooks
  describe Validator do
    # ── Happy paths ────────────────────────────────────────────────────

    it "passes for an event hook with a valid on_event export" do
      hooks = parse_hooks([{
        "id"     => "on-delinquent",
        "kind"   => "event",
        "script" => event_script("on_event"),
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.should be_empty
    end

    it "passes for a schedule hook with a valid on_schedule export and 5-field cron" do
      hooks = parse_hooks([{
        "id"       => "nightly",
        "kind"     => "schedule",
        "schedule" => "0 0 * * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.should be_empty
    end

    it "passes for 5-field cron expressions with step repetition" do
      ["*/15 * * * *", "0 */2 * * *", "0 0 1 * *", "0 0 1 1 *", "30 4 1 * 1-5"].each do |cron|
        hooks = parse_hooks([{
          "id"       => "step",
          "kind"     => "schedule",
          "schedule" => cron,
          "script"   => schedule_script("on_schedule"),
        }])
        errors = Validator.validate(hooks)
        errors.should be_empty, "expected '#{cron}' to be accepted, got: #{errors.map(&.message)}"
      end
    end

    it "passes for a 5-field cron with comma list values" do
      hooks = parse_hooks([{
        "id"       => "list",
        "kind"     => "schedule",
        "schedule" => "0,30 * * * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.should be_empty
    end

    it "passes for a 5-field cron with range values" do
      hooks = parse_hooks([{
        "id"       => "range",
        "kind"     => "schedule",
        "schedule" => "0 9-17 * * 1-5",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.should be_empty
    end

    it "passes for a script with the required export alongside extras" do
      hooks = parse_hooks([{
        "id"     => "extras",
        "kind"   => "event",
        "script" => <<-LUA,
          local export = {}
          function export.on_event(ctx) end
          function export.helper(ctx) end
          return export
        LUA
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.should be_empty
    end

    # ── Id uniqueness ──────────────────────────────────────────────────

    it "reports duplicate hook ids" do
      hooks = parse_hooks([
        {
          "id"     => "dup",
          "kind"   => "event",
          "script" => event_script("on_event"),
          "source" => {"domain" => "accountancy"},
        },
        {
          "id"     => "dup",
          "kind"   => "event",
          "script" => event_script("on_event"),
          "source" => {"domain" => "identity"},
        },
      ])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("Duplicate hook id 'dup'")).should be_true
    end

    # ── Lua script validation ─────────────────────────────────────────

    it "reports a Lua syntax error" do
      hooks = parse_hooks([{
        "id"     => "syntax",
        "kind"   => "event",
        "script" => "this is not lua",
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("syntax")
      errors[0].field.should eq("hooks.syntax.script")
    end

    it "reports a script that does not return a table" do
      hooks = parse_hooks([{
        "id"     => "not-table",
        "kind"   => "event",
        "script" => "return 42",
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("must return a Lua table")
    end

    it "appends the module-pattern hint for a nil-global export index" do
      hooks = parse_hooks([{
        "id"     => "bare-export",
        "kind"   => "event",
        "script" => "function export.on_event(ctx) end",
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("script error:")
      errors[0].message.should contain("declare `local export = {}` before `function export.…`")
    end

    it "reports a missing on_event export for an event hook" do
      hooks = parse_hooks([{
        "id"     => "missing-event",
        "kind"   => "event",
        "script" => "local export = {} return export",
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("'on_event'")
    end

    it "reports a missing on_schedule export for a schedule hook" do
      hooks = parse_hooks([{
        "id"       => "missing-schedule",
        "kind"     => "schedule",
        "schedule" => "0 0 * * *",
        "script"   => "local export = {} return export",
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("'on_schedule'")
    end

    it "reports when on_event is present but not a function" do
      hooks = parse_hooks([{
        "id"     => "not-fn",
        "kind"   => "event",
        "script" => "local export = { on_event = 'not a function' } return export",
        "source" => {"domain" => "accountancy"},
      }])
      errors = Validator.validate(hooks)
      errors.size.should eq(1)
      errors[0].message.should contain("must be a function")
    end

    # ── Cron restrictiveness ──────────────────────────────────────────

    it "rejects an @-macro cron expression" do
      hooks = parse_hooks([{
        "id"       => "macro",
        "kind"     => "schedule",
        "schedule" => "@daily",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("not in the supported form")).should be_true
    end

    it "rejects a 6-field cron expression with seconds" do
      hooks = parse_hooks([{
        "id"       => "six-field",
        "kind"     => "schedule",
        "schedule" => "0 0 0 * * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("not in the supported form")).should be_true
    end

    it "rejects a 4-field cron expression" do
      hooks = parse_hooks([{
        "id"       => "four-field",
        "kind"     => "schedule",
        "schedule" => "0 0 * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("not in the supported form")).should be_true
    end

    it "rejects a cron field with a W modifier" do
      hooks = parse_hooks([{
        "id"       => "w-mod",
        "kind"     => "schedule",
        "schedule" => "0 0 15W * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("not in the supported form")).should be_true
    end

    it "rejects a cron field with an L modifier" do
      hooks = parse_hooks([{
        "id"       => "l-mod",
        "kind"     => "schedule",
        "schedule" => "0 0 L * *",
        "script"   => schedule_script("on_schedule"),
      }])
      errors = Validator.validate(hooks)
      errors.any?(&.message.includes?("not in the supported form")).should be_true
    end
  end
end
