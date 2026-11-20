# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

# B-142 — the credential-token TTL (`iam.change_password_expiration`) is
# a runtime key on `core.SystemSettings` (`IAM::Policy.change_password_expiration`);
# the config-file value (YAML only — never ENV) is the fallback tier. A
# short configured TTL gives the expiry path a testable window: a link
# minted through the production request path dies on its own once the
# window elapses, and the one-shot contract holds on a live token. The
# runtime tier is covered by the second describe block: the document
# value overrides the file, an unpinned document follows the file, and
# the minted rows carry the pinned window.

# Swaps the config singleton for one whose reset TTL is 2 seconds, and
# restores the loaded config after. The secrets section carries over —
# the master key must match the suite's, or the slot rows written inside
# the block would be unreadable outside it.
private def with_short_reset_ttl(&)
  original = Facet::Config.instance
  Facet::Config.instance = Facet::Config.new(
    artifact_grant_secret: original.artifact_grant_secret,
    secrets: original.secrets,
    iam: Facet::Config::IAMConfig.new(change_password_expiration: 2),
  )
  yield
ensure
  Facet::Config.instance = original if original
end

# Redirects STDOUT to a temp file for the duration of the block and returns
# what was written. The DevAdapter prints emails to stdout, so this captures
# the delivered email body. (File-local twin of the helper in invite_spec.cr
# — declared private so both definitions can coexist in one suite run.)
private def capture_stdout(&) : String
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

# Runs a real reset request and pulls the raw token out of the printed
# dev-adapter email — the store keeps only the digest, so the mail body
# is the only place the raw value exists.
private def request_reset_token(db, email) : String
  body = capture_stdout do
    result = Facet::IAM::PasswordReset.request(
      db, email, "https://example.test/ResetPassword"
    )
    result.should be_a(Facet::IAM::PasswordReset::Requested)
  end
  token = body[/ResetPassword\?token=([0-9a-f]{64})/, 1]
  token.should_not be_nil
  token.as(String)
end

describe "PasswordReset TTL from config (B-142)" do
  around_each do |example|
    redis_cleanup
    Facet::BaseEmail.reset_configuration!
    begin
      example.run
    ensure
      redis_cleanup
    end
  end

  it "refuses a link minted through the request path once the configured TTL elapses" do
    with_short_reset_ttl do
      with_db do |db|
        account_id = create_test_account(db, email: "ttl-expiry@example.com", password: "old-password-1")

        token = request_reset_token(db, "ttl-expiry@example.com")

        # The minted row carries the configured window, not a default.
        expires_at, set_at = db.query_one(
          "SELECT expires_at, set_at FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' " \
          "AND doc_id = $1 AND slot = 'reset'",
          account_id, as: {Time, Time})
        (expires_at - set_at).total_seconds.should be_close(2, 1)

        # Backdate the row past its window: the confirm's consume gates on
        # `expires_at > now()`, so the refusal needs no wall-clock wait.
        # The minted-window contract is already asserted above via the
        # `expires_at - set_at` diff.
        db.exec(
          "UPDATE secrets SET expires_at = now() - interval '1 second' " \
          "WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'reset'",
          account_id)
        expired = db.query_one?(
          "SELECT 1 FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' " \
          "AND doc_id = $1 AND slot = 'reset' AND expires_at > now()",
          account_id, as: Int32)
        expired.should be_nil

        refused = Facet::IAM::PasswordReset.confirm(db, token, "new-password-1")
        refused.should be_a(Facet::ServiceError)
        refused.as(Facet::ServiceError).status.should eq(401)
      end
    end
  end

  it "stays one-shot within the window: first confirm resets, second refuses" do
    with_short_reset_ttl do
      with_db do |db|
        create_test_account(db, email: "ttl-once@example.com", password: "old-password-1")

        token = request_reset_token(db, "ttl-once@example.com")

        # Confirm inside the 2-second window — the row is still live.
        confirmed = Facet::IAM::PasswordReset.confirm(db, token, "new-password-1")
        confirmed.should be_a(Facet::IAM::PasswordReset::Confirmed)

        # The row is gone — a replay of the same link is refused.
        replay = Facet::IAM::PasswordReset.confirm(db, token, "another-password-1")
        replay.should be_a(Facet::ServiceError)
        replay.as(Facet::ServiceError).status.should eq(401)

        # And the new credential works.
        login = Facet::IAM::Login.call(db, email: "ttl-once@example.com",
          password: "new-password-1", cookie: false)
        login.should be_a(Facet::IAM::Login::TokensEmitted)
      end
    end
  end
end

describe "PasswordReset TTL from the runtime key (B-142)" do
  around_each do |example|
    Facet::SystemSettings.reset_cache!
    begin
      example.run
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  it "reads the document value when the runtime key is pinned, overriding the file tier" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"iam": {"change_password_expiration": 7200}}))

      # The file tier in the test env is 3600 — the pin must win.
      Facet::IAM::Policy.change_password_expiration(db).should eq(7200)
      Facet::IAM::Policy.change_password_expiration(db)
        .should_not eq(Facet::IAM::Config.change_password_expiration)
    end
  end

  it "falls back to the file value when the document does not pin the key" do
    with_db do |db|
      ensure_settings_doc(db)

      Facet::IAM::Policy.change_password_expiration(db)
        .should eq(Facet::IAM::Config.change_password_expiration)
    end
  end

  it "mints the reset token with the pinned window through the request path" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"iam": {"change_password_expiration": 7200}}))
      account_id = create_test_account(db, email: "ttl-runtime@example.com", password: "old-password-1")

      request_reset_token(db, "ttl-runtime@example.com")

      expires_at, set_at = db.query_one(
        "SELECT expires_at, set_at FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' " \
        "AND doc_id = $1 AND slot = 'reset'",
        account_id, as: {Time, Time})
      (expires_at - set_at).total_seconds.should be_close(7200, 5)
    end
  end

  it "mints the invite token with the pinned window through the invite path" do
    with_db do |db|
      ensure_settings_doc(db)
      pin_settings(db, %({"iam": {"change_password_expiration": 7200}}))
      account_id = create_test_account(db, email: "ttl-invite@example.com", password: "old-password-1")

      capture_stdout do
        sent = Facet::IAM::Invite.send_invite(db, account_id)
        sent.should be_a(Facet::IAM::Invite::InviteSent)
      end

      expires_at, set_at = db.query_one(
        "SELECT expires_at, set_at FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' " \
        "AND doc_id = $1 AND slot = 'reset'",
        account_id, as: {Time, Time})
      (expires_at - set_at).total_seconds.should be_close(7200, 5)
    end
  end
end
