# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../system_settings/service"
require "./pass"

module Facet
  module Cron
    # Clears the bulky payload (`content`/`links`/`search`) from tombstones
    # that are older than the configured retention window.
    #
    # A delete tombstone keeps its pre-delete payload so per-emit RBAC
    # checks (e.g. WebSocket collection subscriptions) can scope-evaluate
    # `deleted` events against the content the principal could already
    # read. Clearing that payload is a storage concern only — nothing
    # reads tombstone content for feature purposes after the retention
    # window (audit history lives in the append-only `mutations` log and
    # `Audit::Rollback` replays from there, not from the projection row).
    #
    # ## Algorithm
    #
    # 1. Select ids of tombstones older than `tombstone.content_retention_days`
    #    whose payload is not already cleared (`content <> '{}'` OR
    #    `links <> '[]'` OR `search IS NOT NULL`).
    # 2. Clear `content`/`links`/`search` on those ids in one UPDATE per
    #    batch. Each batch is its own implicit transaction, so a failure
    #    does not roll back earlier batches and a rerun resumes from where
    #    the failed run left off.
    # 3. Repeat until a batch returns fewer ids than the batch size.
    #
    # `display_name` is never cleared — audit views label tombstoned rows
    # with it. Already-cleared tombstones do not match the payload
    # predicate, so repeated passes are no-ops (idempotent).
    class TombstoneContentPrune
      Log = ::Log.for("facet.cron.tombstone_content_prune")

      # The maximum number of ids per UPDATE batch. Caps the `ANY($2)`
      # array size so the bind payload stays bounded.
      BATCH_SIZE = 1000

      # Runs one prune pass. The retention window resolves per pass from
      # the runtime settings; a window of 0 disables the prune.
      def self.call : Nil
        Cron.run_pass("Tombstone content prune") do |db|
          window = runtime_retention_days(db)
          if window.zero?
            Log.info { "tombstone content prune disabled: content_retention_days = 0 (keep forever)" }
            next 0
          end
          prune(db, retention_days: window)
        end
      end

      # The window resolves per pass from the runtime settings
      # (document → file → default), so an admin change applies from the
      # next daily run without a restart. A window of 0 keeps every
      # tombstone payload forever.
      private def self.runtime_retention_days(db : DB::Connection) : Int32
        n = SystemSettings.int_at(db, "tombstone.content_retention_days")
        n.nil? || n < 0 ? Facet::Config.instance.tombstone.content_retention_days : n.to_i32
      end

      # Clears the payload on tombstones older than `retention_days`.
      # Returns the count of rows cleared. A window of 0 or less deletes
      # nothing — 0 means keep forever. Idempotent — already-pruned rows
      # do not match again.
      def self.prune(db : DB::Connection, retention_days : Int32) : Int32
        return 0 if retention_days <= 0
        total = 0
        loop do
          ids = select_expired_ids(db, retention_days)
          break if ids.empty?

          db.exec(
            <<-SQL,
              UPDATE projections
              SET
                  content = '{}'::jsonb,
                  links   = '[]'::jsonb,
                  search  = NULL
              WHERE id = ANY($1)
            SQL
            ids,
          )
          total += ids.size
          break if ids.size < BATCH_SIZE
        end
        total
      end

      # ── Private ─────────────────────────────────────────────────────

      # Returns the ids of expired tombstones that still carry a payload.
      # `deleted_at` and `now()` are both tz-naive UTC, so the interval
      # comparison is deterministic (see the Time / Timezone contract).
      private def self.select_expired_ids(db : DB::Connection, retention_days : Int32) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT id FROM projections
            WHERE deleted_at IS NOT NULL
              AND deleted_at < now() - make_interval(days => $1)
              AND (
                   content <> '{}'::jsonb
                OR links   <> '[]'::jsonb
                OR search IS NOT NULL
              )
            LIMIT #{BATCH_SIZE}
          SQL
          retention_days,
          as: String,
        )
      end
    end
  end
end
