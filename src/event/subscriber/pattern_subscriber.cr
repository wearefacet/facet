# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../../metrics"
require "../../util/fiber_supervisor"

module Facet
  module Event
    module Subscriber
      # Base class for the process-wide cache-invalidation Pub/Sub
      # subscribers (`DoctypeCache`, `AppCache`, `RoleCache`).
      #
      # Owns the whole lifecycle: one long-lived `PSUBSCRIBE` connection on
      # the patterns from `#patterns`, a reconnect loop with a 1-second
      # backoff, and clean `start`/`stop`. No per-instance stop channel —
      # `stop` only flips the flag; the blocking `psubscribe` loop ends with
      # its connection, and the run loop notices `@started == false` on its
      # next iteration (these subscribers are daemon-like). The run fiber is
      # supervised (`Util::FiberSupervisor`), so a raise that escapes the
      # reconnect loop restarts it instead of dying silently.
      #
      # Per-message errors never kill the connection — the message handler
      # runs inside a `rescue`.
      #
      # Subclasses define only `#patterns`, `#handle_message`, and their own
      # `Log` constant for debug lines. Everything is channel-keyed and
      # invalidate-only: the payload is never inspected.
      #
      # `Fanout` keeps its own loop — it drains `Sub`/`Unsub` commands and
      # guards its connection with a mutex. That machinery does not fit
      # this base, so the two stay separate.
      abstract class PatternSubscriber
        getter redis_url : String
        getter service_id : String
        getter? started : Bool

        # - *subscriber_name* — used for the spawn label and the log
        #   source: `"DoctypeCache"` spawns `"DoctypeCache Subscriber
        #   (<service_id>)"` and logs as
        #   `facet.event.subscriber.doctype_cache` when the base owns the
        #   line.
        def initialize(@redis_url : String, @service_id : String, subscriber_name : String)
          @started = false
          @log = ::Log.for("facet.event.subscriber.#{subscriber_name.underscore}")
          @spawn_name = "#{subscriber_name} Subscriber (#{@service_id})"
        end

        # The Redis patterns to `PSUBSCRIBE`. Constant for the process
        # lifetime; a compile-time tuple so the call site can splat it into
        # the varargs `PSUBSCRIBE` (Crystal expands tuple splats at compile
        # time; an `Array` splat is not valid).
        abstract def patterns : Tuple

        # Dispatches one pattern message. Channel-keyed; the payload stays
        # unused.
        abstract def handle_message(channel : String, message : String) : Nil

        def start : Nil
          return if @started
          @started = true
          Util::FiberSupervisor.supervise(@spawn_name) { run }
        end

        def stop : Nil
          return unless @started
          @started = false
        end

        private def run : Nil
          loop do
            break unless @started
            begin
              run_once
            rescue e : Exception
              @log.error { "subscriber error: #{e.message}" }
              Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => @spawn_name})
              sleep 1.second if @started
            end
          end
        end

        private def run_once : Nil
          conn = ::Redis::Connection.new(URI.parse(@redis_url))

          begin
            case pats = patterns
            when Tuple(String)                                 then psubscribe(conn, pats)
            when Tuple(String, String)                         then psubscribe(conn, pats)
            when Tuple(String, String, String)                 then psubscribe(conn, pats)
            when Tuple(String, String, String, String)         then psubscribe(conn, pats)
            when Tuple(String, String, String, String, String) then psubscribe(conn, pats)
            else
              raise "#{self.class.name}: unsupported pattern arity #{pats.size}"
            end
          ensure
            conn.close
          end
        end

        # Splits the `PSUBSCRIBE` call per tuple width: generic instantiation
        # gives each pattern-list type its own body, so the varargs splat
        # stays compile-time (a union splat does not compile).
        private def psubscribe(conn : ::Redis::Connection, patterns : P) forall P
          conn.psubscribe(*patterns) do |subscription, _connection|
            subscription.on_message do |channel, message|
              dispatch_pattern_message(channel, message)
            end
          end
        end

        # Per-message error barrier: one bad message must not tear down
        # the subscription.
        private def dispatch_pattern_message(channel : String, message : String) : Nil
          handle_message(channel, message)
        rescue e : Exception
          @log.error { "handle_message error on #{channel}: #{e.message}" }
        end
      end
    end
  end
end
