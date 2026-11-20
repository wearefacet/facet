# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../event/loss"
require "../cron/event_lag_check"
require "../service"

module Facet
  module HTTP
    # Liveness + dependency probe route.
    #
    # Used by `scripts/dev.sh` for the backend readiness check and available
    # to any orchestrator. Returns 503 if any backing service is unreachable
    # so the probe fails loudly rather than masking the failure behind a 200.
    #
    # Whitelisted in `AuthHandler::PUBLIC_ROUTES` (no auth) and inherently
    # outside `DomainGate` (no `/Api/:domain` prefix).
    module Healthcheck
      # Process start instant for the liveness probe's uptime. Set when
      # this file loads — effectively process boot, since the require
      # chain pulls it in before `Kemal.run`.
      STARTED_AT = Time.utc

      def self.register : Nil
        get "/Healthcheck" do |env|
          handle(env)
        end

        # Liveness probe: answers while the process itself is alive. No
        # dependency checks — a dependency outage must not restart the
        # process (readiness, above, owns the degraded signal; the kill
        # policy belongs to the orchestrator only when the process is
        # dead). See `doc/backend/http-layer.md` → Healthcheck.
        get "/Healthcheck/live" do |env|
          env.response.content_type = "application/json"
          {status: "ok", uptime_seconds: uptime_seconds}.to_json
        end
      end

      private def self.uptime_seconds : Int64
        (Time.utc - STARTED_AT).total_seconds.to_i64
      end

      private def self.handle(env)
        # DB probe — `SELECT 1` per pool is the canonical "is the backend
        # alive?" check. Every pool of the route table reports its own
        # status (database entry + role); a broken pool reports itself and
        # does not abort the endpoint — the aggregate below still completes
        # and the per-pool detail tells the operator which pool broke.
        pools = probe_pools

        db_status = pools.empty? ? "error" : (pools.all?(&.[:status].==("ok")) ? "ok" : "error")
        db_error = pools.find(&.[:status].==("error")).try(&.[:error]) || (pools.empty? ? "no database pools initialized" : nil)

        # Redis probe — delegates to the event manager (real Redis in
        # production, `in_process` in tests / single-process dev where
        # `Event::Publisher.manager` is an `InProcessManager`).
        if mgr = Event::Publisher.manager
          health = mgr.redis_health
          redis_status = health[:status]
          redis_error = health[:error]
        else
          redis_status = "error"
          redis_error = "Event::Publisher.manager not initialized"
        end

        # Consumer-health aggregate for the stream subscriber fibers (see
        # `Event::ConsumerHealth`). Readiness semantics: one degraded consumer
        # makes the whole probe 503 — the process reports the degraded state
        # truthfully and self-heals; the kill policy belongs to the
        # deployment layer. Under the `InProcessManager` (tests /
        # single-process dev) no stream consumers run; the section reports
        # `in_process` instead.
        events_status = events_health_status

        healthy = db_status == "ok" &&
                  (redis_status == "ok" || redis_status == "in_process") &&
                  events_status != "degraded"

        env.response.status_code = healthy ? 200 : 503
        env.response.content_type = "application/json"
        {
          status: healthy ? "ok" : "degraded",
          # Process identity (Facet::Service) — one instance id per boot.
          # Independent of the event manager, so the same value reports under
          # the InProcessManager (tests, single-process dev) and the real
          # manager; an operator matches it against the boot log and the
          # shard-lock holders in Redis.
          service:  {env: Facet::Service.app_env, instance_id: Facet::Service.instance_id},
          database: {status: db_status, error: db_error, pools: pools},
          redis:    {status: redis_status, error: redis_error},
          # Per-consumer health of the stream subscriber fibers — the
          # "green but dead" guard. While a consumer reports consecutive
          # failures, the probe fails even when Redis itself answers again
          # (see `doc/backend/event.md` → Supervision and error backoff).
          events: {status: events_status, consumers: Event::ConsumerHealth.snapshot},
          # Event delivery is at-most-once by decision; the loss counters
          # make the silent part observable (see `doc/backend/event.md` →
          # Delivery contract). Process-wide, reset on restart.
          event_loss: Event::Loss.snapshot,
          # The max consumer-group lag observed by the last
          # `Cron::EventLagCheck` pass — the trim-loss precursor.
          event_lag: {max_lag: Cron::EventLagCheck.max_lag},
        }.to_json
      end

      private alias DBPoolStatus = NamedTuple(database: String, role: String, status: String, error: String?)

      # Probes every pool of the route table with `SELECT 1`. One status
      # record per (database, role); a broken pool reports itself without
      # aborting the sweep.
      private def self.probe_pools : Array(DBPoolStatus)
        pools = [] of DBPoolStatus
        Facet::Database.each_pool do |database, role, pool|
          begin
            conn = pool.checkout
            begin
              result = conn.scalar("SELECT 1")
              pools << {database: database, role: role,
                        status: result.to_s == "1" ? "ok" : "error", error: nil}
            ensure
              conn.release
            end
          rescue ex
            pools << {database: database, role: role, status: "error", error: ex.message}
          end
        end
        pools
      end

      private def self.events_health_status : String
        if Event::ConsumerHealth.degraded?
          "degraded"
        elsif Event::Publisher.manager.is_a?(Event::InProcessManager)
          "in_process"
        else
          "ok"
        end
      end
    end
  end
end
