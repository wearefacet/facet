# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Crockford's Base32 alphabet (no I, L, O, U).
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# Builds a `Config` with known hosts for the `.facet_hosts` specs. Kept at
# file scope: a `def` cannot be declared inside the spec DSL's describe
# blocks.
def known_hosts_config : Facet::Config
  Facet::Config.new(
    host: "https://facet.example.tld:3443",
    base_url: "https://facet.example.tld:3443",
    artifact_base_url: "https://artifact.example.tld",
    artifact_grant_secret: "test-grant-secret",
    secrets: Facet::Secrets::Config.new(master_key: TEST_MASTER_KEY),
    # Keep the suite posture (bound disabled) — a swap that defaulted it
    # to 300 would let the process caches rebuild from the truncated
    # projections mid-suite.
    cache: Facet::Config::CacheConfig.new(staleness_ttl_s: 0),
  )
end

# Decodes the time component of a ULID produced by the platform generators:
# the 48-bit ms timestamp (first 10 chars) and the 10-bit sub-ms tick
# (chars 11-12). Returns ms * 1024 + tick — a value that increases with
# creation time and is independent of the random bits.
def decode_tick(ulid : String) : Int64
  head = 0_i64
  ulid[0, 10].each_char { |c| head = (head << 5) | CROCKFORD.index!(c).to_i64 }
  tick = 0_i64
  ulid[10, 2].each_char { |c| tick = (tick << 5) | CROCKFORD.index!(c).to_i64 }
  ms = (head >> 2) & ((1_i64 << 48) - 1)
  ms * 1024 + tick
end

# Runs `count` back-to-back PG ulid() calls inside one SQL statement and
# returns them in generation order.
def pg_ulids(db, count : Int32) : Array(String)
  raw = db.query_one(
    "SELECT string_agg(u, ',' ORDER BY n) " \
    "FROM (SELECT ulid() AS u, n FROM generate_series(1, #{count}) AS g(n)) s",
    as: String,
  )
  raw.split(',')
end

module Facet
  module Util
    describe ScriptHelpers do
      describe ".ulid" do
        it "returns a 26-character Crockford Base32 string" do
          ulid = ScriptHelpers.ulid
          ulid.size.should eq(26)
          ulid.each_char { |c| CROCKFORD.includes?(c).should be_true }
        end

        it "encodes a recent millisecond timestamp in the first 10 chars" do
          # The first 10 chars decode (naive MSB-first 5-bit-per-char) to the
          # 48-bit ms timestamp padded with 2 zero low bits. Shift right by 2
          # to recover the ms timestamp, which must be within ~2 seconds of
          # the reference snapshot.
          reference_ms = Time.utc.to_unix_ms
          ulid = ScriptHelpers.ulid

          d = 0_i64
          ulid[0, 10].each_char do |c|
            d = (d << 5) | CROCKFORD.index!(c).to_i64
          end
          ts = (d >> 2) & ((1_i64 << 48) - 1)
          (ts - reference_ms).abs.should be < 2000
        end

        it "orders rapid successive ULIDs by their time component" do
          # Issuing N ULIDs back-to-back. The 10-bit sub-ms precision
          # (~0.977 µs) means two calls can land in the same sub-ms slot;
          # ties within one tick resolve on random bits and may order either
          # way (the same contract the PG `ulid()` tests assert). What the
          # design guarantees: the decoded (ms, tick) component never goes
          # back, and whenever it advances, the full string sorts after —
          # so `ORDER BY id` follows creation order to ~1 µs.
          ulids = Array(String).new(100) { ScriptHelpers.ulid }
          ulids.each_cons(2) do |pair|
            t0, t1 = decode_tick(pair[0]), decode_tick(pair[1])
            t0.should be <= t1
            if t0 < t1
              (pair[0] < pair[1]).should be_true
            end
          end
          # Sanity: the sequence is not constant.
          ulids.uniq.size.should be > 1
        end

        it "produces unique ULIDs across many calls" do
          ulids = Array(String).new(1000) { ScriptHelpers.ulid }
          ulids.uniq.size.should eq(ulids.size)
        end
      end

      describe ".ulid (time component)" do
        it "keeps the decoded time component non-decreasing across rapid calls" do
          # Compare the decoded (ms, sub-ms tick) pair, not the full string:
          # two calls inside the same tick resolve ties on random bits, which
          # may order either way. The tick grid itself must never go back.
          ulids = Array(String).new(200) { ScriptHelpers.ulid }
          ticks = ulids.map { |u| decode_tick(u) }
          ticks.each_cons(2) do |pair|
            (pair[0] <= pair[1]).should be_true
          end
        end
      end

      describe ".facet_hosts" do
        it "reserves the configured hosts in port-less form" do
          original = Facet::Config.instance
          Facet::Config.instance = known_hosts_config
          hosts = ScriptHelpers.facet_hosts
          Facet::Config.instance = original
          hosts.should contain("facet.example.tld")
          hosts.should contain("artifact.example.tld")
        end

        it "reserves the loopback literals" do
          original = Facet::Config.instance
          Facet::Config.instance = known_hosts_config
          hosts = ScriptHelpers.facet_hosts
          Facet::Config.instance = original
          hosts.should contain("127.0.0.1")
          hosts.should contain("::1")
        end

        it "reserves the stacks' internal service name" do
          # The docker e2e stacks reach the backend as `http://backend:3000`,
          # so forwarded requests carry `Host: backend`. The app-host
          # dispatcher must fall through on that host (and no app may
          # claim it) — see e2e-harness plan, D1.
          original = Facet::Config.instance
          Facet::Config.instance = known_hosts_config
          hosts = ScriptHelpers.facet_hosts
          Facet::Config.instance = original
          hosts.should contain("backend")
        end
      end

      describe ".valid_hostname?" do
        it "accepts a bare lowercase hostname" do
          ["hr.app.example.com", "localhost", "a-b.example.tld"].each do |value|
            ScriptHelpers.valid_hostname?(value).should be_true
          end
        end

        it "rejects a host that carries a port (B-211)" do
          # The deployment target supplies the port at serve time. A stored
          # port made the dispatcher's port-stripped lookup miss (404) while
          # the UI reported the app Active.
          ["hr.app.example.com:8443", "localhost:3000"].each do |value|
            ScriptHelpers.valid_hostname?(value).should be_false
          end
        end

        it "rejects scheme, path, wildcard, uppercase, empty, and oversized shapes" do
          bad = ["https://hr.app.example.com", "hr.app.example.com/path",
                 "*.app.example.com", "HR.App.Example.COM", "",
                 "-leading.example.com", "a" * 254]
          bad.each do |value|
            ScriptHelpers.valid_hostname?(value).should be_false
          end
        end
      end

      describe ".normalize_host" do
        it "strips the scheme, the path, and the port" do
          ScriptHelpers.normalize_host("HTTPS://MyApp.Example.COM:443/x").should eq("myapp.example.com")
        end

        it "keeps a bare host unchanged" do
          ScriptHelpers.normalize_host("myapp.example.com").should eq("myapp.example.com")
        end

        it "strips one trailing dot" do
          # A fully qualified DNS name may carry one trailing dot. The
          # webhook host check strips it too, so both checks see the same
          # value (F07-02).
          ScriptHelpers.normalize_host("myapp.example.com.").should eq("myapp.example.com")
        end

        it "strips the trailing dot on a full URL form" do
          ScriptHelpers.normalize_host("https://myapp.example.com.:8443/app/").should eq("myapp.example.com")
        end

        it "keeps a lone dot unchanged (the guard mirrors Webhook::TargetCheck)" do
          ScriptHelpers.normalize_host(".").should eq(".")
        end
      end

      describe "PG ulid() (mirror contract)" do
        it "keeps the decoded time component non-decreasing within one statement" do
          # 500 back-to-back calls inside one SQL statement run in a few
          # milliseconds, so many pairs share a millisecond prefix — this
          # exercises exactly the sub-ms ordering that ORDER BY id relies on.
          with_db do |db|
            ulids = pg_ulids(db, 500)
            # Same-ms coverage: the calls must not span 500 distinct ms.
            ms_prefixes = ulids.map { |u| u[0, 10] }
            ms_prefixes.uniq.size.should be < 500
            ticks = ulids.map { |u| decode_tick(u) }
            ticks.each_cons(2) do |pair|
              (pair[0] <= pair[1]).should be_true
            end
          end
        end

        it "produces unique values" do
          with_db do |db|
            ulids = pg_ulids(db, 500)
            ulids.uniq.size.should eq(ulids.size)
          end
        end
      end

      describe ".date_diff" do
        it "measures elapsed days physically" do
          ScriptHelpers.date_diff("2026-07-27", "2026-08-06", "day").should eq(10.0)
        end

        it "returns fractional elapsed days for a half day" do
          ScriptHelpers.date_diff("2026-01-01T00:00:00Z", "2026-01-01T12:00:00Z", "day").should eq(0.5)
        end

        it "counts calendar month distance across a month boundary" do
          ScriptHelpers.date_diff("2026-07-27", "2026-08-06", "month").should eq(1.0)
        end

        it "counts zero months within one calendar month" do
          ScriptHelpers.date_diff("2026-01-01", "2026-01-31", "month").should eq(0.0)
        end

        it "counts one month across a single-day boundary crossing" do
          ScriptHelpers.date_diff("2026-01-31", "2026-02-01", "month").should eq(1.0)
        end

        it "counts twelve month boundaries as twelve months" do
          ScriptHelpers.date_diff("2025-01-01", "2026-01-01", "month").should eq(12.0)
        end

        it "counts calendar year distance by year position" do
          ScriptHelpers.date_diff("2024-06-15", "2025-06-14", "year").should eq(1.0)
          ScriptHelpers.date_diff("2026-01-01", "2026-12-31", "year").should eq(0.0)
        end

        it "is signed by argument order" do
          ScriptHelpers.date_diff("2026-08-06", "2026-07-27", "month").should eq(-1.0)
          ScriptHelpers.date_diff("2026-08-06", "2026-07-27", "day").should eq(-10.0)
        end

        it "supports the sub-day and week elapsed units" do
          ScriptHelpers.date_diff("2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z", "hour").should eq(24.0)
          ScriptHelpers.date_diff("2026-01-01T00:00:00Z", "2026-01-01T01:30:00Z", "minute").should eq(90.0)
          ScriptHelpers.date_diff("2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z", "second").should eq(1.0)
          ScriptHelpers.date_diff("2026-01-01", "2026-01-15", "week").should eq(2.0)
        end

        it "reads calendar dates as UTC midnight" do
          ScriptHelpers.date_diff("2026-01-01", "2026-01-02", "second").should eq(86_400.0)
        end

        it "converts offsets to UTC before the distance" do
          ScriptHelpers.date_diff("2026-01-01T00:00:00+02:00", "2026-01-01T00:00:00Z", "hour").should eq(2.0)
        end

        it "raises on an unknown unit" do
          expect_raises(ArgumentError, "unknown unit") do
            ScriptHelpers.date_diff("2026-01-01", "2026-02-01", "fortnight")
          end
        end

        it "raises on an unparseable value" do
          expect_raises(ArgumentError, "not a valid ISO 8601") do
            ScriptHelpers.date_diff("garbage", "2026-02-01", "day")
          end
        end
      end

      describe ".date_today and .date_now" do
        it "returns today's UTC calendar date in YYYY-MM-DD form" do
          ScriptHelpers.date_today.should eq(Time.utc.to_s("%Y-%m-%d"))
        end

        it "returns the current UTC time as a parseable RFC 3339 string" do
          parsed = Time.parse_iso8601(ScriptHelpers.date_now)
          (Time.utc - parsed).abs.total_seconds.should be < 5.0
        end
      end

      describe ".date_add" do
        it "clamps the day when the target month is shorter" do
          ScriptHelpers.date_add("2026-01-31", 1, "month").should eq("2026-02-28")
          ScriptHelpers.date_add("2026-01-31", 2, "month").should eq("2026-03-31")
        end

        it "clamps leap days on year shifts" do
          ScriptHelpers.date_add("2024-02-29", 1, "year").should eq("2025-02-28")
        end

        it "subtracts with a negative count" do
          ScriptHelpers.date_add("2026-03-31", -1, "month").should eq("2026-02-28")
          ScriptHelpers.date_add("2026-07-27", -30, "day").should eq("2026-06-27")
        end

        it "moves a calendar date by days and weeks and stays a calendar date" do
          ScriptHelpers.date_add("2026-07-27", 30, "day").should eq("2026-08-26")
          ScriptHelpers.date_add("2026-07-27", 2, "week").should eq("2026-08-10")
        end

        it "moves a datetime and normalizes to UTC" do
          ScriptHelpers.date_add("2026-01-01T23:00:00Z", 2, "hour").should eq("2026-01-02T01:00:00Z")
          ScriptHelpers.date_add("2026-01-01T00:00:00+02:00", 1, "hour").should eq("2025-12-31T23:00:00Z")
        end

        it "accepts fractional elapsed units on a datetime" do
          ScriptHelpers.date_add("2026-01-01T00:00:00Z", 1.5, "hour").should eq("2026-01-01T01:30:00Z")
          ScriptHelpers.date_add("2026-01-01T00:00:00Z", 1.5, "day").should eq("2026-01-02T12:00:00Z")
        end

        it "rejects fractional calendar units" do
          expect_raises(ArgumentError, "whole number") do
            ScriptHelpers.date_add("2026-01-01", 1.5, "month")
          end
        end

        it "rejects sub-day units on a calendar date" do
          expect_raises(ArgumentError, "needs a datetime") do
            ScriptHelpers.date_add("2026-01-01", 3, "hour")
          end
        end

        it "raises on an unknown unit" do
          expect_raises(ArgumentError, "unknown unit") do
            ScriptHelpers.date_add("2026-01-01", 1, "decade")
          end
        end
      end

      describe ".date_start_of" do
        it "starts the ISO week on Monday" do
          ScriptHelpers.date_start_of("2026-01-31", "week").should eq("2026-01-26")
        end

        it "starts month, quarter, year, and day on a calendar date" do
          ScriptHelpers.date_start_of("2026-01-31", "month").should eq("2026-01-01")
          ScriptHelpers.date_start_of("2026-11-19", "quarter").should eq("2026-10-01")
          ScriptHelpers.date_start_of("2026-11-19", "year").should eq("2026-01-01")
          ScriptHelpers.date_start_of("2026-11-19", "day").should eq("2026-11-19")
        end

        it "returns a UTC midnight instant for a datetime" do
          ScriptHelpers.date_start_of("2026-01-31T15:30:45Z", "month").should eq("2026-01-01T00:00:00Z")
        end

        it "raises on an unknown unit" do
          expect_raises(ArgumentError, "unknown unit") do
            ScriptHelpers.date_start_of("2026-01-31", "semester")
          end
        end
      end

      describe ".date_end_of" do
        it "ends the month on its last day, leap years included" do
          ScriptHelpers.date_end_of("2026-01-15", "month").should eq("2026-01-31")
          ScriptHelpers.date_end_of("2024-02-10", "month").should eq("2024-02-29")
        end

        it "ends the ISO week on Sunday" do
          ScriptHelpers.date_end_of("2026-01-31", "week").should eq("2026-02-01")
        end

        it "ends quarter and year on their last day" do
          ScriptHelpers.date_end_of("2026-11-19", "quarter").should eq("2026-12-31")
          ScriptHelpers.date_end_of("2026-11-19", "year").should eq("2026-12-31")
        end

        it "returns the last whole second for a datetime" do
          ScriptHelpers.date_end_of("2026-01-15T10:00:00Z", "month").should eq("2026-01-31T23:59:59Z")
        end

        it "raises on an unknown unit" do
          expect_raises(ArgumentError, "unknown unit") do
            ScriptHelpers.date_end_of("2026-01-31", "month!")
          end
        end
      end

      describe ".date_parts" do
        it "returns zero time fields for a calendar date" do
          p = ScriptHelpers.date_parts("2026-01-19")
          p[:year].should eq(2026)
          p[:month].should eq(1)
          p[:day].should eq(19)
          p[:hour].should eq(0)
          p[:minute].should eq(0)
          p[:second].should eq(0)
          p[:weekday].should eq(1)
        end

        it "converts an offset datetime to UTC components" do
          p = ScriptHelpers.date_parts("2026-01-01T05:30:10+02:00")
          p[:hour].should eq(3)
          p[:minute].should eq(30)
          p[:second].should eq(10)
        end

        it "uses ISO-8601 weekdays (Monday = 1, Sunday = 7)" do
          ScriptHelpers.date_parts("2026-01-19")[:weekday].should eq(1)
          ScriptHelpers.date_parts("2026-01-25")[:weekday].should eq(7)
        end
      end

      describe ".period_overlaps?" do
        it "is true for sharing instants" do
          ScriptHelpers.period_overlaps?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z",
            "2026-01-05T00:00:00Z", "2026-01-20T00:00:00Z").should be_true
        end

        it "is false for touching ranges — the [) end excludes its instant" do
          ScriptHelpers.period_overlaps?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z",
            "2026-01-10T00:00:00Z", "2026-01-20T00:00:00Z").should be_false
        end

        it "is true for nested and false for disjoint ranges" do
          ScriptHelpers.period_overlaps?("2026-01-01T00:00:00Z", "2026-01-31T00:00:00Z",
            "2026-01-10T00:00:00Z", "2026-01-20T00:00:00Z").should be_true
          ScriptHelpers.period_overlaps?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z",
            "2026-02-01T00:00:00Z", "2026-02-10T00:00:00Z").should be_false
        end
      end

      describe ".period_contains?" do
        it "includes the start and excludes the end" do
          ScriptHelpers.period_contains?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z", "2026-01-01T00:00:00Z").should be_true
          ScriptHelpers.period_contains?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z", "2026-01-10T00:00:00Z").should be_false
          ScriptHelpers.period_contains?("2026-01-01T00:00:00Z", "2026-01-10T00:00:00Z", "2026-01-05T00:00:00Z").should be_true
        end
      end

      describe ".dateperiod_overlaps?" do
        it "is true for touching calendar ranges — both bounds include their day" do
          ScriptHelpers.dateperiod_overlaps?("2026-01-01", "2026-01-10", "2026-01-10", "2026-01-20").should be_true
        end

        it "is true for overlapping and false for disjoint calendar ranges" do
          ScriptHelpers.dateperiod_overlaps?("2026-01-05", "2026-01-15", "2026-01-10", "2026-01-20").should be_true
          ScriptHelpers.dateperiod_overlaps?("2026-01-01", "2026-01-10", "2026-01-11", "2026-01-20").should be_false
        end
      end

      describe ".dateperiod_contains?" do
        it "includes both ends and truncates a datetime to its UTC date" do
          ScriptHelpers.dateperiod_contains?("2026-01-01", "2026-01-31", "2026-01-01").should be_true
          ScriptHelpers.dateperiod_contains?("2026-01-01", "2026-01-31", "2026-01-31").should be_true
          ScriptHelpers.dateperiod_contains?("2026-01-01", "2026-01-31", "2026-01-31T23:00:00Z").should be_true
          ScriptHelpers.dateperiod_contains?("2026-01-01", "2026-01-31", "2026-02-01").should be_false
        end
      end
    end
  end
end
