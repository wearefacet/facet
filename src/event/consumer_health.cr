# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../util/string_util"

module Facet
  module Event
    # Process-wide consumer-health registry for the stream subscriber fibers.
    #
    # `Subscriber::Stream` registers its consumer group on `start` and
    # unregisters on `stop`; the run loop reports one failure per failed turn
    # and one success per clean turn, and the fiber supervisor reports
    # restarts. Reports for unregistered keys are no-ops — a consumer is
    # registered before its fibers spawn, so a post-stop report cannot
    # linger.
    #
    # Keys are consumer group names (`hr`, `cg:repl:hr`, …) and are unique
    # per process. The registry is in-process and reset on restart.
    # `GET /Healthcheck` renders the snapshot as the `events` object and
    # returns 503 while any consumer has consecutive failures — the loud,
    # self-healing degraded state (`doc/backend/event.md` → Supervision
    # and error backoff).
    module ConsumerHealth
      # One consumer's health record.
      class State
        getter name : String
        property consecutive_failures : Int32 = 0
        property restarts : Int32 = 0
        property last_success_at : Time? = nil
        property last_error : String? = nil

        def initialize(@name : String)
        end
      end

      @@states = {} of String => State
      @@mutex = Mutex.new

      # Registers a consumer. Re-registering keeps the existing state.
      def self.register(key : String) : Nil
        @@mutex.synchronize { state(key) }
      end

      # Removes a consumer. No-op for an unknown key.
      def self.unregister(key : String) : Nil
        @@mutex.synchronize { @@states.delete(key) }
      end

      # Records one failed loop turn for the consumer.
      def self.report_failure(key : String, error : Exception) : Nil
        @@mutex.synchronize do
          return unless s = @@states[key]?
          s.consecutive_failures += 1
          s.last_error = Util::StringUtil.truncate(error.message || error.class.name, 200)
        end
      end

      # Records one successful loop turn: clears the failure streak and
      # stamps the success time.
      def self.report_success(key : String) : Nil
        @@mutex.synchronize do
          return unless s = @@states[key]?
          s.consecutive_failures = 0
          s.last_success_at = Time.utc
        end
      end

      # Records one supervised fiber restart for the consumer.
      def self.report_restart(key : String) : Nil
        @@mutex.synchronize do
          return unless s = @@states[key]?
          s.restarts += 1
        end
      end

      # True when at least one registered consumer has consecutive failures.
      def self.degraded? : Bool
        @@mutex.synchronize { @@states.each_value.any? { |s| s.consecutive_failures > 0 } }
      end

      # One entry per registered consumer, sorted by name.
      def self.snapshot : Array(NamedTuple(name: String, consecutive_failures: Int32, restarts: Int32, last_success_at: String?, last_error: String?))
        @@mutex.synchronize do
          @@states.values.sort_by!(&.name).map do |s|
            {
              name:                 s.name,
              consecutive_failures: s.consecutive_failures,
              restarts:             s.restarts,
              last_success_at:      s.last_success_at.try(&.to_rfc3339),
              last_error:           s.last_error,
            }
          end
        end
      end

      # Clears every entry. Spec support only.
      def self.reset : Nil
        @@mutex.synchronize { @@states.clear }
      end

      private def self.state(key : String) : State
        @@states[key] ||= State.new(key)
      end
    end
  end
end
