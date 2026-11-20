# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "redis"
require "../config"

module Facet
  module OAuth
    # Redis-backed single-use replay cache for DPoP proof `jti` values.
    #
    # Keyed by thumbprint: `dpop:jti:{jkt}:{jti}`. Two clients picking
    # colliding `jti` values cannot evict each other's cache entries — only
    # the matching key holder can replays within its own acceptance window.
    #
    # TTL is bound to the configured `iat` acceptance window through
    # `JWTConfig#dpop_replay_ttl` (derived from `dpop_iat_future_tolerance`
    # and `dpop_iat_past_tolerance`). A proof accepted once stays in the cache
    # for the full window it would be re-accepted in. There is no way to
    # widen the tolerance without widening the cache, and no way to set the
    # cache TTL below the acceptance window.
    module ReplayCache
      KEY_PREFIX = "dpop:jti"

      # Marks `(jkt, jti)` as seen if it has not been seen before.
      #
      # Returns `true` when the `jti` is new (the proof is fresh) and `false`
      # when it is already in the cache (a replay). The cache expiry is the
      # configured `dpop_replay_ttl`.
      #
      # Uses the Redis `SET NX EX` atomic so a concurrent double-check of the
      # same `(jkt, jti)` only marks once — the losing request sees `false`.
      def self.check_and_mark(jkt : String, jti : String) : Bool
        ttl = Facet::Config.instance.iam.jwt.dpop_replay_ttl
        key = "#{KEY_PREFIX}:#{jkt}:#{jti}"
        client = Facet::Redis.client
        begin
          # `SET key 1 NX EX ttl` returns "OK" when the key was newly created
          # (proof is fresh) and `nil` when it already existed (replay).
          result = client.set(key, "1", ex: ttl, nx: true)
          result == "OK"
        ensure
          client.close
        end
      end
    end

    # `htu` reconstruction from the configured public origin.
    #
    # RFC 9449 §4.2 — `htu` is the HTTP target URI without query string or
    # fragment. The client signs the public URL; Kemal sees the internal URL
    # behind a reverse proxy (different scheme, possibly different host).
    #
    # This helper reconstructs `htu` exclusively from `Config.instance.host`
    # and the request path — it does **not** consult `X-Forwarded-Proto` or
    # `X-Forwarded-Host`. Forwarded headers are attacker-controlled when the
    # proxy is misconfigured, so trusting them would let an attacker pick an
    # `htu` they have a matching proof for. The configured origin is the same
    # source `OAuth::Discovery` already uses to advertise `issuer`.
    module HTU
      # Builds the canonical `htu` for the given request path.
      #
      # `path` should be the Kemal-parsed `env.request.path` — it already
      # excludes query string. Callers pass it straight through; this method
      # only reconstructs the scheme/host prefix, delegating scheme
      # normalization to `Config#scheme_base_url`.
      def self.reconstruct(path : String) : String
        "#{Facet::Config.instance.scheme_base_url}#{path}"
      end
    end
  end
end
