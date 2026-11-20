# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Redis helpers ───────────────────────────────────────────────────────────
#
# Helpers for clearing Redis state between tests and creating Redis connections.
# These are top-level functions available in every spec.

# Creates a Redis client connection.
# Uses the same Redis URL as the rest of the IAM subsystem: the configured
# `event.url` from `config.{env}.yml` (per the AGENTS.md config golden rule —
# never read `ENV["REDIS_URL"]` directly for config values).
def with_redis(& : ::Redis::Client -> Nil)
  url = Facet::Config.instance.event.url
  client = ::Redis::Client.new(URI.parse(url))
  begin
    yield client
  ensure
    client.close
  end
end

# Opens a raw Redis client against the given URL (the event subscribers
# and manager specs use a dedicated database 9 imported through their own
# `EVENT_REDIS_URL` env default). Yields the client and closes it after.
def with_event_redis(url : String, & : ::Redis::Client ->)
  client = ::Redis::Client.new(URI.parse(url))
  begin
    yield client
  ensure
    client.close
  end
end

# Backdates the `refresh_issued_at` stamp of the session behind a refresh
# token (`"{session_id}.{refresh_id}"`), so a refresh succeeds despite the
# `OAuth::Refresh.REFRESH_FLOOR_S` floor without a fixed sleep. Call it
# immediately before every refresh invocation in a spec; rotation re-stamps
# the field, so each subsequent refresh needs its own backdate.
def backdate_refresh_issued_at(refresh_token : String, seconds_ago : Int32 = 60) : Nil
  sid = refresh_token.split('.', 2)[0]
  with_redis do |r|
    r.hset("session:#{sid}", "refresh_issued_at", (Time.utc - seconds_ago.seconds).to_rfc3339)
  end
end

# Sums the `oauth_token_rl:*` rate-limit counters. Used to assert that a
# grant type does (or does not) increment the token-endpoint bucket.
def token_rl_bucket_count : Int32
  total = 0
  with_redis do |r|
    r.scan_each(match: "oauth_token_rl:*") do |key|
      v = r.get(key)
      total += v.is_a?(String) ? v.to_i : 0
    end
  end
  total
end

# Flushes all Redis data used by IAM (session, challenge, lockout, etc.).
# Does NOT flush the entire Redis — only keys with known prefixes.
def redis_cleanup : Nil
  prefixes = ["session:", "challenge:", "enroll:", "login_lockout:", "pwd_attempts:", "account_sessions:", "pwd_change:", "pwd_reset:", "mfa_verify_attempts:", "oauth_code:", "app_sessions:", "oauth_token_rl:", "oidc:", "artifact_upload:"]
  with_redis do |r|
    # Delete all keys for each known prefix
    prefixes.each do |prefix|
      i = 0u64
      r.scan_each(match: "#{prefix}*") do |key|
        r.del(key)
        i += 1
        break if i >= 1000
      end
    end
  end
end
