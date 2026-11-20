# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../assistant/limits"
require "./pass"

module Facet
  module Cron
    # Deletes `assistant_usage` ledger rows that no live work can ask for.
    #
    # A row is prunable when both hold:
    #
    # 1. It is older than the retention window (`recorded_at` check).
    # 2. Its conversation has not been updated within the window, or its
    #    conversation row is gone. The ledger carries no FK, so rows
    #    survive conversation deletion; a deleted conversation can never
    #    update again, so its rows are stale by definition.
    #
    # The anchor is conversation staleness (`agent_conversations.updated_at`),
    # not the row's own age alone: every turn of a live conversation stays
    # in the ledger however old, and a quiet conversation's rows go
    # prunable together. The `recorded_at` floor keeps every usage query
    # window up to the retention window correct — the rolling 30-day token
    # budget (`Assistant::Limits` via the role `assistant_token_budget`
    # field) reads at most 30 days back, so a window of 31 or more days
    # never deletes a row a budget check can still see. A window of 1–30
    # days under-counts every live budget; the daily pass logs a warning
    # instead of clamping — the config stays the source of truth.
    #
    # ## Algorithm
    #
    # 1. Select ids of prunable rows, `LIMIT`-bounded.
    # 2. Delete those ids in one statement per batch. Each batch is its
    #    own implicit transaction, so a failure does not roll back earlier
    #    batches and a rerun resumes where the failed run stopped.
    # 3. Repeat until a batch returns fewer ids than the batch size.
    #
    # `assistant.usage_retention_days` = 0 (the default) never prunes:
    # the pass returns before it opens a connection.
    class AssistantUsagePrune
      Log = ::Log.for("facet.cron.assistant_usage_prune")

      # The maximum number of ids per DELETE batch. Caps the `ANY($1)`
      # array size so the bind payload stays bounded.
      BATCH_SIZE = 1000

      # Runs one prune pass with the retention window from config. A
      # window of 0 (the default) or less means "never prune" — the pass
      # does not run, and the daily cron fire stays silent. A window
      # inside the budget's rolling 30-day query range warns: pruning
      # deletes rows `Assistant::Limits` still reads, so budgets silently
      # stop counting old usage. Warn, never clamp — the config is the
      # source of truth.
      def self.call : Nil
        retention_days = Facet::Config.instance.assistant.usage_retention_days
        return if retention_days <= 0
        if retention_days <= Assistant::Limits::WINDOW_DAYS
          Log.warn do
            "assistant.usage_retention_days is #{retention_days}: the rolling " \
            "#{Assistant::Limits::WINDOW_DAYS}-day token budget still reads rows this old, " \
            "so budgets under-count. Set the window to " \
            "#{Assistant::Limits::WINDOW_DAYS + 1} or more (or 0 to keep every row)."
          end
        end
        Cron.run_pass("Assistant usage prune") do |db|
          prune(db, retention_days: retention_days)
        end
      end

      # Deletes ledger rows older than `retention_days` whose conversation
      # has not been updated within the window (or is gone). A window of
      # 0 or less deletes nothing. Returns the count of rows deleted.
      def self.prune(db : DB::Connection, retention_days : Int32) : Int32
        return 0 if retention_days <= 0

        total = 0
        loop do
          ids = select_prunable_ids(db, retention_days)
          break if ids.empty?

          db.exec(
            "DELETE FROM assistant_usage WHERE id = ANY($1)",
            ids,
          )
          total += ids.size
          break if ids.size < BATCH_SIZE
        end
        total
      end

      # ── Private ─────────────────────────────────────────────────────

      # Returns the ids of prunable ledger rows, at most `BATCH_SIZE`.
      # `recorded_at` and `updated_at` are both tz-naive UTC and `now()`
      # is pinned to UTC, so the interval math is deterministic (see the
      # Time / Timezone contract in `doc/backend/workflow.md`).
      private def self.select_prunable_ids(db : DB::Connection, retention_days : Int32) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT au.id
            FROM assistant_usage au
            WHERE au.recorded_at < now() - make_interval(days => $1)
              AND NOT EXISTS (
                SELECT 1
                FROM agent_conversations ac
                WHERE ac.id = au.conversation_id
                  AND ac.updated_at >= now() - make_interval(days => $1)
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
