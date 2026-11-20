# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "atomic"
require "redis"
require "../config"

module Facet
  module Cron
    # Consumer-lag probe for the Redis event streams.
    #
    # Event streams are capped by `XADD maxlen ~` (an approximate cap:
    # entries are never deleted after delivery, so every stream sits at
    # its cap in steady state — the cap is a Redis memory bound as much as
    # a retention horizon). A consumer group loses entries to trim only
    # when it falls more than `maxlen` entries behind on one shard; the
    # realistic causes are a dead consumer fiber or a down instance —
    # operating faults, not sizing faults. A client-side `XADD` cannot
    # observe trims, so **lag is the observable precursor**: this task
    # reads every group's `XINFO GROUPS` `lag` and warns before a slow
    # group reaches the trim point.
    #
    # Threshold semantics: a warn means "trim loss is approaching", not
    # "loss happened". The pass is read-only (`KEYS`, `XINFO GROUPS`) and
    # adds no write on the publish path.
    class EventLagCheck
      Log = ::Log.for("facet.cron.event_lag_check")

      # Stream keys carry this prefix (see `Event::Manager#publish_resource_event`).
      STREAM_KEY_PREFIX = "FACET:RESOURCE:"

      # One group over the warn threshold — the structured warn payload.
      record LagWarn,
        stream : String,
        group : String?,
        lag : Int64,
        warn_entries : Int64,
        maxlen : Int64

      @@max_lag = Atomic(Int64).new(0)

      # The maximum group lag observed by the last pass — the gauge exposed
      # on `GET /Healthcheck` next to `event_loss`. Zero until a pass ran.
      def self.max_lag : Int64
        @@max_lag.get
      end

      # Resets the gauge. Spec support only.
      def self.reset_gauge : Nil
        @@max_lag.set(0)
      end

      # Runs one pass against the configured Redis: reads the over-threshold
      # groups and logs one structured warn per group. Builds a client per
      # pass — the cadence is minutes, so a per-pass connection is cheap
      # and keeps the task off the managers' pooled clients.
      def self.call : Nil
        config = Facet::Config.instance.event
        redis = ::Redis::Client.new(URI.parse(config.url))
        begin
          scan(redis, warn_entries: config.lag_warn_entries, maxlen: config.maxlen).each do |warn|
            Log.warn do
              "Consumer-group lag approaching trim loss: stream=#{warn.stream} " \
              "group=#{warn.group || "?"} lag=#{warn.lag} " \
              "threshold=#{warn.warn_entries} maxlen=#{warn.maxlen}"
            end
          end
        ensure
          redis.close
        end
      rescue ex : Exception
        # The scheduler logs and reschedules; re-raise so the task's own
        # span attributes reflect the failure if telemetry is wired.
        Log.error { "Event lag check failed: #{ex.message}" }
        raise ex
      end

      # One pass: discovers stream keys, reads each group's lag, records
      # the pass's max lag as the gauge, and returns every group over the
      # threshold. Public (and client-injectable) so specs drive the pass
      # against stubbed `keys` / `xinfo_groups` replies.
      def self.scan(redis : ::Redis::Client, warn_entries : Int64, maxlen : Int64) : Array(LagWarn)
        warns = [] of LagWarn
        max_lag = 0_i64

        keys_reply = redis.keys("#{STREAM_KEY_PREFIX}*")
        return warns unless keys_reply.is_a?(Array)

        keys_reply.each do |key|
          stream = key.to_s
          groups_reply = redis.xinfo_groups(stream)
          next unless groups_reply.is_a?(Array)

          groups_reply.each do |group|
            name, lag = parse_group(group)
            next if lag.nil?

            max_lag = {max_lag, lag}.max
            if lag > warn_entries
              warns << LagWarn.new(
                stream: stream,
                group: name,
                lag: lag,
                warn_entries: warn_entries,
                maxlen: maxlen
              )
            end
          end
        rescue e : ::Redis::Error
          # A key can vanish between KEYS and XINFO GROUPS (a stream is
          # trimmed to nothing, or the keyspace is flushed) — the pass is
          # read-only, so the miss is logged and the scan moves on.
          Log.debug { "Event lag check: no groups for key #{stream}: #{e.message}" }
        end

        @@max_lag.set(max_lag)
        warns
      end

      # Parses one `XINFO GROUPS` entry: a flat array of alternating field /
      # value pairs (`name`, `consumers`, `pending`, `last-delivered-id`,
      # `entries-read`, `lag`). Returns the group name and its `lag` — nil
      # when the reply has no pair (Redis 7.0+ always reports `lag`, but a
      # nil `lag` means "not yet computable" and parses as nil).
      private def self.parse_group(entry) : {String?, Int64?}
        return {nil, nil} unless entry.is_a?(Array)

        name = nil
        lag = nil
        entry.each_slice(2) do |pair|
          next if pair.size != 2
          field = pair[0].to_s
          value = pair[1].to_s
          case field
          when "name" then name = value
          when "lag"  then lag = value.to_i64?
          else
            # unrelated field — skip
          end
        end
        {name, lag}
      end
    end
  end
end
