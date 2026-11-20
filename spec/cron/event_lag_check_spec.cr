# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "redis"
require "../../src/cron/event_lag_check"
require "../support/redis_helper"

# `Cron::EventLagCheck` — the read-only consumer-lag probe that warns
# before a slow consumer group reaches the stream trim point.
#
# Drives `scan` against a real Redis (the same dedicated database the
# event specs use — `EVENT_REDIS_URL`, default db 9) so the pass sees the
# real `KEYS` / `XINFO GROUPS` reply shapes:
#
# - threshold warn — a group left behind by newer entries;
# - below-threshold silence;
# - a key that vanishes (a non-stream key makes XINFO GROUPS error, the
#   same rescue a trimmed-away key takes);
# - a stream with no consumer groups.
TEST_LAG_REDIS_URL = ENV.fetch("EVENT_REDIS_URL", "redis://localhost:6379/9")

# Creates a sharded stream key with one consumer group left at the
# stream head, then appends `lag` entries — the group's reported lag.
private def seed_lagging_group(redis, key, group, lag)
  redis.xgroup_create(key, group, id: "0", mkstream: true)
  lag.times { redis.xadd(key, "*", {"msg" => "x"}) }
end

module Facet
  describe Cron::EventLagCheck do
    before_each do
      with_event_redis(TEST_LAG_REDIS_URL, &.flushdb)
      Cron::EventLagCheck.reset_gauge
    end

    it "warns per group over the threshold and records the pass max lag" do
      with_event_redis(TEST_LAG_REDIS_URL) do |redis|
        seed_lagging_group(redis, "FACET:RESOURCE:sales:Invoice$0", "cg:webhooks:core", 3)
        seed_lagging_group(redis, "FACET:RESOURCE:sales:Invoice$1", "cg:repl:sales", 1)
        # An unrelated key outside the scan prefix — never visited.
        redis.set("OTHER:key", "x")

        warns = Cron::EventLagCheck.scan(redis, warn_entries: 2_i64, maxlen: 1_000_000_i64)

        # Only the group over the threshold warns — the second stream's
        # group (lag 1) stays silent, and the non-prefixed key is not
        # scanned.
        warns.size.should eq(1)
        warn = warns.first
        warn.stream.should eq("FACET:RESOURCE:sales:Invoice$0")
        warn.group.should eq("cg:webhooks:core")
        warn.lag.should eq(3)
        warn.warn_entries.should eq(2)
        warn.maxlen.should eq(1_000_000)

        # The gauge holds the pass's max — the trim-loss precursor exposed
        # on /Healthcheck.
        Cron::EventLagCheck.max_lag.should eq(3)
      end
    end

    it "stays silent below the threshold but still records the gauge" do
      with_event_redis(TEST_LAG_REDIS_URL) do |redis|
        seed_lagging_group(redis, "FACET:RESOURCE:sales:Invoice$0", "cg:hooks:sales", 4)

        warns = Cron::EventLagCheck.scan(redis, warn_entries: 100_i64, maxlen: 1_000_000_i64)

        warns.should be_empty
        Cron::EventLagCheck.max_lag.should eq(4)
      end
    end

    it "skips a key that XINFO GROUPS errors on (vanished between KEYS and the read)" do
      with_event_redis(TEST_LAG_REDIS_URL) do |redis|
        seed_lagging_group(redis, "FACET:RESOURCE:sales:Invoice$0", "cg:webhooks:core", 5)
        # A non-stream key inside the scan prefix: KEYS lists it, XINFO
        # GROUPS answers WRONGTYPE — the same rescue path a key trimmed
        # away between the two reads takes.
        redis.set("FACET:RESOURCE:gone$0", "x")

        warns = Cron::EventLagCheck.scan(redis, warn_entries: 2_i64, maxlen: 1_000_000_i64)

        warns.size.should eq(1)
        warns.first.stream.should eq("FACET:RESOURCE:sales:Invoice$0")
        # The surviving key's group still feeds the gauge.
        Cron::EventLagCheck.max_lag.should eq(5)
      end
    end

    it "handles a stream with no consumer groups" do
      with_event_redis(TEST_LAG_REDIS_URL) do |redis|
        # A stream with entries but no groups.
        redis.xadd("FACET:RESOURCE:sales:Invoice$0", "*", {"msg" => "x"})

        warns = Cron::EventLagCheck.scan(redis, warn_entries: 1_i64, maxlen: 1_000_000_i64)

        warns.should be_empty
        Cron::EventLagCheck.max_lag.should eq(0)
      end
    end

    it "finds nothing on an empty keyspace" do
      with_event_redis(TEST_LAG_REDIS_URL) do |redis|
        warns = Cron::EventLagCheck.scan(redis, warn_entries: 1_i64, maxlen: 1_000_000_i64)

        warns.should be_empty
        Cron::EventLagCheck.max_lag.should eq(0)
      end
    end
  end
end
