# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "./pass"
require "../secrets/store"

module Facet
  module Cron
    # Deletes secret rows past the configured retention window:
    #
    # - slots on tombstoned documents — a hard delete cascades through the
    #   FK, but a tombstone keeps its rows until this pass (the same
    #   window as the tombstone content prune);
    # - expired `token` rows past the same window.
    #
    # Mirrors `TombstoneContentPrune`: batched deletes, each batch its own
    # implicit transaction, a rerun resumes from where a failed run
    # stopped. Idempotent — already-pruned rows do not match again.
    class SecretsPrune
      Log = ::Log.for("facet.cron.secrets_prune")

      # Runs one prune pass with the retention window from config.
      def self.call : Nil
        retention_days = Facet::Config.instance.secrets.prune_after_days
        Cron.run_pass("Secrets prune") do |db|
          Facet::Secrets.prune(db, retention_days)
        end
      end
    end
  end
end
