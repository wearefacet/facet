# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "log/spec"
require "json"

# Integration test for the Stream subscriber.
# Requires a running Redis server at redis://localhost:6379/9 (configurable via EVENT_REDIS_URL).

ENV["EVENT_REDIS_URL"] = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

# True when any shard lock on *channel* is held by *service_id* for the
# consumer group *group*. Lock key layout from `db/lua/lock_shards.lua`:
# `FACET:STREAM:SHARDLOCK:{stream}:{shard}:{consumer_group}` — the shard
# index is a plain segment, unlike the sharded stream keys (`{stream}$N`).
def stream_spec_shard_lock_held?(redis_url : String, channel : String, group : String, service_id : String) : Bool
  with_event_redis(redis_url) do |r|
    keys = Array(String).new
    r.keys("FACET:STREAM:SHARDLOCK:#{channel}:*:#{group}").each do |key|
      keys << key.as(String)
    end
    keys.any? { |key| r.get(key) == service_id }
  end
end

describe Facet::Event::Subscriber::Stream do
  redis_url = ENV["EVENT_REDIS_URL"]
  test_domain = "test-domain"
  test_channel = "FACET:RESOURCE:TestEvent"
  service_id = "test-service"

  before_each do
    # Flush the test database before each test
    with_event_redis(redis_url, &.flushdb)
  end

  describe "consumer group lifecycle" do
    it "creates consumer groups on start" do
      received = [] of Facet::Event::Message

      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: test_domain,
        consumer_id: service_id,
        partitions: 4,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.5,
          min_block_time: 0.01,
          block_time_delta: 0.5,
          max_messages_count: 10
        )
      ) do |_, message|
        received << message
      end

      subscriber.subscribe(test_channel)
      subscriber.start

      # Verify the group was created using XPENDING
      assert_eventually do
        exists = false
        with_event_redis(redis_url) do |r|
          info = r.xpending("#{test_channel}$0", test_domain)
          exists = info.is_a?(Array(::Redis::Value))
        end
        exists
      end

      subscriber.stop
    end
  end

  describe "message delivery" do
    it "delivers messages published to the stream" do
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: test_domain,
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.5,
          min_block_time: 0.05,
          block_time_delta: 0.5,
          max_messages_count: 10
        )
      ) do |_, message|
        mutex.synchronize { received << message }
      end

      subscriber.subscribe(test_channel)
      subscriber.start

      # Publish a message via raw XADD
      payload_raw = %({"account_id":"123"})
      packed = Facet::Event::Message.new(
        content: JSON.parse(payload_raw),
        id: "msg-1"
      ).pack

      with_event_redis(redis_url) do |r|
        r.xadd("#{test_channel}$0", "*", {"msg" => packed})
      end

      # Wait for delivery
      assert_eventually do
        mutex.synchronize { received.size >= 1 }
      end
      mutex.synchronize do
        if received.size > 0
          received[0].content["account_id"].should eq(::JSON::Any.new("123"))
        end
      end

      subscriber.stop
    end

    it "delivers messages with event headers" do
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: test_domain,
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.5,
          min_block_time: 0.05,
          block_time_delta: 0.5,
          max_messages_count: 10
        )
      ) do |_, message|
        mutex.synchronize { received << message }
      end

      subscriber.subscribe(test_channel)
      subscriber.start

      msg = Facet::Event::Message.new(
        content: JSON.parse(%({"name":"test"})),
        headers: {"event" => ::JSON::Any.new("created")},
        id: "msg-2"
      )
      packed = msg.pack

      with_event_redis(redis_url) do |r|
        r.xadd("#{test_channel}$0", "*", {"msg" => packed})
      end

      assert_eventually do
        mutex.synchronize { received.size >= 1 }
      end
      mutex.synchronize do
        if received.size > 0
          received[0].headers["event"]?.try(&.as_s).should eq("created")
        end
      end

      subscriber.stop
    end
  end

  describe "multi-domain support" do
    it "runs two consumer groups independently" do
      received_a = [] of Facet::Event::Message
      received_b = [] of Facet::Event::Message
      mutex_a = Mutex.new
      mutex_b = Mutex.new

      channel_a = "FACET:RESOURCE:DomainAEvent"
      channel_b = "FACET:RESOURCE:DomainBEvent"

      sub_a = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: "domain-a",
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.5, min_block_time: 0.05, block_time_delta: 0.5, max_messages_count: 10
        )
      ) do |_, message|
        mutex_a.synchronize { received_a << message }
      end

      sub_b = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: "domain-b",
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.5, min_block_time: 0.05, block_time_delta: 0.5, max_messages_count: 10
        )
      ) do |_, message|
        mutex_b.synchronize { received_b << message }
      end

      sub_a.subscribe(channel_a)
      sub_b.subscribe(channel_b)
      sub_a.start
      sub_b.start

      msg = Facet::Event::Message.new(content: JSON.parse(%({"data":"from-a"})))
      with_event_redis(redis_url) { |r| r.xadd("#{channel_a}$0", "*", {"msg" => msg.pack}) }

      msg2 = Facet::Event::Message.new(content: JSON.parse(%({"data":"from-b"})))
      with_event_redis(redis_url) { |r| r.xadd("#{channel_b}$0", "*", {"msg" => msg2.pack}) }

      assert_eventually do
        mutex_a.synchronize { received_a.size >= 1 }
      end
      assert_eventually do
        mutex_b.synchronize { received_b.size >= 1 }
      end

      mutex_a.synchronize do
        if received_a.size > 0
          received_a[0].content["data"].should eq(::JSON::Any.new("from-a"))
        end
      end

      mutex_b.synchronize do
        if received_b.size > 0
          received_b[0].content["data"].should eq(::JSON::Any.new("from-b"))
        end
      end

      sub_a.stop
      sub_b.stop
    end
  end

  # ── Redis outage resilience ──────────────────────────────────────
  # The Redis outage resilience contract (`doc/backend/event.md` →
  # Supervision and error backoff): one Redis blip must not kill the
  # consumer fibers, and the supervised fibers must restart (and report)
  # while Redis is unreachable.
  describe "redis outage resilience" do
    it "survives one blip without killing consumption" do
      proxy = RedisProxy.new(redis_url)
      proxy_url = proxy.start
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: proxy_url,
        consumer_name: "outage-blip",
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.2, min_block_time: 0.02, block_time_delta: 0.5, max_messages_count: 10
        )
      ) do |_, message|
        mutex.synchronize { received << message }
      end

      subscriber.subscribe(test_channel)
      subscriber.start

      begin
        # Batch 1 — delivered through the proxy.
        packed_one = Facet::Event::Message.new(content: JSON.parse(%({"batch":"one"})), id: "blip-1").pack
        with_event_redis(redis_url) { |r| r.xadd("#{test_channel}$0", "*", {"msg" => packed_one}) }
        assert_eventually(timeout: 5.0) { mutex.synchronize { received.size >= 1 } }

        # The blip: the proxy drops every live socket and refuses new ones.
        proxy.pause
        assert_eventually(timeout: 5.0) do
          Facet::Event::ConsumerHealth.snapshot.any? do |s|
            s[:name] == "outage-blip" && s[:consecutive_failures] > 0
          end
        end

        # Batch 2 — published directly against Redis while the proxy is down.
        packed_two = Facet::Event::Message.new(content: JSON.parse(%({"batch":"two"})), id: "blip-2").pack
        with_event_redis(redis_url) { |r| r.xadd("#{test_channel}$0", "*", {"msg" => packed_two}) }

        proxy.resume
        assert_eventually(timeout: 10.0) { mutex.synchronize { received.size >= 2 } }

        mutex.synchronize do
          received[0].content["batch"].should eq(::JSON::Any.new("one"))
          received[1].content["batch"].should eq(::JSON::Any.new("two"))
        end
      ensure
        subscriber.stop
        proxy.close
      end
    end

    it "restarts the supervised fibers while Redis is unreachable" do
      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: "redis://127.0.0.1:1/?initial_pool_size=0", # nothing listens — refused on demand
        consumer_name: "outage-liveness",
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.2, min_block_time: 0.02, block_time_delta: 0.5, max_messages_count: 10
        )
      ) do |_channel, _message|
      end

      subscriber.subscribe("FACET:RESOURCE:OutageProbe")
      subscriber.start

      begin
        assert_eventually(timeout: 2.0, interval: 0.05) do
          Facet::Event::ConsumerHealth.snapshot.any? do |s|
            s[:name] == "outage-liveness" && s[:restarts] > 0
          end
        end
      ensure
        subscriber.stop
      end
    end
  end

  describe "missing consumer group" do
    it "logs the dropped reads and resumes when the group returns" do
      received = [] of Facet::Event::Message
      mutex = Mutex.new

      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: test_domain,
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.2,
          min_block_time: 0.01,
          block_time_delta: 0.5,
          max_messages_count: 10
        )
      ) do |_, message|
        mutex.synchronize { received << message }
      end

      subscriber.subscribe(test_channel)
      subscriber.start

      # A dedicated memory backend captures the subscriber's log entries, so
      # the assertions can poll (`assert_eventually`) instead of sleeping a
      # fixed span: the warn lands within roughly two poll turns, each
      # bounded by max_block_time.
      backend = Log::MemoryBackend.new
      Log.builder.bind("facet.event.subscriber", :info, backend)
      begin
        # The group exists (created synchronously in start). Destroy it so
        # every XREADGROUP answers NOGROUP — the state a lost Redis
        # dataset or one failed group creation on a runtime-added channel
        # leaves behind.
        with_event_redis(redis_url) do |r|
          r.xgroup_destroy(test_channel, test_domain)
        end

        assert_eventually(timeout: 5.0) do
          backend.entries.any? { |e| e.severity.warn? && e.message =~ /NOGROUP/ }
        end

        # Bring the group back at the tail and publish — the loop must
        # still be polling, and the recovery must be visible.
        with_event_redis(redis_url) do |r|
          r.xgroup_create(test_channel, test_domain, id: "$", mkstream: true)
        end
        packed = Facet::Event::Message.new(
          content: JSON.parse(%({"batch":"nogroup"})),
          id: "ng-1"
        ).pack
        with_event_redis(redis_url) { |r| r.xadd("#{test_channel}$0", "*", {"msg" => packed}) }

        assert_eventually(timeout: 5.0) do
          mutex.synchronize { received.size >= 1 }
        end
        mutex.synchronize do
          received[0].content["batch"].should eq(::JSON::Any.new("nogroup"))
        end

        Log::EntriesChecker.new(backend.entries).check(:info, /recovered after \d+ dropped turn/)
      ensure
        Log.builder.unbind("facet.event.subscriber", :info, backend)
        subscriber.stop
      end
    end
  end

  describe "graceful stop" do
    it "releases its shard locks synchronously on stop" do
      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: test_domain,
        consumer_id: service_id,
        partitions: 2,
        config: Facet::Event::Subscriber::Stream::Config.new(
          max_block_time: 0.2, min_block_time: 0.02, block_time_delta: 0.5, max_messages_count: 10
        )
      ) do |_channel, _message|
      end

      subscriber.subscribe(test_channel, lock: true)
      subscriber.start

      # The run loop acquires the shard locks on its first turn.
      assert_eventually(timeout: 5.0) { stream_spec_shard_lock_held?(redis_url, test_channel, test_domain, service_id) }

      subscriber.stop

      # `stop` unlocks synchronously — no waiting out the 3200 s lock TTL
      # (`doc/backend/shutdown.md`), so a live peer
      # can acquire the shards right away.
      assert_eventually(timeout: 2.0) { !stream_spec_shard_lock_held?(redis_url, test_channel, test_domain, service_id) }
    end
  end

  # ── Multi-instance operation ────────────────────────────────────
  # Per-boot instance identity (`Facet::Service`, `doc/backend/event.md` →
  # Service identity): a live holder's shards are not stealable, a dead
  # holder's shards are, and an unlock never crosses instances. Shard locks
  # are per-turn leases — the run loop locks, reads, and unlocks each turn —
  # so the subscriber-level assertion samples the lock keys over a window
  # instead of checking one instant; the Lua-level specs pin the steal and
  # unlock semantics deterministically.
  describe "multi-instance operation" do
    lock_prefix = "FACET:STREAM:SHARDLOCK"
    lock_script = File.read(File.join(__DIR__, "..", "..", "..", "db", "lua", "lock_shards.lua"))
    unlock_script = File.read(File.join(__DIR__, "..", "..", "..", "db", "lua", "unlock_shards.lua"))

    fast_config = Facet::Event::Subscriber::Stream::Config.new(
      max_block_time: 0.2, min_block_time: 0.02, block_time_delta: 0.5, max_messages_count: 10
    )

    it "does not steal shard locks while the holder's liveness key exists (Lua level)" do
      channel = "FACET:RESOURCE:StealPathEvent"
      group = "steal-path"

      with_event_redis(redis_url) do |r|
        sha = r.script_load(lock_script)

        # Holder A locks both shards with its liveness key present — the
        # exact key `liveness_run` writes and `lock_shards.lua` reads.
        r.set("#{lock_prefix}:SERVICE_LIVENESS:steal-a", "1", ex: 30)
        result = r.evalsha(sha, keys: [lock_prefix], args: [group, "steal-a", "2", channel]).as(Array)
        result[1].as(Int64).should eq(3) # both shards

        # B runs while A is alive: no steal, no shards.
        result = r.evalsha(sha, keys: [lock_prefix], args: [group, "steal-b", "2", channel]).as(Array)
        result[1].as(Int64).should eq(0)

        # A dies: its liveness key is gone, B steals every shard.
        r.del("#{lock_prefix}:SERVICE_LIVENESS:steal-a")
        result = r.evalsha(sha, keys: [lock_prefix], args: [group, "steal-b", "2", channel]).as(Array)
        result[1].as(Int64).should eq(3)
        r.get("#{lock_prefix}:#{channel}:0:#{group}").should eq("steal-b")
        r.get("#{lock_prefix}:#{channel}:1:#{group}").should eq("steal-b")
      end
    end

    it "releases only its own shard locks on unlock (Lua level)" do
      channel = "FACET:RESOURCE:UnlockIsoEvent"
      group = "unlock-iso"

      with_event_redis(redis_url) do |r|
        lock_sha = r.script_load(lock_script)
        unlock_sha = r.script_load(unlock_script)

        # A locks both shards, then vacates shard 1 only (bitmask 0b10).
        r.set("#{lock_prefix}:SERVICE_LIVENESS:iso-a", "1", ex: 30)
        result = r.evalsha(lock_sha, keys: [lock_prefix], args: [group, "iso-a", "2", channel]).as(Array)
        result[1].as(Int64).should eq(3)
        r.evalsha(unlock_sha, keys: [lock_prefix], args: [group, "iso-a", "2", channel, "2"])

        # B acquires the free shard 1; A still holds shard 0 (alive).
        result = r.evalsha(lock_sha, keys: [lock_prefix], args: [group, "iso-b", "2", channel]).as(Array)
        result[1].as(Int64).should eq(2)
        r.get("#{lock_prefix}:#{channel}:0:#{group}").should eq("iso-a")
        r.get("#{lock_prefix}:#{channel}:1:#{group}").should eq("iso-b")

        # B releases everything — A's lock survives the shared prefix.
        r.evalsha(unlock_sha, keys: [lock_prefix], args: [group, "iso-b", "2", channel, "4294967295"])
        r.get("#{lock_prefix}:#{channel}:0:#{group}").should eq("iso-a")
        r.get("#{lock_prefix}:#{channel}:1:#{group}").should be_nil
      end
    end

    it "writes the liveness key the lock script reads" do
      subscriber = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: "liveness-key",
        consumer_id: "live-liveness",
        partitions: 2,
        config: fast_config
      ) do |_channel, _message|
      end

      subscriber.subscribe("FACET:RESOURCE:LivenessKeyEvent")
      subscriber.start

      begin
        assert_eventually do
          with_event_redis(redis_url) do |r|
            r.get("#{lock_prefix}:SERVICE_LIVENESS:live-liveness") == "1"
          end
        end
        # The hash-tagged form must stay absent — the lock script cannot
        # see it, so a live holder's shards would look stealable.
        with_event_redis(redis_url) do |r|
          r.get("{#{lock_prefix}}:SERVICE_LIVENESS:live-liveness").should be_nil
        end
      ensure
        subscriber.stop
      end
    end

    it "keeps shard ownership disjoint across two live instances" do
      channel = "FACET:RESOURCE:MiOwnershipEvent"
      group = "mi-ownership"
      id_a = "mi-owner-a"
      id_b = "mi-owner-b"

      sub_a = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: group,
        consumer_id: id_a,
        partitions: 2,
        config: fast_config
      ) do |_channel, _message|
      end
      sub_b = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: group,
        consumer_id: id_b,
        partitions: 2,
        config: fast_config
      ) do |_channel, _message|
      end

      sub_a.subscribe(channel)
      sub_b.subscribe(channel)
      sub_a.start
      sub_b.start

      begin
        # Sample the lock keys over a window: every observed holder must be
        # one of the two ids, both ids must get turns, and both shards must
        # be covered between them.
        observed = Set(String).new
        shards_covered = Set(Int32).new
        assert_eventually(timeout: 10.0) do
          with_event_redis(redis_url) do |r|
            2.times do |i|
              value = r.get("#{lock_prefix}:#{channel}:#{i}:#{group}")
              if value.is_a?(String)
                observed << value
                shards_covered << i
              end
            end
          end
          observed.all? { |v| v == id_a || v == id_b } &&
            observed.includes?(id_a) && observed.includes?(id_b) &&
            shards_covered.size == 2
        end
      ensure
        sub_a.stop
        sub_b.stop
      end
    end

    it "delivers each message exactly once across two instances" do
      channel = "FACET:RESOURCE:MiOnceEvent"
      group = "mi-once"
      mutex = Mutex.new
      deliveries = Array(Tuple(String, String)).new # {stream, entry id}

      sub_a = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: group,
        consumer_id: "mi-once-a",
        partitions: 2,
        config: fast_config
      ) do |ch, message|
        mutex.synchronize { deliveries << {ch, message.id} }
      end
      sub_b = Facet::Event::Subscriber::Stream.new(
        redis_url: redis_url,
        consumer_name: group,
        consumer_id: "mi-once-b",
        partitions: 2,
        config: fast_config
      ) do |ch, message|
        mutex.synchronize { deliveries << {ch, message.id} }
      end

      # Group creation is synchronous in start, so both group tails sit at
      # `$` before the first XADD — every message below is deliverable.
      sub_a.subscribe(channel)
      sub_b.subscribe(channel)
      sub_a.start
      sub_b.start

      begin
        packed = (0...8).map do |n|
          Facet::Event::Message.new(content: JSON.parse(%({"n":#{n}})), id: "mi-#{n}").pack
        end
        with_event_redis(redis_url) do |r|
          8.times { |n| r.xadd("#{channel}$#{n % 2}", "*", {"msg" => packed[n]}) }
        end

        assert_eventually(timeout: 5.0) do
          mutex.synchronize { deliveries.size >= 8 }
        end
        mutex.synchronize do
          deliveries.size.should eq(8)
          # No stream entry delivered twice — the (stream, entry id) pairs
          # are unique even though entry ids can repeat across shard keys.
          deliveries.uniq.size.should eq(8)
        end
      ensure
        sub_a.stop
        sub_b.stop
      end
    end
  end
end
