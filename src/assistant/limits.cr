# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"

require "./access"
require "./usage"

module Facet
  module Assistant
    # Token-budget enforcement for the assistant.
    #
    # `Assistant::Routes.handle_stream` calls `allow?` before the SSE
    # headers go out, so a denial lands as a clean JSON 429 — never
    # mid-stream. The check sums **total tokens** (input + output; no
    # cached/uncached split) over every assistant conversation of the
    # account in a **rolling 30-day window** (`recorded_at >= now - 30
    # days`, open upper bound) and compares against the account's
    # effective budget (`Access.effective_budget`): `total >= budget`
    # denies, so a budget of `0` means "no tokens" and an unset budget
    # (`nil`, unlimited) skips the ledger sum entirely. The same check
    # gates the domain-builder turns — one ledger, one rule.
    module Limits
      # Length of the rolling usage window, in days. `assistant.usage_retention_days`
      # must be `0` or at least one day past this value (`Cron::AssistantUsagePrune`
      # warns when it is not) so pruning never deletes rows the budget still reads.
      WINDOW_DAYS = 30

      # Returns `true` when the account may start another streamed turn.
      def self.allow?(db : DB::Connection, account_id : String) : Bool
        budget = Access.effective_budget(db, account_id)
        return true if budget.nil?

        totals = Usage.total_for_account(db, account_id, since: Time.utc - WINDOW_DAYS.days)
        totals.total < budget
      end
    end
  end
end
