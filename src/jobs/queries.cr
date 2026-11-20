# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"

module Facet
  module Jobs
    # SQL operations on the `background_jobs` table.
    #
    # Every statement the worker and callers need lives here; later phases
    # (`Worker`, `Manager`) touch the table only through this module. All
    # methods take an explicit `db : DB::Connection` (use `Database.with_db`
    # to obtain one) and bind timestamps as UTC RFC-3339 strings — the
    # columns are `TIMESTAMPTZ`.
    #
    # Retry policy is decided in one atomic `UPDATE`, not in Crystal:
    # `write_failed` reads the row's own `attempts` / `max_attempts` and
    # picks `pending` (with `run_after` pushed out) or `failed` in a single
    # statement, so a lease expiry can never interleave between the
    # decision and the write. The lease sweep applies the same cap.
    module Queries
      # Inserts one `pending` row. `max_attempts` / `backoff` default to nil
      # — the caller (handler class) supplies the policy; a nil
      # `max_attempts` falls back to the column default. `run_after`
      # defaults to now. `lease_ttl_s` defaults to nil — the row then uses
      # the worker's TTL at claim time; long job kinds pass a generous
      # per-row horizon instead.
      def self.insert(db : DB::Connection, id : String, kind : String, payload : JSON::Any, *, max_attempts : Int32? = nil, backoff : Array(Int32)? = nil, run_after : Time? = nil, lease_ttl_s : Int32? = nil) : Nil
        db.exec(
          "INSERT INTO background_jobs (id, kind, payload, max_attempts, backoff_seconds, run_after, lease_ttl_s)
           VALUES ($1, $2, $3, COALESCE($4, 5), $5, $6, $7)",
          id, kind, payload.to_json, max_attempts, backoff, bind_time(run_after || Time.utc), lease_ttl_s,
        )
      end

      # Claims up to `batch` due rows for the owner tag `locked_by`. Due
      # means `status = 'pending' AND run_after <= now()`. Rows locked by
      # another worker (SELECT ... FOR UPDATE SKIP LOCKED) are skipped, so
      # two workers on the same DB get disjoint row sets. Sets `running`,
      # increments `attempts`, and holds a lease. The lease length is the
      # row's own `lease_ttl_s` when the caller set one at enqueue time,
      # else `lease_ttl_s` (the worker default). `locked_by` carries the
      # owner tag `{instance_id}:{worker_id}` — the boot's `Facet::Service`
      # instance id, then the worker's own ULID — so the sweep can check
      # the owner instance's liveness.
      def self.claim(db : DB::Connection, locked_by : String, lease_ttl_s : Int32, batch : Int32) : Array(Job)
        claimed = [] of {job: Job, run_after: Time}
        db.query(<<-SQL, locked_by, lease_ttl_s, batch) do |rs|
          UPDATE background_jobs SET
            status       = 'running',
            attempts     = attempts + 1,
            locked_by    = $1,
            locked_until = now() + (COALESCE(lease_ttl_s, $2::int) * interval '1 second'),
            updated_at   = now()
          WHERE id IN (
            SELECT id FROM background_jobs
            WHERE status = 'pending'
              AND run_after <= now()
            ORDER BY run_after
            LIMIT $3
            FOR UPDATE SKIP LOCKED
          )
          RETURNING id, kind, payload, attempts, max_attempts, backoff_seconds, run_after
        SQL
          rs.each do
            job = read_job(rs)
            run_after = rs.read(Time)
            claimed << {job: job, run_after: run_after}
          end
        end
        # UPDATE ... RETURNING has no guaranteed row order in PG; restore
        # the due order the subquery selected.
        claimed.sort_by(&.[:run_after]).map(&.[:job])
      end

      # Writes a terminal `succeeded` outcome for one claimed row.
      # `result` is the handler's terminal payload (e.g. an export job's
      # `{artifact_id, row_count, format}`); nil leaves the column NULL.
      def self.write_succeeded(db : DB::Connection, id : String, *, http_status : Int32? = nil, result : JSON::Any? = nil) : Nil
        db.exec(
          "UPDATE background_jobs SET
             status           = 'succeeded',
             last_error       = NULL,
             last_http_status = $2,
             result           = $3,
             run_after        = NULL,
             locked_by        = NULL,
             locked_until     = NULL,
             updated_at       = now()
           WHERE id = $1",
          id, http_status, result.try(&.to_json),
        )
      end

      # Writes the outcome of a failed execution. One atomic `UPDATE`:
      # when the row's `attempts >= max_attempts` the row goes to
      # `failed`; otherwise it returns to `pending` with `run_after` set
      # per `backoff_seconds`. The `backoff` list passed by the worker
      # wins; a nil falls back to the row's `backoff_seconds` column. A
      # NULL or empty list retries immediately. `result` is the handler's
      # terminal payload (e.g. the failing row's `{row, field, message}` on
      # an import); it only carries meaning on a terminal row.
      def self.write_failed(db : DB::Connection, id : String, *, error : String? = nil, http_status : Int32? = nil, backoff_seconds : Array(Int32)? = nil, result : JSON::Any? = nil) : Nil
        db.exec(
          "UPDATE background_jobs SET
             status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'pending' END,
             last_error       = $2,
             last_http_status = $3,
            -- attempts was incremented by claim: the stored value is the
            -- failed-attempt count. Subscripts are 1-based, so
            -- backoff_seconds[attempts] is the last failed attempt's delay.
             run_after = CASE
               WHEN attempts >= max_attempts THEN NULL
               WHEN COALESCE(array_length(COALESCE($4, backoff_seconds), 1), 0) = 0 THEN now()
               ELSE now() + ((COALESCE($4, backoff_seconds))[LEAST(attempts, array_length(COALESCE($4, backoff_seconds), 1))] * interval '1 second')
             END,
             locked_by        = NULL,
             locked_until     = NULL,
             result           = $5,
             updated_at       = now()
           WHERE id = $1",
          id, error, http_status, backoff_seconds, result.try(&.to_json),
        )
      end

      # The distinct owner instance ids of the `running` rows. `locked_by`
      # carries `{instance_id}:{worker_id}`; the instance id is the part
      # before the first colon. The worker checks each id against the
      # owner's liveness key and passes the dead ones to
      # `sweep_expired_leases`.
      def self.running_owner_instances(db : DB::Connection) : Array(String)
        db.query_all(<<-SQL, &.read(String))
          SELECT DISTINCT split_part(locked_by, ':', 1)
          FROM background_jobs
          WHERE status = 'running'
            AND locked_by IS NOT NULL
        SQL
      end

      # The `last_error` the sweep writes when it caps a stranded row. The
      # row's own history holds no error — the worker that ran it died.
      ABANDONED_ERROR = "job abandoned — worker lost"

      # Recovers stranded `running` rows: back to `pending`, due
      # immediately, or — past the retry cap — to terminal `failed`. A row
      # is stranded when its lease expired or its owner instance is in
      # `dead_instances` (the liveness check marked those instance ids
      # dead). The cap mirrors `write_failed`: a touched row whose
      # `attempts >= max_attempts` goes `failed` with `last_error` set to
      # `ABANDONED_ERROR`, so a crash-looping job cannot requeue forever.
      # Does not touch `attempts` — the next claim increments it. Returns
      # the touched rows' `id` and `kind`, so the worker can fire the
      # `attempt_abandoned` handler hook per kind (in the same
      # transaction when it runs the sweep inside one).
      def self.sweep_expired_leases(db : DB::Connection, dead_instances : Array(String) = [] of String) : Array({id: String, kind: String})
        requeued = [] of {id: String, kind: String}
        db.query(<<-SQL, dead_instances, ABANDONED_ERROR) do |rs|
          UPDATE background_jobs SET
            status       = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'pending' END,
            last_error   = CASE WHEN attempts >= max_attempts THEN $2::text ELSE last_error END,
            run_after    = CASE WHEN attempts >= max_attempts THEN NULL ELSE now() END,
            locked_by    = NULL,
            locked_until = NULL,
            updated_at   = now()
          WHERE status = 'running'
            AND (
              locked_until < now()
              OR split_part(locked_by, ':', 1) = ANY($1::text[])
            )
          RETURNING id, kind
        SQL
          rs.each do
            requeued << {id: rs.read(String), kind: rs.read(String)}
          end
        end
        requeued
      end

      # Deletes terminal rows older than `retention_days`. Returns the
      # count deleted. Non-terminal rows survive whatever their age.
      def self.prune_terminal(db : DB::Connection, retention_days : Int32) : Int32
        db.exec(<<-SQL, retention_days).rows_affected.to_i32
          DELETE FROM background_jobs
          WHERE status IN ('succeeded', 'failed')
            AND updated_at < now() - ($1::int * interval '1 day')
        SQL
      end

      # Single-row lookup by id. Returns nil when the row does not exist.
      def self.find(db : DB::Connection, id : String) : Job?
        db.query_one?("SELECT id, kind, payload, attempts, max_attempts, backoff_seconds
           FROM background_jobs WHERE id = $1",
          id,
        ) do |rs|
          read_job(rs)
        end
      end

      # The caller-facing outcome of one row: terminal status, error, and the
      # handler's result payload. The status route reads this shape. Returns
      # nil when the row does not exist. `result` is NULL while the row is
      # pending/running — the handler's payload only exists on a written
      # terminal outcome.
      record Outcome,
        status : String,
        error : String?,
        result : JSON::Any?

      def self.find_outcome(db : DB::Connection, id : String) : Outcome?
        row = db.query_one?("SELECT status, last_error, result FROM background_jobs WHERE id = $1",
          id,
        ) do |rs|
          {status: rs.read(String), error: rs.read(String?), result: rs.read(JSON::Any?)}
        end
        row.try { |r| Outcome.new(status: r[:status], error: r[:error], result: r[:result]) }
      end

      # ── Private helpers ───────────────────────────────────────────────

      # Reads the six `RETURNING` / `SELECT` columns in the fixed order
      # used by `claim` and `find`.
      private def self.read_job(rs : DB::ResultSet) : Job
        Job.new(
          id: rs.read(String),
          kind: rs.read(String),
          payload: rs.read(JSON::Any),
          attempts: rs.read(Int32),
          max_attempts: rs.read(Int32),
          backoff: rs.read(Array(Int32)?),
        )
      end

      # Binds a Time as a UTC RFC-3339 string with no fraction digits.
      # The columns are TIMESTAMPTZ; the text form is parsed by PG in the
      # session's pinned UTC zone.
      private def self.bind_time(time : Time) : String
        Time::Format::RFC_3339.format(time, fraction_digits: 0)
      end
    end
  end
end
