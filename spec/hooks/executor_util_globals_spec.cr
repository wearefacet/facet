# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/hooks"

# B-203 — domain hooks run with the same sandbox globals as the lifecycle
# script contexts: `util.*` (including the JSON helpers and the db-backed
# gates), `date.*`, and `math.clamp`.
#
# The scripts report values back through `ctx.error(msg)` — the validation
# collector — so each assertion reads the collected message.

# Calls `util.ulid()` and reports the shape back.
UTIL_SCRIPT = <<-LUA
  local export = {}
  function export.on_event(ctx)
    ctx.error("ULID:" .. util.ulid())
  end
  return export
LUA

# Round-trips a Lua table through `util.json_encode` → `util.json_decode`.
JSON_SCRIPT = <<-LUA
  local export = {}
  function export.on_event(ctx)
    local encoded = util.json_encode({ label = "hook", n = 2 })
    local decoded = util.json_decode(encoded)
    ctx.error("JSON:" .. decoded.label .. ":" .. decoded.n)
  end
  return export
LUA

# Reads the date and math globals. `string.format` pins the number format,
# so the assertion does not depend on the Lua float-to-string rule.
DATE_MATH_SCRIPT = <<-LUA
  local export = {}
  function export.on_event(ctx)
    ctx.error("DATE:" .. string.format("%.0f", date.diff("2026-01-01", "2026-01-02", "day")))
    ctx.error("CLAMP:" .. string.format("%.0f", math.clamp(15, 0, 10)))
  end
  return export
LUA

# A db-backed gate binding — present only when a connection was handed to
# the sandbox registration.
DB_GATE_SCRIPT = <<-LUA
  local export = {}
  function export.on_event(ctx)
    ctx.error("GATE:" .. type(util.role_has_channel))
  end
  return export
LUA

def util_event_hook(id : String, script : String) : Facet::Hooks::Definition::Hook
  Facet::Hooks::Definition::Hook.new(
    id: id,
    kind: :event,
    script: script,
    source_domain: "src",
    source_doc_type: "Source",
    source_events: nil,
    schedule: nil,
    owning_domain: "consumer",
  )
end

def util_event_payload : JSON::Any
  h = {} of String => JSON::Any
  h["domain"] = JSON::Any.new("src")
  h["doc_type"] = JSON::Any.new("Source")
  h["event"] = JSON::Any.new("updated")
  h["doc_id"] = JSON::Any.new("src-1")
  h["mutation_id"] = JSON::Any.new(nil.as(JSON::Any::Type))
  h["actioner_id"] = JSON::Any.new("system:test")
  h["content"] = JSON::Any.new({} of String => JSON::Any)
  JSON::Any.new(h)
end

describe "Hooks::Executor sandbox globals (B-203)" do
  it "exposes util.ulid to a domain hook" do
    with_db do |db|
      hook = util_event_hook("util-ulid", UTIL_SCRIPT)

      Facet::Hooks::Executor.new(db, "consumer", hook) do |executor|
        errors = executor.run_event(util_event_payload)
        errors.size.should eq(1)
        message = errors.first.message
        message.should start_with("ULID:")
        # A ULID is 26 Crockford-Base32 characters.
        message[5..].size.should eq(26)
      end
    end
  end

  it "exposes the JSON helpers to a domain hook" do
    with_db do |db|
      hook = util_event_hook("util-json", JSON_SCRIPT)

      Facet::Hooks::Executor.new(db, "consumer", hook) do |executor|
        errors = executor.run_event(util_event_payload)
        errors.size.should eq(1)
        errors.first.message.should eq("JSON:hook:2")
      end
    end
  end

  it "exposes the date and math globals to a domain hook" do
    with_db do |db|
      hook = util_event_hook("util-date-math", DATE_MATH_SCRIPT)

      Facet::Hooks::Executor.new(db, "consumer", hook) do |executor|
        errors = executor.run_event(util_event_payload)
        errors.map(&.message).should eq(["DATE:1", "CLAMP:10"])
      end
    end
  end

  it "exposes the db-backed gate bindings to a domain hook" do
    with_db do |db|
      hook = util_event_hook("util-db-gate", DB_GATE_SCRIPT)

      Facet::Hooks::Executor.new(db, "consumer", hook) do |executor|
        errors = executor.run_event(util_event_payload)
        errors.size.should eq(1)
        errors.first.message.should eq("GATE:function")
      end
    end
  end
end
