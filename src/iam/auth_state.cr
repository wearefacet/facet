# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../secrets/store"

module Facet
  module IAM
    # Volatile operational state for accounts, keyed by document — same
    # storage family as `account_settings`: not a secret, not document data.
    # Lives outside the doctype system because it must never enter the
    # event log and carries no audit value.
    #
    # The `auth_state` table currently holds one column, `last_totp_step`,
    # the TOTP replay guard. Identical semantics to the guard that lived on
    # `auth_secrets` — an atomic conditional advance serialized at the
    # database level.
    module AuthState
      # Advances the TOTP step counter only if `step` is strictly greater
      # than the stored value (or the stored value is NULL).
      #
      # Single statement: an upsert whose `DO UPDATE` carries the guard in
      # its `WHERE`. Returns true when the step was accepted, false on
      # replay (0 rows affected — a concurrent request already consumed an
      # equal or greater step). The row is created on first use.
      def self.try_advance_totp_step(db : DB::Connection, doc_ref : String, step : Int64) : Bool
        ref = Facet::Secrets.resolve(doc_ref)
        result = db.exec(
          <<-SQL,
            INSERT INTO auth_state (domain, doc_type, doc_id, last_totp_step, updated_at)
            VALUES ($1, $2, $3, $4, now())
            ON CONFLICT (domain, doc_type, doc_id) DO UPDATE SET
              last_totp_step = EXCLUDED.last_totp_step,
              updated_at = now()
            WHERE auth_state.last_totp_step IS NULL
               OR auth_state.last_totp_step < EXCLUDED.last_totp_step
          SQL
          ref.domain, ref.doc_type, ref.doc_id, step,
        )
        result.rows_affected > 0
      end

      # Clears the TOTP step counter (MFA disable / recovery path). Mirrors
      # the `last_totp_step = NULL` reset the guard column had on
      # `auth_secrets`. A missing row is a no-op.
      def self.reset_totp_step(db : DB::Connection, doc_ref : String) : Nil
        ref = Facet::Secrets.resolve(doc_ref)
        db.exec(
          "UPDATE auth_state SET last_totp_step = NULL, updated_at = now() " \
          "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3",
          ref.domain, ref.doc_type, ref.doc_id,
        )
      end
    end
  end
end
