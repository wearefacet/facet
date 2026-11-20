# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "../metrics"

module Facet
  module Util
    # Restarts a long-lived fiber's body when it raises, so one unhandled
    # exception cannot silently kill background work. Standardized from the
    # `Subscriber::Stream#liveness_run` recursive-restart precedent.
    #
    # `supervise` runs the body inside one supervisor fiber — the fiber keeps
    # the passed `name`, so crash reports and debug output stay comparable. A
    # raise logs one ERROR line, increments the
    # `facet_fiber_restarts_total{fiber}` counter, fires the `on_restart`
    # callback, waits out the backoff, and runs the body again. A normal
    # return ends the supervision (clean stop): `on_stop` fires on the
    # supervisor fiber before it exits — the observable end of supervision.
    #
    # The callbacks must not raise — report to a registry and return. A
    # raising callback would kill the supervisor itself.
    #
    # Every long-lived fiber in `src/` runs under this supervisor
    # (`doc/backend/event.md` → Supervision and error backoff).
    module FiberSupervisor
      extend self

      Log = ::Log.for("facet.fiber_supervisor")

      # Restart-delay schedule: `#next` returns the current delay and then
      # grows it by `factor`, capped at `cap`. `#reset` returns to the
      # initial delay. Defaults (0.5 s, ×2, 5 s cap) keep a restarted
      # consumer well inside the 30 s shard-liveness TTL.
      class Backoff
        def initialize(@initial : Time::Span = 0.5.seconds, @factor : Float64 = 2.0, @cap : Time::Span = 5.seconds)
          @current = @initial
        end

        # Returns the current delay, then grows it towards the cap.
        def next : Time::Span
          delay = @current
          grown = @current * @factor
          @current = grown < @cap ? grown : @cap
          delay
        end

        def reset : Nil
          @current = @initial
        end
      end

      # Runs *body* inside one supervised fiber named *name*. A normal return
      # of the body ends the supervision; a raise restarts it after the next
      # backoff delay. `on_stop` fires once on that clean-return path, on the
      # supervisor fiber, before it exits — a shutdown hook and the
      # test-visible end of supervision. Returns the supervisor fiber, so
      # callers that expose the fiber (e.g. for `dead?` assertions in specs)
      # keep doing so.
      def supervise(name : String, backoff : Backoff = Backoff.new, on_restart : Proc(Nil)? = nil, on_stop : Proc(Nil)? = nil, &body : -> Nil) : Fiber
        spawn(name: name) do
          loop do
            begin
              body.call
              on_stop.try(&.call)
              break
            rescue e : Exception
              delay = backoff.next
              Log.error { "#{name} died: #{e.class}: #{e.message} — restarting in #{delay.total_milliseconds} ms" }
              Metrics.inc("facet_fiber_restarts_total", {"fiber" => name})
              on_restart.try(&.call)
              sleep(delay)
            end
          end
        end
      end
    end
  end
end
