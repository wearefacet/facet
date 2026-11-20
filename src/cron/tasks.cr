# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# The table wires the eight boot task classes, so it requires them — a
# `require` of this file alone is enough for the CLI listing and the specs.
require "../config"
require "./assistant_turn_sweep"
require "./assistant_usage_prune"
require "./event_lag_check"
require "./mutation_compaction"
require "./secrets_prune"
require "./sidecar_reconcile"
require "./tombstone_content_prune"
require "./webhook_reconcile"

# The boot cron task table.
#
# One row per task the server registers with `Cron::Scheduler#register` at
# boot. The table is the single source: `CLI.run_server` feeds it to the
# scheduler, and `facet cron:list` (`Cron::ListCLI`) prints it. Each row
# names the config key that owns its schedule, so the listing can point at
# the setting and not only at the value.
module Facet
  module Cron
    module Tasks
      # One boot task: the scheduler id, the config key that holds the
      # schedule, the expression read from that key, and the zero-argument
      # callback the scheduler fires.
      record Entry,
        id : String,
        schedule_key : String,
        cron : String,
        task : Proc(Nil)

      # The boot tasks, in registration order. The expressions come from
      # `Facet::Config.instance` — the keys above name where each one lives.
      def self.boot_entries : Array(Entry)
        config = Facet::Config.instance
        [
          Entry.new(id: "sidecar.reconcile", schedule_key: "sidecar.reconcile_cron", cron: config.sidecar.reconcile_cron, task: -> { Facet::Cron::SidecarReconcile.call }),
          Entry.new(id: "tombstone.content_prune", schedule_key: "tombstone.prune_cron", cron: config.tombstone.prune_cron, task: -> { Facet::Cron::TombstoneContentPrune.call }),
          Entry.new(id: "secrets.prune", schedule_key: "secrets.prune_cron", cron: config.secrets.prune_cron, task: -> { Facet::Cron::SecretsPrune.call }),
          Entry.new(id: "assistant.turn_sweep", schedule_key: "assistant.turn_sweep_cron", cron: config.assistant.turn_sweep_cron, task: -> { Facet::Cron::AssistantTurnSweep.call }),
          Entry.new(id: "assistant.usage_prune", schedule_key: "assistant.usage_prune_cron", cron: config.assistant.usage_prune_cron, task: -> { Facet::Cron::AssistantUsagePrune.call }),
          Entry.new(id: "mutations.compaction", schedule_key: "mutations.compaction_cron", cron: config.mutations.compaction_cron, task: -> { Facet::Cron::MutationCompaction.call }),
          Entry.new(id: "webhook.reconcile", schedule_key: "webhook.reconcile_cron", cron: config.webhook.reconcile_cron, task: -> { Facet::Cron::WebhookReconcile.call }),
          Entry.new(id: "event.lag_check", schedule_key: "event.lag_check_cron", cron: config.event.lag_check_cron, task: -> { Facet::Cron::EventLagCheck.call }),
        ]
      end
    end
  end
end
