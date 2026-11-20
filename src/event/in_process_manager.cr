# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./message"
require "./subscription_registry"

module Facet
  module Event
    # In-memory event manager for single-process usage (tests, development,
    # and future registration layer).
    #
    # Mirrors the `Event::Manager` publish/subscribe interface but keeps
    # everything in local memory — no Redis connection needed.
    #
    # ## Design
    #
    # - Events are stored in a `Hash(String, Array(Message))` keyed by
    #   channel name (e.g. `"FACET:RESOURCE:hr:Employee"`).
    # - Publishing appends to the channel's array.
    # - Subscriptions register a callback that is invoked synchronously on
    #   publish. No consumer groups, no sharding, no persistence.
    # - Suitable for single-process multi-fiber setups. Thread-safety is
    #   provided by a single `Mutex` — lock contention is negligible since
    #   this is designed for non-Redis environments.
    class InProcessManager
      # The shared subscription record lives on `Event::Subscription` (see
      # `SubscriptionRegistry`). Kept as a nested alias so
      # `Event::InProcessManager::Subscription` stays valid for external
      # type annotations.
      alias Subscription = ::Facet::Event::Subscription

      include SubscriptionRegistry

      getter subscriptions : Array(Subscription)
      getter events : Hash(String, Array(Message))

      def initialize
        @subscriptions = [] of Subscription
        @events = {} of String => Array(Message)
        @started = false
        @mutex = Mutex.new
      end

      # ── Subscription ──────────────────────────────────────────────
      # The subscribe entry points (`subscribe_resource_event`,
      # `subscribe_resource_stream`) come from `SubscriptionRegistry`.
      # Subscriptions must be registered before `start`, same contract as
      # `Manager` (the registry raises after start).

      # ── Publishing ────────────────────────────────────────────────────

      # Publish a resource event — stores it in memory on both the resource
      # stream channel and the fanout channel, and dispatches to matching
      # subscriptions synchronously.
      #
      # Fanout channel format: `fanout:{domain}.{doc_type}:{resource_id}`.
      # On the default path (no `fanout_channels` override) the event is
      # ALSO stored on the collection channel `fanout:{domain}.{doc_type}`
      # (no trailing `:id`) so WebSocket collection subscribers receive the
      # mutation. Override paths (e.g. the `notified` event) skip the
      # collection channel — their payload is not a document-id frame.
      # `fanout_channels` overrides the derived document fanout channel.
      # `nil` stores on the default `fanout:{domain}.{doc_type}:{id}` plus
      # the collection channel; an explicit list stores on exactly those
      # channels (an empty list skips the fanout store). Mirrors
      # `Event::Manager`.
      def publish_resource_event(
        domain : String,
        resource_type : String,
        resource_id : String,
        event : String,
        payload : Hash(String, ::JSON::Any),
        headers : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any,
        fanout_channels : Array(String)? = nil,
      ) : String
        channel = "FACET:RESOURCE:#{resource_type}"

        merged_headers = headers.merge({"event" => ::JSON::Any.new(event)})
        message = Message.new(
          content: ::JSON::Any.new(payload),
          headers: merged_headers,
          channel: "#{channel}:#{event}",
        )

        id = message.id

        fanout_channels ||= [
          "fanout:#{domain}.#{extract_doc_type(resource_type)}:#{resource_id}",
          "fanout:#{domain}.#{extract_doc_type(resource_type)}",
        ]

        @mutex.synchronize do
          # Store on the resource stream channel
          (@events[channel] ||= [] of Message) << message

          # Store on the fanout channel(s) (mirrors the PUBLISH in Manager)
          fanout_channels.each do |fanout_channel|
            (@events[fanout_channel] ||= [] of Message) << message
          end

          # Dispatch to matching subscriptions (exact channel names only)
          dispatch_subscriptions(channel, message)
        end

        id
      end

      # Publish to a named channel (generic, not resource-scoped).
      def publish(
        channel : String,
        payload : ::JSON::Any,
        headers : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any,
      ) : String
        message = Message.new(content: payload, headers: headers, channel: channel)
        id = message.id

        @mutex.synchronize do
          (@events[channel] ||= [] of Message) << message

          dispatch_subscriptions(channel, message)
        end

        id
      end

      # ── Lifecycle ─────────────────────────────────────────────

      # Start/stop only flip the flag. Subscriptions must be registered
      # before `start` (the registry raises after start).
      def start : Nil
        @mutex.synchronize do
          @started = true
        end
      end

      def stop : Nil
        @mutex.synchronize do
          @started = false
        end
      end

      def started? : Bool
        @started
      end

      # ── Health ───────────────────────────────────────────────────────

      # Reports `in_process` because this manager has no Redis connection to
      # probe. Used by the `/Healthcheck` HTTP endpoint so the healthcheck
      # does not falsely report a Redis failure in tests / single-process dev.
      def redis_health : NamedTuple(status: String, error: String?)
        {status: "in_process", error: nil}
      end

      # ── Inspection ────────────────────────────────────────────────────

      # Returns all stored events for a given channel (for assertions in specs).
      def events_for(channel : String) : Array(Message)
        @mutex.synchronize do
          @events.fetch(channel, [] of Message).dup
        end
      end

      # Clears all stored events and subscriptions (for test isolation).
      def clear! : Nil
        @mutex.synchronize do
          @events.clear
          @subscriptions.clear
          @started = false
        end
      end
    end
  end
end
