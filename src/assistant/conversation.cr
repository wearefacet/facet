# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"
require "../util/time_helper"
require "../util/like_escape"
require "./config"

module Facet
  module Assistant
    # Storage service for the `agent_conversations` table (`db/migrations/0005_assistant.sql`).
    #
    # A conversation is one `Agent` session. This service persists the stable
    # identity (`session_id`, `cache_key`) and the conversation-stored prompt
    # — everything the replay needs to reconstruct the session via `Agent#load`.
    # The model and the sampling knobs are NOT pinned here: with runtime
    # settings the assistant connection resolves from the effective settings at
    # every turn start (`SystemSettings::AssistantView`), so a settings change
    # reaches existing conversations on their next turn. See
    # `doc/backend/agent-conversations.md`.
    module Conversation
      # A row from `agent_conversations`.
      record Record,
        id : String,
        session_id : String,
        cache_key : String,
        system_prompt : String?,
        context : JSON::Any,
        enabled_tools : JSON::Any,
        created_at : Time,
        updated_at : Time,
        archived_at : Time?

      module Result
        record Created, record : Record
      end

      # Default items per page for `list`.
      DEFAULT_ITEMS = 100

      # Allow-list of sortable column names on `agent_conversations`.
      SORTABLE_COLUMNS = Set{"id", "created_at", "updated_at"}

      # Allow-list of filterable plain columns (everything except the jsonb
      # `context` / `enabled_tools` columns, which are handled separately via
      # jsonb containment). The plain columns on `agent_conversations` are all
      # `text` or `timestamp`; `Util::FilterSet` is hardwired to
      # `content->>'field'` (the JSONB projection column) and so cannot be
      # reused here.
      COLUMN_FILTERS = Set{"id", "session_id", "cache_key", "created_at", "updated_at"}

      # Subset of `COLUMN_FILTERS` whose Postgres type is `timestamp` rather
      # than `text`. Comparison against these casts both sides to
      # `timestamptz` so callers can pass ISO-8601 strings.
      TIMESTAMP_COLUMNS = Set{"created_at", "updated_at"}

      # Operators accepted on plain text columns.
      TEXT_OPS = Set{"eq", "ne", "match"}
      # Operators accepted on timestamp columns (`match` does not apply).
      TIMESTAMP_OPS = Set{"eq", "ne", "gt", "gte", "lt", "lte"}

      # Inserts a new conversation row.
      #
      # `session_id` and `cache_key` come from the live `Agent` instance and
      # must stay stable across all turns of the conversation to keep the
      # provider KV cache hot. Caller is responsible for supplying values that
      # match the `Agent` that will own this conversation.
      #
      # `context` is free-form jsonb describing what the conversation is for —
      # see `doc/backend/agent-conversations.md`. `enabled_tools` is the array
      # of tool **names** that were enabled (mirrors `Agent#dump`).
      def self.create(
        db : DB::Connection,
        session_id : String,
        cache_key : String,
        system_prompt : String?,
        context : String = "{}",
        enabled_tools : String = "[]",
      ) : Result::Created | Facet::ServiceError
        row = db.query_one?(
          <<-SQL,
            INSERT INTO agent_conversations
              (session_id, cache_key, system_prompt, context, enabled_tools)
            VALUES ($1, $2, $3, $4::jsonb, $5::jsonb)
            RETURNING id, session_id, cache_key, system_prompt, context,
                      enabled_tools, created_at, updated_at, archived_at
          SQL
          args: [session_id, cache_key, system_prompt, context, enabled_tools],
        ) do |rs|
          read_record(rs)
        end

        return Facet::ServiceError.new(500, "Conversation insert returned no row") unless row

        Result::Created.new(row)
      rescue ex : DB::Error
        Facet::ServiceError.new(500, "Database error: #{ex.message}")
      end

      # Fetches a conversation by primary key.
      def self.find(db : DB::Connection, id : String) : Record?
        db.query_one?(
          "SELECT id, session_id, cache_key, system_prompt, context,
                  enabled_tools, created_at, updated_at, archived_at
           FROM agent_conversations WHERE id = $1",
          id,
        ) do |rs|
          read_record(rs)
        end
      end

      # Touches `updated_at` on the conversation. Called by `Turn.create` to
      # keep the parent's `updated_at` in step with the latest turn.
      def self.touch(db : DB::Connection, id : String) : Nil
        db.exec("UPDATE agent_conversations SET updated_at = now() WHERE id = $1", id)
      end

      # Sets or clears the archive timestamp on a conversation.
      #
      # `archived = true` stamps `archived_at` with `now()`; `false` clears it.
      # Returns `true` when the row exists — the caller answers a missing row
      # with 404. Archiving is list-organisation only: an archived conversation
      # stays readable and streamable, and its next turn clears the flag
      # (`Turn.open` / `Turn.create` call `unarchive`).
      def self.set_archived(db : DB::Connection, id : String, archived : Bool) : Bool
        row = db.query_one?(
          "UPDATE agent_conversations
           SET archived_at = CASE WHEN $2 THEN now() ELSE NULL END
           WHERE id = $1
           RETURNING id",
          id, archived,
        ) { |rs| rs.read(String) }
        row != nil
      end

      # Clears the archive flag when it is set — the turn writers
      # (`Turn.open`, `Turn.create`) call it, so activity on a conversation
      # unarchives it. The WHERE guard keeps a live conversation a no-op write.
      def self.unarchive(db : DB::Connection, id : String) : Nil
        db.exec(
          "UPDATE agent_conversations SET archived_at = NULL WHERE id = $1 AND archived_at IS NOT NULL",
          id,
        )
      end

      # Auto-titles a conversation. Called once by the stream route after the
      # first turn opens (`idx == 1`) with the user's message text: collapsed
      # whitespace, trimmed, capped at 60 characters. The title lives in the
      # free-form `context` jsonb under `title` — no migration — and the typed
      # context parsers (workspace, domain-builder, app) read only their own
      # keys, so the extra member is inert to them. A conversation that
      # already carries a title is never re-titled (the WHERE guard makes the
      # write a no-op), so an explicit rename survives later turns.
      def self.set_title(db : DB::Connection, id : String, title : String) : Nil
        db.exec(
          "UPDATE agent_conversations " \
          "SET context = context || jsonb_build_object('title', $2::text) " \
          "WHERE id = $1 AND NOT (context ? 'title')",
          id, title,
        )
      end

      # Explicit rename from the PATCH door: sets or clears `context.title`.
      # Unlike {@link set_title} this overwrites any stored title, and
      # `nil` removes the member. Returns `true` when the row exists — the
      # caller answers a missing row with 404.
      def self.rename(db : DB::Connection, id : String, title : String?) : Bool
        row = if title
                db.query_one?("UPDATE agent_conversations SET context = jsonb_set(context, '{title}', to_jsonb($2)) WHERE id = $1 RETURNING id", id, title) { |rs| rs.read(String) }
              else
                db.query_one?("UPDATE agent_conversations SET context = context - 'title' WHERE id = $1 RETURNING id", id) { |rs| rs.read(String) }
              end
        row != nil
      end

      # Lists conversations with filtering, sorting, and pagination.
      #
      # Filters use the same `field__op` convention as `Document::List`:
      #
      # - `context.<key>__eq=value` — jsonb containment on `context`.
      #   Multiple `context.<key>` filters are merged into a single jsonb
      #   object and applied with `context @> $N::jsonb`.
      # - `<column>__op=value` — direct comparison on a known column
      #   (`id`, `session_id`, `cache_key`, `created_at`, `updated_at`).
      #   Supports `eq`/`ne`/`gt`/`gte`/`lt`/`lte`/`match`.
      # - `archived__eq=true` — archived rows only. Without it (or with any
      #   other value) the list shows live rows only: archived conversations
      #   stay hidden until a caller asks for them.
      #
      # Sort keys are validated against `SORTABLE_COLUMNS` and may be
      # prefixed with `-` for descending. The default is `-updated_at` so the
      # conversation with the most recently added turn surfaces first
      # (`Turn.create` calls `touch` on the parent).
      def self.list(
        db : DB::Connection,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        sort : Array(String) = ["-updated_at"],
        items : Int32 = DEFAULT_ITEMS,
        offset : Int32 = 0,
      ) : Array(Record)
        where_sql, params = build_where_clause(filters)
        order_sql = build_order_clause(sort)

        rows = [] of Record
        db.query(
          "SELECT id, session_id, cache_key, system_prompt, context,
                  enabled_tools, created_at, updated_at, archived_at
           FROM agent_conversations
           WHERE #{where_sql}
           ORDER BY #{order_sql}
           LIMIT $#{params.size + 1} OFFSET $#{params.size + 2}",
          args: params + [items, offset] of ::DB::Any,
        ) do |rs|
          rs.each { rows << read_record(rs) }
        end
        rows
      end

      # Returns the capped count of conversations matching `filters`, from
      # `offset`, bounded by the shared `COUNT_CAP`. The caller reads `more`
      # as "counting was truncated". Applies the same archive visibility as
      # `list` (live-only unless `archived__eq=true`).
      def self.count(db : DB::Connection, filters : Hash(String, JSON::Any), offset : Int32) : Int64
        where_sql, params = build_where_clause(filters)
        db.query_one(
          "SELECT COUNT(*) FROM (
             SELECT 1 FROM agent_conversations
             WHERE #{where_sql}
             LIMIT #{Facet::HTTP::Responders::COUNT_CAP + 1} OFFSET #{offset}
           ) AS sub",
          args: params,
          as: Int64,
        )
      end

      # Serialises a record to the JSON-ready hash the HTTP surfaces render
      # as the `data` member. Shared by the conversation, domain-builder,
      # and workspace routes, so all three emit the same response shape.
      #
      # `active` is the derived conversation status the chat UI renders as a
      # running icon in the rail: true while the conversation has a
      # `running` turn (`Turn.running?` for a single row,
      # `Turn.running_conversation_ids` for a list). Create routes pass the
      # default — a brand-new conversation cannot have one.
      def self.api_hash(record : Record, active : Bool = false)
        {
          id:            record.id,
          session_id:    record.session_id,
          cache_key:     record.cache_key,
          system_prompt: record.system_prompt,
          context:       record.context,
          # Auto-title (or rename) — lifted out of `context` so every
          # consumer reads one flat key instead of digging into the jsonb.
          title:         record.context.as_h?.try(&.["title"]?.try(&.as_s?)),
          enabled_tools: record.enabled_tools,
          created_at:    record.created_at,
          updated_at:    record.updated_at,
          archived_at:   record.archived_at,
          active:        active,
        }
      end

      # ── Private helpers ──────────────────────────────────────────────────

      # Builds the WHERE clause and its bound parameters from `filters`.
      #
      # The archive visibility clause is always present: live rows only,
      # unless `archived__eq=true` flips it to archived rows only. On top of
      # it, two kinds of filters are accepted:
      #
      # - `context.<key>__eq=value` — collected into a single jsonb object
      #   and applied as `context @> $N::jsonb`. Only `eq` is supported on
      #   context keys (jsonb containment is equality on a subset).
      # - `<column>__op=value` where `<column>` is in `COLUMN_FILTERS` —
      #   compiled inline (see `build_column_clause`).
      #
      # Unknown filter keys are silently ignored — the vocabulary here is a
      # fixed internal set, not a doctype field list (the document API
      # validates its filter keys instead).
      private def self.build_where_clause(filters : Hash(String, JSON::Any)) : {String, Array(::DB::Any)}
        clauses = [archive_visibility_clause(filters["archived__eq"]?)]
        params = [] of ::DB::Any

        context_obj = {} of String => JSON::Any
        column_filters = {} of String => JSON::Any

        filters.each do |key, value|
          field, op = parse_filter_key(key)
          if field.starts_with?("context.")
            # Only `eq` is meaningful for jsonb containment.
            next unless op == "eq"
            ctx_key = field[8..]
            next if ctx_key.empty?
            context_obj[ctx_key] = value
          elsif COLUMN_FILTERS.includes?(field)
            column_filters[key] = value
          end
        end

        column_filters.each do |key, value|
          clause, vals = build_column_clause(key, value, params.size)
          clauses << clause
          params.concat(vals)
        end

        unless context_obj.empty?
          clauses << "context @> $#{params.size + 1}::jsonb"
          params << context_obj.to_json
        end

        {clauses.join(" AND "), params}
      end

      # The archive visibility clause. `archived__eq=true` selects archived
      # rows; every other value — including a missing or malformed one —
      # keeps the live-only default, so a bad filter can never widen the
      # result past the caller's ask.
      private def self.archive_visibility_clause(value : JSON::Any?) : String
        requested = case raw = value.try(&.raw)
                    when Bool
                      raw
                    when String
                      raw.downcase == "true"
                    else
                      false
                    end
        requested ? "archived_at IS NOT NULL" : "archived_at IS NULL"
      end

      # Builds a single SQL WHERE clause fragment for a plain column filter.
      #
      # Text columns support `eq`/`ne`/`match` (ILIKE). Timestamp columns
      # support `eq`/`ne`/`gt`/`gte`/`lt`/`lte` with the bound value cast to
      # `timestamptz` so callers can pass ISO-8601 strings. Other operator/
      # column combinations degrade to a `FALSE` clause (a bad filter should
      # not 500 the request).
      private def self.build_column_clause(key : String, value : JSON::Any, idx : Int32) : {String, Array(::DB::Any)}
        field, op = parse_filter_key(key)
        n = idx + 1
        val = case raw = value.raw
              when String, Int64, Float64, Bool, Nil
                raw
              else
                raw.to_s
              end

        if TIMESTAMP_COLUMNS.includes?(field)
          build_timestamp_column_clause(field, op, val, n)
        else
          return {"FALSE", [] of ::DB::Any} unless TEXT_OPS.includes?(op)
          case op
          when "eq" then {"#{field} = $#{n}", [val] of ::DB::Any}
          when "ne" then {"#{field} IS DISTINCT FROM $#{n}", [val] of ::DB::Any}
          when "match"
            # Same escaped-substring contract as `Util::FilterSet`: the
            # caller passes a plain substring; `%` / `_` are matched
            # literally, never as ILIKE wildcards.
            {"#{field} ILIKE '%' || $#{n} || '%' ESCAPE '\\'",
             [Util::LikeEscape.escape(val.to_s)] of ::DB::Any}
          else {"FALSE", [] of ::DB::Any}
          end
        end
      end

      # Builds a comparison clause against a timestamp column. Resolves the
      # ISO‑8601 input (or a relative date such as `-7d`) to UTC RFC‑3339
      # before binding: the `created_at` / `updated_at` columns are tz‑naive
      # and store UTC, so a bare `text::timestamp` cast would silently drop
      # any timezone offset supplied by the caller. Casting to `::timestamp`
      # (rather than `::timestamptz`) avoids the crossed tz‑aware vs tz‑naive
      # comparison. A relative `lte` bound takes the calendar reading of its
      # day (end of day); every other operator keeps the exact instant.
      private def self.build_timestamp_column_clause(
        field : String,
        op : String,
        val : ::DB::Any,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        return {"FALSE", [] of ::DB::Any} unless TIMESTAMP_OPS.includes?(op)
        return {"FALSE", [] of ::DB::Any} unless val.is_a?(String)

        resolved = Util::TimeHelper.resolve_bound(val)
        return {"FALSE", [] of ::DB::Any} unless resolved
        resolved = Util::TimeHelper.day_edge(resolved, :end) if op == "lte" && Util::TimeHelper.relative?(val)
        {"#{field} #{sql_operator(op)} $#{n}::timestamp", [resolved] of ::DB::Any}
      end

      # Maps an operator suffix to its SQL operator.
      private def self.sql_operator(op : String) : String
        case op
        when "gt"  then ">"
        when "gte" then ">="
        when "lt"  then "<"
        when "lte" then "<="
        else            "="
        end
      end

      # Parses a filter key like `"updated_at__gte"` into `{"updated_at", "gte"}`.
      private def self.parse_filter_key(key : String) : {String, String}
        if key.includes?("__")
          parts = key.split("__", 2)
          {parts[0], parts[1]}
        else
          {key, "eq"}
        end
      end

      # Builds the ORDER BY clause from `sort` keys, validating each against
      # `SORTABLE_COLUMNS`. Falls back to `updated_at DESC` when no valid sort
      # remains (matches the `list` default).
      #
      # Afinal `id` tiebreaker is appended whenever the primary sort is not
      # already `id`. `updated_at` has microsecond resolution, so two rows
      # can share the same instant when their writes land in the same
      # transaction. Without a tiebreaker, `ORDER BY updated_at DESC` returns
      # ties in arbitrary order — which produced a flaky list test where
      # the touched conversation did not reliably surface first. The `id`
      # column is a ULID (time-sortable), so it gives a deterministic and
      # intuitively correct order: newest activity first, ties broken by
      # newest creation.
      private def self.build_order_clause(sort : Array(String)) : String
        order_clauses = sort.compact_map do |field|
          dir = field.starts_with?("-") ? "DESC" : "ASC"
          col = field.starts_with?("-") ? field[1..] : field
          next unless SORTABLE_COLUMNS.includes?(col)
          "#{col} #{dir}"
        end
        if order_clauses.empty?
          order_clauses = ["updated_at DESC"]
        end
        unless order_clauses.any?(&.starts_with?("id "))
          order_clauses << "id DESC"
        end
        order_clauses.join(", ")
      end

      # Reads a record from the current row of a result set.
      private def self.read_record(rs : DB::ResultSet) : Record
        Record.new(
          id: rs.read(String),
          session_id: rs.read(String),
          cache_key: rs.read(String),
          system_prompt: rs.read(String?),
          context: rs.read(JSON::Any),
          enabled_tools: rs.read(JSON::Any),
          created_at: rs.read(Time),
          updated_at: rs.read(Time),
          archived_at: rs.read(Time?),
        )
      end
    end
  end
end
