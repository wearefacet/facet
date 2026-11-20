# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./parser"
require "./tasks"

module Facet
  module Cron
    # `facet cron:list` — prints the boot cron task table.
    #
    # One row per task: the scheduler id, the config key that owns the
    # schedule, the expression, and the next fire time computed from `now`
    # (UTC). The command reads config only — no database, no Redis — so it
    # runs offline and chains with other commands.
    #
    # An expression the parser refuses marks its row and fails the command
    # (exit code 1): the server refuses to boot on the same error, so the
    # listing must not answer 0.
    module ListCLI
      # One rendered row. `next_run` holds the formatted fire time, or the
      # parse error prefixed with `invalid: `.
      private record Row, id : String, schedule_key : String, cron : String, next_run : String

      private HEADER = ["task id", "schedule key", "expression", "next run (UTC)"]

      private COLUMN_GAP = "   "

      # Prints the table and returns the process exit code.
      def self.run(entries : Array(Facet::Cron::Tasks::Entry), io : IO = STDOUT, now : Time = Time.utc) : Int32
        rows = entries.map { |entry| row_for(entry, now) }
        cells = rows.map { |row| [row.id, row.schedule_key, row.cron, row.next_run] }
        widths = column_widths(cells + [HEADER])

        print_row(io, HEADER, widths)
        rows.each do |row|
          print_row(io, [row.id, row.schedule_key, row.cron, row.next_run], widths)
        end

        if rows.any?(&.next_run.starts_with?("invalid: "))
          io.puts
          io.puts "Error: fix the marked cron expressions in the config — the server refuses to boot while one is invalid."
          1
        else
          0
        end
      end

      # ── Internals ──────────────────────────────────────────────────────

      # Renders one row. The fire time format is plain UTC — the same
      # convention the storage layer pins.
      private def self.row_for(entry : Facet::Cron::Tasks::Entry, now : Time) : Row
        Row.new(entry.id, entry.schedule_key, entry.cron, next_run_cell(entry.cron, now))
      end

      private def self.next_run_cell(cron : String, now : Time) : String
        Facet::Cron::Parser.new(cron).next(now).to_s("%Y-%m-%d %H:%M:%S UTC")
      rescue e : ArgumentError
        "invalid: #{e.message}"
      end

      private def self.column_widths(table : Array(Array(String))) : Array(Int32)
        widths = Array.new(HEADER.size, 0)
        table.each do |row|
          row.each_with_index do |cell, i|
            widths[i] = cell.size if cell.size > widths[i]
          end
        end
        widths
      end

      private def self.print_row(io : IO, cells : Array(String), widths : Array(Int32)) : Nil
        line = cells.map_with_index { |cell, i| cell.ljust(widths[i]) }.join(COLUMN_GAP)
        io.puts line.rstrip
      end
    end
  end
end
