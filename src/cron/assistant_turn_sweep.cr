# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "./pass"
require "../assistant/turn"

module Facet
  module Cron
    # Marks stale `running` assistant turns as `error` with message
    # `interrupted`.
    #
    # A turn row is written at turn START and flipped to its terminal
    # status by `Assistant::Stream::Session` at the exit path. When the
    # server process dies mid-turn (deploy, dev restart, crash), no exit
    # path ever runs and the row stays `running` forever. This task is the
    # liveness backstop: a running row older than the configured timeout
    # cannot belong to a live stream (no legitimate turn runs that long),
    # so it is marked `interrupted` — an honest corpse the catch-up poll
    # and the audit trail can read.
    #
    # The pass is idempotent: already-terminal rows never match.
    class AssistantTurnSweep
      Log = ::Log.for("facet.cron.assistant_turn_sweep")

      # Runs one sweep pass with the timeout from config. The completion
      # line is logged only when the sweep touched rows — the task fires on
      # a frequent cron and rarely finds work.
      def self.call : Nil
        timeout = Facet::Config.instance.assistant.turn_timeout_seconds
        Cron.run_pass("Assistant turn sweep", log_zero: false) do |db|
          Assistant::Turn.sweep_stale_running(db, timeout)
        end
      end
    end
  end
end
