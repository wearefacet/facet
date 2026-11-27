# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

module Facet
  module Jobs
    # Contract for one background-job kind. The worker dispatches claimed
    # rows to a concrete subclass through a flat `case` on `Job#kind`.
    # A handler owns the full lifecycle of its kind: `execute` does the
    # work, the attempt hooks observe the worker's lifecycle points. Every
    # hook has a no-op default — a subclass overrides only the ones it
    # needs (an attempt-log writer overrides all four).
    abstract class Handler
      enum Kind
        Succeeded
        Failed
      end

      # Outcome of one handler execution. The worker writes this to the
      # `background_jobs` row and decides retry vs. terminal from the row's
      # `max_attempts` — the handler does not classify its own retryability.
      # `response_body` / `duration_ms` carry the transport-level debug
      # capture of the attempt (nil for handlers that do not measure it).
      # `result` is the terminal outcome payload for the job's caller (e.g.
      # an export job's `{artifact_id, row_count, format}`); the worker
      # persists it on the row only when the outcome is written, and the
      # status route surfaces it. Rows still pending/running read NULL.
      record Result,
        status : Kind,
        error : String? = nil,
        http_status : Int32? = nil,
        response_body : String? = nil,
        duration_ms : Int64? = nil,
        result : ::JSON::Any? = nil

      # Executes the work for one claimed row. The handler must NOT touch
      # the `background_jobs` row — the worker writes the outcome from the
      # returned `Result`. The worker decides retry-vs-terminal by reading
      # the row's `max_attempts`; the handler does not classify its own
      # retryability. An uncaught exception in `execute` is turned into
      # `Result.new(status: Failed, error: ...)` by the worker;
      # handlers must not catch their own exceptions for retry purposes.
      #
      # Subclasses must be stateless and constructible with no arguments:
      # the worker instantiates one per claimed row through the dispatch
      # table, so a required constructor argument breaks the worker's
      # compile.
      abstract def execute(job : Job) : Result

      # Kind defaults. A job row may override these at enqueue time.
      def self.default_max_attempts : Int32
        5
      end

      def self.default_backoff : Array(Int32)
        [10, 60, 300, 1800, 7200]
      end

      # The kind's own concurrency cap, or `nil` for none. A worker that
      # runs this kind holds at most this many job fibers at once, so a
      # kind whose single execution allocates a whole file (the import)
      # cannot multiply the process footprint by the queue batch size. The
      # cap rides the enqueue and applies from the next worker start.
      def self.max_concurrent : Int32?
        nil
      end

      # ── Attempt lifecycle hooks ──────────────────────────────────────

      # One callback per attempt: `attempt_started` right after the worker
      # claims a row, `attempt_finished` right after the outcome write, and
      # `attempt_abandoned` when the lease sweep re-queues a `running` row
      # whose lease expired.
      #
      # The worker wraps every invocation: a raising hook is logged and
      # skipped — the job outcome path is never affected.
      def attempt_started(db : DB::Connection, job : Job, attempt : Int32) : Nil
      end

      def attempt_finished(db : DB::Connection, job_id : String, attempt : Int32, result : Result) : Nil
      end

      def attempt_abandoned(db : DB::Connection, job_id : String) : Nil
      end

      # Maintenance hook: the worker's terminal-prune pass calls it with
      # the queue's retention horizon, so a handler that owns an
      # attempt-log table deletes its stale rows on the same cadence and
      # from the same `retention_days` source. Deletes terminal rows older
      # than `retention_days`; returns the count deleted. Non-terminal
      # rows survive whatever their age.
      def prune_expired(db : DB::Connection, retention_days : Int32) : Int32
        0
      end
    end

    # Raised by a handler when its inputs can no longer produce a valid
    # outcome (a vanished role, an unresolvable app grant). The worker
    # converts it to a terminal `Failed` result via the handler contract.
    class JobError < Exception
    end
  end
end
