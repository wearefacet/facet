# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "redis"
require "../error"
require "../secrets/store"

module Facet
  module IAM
    # Handles MFA challenge verification during login.
    #
    # The TOTP seed is revealed from the account's sealed `mfa` slot; the
    # replay guard advances atomically in the `auth_state` table. The
    # `backup_code` method skips the seed entirely: it consumes one of the
    # account's single-use backup codes (`IAM::BackupCodes`) — the
    # self-recovery path when the authenticator is lost.
    module Challenge
      record TokensEmitted,
        result : TokenEmitter::Result

      # Verifies an MFA challenge.
      #
      # * `db` — database connection
      # * `challenge_id` — the challenge ULID from Redis
      # * `code` — the 6-digit TOTP code, or (with `method: "backup_code"`)
      #   one of the single-use backup codes
      # * `method` — `"totp"` (default) or `"backup_code"`
      def self.call(
        db : DB::Connection,
        challenge_id : String,
        code : String,
        method : String = "totp",
      ) : TokensEmitted | Facet::ServiceError
        r = RedisSession.redis
        challenge_key = "challenge:#{challenge_id}"

        # 1. Load the challenge
        data = load_challenge(r, challenge_key)
        return data if data.is_a?(Facet::ServiceError)
        challenge = data.as(NamedTuple)
        account_id = challenge[:account_id]
        active_role = challenge[:active_role]
        cookie_requested = challenge[:cookie_requested]

        if method == "backup_code"
          return verify_backup_code(db, r, challenge_key, account_id, active_role,
            cookie_requested, code)
        end

        # 2. Fetch the account's MFA secret from the sealed `mfa` slot.
        doc_ref = "iam.Account.#{account_id}"
        mfa_secret = Secrets.reveal(db, doc_ref, "mfa")
        if mfa_secret.nil?
          return Facet::ServiceError.new(401, "MFA not configured. Please re-login.")
        end

        # 3. Validate the TOTP code
        mfa_config = Config.mfa.totp
        step = TOTP.validate(mfa_secret, code, window: mfa_config.window)

        if step.nil?
          return handle_invalid_code(r, challenge_key, db, account_id)
        end

        # 4. Atomically advance last_totp_step in `auth_state` (replay
        # protection). The conditional upsert serializes the advancement at
        # the DB level — 0 rows affected means a concurrent request already
        # consumed this step, so this is a replay.
        unless AuthState.try_advance_totp_step(db, doc_ref, step)
          r.del(challenge_key)
          return Facet::ServiceError.new(401, "Code already used. Please re-login.")
        end

        # 5. Delete the challenge
        r.del(challenge_key)

        # 7. Emit tokens and write login event
        Helpers.write_login_event(db, account_id, "login", "MFA challenge passed, role: #{active_role}")
        emit_tokens(db, account_id, active_role, cookie_requested)
      end

      # ── Private ──────────────────────────────────────────────────────

      # Verifies a backup code — the lost-authenticator self-recovery path.
      # The consume is its own replay guard: one atomic UPDATE that only
      # matches a still-unused row. A failure burns a challenge attempt like
      # a wrong TOTP code (lockout included), so the codes cannot be probed.
      private def self.verify_backup_code(
        db : DB::Connection,
        r : ::Redis::Client,
        challenge_key : String,
        account_id : String,
        active_role : String,
        cookie_requested : Bool,
        code : String,
      ) : TokensEmitted | Facet::ServiceError
        if BackupCodes.consume(db, account_id, code)
          r.del(challenge_key)
          Helpers.write_login_event(db, account_id, "login",
            "MFA challenge passed via backup code, role: #{active_role}")
          return emit_tokens(db, account_id, active_role, cookie_requested)
        end
        handle_invalid_code(r, challenge_key, db, account_id)
      end

      # Loads a challenge from Redis and returns it as a NamedTuple, or an Error.
      private def self.load_challenge(r, challenge_key : String) : Facet::ServiceError | NamedTuple(account_id: String, active_role: String, cookie_requested: Bool)
        raw = r.hgetall(challenge_key)
        raw_arr = raw.as?(Array)
        if raw_arr.nil? || raw_arr.empty?
          return Facet::ServiceError.new(401, "Challenge not found or expired. Please re-login.")
        end

        data = ::Redis.to_hash(raw_arr)
        account_id = data["account_id"]?.try(&.to_s) || ""
        active_role = data["active_role"]?.try(&.to_s) || ""
        cookie_requested = data["cookie_requested"]?.try(&.to_s) == "true"

        if account_id.empty?
          return Facet::ServiceError.new(401, "Challenge data corrupted.")
        end

        {account_id: account_id, active_role: active_role, cookie_requested: cookie_requested}
      end

      # Handles an invalid TOTP code by decrementing attempts and possibly locking out.
      private def self.handle_invalid_code(r, challenge_key : String, db : DB::Connection, account_id : String) : Facet::ServiceError
        remaining_val = r.hincrby(challenge_key, "attempts_remaining", -1)
        remaining = remaining_val.is_a?(Int64) ? remaining_val : 0
        if remaining <= 0
          r.del(challenge_key)
          LoginThrottle.set_lockout(account_id)
          Helpers.write_login_event(db, account_id, "lockout", "MFA lockout: too many attempts")
          return Facet::ServiceError.new(429, "Too many attempts. Account locked.")
        end
        noun = remaining == 1 ? "attempt" : "attempts"
        Facet::ServiceError.new(401, "Invalid code. #{remaining} #{noun} remaining.")
      end

      private def self.emit_tokens(
        db : DB::Connection,
        account_id : String,
        active_role : String,
        cookie_requested : Bool,
      ) : TokensEmitted | Facet::ServiceError
        result = SessionEmit.call(db, account_id, active_role, cookie_requested)
        return result if result.is_a?(Facet::ServiceError)
        TokensEmitted.new(result: result)
      end
    end
  end
end
