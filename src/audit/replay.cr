# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../mutation/json_diff"

module Facet
  module Audit
    # Shared replay of one document's mutation history.
    #
    # `Audit::Rollback` replays content to a target mutation and persists
    # the result as a snapshot; `Cron::MutationCompaction` replays the
    # document state at the retention cut so the synthetic compaction
    # snapshot can replace the history below it. The replay rules are one
    # concern — this module owns them so the two services cannot drift.
    #
    # Replay starts at the most recent `snapshot` mutation with
    # `idx <= target_idx` (or `{}` when none exists) and applies every row
    # from `start_idx + 1` through `target_idx`:
    #
    # - `create`  → content and meta from `arguments`, `version = 1`,
    #   `created_at` from the row's `emitted_at`
    # - `update`  → apply `diff` to content and `meta_diff` to meta
    #   (`Mutation::JsonDiff.apply_diff`)
    # - `snapshot` → overwrite all four fields from `arguments`
    # - `delete`  → no-op (a delete target is resolved to the pre-delete
    #   mutation before replay runs, so a delete here is only passed
    #   through — e.g. create → delete → create)
    module Replay
      # The document state as of one mutation index.
      record State,
        content : JSON::Any,
        meta : JSON::Any,
        version : Int32,
        created_at : String

      # The state of one document as of `target_idx`, replayed from the
      # last snapshot at or below `target_idx`.
      def self.state_at(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        target_idx : Int32,
      ) : State
        snapshot = find_last_snapshot(db, domain, doc_type, doc_id, target_idx)
        start_idx, state = resolve_replay_start(snapshot)
        replay_forward(db, domain, doc_type, doc_id, start_idx, target_idx, state)
      end

      # ── Private ────────────────────────────────────────────────────────

      # The replay start point carried by the last snapshot at or below
      # the target, or `{}` with idx 0 when the document has no snapshot
      # below the target.
      private record SnapshotStart,
        idx : Int32,
        state : State

      # Finds the most recent snapshot mutation with idx <= target_idx.
      private def self.find_last_snapshot(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        target_idx : Int32,
      ) : SnapshotStart?
        db.query_one?(
          <<-SQL,
            SELECT idx, arguments->'content' AS content, arguments->'meta' AS meta,
                   COALESCE((arguments->>'version')::int, 1) AS version,
                   arguments->>'created_at' AS created_at
            FROM mutations
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3
              AND action = 'snapshot'
              AND idx <= $4
            ORDER BY idx DESC
            LIMIT 1
          SQL
          domain, doc_type, doc_id, target_idx
        ) do |rs|
          idx = rs.read(Int32)
          content = rs.read(JSON::Any)
          meta = rs.read(JSON::Any)
          version = rs.read(Int32)
          created_at = rs.read(String?)
          SnapshotStart.new(
            idx: idx,
            state: State.new(
              content: content,
              meta: meta,
              version: version,
              created_at: created_at || Time.utc.to_rfc3339,
            ),
          )
        end
      end

      # Resolves the replay start point from an optional snapshot.
      private def self.resolve_replay_start(snapshot : SnapshotStart?) : {Int32, State}
        if snap = snapshot
          {snap.idx, snap.state}
        else
          {0, empty_state}
        end
      end

      private def self.empty_state : State
        State.new(
          content: JSON.parse("{}"),
          meta: JSON.parse("{}"),
          version: 1,
          created_at: Time.utc.to_rfc3339,
        )
      end

      # The `version` field of a snapshot's arguments, as Int32.
      private def self.snapshot_version(arguments : JSON::Any) : Int32
        arguments["version"]?.try(&.as_i?).try(&.to_i32) || 1
      end

      # Replays mutations forward from start_idx+1 to target_idx.
      private def self.replay_forward(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        start_idx : Int32,
        target_idx : Int32,
        initial : State,
      ) : State
        state = initial
        replay_mutations(db, domain, doc_type, doc_id, start_idx, target_idx) do |action, arguments, emitted_at|
          case action
          when "create"
            state = State.new(
              content: arguments["content"]? || JSON.parse("{}"),
              meta: arguments["meta"]? || JSON.parse("{}"),
              version: 1,
              created_at: emitted_at.to_rfc3339,
            )
          when "update"
            state = apply_update(state, arguments)
          when "snapshot"
            state = State.new(
              content: arguments["content"]? || JSON.parse("{}"),
              meta: arguments["meta"]? || JSON.parse("{}"),
              version: snapshot_version(arguments),
              created_at: arguments["created_at"]?.try(&.as_s?) || emitted_at.to_rfc3339,
            )
          when "delete"
            # Passed through only when a later create/snapshot overwrites
            # the content (see the module doc).
          end
        end
        state
      end

      # Applies one `update` row's diffs to the replay state.
      private def self.apply_update(state : State, arguments : JSON::Any) : State
        content = state.content
        if diff = arguments["diff"]?
          content = Mutation::JsonDiff.apply_diff(content, diff)
        end
        meta = state.meta
        if meta_diff = arguments["meta_diff"]?
          meta = Mutation::JsonDiff.apply_diff(meta, meta_diff)
        end
        State.new(content: content, meta: meta, version: state.version, created_at: state.created_at)
      end

      # Yields each mutation (action, arguments, emitted_at) in order from
      # start_idx+1 to target_idx.
      #
      # The block form closes the `ResultSet` on every path — a raising
      # consumer (a rollback refusing a document, a compaction replay
      # failing) must not leave the response frames queued on the pinned
      # connection (see `src/database/wire_guard.cr`).
      private def self.replay_mutations(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        start_idx : Int32,
        target_idx : Int32,
        & : String, JSON::Any, Time -> Nil
      ) : Nil
        db.query(
          <<-SQL,
            SELECT action, arguments, emitted_at
            FROM mutations
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3
              AND idx > $4 AND idx <= $5
            ORDER BY idx ASC
          SQL
          domain, doc_type, doc_id, start_idx, target_idx
        ) do |rs|
          rs.each do
            action = rs.read(String)
            arguments = rs.read(JSON::Any)
            emitted_at = rs.read(Time)
            yield action, arguments, emitted_at
          end
        end
      end
    end
  end
end
