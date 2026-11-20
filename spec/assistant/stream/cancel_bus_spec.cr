# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "../../../src/assistant/stream/cancel_bus"

# Concurrency-safe counter for unique turn tokens within a single process.
class Unique
  @@i = 0
  @@mutex = Mutex.new

  def self.next : String
    @@mutex.synchronize { @@i &+= 1 }
    @@i.to_s
  end
end

# Uses a dedicated Redis database (9) to avoid colliding with development data
# or with the event subsystem's Redis usage. Matches the pattern in
# spec/event/manager_spec.cr.
TEST_CANCEL_REDIS_URL = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

private def with_cancel_redis(url : String, & : ::Redis::Client ->)
  client = ::Redis::Client.new(URI.parse(url))
  begin
    yield client
  ensure
    client.close
  end
end

describe Facet::Assistant::Stream::CancelBus do
  redis_url = TEST_CANCEL_REDIS_URL

  before_each do
    with_cancel_redis(redis_url, &.flushdb)
  end

  describe ".publish / .channel / .cancel_key" do
    it "builds channel and key names from the turn token" do
      Facet::Assistant::Stream::CancelBus.channel("01ABC").should eq("assistant:cancel:01ABC")
      Facet::Assistant::Stream::CancelBus.cancel_key("01ABC").should eq("assistant:cancel:01ABC")
    end

    it "sets the cancel key with a TTL on publish" do
      Facet::Assistant::Stream::CancelBus.publish("tok-ttl", redis_url, ttl_seconds: 10)
      with_cancel_redis(redis_url) do |r|
        r.get("assistant:cancel:tok-ttl").should eq("1")
      end
    end
  end

  describe ".subscribe" do
    it "receives the cancel via live Pub/Sub when subscribed before publish" do
      received = Channel(Bool).new
      turn_token = "tok-live-#{Unique.next}"

      handle = Facet::Assistant::Stream::CancelBus.subscribe(turn_token, redis_url) do
        received.send(true)
      end

      # Pub/Sub is fire-and-forget; wait until Redis confirms the subscription
      # before publishing, otherwise the message is lost.
      assert_eventually do
        active = false
        with_cancel_redis(redis_url) do |r|
          result = r.run({"pubsub", "numsub", Facet::Assistant::Stream::CancelBus.channel(turn_token)})
          active = result.is_a?(Array(::Redis::Value)) && result.size >= 2 && result[1].as(Int64) > 0
        end
        active
      end

      Facet::Assistant::Stream::CancelBus.publish(turn_token, redis_url, ttl_seconds: 10)

      received.receive.should be_true
      handle.close
    end

    it "catches a cancel that raced the subscription via the pre-loop GET" do
      received = Channel(Bool).new
      turn_token = "tok-race-#{Unique.next}"

      # Publish BEFORE subscribing. The SET key is now in Redis.
      Facet::Assistant::Stream::CancelBus.publish(turn_token, redis_url, ttl_seconds: 10)

      handle = Facet::Assistant::Stream::CancelBus.subscribe(turn_token, redis_url) do
        received.send(true)
      end

      received.receive.should be_true
      handle.close
    end

    it "arms the publish TTL on the cancel key" do
      ttl = 10
      turn_token = "tok-exp-#{Unique.next}"
      Facet::Assistant::Stream::CancelBus.publish(turn_token, redis_url, ttl_seconds: ttl)

      # The expiry is armed: the key carries its full TTL. The sweep itself
      # is Redis's contract — deleting the key stands in for it.
      with_cancel_redis(redis_url) do |r|
        r.ttl("assistant:cancel:#{turn_token}").should eq(ttl)
        r.del("assistant:cancel:#{turn_token}")
      end

      with_cancel_redis(redis_url) do |r|
        r.get("assistant:cancel:#{turn_token}").should be_nil
      end
    end

    it "closing the handle is idempotent and unblocks the subscriber" do
      turn_token = "tok-close-#{Unique.next}"
      handle = Facet::Assistant::Stream::CancelBus.subscribe(turn_token, redis_url) { }
      handle.close
      handle.close # should not raise
    end
  end
end
