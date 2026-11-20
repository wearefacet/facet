# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# B-206 — every cron metric the scheduler increments must carry a HELP
# line in the Prometheus exposition. An unregistered name renders as
# "(undocumented metric)" — docs-vs-exposition drift. The two counters
# below are the names incremented in `src/cron/scheduler.cr`.

require "./spec_helper"

# The cron counters incremented in `src/cron/scheduler.cr`. The spec
# increments each with a spec-only task label, so it never disturbs the
# per-task series other specs assert on.
CRON_CATALOG_COUNTERS = ["facet_cron_task_failures_total", "facet_cron_task_lease_skips_total"]

describe "Facet::Metrics cron catalog (B-206)" do
  it "renders a HELP line for every incremented cron metric name" do
    CRON_CATALOG_COUNTERS.each_with_index do |name, i|
      Facet::Metrics.inc(name, {"task" => "spec-catalog-#{i}"})
    end

    rendered = Facet::Metrics.render
    CRON_CATALOG_COUNTERS.each do |name|
      help_line = rendered.lines.find(&.starts_with?("# HELP #{name} "))
      help_line.should_not be_nil
      help_line.as(String).should_not contain("(undocumented metric)")
    end
  end

  it "documents the lease-skip help with the lease semantics from metrics.md" do
    Facet::Metrics.inc("facet_cron_task_lease_skips_total", {"task" => "spec-catalog-help"})

    line = Facet::Metrics.render.lines.find(&.starts_with?("# HELP facet_cron_task_lease_skips_total "))
    line.should_not be_nil
    line.as(String).should contain("another instance holds the tick lease")
  end
end
