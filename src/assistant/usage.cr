# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

require "../database"
require "../error"
require "../util/script_helpers"

module Facet
  module Assistant
    # Per-account token usage ledger over the `assistant_usage` table
    # (`db/migrations/0005_assistant.sql`).
    #
    # One row per billed streaming turn — written by `Stream::Session`
    # inside the turn-persistence transaction when the turn reports real
    # token counts. `total_for_account` is the query surface any future
    # limit check or admin view calls: exact per-account input/output
    # totals over a `recorded_at` window.
    module Usage
      # Windowed token totals for one account.
      record Totals, input : Int64, output : Int64, total : Int64

      # Inserts one ledger row. `id` is a fresh ULID; `recorded_at` defaults
      # to `now()` (UTC) — pass an explicit timestamp to write outside the
      # default (specs use this to place rows inside or outside a query
      # window). `estimated` marks rows whose counts the provider never
      # reported on (the anti-siphon estimate for cancelled turns). Callers
      # run inside their own transaction (the stream session's turn
      # persistence), so failures roll back with it.
      def self.insert(
        db : DB::Connection,
        account_id : String,
        conversation_id : String,
        turn_id : String,
        model : String?,
        input_tokens : Int64,
        output_tokens : Int64,
        estimated : Bool = false,
        recorded_at : Time? = nil,
      ) : Nil
        if recorded_at
          db.exec(
            <<-SQL,
              INSERT INTO assistant_usage
                (id, account_id, conversation_id, turn_id, model, input_tokens, output_tokens,
                 estimated, recorded_at)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::timestamp)
            SQL
            Util::ScriptHelpers.ulid, account_id, conversation_id, turn_id,
            model, input_tokens, output_tokens, estimated,
            recorded_at.to_utc.to_rfc3339,
          )
        else
          db.exec(
            <<-SQL,
              INSERT INTO assistant_usage
                (id, account_id, conversation_id, turn_id, model, input_tokens, output_tokens,
                 estimated)
              VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            SQL
            Util::ScriptHelpers.ulid, account_id, conversation_id, turn_id,
            model, input_tokens, output_tokens, estimated,
          )
        end
      end

      # Sums the token totals of one account over a `recorded_at` window.
      # `since` is inclusive, `to` exclusive; `nil` leaves a bound open.
      # Both bounds convert to UTC RFC-3339 before binding — the column is
      # tz-naive and stores UTC (see `doc/backend/workflow.md` → Time /
      # Timezone). An unknown account or an empty window yields zeros.
      def self.total_for_account(
        db : DB::Connection,
        account_id : String,
        since : Time? = nil,
        to : Time? = nil,
      ) : Totals
        clauses = ["account_id = $1"]
        params = [account_id] of ::DB::Any
        if since
          clauses << "recorded_at >= $#{params.size + 1}::timestamp"
          params << since.to_utc.to_rfc3339
        end
        if to
          clauses << "recorded_at < $#{params.size + 1}::timestamp"
          params << to.to_utc.to_rfc3339
        end

        db.query_one(
          <<-SQL,
            SELECT
              COALESCE(SUM(input_tokens), 0)::bigint,
              COALESCE(SUM(output_tokens), 0)::bigint
            FROM assistant_usage
            WHERE #{clauses.join(" AND ")}
          SQL


          args: params,
        ) do |rs|
          input = rs.read(Int64)
          output = rs.read(Int64)
          Totals.new(input, output, input + output)
        end
      end
    end
  end
end
