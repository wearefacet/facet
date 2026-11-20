# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./base"
require "../message"
require "../consumer_health"
require "../../metrics"
require "../../util/fiber_supervisor"

module Facet
  module Event
    module Subscriber
      # Subscriber that reads from Redis Streams using Consumer Groups.
      #
      # Uses shard-locking (via Lua scripts) to distribute ordered streams
      # across multiple service instances. Each consumer group (one per
      # domain) locks a subset of shards and reads messages via XREADGROUP.
      #
      # Runs in a single fiber. Blocking Redis calls are made on dedicated
      # connections checked out from the Redis client pool; the subscriber
      # fiber yields between iterations via `sleep`.
      class Stream < Base
        # ── Config ────────────────────────────────────────────────────────

        struct Config
          getter max_block_time : Float64
          getter min_block_time : Float64
          getter block_time_delta : Float64
          getter max_messages_count : Int32

          def initialize(
            @max_block_time : Float64 = 2.0,
            @min_block_time : Float64 = 0.1,
            @block_time_delta : Float64 = 0.7,
            @max_messages_count : Int32 = 10,
          )
          end
        end

        # ── Lua scripts (embedded at compile time from `db/lua/`) ─────────

        LOCK_SHARDS_SCRIPT   = {{ read_file("#{__DIR__}/../../../db/lua/lock_shards.lua") }}
        UNLOCK_SHARDS_SCRIPT = {{ read_file("#{__DIR__}/../../../db/lua/unlock_shards.lua") }}

        # ── Instance state ────────────────────────────────────────────────

        @sha_scripts = Hash(String, String).new
        # Guards `@sha_scripts`: the run-loop fiber and the stop path (see
        # `release_shard_locks`) can both resolve a script id concurrently,
        # and Crystal's Hash is not safe for unsynchronized read/write.
        @script_mutex = Mutex.new
        @block_time : Float64
        @config : Config
        @stop_channel : Channel(Nil)?
        @redis : ::Redis::Client
        @channel_provider : Proc(Array(String))?
        @on_channels_added : Proc(Array(String), Nil)?
        @channel_mutex : Mutex
        @group_start_id : String
        @consecutive_failures : Int32 = 0
        @nogroup_streak : Int32 = 0
        @error_backoff : Util::FiberSupervisor::Backoff = Util::FiberSupervisor::Backoff.new
        @failure_since : Time::Instant = Time.instant

        getter consumer_name : String
        getter consumer_id : String
        getter prefix : String
        getter redis_url : String
        getter partitions : Int32

        # The consumer kind this subscriber serves, read from the consumer
        # group prefix (`cg:repl:`, `cg:hooks:`, `cg:webhooks:`,
        # `cg:sidecar:`; the unprefixed default is the general manager).
        # Log lines use it to name the real consumer — one run-loop
        # implementation serves every kind.
        def consumer_kind : String
          case @consumer_name
          when .starts_with?("cg:repl:")     then "Replication"
          when .starts_with?("cg:hooks:")    then "Hooks"
          when .starts_with?("cg:webhooks:") then "Webhook"
          when .starts_with?("cg:sidecar:")  then "Sidecar sweep"
          else                                    "Stream"
          end
        end

        def initialize(
          @redis_url : String,
          @consumer_name : String, # The domain name (e.g. "hr", "identity")
          @consumer_id : String,   # The service instance ID (ULID)
          @prefix : String = "",
          @partitions : Int32 = 16,
          config : Config = Config.new,
          channel_provider : Proc(Array(String))? = nil,
          group_start_id : String = "$",
          &block : Proc(String, Message, Nil)
        )
          super(block)
          @config = config
          @block_time = config.min_block_time
          @redis = ::Redis::Client.new(URI.parse(@redis_url))
          @channel_provider = channel_provider
          @channel_mutex = Mutex.new
          @script_mutex = Mutex.new
          @group_start_id = group_start_id
        end

        # Sets a callable that returns the current set of channels to consume.
        # On each polling turn the run loop invokes it; if the returned set
        # differs from the currently-subscribed channels, new channels are
        # subscribed (consumer groups created) and removed channels dropped.
        # Used by replication to react to doctype-schema changes (new source
        # doctypes appear / old ones disappear) without restarting the fiber.
        def channel_provider=(provider : Proc(Array(String))?) : Nil
          @channel_mutex.synchronize { @channel_provider = provider }
        end

        # Sets a callable invoked with the channels `refresh_channels_if_changed`
        # adds at runtime. The caller pairs each addition with a dispatch
        # registration (`Event::Manager.register_stream_subscription`) — the
        # consumer groups alone only make the messages readable; without a
        # subscription the dispatcher drops every message read from the new
        # channel.
        def on_channels_added=(callback : Proc(Array(String), Nil)?) : Nil
          @channel_mutex.synchronize { @on_channels_added = callback }
        end

        # ── Lifecycle ────────────────────────────────────────────────────

        def start : Nil
          super
          # A provider signals that channels may appear after start — start
          # the loop even with an empty initial set so the first polling turn
          # can pick them up. Without a provider an empty set means the
          # subscriber has nothing to do forever, and the early return avoids
          # an idle fiber + a phantom consumer-health entry.
          has_provider = @channel_mutex.synchronize { !@channel_provider.nil? }
          return if @channels.empty? && !has_provider

          @stop_channel = Channel(Nil).new

          Event::ConsumerHealth.register(@consumer_name)
          @consecutive_failures = 0
          @error_backoff.reset

          # Best-effort synchronous group creation: when Redis answers, the
          # groups exist before `start` returns — a publisher that XADDs right
          # after start cannot fall behind a group created at the tail (`$`).
          # When Redis is unreachable, creation is deferred: the supervised
          # run below retries it until it succeeds, and the subscriber comes
          # up degraded instead of failing boot.
          begin
            init_groups(@redis, @channels.map(&.[0]))
          rescue e : Exception
            Log.warn { "Consumer-group creation deferred (Redis unreachable): #{e.class}: #{e.message}" }
          end

          Util::FiberSupervisor.supervise(
            "Event Stream Subscriber (#{@consumer_name})",
            on_restart: restart_callback
          ) { supervised_run }
          Util::FiberSupervisor.supervise(
            "Event Stream Liveness (#{@consumer_name})",
            on_restart: restart_callback
          ) { liveness_run }
        end

        def stop : Nil
          super
          @stop_channel.try(&.close)
          Event::ConsumerHealth.unregister(@consumer_name)
          release_shard_locks
        end

        # Releases this subscriber's shard locks synchronously, so a graceful
        # shutdown hands the locked shards to a live peer right away instead
        # of leaving them to the 3200 s lock TTL (under the static
        # `service_id` a lock is only stealable once every instance sharing
        # the id stops refreshing its liveness key — see the shard-locking
        # section of `doc/backend/event.md`).
        #
        # Safe next to the run loop's own `ensure` unlock: the Lua script
        # only deletes locks this subscriber still owns, and once `@stopped`
        # is set the loop cannot start a new turn to re-acquire. A turn that
        # was already past its `until @stopped` check may lock once more
        # after this runs; that turn then exits and unlocks again — the lock
        # is gone at most one `max_block_time` later.
        private def release_shard_locks : Nil
          return if @channels.empty?
          unlock_all_shards(@redis)
        rescue e : Exception
          Log.warn { "Shard unlock on stop failed (locks recover via TTL): #{e.class}: #{e.message}" }
        end

        private def restart_callback : Proc(Nil)
          -> { Event::ConsumerHealth.report_restart(@consumer_name) }
        end

        # Runs inside the supervised subscriber fiber: create the consumer
        # groups, then enter the long-polling loop. Group creation is retried
        # through the supervisor — when Redis is unreachable at start, the
        # subscriber comes up degraded and converges when Redis returns
        # instead of failing boot. Re-entry after stop is a no-op.
        private def supervised_run : Nil
          return if @stopped
          init_groups(@redis, @channels.map(&.[0]))
          run
        end

        # ── Shard locking (via Lua) ──────────────────────────────

        private def run_script(script : String, redis, keys : Array(String) = [] of String, argv : Array(String) = [] of String, retried : Bool = false)
          script_id = @script_mutex.synchronize { @sha_scripts[script] ||= redis.script_load(script) }

          begin
            redis.evalsha(script_id, keys: keys, args: argv)
          rescue e : ::Redis::Error
            if !retried && e.message.try(&.includes?("NOSCRIPT"))
              @sha_scripts.delete(script)
              return run_script(script, redis, keys: keys, argv: argv, retried: true)
            end
            raise e
          end
        end

        private def acquire_locks(redis) : Array(String)
          result = run_script(
            LOCK_SHARDS_SCRIPT,
            redis,
            keys: ["FACET:STREAM:SHARDLOCK"],
            argv: [@consumer_name, @consumer_id, @partitions.to_s, *@channels.map(&.[0])]
          )

          arr = result.as(Array)
          output = [] of String
          arr.each_slice(2) do |(channel, flag)|
            flag_val = flag.as(Int64)
            @partitions.times do |shard_id|
              if (flag_val & (1_i64 << shard_id)) != 0
                output << "#{channel}$#{shard_id}"
              end
            end
          end
          output
        end

        private def unlock_all_shards(redis)
          chan_flags = @channels.map(&.[0]).flat_map { |ch| [ch, "0xFFFFFFFF"] }
          run_script(
            UNLOCK_SHARDS_SCRIPT,
            redis,
            keys: ["FACET:STREAM:SHARDLOCK"],
            argv: [@consumer_name, @consumer_id, @partitions.to_s, *chan_flags]
          )
        end

        private def unlock_empty_shards(message_channels : Array(String), redis)
          hash = {} of String => Int64

          message_channels.each do |channel|
            original_channel, _, shard_id_str = channel.rpartition("$")
            shard_id = shard_id_str.to_i?

            if shard_id
              hash[original_channel] ||= 0xFFFFFFFF_i64
              hash[original_channel] &= ~(1_i64 << shard_id)
            end
          end

          flat = hash.flat_map { |(ch, flag)| [ch, flag.to_s] }
          run_script(
            UNLOCK_SHARDS_SCRIPT,
            redis,
            keys: ["FACET:STREAM:SHARDLOCK"],
            argv: [@consumer_name, @consumer_id, @partitions.to_s, *flat]
          )
        end

        # ── Block time adaptation ────────────────────────────────────────

        private def reduce_block_time
          @block_time = {
            @config.block_time_delta * @block_time,
            @config.min_block_time,
          }.max
        end

        private def increase_block_time
          @block_time = {
            @block_time / @config.block_time_delta,
            @config.max_block_time,
          }.min
        end

        # ── Consumer group management ────────────────────────────────────

        # Creates the consumer group on each channel (plain key plus every
        # shard key). `BUSYGROUP` (group already exists) is ignored — an
        # existing group keeps its last-delivered-id, so the start id only
        # applies to groups created by this call. Shared by `start` (the
        # initial channel set) and `refresh_channels_if_changed` (runtime
        # additions).
        #
        # `group_start_id` decides where a NEW group starts reading: `$`
        # (default) starts at the tail — new events only; `"0"` replays the
        # retained stream. Replication uses `"0"` so a new binding converges
        # from history; hooks and webhooks keep `$` (a replay would re-fire
        # automations and re-deliver to external systems).
        private def init_groups(redis, channels : Array(String)) : Nil
          full = [] of String
          channels.each do |ch|
            full << ch
            @partitions.times { |i| full << "#{ch}$#{i}" }
          end

          full.each do |channel|
            redis.xgroup_create(channel, @consumer_name, id: @group_start_id, mkstream: true)
          rescue e : ::Redis::Error
            raise e unless e.message.try(&.includes?("BUSYGROUP"))
          end
        end

        # ── Liveness heartbeat ───────────────────────────────────────────

        private def liveness_run
          ch = @stop_channel
          return unless ch

          until @stopped
            # The key must match what `lock_shards.lua` reads:
            # `KEYS[1] .. ':SERVICE_LIVENESS:' .. <holder>` with
            # `KEYS[1] = "FACET:STREAM:SHARDLOCK"` (see `acquire_locks`). A
            # hash-tagged variant would never be found there, so every lock
            # would look stealable while its holder is alive.
            @redis.set("FACET:STREAM:SHARDLOCK:SERVICE_LIVENESS:#{@consumer_id}", "1", ex: 30)

            select
            when ch.receive?
              break
            when timeout(15.seconds)
              # continue
            end
          end
        end

        # ── Reading from streams ─────────────────────────────────────────

        private def read_stream(redis, channels : Array(String)) : Hash(String, Array(Tuple(String, String)))
          block_ms = {@config.min_block_time * 1000, 1}.max

          streams = {} of String => String
          channels.each { |ch| streams[ch] = ">" }

          result = redis.xreadgroup(
            @consumer_name,
            @consumer_id,
            count: @config.max_messages_count,
            block: block_ms.to_i,
            no_ack: true,
            streams: streams
          )

          output = {} of String => Array(Tuple(String, String))
          if result.is_a?(Array)
            result.each do |entry|
              entry = entry.as(Array)
              stream_name = entry[0].as(String)
              messages_raw = entry[1]?.try(&.as(Array)) || [] of ::Redis::Value

              messages = messages_raw.map do |msg_entry|
                msg_data = msg_entry.as(Array)
                msg_id = msg_data[0].as(String)
                msg_fields = msg_data[1]?.try(&.as(Array)) || [] of ::Redis::Value

                msg_content = if msg_fields.size >= 2 && msg_fields[0].as(String) == "msg"
                                msg_fields[1].as(String)
                              else
                                ""
                              end

                {msg_id, msg_content}
              end

              output[stream_name] = messages
            end
          end

          if @nogroup_streak > 0
            Log.info do
              "Consumer group read recovered after #{@nogroup_streak} dropped turn(s) (#{@consumer_name})"
            end
            @nogroup_streak = 0
          end

          output
        rescue e : ::Redis::Error
          raise e unless e.message.try(&.includes?("NOGROUP"))
          # A missing consumer group fails the whole XREADGROUP — every
          # stream in the batch reads nothing this turn, and the empty
          # result is indistinguishable from a healthy-but-idle subscriber.
          # That silence is how a lost group (a Redis flush, or one failed
          # group creation on a runtime-added channel) hides. Log the first
          # turn of each streak; the error message carries the stream key
          # and the group name. Recovery logs on the next clean read.
          @nogroup_streak += 1
          if @nogroup_streak == 1
            Log.warn do
              "Consumer group missing for #{@consumer_name} — reads drop until the group is re-created (NOGROUP): #{e.message}"
            end
          end
          {} of String => Array(Tuple(String, String))
        end

        # ── Message processing ──────────────────────────────────────────

        private def process_messages_for_channel(channel_messages : Tuple(String, Array(Tuple(String, String))))
          channel, messages = channel_messages

          business_channel = channel
          business_channel = business_channel.sub(@prefix, "") unless @prefix.empty?
          business_channel = business_channel.rpartition("$")[0]

          messages.each do |(msg_id, packed)|
            # One construction: the entry id from XREADGROUP overrides the
            # packed id, so the consumer path identifies a message by its
            # stream entry id, not the producer's message id.
            message = Message.unpack(
              packed,
              channel: business_channel,
              consumer_group: @consumer_name,
              id: msg_id
            )
            process_message(channel, message)
            # Counted per message, after the handler ran without raising —
            # the rescue below is the drop path (`Event::Loss` owns that
            # number). All managers' consumers report here under their own
            # consumer group name.
            Metrics.inc("facet_messages_processed_total", {"consumer" => @consumer_name})
          rescue e : Exception
            Log.error { "Event processing error on #{channel}: #{e.message}" }
            Event::Loss.record_dropped_message
          end
        end

        # ── Main loop ────────────────────────────────────────────────────

        private def run
          # Long-polling loop: on each turn, if a channel provider is set,
          # refresh the channel set. This honours runtime schema changes
          # (new source doctypes appear) without restarting the subscriber.
          until @stopped
            turn_failed = false

            begin
              refresh_channels_if_changed

              # If the channel set is empty after a refresh (e.g. registry has
              # no bindings yet), skip the work below and just sleep.
              unless @channels.empty?
                sharded_channels = acquire_locks(@redis)

                all_channels = [*@channels.map(&.[0]), *sharded_channels]
                output = read_stream(@redis, all_channels)

                has_messages = output.any? { |_, msgs| msgs.any? }

                if has_messages
                  unlock_empty_shards(output.keys, @redis)
                  output.each { |entry| process_messages_for_channel(entry) }
                  reduce_block_time
                else
                  increase_block_time
                end

                record_success
              end
            rescue e : Exception
              turn_failed = true
              record_failure(e)
            ensure
              begin
                unlock_all_shards(@redis)
              rescue e : Exception
                # A failed unlock must not kill the loop — an exception raised
                # in `ensure` escapes the sibling `rescue`. This instance
                # re-locks the same shards (same owner) on the next turn, or
                # the lock expires via TTL.
                Log.warn { "Shard unlock failed: #{e.class}: #{e.message}" }
              end
            end

            # The locks are already released: this sleep is the hand-off
            # window. A live peer acquires the free shards on its next turn.
            # If the unlock ran only after this sleep, the releaser would
            # re-acquire within microseconds and a live peer would starve.
            # A failed turn already slept in `record_failure` while holding
            # the locks, so it does not sleep twice.
            sleep_block unless turn_failed
          end
        end

        # Reports one clean loop turn: clears the failure streak, resets the
        # error backoff, and — after a failure streak — logs one recovery
        # line with the failure count and the outage length.
        private def record_success : Nil
          failures = @consecutive_failures
          @consecutive_failures = 0
          @error_backoff.reset
          Event::ConsumerHealth.report_success(@consumer_name)
          if failures > 0
            Log.info do
              "Event stream recovered after #{failures} failure(s) (#{(Time.instant - @failure_since).total_milliseconds} ms)"
            end
          end
        end

        # Reports one failed loop turn and backs off before the next attempt.
        # The sleep runs through the stop channel, so a stop during the
        # backoff ends the loop instead of waiting out the delay.
        private def record_failure(e : Exception) : Nil
          first = @consecutive_failures == 0
          @consecutive_failures += 1
          @failure_since = Time.instant if first
          delay = @error_backoff.next
          Event::ConsumerHealth.report_failure(@consumer_name, e)
          if first
            Log.error { "Event stream error: #{e.class}: #{e.message}" }
          else
            Log.warn { "Event stream error (attempt #{@consecutive_failures}, retry in #{delay.total_milliseconds} ms): #{e.class}: #{e.message}" }
          end
          interruptible_sleep(delay)
        end

        # Sleeps for the given span, interruptible by stop.
        private def interruptible_sleep(span : Time::Span) : Nil
          ch = @stop_channel
          return unless ch

          select
          when ch.receive?
            @stopped = true
          when timeout(span)
            # continue
          end
        end

        # Sleeps for the current adaptive block time, interruptible by stop.
        private def sleep_block : Nil
          interruptible_sleep(@block_time.seconds)
        end

        # If a channel provider is registered, re-fetch the desired channel
        # set. When it differs from the currently subscribed channels,
        # subscribe to the additions (creating consumer groups) and drop the
        # removals. Driven by the long-polling turn — no fiber restart.
        private def refresh_channels_if_changed : Nil
          provider = @channel_mutex.synchronize { @channel_provider }
          return if provider.nil?

          desired = provider.call.uniq!
          current = @channels.map(&.[0])

          return if desired == current

          additions = desired - current
          removals = current - desired

          @channel_mutex.synchronize do
            additions.each { |ch| @channels << {ch, false} }
            @channels.reject! { |(ch, _)| removals.includes?(ch) }
          end

          unless additions.empty?
            # Same consumer-group routine `start` uses, applied to the new
            # channels only.
            init_groups(@redis, additions)
            # A group created here starts at `group_start_id`: `$` (hooks,
            # webhooks) reads new events only, so entries published before
            # the group existed are skipped; `"0"` (replication) replays.
            skipped = @group_start_id == "$" ? "; groups start at '$' — entries published before their creation are skipped" : ""
            Log.info do
              "#{consumer_kind} subscriber #{@consumer_name}: added #{additions.size} channel(s), removed #{removals.size}#{skipped}"
            end
            @on_channels_added.try(&.call(additions))
          end
        end
      end
    end
  end
end
