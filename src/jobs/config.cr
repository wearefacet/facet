# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  # ── `jobs:` section of `Facet::Config` ───────────────────────────────
  #
  # The `jobs:` record and its YAML loader live here, next to the jobs
  # concern. `Facet::Config` (src/config.cr) declares the `jobs` field
  # and calls `load_jobs` when it parses the file.
  class Config
    # ── Jobs (background job queue) ──────────────────────────────────────
    #
    # Tuning for `Jobs::Worker`, the poll-loop worker over the
    # `background_jobs` table. Returns the defaults when the `jobs:`
    # section is absent — the section is optional. With `enabled: false`
    # the worker never starts and `Jobs::Manager` stays in enqueue-only
    # mode (rows are inserted, but nothing claims them).
    #
    # - `poll_interval_s` — idle wait between claim passes.
    # - `lease_ttl_s` — how long a claimed row stays `running` before the
    #   lease sweep requeues it.
    # - `long_lease_ttl_s` — the per-row lease horizon long job kinds
    #   (import/export) pass at enqueue. Far above any real runtime, short
    #   enough that a dead worker's row recovers within the window.
    # - `batch` — max rows claimed per pass.
    # - `sweep_interval_s` — cadence of the expired-lease sweep.
    # - `retention_days` — terminal rows older than this are pruned.
    record JobsConfig,
      poll_interval_s : Float64 = 5.0,
      lease_ttl_s : Int32 = 60,
      long_lease_ttl_s : Int32 = 3600,
      batch : Int32 = 32,
      sweep_interval_s : Float64 = 30.0,
      retention_days : Int32 = 30,
      enabled : Bool = true

    # Parses the background-jobs config from the YAML document. Returns the
    # default config when the `jobs:` section is absent — the section is
    # optional and workers run with defaults (enabled) when it is missing.
    private def self.load_jobs(raw : YAML::Any) : JobsConfig
      jobs_raw = raw["jobs"]?
      return JobsConfig.new if jobs_raw.nil? || jobs_raw.raw.nil?

      JobsConfig.new(
        poll_interval_s: read_float(jobs_raw["poll_interval_s"]?, 5.0),
        lease_ttl_s: read_int(jobs_raw["lease_ttl_s"]?, 60),
        long_lease_ttl_s: read_int(jobs_raw["long_lease_ttl_s"]?, 3600),
        batch: read_int(jobs_raw["batch"]?, 32),
        sweep_interval_s: read_float(jobs_raw["sweep_interval_s"]?, 30.0),
        retention_days: read_int(jobs_raw["retention_days"]?, 30),
        enabled: read_bool(jobs_raw["enabled"]?, true),
      )
    end
  end
end
