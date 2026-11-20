# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::PasswordReset do
  around_each do |example|
    redis_cleanup
    Facet::BaseEmail.reset_configuration!
    begin
      example.run
    ensure
      redis_cleanup
    end
  end

  # ── Request flow ────────────────────────────────────────────────────

  describe ".request" do
    it "writes a reset-slot token when the account exists with a password" do
      with_db do |db|
        account_id = create_test_account(db, email: "reset@example.com")

        result = Facet::IAM::PasswordReset.request(
          db, "reset@example.com", "https://example.test/ResetPassword"
        )
        result.should be_a(Facet::IAM::PasswordReset::Requested)

        reset_slot_exists?(db, account_id).should be_true
      end
    end

    it "returns Requested even when the email does not exist (no enumeration)" do
      with_db do |db|
        result = Facet::IAM::PasswordReset.request(
          db, "nope@example.com", "https://example.test/ResetPassword"
        )
        result.should be_a(Facet::IAM::PasswordReset::Requested)
      end
    end

    it "is a silent no-op for an account without a password slot" do
      with_db do |db|
        account_id = create_test_account(db, email: "pending@example.com", status: "pending")
        Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")

        result = Facet::IAM::PasswordReset.request(
          db, "pending@example.com", "https://example.test/ResetPassword"
        )
        result.should be_a(Facet::IAM::PasswordReset::Requested)

        # No token written, no event — the link would never confirm.
        reset_slot_exists?(db, account_id).should be_false
        login_events(db).should_not contain("password_reset_requested")
      end
    end

    it "is a silent no-op for a service account (no email, no token)" do
      with_db do |db|
        service_id = create_service_account(db, "svc@example.com")

        body = capture_stdout do
          result = Facet::IAM::PasswordReset.request(
            db, "svc@example.com", "https://example.test/ResetPassword"
          )
          result.should be_a(Facet::IAM::PasswordReset::Requested)
        end

        # Nothing delivered — the email body never left the process.
        body.should_not contain("Reset your Facet password")
        reset_slot_exists?(db, service_id).should be_false
        login_events(db).should_not contain("password_reset_requested")
      end
    end

    it "normalizes the email (strips and lowercases) before lookup" do
      with_db do |db|
        account_id = create_test_account(db, email: "case@example.com")

        result = Facet::IAM::PasswordReset.request(
          db, "  CASE@example.com  ", "https://example.test/ResetPassword"
        )
        result.should be_a(Facet::IAM::PasswordReset::Requested)
        reset_slot_exists?(db, account_id).should be_true
      end
    end

    it "writes a password_reset_requested LoginEvent" do
      with_db do |db|
        create_test_account(db, email: "audit@example.com")

        Facet::IAM::PasswordReset.request(
          db, "audit@example.com", "https://example.test/ResetPassword"
        )

        login_events(db).should contain("password_reset_requested")
      end
    end

    it "states the effective TTL in the email copy, not a hardcoded duration (B-90)" do
      with_db do |db|
        create_test_account(db, email: "validity@example.com")

        body = capture_stdout do
          Facet::IAM::PasswordReset.request(
            db, "validity@example.com", "https://example.test/ResetPassword"
          )
        end

        # config.test.yml sets `iam.change_password_expiration: 3600` — the
        # email must render the TTL derived from that setting.
        expected = Facet::IAM::Helpers.link_validity_text(
          Facet::IAM::Config.change_password_expiration)
        body.should contain("This link expires in #{expected}.")
      end
    end
  end

  # ── Confirm flow ────────────────────────────────────────────────────

  describe ".confirm" do
    it "resets the password when the token and new password are valid" do
      with_db do |db|
        account_id = create_test_account(db, email: "reset@example.com", password: "old-password-1")
        reset_token = mint_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        result.should be_a(Facet::IAM::PasswordReset::Confirmed)

        # Verify the new password works on login.
        login_result = Facet::IAM::Login.call(db, email: "reset@example.com", password: "new-password-1", cookie: false)
        login_result.should be_a(Facet::IAM::Login::TokensEmitted)

        # The old password should no longer work.
        old_login = Facet::IAM::Login.call(db, email: "reset@example.com", password: "old-password-1", cookie: false)
        old_login.should be_a(Facet::ServiceError)
      end
    end

    it "rejects an unknown token" do
      with_db do |db|
        create_test_account(db, email: "reset@example.com")

        result = Facet::IAM::PasswordReset.confirm(db, "totally-fake-token", "new-password-1")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(401)
      end
    end

    it "rejects an expired token" do
      with_db do |db|
        account_id = create_test_account(db, email: "reset@example.com")
        reset_token = mint_reset_token(db, account_id)
        expire_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(401)
      end
    end

    it "rejects a new password shorter than 8 characters without consuming the token" do
      with_db do |db|
        account_id = create_test_account(db, email: "reset@example.com")
        reset_token = mint_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "short")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)

        # Token should still be usable — short-password is a client error,
        # not a consumption event.
        result2 = Facet::IAM::PasswordReset.confirm(db, reset_token, "valid-password-1")
        result2.should be_a(Facet::IAM::PasswordReset::Confirmed)
      end
    end

    it "is single-use: a token cannot be consumed twice" do
      with_db do |db|
        account_id = create_test_account(db, email: "reset@example.com")
        reset_token = mint_reset_token(db, account_id)

        r1 = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        r1.should be_a(Facet::IAM::PasswordReset::Confirmed)

        r2 = Facet::IAM::PasswordReset.confirm(db, reset_token, "another-password-1")
        r2.should be_a(Facet::ServiceError)
        err = r2.as(Facet::ServiceError)
        err.status.should eq(401)
      end
    end

    it "writes a password_reset_used LoginEvent on a non-first confirm" do
      with_db do |db|
        account_id = create_test_account(db, email: "audit@example.com")
        reset_token = mint_reset_token(db, account_id)

        Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")

        login_events(db).should contain("password_reset_used")
      end
    end

    it "emits a session and flips status on the first-credential path" do
      with_db do |db|
        account_id = create_test_account(db, email: "invite@example.com", status: "pending")
        # A first-invite account holds no `password` slot yet.
        Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
        reset_token = mint_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        result.should be_a(Facet::IAM::PasswordReset::SessionStarted)
        session = result.as(Facet::IAM::PasswordReset::SessionStarted)
        session.account_id.should eq(account_id)
        session.result.access_token.should_not be_empty
        session.result.refresh_token.should_not be_empty

        # The account is now active with its first credential.
        status = db.query_one(
          "SELECT content->>'status' FROM projections WHERE id = $1",
          account_id, as: String
        )
        status.should eq("active")

        must_change_pw = db.query_one(
          "SELECT COALESCE((content->>'must_change_pw')::boolean, false) FROM projections WHERE id = $1",
          account_id, as: Bool
        )
        must_change_pw.should be_false

        login_events(db).should contain("invite_accepted")
      end
    end

    it "holds the first-credential confirm at enrollment under always (B-141)" do
      with_mfa_enforcement("always") do
        with_db do |db|
          account_id = create_test_account(db, email: "held@example.com", status: "pending", mfa_enabled: false)
          # A first-invite account holds no `password` slot yet.
          Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
          reset_token = mint_reset_token(db, account_id)

          result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
          result.should be_a(Facet::IAM::PasswordReset::EnrollmentHeld)
          held = result.as(Facet::IAM::PasswordReset::EnrollmentHeld)
          held.account_id.should eq(account_id)

          # The credential is set and the account is active — but no session
          # exists. The invite itself is accepted (audit), and the sign-in
          # that follows holds at the enrollment step.
          status = db.query_one(
            "SELECT content->>'status' FROM projections WHERE id = $1",
            account_id, as: String
          )
          status.should eq("active")
          login_events(db).should contain("invite_accepted")

          login = Facet::IAM::Login.call(db, email: "held@example.com", password: "new-password-1", cookie: false)
          login.should be_a(Facet::IAM::Login::EnrollmentRequired)
        end
      end
    end

    it "keeps emitting the first-credential session under preferred" do
      with_mfa_enforcement("preferred") do
        with_db do |db|
          account_id = create_test_account(db, email: "preferred@example.com", status: "pending", mfa_enabled: false)
          Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
          reset_token = mint_reset_token(db, account_id)

          result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
          result.should be_a(Facet::IAM::PasswordReset::SessionStarted)
        end
      end
    end

    it "emits a session under the anonymous role for a roleless invitee (B-120)" do
      with_db do |db|
        # The anonymous role is a production seed; the lighter `seed_test_roles`
        # does not create it, so seed the full role set first.
        ensure_seed_roles_with_dependencies(db)
        account_id = create_test_account(db, email: "norole@example.com", status: "pending",
          roles: [] of String, default_role: nil)
        # A first-invite account holds no `password` slot yet.
        Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
        reset_token = mint_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        result.should be_a(Facet::IAM::PasswordReset::SessionStarted)
        session = result.as(Facet::IAM::PasswordReset::SessionStarted)
        session.account_id.should eq(account_id)
        session.result.active_role.should eq(Facet::IAM::ANONYMOUS_ROLE_ID)
        session.result.available_roles.should be_empty
        session.result.access_token.should_not be_empty

        # The invite is accepted: the account is active and the token is spent.
        status = db.query_one(
          "SELECT content->>'status' FROM projections WHERE id = $1",
          account_id, as: String
        )
        status.should eq("active")
        login_events(db).should contain("invite_accepted")
      end
    end

    it "keeps the no-session rule and status on an existing-credential confirm" do
      with_db do |db|
        account_id = create_test_account(db, email: "existing@example.com", status: "suspended")
        reset_token = mint_reset_token(db, account_id)

        result = Facet::IAM::PasswordReset.confirm(db, reset_token, "new-password-1")
        result.should be_a(Facet::IAM::PasswordReset::Confirmed)

        status = db.query_one(
          "SELECT content->>'status' FROM projections WHERE id = $1",
          account_id, as: String
        )
        status.should eq("suspended")
      end
    end
  end

  # ── Convergence with the invite flow ────────────────────────────────

  describe "convergence with Invite" do
    it "clears a pending invite link when a temporary password is generated" do
      with_db do |db|
        account_id = create_test_account(db, email: "conv@example.com")
        Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")

        sent = Facet::IAM::Invite.send_invite(db, account_id)
        sent.should be_a(Facet::IAM::Invite::InviteSent)
        reset_slot_exists?(db, account_id).should be_true

        generated = Facet::IAM::Invite.generate_temporary_password(db, account_id)
        generated.should be_a(Facet::IAM::Invite::Generated)

        reset_slot_exists?(db, account_id).should be_false
      end
    end

    it "keeps the temporary password usable when an invite is sent afterwards" do
      with_db do |db|
        account_id = create_test_account(db, email: "conv2@example.com")

        generated = Facet::IAM::Invite.generate_temporary_password(db, account_id)
        temp_password = generated.as(Facet::IAM::Invite::Generated).password

        sent = Facet::IAM::Invite.send_invite(db, account_id)
        sent.should be_a(Facet::IAM::Invite::InviteSent)

        login_result = Facet::IAM::Login.call(db, email: "conv2@example.com", password: temp_password, cookie: false)
        login_result.should be_a(Facet::IAM::Login::PasswordChangeRequired)

        must_change_pw = db.query_one(
          "SELECT COALESCE((content->>'must_change_pw')::boolean, false) FROM projections WHERE id = $1",
          account_id, as: Bool
        )
        must_change_pw.should be_true
      end
    end
  end

  # ── Helpers (shared reset-token helpers live in spec/support/iam_helper.cr)
end
