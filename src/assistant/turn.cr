# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"

module Facet
  module Assistant
    # Storage service for the `agent_turns` table (`db/migrations/0005_assistant.sql`).
    #
    # Each turn is one `Agent#ask` invocation. The row is written at turn
    # start (`Turn.open`) with `status = 'running'` and only its request
    # messages, then updated at the turn's exit path (`Turn.complete`) with
    # the terminal `status`, the response messages, and the usage. The exact
    # input/output message sequence is stored as jsonb so that concatenating
    # turns in `idx` order reproduces the agent's full history array — the
    # same array `Agent#dump` would emit. This is what `Agent#load` consumes
    # to resume a session.
    #
    # ## Status lifecycle
    #
    # | Status       | Meaning |
    # |--------------|---------|
    # | `running`    | The turn was opened and the agent is working. At most one per conversation — enforced by the partial unique index `idx_agent_turns_one_running`. |
    # | `done`       | Normal completion; `finish_reason` is set. |
    # | `cancelled`  | User cancel (or a client refresh treated as one); the partial response is kept in `response_messages` and `error` is `"cancelled"`. A terminal refusal lands here too: when the model repeats a final refused tool call, `TerminalRefusalStop` cancels the response, so the turn exits through this same path. Deliberate — no status or meta marks the refusal. The turn's tool trace is the only differentiator: the terminal envelope rides a `tool_call` chunk with `status = "error"`. |
    # | `capped`     | The tool loop hit the agent's iteration cap (`Stream::Session#handle_capped`); the partial exchange is kept in `response_messages`, `error` carries the raw cap message, and `Resume` replays it. |
    # | `error`      | Provider error, an unexpected exception, or a provider stream that ended before completion. `error` carries the message; truncated streams prefix it with `truncated: `. `response_messages` stays empty when the failure hit before any output, and MAY carry the partial exchange when the turn streamed output first. A stale `running` row is swept to this state with `error = "interrupted"`. |
    #
    # The running row makes an in-flight turn observable: the 409
    # concurrent-stream guard, the conversation `active` flag, and the
    # frontend catch-up poll all read it.
    #
    # See `doc/backend/agent-conversations.md` for the replay procedure.
    module Turn
      # A row from `agent_turns` (message columns surfaced as `JSON::Any`).
      # `turn_token` is the streaming cancel token (nil for manual rows).
      record Record,
        id : String,
        conversation_id : String,
        idx : Int32,
        request_messages : JSON::Any,
        response_messages : JSON::Any,
        status : String,
        usage : JSON::Any,
        finish_reason : String?,
        error : String?,
        turn_token : String?,
        created_at : Time

      # Lightweight latest-row summary for the catch-up poll. Polling is cheap
      # even on long conversations: only the one latest row is read. The row's
      # messages ride along so a client that reloads mid-turn can render the
      # running turn's checkpointed partial exchange while it generates.
      # `turn_token` lets that client re-arm the cancel button against the
      # still-running row.
      record Summary,
        id : String,
        idx : Int32,
        status : String,
        finish_reason : String?,
        error : String?,
        turn_token : String?,
        created_at : Time,
        request_messages : JSON::Any,
        response_messages : JSON::Any

      module Result
        record Created, record : Record
        # The partial unique index `idx_agent_turns_one_running` rejected the
        # insert — another turn is already running on this conversation.
        record Conflict
      end

      # Opens a turn: inserts the `running` row with the request messages.
      #
      # `turn_token` is the streaming cancel token; the stream route generates
      # it before the open and passes the same value to `Stream::Session`, so
      # the persisted row and the live cancel channel agree from the start.
      #
      # `idx` is computed via `MAX(idx) + 1`. The insert races on the
      # `idx_agent_turns_one_running` partial unique index, not on a
      # read-then-check; the database decides, so two concurrent opens
      # cannot both run. Callers treat `Conflict` as HTTP 409.
      def self.open(
        db : DB::Connection,
        conversation_id : String,
        request_messages_json : String,
        turn_token : String? = nil,
      ) : Result::Created | Result::Conflict | Facet::ServiceError
        row = db.query_one?(
          <<-SQL,
            WITH next_idx AS (
              SELECT COALESCE(MAX(idx), 0) + 1 AS v
              FROM agent_turns WHERE conversation_id = $1
            )
            INSERT INTO agent_turns
              (conversation_id, idx, request_messages, status, turn_token)
            VALUES ($1, (SELECT v FROM next_idx), $2, 'running', $3)
            RETURNING id, conversation_id, idx, request_messages, response_messages,
                      status, usage, finish_reason, error, turn_token, created_at
          SQL
          args: [conversation_id, request_messages_json, turn_token],
        ) do |rs|
          read_record(rs)
        end

        return Facet::ServiceError.new(500, "Turn open returned no row") unless row

        Conversation.touch(db, conversation_id)
        Conversation.unarchive(db, conversation_id)

        Result::Created.new(row)
      rescue ex : PQ::PQError
        conflict?(ex) ? Result::Conflict.new : Facet::ServiceError.new(500, "Database error: #{ex.message}")
      rescue ex : DB::Error
        Facet::ServiceError.new(500, "Database error: #{ex.message}")
      end

      # Completes a turn: updates the row opened by `Turn.open` with its
      # terminal state. Runs inside the caller's transaction together with
      # the usage-ledger write.
      #
      # The update targets the row by `id` alone — a row swept to
      # `error`/`interrupted` in the meantime is overwritten by the real
      # outcome, which is the truth the turn actually reached.
      def self.complete(
        db : DB::Connection,
        turn_id : String,
        response_messages_json : String,
        usage_json : String,
        status : String,
        finish_reason : String? = nil,
        error : String? = nil,
      ) : Bool
        row = db.query_one?(
          <<-SQL,
            UPDATE agent_turns
            SET response_messages = $2::jsonb,
                usage             = $3::jsonb,
                status            = $4,
                finish_reason     = $5,
                error             = $6
            WHERE id = $1
            RETURNING id
          SQL
          args: [turn_id, response_messages_json, usage_json, status, finish_reason, error],
        ) { |rs| rs.read(String) }

        row != nil
      rescue ex : DB::Error
        Log.error { "Failed to complete turn #{turn_id}: #{ex.message}" }
        false
      end

      # Inserts a fully formed (already terminal) turn row. Exists for the
      # manual `POST /:id/turns` route and for the `Turn::open` fallback in
      # `Session` — normal streaming turns go through `open` + `complete`.
      #
      # The status derives from `error`: `"cancelled"` maps to the
      # `cancelled` status, any other error to `error`, otherwise `done`.
      #
      # `idx` is computed via `MAX(idx) + 1` within the caller-supplied
      # transaction — callers MUST hold a transaction (e.g. via
      # `Facet::Database.with_transaction`) so the read-then-write is
      # atomic with respect to concurrent turns on the same conversation.
      #
      # `request_messages_json` and `response_messages_json` are expected to be
      # `JSON.build`-shaped strings carrying arrays of serialised
      # `Agent::Message` objects. `usage_json` is a serialised `Agent::Usage`.
      # Either `finish_reason` (happy path) or `error` (failed turn) may be
      # nil; at least one is expected in practice.
      def self.create(
        db : DB::Connection,
        conversation_id : String,
        request_messages_json : String,
        response_messages_json : String,
        usage_json : String,
        finish_reason : String? = nil,
        error : String? = nil,
      ) : Result::Created | Facet::ServiceError
        record = create!(
          db,
          conversation_id,
          request_messages_json,
          response_messages_json,
          usage_json,
          status: derive_status(error),
          finish_reason: finish_reason,
          error: error,
        )
        return Facet::ServiceError.new(500, "Turn insert returned no row") unless record

        Conversation.touch(db, conversation_id)
        Conversation.unarchive(db, conversation_id)

        Result::Created.new(record)
      rescue ex : PQ::PQError
        Facet::ServiceError.new(500, "Database error: #{ex.message}")
      rescue ex : DB::Error
        Facet::ServiceError.new(500, "Database error: #{ex.message}")
      end

      # Inserts a terminal turn row inside an OPEN transaction.
      # Fallback for `Session#fail_terminal` when `Turn.open` never
      # produced a row — the terminal outcome still lands for
      # observability, bypassing the one-running-turn invariant.
      def self.create_terminal(
        tx : DB::Connection,
        conversation_id : String,
        request_messages_json : String,
        usage_json : String,
        error : String,
      ) : Result::Created | Facet::ServiceError
        record = create!(
          tx,
          conversation_id,
          request_messages_json,
          "[]",
          usage_json,
          status: "error",
          finish_reason: nil,
          error: error,
        )
        return Facet::ServiceError.new(500, "Terminal turn insert returned no row") unless record

        Result::Created.new(record)
      end

      # Returns the running row for a conversation, or nil. The one-running
      # invariant makes a single-row read sufficient.
      def self.running_turn(db : DB::Connection, conversation_id : String) : Record?
        read_one(
          db,
          "SELECT id, conversation_id, idx, request_messages, response_messages,
                  status, usage, finish_reason, error, turn_token, created_at
           FROM agent_turns
           WHERE conversation_id = $1 AND status = 'running'
           ORDER BY idx ASC
           LIMIT 1",
          conversation_id,
        )
      end

      # True when the conversation has a `running` turn — the conversation
      # `active` flag the conversation list and get surfaces render. The
      # partial index `idx_agent_turns_one_running` makes the probe a
      # one-row index lookup.
      def self.running?(db : DB::Connection, conversation_id : String) : Bool
        db.query_one(
          "SELECT EXISTS (
             SELECT 1 FROM agent_turns
             WHERE conversation_id = $1 AND status = 'running'
           )",
          conversation_id,
          as: Bool,
        )
      rescue ex : DB::Error
        Log.error { "Failed to probe running turn for #{conversation_id}: #{ex.message}" }
        false
      end

      # The ids of every conversation with a `running` turn — the batch read
      # behind the conversation list's per-row `active` flag. The partial
      # index keeps the scan proportional to the (tiny) running set, not the
      # table.
      def self.running_conversation_ids(db : DB::Connection) : Set(String)
        ids = Set(String).new
        db.query("SELECT DISTINCT conversation_id FROM agent_turns WHERE status = 'running'") do |rs|
          rs.each { ids << rs.read(String) }
        end
        ids
      rescue ex : DB::Error
        Log.error { "Failed to list running conversation ids: #{ex.message}" }
        Set(String).new
      end

      # Returns the latest turn row (by `idx`) as a `Summary`, or nil when
      # the conversation has no turns. The catch-up poll reads this to
      # learn whether the in-flight turn reached its terminal state, and
      # renders the messages while the row is still `running`.
      def self.latest(db : DB::Connection, conversation_id : String) : Summary?
        db.query_one?("SELECT id, idx, status, finish_reason, error, turn_token, created_at,
                          request_messages, response_messages
           FROM agent_turns
           WHERE conversation_id = $1
           ORDER BY idx DESC
           LIMIT 1",
          conversation_id,
        ) do |rs|
          Summary.new(
            id: rs.read(String),
            idx: rs.read(Int32),
            status: rs.read(String),
            finish_reason: rs.read(String?),
            error: rs.read(String?),
            turn_token: rs.read(String?),
            created_at: rs.read(Time),
            request_messages: rs.read(JSON::Any),
            response_messages: rs.read(JSON::Any),
          )
        end
      end

      # Persists the in-flight exchange of a `running` turn. The stream
      # session calls this on a cadence while the model works, so a client
      # that reloads mid-turn (or another device) sees the committed tool
      # calls and text grow instead of a bare `running` row.
      #
      # The update targets `status = 'running'` rows only — a checkpoint
      # that lands after `Turn.complete` is a no-op, so a late write can
      # never clobber a terminal outcome. Returns true when the row was
      # still running and got updated.
      def self.checkpoint(
        db : DB::Connection,
        turn_id : String,
        response_messages_json : String,
      ) : Bool
        row = db.query_one?("UPDATE agent_turns
            SET response_messages = $2::jsonb
            WHERE id = $1 AND status = 'running'
            RETURNING id",
          args: [turn_id, response_messages_json],
        ) { |rs| rs.read(String) }

        row != nil
      rescue ex : DB::Error
        Log.error { "Failed to checkpoint turn #{turn_id}: #{ex.message}" }
        false
      end

      # Returns the ordered turns for a conversation (by `idx`).
      def self.list(db : DB::Connection, conversation_id : String) : Array(Record)
        rows = [] of Record
        db.query(
          "SELECT id, conversation_id, idx, request_messages, response_messages,
                  status, usage, finish_reason, error, turn_token, created_at
           FROM agent_turns WHERE conversation_id = $1 ORDER BY idx ASC",
          conversation_id,
        ) do |rs|
          rs.each { rows << read_record(rs) }
        end
        rows
      end

      # Marks every stale `running` row as an `error` turn with message
      # `interrupted`. A running row older than `timeout_seconds` cannot
      # belong to a live process holding the SSE route: the process either
      # restarted (the turn died with it) or the runner is wedged far past
      # any legitimate turn. Called by `Cron::AssistantTurnSweep`.
      #
      # Returns the count of rows swept.
      def self.sweep_stale_running(db : DB::Connection, timeout_seconds : Int32) : Int32
        db.exec(
          <<-SQL,
            UPDATE agent_turns
            SET status = 'error', error = 'interrupted'
            WHERE status = 'running'
              AND created_at < now() - make_interval(secs => $1)
          SQL
          timeout_seconds,
        ).rows_affected.to_i32
      rescue ex : DB::Error
        Log.error { "Failed to sweep stale assistant turns: #{ex.message}" }
        0
      end

      # ── Private ────────────────────────────────────────────────────────

      Log = ::Log.for("facet.assistant.turn")

      # The shared insert used by `create` and `create_terminal`. Callers
      # handle the `Conversation.touch` bookkeeping. Returns nil when the
      # INSERT .. RETURNING produced no row.
      private def self.create!(
        db : DB::Connection,
        conversation_id : String,
        request_messages_json : String,
        response_messages_json : String,
        usage_json : String,
        status : String,
        finish_reason : String?,
        error : String?,
      ) : Record?
        db.query_one?(
          <<-SQL,
            WITH next_idx AS (
              SELECT COALESCE(MAX(idx), 0) + 1 AS v
              FROM agent_turns WHERE conversation_id = $1
            )
            INSERT INTO agent_turns
              (conversation_id, idx, request_messages, response_messages, status, usage,
               finish_reason, error)
            VALUES ($1, (SELECT v FROM next_idx), $2::jsonb, $3::jsonb, $4, $5::jsonb, $6, $7)
            RETURNING id, conversation_id, idx, request_messages, response_messages,
                      status, usage, finish_reason, error, turn_token, created_at
          SQL
          args: [conversation_id, request_messages_json, response_messages_json,
                 status, usage_json, finish_reason, error],
        ) do |rs|
          read_record(rs)
        end
      end

      # Maps a turn `error` value onto the terminal status.
      private def self.derive_status(error : String?) : String
        case error
        when nil         then "done"
        when "cancelled" then "cancelled"
        else                  "error"
        end
      end

      # Reads a full turn row. The column order matches the SELECT in
      # every reader above.
      private def self.read_record(rs : DB::ResultSet) : Record
        Record.new(
          id: rs.read(String),
          conversation_id: rs.read(String),
          idx: rs.read(Int32),
          request_messages: rs.read(JSON::Any),
          response_messages: rs.read(JSON::Any),
          status: rs.read(String),
          usage: rs.read(JSON::Any),
          finish_reason: rs.read(String?),
          error: rs.read(String?),
          turn_token: rs.read(String?),
          created_at: rs.read(Time),
        )
      end

      private def self.read_one(
        db : DB::Connection,
        sql : String,
        conversation_id : String,
      ) : Record?
        db.query_one?(sql, conversation_id) do |rs|
          read_record(rs)
        end
      end

      # Detects the one-running-turn violation. crystal-pg surfaces server
      # errors as `PQ::PQError` whose field list carries the SQLSTATE under
      # the `:code` field and the constraint name under `:constraint_name`;
      # matching both pins the hit to the partial unique index instead of
      # any other constraint.
      private def self.conflict?(ex : PQ::PQError) : Bool
        field(ex, :code) == "23505" && field(ex, :constraint_name) == "idx_agent_turns_one_running"
      end

      private def self.field(ex : PQ::PQError, name : Symbol) : String?
        ex.fields.find { |f| f.name == name }.try(&.message)
      end
    end
  end
end
