# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/rate_limiter"
require "../support/redis_helper"

# `OAuth::RateLimiter`.
#
# The limiter is keyed on
# `(client_id, IP)` so a single attacker can't starve a victim app's
# per-client bucket (per-`client_id` alone) nor starve every other user
# behind the same NAT (per-IP alone).
#
# Sliding-window counter in Redis using the same `incr` + windowed-TTL
# pattern as `IAM::LoginThrottle.increment_ip_attempts`. The cap and window
# are overridable in tests so we don't have to issue 30 requests.

describe "OAuth::RateLimiter" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  it "allows requests under the cap" do
    throttled = Facet::OAuth::RateLimiter.check("client_1", "1.2.3.4", cap: 3, window_s: 60)
    throttled.should be_nil

    throttled = Facet::OAuth::RateLimiter.check("client_1", "1.2.3.4", cap: 3, window_s: 60)
    throttled.should be_nil
  end

  it "returns Throttled when the cap is exceeded" do
    cap = 3
    (1..cap).each do
      Facet::OAuth::RateLimiter.check("client_2", "5.6.7.8", cap: cap, window_s: 60).should be_nil
    end
    throttled = Facet::OAuth::RateLimiter.check("client_2", "5.6.7.8", cap: cap, window_s: 60)
    throttled.should be_a(Facet::OAuth::RateLimiter::Throttled)
    t = throttled.as(Facet::OAuth::RateLimiter::Throttled)
    t.count.should eq(cap + 1)
    t.cap.should eq(cap)
  end

  it "isolates buckets by client_id" do
    # Burn the budget for (client_A, IP).
    Facet::OAuth::RateLimiter.check("client_A", "9.9.9.9", cap: 1, window_s: 60).should be_nil
    Facet::OAuth::RateLimiter.check("client_A", "9.9.9.9", cap: 1, window_s: 60).should_not be_nil

    # (client_B, same IP) is unaffected.
    Facet::OAuth::RateLimiter.check("client_B", "9.9.9.9", cap: 1, window_s: 60).should be_nil
  end

  it "isolates buckets by IP" do
    Facet::OAuth::RateLimiter.check("client_X", "10.0.0.1", cap: 1, window_s: 60).should be_nil
    Facet::OAuth::RateLimiter.check("client_X", "10.0.0.1", cap: 1, window_s: 60).should_not be_nil

    # Same client, different IP — different bucket.
    Facet::OAuth::RateLimiter.check("client_X", "10.0.0.2", cap: 1, window_s: 60).should be_nil
  end

  it "fails open when the IP is missing (degenerate request)" do
    # No `remote_address` — e.g. a proxied request. Fail open: PKCE + the
    # single-use code + refresh rotation is the actual security surface.
    Facet::OAuth::RateLimiter.check("client_Y", nil).should be_nil
    Facet::OAuth::RateLimiter.check("client_Y", "").should be_nil
  end

  it "recovers after the window elapses" do
    cap = 1
    Facet::OAuth::RateLimiter.check("client_R", "11.0.0.1", cap: cap, window_s: 1).should be_nil
    Facet::OAuth::RateLimiter.check("client_R", "11.0.0.1", cap: cap, window_s: 1).should_not be_nil

    # A throttled call still increments the counter but does not re-arm the
    # TTL — `expire` runs only when the count first becomes 1 — so the key
    # expires on schedule. Poll until the first post-expiry call returns
    # nil; that poll result is the assertion. Do not call `check` again
    # after the poll: a further call would increment past the cap and
    # throttle again.
    wait_for(3.0) do
      Facet::OAuth::RateLimiter.check("client_R", "11.0.0.1", cap: cap, window_s: 1).nil?
    end.should be_true
  end
end

# The per-IP variant backs the unauthenticated endpoints that have no
# client_id to key on — dynamic client registration. Same sliding-window
# counter, bucket namespaced by the scope so a registration counter can
# never collide with a token counter for the same IP.
describe "OAuth::RateLimiter.check_ip" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  it "allows requests under the cap and throttles past it" do
    cap = 2
    2.times do
      Facet::OAuth::RateLimiter.check_ip("1.2.3.4", "register", cap: cap, window_s: 60).should be_nil
    end
    throttled = Facet::OAuth::RateLimiter.check_ip("1.2.3.4", "register", cap: cap, window_s: 60)
    throttled.should be_a(Facet::OAuth::RateLimiter::Throttled)
    t = throttled.as(Facet::OAuth::RateLimiter::Throttled)
    t.count.should eq(cap + 1)
    t.cap.should eq(cap)
  end

  it "isolates the scoped bucket from the token bucket for the same IP" do
    Facet::OAuth::RateLimiter.check_ip("10.0.0.1", "register", cap: 1, window_s: 60).should be_nil
    Facet::OAuth::RateLimiter.check_ip("10.0.0.1", "register", cap: 1, window_s: 60).should_not be_nil

    # The (client_id, IP) token bucket is unaffected by the scoped counter.
    Facet::OAuth::RateLimiter.check("client_Z", "10.0.0.1", cap: 1, window_s: 60).should be_nil
  end

  it "fails open when the IP is missing" do
    Facet::OAuth::RateLimiter.check_ip(nil, "register").should be_nil
    Facet::OAuth::RateLimiter.check_ip("", "register").should be_nil
  end
end
