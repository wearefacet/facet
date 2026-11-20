# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "digest"
require "../database"

module Facet
  module IAM
    # Single-use MFA backup codes — the self-recovery path for a lost
    # authenticator.
    #
    # A fresh set is minted every time a TOTP enrollment completes (the
    # session-based `MFA.verify` and the enroll-at-login `Enroll.verify`).
    # The raw codes are returned once and shown to the account; only the
    # SHA-256 digest of the normalized code is stored, in the dedicated
    # `mfa_backup_codes` table (the same secret-storage precedent as
    # `api_keys` — the values never enter the event log). Consumption is
    # one atomic UPDATE that only matches rows still unused, so a code
    # works exactly once; the challenge limiter punishes wrong guesses.
    module BackupCodes
      # Codes per set.
      COUNT = 10

      # Random hex characters per code (32 bits). Combined with the
      # challenge limiter (5 bad answers delete the challenge and lock the
      # account) this keeps online guessing impractical while staying
      # typable from paper.
      HEX_LENGTH = 8

      record Generated,
        codes : Array(String)

      # ── Generate ─────────────────────────────────────────────────────

      # Replaces the account's codes with a fresh set and returns the raw
      # codes in their display form (`xxxx-xxxx`). The plaintext is never
      # stored — regeneration makes the previous set unusable.
      def self.generate(db : DB::Connection, account_id : String) : Generated
        codes = [] of String
        Database.with_transaction(db) do |txn|
          txn.exec("DELETE FROM mfa_backup_codes WHERE account_id = $1", account_id)
          COUNT.times do
            raw = Random::Secure.hex(HEX_LENGTH // 2)
            codes << display_form(raw)
            txn.exec(
              "INSERT INTO mfa_backup_codes (account_id, code_hash) VALUES ($1, $2)",
              account_id,
              digest(raw),
            )
          end
        end
        Generated.new(codes: codes)
      end

      # ── Consume ──────────────────────────────────────────────────────

      # Consumes one code. Returns true when the code matched a still-unused
      # row — the `used_at IS NULL` predicate in the same statement makes
      # the single-use property atomic, with no read-then-write race.
      def self.consume(db : DB::Connection, account_id : String, candidate : String) : Bool
        normalized = normalize(candidate)
        return false if normalized.empty?

        result = db.exec(
          "UPDATE mfa_backup_codes SET used_at = now() " \
          "WHERE account_id = $1 AND code_hash = $2 AND used_at IS NULL",
          account_id,
          digest(normalized),
        )
        result.rows_affected > 0
      end

      # Number of unconsumed codes the account holds.
      def self.remaining(db : DB::Connection, account_id : String) : Int64
        db.query_one(
          "SELECT count(*) FROM mfa_backup_codes WHERE account_id = $1 AND used_at IS NULL",
          account_id,
          as: Int64,
        )
      end

      # Deletes every code for the account (MFA disable, hygiene).
      def self.clear(db : DB::Connection, account_id : String) : Nil
        db.exec("DELETE FROM mfa_backup_codes WHERE account_id = $1", account_id)
      end

      # ── Private ──────────────────────────────────────────────────────

      # Lowers the case and strips every non-alphanumeric character, so the
      # `xxxx-xxxx` display form, a bare `xxxxxxxx`, and any spaced or
      # uppercase typing all hash to the stored digest.
      private def self.normalize(code : String) : String
        code.downcase.gsub(/[^a-z0-9]/, "")
      end

      private def self.display_form(raw : String) : String
        "#{raw[0, 4]}-#{raw[4, 4]}"
      end

      private def self.digest(normalized : String) : String
        Digest::SHA256.hexdigest(normalized)
      end
    end
  end
end
