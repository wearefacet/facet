# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../../src/event/manager"

# A drop-in `Event::Manager` substitute that records subscription
# registrations and channel-provider installs without touching Redis.
# Exposes the same surface `Hooks::Manager` and `Webhook::Manager` call
# during `start`: `subscribe_resource_stream`, `set_channel_provider`,
# `set_channel_add_callback`, `ensure_stream_subscriber`, `start`, `stop`,
# `started?`.
#
# Shared by `spec/hooks/manager_spec.cr` and `spec/webhook/manager_spec.cr`.
class StubEventManager < Facet::Event::Manager
  # Minimal model of one provider-driven stream subscriber: the surface
  # `Event::Manager#ensure_stream_subscriber` wires before the polling
  # fiber starts. Specs assert subscriber existence and consult the
  # provider / add callback directly — no Redis, no fibers.
  class StubStreamSubscriber
    getter channels : Array(String)
    property provider : Proc(Array(String))?
    property on_channels_added : Proc(Array(String), Nil)?

    def initialize(channels : Array(String))
      @channels = channels.dup
    end

    def subscribe(channel : String) : Nil
      @channels << channel unless @channels.includes?(channel)
    end
  end

  getter subscriptions : Array(Facet::Event::Manager::Subscription)
  getter channel_providers : Hash(String, Proc(Array(String)))
  getter channel_add_callbacks : Hash(String, Proc(Array(String), Nil))
  getter stub_subscribers : Hash(String, StubStreamSubscriber)
  property? started : Bool = false

  def initialize
    # Bypass the parent initializer (which opens a real Redis client).
    # Only the fields the managers read are populated; `@redis` is set to
    # a lazy client against a dummy URL — crystal-redis does not connect
    # until a command is sent, and the stub never sends one.
    @config = Facet::Event::Config.new
    @service_id = "stub"
    @consumer_group_prefix = "cg:stub:"
    @group_start_id = "$"
    @subscriptions = [] of Facet::Event::Manager::Subscription
    @stream_subscribers = {} of String => Facet::Event::Subscriber::Stream
    @started = false
    @mutex = Mutex.new
    @redis = ::Redis::Client.new(URI.parse("redis://localhost:6379/0"))
    @channel_providers = {} of String => Proc(Array(String))
    @channel_add_callbacks = {} of String => Proc(Array(String), Nil)
    @stub_subscribers = {} of String => StubStreamSubscriber
  end

  def subscribe_resource_stream(
    domain : String,
    resource_type : String,
    &handler : Facet::Event::Message ->
  ) : Nil
    channel = "FACET:RESOURCE:#{resource_type}"
    @subscriptions << Facet::Event::Manager::Subscription.new(domain, channel, handler)
  end

  def set_channel_provider(domain : String, provider : Proc(Array(String))) : Nil
    @channel_providers[domain] = provider
    @stub_subscribers[domain]?.try(&.provider=(provider))
  end

  def set_channel_add_callback(domain : String, callback : Proc(Array(String), Nil)) : Nil
    @channel_add_callbacks[domain] = callback
    @stub_subscribers[domain]?.try(&.on_channels_added=(callback))
  end

  # Mirrors the real manager: creates the subscriber for `domain` when it
  # does not exist, with the channels subscribed and the provider + add
  # callback installed before `start`; a no-op when it does. The real
  # implementation starts Redis polling fibers — the stub only records.
  def ensure_stream_subscriber(
    domain : String,
    channels : Array(String),
    provider : Proc(Array(String)),
    on_channels_added : Proc(Array(String), Nil),
  ) : Nil
    return if @stub_subscribers[domain]?

    subscriber = StubStreamSubscriber.new(channels)
    channels.each { |ch| subscriber.subscribe(ch) }
    subscriber.provider = provider
    subscriber.on_channels_added = on_channels_added
    @stub_subscribers[domain] = subscriber

    # The provider and add callback are live on a real subscriber from
    # this point — record them for the hash-based assertions too.
    @channel_providers[domain] = provider
    @channel_add_callbacks[domain] = on_channels_added
  end

  def start : Nil
    @mutex.synchronize { @started = true }
  end

  def stop : Nil
    @mutex.synchronize { @started = false }
  end

  def started? : Bool
    @started
  end
end
