# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "./redis_session"

module Facet
  module IAM
    # One-shot MFA enroll tokens in Redis. Login issues an enroll token when
    # the MFA policy enforces enrollment at login; the enroll-verify route
    # consumes the token. The token binds the account, the resolved role, and
    # the cookie request. A wrong TOTP code decrements `attempts_remaining`;
    # the store deletes the token when no attempts remain, after a replayed
    # code, and after a successful enrollment — the token is single-use.
    module EnrollToken
      # Key prefix for one-shot enroll tokens (issued by the login branch
      # under `always` enforcement, consumed by the enroll-verify route).
      ENROLL_PREFIX = "enroll:"
      # TTL (seconds) — matches the login challenge window.
      ENROLL_TTL = 300
      # Invalid TOTP attempts allowed before the token is deleted and the
      # account locks out. Matches the challenge limiter.
      ENROLL_ATTEMPTS = 5

      record EnrollToken,
        account_id : String,
        active_role : String,
        cookie_requested : Bool

      # Creates a one-shot enroll token bound to the account and the resolved
      # role. Returns the opaque token (the login response gives it to the
      # client — it is the authorization for the enroll-verify route).
      def self.create_enroll_token(
        account_id : String,
        active_role : String,
        cookie_requested : Bool,
        ttl : Int32 = ENROLL_TTL,
      ) : String
        token = Random::Secure.hex(32)
        r = RedisSession.redis
        r.hset(
          "#{ENROLL_PREFIX}#{token}",
          "account_id", account_id,
          "active_role", active_role,
          "cookie_requested", cookie_requested.to_s,
          "attempts_remaining", ENROLL_ATTEMPTS.to_s,
        )
        r.expire("#{ENROLL_PREFIX}#{token}", ttl)
        token
      end

      # Loads an enroll token. Returns nil when the token is missing,
      # expired, or carries no account id.
      def self.load_enroll_token(token : String) : EnrollToken?
        raw = RedisSession.redis.hgetall("#{ENROLL_PREFIX}#{token}")
        raw_arr = raw.as?(Array)
        return nil if raw_arr.nil? || raw_arr.empty?

        data = ::Redis.to_hash(raw_arr)
        account_id = data["account_id"]?.try(&.to_s) || ""
        return nil if account_id.empty?

        active_role = data["active_role"]?.try(&.to_s) || ""
        cookie_requested = data["cookie_requested"]?.try(&.to_s) == "true"

        EnrollToken.new(account_id: account_id, active_role: active_role, cookie_requested: cookie_requested)
      end

      # Decrements `attempts_remaining` and returns the value after the
      # decrement. A value of 0 or less means the caller must delete the
      # token.
      def self.decrement_enroll_attempts(token : String) : Int32
        remaining = RedisSession.redis.hincrby("#{ENROLL_PREFIX}#{token}", "attempts_remaining", -1)
        remaining.is_a?(Int64) ? remaining.to_i32 : 0
      end

      # Deletes an enroll token (exhausted attempts, replayed code, or a
      # successful enrollment — the token is always single-use).
      def self.delete_enroll_token(token : String) : Nil
        RedisSession.redis.del("#{ENROLL_PREFIX}#{token}")
      end
    end
  end
end
