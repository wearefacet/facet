# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/replay_cache"

# Replay cache specs.
#
# Scoped by `(jkt, jti)` — two clients picking colliding `jti` values cannot
# evict each other's cache entries. TTL is bound to the configured `iat`
# acceptance window via `JWTConfig#dpop_replay_ttl`, derived as
# `max(future, past) + 30`. These specs do not vary the config (that would
# couple this spec to the dpop_spec's tolerance tests); they only assert the
# mark-and-reject contract.
describe Facet::OAuth::ReplayCache do
  jkt = "thumbprint_a"
  jti = "jti_#{Random::Secure.hex(8)}"

  after_each do
    # Best-effort cleanup so a slow TTL doesn't leak between this and a wide
    # future-tolerance run. The key persists under the configured TTL after a
    # mark; deleting it is safe.
    with_redis do |r|
      r.del("dpop:jti:#{jkt}:#{jti}")
    end
  end

  it "marks a fresh (jkt, jti) as new" do
    Facet::OAuth::ReplayCache.check_and_mark(jkt, jti).should be_true
  end

  it "rejects a replayed (jkt, jti)" do
    Facet::OAuth::ReplayCache.check_and_mark(jkt, jti).should be_true
    Facet::OAuth::ReplayCache.check_and_mark(jkt, jti).should be_false
  end

  it "isolates by jkt — colliding jti under different jkt is accepted" do
    jkt_b = "thumbprint_b"
    Facet::OAuth::ReplayCache.check_and_mark(jkt, jti).should be_true
    Facet::OAuth::ReplayCache.check_and_mark(jkt_b, jti).should be_true

    # Cleanup the second jkt's cache entry too.
    with_redis do |r|
      r.del("dpop:jti:#{jkt_b}:#{jti}")
    end
  end
end
