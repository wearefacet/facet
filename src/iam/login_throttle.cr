# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./redis_session"

module Facet
  module IAM
    # Login throttle state in Redis: the account lockout flag and the
    # brute-force attempt counters for password login and MFA verify.
    #
    # ## Key structure
    #
    # - `login_lockout:{account_id}` — present while the account is locked out.
    # - `pwd_attempts:{account_id}` — failed password attempts for an account.
    # - `pwd_attempts:ip:{ip}` — failed password attempts from one client
    #   IP address. `{ip}` is the resolved client IP (`Util::ClientIp` —
    #   a bare host, never a port).
    # - `mfa_verify_attempts:{account_id}` — failed MFA verify attempts.
    # - `change_password_attempts:{account_id}` — failed `old_password`
    #   attempts at `/Api/iam/change-password`.
    # - `challenge_issue_attempts:{account_id}` — MFA challenges opened by
    #   repeated logins in the window.
    # - `challenge_active:{account_id}` — the account's current live challenge
    #   id. A new login replaces (and deletes) the previous challenge.
    #
    # Each counter sets its TTL on the first increment and expires after the
    # window. `reset_pwd_attempts` deletes the password counters after a
    # successful login.
    module LoginThrottle
      # Checks whether the account is locked out.
      def self.locked_out?(account_id : String) : Bool
        r = RedisSession.redis
        result = r.exists("login_lockout:#{account_id}")
        result.is_a?(Int64) && result > 0
      end

      # Sets a login lockout for the account.
      def self.set_lockout(account_id : String, ttl : Int32 = 300) : Nil
        r = RedisSession.redis
        r.set("login_lockout:#{account_id}", "1", ex: ttl)
      end

      # Increments a brute-force attempt counter. Sets the TTL on the first
      # increment so the counter expires after the window. Returns the new
      # count.
      private def self.bump_attempt(key : String, ttl : Int32 = 300) : Int32
        r = RedisSession.redis
        count = r.incr(key)
        count_val = count.is_a?(Int64) ? count : 0_i64
        r.expire(key, ttl) if count_val == 1
        count_val.to_i
      end

      # Reads a brute-force attempt counter without incrementing it.
      private def self.attempt_count(key : String) : Int32
        val = RedisSession.redis.get(key)
        val.is_a?(String) ? val.to_i : 0
      end

      # Increments and returns the password attempt counter for an account.
      # Returns the new count.
      def self.increment_pwd_attempts(account_id : String) : Int32
        bump_attempt("pwd_attempts:#{account_id}")
      end

      # Returns the current password attempt count for an account (without
      # incrementing).
      def self.get_pwd_attempts(account_id : String) : Int32
        attempt_count("pwd_attempts:#{account_id}")
      end

      # Increments the per-IP password attempt counter.
      def self.increment_ip_attempts(ip : String) : Int32
        bump_attempt("pwd_attempts:ip:#{ip}")
      end

      # Returns the current per-IP attempt count.
      def self.get_ip_attempts(ip : String) : Int32
        attempt_count("pwd_attempts:ip:#{ip}")
      end

      # Resets password attempt counters for an account and IP.
      def self.reset_pwd_attempts(account_id : String, ip : String? = nil) : Nil
        r = RedisSession.redis
        r.del("pwd_attempts:#{account_id}")
        if ip
          r.del("pwd_attempts:ip:#{ip}")
        end
      end

      # Redis key prefix for the MFA verify brute-force limiter.
      MFA_VERIFY_PREFIX = "mfa_verify_attempts:"
      # TTL (seconds) for the attempt counter window.
      MFA_VERIFY_TTL = 300

      # Increments and returns the MFA verify attempt count for an account.
      # Sets a 5-minute TTL on the first increment so the counter expires
      # after the window.
      def self.increment_mfa_verify_attempts(account_id : String) : Int32
        bump_attempt("#{MFA_VERIFY_PREFIX}#{account_id}", MFA_VERIFY_TTL)
      end

      # Returns the current MFA verify attempt count (without incrementing).
      def self.get_mfa_verify_attempts(account_id : String) : Int32
        attempt_count("#{MFA_VERIFY_PREFIX}#{account_id}")
      end

      # Resets the MFA verify attempt counter (called on success).
      def self.reset_mfa_verify_attempts(account_id : String) : Nil
        RedisSession.redis.del("#{MFA_VERIFY_PREFIX}#{account_id}")
      end

      # Redis key prefix for the change-password `old_password` limiter.
      CHANGE_PASSWORD_PREFIX = "change_password_attempts:"
      # TTL (seconds) for the change-password attempt counter window.
      CHANGE_PASSWORD_TTL = 300

      # Increments and returns the change-password attempt count for an
      # account. Sets a 5-minute TTL on the first increment so the counter
      # expires after the window.
      def self.increment_change_password_attempts(account_id : String) : Int32
        bump_attempt("#{CHANGE_PASSWORD_PREFIX}#{account_id}", CHANGE_PASSWORD_TTL)
      end

      # Returns the current change-password attempt count (without
      # incrementing).
      def self.get_change_password_attempts(account_id : String) : Int32
        attempt_count("#{CHANGE_PASSWORD_PREFIX}#{account_id}")
      end

      # Resets the change-password attempt counter (called on success).
      def self.reset_change_password_attempts(account_id : String) : Nil
        RedisSession.redis.del("#{CHANGE_PASSWORD_PREFIX}#{account_id}")
      end

      # Redis key prefix for the MFA-challenge creation limiter.
      CHALLENGE_ISSUE_PREFIX = "challenge_issue_attempts:"
      # TTL (seconds) for the challenge-creation counter window. Matches the
      # challenge TTL so the window spans a challenge's whole life.
      CHALLENGE_ISSUE_TTL = 300

      # Increments and returns the MFA-challenge creation count for an
      # account. Sets a 5-minute TTL on the first increment so the counter
      # expires after the window.
      def self.increment_challenge_issues(account_id : String) : Int32
        bump_attempt("#{CHALLENGE_ISSUE_PREFIX}#{account_id}", CHALLENGE_ISSUE_TTL)
      end

      # Returns the current MFA-challenge creation count (without
      # incrementing).
      def self.get_challenge_issues(account_id : String) : Int32
        attempt_count("#{CHALLENGE_ISSUE_PREFIX}#{account_id}")
      end

      # Resets the MFA-challenge creation counter (called after a passed
      # challenge).
      def self.reset_challenge_issues(account_id : String) : Nil
        RedisSession.redis.del("#{CHALLENGE_ISSUE_PREFIX}#{account_id}")
      end

      # Redis key that names an account's current live MFA challenge, so a new
      # login replaces the previous one instead of opening a parallel one.
      CHALLENGE_ACTIVE_PREFIX = "challenge_active:"

      # Names `challenge_id` as the account's live challenge, deleting the
      # previous one it replaced. Returns the replaced challenge id, or nil
      # when there was none.
      def self.track_active_challenge(account_id : String, challenge_id : String, ttl : Int32 = CHALLENGE_ISSUE_TTL) : String?
        r = RedisSession.redis
        key = "#{CHALLENGE_ACTIVE_PREFIX}#{account_id}"
        previous = r.get(key)
        r.set(key, challenge_id, ex: ttl)
        if previous.is_a?(String) && !previous.empty? && previous != challenge_id
          r.del("challenge:#{previous}")
          previous
        end
      end

      # Deletes the account's live challenge (a passed or exhausted
      # challenge) and clears the tracking key when it still names
      # `challenge_id`.
      def self.clear_active_challenge(account_id : String, challenge_id : String) : Nil
        r = RedisSession.redis
        key = "#{CHALLENGE_ACTIVE_PREFIX}#{account_id}"
        current = r.get(key)
        r.del(key) if current.is_a?(String) && current == challenge_id
        r.del("challenge:#{challenge_id}")
      end
    end
  end
end
