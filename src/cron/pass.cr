# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"

module Facet
  module Cron
    # Shared runner for one scheduled pass.
    #
    # Every cron task follows the same wrapper: open a pooled connection,
    # run the work block, log one completion line, and — on failure — log
    # and re-raise so the scheduler's own error log fires too
    # (`Scheduler#spawn_fire` rescues and reschedules).
    #
    # - *label* names the task in both log lines, e.g. "Tombstone content
    #   prune".
    # - The block receives the connection and returns the touched row
    #   count.
    # - *log_zero* keeps the completion heartbeat for zero-row passes. The
    #   two retention prune passes log unconditionally (they run daily, so
    #   the line is the "this ran" marker); a high-frequency sweep passes
    #   `false` so a quiet pass stays out of the log.
    #
    # Every pass writes (prune, compaction, reconcile, sweep), so the
    # wrapper pins the rw pool explicitly — the write-path label the
    # per-domain placement phase will route on.
    def self.run_pass(label : String, log_zero : Bool = true, &) : Nil
      touched = 0
      Database.with_db(:read_write) do |db|
        touched = yield db
      end
      Log.info { "#{label} pass complete: #{touched} row(s) touched" } if log_zero || touched.positive?
    rescue ex : Exception
      Log.error { "#{label} pass failed: #{ex.message}" }
      raise ex
    end
  end
end
