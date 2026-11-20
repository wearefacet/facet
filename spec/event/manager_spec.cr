# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"

# Uses a dedicated Redis database (9) to avoid colliding with development data.
TEST_EVENT_REDIS_URL = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

# Custom exception used to exit a Redis subscribe block cleanly after
# receiving the expected message.
class RedisSubStop < Exception
end

describe Facet::Event::Manager do
  redis_url = TEST_EVENT_REDIS_URL
  service_id = "manager-test-svc"

  before_each do
    with_event_redis(redis_url, &.flushdb)
  end

  describe "subscription registration" do
    it "registers subscriptions before start" do
      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      called = false
      manager.subscribe_resource_event(domain: "test", resource_type: "User", event: "created") do |_msg|
        called = true
      end

      manager.subscriptions.size.should eq(1)
      manager.subscriptions[0].domain.should eq("test")
    end

    it "raises when subscribing after start" do
      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      manager.start
      expect_raises(Exception, "cannot subscribe after start") do
        manager.subscribe_resource_event(domain: "test", resource_type: "User", event: "created") { }
      end
      manager.stop
    end
  end

  describe "publish and subscribe integration" do
    it "publishes a resource event and delivers it via stream" do
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      manager.subscribe_resource_event(domain: "test", resource_type: "Order", event: "placed") do |msg|
        mutex.synchronize { received << msg }
      end

      manager.start

      payload = {"order_id" => ::JSON::Any.new("ord-1"), "total" => ::JSON::Any.new(100_i64)}
      manager.publish_resource_event(
        domain: "test",
        resource_type: "Order",
        resource_id: "ord-1",
        event: "placed",
        payload: payload
      )

      assert_eventually do
        mutex.synchronize { received.size >= 1 }
      end
      mutex.synchronize do
        if received.size > 0
          received[0].content["order_id"].should eq(::JSON::Any.new("ord-1"))
        end
      end

      manager.stop
    end

    it "filters events by event type" do
      received_placed = [] of Facet::Event::Message
      received_shipped = [] of Facet::Event::Message
      mutex_p = Mutex.new
      mutex_s = Mutex.new

      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      manager.subscribe_resource_event(domain: "test", resource_type: "Order", event: "placed") do |msg|
        mutex_p.synchronize { received_placed << msg }
      end
      manager.subscribe_resource_event(domain: "test", resource_type: "Order", event: "shipped") do |msg|
        mutex_s.synchronize { received_shipped << msg }
      end

      manager.start

      payload = {"order_id" => ::JSON::Any.new("ord-1")}
      manager.publish_resource_event(
        domain: "test", resource_type: "Order", resource_id: "ord-1",
        event: "placed", payload: payload
      )

      assert_eventually do
        mutex_p.synchronize { received_placed.size >= 1 }
      end
      mutex_s.synchronize { received_shipped.size.should eq(0) }

      manager.stop
    end
  end

  describe "multi-domain" do
    it "creates separate consumer groups for each domain" do
      received_hr = [] of Facet::Event::Message
      received_fin = [] of Facet::Event::Message
      mutex_hr = Mutex.new
      mutex_fin = Mutex.new

      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      manager.subscribe_resource_event(domain: "hr", resource_type: "Employee", event: "hired") do |msg|
        mutex_hr.synchronize { received_hr << msg }
      end
      manager.subscribe_resource_event(domain: "finance", resource_type: "Invoice", event: "paid") do |msg|
        mutex_fin.synchronize { received_fin << msg }
      end

      manager.start

      # Verify two consumer groups exist
      assert_eventually do
        exists = false
        with_event_redis(redis_url) do |r|
          info = r.xpending("FACET:RESOURCE:Employee$0", "hr")
          if info.is_a?(Array(::Redis::Value))
            info = r.xpending("FACET:RESOURCE:Invoice$0", "finance")
            exists = info.is_a?(Array(::Redis::Value))
          end
        end
        exists
      end

      manager.publish_resource_event(
        domain: "hr", resource_type: "Employee", resource_id: "e1",
        event: "hired", payload: {"name" => ::JSON::Any.new("Alice")}
      )
      manager.publish_resource_event(
        domain: "finance", resource_type: "Invoice", resource_id: "inv-1",
        event: "paid", payload: {"amount" => ::JSON::Any.new(500_i64)}
      )

      assert_eventually do
        mutex_hr.synchronize { received_hr.size >= 1 }
      end
      assert_eventually do
        mutex_fin.synchronize { received_fin.size >= 1 }
      end

      manager.stop
    end
  end

  describe "fanout publication" do
    it "publishes a message on the fanout channel via PUBLISH" do
      received = Channel(String).new

      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      fanout_channel = "fanout:test.Order:ord-1"

      # Spawn a fiber that subscribes to the fanout channel and sends messages
      # back via a Channel. It will stop after receiving one message.
      spawn do
        sub_client = ::Redis::Client.new(URI.parse(redis_url))
        sub_client.subscribe(fanout_channel) do |event|
          event.on_message do |_channel, message|
            received.send(message)
            # Stop subscribing by raising to exit the subscribe block
            raise RedisSubStop.new
          end
        end
      rescue RedisSubStop
        # Expected exit after receiving the message
      end

      # Pub/Sub is fire-and-forget; wait until Redis reports the subscriber as
      # connected before publishing, otherwise the message is lost.
      assert_eventually do
        active = false
        with_event_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", fanout_channel})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      payload = {"order_id" => ::JSON::Any.new("ord-1")}
      manager.publish_resource_event(
        domain: "test",
        resource_type: "test:Order",
        resource_id: "ord-1",
        event: "placed",
        payload: payload
      )

      packed = received.receive
      unpacked = Facet::Event::Message.unpack(packed)
      unpacked.content.should eq(::JSON::Any.new(payload))
      unpacked.headers["event"]?.try(&.as_s).should eq("placed")

      manager.stop
    end
  end

  describe "metrics counters" do
    before_each do
      Facet::Metrics.reset
    end

    it "counts published resource events and channel publishes" do
      manager = Facet::Event::Manager.new(
        config: Facet::Event::Config.new(url: redis_url, partitions: 2),
        service_id: service_id
      )

      manager.publish_resource_event(
        domain: "test", resource_type: "Order", resource_id: "ord-1",
        event: "placed", payload: {"order_id" => ::JSON::Any.new("ord-1")}
      )
      manager.publish("facet:spec:channel", ::JSON::Any.new({"n" => ::JSON::Any.new(1)}))

      Facet::Metrics.value("facet_events_published_total").should eq(2.0)
    end
  end
end
