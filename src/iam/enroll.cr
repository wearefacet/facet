# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "redis"
require "json"
require "../error"
require "../secrets/store"
require "./account_patch"
require "./session_emit"

module Facet
  module IAM
    # Completes the enroll-at-login flow (MFA enforcement `always`).
    #
    # The login branch held an un-enrolled account at the enrollment step and
    # returned a one-shot enroll token plus the provisional TOTP secret. This
    # service validates the first code against that secret, flips
    # `mfa_enabled`, and emits the session the login withheld. The enroll
    # token is the only authorization here — no session exists yet.
    module Enroll
      record TokensEmitted,
        result : TokenEmitter::Result,
        backup_codes : Array(String)

      # Verifies the enrollment code and completes the login.
      #
      # * `db` — database connection
      # * `enroll_token` — the one-shot token returned by the login branch
      # * `code` — the 6-digit TOTP code from the authenticator app
      def self.verify(
        db : DB::Connection,
        enroll_token : String,
        code : String,
      ) : TokensEmitted | Facet::ServiceError
        # 1. Load the enroll token (nil → the login session is gone; the
        # account must re-login).
        token = EnrollToken.load_enroll_token(enroll_token)
        if token.nil?
          return Facet::ServiceError.new(401, "Enroll session not found or expired. Please re-login.")
        end
        account_id = token.account_id

        # 2. The provisional secret stored by the login branch's `MFA.setup`.
        doc_ref = "iam.Account.#{account_id}"
        mfa_secret = Secrets.reveal(db, doc_ref, "mfa")
        if mfa_secret.nil?
          return Facet::ServiceError.new(401, "MFA not configured. Please re-login.")
        end

        # 3. Validate the TOTP code
        step = TOTP.validate(mfa_secret, code, window: Config.mfa.totp.window)
        if step.nil?
          return handle_invalid_code(enroll_token, db, account_id)
        end

        # 4. Atomically advance the replay guard — same semantics as the
        # challenge flow. 0 rows affected means this step was already
        # consumed, so the code is a replay.
        unless AuthState.try_advance_totp_step(db, doc_ref, step)
          EnrollToken.delete_enroll_token(enroll_token)
          return Facet::ServiceError.new(401, "Code already used. Please re-login.")
        end

        # 5. Flip the account document field (the `MFA.verify` enable path).
        patch = AccountPatch.call(db, account_id, {"mfa_enabled" => JSON::Any.new(true)})
        return patch if patch.is_a?(Facet::ServiceError)

        # 6. The token is single-use — dead before anything else happens.
        EnrollToken.delete_enroll_token(enroll_token)

        Helpers.write_login_event(db, account_id, "mfa_enrolled")

        # 7. Bootstrap completion: an enrollment that issues a session is a
        # full login, so a still-`pending` account flips to `active`. The
        # flip is idempotent — a no-op patch is a success.
        account = Helpers.find_account_by_id(db, account_id)
        if account && account[:status] == "pending"
          status_patch = AccountPatch.call(db, account_id, {"status" => JSON::Any.new("active")})
          return status_patch if status_patch.is_a?(Facet::ServiceError)
        end

        # 8. Emit the session the login withheld.
        result = SessionEmit.call(db, account_id, token.active_role, token.cookie_requested)
        return result if result.is_a?(Facet::ServiceError)

        # 9. Mint the single-use backup codes — the enrollment completed, so
        # the recovery set rides on this response and is shown exactly once.
        generated = BackupCodes.generate(db, account_id)
        TokensEmitted.new(result: result, backup_codes: generated.codes)
      end

      # ── Private ──────────────────────────────────────────────────────

      # Handles an invalid TOTP code by decrementing attempts and possibly
      # locking out — mirrors `Challenge.handle_invalid_code`.
      private def self.handle_invalid_code(
        enroll_token : String,
        db : DB::Connection,
        account_id : String,
      ) : Facet::ServiceError
        remaining = EnrollToken.decrement_enroll_attempts(enroll_token)
        if remaining <= 0
          EnrollToken.delete_enroll_token(enroll_token)
          LoginThrottle.set_lockout(account_id)
          Helpers.write_login_event(db, account_id, "lockout", "MFA enrollment lockout: too many attempts")
          return Facet::ServiceError.new(429, "Too many attempts. Account locked.")
        end
        noun = remaining == 1 ? "attempt" : "attempts"
        Facet::ServiceError.new(401, "Invalid code. #{remaining} #{noun} remaining.")
      end
    end
  end
end
