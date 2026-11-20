# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../message"
require "../../metrics"
require "../../util/fiber_supervisor"
require "../../util/retry"

module Facet
  module Event
    module Subscriber
      # Per-process fanout Pub/Sub listener.
      #
      # Opens one long-lived Redis Pub/Sub connection managed by a single
      # control fiber. WebSocket fibers (or any producer) send `Sub`/`Unsub`
      # commands through a shared `Channel(Command)` — they never touch the
      # Redis connection directly, preventing frame interleaving at flush
      # yields.
      #
      # ## Sentinel
      #
      # A sentinel channel (`fanout:_keepalive:{service_id}`) is subscribed at
      # start and **never** unsubscribed. This keeps the subscription count
      # above zero so the underlying Redis SUBSCRIBE loop does not exit.
      # The sentinel is never published to.
      #
      # ## Reconnection
      #
      # If the connection drops, the subscriber automatically reconnects after
      # a short backoff. Redis drops the per-connection `SUBSCRIBE` state when
      # the socket dies, so every reconnect re-subscribes the sentinel plus
      # every channel in the tracked set (`#subscribe` / `#unsubscribe` keep
      # it in step with the `Websocket::Manager` intent) before the message
      # loop starts. Messages published inside the reconnect window are lost —
      # Pub/Sub is fire-and-forget; the window is bounded by the 1-second
      # backoff. Commands issued while the connection is down are dropped by
      # the drain (a missing connection means mid-reconnect) — the tracked set
      # plus the resubscribe pass re-establishes the desired state, so a
      # dropped command cannot leave a stale subscription behind.
      class Fanout
        Log = ::Log.for("facet.event.subscriber.fanout")

        record Command,
          verb : Verb,
          channel : String

        enum Verb
          Sub
          Unsub
        end

        getter service_id : String
        getter sentinel : String

        def initialize(
          @redis_url : String,
          @service_id : String,
          &@handler : String, Message ->
        )
          @sentinel = "fanout:_keepalive:#{@service_id}"
          @commands = Channel(Command).new(32)
          @done = Channel(Nil).new(1)
          @connection = nil.as(::Redis::Connection?)
          @connection_mutex = Mutex.new
          # Channels the process wants subscribed, guarded by
          # `@connection_mutex`. The source of truth for the per-reconnect
          # resubscribe pass — the `Sub`/`Unsub` commands only apply deltas
          # on a live connection.
          @subscriptions = Set(String).new
          @started = false
        end

        # ── Public API ────────────────────────────────────────────────────

        # Register a channel subscription.
        #
        # Can be called before *or* after `#start`. The command queues in
        # `@commands` until the drain fiber processes it; the tracked set is
        # updated immediately, so a reconnect that happens first still
        # re-subscribes the channel.
        def subscribe(channel : String) : Nil
          @connection_mutex.synchronize { @subscriptions << channel }
          @commands.send(Command.new(verb: Verb::Sub, channel: channel))
        end

        # Unsubscribe from a channel.
        #
        # The sentinel channel can never be unsubscribed — calls targeting it
        # are silently ignored.
        def unsubscribe(channel : String) : Nil
          return if channel == @sentinel
          @connection_mutex.synchronize { @subscriptions.delete(channel) }
          @commands.send(Command.new(verb: Verb::Unsub, channel: channel))
        end

        # Start the subscriber: one supervised command-drain fiber (lives for
        # the whole `Fanout`, survives per-command failures) and one
        # supervised connection loop.
        def start : Nil
          return if @started
          @started = true
          Util::FiberSupervisor.supervise(drain_label) { drain_commands }
          Util::FiberSupervisor.supervise(subscriber_label) { run }
        end

        # Stop the subscriber and wait for the fiber to exit.
        def stop : Nil
          return unless @started
          @started = false
          @commands.close

          # Close the connection from outside so the blocking subscribe loop
          # exits even if the drain fiber hasn't processed the close yet.
          @connection_mutex.synchronize do
            conn = @connection
            @connection = nil
            conn.try(&.close)
          end

          # Wait for the run fiber to signal completion (with a timeout).
          select
          when @done.receive?
            # Clean shutdown.
          when timeout(3.seconds)
            Log.warn { "Fanout subscriber did not stop within 3s" }
          end
        end

        def started? : Bool
          @started
        end

        # ── Internal ──────────────────────────────────────────────────────

        # Fiber labels — also the `facet_fiber_*` metric labels. Bounded per
        # process (one Fanout per service id).
        private def subscriber_label : String
          "Fanout Subscriber (#{@service_id})"
        end

        private def drain_label : String
          "Fanout Command Drain (#{@service_id})"
        end

        private def run
          loop do
            break unless @started
            begin
              run_once
            rescue e : Exception
              if @started
                Log.error { "Fanout subscriber error: #{e.message}" }
                Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => subscriber_label})
                sleep 1.second
              end
            end
          end
        ensure
          @done.send(nil)
        end

        private def run_once
          conn = ::Redis::Connection.new(URI.parse(@redis_url))

          begin
            # Subscribe to the sentinel (blocking call with callback loop).
            # subscription.call blocks until the connection is closed.
            conn.subscribe(@sentinel) do |subscription, _connection|
              subscription.on_message do |channel, message|
                handle_message(channel, message)
              end

              # Re-establish the tracked subscriptions while this fiber is
              # still the connection's only writer (`@connection` is not
              # handed to the drain yet), then hand the connection over. The
              # drain becomes the single writer; the subscription loop above
              # is the single reader.
              resubscribe_all(conn)
              @connection_mutex.synchronize { @connection = conn }
            end
          ensure
            @connection_mutex.synchronize do
              @connection = nil if @connection == conn
            end
          end
        end

        # Re-subscribes every tracked channel on *conn*. Runs before the
        # connection is published to the drain, so failures here cannot
        # interleave with drain writes. One failing channel must not skip the
        # rest; a connection-level failure fails each remaining channel the
        # same way and the reconnect loop replaces the connection.
        private def resubscribe_all(conn : ::Redis::Connection) : Nil
          channels = @connection_mutex.synchronize { @subscriptions.dup }
          channels.each do |channel|
            begin
              conn.subscribe(channel)
            rescue e : Exception
              Log.error { "Fanout resubscribe failed for #{channel}: #{e.message}" }
              Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => subscriber_label})
            end
          end
        end

        private def handle_message(channel : String, message : String) : Nil
          return if channel == @sentinel

          msg = Message.unpack(message, channel: channel)
          @handler.call(channel, msg)
        rescue e : Exception
          Log.error { "Handler error on #{channel}: #{e.message}" }
        end

        # One drain fiber for the whole `Fanout` lifetime. Resolves the
        # current connection per command: a missing connection means a
        # reconnect is in flight — the command is dropped and the tracked set
        # plus the resubscribe pass re-establishes the desired state. A
        # command that keeps failing on a live connection is retried, then
        # logged and counted — the drain itself must never die, or every
        # later sub/unsub would queue forever.
        private def drain_commands : Nil
          loop do
            cmd = @commands.receive

            case cmd.verb
            when Verb::Sub
              run_command(cmd, &.subscribe(cmd.channel))
            when Verb::Unsub
              run_command(cmd, &.unsubscribe(cmd.channel))
            end
          end
        rescue Channel::ClosedError
          # Stop was called — no need to close connection here; the outer
          # stop() method closes it directly.
        end

        # Executes one subscription command against the current connection,
        # re-resolving it per retry so a reconnect that lands mid-retry
        # targets the fresh connection. Final failure is logged and counted;
        # the drain continues with the next command.
        private def run_command(cmd : Command, &) : Nil
          Util::Retry.with_retry(max_attempts: 5) do
            conn = @connection_mutex.synchronize { @connection }
            next if conn.nil?
            yield conn
          end
        rescue e : Exception
          Log.error { "Fanout command #{cmd.verb} #{cmd.channel} failed: #{e.class}: #{e.message}" }
          Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => drain_label})
        end
      end
    end
  end
end
