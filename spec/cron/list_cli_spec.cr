# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cron/list_cli"

# Builds one table entry with an inert callback — the listing never calls
# the task.
private def entry(id : String, schedule_key : String, cron : String) : Facet::Cron::Tasks::Entry
  Facet::Cron::Tasks::Entry.new(id: id, schedule_key: schedule_key, cron: cron, task: -> { nil })
end

describe Facet::Cron::ListCLI do
  describe ".run" do
    it "prints the header and one row per task with the computed next run" do
      io = IO::Memory.new
      now = Time.utc(2024, 1, 1, 0, 0, 0)

      code = Facet::Cron::ListCLI.run(
        [entry("demo.pass", "demo.pass_cron", "30 5 * * *")],
        io,
        now,
      )

      code.should eq 0
      out = io.to_s
      out.should contain("task id")
      out.should contain("schedule key")
      out.should contain("expression")
      out.should contain("next run (UTC)")
      out.should contain("demo.pass")
      out.should contain("demo.pass_cron")
      out.should contain("30 5 * * *")
      out.should contain("2024-01-01 05:30:00 UTC")
    end

    it "prints the rows in the order the table carries them" do
      io = IO::Memory.new
      entries = [
        entry("first.task", "first.task_cron", "0 3 * * *"),
        entry("second.task", "second.task_cron", "0 4 * * *"),
      ]

      code = Facet::Cron::ListCLI.run(entries, io, Time.utc(2024, 1, 1, 0, 0, 0))

      code.should eq 0
      out = io.to_s
      out.index!("first.task").should be < out.index!("second.task")
    end

    it "marks an unparseable expression and fails the command" do
      io = IO::Memory.new

      code = Facet::Cron::ListCLI.run(
        [entry("demo.bad", "demo.bad_cron", "@reboot")],
        io,
        Time.utc(2024, 1, 1, 0, 0, 0),
      )

      code.should eq 1
      out = io.to_s
      out.should contain("demo.bad")
      out.should contain("invalid:")
      out.should contain("Error: fix the marked cron expressions in the config")
    end
  end
end
