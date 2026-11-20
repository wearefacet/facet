# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "../metrics"
require "../event/loss"
require "../event/consumer_health"
require "../cron/event_lag_check"

module Facet
  module HTTP
    # The Prometheus scrape endpoint: `GET /metrics`.
    #
    # Access is deliberately unauthenticated (like `/Healthcheck`): the
    # dev Caddyfile does not route `/metrics` to the backend, so the
    # endpoint is only reachable on the backend origin of the private
    # network — that is also the scrape address to configure (e.g.
    # `http://127.0.0.1:3000/metrics`). See `doc/backend/metrics.md`.
    #
    # Counters accumulate through hooks in the application code; the
    # gauges below are scrape-time views over existing process state and
    # need no hooks.
    module MetricsRoute
      def self.register : Nil
        get "/metrics" do |env|
          env.response.content_type = "text/plain; version=0.0.4; charset=utf-8"
          collect_gauges
          Facet::Metrics.render
        end
      end

      # Renders the scrape-time gauges from the live registries before
      # `Facet::Metrics.render` serializes them.
      private def self.collect_gauges : Nil
        Event::Loss.snapshot.each do |key, value|
          Metrics.set("facet_event_loss_#{key}_total", value)
        end
        Event::ConsumerHealth.snapshot.each do |consumer|
          Metrics.set("facet_consumer_consecutive_failures", consumer[:consecutive_failures], {"name" => consumer[:name]})
          Metrics.set("facet_consumer_restarts_total", consumer[:restarts], {"name" => consumer[:name]})
        end
        Metrics.set("facet_event_lag_max", Cron::EventLagCheck.max_lag)
      end
    end
  end
end
