# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "./redis_session"

module Facet
  module IAM
    # One-shot password-change tokens in Redis. Login issues a token when the
    # account must change its password; the change-password route consumes the
    # token. Each consume decrements `attempts_remaining`; the store deletes
    # the token when no attempts remain. The TTL caps the token lifetime.
    #
    # After a successful change the route burns the token and leaves a short
    # "used" marker. A retry that finds no token but the marker answers with
    # a distinct message: the change succeeded, so the caller signs in with
    # the new password.
    #
    # Key structure: `pwd_change:{token}` — hash `{account_id,
    # attempts_remaining}`. The used marker: `pwd_change:used:{token}`.
    module PwdChangeToken
      # Key prefix for one-shot password-change tokens (issued by login when
      # `must_change_pw` is true, consumed by the change-password route).
      PWD_CHANGE_PREFIX   = "pwd_change:"
      PWD_CHANGE_ATTEMPTS = 5

      # Key prefix of the "used" marker left after a successful change. It
      # sits under `PWD_CHANGE_PREFIX`, so the shared `pwd_change:` cleanup
      # sweep removes it too.
      USED_MARKER_PREFIX = "pwd_change:used:"

      # TTL of the "used" marker (seconds). The marker only needs to outlive
      # the retry the client sends after a lost response. A short window
      # keeps Redis clean.
      USED_MARKER_TTL_S = 300

      # Creates a one-shot password-change token for the given account.
      # Returns the opaque token. The caller gives it to the client.
      def self.create_pwd_change_token(account_id : String, ttl : Int32) : String
        token = Random::Secure.hex(32)
        r = RedisSession.redis
        r.hset(
          "#{PWD_CHANGE_PREFIX}#{token}",
          "account_id", account_id,
          "attempts_remaining", PWD_CHANGE_ATTEMPTS.to_s,
        )
        r.expire("#{PWD_CHANGE_PREFIX}#{token}", ttl)
        token
      end

      # Loads (and validates) a password-change token.
      # Decrements `attempts_remaining` on each call; deletes the token when
      # attempts are exhausted. Returns the account_id if the token is valid
      # and still has attempts remaining, nil otherwise.
      def self.consume_pwd_change_token(token : String) : String?
        r = RedisSession.redis
        key = "#{PWD_CHANGE_PREFIX}#{token}"
        raw = r.hgetall(key)
        return nil if raw.is_a?(Array) && raw.empty?

        data = ::Redis.to_hash(raw.as(Array))
        return nil if data.empty?

        to_s = ->(v : ::Redis::Value) { v.is_a?(String) ? v : v.to_s }
        account_id = to_s.call(data["account_id"]? || "")
        return nil if account_id.empty?

        remaining = (to_s.call(data["attempts_remaining"]? || "0")).to_i
        if remaining <= 1
          r.del(key)
          nil
        else
          r.hset(key, "attempts_remaining", (remaining - 1).to_s)
          account_id
        end
      end

      # Deletes a password-change token (called after a successful password
      # change so the token cannot be replayed).
      def self.delete_pwd_change_token(token : String) : Nil
        RedisSession.redis.del("#{PWD_CHANGE_PREFIX}#{token}")
      end

      # Leaves a short-TTL "used" marker after a successful password change.
      # A retry that finds no token but the marker knows the change succeeded.
      def self.mark_pwd_change_token_used(token : String) : Nil
        RedisSession.redis.set("#{USED_MARKER_PREFIX}#{token}", "1", ex: USED_MARKER_TTL_S)
      end

      # Returns true when the token was consumed by a successful password
      # change and the marker has not expired yet.
      def self.used_pwd_change_token?(token : String) : Bool
        result = RedisSession.redis.exists("#{USED_MARKER_PREFIX}#{token}")
        result.is_a?(Int64) && result > 0
      end
    end
  end
end
