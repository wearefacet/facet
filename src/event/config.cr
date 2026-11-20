# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module Event
    # Configuration for the Event system.
    #
    # Loaded from the `event:` section of `config.{env}.yml`.
    struct Config
      # Redis connection URL (e.g. "redis://localhost:6379/0").
      getter url : String

      # Number of partitions (shards) per stream. Default 16, max 32.
      getter partitions : Int32

      # Maximum stream length (approximate). Older entries are removed.
      getter maxlen : Int64

      # Cron expression that schedules `Cron::EventLagCheck` (the
      # consumer-lag probe — see `doc/backend/event.md` → Consumer-lag
      # check). Defaults to every 10 minutes.
      getter lag_check_cron : String

      # Warn threshold for one consumer group's `XINFO GROUPS` `lag`: a
      # group over the threshold logs a structured warn — trim loss is
      # approaching (the stream is capped by `maxlen`). Defaults to
      # 100,000 — 10% of the default `maxlen`.
      getter lag_warn_entries : Int64

      # Stream subscriber tuning.
      getter stream : StreamConfig

      def initialize(
        @url : String = "redis://localhost:6379/0",
        @partitions : Int32 = 16,
        @maxlen : Int64 = 1_000_000,
        @lag_check_cron : String = "*/10 * * * *",
        @lag_warn_entries : Int64 = 100_000_i64,
        @stream : StreamConfig = StreamConfig.new,
      )
      end

      def self.from_yaml(raw : YAML::Any) : self
        new(
          url: raw["url"]?.try(&.as_s) || "redis://localhost:6379/0",
          partitions: raw["partitions"]?.try(&.as_i) || 16,
          maxlen: raw["maxlen"]?.try(&.as_i64) || 1_000_000_i64,
          lag_check_cron: raw["lag_check_cron"]?.try(&.as_s) || "*/10 * * * *",
          lag_warn_entries: raw["lag_warn_entries"]?.try(&.as_i64) || 100_000_i64,
          stream: StreamConfig.from_yaml(raw["stream"]?)
        )
      end

      struct StreamConfig
        # Maximum time (seconds) to block waiting for messages.
        getter max_block_time : Float64

        # Minimum time (seconds) to block waiting for messages.
        getter min_block_time : Float64

        # Factor (< 1) used to reduce/increase block time adaptively.
        getter block_time_delta : Float64

        # Maximum number of messages to read per XREADGROUP call.
        getter max_messages_count : Int32

        def initialize(
          @max_block_time : Float64 = 2.0,
          @min_block_time : Float64 = 0.1,
          @block_time_delta : Float64 = 0.7,
          @max_messages_count : Int32 = 10,
        )
        end

        def self.from_yaml(raw : YAML::Any?) : self
          return new if raw.nil? || raw.raw.nil?

          new(
            max_block_time: raw["max_block_time"]?.try(&.as_f) || 2.0,
            min_block_time: raw["min_block_time"]?.try(&.as_f) || 0.1,
            block_time_delta: raw["block_time_delta"]?.try(&.as_f) || 0.7,
            max_messages_count: raw["max_messages_count"]?.try(&.as_i) || 10
          )
        end
      end
    end
  end
end
