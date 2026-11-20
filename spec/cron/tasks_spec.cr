# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cron/tasks"

describe Facet::Cron::Tasks do
  describe ".boot_entries" do
    it "lists the eight boot tasks in registration order" do
      Facet::Cron::Tasks.boot_entries.map(&.id).should eq([
        "sidecar.reconcile",
        "tombstone.content_prune",
        "secrets.prune",
        "assistant.turn_sweep",
        "assistant.usage_prune",
        "mutations.compaction",
        "webhook.reconcile",
        "event.lag_check",
      ])
    end

    it "names the config key that owns each schedule" do
      Facet::Cron::Tasks.boot_entries.map(&.schedule_key).should eq([
        "sidecar.reconcile_cron",
        "tombstone.prune_cron",
        "secrets.prune_cron",
        "assistant.turn_sweep_cron",
        "assistant.usage_prune_cron",
        "mutations.compaction_cron",
        "webhook.reconcile_cron",
        "event.lag_check_cron",
      ])
    end

    it "carries the expressions from config, and every one parses" do
      entries = Facet::Cron::Tasks.boot_entries
      entries.map(&.cron).should eq([
        Facet::Config.instance.sidecar.reconcile_cron,
        Facet::Config.instance.tombstone.prune_cron,
        Facet::Config.instance.secrets.prune_cron,
        Facet::Config.instance.assistant.turn_sweep_cron,
        Facet::Config.instance.assistant.usage_prune_cron,
        Facet::Config.instance.mutations.compaction_cron,
        Facet::Config.instance.webhook.reconcile_cron,
        Facet::Config.instance.event.lag_check_cron,
      ])

      entries.each do |entry|
        Facet::Cron::Parser.new(entry.cron).next(Time.utc).should be_a(Time)
      end
    end
  end
end
