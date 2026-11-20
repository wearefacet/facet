# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../database"
require "../system_settings/service"

module Facet
  module Mutation
    # The effective mutation-retention window, resolved in one place.
    #
    # Two consumers read the same numbers:
    #
    # - `Cron::MutationCompaction` — the pass that removes rows past the
    #   window.
    # - `Audit::Rollback` — the 404 message for a mutation id that resolves
    #   to no row, which names the window in force.
    #
    # Resolution mirrors compaction exactly:
    #
    # - Base: `mutations.retention_days` is a runtime hot key — a non-null
    #   pin on `core.SystemSettings` wins; otherwise the YAML config value.
    # - Per-doctype: `mutations.retention_overrides` (YAML only) replaces
    #   the base for one qualified doctype.
    # - A base of `0` keeps history forever: compaction skips entirely,
    #   including the overrides, so the effective window is `0` everywhere.
    module Retention
      # The effective window in days for one doctype: the per-doctype
      # override when present (and the base window is non-zero), otherwise
      # the base window. `0` = keep forever (compaction disabled).
      def self.effective_days(db : DB::Connection, domain : String, doc_type : String) : Int32
        base = base_days(db)
        return 0 if base.zero?
        Facet::Config.instance.mutations.retention_overrides["#{domain}.#{doc_type}"]? || base
      end

      # The base window in days: the `mutations.retention_days` pin on
      # `core.SystemSettings` when present, otherwise the YAML config
      # value. `0` = keep forever.
      def self.base_days(db : DB::Connection) : Int32
        n = SystemSettings.int_at(db, "mutations.retention_days")
        n.nil? || n < 0 ? Facet::Config.instance.mutations.retention_days : n.to_i32
      end
    end
  end
end
