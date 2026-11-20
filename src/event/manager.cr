# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "random/secure"
require "redis"
require "../metrics"
require "./config"
require "./message"
require "./subscription_registry"
require "./subscriber/stream"

module Facet
  module Event
    Log = ::Log.for("facet.event")

    # The central event manager.
    #
    # Manages subscriptions and publish for multiple domains. Each domain
    # gets its own Stream subscriber (consumer group), all running in
    # separate fibers.
    class Manager
      # The shared subscription record lives on `Event::Subscription` (see
      # `SubscriptionRegistry`). Kept as a nested alias so
      # `Event::Manager::Subscription` stays valid for external type
      # annotations.
      alias Subscription = ::Facet::Event::Subscription

      include SubscriptionRegistry

      getter subscriptions : Array(Subscription)
      getter config : Config
      getter service_id : String
      getter stream_subscribers : Hash(String, Subscriber::Stream)

      # Prefix prepended to the consumer group name. The general-purpose
      # manager (default) uses bare domain names (e.g. `hr`). The replication
      # manager passes `"cg:repl:"` so consumer groups become `cg:repl:hr`,
      # isolating replication consumers from other stream consumers on the
      # same source channels.
      getter consumer_group_prefix : String

      # The stream id a consumer group created by this manager starts from:
      # `"$"` (default — the tail, new events only) or `"0"` (replay the
      # retained stream). Only applies to groups that do not exist yet;
      # `BUSYGROUP` is ignored for existing groups. Replication passes
      # `"0"` so a new binding converges from retained history.
      getter group_start_id : String

      def initialize(
        config : Config = Config.new,
        service_id : String = Random.new.hex(8),
        consumer_group_prefix : String = "",
        group_start_id : String = "$",
      )
        @config = config
        @service_id = service_id
        @consumer_group_prefix = consumer_group_prefix
        @group_start_id = group_start_id
        @subscriptions = [] of Subscription
        @stream_subscribers = {} of String => Subscriber::Stream
        @started = false
        @mutex = Mutex.new
        @redis = ::Redis::Client.new(URI.parse(config.url))
      end

      # ── Health ───────────────────────────────────────────────────────

      # Probes the Redis connection with a PING. Returns `status` ("ok" |
      # "error") and `error` (message on failure, nil on success). Used by the
      # `/Healthcheck` HTTP endpoint — see `HTTP::Server.routes`.
      def redis_health : NamedTuple(status: String, error: String?)
        @redis.ping
        {status: "ok", error: nil}
      rescue ex
        {status: "error", error: ex.message}
      end

      # ── Subscription ──────────────────────────────────────────────────
      # The subscribe entry points (`subscribe_resource_event`,
      # `subscribe_resource_stream`) come from `SubscriptionRegistry`.

      # ── Publishing ────────────────────────────────────────────────────

      # Publish a resource event — writes to the sharded stream and also
      # issues a Redis PUBLISH on a fanout channel so interested consumers
      # (e.g. WebSocket bridges) can follow specific documents in real time.
      #
      # Fanout channel format: `fanout:{domain}.{doc_type}:{resource_id}`.
      # On the default path (no `fanout_channels` override) the event is
      # ALSO published to the collection channel `fanout:{domain}.{doc_type}`
      # (no trailing `:id`) so WebSocket collection subscribers receive the
      # mutation. Override paths (e.g. the `notified` event) skip the
      # collection publish — their payload is not a document-id frame.
      # `fanout_channels` overrides the derived document fanout channel.
      # `nil` publishes to the default `fanout:{domain}.{doc_type}:{id}`
      # plus the collection channel; an explicit list publishes to exactly
      # those channels (an empty list skips the fanout publish).
      def publish_resource_event(
        domain : String,
        resource_type : String,
        resource_id : String,
        event : String,
        payload : Hash(String, ::JSON::Any),
        headers : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any,
        fanout_channels : Array(String)? = nil,
      ) : String
        partition = find_partition(resource_id)
        shard = partition % @config.partitions
        stream = "FACET:RESOURCE:#{resource_type}$#{shard}"

        merged_headers = headers.merge({"event" => ::JSON::Any.new(event)})
        message = Message.new(
          content: ::JSON::Any.new(payload),
          headers: merged_headers
        )

        packed = message.pack

        # Write to the sharded stream (persistent event log)
        id = @redis.xadd(stream, "*", maxlen: {"~", @config.maxlen.to_s}, fields: {"msg" => packed}).to_s
        Metrics.inc("facet_events_published_total")

        # Publish to the fanout channel(s) (real-time notification)
        if channels = fanout_channels
          channels.each { |channel| @redis.publish(channel, packed) }
        else
          doc_type = extract_doc_type(resource_type)
          @redis.publish("fanout:#{domain}.#{doc_type}:#{resource_id}", packed)
          # Collection channel — no trailing :id. WebSocket collection
          # subscribers filter per-connection via RBAC at dispatch time.
          @redis.publish("fanout:#{domain}.#{doc_type}", packed)
        end

        id
      end

      # Publish to a named channel.
      def publish(
        channel : String,
        payload : ::JSON::Any,
        headers : Hash(String, ::JSON::Any) = {} of String => ::JSON::Any,
      ) : String
        message = Message.new(content: payload, headers: headers)
        packed = message.pack

        id = @redis.xadd(channel, "*", maxlen: {"~", @config.maxlen.to_s}, fields: {"msg" => packed}).to_s
        Metrics.inc("facet_events_published_total")
        id
      end

      # ── Start / Stop ──────────────────────────────────────────────────

      def start : Nil
        @mutex.synchronize do
          return if @started
          @started = true
        end

        by_domain = @subscriptions.group_by(&.domain)

        by_domain.each do |domain, subs|
          channels = subs.map(&.channel).uniq!
          subscriber = build_stream_subscriber(domain)

          channels.each { |ch| subscriber.subscribe(ch) }

          subscriber.start
          @stream_subscribers[domain] = subscriber
        end
      end

      def stop : Nil
        @mutex.synchronize do
          return unless @started
          @started = false
        end

        @stream_subscribers.each_value(&.stop)
        @stream_subscribers.clear
      end

      # Installs a channel-provider callback on the stream subscriber for the
      # given consuming domain. The subscriber consults it on each polling
      # turn to detect channel-set changes (e.g. new source doctypes added by
      # a registry refresh) and applies the diff at runtime — no restart.
      #
      # Must be called after `start`. No-op if the domain has no subscriber.
      def set_channel_provider(domain : String, provider : Proc(Array(String))) : Nil
        subscriber = @stream_subscribers[domain]?
        subscriber.try(&.channel_provider=(provider))
      end

      # Installs the callback invoked with the channels a provider-driven
      # subscriber adds at runtime. The callback must pair each addition with
      # a dispatch registration (`register_stream_subscription`) — without it
      # the messages on the new channels are read from the stream and then
      # dropped, because the dispatcher only delivers to registered
      # subscriptions.
      #
      # Must be called after `start`. No-op if the domain has no subscriber.
      def set_channel_add_callback(domain : String, callback : Proc(Array(String), Nil)) : Nil
        subscriber = @stream_subscribers[domain]?
        subscriber.try(&.on_channels_added=(callback))
      end

      # Creates and starts the stream subscriber for `domain` if it does not
      # exist yet. Used by subsystem managers whose consumer set grows at
      # runtime: a consuming domain that was unknown at `start` has no
      # subscriber, and `set_channel_provider` cannot reach one that does not
      # exist. The initial *channels* are subscribed before the fiber starts
      # (consumer groups created with the manager's `group_start_id` — `$`
      # starts at the tail, so entries published before this point are never
      # delivered; only replication, which passes `"0"`, replays the
      # retained stream), and *provider* plus *on_channels_added* are
      # installed before `start` so the subscriber never runs without them.
      # Idempotent.
      def ensure_stream_subscriber(
        domain : String,
        channels : Array(String),
        provider : Proc(Array(String)),
        on_channels_added : Proc(Array(String), Nil),
      ) : Nil
        @mutex.synchronize do
          next if @stream_subscribers[domain]?

          subscriber = build_stream_subscriber(domain)
          channels.each { |ch| subscriber.subscribe(ch) }
          subscriber.channel_provider = provider
          subscriber.on_channels_added = on_channels_added
          subscriber.start
          @stream_subscribers[domain] = subscriber

          # First subscriber for this domain, created after boot — the sync
          # fiber noticed a consumer that appeared at runtime. With the
          # default `$` start every entry published before this line is
          # never delivered (at-most-once by decision, no replay); the log
          # makes that drop observable instead of silent (B-337).
          if @group_start_id == "$"
            Log.warn { "#{subscriber.consumer_kind} subscriber for domain '#{domain}' created after boot — stream entries published before now are skipped (groups start at '$', no replay)" }
          end
        end
      end

      def started? : Bool
        @started
      end

      # ── Dispatch ──────────────────────────────────────────────

      # The Redis stream path dispatches with prefix matching: the
      # subscriber delivers sharded keys (`FACET:RESOURCE:hr:Employee$3`),
      # while subscriptions register the unsharded channel.
      private def dispatch_message(channel : String, message : Message) : Nil
        dispatch_subscriptions(channel, message, prefix_match: true)
      end

      # ── Helpers ────────────────────────────────────────────────────

      # Builds one per-domain stream subscriber with the shared config. The
      # caller owns subscribing channels, installing the provider / add
      # callback, starting it, and recording it in `@stream_subscribers`.
      private def build_stream_subscriber(domain : String) : Subscriber::Stream
        Subscriber::Stream.new(
          redis_url: @config.url,
          consumer_name: "#{@consumer_group_prefix}#{domain}",
          consumer_id: @service_id,
          prefix: "FACET:RESOURCE:",
          partitions: @config.partitions,
          config: Subscriber::Stream::Config.new(
            max_block_time: @config.stream.max_block_time,
            min_block_time: @config.stream.min_block_time,
            block_time_delta: @config.stream.block_time_delta,
            max_messages_count: @config.stream.max_messages_count
          ),
          group_start_id: @group_start_id
        ) do |channel, message|
          dispatch_message(channel, message)
        end
      end

      private def find_partition(key : String) : Int32
        # Simple hash using string bytes, modulo partitions.
        #
        # Uses the wrapping operators `&*` / `&+` so an intermediate product
        # that exceeds Int32 range wraps (two's complement) instead of raising
        # OverflowError. The subsequent `& 0x7fffffff` masks to the low 31 bits,
        # which are identical whether or not the intermediate overflowed — this
        # is exactly the deterministic partition we want. Without `&*`, ids like
        # `"identity.Person"` (16 bytes) raise on the very first overflow.
        hash = 0
        key.each_byte do |b|
          hash = (hash &* 31 &+ b) & 0x7fffffff
        end
        hash % @config.partitions
      end
    end
  end
end
