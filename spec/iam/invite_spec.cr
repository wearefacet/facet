# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

# ── Helpers for Invite specs ────────────────────────────────────────

# Creates a human account WITHOUT a password slot — the state an account is
# in before its first invite. `create_test_account` always seeds a password,
# so the slot is cleared afterwards.
def create_passwordless_account(db, email, status = "pending") : String
  account_id = create_test_account(db, email: email, status: status)
  Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
  account_id
end

# Redirects STDOUT to a temp file for the duration of the block and returns
# what was written. The DevAdapter prints emails to stdout, so this captures
# the delivered email body.
def capture_stdout(&) : String
  STDOUT.flush
  saved_fd = LibC.dup(STDOUT.fd)
  path = File.tempname("spec_email", ".txt")
  file = File.open(path, "w")
  LibC.dup2(file.fd, STDOUT.fd)
  begin
    yield
    STDOUT.flush
  ensure
    LibC.dup2(saved_fd, STDOUT.fd)
    LibC.close(saved_fd)
    file.close
  end
  body = File.read(path)
  File.delete(path) rescue nil
  body
end

# Extracts the raw invite token from a captured email link.
def extract_link_token(email_body : String) : String
  match = email_body.match(%r{/ResetPassword\?token=([0-9a-f]+)})
  raise "no invite link with token found in email" unless match
  match[1]
end

def account_field(db, account_id, field : String) : String?
  db.query_one?("SELECT content->>'#{field}' FROM projections WHERE id = $1", account_id, as: String)
end

describe Facet::IAM::Invite do
  around_each do |example|
    redis_cleanup
    Facet::BaseEmail.reset_configuration!
    begin
      example.run
    ensure
      redis_cleanup
    end
  end

  # ── Temporary password ──────────────────────────────────────────────

  describe ".generate_temporary_password" do
    it "returns a 16-character dashed password over the 30-symbol alphabet" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")

        result = Facet::IAM::Invite.generate_temporary_password(db, account_id)
        password = result.as(Facet::IAM::Invite::Generated).password

        password.should match(/^[2-9A-HJKMNP-TV-Z]{4}(-[2-9A-HJKMNP-TV-Z]{4}){3}$/)
      end
    end

    it "stores a hash that verifies against the returned plaintext" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")

        result = Facet::IAM::Invite.generate_temporary_password(db, account_id)
        password = result.as(Facet::IAM::Invite::Generated).password

        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "password", password).should be_true
      end
    end

    it "forces a password change on next login" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")

        Facet::IAM::Invite.generate_temporary_password(db, account_id)

        account_field(db, account_id, "must_change_pw").should eq("true")
      end
    end

    it "clears any pending reset token" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")
        Facet::IAM::Invite.send_invite(db, account_id)
        reset_slot_exists?(db, account_id).should be_true

        Facet::IAM::Invite.generate_temporary_password(db, account_id)

        reset_slot_exists?(db, account_id).should be_false
      end
    end

    it "never writes the plaintext password into a LoginEvent" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")

        result = Facet::IAM::Invite.generate_temporary_password(db, account_id)
        password = result.as(Facet::IAM::Invite::Generated).password

        events = db.query_all(
          "SELECT content::text FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
          as: String
        )
        events.each do |content|
          content.should_not contain(password)
        end
        login_events(db).should contain("temp_password_generated")
      end
    end

    it "rejects service accounts and disabled/suspended accounts" do
      with_db do |db|
        service_id = create_service_account(db, "svc@example.com")
        disabled_id = create_test_account(db, email: "disabled@example.com", status: "disabled")
        suspended_id = create_test_account(db, email: "suspended@example.com", status: "suspended")

        [service_id, disabled_id, suspended_id].each do |account_id|
          result = Facet::IAM::Invite.generate_temporary_password(db, account_id)
          result.should be_a(Facet::ServiceError)
          result.as(Facet::ServiceError).status.should eq(422)
        end
      end
    end

    it "regenerates a different password on a second call (upsert path)" do
      with_db do |db|
        account_id = create_test_account(db, email: "temp@example.com")

        first = Facet::IAM::Invite.generate_temporary_password(db, account_id).as(Facet::IAM::Invite::Generated).password
        second = Facet::IAM::Invite.generate_temporary_password(db, account_id).as(Facet::IAM::Invite::Generated).password

        first.should_not eq(second)
        # The stored hash matches the newest password only.
        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "password", second).should be_true
        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "password", first).should be_false
      end
    end
  end

  # ── Invite link ─────────────────────────────────────────────────────

  describe ".send_invite" do
    it "reports first_invite true when no password slot existed" do
      with_db do |db|
        account_id = create_passwordless_account(db, "invite@example.com")

        result = Facet::IAM::Invite.send_invite(db, account_id)
        result.as(Facet::IAM::Invite::InviteSent).first_invite.should be_true
      end
    end

    it "reports first_invite false when a password slot exists" do
      with_db do |db|
        account_id = create_test_account(db, email: "invite@example.com")

        result = Facet::IAM::Invite.send_invite(db, account_id)
        result.as(Facet::IAM::Invite::InviteSent).first_invite.should be_false
      end
    end

    it "stores only the digest on the reset slot and emails the raw token" do
      with_db do |db|
        account_id = create_test_account(db, email: "invite@example.com")

        body = capture_stdout { Facet::IAM::Invite.send_invite(db, account_id) }
        token = extract_link_token(body)

        # The link is a fully-qualified URL over the configured base.
        body.should contain("/ResetPassword?token=#{token}")

        # The value column holds the SHA-256 digest — never the raw token.
        row = db.query_one(
          "SELECT mode, value FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
          account_id, as: {String, String}
        )
        row[0].should eq("token")
        row[1].should_not eq(token)
        # The digest matches the emailed raw token.
        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "reset", token).should be_true
      end
    end

    it "states the effective TTL in the email copy, not a hardcoded duration (B-90)" do
      with_db do |db|
        account_id = create_test_account(db, email: "validity@example.com")

        body = capture_stdout { Facet::IAM::Invite.send_invite(db, account_id) }

        # config.test.yml sets `iam.change_password_expiration: 3600` — the
        # email must render the TTL derived from that setting.
        expected = Facet::IAM::Helpers.link_validity_text(
          Facet::IAM::Config.change_password_expiration)
        body.should contain("expires in #{expected}.")
      end
    end

    it "replaces the pending link on a second invite (old link dead)" do
      with_db do |db|
        account_id = create_test_account(db, email: "invite@example.com")

        body1 = capture_stdout { Facet::IAM::Invite.send_invite(db, account_id) }
        token1 = extract_link_token(body1)

        body2 = capture_stdout { Facet::IAM::Invite.send_invite(db, account_id) }
        token2 = extract_link_token(body2)

        token1.should_not eq(token2)
        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "reset", token1).should be_false
        Facet::Secrets.verify(db, "iam.Account.#{account_id}", "reset", token2).should be_true
      end
    end

    it "rejects service accounts and accepts suspended accounts" do
      with_db do |db|
        service_id = create_service_account(db, "svc@example.com")
        result = Facet::IAM::Invite.send_invite(db, service_id)
        result.should be_a(Facet::ServiceError)
        result.as(Facet::ServiceError).status.should eq(422)

        suspended_id = create_test_account(db, email: "suspended@example.com", status: "suspended")
        result2 = Facet::IAM::Invite.send_invite(db, suspended_id)
        result2.should be_a(Facet::IAM::Invite::InviteSent)
      end
    end

    it "writes an invite_sent LoginEvent" do
      with_db do |db|
        account_id = create_test_account(db, email: "invite@example.com")

        capture_stdout { Facet::IAM::Invite.send_invite(db, account_id) }

        login_events(db).should contain("invite_sent")
      end
    end
  end

  # ── Credential states ───────────────────────────────────────────────

  describe ".credential_states" do
    it "reports one entry per account with slot and document state" do
      with_db do |db|
        bare_id = create_passwordless_account(db, "bare@example.com")
        full_id = create_test_account(db, email: "full@example.com", mfa_enabled: true)
        Facet::IAM::AccountPatch.call(db, full_id, {"must_change_pw" => JSON::Any.new(true)})
        invited_id = create_passwordless_account(db, "invited@example.com")
        Facet::IAM::Invite.send_invite(db, invited_id)

        states = Facet::IAM::Invite.credential_states(db, [bare_id, full_id, invited_id])

        states.size.should eq(3)

        bare = states.find!(&.id.==(bare_id))
        bare.has_password.should be_false
        bare.must_change_pw.should be_false
        bare.mfa_enabled.should be_false
        bare.invite_pending.should be_false
        bare.federated.should be_false

        full = states.find!(&.id.==(full_id))
        full.has_password.should be_true
        full.must_change_pw.should be_true
        full.mfa_enabled.should be_true
        full.invite_pending.should be_false

        invited = states.find!(&.id.==(invited_id))
        invited.has_password.should be_false
        invited.invite_pending.should be_true
      end
    end

    it "ignores an expired reset token for invite_pending" do
      with_db do |db|
        account_id = create_passwordless_account(db, "expired@example.com")
        Facet::IAM::Invite.send_invite(db, account_id)
        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 minute' WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
          account_id
        )

        states = Facet::IAM::Invite.credential_states(db, [account_id])
        states.first.invite_pending.should be_false
      end
    end

    it "returns an empty array for an empty id list" do
      with_db do |db|
        Facet::IAM::Invite.credential_states(db, [] of String).should be_empty
      end
    end
  end
end
