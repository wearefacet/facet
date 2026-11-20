# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "redis"

module Facet
  module OAuth
    # Rate limiter for the token endpoint (`POST /OAuth/token`).
    #
    # ## Scope: the `authorization_code` grant only
    #
    # The counter governs interactive exchanges — a one-shot, human-paced
    # event an abuser can hammer. `refresh_token` is exempt from this
    # limiter: refresh runs on a clock (CLIs and agents renew on a
    # schedule), so counting refreshes would starve long-lived sessions and
    # burst a legitimate client the moment its access token expires. The
    # refresh grant is guarded instead by the refresh floor
    # (`OAuth::Refresh.REFRESH_FLOOR_S`) plus rotation and reuse detection —
    # the floor is the refresh guard.
    #
    # ## Why `(client_id, IP)`
    #
    # - Per-`client_id` alone would let a single attacker starve a legitimate
    #   app's budget.
    # - Per-IP alone would let one abuser starve every other user behind a NAT.
    #
    # The pair scopes a single abuser to their own bucket while leaving
    # legitimate clients on the same IP or the same app unaffected. Both fields
    # are present on every `/OAuth/token` request: `client_id` is a required
    # param, `IP` comes from the request.
    #
    # ## Implementation
    #
    # A sliding-window counter in Redis using the same `incr` + windowed-TTL
    # pattern as `IAM::LoginThrottle.increment_ip_attempts`: the first request
    # in a window sets the TTL; the counter auto-expires when the window ends.
    # The window is 5 minutes, the cap is 30 requests (default) — both
    # configurable in `iam.jwt` (leaving the rate-limit tuning close to the
    # token-TTL tuning it logically pairs with).
    #
    # `check_ip` is the per-IP variant for unauthenticated endpoints with no
    # client_id yet — dynamic client registration (`POST /OAuth/register`).
    # Both variants receive the resolved client IP from the routes
    # (`Util::ClientIp.resolve`): the socket host, or the forwarded client
    # address when the peer is a configured trusted proxy. With no trusted
    # proxy configured every caller behind the proxy shares its socket
    # address and funnels into one bucket; acceptable because a
    # registration is a rare, human-paced event and the counter bounds only
    # request pressure, not authorization.
    module RateLimiter
      # The bucket key prefix.
      KEY_PREFIX = "oauth_token_rl:"

      # Default window in seconds. Mirrors `IAM::LoginThrottle` lockout windows.
      WINDOW_S = 300

      # Default cap (requests per window per `(client_id, IP)`). The brief's
      # "rate limiting on the token endpoint" doesn't specify a budget; 30 per
      # 5 minutes is generous for real apps (one token per access-token TTL is
      # 4/hour) and tight enough to make brute-forcing a code or refresh token
      # infeasible.
      DEFAULT_CAP = 30

      # Returned when the caller has exceeded the cap. The route translates
      # this into an HTTP 429 with `error: "slow_down"`.
      record Throttled,
        count : Int32,
        cap : Int32,
        window_s : Int32

      # Checks the rate-limit bucket for `(client_id, ip)`. Returns `nil` when
      # the request is allowed. Every checked request increments the counter,
      # throttled ones included — the increment runs before the cap check, so
      # `Throttled.count` is always the post-increment value (cap + 1 or
      # more; the 429 body caps the reported count at the cap, B-387). The
      # window recovers on its own: the key expires when the TTL ends,
      # whatever the counter reached.
      def self.check(
        client_id : String,
        ip : String?,
        cap : Int32 = DEFAULT_CAP,
        window_s : Int32 = WINDOW_S,
      ) : Throttled?
        # No IP is a degenerate case (e.g. a proxied request with no remote
        # address). Fail open here rather than 429-ing a legitimate caller.
        # The PKCE + single-use-code + refresh-rotation machinery upstream and
        # downstream is the actual security surface; rate-limiting is a
        # convenience layer.
        return nil if ip.nil? || ip.empty?

        incr_window(key_for(client_id, ip), cap, window_s)
      end

      # Per-IP counter for an unauthenticated endpoint that has no client_id
      # to key on — dynamic client registration. `scope` namespaces the
      # bucket so a registration counter can never collide with a token
      # counter for the same IP. Same fail-open rule on a missing IP.
      def self.check_ip(
        ip : String?,
        scope : String,
        cap : Int32 = DEFAULT_CAP,
        window_s : Int32 = WINDOW_S,
      ) : Throttled?
        return nil if ip.nil? || ip.empty?

        incr_window("#{KEY_PREFIX}#{scope}:#{ip}", cap, window_s)
      end

      private def self.incr_window(key : String, cap : Int32, window_s : Int32) : Throttled?
        r = Facet::Redis.client
        count = r.incr(key)
        count_val = count.is_a?(Int64) ? count : 0_i64
        r.expire(key, window_s) if count_val == 1

        return nil if count_val <= cap
        Throttled.new(count: count_val.to_i32, cap: cap, window_s: window_s)
      end

      private def self.key_for(client_id : String, ip : String) : String
        # Hash the pair so an attacker can't craft a `client_id` containing a
        # colon to collide with another client's bucket. The hash is
        # deterministic and stable across processes.
        "#{KEY_PREFIX}#{client_id}::#{ip}"
      end
    end
  end
end
