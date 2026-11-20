# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "atomic"

module Facet
  module Event
    # In-process loss counters for the at-most-once event bus.
    #
    # Event delivery is at-most-once by decision (`doc/backend/event.md` →
    # Delivery contract): publish-time and
    # dispatch-time failures drop events with one log line and no retry. The
    # webhooks enqueue hop is repaired by `Cron::WebhookReconcile`; every
    # other consumer self-heals or stays accepted drift. These counters turn
    # the silent part of that contract into a number an operator can alert
    # on — they are visibility, not accounting.
    #
    # The counters are process-wide and reset on restart. `GET /Healthcheck`
    # exposes the snapshot as the `event_loss` object.
    module Loss
      @@publish_flush_failures = Atomic(Int64).new(0)
      @@publish_events_dropped = Atomic(Int64).new(0)
      @@messages_dropped = Atomic(Int64).new(0)

      # Records one failed `Publisher.flush` and the number of events the
      # flushed queue held at failure (the queue is discarded — see
      # `Publisher#flush`'s `ensure`).
      def self.record_flush_failure(events_dropped : Int32) : Nil
        @@publish_flush_failures.add(1)
        @@publish_events_dropped.add(events_dropped.to_i64)
      end

      # Records one message swallowed by a dispatch rescue. The rescues
      # nest (stream → subscriber base → registry → subsystem handler); the
      # innermost one that swallows the error is the one that increments,
      # so each dropped message counts once.
      def self.record_dropped_message : Nil
        @@messages_dropped.add(1)
      end

      # Returns the current counter values.
      def self.snapshot : Hash(String, Int64)
        {
          "publish_flush_failures" => @@publish_flush_failures.get,
          "publish_events_dropped" => @@publish_events_dropped.get,
          "messages_dropped"       => @@messages_dropped.get,
        }
      end

      # Resets every counter. Spec support only.
      def self.reset : Nil
        @@publish_flush_failures.set(0)
        @@publish_events_dropped.set(0)
        @@messages_dropped.set(0)
      end
    end
  end
end
