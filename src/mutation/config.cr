# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  # ── `mutations:` section of `Facet::Config` ──────────────────────────
  #
  # The `mutations:` record and its YAML loader live here, next to the
  # mutation concern. `Facet::Config` (src/config.cr) declares the
  # `mutations` field, calls `load_mutations` when it parses the file,
  # and owns the cross-section check against `jobs.retention_days`.
  class Config
    # ── Mutations retention and coalescing ──────────────────────────────
    #
    # Bounds the `mutations` table (see doc/backend/mutation.md →
    # Retention compaction / Write-time coalescing). The section is
    # optional in `config.{env}.yml` — the defaults keep the subsystem
    # usable without configuration.
    #
    # - `retention_days` — mutations older than this are replaced by one
    #   synthetic `snapshot` row (`Cron::MutationCompaction`). Defaults to
    #   180. Rollback depth equals the window: a rollback request for a
    #   mutation older than the window returns `404`. `0` disables
    #   compaction for every doctype — history (and rollback depth) is
    #   unbounded, and the file-side `retention_overrides` stop applying
    #   for that pass.
    # - `retention_overrides` — per-doctype override in days, keyed by the
    #   qualified doctype name (`domain.Doctype`). An absent key uses
    #   `retention_days`. Retention is deployment policy, not domain
    #   structure — it lives in config, never on the doctype definition.
    # - `compaction_cron` — the cron expression that schedules the
    #   compaction pass. Defaults to daily at 03:45 (`"45 3 * * *"),
    #   offset from the tombstone prune at 04:15 and the sidecar
    #   reconcile at minute 0.
    # - `coalesce_window_minutes` — write-time coalescing window: a new
    #   update from the same actor through the same channel inside the
    #   window folds into the document's previous update row. `0`
    #   disables coalescing. Defaults to 3.
    record MutationsConfig,
      retention_days : Int32 = 180,
      retention_overrides : Hash(String, Int32) = {} of String => Int32,
      compaction_cron : String = "45 3 * * *",
      coalesce_window_minutes : Int32 = 3

    # Parses the mutations retention config from the YAML document. Returns
    # the default `MutationsConfig` when the `mutations:` section is absent —
    # the section is optional; the compaction cron and the update-path
    # coalescing consume it. The default cron expression is validated lazily
    # by `Cron::Parser` when the compaction task is registered.
    private def self.load_mutations(raw : YAML::Any) : MutationsConfig
      mutations_raw = raw["mutations"]?
      return MutationsConfig.new if mutations_raw.nil? || mutations_raw.raw.nil?

      retention_days = read_int(mutations_raw["retention_days"]?, 180)
      if retention_days.negative?
        raise ArgumentError.new(
          "mutations.retention_days must be zero (keep forever — compaction off) or a " \
          "positive number of days (got #{retention_days})"
        )
      end

      coalesce_window = read_int(mutations_raw["coalesce_window_minutes"]?, 3)
      if coalesce_window.negative?
        raise ArgumentError.new(
          "mutations.coalesce_window_minutes must be zero or a positive number of " \
          "minutes — zero disables coalescing (got #{coalesce_window})"
        )
      end

      overrides = {} of String => Int32
      if overrides_raw = mutations_raw["retention_overrides"]?.try(&.as_h?)
        overrides_raw.each do |key, value|
          days = value.as_i
          if days < 1
            raise ArgumentError.new(
              "mutations.retention_overrides[#{key}] must be a positive number of days (got #{days})"
            )
          end
          overrides[key.to_s] = days
        end
      end

      MutationsConfig.new(
        retention_days: retention_days,
        retention_overrides: overrides,
        compaction_cron: read_str(mutations_raw["compaction_cron"]?) || "45 3 * * *",
        coalesce_window_minutes: coalesce_window,
      )
    end
  end
end
