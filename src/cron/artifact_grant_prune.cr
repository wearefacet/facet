# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../artifact/grants"
require "../system_settings/service"
require "./pass"

module Facet
  module Cron
    # Deletes expired `ephemeral` grant rows past the configured retention
    # window (`artifact.grant_prune_days`). Every download-gateway click
    # mints one ephemeral row, so without this pass `artifact_grants` grows
    # without bound except for the purge and domain-drop cascades. The
    # window counts from the row's `expires_at` — a link stays auditable
    # for the retention days after it went dead, then the pass removes it.
    #
    # Permanent grants never expire and never match. Mirrors
    # `TombstoneContentPrune`: the window resolves per pass from the
    # runtime settings, a window of 0 disables the pass (keep forever),
    # and the delete is idempotent — a pruned row does not match again.
    class ArtifactGrantPrune
      Log = ::Log.for("facet.cron.artifact_grant_prune")

      # Runs one prune pass. The retention window resolves per pass from
      # the runtime settings; a window of 0 disables the prune.
      def self.call : Nil
        Cron.run_pass("Artifact grant prune") do |db|
          window = runtime_retention_days(db)
          if window.zero?
            Log.info { "artifact grant prune disabled: artifact.grant_prune_days = 0 (keep forever)" }
            next 0
          end
          ::Facet::Artifact::Grants.prune_expired(db, retention_days: window)
        end
      end

      # The window resolves per pass from the runtime settings
      # (document → file → default), so an admin change applies from the
      # next daily run without a restart. A window of 0 keeps every
      # expired grant row forever.
      private def self.runtime_retention_days(db : DB::Connection) : Int32
        n = SystemSettings.int_at(db, "artifact.grant_prune_days")
        n.nil? || n < 0 ? Facet::Config.instance.artifact.grant_prune_days : n.to_i32
      end
    end
  end
end
