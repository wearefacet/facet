# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../audit/replay"
require "../mutation/client"
require "../system_settings/service"
require "./pass"

module Facet
  module Cron
    # Bounds the `mutations` table by retention compaction: every
    # mutation older than the retention window is replaced by one
    # synthetic `snapshot` row (`cause_kind = 'compaction'`), so the
    # document's history stays replayable from the boundary while the
    # table stays bounded. See `doc/backend/mutation.md` → Retention
    # compaction.
    #
    # ## Algorithm (per document)
    #
    # 1. Resolve the window: `horizon = now() - retention_days` for the
    #    document's doctype (per-doctype override from config).
    # 2. Tombstone check first: for a tombstoned document the cut is
    #    clamped to `delete_idx - 2`, so the trailing `delete` and its
    #    predecessor always survive (`Audit::Restore` and
    #    rollback-to-delete resolve the predecessor).
    # 3. Find the cut: the newest row with `emitted_at <= horizon` (and
    #    `idx <= clamp`). No such row, or `cut_idx <= 1` — nothing to do.
    # 4. Short path: when the cut row is already a compaction snapshot,
    #    only the rows below it are deleted. Reruns are no-ops.
    # 5. Replay the document state at the cut (`Audit::Replay.state_at`)
    #    — before the delete, which removes the rows the replay reads.
    # 6. Delete the rows with `idx <= cut_idx`, then insert the compaction
    #    snapshot at `idx = cut_idx` under both trigger GUCs. The order is
    #    forced by the unique index `idx_mutations_doc_id_idx`: the row at
    #    `cut_idx` must be gone before the snapshot can take that idx.
    #
    # The projection is never touched and no events are emitted — the pass
    # changes no document state. `idx` stays contiguous: after the pass the
    # document's rows read `snapshot@cut_idx, cut_idx+1, …, N`.
    class MutationCompaction
      Log = ::Log.for("facet.cron.mutation_compaction")

      # Runs one compaction pass. The retention window resolves per pass
      # from the runtime settings (document → file → default), so an admin
      # change applies from the next daily run. A window of 0 disables
      # compaction for every doctype — including the file-side per-doctype
      # overrides; the pass logs the disable and touches nothing. The
      # overrides themselves stay file-only — deployment policy beyond the
      # settings page.
      def self.call : Nil
        Cron.run_pass("Mutation compaction") do |db|
          window = Mutation::Retention.base_days(db)
          if window.zero?
            Log.info { "compaction disabled: mutations.retention_days = 0 (keep forever)" }
            next 0
          end
          compact(db, retention_days: window,
            overrides: Facet::Config.instance.mutations.retention_overrides)
        end
      end

      # One compaction pass over every document that has a mutation older
      # than its doctype's window. Returns the number of mutation rows
      # removed (the synthetic snapshot adds one row back per compacted
      # document). A window of 0 or less deletes nothing — 0 means keep
      # forever — so an explicit 0 from the caller is safe.
      def self.compact(
        db : DB::Connection,
        retention_days : Int32,
        overrides : Hash(String, Int32) = {} of String => Int32,
      ) : Int32
        return 0 if retention_days <= 0
        touched = 0
        candidate_docs(db, retention_days, overrides).each do |domain, doc_type, doc_id|
          days = overrides["#{domain}.#{doc_type}"]? || retention_days
          touched += compact_document(db, domain, doc_type, doc_id, days)
        end
        touched
      end

      # ── Private ─────────────────────────────────────────────────────────

      # Documents with any row older than the smallest configured window.
      # The per-document pass applies the doctype's own window, so a
      # longer-window doctype surfaces here but is skipped there.
      private def self.candidate_docs(
        db : DB::Connection,
        retention_days : Int32,
        overrides : Hash(String, Int32),
      ) : Array({String, String, String})
        min_days = ([retention_days] + overrides.values).min
        db.query_all(
          <<-SQL,
            SELECT DISTINCT domain, doc_type, doc_id
            FROM mutations
            WHERE emitted_at <= now() - make_interval(days => $1)
          SQL
          min_days,
          as: {String, String, String}
        )
      end

      # Compacts one document. Returns the number of rows removed.
      private def self.compact_document(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        retention_days : Int32,
      ) : Int32
        clamp = tombstone_clamp(db, domain, doc_type, doc_id)
        return 0 if clamp.nil?

        cut = find_cut(db, domain, doc_type, doc_id, clamp, retention_days)
        return 0 if cut.nil?

        # Short path: the boundary is already a compaction snapshot — only
        # the rows below it can go. Makes reruns no-ops.
        if cut[:cause_kind] == "compaction"
          return delete_rows(db, domain, doc_type, doc_id, cut[:idx], inclusive: false)
        end

        Database.with_transaction(db, ignore_if_set: true) do |txn|
          # The replay must run before the delete — the delete removes the
          # rows the replay reads.
          state = Audit::Replay.state_at(txn, domain, doc_type, doc_id, cut[:idx])
          removed = delete_rows(txn, domain, doc_type, doc_id, cut[:idx], inclusive: true)
          insert_compaction_snapshot(txn, domain, doc_type, doc_id, cut, state)
          removed
        end
      end

      # The upper idx bound for the cut on a tombstoned document:
      # `delete_idx - 2`, so the trailing delete and its predecessor
      # survive. `nil` skips the document (live document → no clamp;
      # delete too close to the start → nothing safe to cut).
      private def self.tombstone_clamp(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Int32?
        last = db.query_one?(
          <<-SQL,
            SELECT idx, action FROM mutations
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3
            ORDER BY idx DESC
            LIMIT 1
          SQL
          domain, doc_type, doc_id
        ) do |rs|
          {idx: rs.read(Int32), action: rs.read(String)}
        end
        return Int32::MAX if last.nil? || last[:action] != "delete"

        clamp = last[:idx] - 2
        clamp >= 1 ? clamp : nil
      end

      # The newest row at or below the clamp whose `emitted_at` falls
      # inside the retention window. `nil` or `idx <= 1` means nothing to
      # compact — one row replaced by one row saves nothing.
      private def self.find_cut(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        clamp : Int32,
        retention_days : Int32,
      ) : NamedTuple(idx: Int32, emitted_at: Time, cause_kind: String)?
        cut = db.query_one?(
          <<-SQL,
            SELECT idx, emitted_at, cause_kind FROM mutations
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3
              AND idx <= $4
              AND emitted_at <= now() - make_interval(days => $5)
            ORDER BY idx DESC
            LIMIT 1
          SQL
          domain, doc_type, doc_id, clamp, retention_days
        ) do |rs|
          {idx: rs.read(Int32), emitted_at: rs.read(Time), cause_kind: rs.read(String)}
        end
        return nil if cut.nil? || cut[:idx] <= 1
        cut
      end

      # Deletes the rows up to `bound_idx` (`inclusive: true`) or strictly
      # below it (`inclusive: false`). Returns the number of rows removed.
      private def self.delete_rows(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        bound_idx : Int32,
        inclusive : Bool,
      ) : Int32
        operator = inclusive ? "<=" : "<"
        sql = "DELETE FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx #{operator} $4"
        db.exec(sql, domain, doc_type, doc_id, bound_idx).rows_affected.to_i
      end

      # Inserts the synthetic compaction snapshot at the cut row's position
      # under both trigger GUCs: the explicit idx keeps the row at
      # `cut_idx`, the bypass keeps the projection untouched.
      private def self.insert_compaction_snapshot(
        txn : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        cut : NamedTuple(idx: Int32, emitted_at: Time, cause_kind: String),
        state : Audit::Replay::State,
      ) : Nil
        txn.exec("SELECT set_config($1, $2, true)", "harness.bypass_projection_triggers", "on")
        Mutation::Client.compaction_snapshot(
          txn, domain, doc_type, doc_id,
          idx: cut[:idx],
          emitted_at: cut[:emitted_at],
          content: state.content.to_json,
          meta: state.meta.to_json,
          version: state.version,
          created_at: state.created_at,
        )
      end
    end
  end
end
