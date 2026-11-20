# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"

# Integration test for the Fanout Pub/Sub subscriber.
# Requires a running Redis server at redis://localhost:6379/9 (configurable via EVENT_REDIS_URL).

ENV["EVENT_REDIS_URL"] = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

# Receives a value from `ch` or fails the spec after `timeout` seconds.
# Prevents a missed Pub/Sub message from hanging the whole suite.
private def receive_or_fail(ch : Channel(T), timeout : Float64 = 2.0, & : T -> Nil) : T forall T
  select
  when v = ch.receive
    yield v
    v
  when timeout(timeout.seconds)
    fail "did not receive on channel within #{timeout}s"
  end
end

# Verifies that no value arrives on `ch` within `timeout` seconds.
private def assert_no_receive(ch : Channel(T), timeout : Float64 = 0.5) : Nil forall T
  select
  when _ = ch.receive
    fail "received unexpected message on channel"
  when timeout(timeout.seconds)
    # expected — no message should arrive
  end
end

# Redis-side subscriber count for *channel*, as seen by the real server.
private def numsub_gt_zero?(redis_url : String, channel : String) : Bool
  with_event_redis(redis_url) do |r|
    result = r.run({"pubsub", "numsub", channel})
    result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
  end
end

describe Facet::Event::Subscriber::Fanout do
  redis_url = ENV["EVENT_REDIS_URL"]
  service_id = "fanout-test-#{Random.new.hex(4)}"
  sentinel = "fanout:_keepalive:#{service_id}"

  before_each do
    with_event_redis(redis_url, &.flushdb)
  end

  describe "startup and sentinel" do
    it "subscribes to the sentinel channel on start" do
      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |_channel, _message|
        # no-op
      end

      subscriber.start

      # Verify the sentinel subscription is active by inspecting PUBSUB NUMSUB
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", sentinel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      subscriber.stop
    end

    it "delivers a message published to a subscribed channel" do
      received = Channel({String, Facet::Event::Message}).new
      channel = "fanout:test.Item:item-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |ch, msg|
        received.send({ch, msg})
      end

      subscriber.subscribe(channel)
      subscriber.start

      # Wait for subscription to be active
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      # Publish a message via raw Redis PUBLISH
      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"name" => ::JSON::Any.new("test")}),
        headers: {"event" => ::JSON::Any.new("created")}
      ).pack

      with_event_redis(redis_url) do |r|
        r.publish(channel, payload)
      end

      receive_or_fail(received) do |ch, msg|
        ch.should eq(channel)
        msg.content["name"].should eq(::JSON::Any.new("test"))
        msg.headers["event"]?.try(&.as_s).should eq("created")
      end

      subscriber.stop
    end
  end

  describe "dynamic subscription" do
    it "subscribes to a channel after start" do
      received = Channel({String, Facet::Event::Message}).new
      channel = "fanout:test.Order:ord-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |ch, msg|
        received.send({ch, msg})
      end

      subscriber.start

      # Subscribe after start
      subscriber.subscribe(channel)

      # Wait for the subscription to be confirmed
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"id" => ::JSON::Any.new("ord-1")})
      ).pack

      with_event_redis(redis_url) do |r|
        r.publish(channel, payload)
      end

      receive_or_fail(received) do |ch, msg|
        ch.should eq(channel)
        msg.content["id"].should eq(::JSON::Any.new("ord-1"))
      end

      subscriber.stop
    end

    it "unsubscribes from a channel after start and stops receiving" do
      received_a = Channel({String, Facet::Event::Message}).new
      channel = "fanout:test.Order:ord-2"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |ch, msg|
        received_a.send({ch, msg})
      end

      subscriber.subscribe(channel)
      subscriber.start

      # Wait for subscription to be active
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      # Publish and verify delivery
      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"msg" => ::JSON::Any.new("before-unsub")})
      ).pack

      with_event_redis(redis_url) do |r|
        r.publish(channel, payload)
      end

      receive_or_fail(received_a) do |_ch, msg|
        msg.content["msg"].should eq(::JSON::Any.new("before-unsub"))
      end

      # Unsubscribe
      subscriber.unsubscribe(channel)

      # Wait until Redis reports zero subscribers; the follow-up publish then
      # provably cannot be delivered.
      assert_eventually do
        gone = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          gone = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) == 0
        end
        gone
      end

      # Publish again — should not be delivered
      payload2 = Facet::Event::Message.new(
        content: ::JSON::Any.new({"msg" => ::JSON::Any.new("after-unsub")})
      ).pack

      with_event_redis(redis_url) do |r|
        r.publish(channel, payload2)
      end

      # Verify no message arrives within a short window
      assert_no_receive(received_a, timeout: 0.5)

      subscriber.stop
    end
  end

  describe "sentinel persistence" do
    it "keeps the sentinel subscribed after unsubscribing all non-sentinel channels" do
      channel = "fanout:test.Session:sess-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |_ch, _msg|
        # no-op
      end

      subscriber.subscribe(channel)
      subscriber.start

      # Wait for the channel subscription to be confirmed
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      # Unsubscribe the only non-sentinel channel, then wait until Redis
      # reports zero subscribers for it.
      subscriber.unsubscribe(channel)
      assert_eventually do
        gone = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          gone = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) == 0
        end
        gone
      end

      # Sentinel should still be active
      with_event_redis(redis_url) do |r|
        result = r.run({"pubsub", "numsub", sentinel})
        result.should be_a(Array(::Redis::Value))
        arr = result.as(Array(::Redis::Value))
        arr.size.should be >= 2
        arr[1].as(Int64).should be > 0
      end

      subscriber.stop
    end
  end

  describe "pre-start subscriptions" do
    it "subscribes to channels registered before start" do
      received = Channel({String, Facet::Event::Message}).new
      channel = "fanout:test.Pre:pre-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |ch, msg|
        received.send({ch, msg})
      end

      # Subscribe before start
      subscriber.subscribe(channel)
      subscriber.start

      # Wait for the subscription to be active in Redis before publishing,
      # otherwise the PUBLISH can race ahead of the SUBSCRIBE and the message
      # is lost (Pub/Sub is fire-and-forget).
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      # Publish and verify delivery
      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"pre" => ::JSON::Any.new(true)})
      ).pack

      with_event_redis(redis_url) do |r|
        r.publish(channel, payload)
      end

      receive_or_fail(received) do |ch, msg|
        ch.should eq(channel)
        msg.content["pre"].should eq(::JSON::Any.new(true))
      end

      subscriber.stop
    end
  end

  describe "stop" do
    it "stops cleanly" do
      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |_ch, _msg|
        # no-op
      end

      subscriber.subscribe("fanout:test.A:a-1")
      subscriber.start

      assert_eventually { subscriber.started? }
      subscriber.started?.should be_true

      subscriber.stop
      subscriber.started?.should be_false
    end
  end

  describe "concurrent subscribe/unsubscribe" do
    it "handles rapid subscribe/unsubscribe from multiple fibers" do
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: redis_url,
        service_id: service_id
      ) do |_ch, msg|
        mutex.synchronize { received << msg }
      end

      subscriber.start

      channels = (1..10).map { |i| "fanout:test.Concurrent:item-#{i}" }

      # Rapidly subscribe to all channels from multiple fibers
      barrier = Channel(Nil).new(channels.size)
      channels.each do |ch|
        spawn do
          subscriber.subscribe(ch)
          barrier.send(nil)
        end
      end
      channels.size.times { barrier.receive }

      # Wait until Redis confirms all 10 subscriptions before publishing; a
      # PUBLISH that races a not-yet-processed SUBSCRIBE is permanently lost.
      assert_eventually do
        all_active = false
        with_event_redis(redis_url) do |r|
          result = r.run(["pubsub", "numsub"] + channels)
          if result.is_a?(Array(::Redis::Value)) && result.size == channels.size * 2
            all_active = result.each_slice(2).all? { |pair| pair[1].as(Int64) > 0 }
          end
        end
        all_active
      end

      # Publish to each channel
      channels.each_with_index do |ch, i|
        payload = Facet::Event::Message.new(
          content: ::JSON::Any.new({"idx" => ::JSON::Any.new(i.to_i64)})
        ).pack

        with_event_redis(redis_url) do |r|
          r.publish(ch, payload)
        end
      end

      assert_eventually do
        mutex.synchronize { received.size >= 10 }
      end

      subscriber.stop
    end
  end

  # The subscriber connects through a TCP proxy so the spec can drop the
  # socket without stopping the shared Redis server (same harness as the
  # stream-outage regression specs).
  describe "reconnect" do
    it "re-establishes channel subscriptions after a connection loss" do
      proxy = RedisProxy.new(redis_url)
      proxied_url = proxy.start
      received = Channel({String, Facet::Event::Message}).new
      channel = "fanout:test.Reconnect:r-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: proxied_url,
        service_id: service_id
      ) do |ch, msg|
        received.send({ch, msg})
      end

      subscriber.subscribe(channel)
      subscriber.start

      # The subscription lands on the real server through the proxy.
      assert_eventually { numsub_gt_zero?(redis_url, channel) }

      proxy.pause
      # The server drops the subscription when the socket dies.
      assert_eventually(timeout: 5.0) { !numsub_gt_zero?(redis_url, channel) }

      proxy.resume
      # The reconnect loop (1 s backoff) re-subscribes the tracked set.
      assert_eventually(timeout: 5.0) { numsub_gt_zero?(redis_url, channel) }

      # Delivery works again end to end.
      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"after" => ::JSON::Any.new("reconnect")})
      ).pack
      with_event_redis(redis_url) { |r| r.publish(channel, payload) }

      receive_or_fail(received) do |ch, msg|
        ch.should eq(channel)
        msg.content["after"].should eq(::JSON::Any.new("reconnect"))
      end

      subscriber.stop
      proxy.close
    end

    it "keeps the command drain alive when a command fails during an outage" do
      proxy = RedisProxy.new(redis_url)
      proxied_url = proxy.start
      received = Channel({String, Facet::Event::Message}).new
      channel_a = "fanout:test.Drain:a-1"
      channel_b = "fanout:test.Drain:b-1"
      channel_c = "fanout:test.Drain:c-1"

      subscriber = Facet::Event::Subscriber::Fanout.new(
        redis_url: proxied_url,
        service_id: service_id
      ) do |ch, msg|
        received.send({ch, msg})
      end

      subscriber.subscribe(channel_a)
      subscriber.start
      assert_eventually { numsub_gt_zero?(redis_url, channel_a) }

      # Outage: the command for channel_b fails against the dead connection.
      # The drain must survive it.
      proxy.pause
      assert_eventually(timeout: 5.0) { !numsub_gt_zero?(redis_url, channel_a) }
      subscriber.subscribe(channel_b)

      proxy.resume
      # Reconnect re-subscribes the tracked set (a and b).
      assert_eventually(timeout: 5.0) { numsub_gt_zero?(redis_url, channel_a) }
      assert_eventually(timeout: 5.0) { numsub_gt_zero?(redis_url, channel_b) }

      # A command issued after recovery is the drain's own proof of life: the
      # resubscribe pass cannot cover channel_c — only a living drain can.
      subscriber.subscribe(channel_c)
      assert_eventually(timeout: 5.0) { numsub_gt_zero?(redis_url, channel_c) }

      payload = Facet::Event::Message.new(
        content: ::JSON::Any.new({"drain" => ::JSON::Any.new("alive")})
      ).pack
      with_event_redis(redis_url) { |r| r.publish(channel_c, payload) }
      receive_or_fail(received) do |ch, msg|
        ch.should eq(channel_c)
        msg.content["drain"].should eq(::JSON::Any.new("alive"))
      end

      subscriber.stop
      proxy.close
    end
  end
end
