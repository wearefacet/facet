# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../database"
require "../http/responders"

module Facet
  module Webhook
    # Read side of the call log: queries over `webhook_calls`, one row per
    # outbound HTTP attempt, newest first per webhook. Replaces the
    # delivery log over `background_jobs` — the queue keeps its own
    # outcome columns; this table is the user-facing debug log.
    module Calls
      # The status filter values the list route accepts (decision 3 —
      # same vocabulary as the queue).
      STATUSES = %w[pending succeeded failed]

      # One `webhook_calls` row. Envelope identity is denormalized onto
      # the row, so the log is filterable without touching the job
      # payload; `job_id` is nil for test probes.
      record Call,
        id : String,
        webhook_id : String,
        job_id : String?,
        event : String,
        source_doc_id : String?,
        mutation_id : String?,
        attempt : Int32,
        status : String,
        http_status : Int32?,
        error : String?,
        response_body : String?,
        duration_ms : Int32?,
        created_at : Time,
        updated_at : Time

      # Lists one webhook's call rows, newest first, paginated. An
      # optional `status` narrows to one value of `STATUSES`. Returns the
      # page rows plus the capped count of matching rows from the page
      # offset (see `HTTP::Responders::COUNT_CAP`).
      def self.list(db : DB::Connection, webhook_id : String, status : String?, page : Int32, per_page : Int32) : {Array(Call), Int32}
        page = Math.max(1, page)
        per_page = Math.max(1, per_page)
        offset = (page - 1) * per_page
        cap = HTTP::Responders::COUNT_CAP

        if status
          total = db.query_one(
            <<-SQL, webhook_id, status, cap + 1, offset, as: Int64)
              SELECT count(*) FROM (
                SELECT 1 FROM webhook_calls
                WHERE webhook_id = $1 AND status = $2
                ORDER BY updated_at DESC, id DESC
                LIMIT $3 OFFSET $4
              ) AS sub
            SQL
          total = total.to_i32

          calls = db.query_all(
            <<-SQL, webhook_id, status, per_page, offset) do |rs|
            SELECT id, webhook_id, job_id, event, source_doc_id, mutation_id,
                   attempt, status, http_status, error, response_body,
                   duration_ms, created_at, updated_at
            FROM webhook_calls
            WHERE webhook_id = $1 AND status = $2
            ORDER BY updated_at DESC, id DESC
            LIMIT $3 OFFSET $4
          SQL
            read_call(rs)
          end
          {calls, total}
        else
          total = db.query_one(
            <<-SQL, webhook_id, cap + 1, offset, as: Int64)
              SELECT count(*) FROM (
                SELECT 1 FROM webhook_calls
                WHERE webhook_id = $1
                ORDER BY updated_at DESC, id DESC
                LIMIT $2 OFFSET $3
              ) AS sub
            SQL
          total = total.to_i32

          calls = db.query_all(
            <<-SQL, webhook_id, per_page, offset) do |rs|
            SELECT id, webhook_id, job_id, event, source_doc_id, mutation_id,
                   attempt, status, http_status, error, response_body,
                   duration_ms, created_at, updated_at
            FROM webhook_calls
            WHERE webhook_id = $1
            ORDER BY updated_at DESC, id DESC
            LIMIT $2 OFFSET $3
          SQL
            read_call(rs)
          end

          {calls, total}
        end
      end

      # Finds one call row of this webhook by id. Returns nil when the row
      # does not exist or belongs to another webhook — a call is never
      # readable outside its webhook's log.
      def self.find(db : DB::Connection, webhook_id : String, call_id : String) : Call?
        db.query_one?(
          <<-SQL, call_id, webhook_id) do |rs|
          SELECT id, webhook_id, job_id, event, source_doc_id, mutation_id,
                 attempt, status, http_status, error, response_body,
                 duration_ms, created_at, updated_at
          FROM webhook_calls
          WHERE id = $1 AND webhook_id = $2
        SQL
          read_call(rs)
        end
      end

      # ── Private ───────────────────────────────────────────────────────

      # Reads the fourteen selected columns in the fixed order above.
      private def self.read_call(rs : DB::ResultSet) : Call
        Call.new(
          id: rs.read(String),
          webhook_id: rs.read(String),
          job_id: rs.read(String?),
          event: rs.read(String),
          source_doc_id: rs.read(String?),
          mutation_id: rs.read(String?),
          attempt: rs.read(Int32),
          status: rs.read(String),
          http_status: rs.read(Int32?),
          error: rs.read(String?),
          response_body: rs.read(String?),
          duration_ms: rs.read(Int32?),
          created_at: rs.read(Time),
          updated_at: rs.read(Time),
        )
      end
    end
  end
end
