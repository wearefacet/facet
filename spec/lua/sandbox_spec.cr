# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Boots a sandbox with the shared globals and no db connection — the
# same registrations the compute engine takes, so the db-backed `util.*`
# gates stay absent. Kept at file scope: a `def` cannot be declared
# inside the spec DSL's describe blocks.
def booted_util_sandbox : Facet::Lua::Sandbox
  sandbox = Facet::Lua::Sandbox.new
  sandbox.register_util_globals!(json_helpers: false)
  sandbox
end

module Facet
  module Lua
    describe Sandbox do
      describe "date globals" do
        it "diffs through the binding with the calendar month rule" do
          booted_util_sandbox.engine.run(
            "return date.diff('2026-07-27', '2026-08-06', 'month')",
          ).should eq(1.0)
        end

        it "adds with day clamping and keeps a calendar date a calendar date" do
          booted_util_sandbox.engine.run(
            "return date.add('2026-01-31', 1, 'month')",
          ).should eq("2026-02-28")
        end

        it "coerces a Lua number argument through the string binding" do
          booted_util_sandbox.engine.run(
            "return date.add('2026-01-01', 30, 'day')",
          ).should eq("2026-01-31")
        end

        it "returns today as a YYYY-MM-DD string" do
          today = booted_util_sandbox.engine.run("return date.today()")
          today.should be_a(String)
          today.as(String).matches?(/^\d{4}-\d{2}-\d{2}$/).should be_true
        end

        it "returns date.parts as a table with ISO weekdays" do
          sandbox = booted_util_sandbox
          sandbox.engine.run(
            "local p = date.parts('2026-01-25'); return p.weekday",
          ).should eq(7.0)
          sandbox.engine.run(
            "local p = date.parts('2026-01-19'); return p.hour",
          ).should eq(0.0)
        end

        it "reads period bounds through p['end'] — touching [) ranges do not overlap" do
          booted_util_sandbox.engine.run(<<-LUA).should be_false
            local a = {start = '2026-01-01T00:00:00Z', ['end'] = '2026-01-10T00:00:00Z'}
            local b = {start = '2026-01-10T00:00:00Z', ['end'] = '2026-01-20T00:00:00Z'}
            return date.period_overlaps(a, b)
          LUA
        end

        it "treats touching dateperiod ranges as overlapping — inclusive bounds" do
          booted_util_sandbox.engine.run(<<-LUA).should be_true
            local a = {start = '2026-01-01', ['end'] = '2026-01-10'}
            local b = {start = '2026-01-10', ['end'] = '2026-01-20'}
            return date.dateperiod_overlaps(a, b)
          LUA
        end

        it "raises a catchable Lua error on bad input" do
          sandbox = booted_util_sandbox
          r_ok = sandbox.engine.run(<<-LUA)
            local ok, err = pcall(date.diff, 'garbage', '2026-01-01', 'day')
            return ok
          LUA
          r_ok.should be_false
          r_err = sandbox.engine.run(<<-LUA)
            local ok, err = pcall(date.diff, 'garbage', '2026-01-01', 'day')
            return err
          LUA
          r_err.should be_a(String)
          r_err.as(String).should contain("date.diff")
        end

        it "raises a catchable Lua error on an unknown unit" do
          r = booted_util_sandbox.engine.run(<<-LUA)
            local ok, err = pcall(date.diff, '2026-01-01', '2026-02-01', 'fortnight')
            return tostring(err)
          LUA
          r.should be_a(String)
          r.as(String).should contain("unknown unit")
        end

        it "clears the temp binding globals after registration" do
          booted_util_sandbox.engine.run("return __date_diff == nil and __date_parts == nil").should be_true
        end
      end
    end
  end
end
