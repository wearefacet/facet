# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "../database"
require "../emails/password_reset_email"
require "../error"
require "../secrets/store"

module Facet
  module IAM
    # Password reset flow: request → email link → confirm with new password.
    #
    # Tokens live on the `reset` slot of the `secrets` store — the same slot
    # the invite flow uses — with a TTL of `iam.change_password_expiration`
    # (default 24h). The store digests the raw token (SHA-256); only the
    # email ever sees the raw value. The link sent by email contains the
    # token; the frontend renders the reset form and POSTs to
    # `/Api/iam/password-reset/confirm`.
    #
    # Reset tokens are single-use: `Secrets.consume` is one atomic
    # `DELETE … RETURNING`, so zero rows means missing, expired, or already
    # used — the caller fails closed.
    #
    # The request endpoint is anti-enumeration: it always returns `Requested`
    # (HTTP 200 with `{ok: true}`) whether or not the email exists in the
    # system. A link is sent only when the account exists **and** holds a
    # `password` slot — a credential-less account (first-invite pending, or a
    # service account) would receive a link whose confirm can never succeed,
    # so the request is a silent no-op for it.
    #
    # Convergence: a confirm on a first-invite account sets the
    # first credential and auto-logs the recipient in — the account flips to
    # `active` and a session is emitted in the response. Under MFA
    # enforcement `always` an un-enrolled account gets no session: the
    # invitee signs in and is held at the enrollment step (B-141). An
    # account that already holds a password keeps the no-session rule.
    module PasswordReset
      record Requested

      record Confirmed,
        account_id : String

      # First-credential confirm: a session was emitted alongside the
      # standard token response body.
      record SessionStarted,
        account_id : String,
        result : TokenEmitter::Result

      # First credential under the `always` enrollment hold (B-141): the
      # password is set and the account is active, but no session was
      # emitted. The invitee signs in, and the login pipeline holds at the
      # enrollment step — the same hold every un-enrolled login sees.
      record EnrollmentHeld,
        account_id : String

      # ── Request ─────────────────────────────────────────────────────

      # Handles `POST /Api/iam/password-reset/request`.
      #
      # Always returns `Requested` — even when `email` does not match any
      # account, the caller can't tell. When the account exists and holds a
      # `password` slot, a `reset`-slot token is written and a
      # `PasswordResetEmail` is delivered.
      def self.request(
        db : DB::Connection,
        email : String,
        reset_link_base : String,
      ) : Requested | Facet::ServiceError
        normalized = email.strip.downcase
        account = Helpers.find_account_by_email(db, normalized)

        # Only deliver when the account exists and can actually confirm —
        # it must hold a `password` slot. Otherwise silently succeed: the
        # endpoint stays anti-enumeration, and a credential-less account
        # never receives a dead link.
        if account && !account[:service_account] && Helpers.password_slot_exists?(db, account[:id])
          ttl = Policy.change_password_expiration(db)
          token = Random::Secure.hex(32)
          Secrets.set(db, "iam.Account.#{account[:id]}", "reset", token,
            mode: "token", set_by: account[:id], ttl: ttl.seconds)
          reset_link = "#{reset_link_base}?token=#{token}"

          PasswordResetEmail.new(account[:email], account[:display_name], reset_link,
            Helpers.link_validity_text(ttl)).deliver

          Helpers.write_login_event(db, account[:id], "password_reset_requested")
        end

        Requested.new
      end

      # ── Confirm ─────────────────────────────────────────────────────

      # Handles `POST /Api/iam/password-reset/confirm`.
      #
      # Enforces the minimum password length before touching the token
      # (a client error must not consume the link), then consumes the
      # `reset` slot — single-use, TTL-checked in the same atomic statement.
      # `consumed.doc_id` is the account id.
      #
      # When the account held no `password` slot (first credential via an
      # operator invite), the account flips `pending → active` and a session
      # is emitted with the token response — `cookie` controls the response
      # mode exactly like login (cookie jar vs. tokens in body). Under MFA
      # enforcement `always` with an un-enrolled account the session is
      # withheld — the result is `EnrollmentHeld`, and the sign-in that
      # follows holds at the enrollment step (B-141). Otherwise no session
      # is issued — the account logs in with the new password.
      def self.confirm(
        db : DB::Connection,
        token : String,
        new_password : String,
        cookie : Bool = true,
      ) : Confirmed | SessionStarted | EnrollmentHeld | Facet::ServiceError
        return Facet::ServiceError.new(422, "New password must be at least 8 characters") if new_password.size < 8

        consumed = Secrets.consume(db, "reset", token, domain: "iam")
        return Facet::ServiceError.new(401, "Reset token is invalid or expired") unless consumed
        return Facet::ServiceError.new(401, "Reset token is invalid or expired") unless consumed.domain == "iam" && consumed.doc_type == "Account"

        account_id = consumed.doc_id
        doc_ref = "iam.Account.#{account_id}"

        first_invite = false
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          # Detect the first-credential state before the write — the slot
          # presence check must see the account as it was.
          first_invite = !Helpers.password_slot_exists?(txn, account_id)

          Secrets.set(txn, doc_ref, "password", new_password,
            mode: "hash", set_by: account_id)
          # The clear is by design (B-195): the person at this form chose
          # the password, so the forced-change gate has nothing left to
          # force. An admin-set `must_change_pw` is cleared on this path
          # too — see the first-credential paragraph in doc/backend/iam.md.
          AccountPatch.call(txn, account_id, {"must_change_pw" => JSON::Any.new(false)})
          # The pending link is already gone — the consume above deleted the
          # row. A password write on a first-invite account completes the
          # bootstrap: the status flip is idempotent (no-op patch is a
          # success), so a re-confirm never re-writes it.
          if first_invite
            AccountPatch.call(txn, account_id, {"status" => JSON::Any.new("active")})
          end
        end

        if first_invite
          # The `always` enrollment hold (B-141): an un-enrolled account gets
          # no session here. The invitee signs in with the password they set,
          # and the login pipeline holds at the enrollment step. The invite
          # itself is accepted — the credential is set and the account is
          # active — so the audit event is the same on both sides.
          account = Helpers.find_account_by_id(db, account_id)
          if account && Policy.enroll_hold?(db, account[:mfa_enabled])
            Helpers.write_login_event(db, account_id, "invite_accepted",
              "First credential set; no session — held at MFA enrollment (always)")
            return EnrollmentHeld.new(account_id: account_id)
          end

          # Flip before the session is issued — the emitted tokens are for
          # an `active` account. No role is elected: `SessionEmit` resolves
          # it like a login (default_role → first assigned) and falls back
          # to the anonymous role when the account holds no usable role
          # (B-120), so a roleless invitee still gets a session.
          emitted = SessionEmit.call(db, account_id, nil, cookie)
          return emitted if emitted.is_a?(Facet::ServiceError)

          Helpers.write_login_event(db, account_id, "invite_accepted")
          SessionStarted.new(account_id: account_id, result: emitted)
        else
          Helpers.write_login_event(db, account_id, "password_reset_used")
          Confirmed.new(account_id: account_id)
        end
      end
    end
  end
end
