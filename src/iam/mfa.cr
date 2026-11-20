# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "redis"
require "../database"
require "../error"
require "../secrets/store"
require "./policy"

module Facet
  module IAM
    # Handles MFA enrollment, verification, and disable.
    #
    # The TOTP seed lives in the `mfa` slot of the account's secret store
    # row (mode `sealed`, `meta.mfa_type = "totp"`) — encrypted at rest.
    # The `mfa_enabled` flag is the account document field; it flips through
    # `AccountPatch` so the change is event-sourced like any other content.
    module MFA
      # Maximum invalid TOTP attempts before the enroll-verify endpoint returns 429.
      # Matches the login-challenge limiter (5 attempts).
      MFA_VERIFY_ATTEMPTS = 5

      record SetupResult,
        secret : String,
        otpauth_uri : String

      record VerifyResult,
        backup_codes : Array(String)

      # ── Setup (provisional) ──────────────────────────────────────────

      # Generates a provisional TOTP secret and stores it.
      # Does NOT enable MFA — that happens after `verify` confirms the secret
      # round-trips.
      #
      # Returns a `SetupResult` with the base32 secret and `otpauth://` URI.
      #
      # Refuses when the effective policy turns MFA off (`iam.mfa.type:
      # none`) — the whole factor is unavailable, not just the login gates
      # (`422`; the type gate used to read the config boolean and answer
      # `403`).
      def self.setup(
        db : DB::Connection,
        account_id : String,
        account_name : String,
      ) : SetupResult | Facet::ServiceError
        unless Policy.mfa_type(db) == "totp"
          return Facet::ServiceError.new(422, "MFA is disabled on this server")
        end

        secret = TOTP.generate_secret
        uri = TOTP.otpauth_uri(secret, account_name, Config.mfa.totp.issuer)

        # Store provisionally in the `mfa` slot — a slot write only, no
        # document mutation (`mfa_enabled` stays untouched until verify).
        Secrets.set(db, "iam.Account.#{account_id}", "mfa", secret,
          mode: "sealed", set_by: account_id, meta: {"mfa_type" => "totp"})

        SetupResult.new(secret: secret, otpauth_uri: uri)
      end

      # ── Verify (enable) ──────────────────────────────────────────────

      # Verifies a TOTP code against the sealed `mfa` slot and enables MFA.
      #
      # On success, flips the account document's `mfa_enabled` field, writes
      # a `mfa_enabled` event, and mints the account's single-use backup
      # codes — the raw codes travel in the result and are shown exactly
      # once (`VerifyResult#backup_codes`).
      #
      # Brute-force protection: a Redis-backed attempt counter
      # (`mfa_verify_attempts:{account_id}`) caps invalid tries at 5 within a
      # 5-minute window, matching the login-challenge limiter.
      def self.verify(
        db : DB::Connection,
        account_id : String,
        code : String,
      ) : VerifyResult | Facet::ServiceError
        # 1. Brute-force guard — short-circuit before TOTP computation.
        if LoginThrottle.get_mfa_verify_attempts(account_id) >= MFA_VERIFY_ATTEMPTS
          return Facet::ServiceError.new(429, "Too many attempts. Please try again later.")
        end

        doc_ref = "iam.Account.#{account_id}"
        mfa_secret = Secrets.reveal(db, doc_ref, "mfa")
        if mfa_secret.nil?
          # A missing account and a missing slot both surface as nil from
          # reveal — separate them so the status codes stay as before.
          if Helpers.find_account_by_id(db, account_id).nil?
            return Facet::ServiceError.new(404, "Account not found")
          end
          return Facet::ServiceError.new(400, "No MFA secret configured. Run setup first.")
        end

        mfa_config = Config.mfa.totp
        step = TOTP.validate(mfa_secret, code, window: mfa_config.window)

        if step.nil?
          remaining = record_mfa_verify_failure(account_id)
          if remaining <= 0
            return Facet::ServiceError.new(429, "Too many attempts. Please try again later.")
          end
          return Facet::ServiceError.new(401, "Invalid code")
        end

        # 2. Atomically advance the replay guard. 0 rows affected means a
        # concurrent request already consumed this step (replay) — guard
        # first, so a replay writes nothing.
        unless AuthState.try_advance_totp_step(db, doc_ref, step)
          return Facet::ServiceError.new(401, "Code already used")
        end

        # 3. Flip the account document field.
        AccountPatch.call(db, account_id, {"mfa_enabled" => JSON::Any.new(true)})

        LoginThrottle.reset_mfa_verify_attempts(account_id)
        Helpers.write_login_event(db, account_id, "mfa_enabled")

        # 4. Mint the single-use backup codes — the advertised self-recovery
        # path for a lost authenticator. A fresh set replaces any previous
        # one, so a re-verified enrollment rotates the codes.
        generated = BackupCodes.generate(db, account_id)
        VerifyResult.new(backup_codes: generated.codes)
      end

      # Records a failed MFA verify attempt and returns the remaining attempts.
      # Returns 0 when the limit has been reached (no further attempts allowed).
      private def self.record_mfa_verify_failure(account_id : String) : Int32
        count = LoginThrottle.increment_mfa_verify_attempts(account_id)
        MFA_VERIFY_ATTEMPTS - count
      end

      # ── Disable (admin recovery) ────────────────────────────────────

      # Disables MFA for an account. This is the recovery path — clears the
      # `mfa` slot, resets the TOTP step counter, deletes any backup codes,
      # and flips the account document's `mfa_enabled` field to false. The
      # account's next login is MFA-less and the frontend forces re-enrollment.
      #
      # This is RBAC-gated (admin action). The caller is responsible for
      # authorization.
      def self.disable(
        db : DB::Connection,
        account_id : String,
      ) : Facet::ServiceError?
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          doc_ref = "iam.Account.#{account_id}"
          Secrets.clear(txn, doc_ref, "mfa")
          AuthState.reset_totp_step(txn, doc_ref)
          BackupCodes.clear(txn, account_id)
          AccountPatch.call(txn, account_id, {"mfa_enabled" => JSON::Any.new(false)})
        end
        Helpers.write_login_event(db, account_id, "mfa_disabled")
        nil
      end
    end
  end
end
