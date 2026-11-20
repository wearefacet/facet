# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "json"
require "../database"
require "../error"
require "../secrets/store"
require "../emails/invite_email"
require "./account_patch"

module Facet
  module IAM
    # Credential bootstrap for invited accounts — the operator-side services
    # behind `POST /Api/iam/accounts/:id/temporary-password` and
    # `POST /Api/iam/accounts/:id/invite`.
    #
    # The two paths converge: a temporary password clears any
    # pending invite link, and a new invite replaces the previous link so a
    # stale email can never outlive the credential flow that created it.
    # The plaintext temporary password is returned exactly once by the route
    # — it is never stored in plaintext, never emailed, and never logged.
    module Invite
      # Crockford Base32 without the `0/O` and `1/I` confusions: the shared
      # `CROCKFORD` alphabet still contains `0` and `1`, so the temporary
      # password uses these 30 symbols — safe to read aloud or type.
      TEMP_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"

      record Generated,
        password : String

      record InviteSent,
        first_invite : Bool

      record CredentialState,
        id : String,
        has_password : Bool,
        must_change_pw : Bool,
        mfa_enabled : Bool,
        invite_pending : Bool,
        federated : Bool

      # ── Temporary password ──────────────────────────────────────────

      # Generates a 16-character temporary password (4 groups of 4, dashed),
      # stores its bcrypt hash on the `password` slot, forces a change on
      # next login, and clears any pending invite link — all in one
      # transaction. Returns the plaintext for the one-time reveal.
      #
      # Rejected (422) for a missing account, a service account, and
      # `disabled` / `suspended` accounts — a password the recipient cannot
      # use is misleading.
      def self.generate_temporary_password(
        db : DB::Connection,
        account_id : String,
        set_by : String = "system",
      ) : Generated | Facet::ServiceError
        account = Helpers.find_account_by_id(db, account_id)
        return Facet::ServiceError.new(422, "Account not found") if account.nil?
        return Facet::ServiceError.new(422, "Service accounts cannot hold a password") if account[:service_account]
        return Facet::ServiceError.new(422, "Account is #{account[:status]}") if account[:status] == "disabled" || account[:status] == "suspended"

        password = generate_password
        doc_ref = "iam.Account.#{account_id}"

        Database.with_transaction(db, ignore_if_set: true) do |txn|
          Secrets.set(txn, doc_ref, "password", password, mode: "hash", set_by: set_by)
          AccountPatch.call(txn, account_id, {"must_change_pw" => JSON::Any.new(true)})
          # Convergence rule: a password write clears any pending invite
          # link in the same transaction — a slot write never touches
          # another slot, so the clear must be explicit.
          Secrets.clear(txn, doc_ref, "reset")
        end

        # The `details` field never carries the plaintext password.
        Helpers.write_login_event(db, account_id, "temp_password_generated")

        Generated.new(password: password)
      end

      # ── Invite link ─────────────────────────────────────────────────

      # Mints a single-use reset token, stores it on the `reset` slot with
      # the configured TTL, and emails the invite link. A second invite
      # upserts the slot, so the previous email's link dies immediately.
      #
      # Rejected (422) for a missing or service account. `suspended` is
      # allowed — the operator may bring the account back through the
      # invite. Returns `first_invite` (true when the account held no
      # `password` slot before the call) so the UI can label the button.
      def self.send_invite(
        db : DB::Connection,
        account_id : String,
        set_by : String = "system",
      ) : InviteSent | Facet::ServiceError
        account = Helpers.find_account_by_id(db, account_id)
        return Facet::ServiceError.new(422, "Account not found") if account.nil?
        return Facet::ServiceError.new(422, "Service accounts cannot be invited") if account[:service_account]

        first_invite = !Helpers.password_slot_exists?(db, account_id)

        token = Random::Secure.hex(32)
        ttl = Policy.change_password_expiration(db)
        Secrets.set(db, "iam.Account.#{account_id}", "reset", token,
          mode: "token", set_by: set_by, ttl: ttl.seconds)

        invite_link = "#{Facet::Config.instance.scheme_base_url}/ResetPassword?token=#{token}"
        InviteEmail.new(account[:email], account[:display_name], invite_link,
          Helpers.link_validity_text(ttl)).deliver

        # No token material in `details` — the link lives only in the email.
        Helpers.write_login_event(db, account_id, "invite_sent")

        InviteSent.new(first_invite: first_invite)
      end

      # ── Credential states ───────────────────────────────────────────

      # One credential-state entry per requested account id — the read
      # behind `GET /Api/iam/accounts/credential-states` (the admin
      # table). One SQL query LEFT JOINs `secrets` twice (once per slot);
      # ids with no live account row are skipped.
      #
      # `federated` reads the account's `federated_identities` array — the
      # field is written by the inbound-OIDC flow and is absent (hence
      # `false`) for every account until a link exists.
      def self.credential_states(db : DB::Connection, account_ids : Array(String)) : Array(CredentialState)
        return [] of CredentialState if account_ids.empty?

        db.query_all(
          <<-SQL,
            SELECT p.id,
                   (pw.doc_id IS NOT NULL)                            AS has_password,
                   COALESCE((p.content->>'must_change_pw')::boolean, false) AS must_change_pw,
                   COALESCE((p.content->>'mfa_enabled')::boolean, false)    AS mfa_enabled,
                   (rs.doc_id IS NOT NULL)                            AS invite_pending,
                   COALESCE(jsonb_array_length(p.content->'federated_identities'), 0) > 0 AS federated
            FROM projections p
            LEFT JOIN secrets pw
              ON pw.domain = 'iam' AND pw.doc_type = 'Account' AND pw.doc_id = p.id AND pw.slot = 'password'
            LEFT JOIN secrets rs
              ON rs.domain = 'iam' AND rs.doc_type = 'Account' AND rs.doc_id = p.id AND rs.slot = 'reset'
             AND rs.mode = 'token' AND rs.expires_at > now()
            WHERE p.domain = 'iam' AND p.doc_type = 'Account'
              AND p.deleted_at IS NULL
              AND p.id = ANY($1)
          SQL
          account_ids,
        ) do |rs|
          CredentialState.new(
            id: rs.read(String),
            has_password: rs.read(Bool),
            must_change_pw: rs.read(Bool),
            mfa_enabled: rs.read(Bool),
            invite_pending: rs.read(Bool),
            federated: rs.read(Bool),
          )
        end
      end

      # 16 characters over the 30-symbol alphabet, joined as 4 groups of 4
      # with dashes (e.g. `K7M4-9XQ2-WBTD-H3PN`). `Random::Secure.rand(30)`
      # is uniform — do not use the 32-symbol byte-mask trick here.
      #
      # Shared one-time credential generator: the invite flow and the
      # first-admin bootstrap (`Seed.seed_admin`) both use it, so an
      # operator always reads the same password shape.
      def self.generate_password : String
        Array.new(4) do
          String.build(4) do |s|
            4.times { s << TEMP_ALPHABET[Random::Secure.rand(TEMP_ALPHABET.size)] }
          end
        end.join("-")
      end

      # ── Private ──────────────────────────────────────────────────────
    end
  end
end
