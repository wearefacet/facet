# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "mutex"

module Facet
  # In-process metrics registry rendered on `GET /metrics` in the
  # Prometheus text exposition format 0.0.4.
  #
  # The OpenTelemetry shard carries a traces-only API — no metrics — so
  # the registry is a small, local series store: counters and gauges
  # keyed by metric name plus a bounded label set, guarded by a mutex.
  # Same posture as `Event::Loss` and `Event::ConsumerHealth`:
  # process-wide, reset on restart, no new shard dependency. Multi-instance
  # deployments scrape every process; Prometheus does the aggregation.
  #
  # ## Cardinality policy
  #
  # Labels must come from bounded sets (job kind, HTTP method, status
  # class, first path segment, consumer-group name, task id). The sets
  # are declared in the metric catalog (see `doc/backend/metrics.md`)
  # and enforced by review, not at runtime — a label with unbounded
  # cardinality (document id, tenant) must never reach `inc` / `set`.
  #
  # See `doc/backend/metrics.md`.
  module Metrics
    # One stored series: the rendered label set (also the lookup key) and
    # the current value. A reference type — counters and gauges mutate
    # through the registry's hash, never through a copy.
    private class Series
      property value : Float64
      getter labels : Hash(String, String)
      getter label_key : String

      def initialize(@labels : Hash(String, String), @label_key : String, @value : Float64 = 0.0)
      end
    end

    # Catalog metadata for one metric name: the exposition type and the
    # HELP line. Names missing from the catalog render as counters with a
    # generic help line.
    private record MetricMeta, kind : String, help : String

    private CATALOG = {
      "facet_events_published_total"                  => MetricMeta.new("counter", "Resource events written to the Redis streams by this process."),
      "facet_messages_processed_total"                => MetricMeta.new("counter", "Stream messages dispatched to a subscription handler, per consumer group."),
      "facet_jobs_enqueued_total"                     => MetricMeta.new("counter", "Background job rows inserted, per kind."),
      "facet_jobs_claimed_total"                      => MetricMeta.new("counter", "Background job rows claimed by the worker, per kind."),
      "facet_jobs_succeeded_total"                    => MetricMeta.new("counter", "Background job attempts written as succeeded, per kind."),
      "facet_jobs_failed_total"                       => MetricMeta.new("counter", "Background job attempts written as failed, per kind."),
      "facet_jobs_abandoned_total"                    => MetricMeta.new("counter", "Background job rows requeued by the expired-lease sweep, per kind."),
      "facet_http_requests_total"                     => MetricMeta.new("counter", "HTTP requests handled, by method, route group, and status class."),
      "facet_db_checkout_total"                       => MetricMeta.new("counter", "Pooled connection checkouts, by database entry and pool role (rw/ro)."),
      "facet_db_poisoned_discards_total"              => MetricMeta.new("counter", "Pooled connections discarded at release because a response was still queued on their socket (abandoned result set)."),
      "facet_cron_task_failures_total"                => MetricMeta.new("counter", "Cron task firings that raised, per task id."),
      "facet_cron_task_lease_skips_total"             => MetricMeta.new("counter", "Cron task dispatches skipped because another instance holds the tick lease, per task id."),
      "facet_event_loss_publish_flush_failures_total" => MetricMeta.new("counter", "Failed Event::Publisher.flush calls since process start."),
      "facet_event_loss_publish_events_dropped_total" => MetricMeta.new("counter", "Events dropped by failed publish flushes since process start."),
      "facet_event_loss_messages_dropped_total"       => MetricMeta.new("counter", "Dispatched messages swallowed by handler errors since process start."),
      "facet_consumer_consecutive_failures"           => MetricMeta.new("gauge", "Consecutive failed loop turns per stream consumer group."),
      "facet_consumer_restarts_total"                 => MetricMeta.new("counter", "Supervised fiber restarts per stream consumer group since process start."),
      "facet_event_lag_max"                           => MetricMeta.new("gauge", "Maximum consumer-group lag observed by the last Cron::EventLagCheck pass."),
      "facet_fiber_restarts_total"                    => MetricMeta.new("counter", "Supervised fiber restarts, by fiber name, since process start."),
      "facet_fiber_loop_errors_total"                 => MetricMeta.new("counter", "Long-lived loop turns that rescued an exception, by fiber name."),
    }

    @@series = {} of String => Hash(String, Series)
    @@mutex = Mutex.new

    # Increments a counter by `by` (default 1).
    def self.inc(name : String, labels : Hash(String, String)? = nil, by : Int = 1) : Nil
      @@mutex.synchronize do
        series(name, labels).value += by
      end
    end

    # Sets a gauge (or a scrape-sourced counter) to `value`.
    def self.set(name : String, value : Number, labels : Hash(String, String)? = nil) : Nil
      @@mutex.synchronize do
        series(name, labels).value = value.to_f
      end
    end

    # Returns the current value of one series. Spec and diagnostics use.
    def self.value(name : String, labels : Hash(String, String)? = nil) : Float64
      @@mutex.synchronize do
        by_name = @@series[name]?
        found = by_name.try(&.fetch(label_key(labels), nil))
        found ? found.value : 0.0
      end
    end

    # Renders the whole registry as Prometheus text exposition 0.0.4:
    # one `# HELP` / `# TYPE` pair per metric name, then one sample per
    # series, names sorted, series sorted by label set.
    def self.render : String
      String.build do |io|
        @@mutex.synchronize do
          names = CATALOG.keys + @@series.keys
          names.uniq!
          names.sort!
          names.each do |name|
            meta = CATALOG[name]?
            io << "# HELP " << name << ' ' << (meta ? meta.help : "(undocumented metric)") << '\n'
            io << "# TYPE " << name << ' ' << (meta ? meta.kind : "counter") << '\n'
            series = @@series[name]?
            next unless series
            series.values.sort_by!(&.label_key).each do |s|
              io << name
              io << '{' << s.label_key << '}' unless s.label_key.empty?
              io << ' ' << format_value(s.value) << '\n'
            end
          end
        end
      end
    end

    # Clears every series. Spec support only.
    def self.reset : Nil
      @@mutex.synchronize { @@series.clear }
    end

    private def self.series(name : String, labels : Hash(String, String)?) : Series
      key = label_key(labels)
      by_name = (@@series[name] ||= {} of String => Series)
      by_name[key] ||= Series.new(labels ? labels.dup : {} of String => String, key)
    end

    # Canonical, sorted `k="v"` pair list — the series identity and the
    # rendering form in one.
    private def self.label_key(labels : Hash(String, String)?) : String
      return "" unless labels
      keys = labels.keys
      keys.sort!
      String.build do |io|
        keys.each_with_index do |k, i|
          io << ',' if i > 0
          io << k << "=\"" << escape_label_value(labels[k]) << '"'
        end
      end
    end

    private def self.escape_label_value(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n")
    end

    # Integer values render without a decimal point — counters stay
    # human-readable and Prometheus keeps full integer precision below
    # 2^53.
    private def self.format_value(value : Float64) : String
      int = value.trunc
      if int == value && int.abs < 9_007_199_254_740_992.0
        int.to_i64.to_s
      else
        value.to_s
      end
    end
  end
end
