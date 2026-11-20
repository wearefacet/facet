# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./message"

module Facet
  module Event
    # The subscription record shared by the Redis-backed `Manager` and the
    # in-memory `InProcessManager` (see `SubscriptionRegistry`). Nested
    # aliases on both managers (`Event::Manager::Subscription`) keep the
    # former qualified names valid for external type annotations.
    class Subscription
      getter domain : String
      getter channel : String
      getter block : Proc(Message, Nil)

      def initialize(@domain : String, @channel : String, @block : Proc(Message, Nil))
      end
    end

    # Shared subscription plumbing for the Redis-backed `Manager` and the
    # in-memory `InProcessManager`.
    #
    # Owns the two subscribe entry points and message dispatch to matching
    # subscriptions; the `Subscription` type sits on `Event` itself. Publish
    # and storage stay per-manager: `Manager` writes to Redis Streams and
    # Pub/Sub; `InProcessManager` stores messages in local memory.
    #
    # Including classes must initialize `@subscriptions`
    # (`Array(Event::Subscription)`), `@started`, and `@mutex` in their own
    # `initialize` before any registry method runs.
    module SubscriptionRegistry
      # Subscribe to a resource event for a specific domain/doctype/event.
      # The handler fires only for messages whose `event` header equals
      # *event*.
      def subscribe_resource_event(
        domain : String,
        resource_type : String,
        event : String,
        &handler : Message ->
      )
        channel = "FACET:RESOURCE:#{resource_type}"

        callback = ->(msg : Message) {
          if msg.headers["event"]?.try(&.as_s) == event
            handler.call(msg)
          end
        }

        register_subscription(domain, channel, callback)
      end

      # Subscribe to a resource stream without filtering by event name.
      #
      # Used by the replication handler, which must react to every mutation
      # event (`created`/`updated`/`deleted`/`migrated`/`rolled_back` and
      # action events alike). Relevance is decided inside the handler by
      # inspecting the source projection, not by the event name.
      #
      # The `domain` is the **consuming** domain (drives consumer-group
      # creation); the `resource_type` is the **source** doctype's
      # `{source_domain}:{source_doctype}`, which becomes the Redis stream
      # key `FACET:RESOURCE:{resource_type}`.
      def subscribe_resource_stream(
        domain : String,
        resource_type : String,
        &handler : Message ->
      )
        channel = "FACET:RESOURCE:#{resource_type}"

        register_subscription(domain, channel, handler)
      end

      # Calls every subscription registered for *channel*.
      #
      # With `prefix_match: true` (the Redis stream path) a message channel
      # also matches its shard keys — `FACET:RESOURCE:hr:Employee$3` matches
      # the subscription for `FACET:RESOURCE:hr:Employee`. The in-memory
      # path publishes to exact channel names, so it matches exactly.
      def dispatch_subscriptions(channel : String, message : Message, prefix_match : Bool = false) : Nil
        @subscriptions.each do |sub|
          next unless prefix_match ? channel.starts_with?(sub.channel) : channel == sub.channel

          begin
            sub.block.call(message)
          rescue e : Exception
            ::Log.for("facet.event").error { "Event dispatch error on #{channel}: #{e.message}" }
            Event::Loss.record_dropped_message
          end
        end
      end

      # Registers a stream subscription after the manager has started.
      #
      # `register_subscription` refuses post-start registration because a
      # late subscription would normally never see messages: the stream
      # subscriber's channel set is fixed outside the provider mechanism.
      # Provider-driven subscribers are the exception — they add channels at
      # runtime (`refresh_channels_if_changed`) and create the consumer
      # groups for them; this method pairs those additions with a dispatch
      # registration so the messages are not read and silently dropped.
      # Duplicate registrations for the same (domain, channel) pair are
      # ignored, so idempotent callers are safe.
      def register_stream_subscription(
        domain : String,
        resource_type : String,
        &handler : Message ->
      ) : Nil
        channel = "FACET:RESOURCE:#{resource_type}"

        @mutex.synchronize do
          return if @subscriptions.any? { |s| s.domain == domain && s.channel == channel }
          @subscriptions << Subscription.new(domain: domain, channel: channel, block: handler)
        end
      end

      # Extracts the doc_type from a resource_type string.
      # Resource type format is `"domain:doc_type"` in production usage.
      # Falls back to the full string if there's no colon separator.
      private def extract_doc_type(resource_type : String) : String
        if idx = resource_type.index(':')
          resource_type[(idx + 1)..]
        else
          resource_type
        end
      end

      private def register_subscription(domain : String, channel : String, block : Proc(Message, Nil)) : Nil
        @mutex.synchronize do
          raise "cannot subscribe after start" if @started
          @subscriptions << Subscription.new(domain: domain, channel: channel, block: block)
        end
      end
    end
  end
end
