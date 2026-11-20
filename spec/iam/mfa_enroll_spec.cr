# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/iam_helper"

HTTPTest.init

# Enroll-at-login (MFA enforcement `always`): the login branch holds an
# un-enrolled account at the enrollment step and returns a one-shot enroll
# token plus the provisional secret; `Enroll.verify` completes the login.
#
# Under `preferred` (the effective default — the test config file and the
# all-null settings document) the backend is unchanged: login emits tokens
# directly.

describe Facet::IAM::Enroll do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "under always: login holds an un-enrolled account at the enrollment step, no session created" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        result = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        result.should be_a(Facet::IAM::Login::EnrollmentRequired)
        enroll = result.as(Facet::IAM::Login::EnrollmentRequired)

        enroll.enroll_token.should_not be_empty
        enroll.secret.should match(/^[A-Z2-7]+$/)
        enroll.otpauth_uri.should start_with("otpauth://totp/")
        enroll.otpauth_uri.should contain("secret=#{enroll.secret}")

        # The provisional secret is stored (sealed), the flag is not flipped
        # yet, and no session exists — tokens come only after verify.
        Facet::Secrets.reveal(db, "iam.Account.#{account_id}", "mfa").should eq(enroll.secret)
        Facet::IAM::RedisSession.list_account_sessions(account_id).should be_empty
      end
    end
  end

  it "under always: a repeated login reuses the pending secret instead of re-minting (B-300)" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        first = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        first_enroll = first.as(Facet::IAM::Login::EnrollmentRequired)

        second = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        second_enroll = second.as(Facet::IAM::Login::EnrollmentRequired)

        # The secret shown on the first login stays valid: the second login
        # serves the stored secret, not a fresh mint. A code derived from
        # the first secret therefore still verifies.
        second_enroll.secret.should eq(first_enroll.secret)
        second_enroll.otpauth_uri.should eq(first_enroll.otpauth_uri)
        Facet::Secrets.reveal(db, "iam.Account.#{account_id}", "mfa").should eq(first_enroll.secret)
      end
    end
  end

  it "under preferred: login emits tokens directly, no enrollment branch" do
    with_db do |db|
      account_id = create_test_account(db, mfa_enabled: false)

      result = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
      result.should be_a(Facet::IAM::Login::TokensEmitted)

      # No provisional secret was written.
      Facet::Secrets.reveal(db, "iam.Account.#{account_id}", "mfa").should be_nil
    end
  end

  it "must_change_pw wins over enrollment: password first, then MFA" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)
        Facet::IAM::AccountPatch.call(db, account_id, {"must_change_pw" => JSON::Any.new(true)})

        result = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        result.should be_a(Facet::IAM::Login::PasswordChangeRequired)

        # No enroll token, no provisional secret.
        Facet::Secrets.reveal(db, "iam.Account.#{account_id}", "mfa").should be_nil
      end
    end
  end

  it "verifies a correct code: tokens emitted, mfa_enabled flips, event written, token single-use" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        login = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        enroll = login.as(Facet::IAM::Login::EnrollmentRequired)

        code = Facet::IAM::TOTP.generate(enroll.secret)
        result = Facet::IAM::Enroll.verify(db, enroll.enroll_token, code)
        result.should be_a(Facet::IAM::Enroll::TokensEmitted)
        emitted = result.as(Facet::IAM::Enroll::TokensEmitted)
        emitted.result.account_id.should eq(account_id)
        emitted.result.active_role.should eq("iam.Roles.admin")
        emitted.result.access_token.should_not be_empty

        # The enrollment mints the single-use backup codes shown once.
        emitted.backup_codes.size.should eq(Facet::IAM::BackupCodes::COUNT)
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(Facet::IAM::BackupCodes::COUNT)
        Facet::IAM::BackupCodes.consume(db, account_id, emitted.backup_codes.first).should be_true

        content = db.query_one("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1",
          account_id, as: JSON::Any)
        content["mfa_enabled"].as_bool.should be_true

        login_events(db).should contain("mfa_enrolled")

        # Single use: the token is gone, a second verify is a 401 re-login.
        Facet::IAM::EnrollToken.load_enroll_token(enroll.enroll_token).should be_nil
        replay = Facet::IAM::Enroll.verify(db, enroll.enroll_token, code)
        replay.should be_a(Facet::ServiceError)
        replay.as(Facet::ServiceError).status.should eq(401)
      end
    end
  end

  it "decrements attempts on a wrong code and locks out after 5 failures" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        login = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        enroll = login.as(Facet::IAM::Login::EnrollmentRequired)

        lockout_reached = false
        5.times do |_|
          result = Facet::IAM::Enroll.verify(db, enroll.enroll_token, "000000")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          if err.status == 429
            lockout_reached = true
            err.message.should contain("Too many attempts")
            break
          end
          err.status.should eq(401)
          err.message.should match(/attempts? remaining/)
        end
        lockout_reached.should be_true

        Facet::IAM::LoginThrottle.locked_out?(account_id).should be_true
        Facet::IAM::EnrollToken.load_enroll_token(enroll.enroll_token).should be_nil
      end
    end
  end

  it "rejects a replayed code (step already consumed)" do
    with_db do |db|
      account_id = create_test_account(db, mfa_enabled: false)
      doc_ref = "iam.Account.#{account_id}"

      setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
      secret = setup.as(Facet::IAM::MFA::SetupResult).secret
      token = Facet::IAM::EnrollToken.create_enroll_token(account_id, "iam.Roles.admin", false)

      code = Facet::IAM::TOTP.generate(secret)
      step = Facet::IAM::TOTP.validate(secret, code, window: 1).not_nil!
      # Consume the step out-of-band: the verify must see the replay.
      Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, step).should be_true

      result = Facet::IAM::Enroll.verify(db, token, code)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should contain("Code already used")

      Facet::IAM::EnrollToken.load_enroll_token(token).should be_nil
    end
  end

  it "flips a pending account to active after enrollment" do
    with_mfa_enforcement("always") do
      with_db do |db|
        account_id = create_test_account(db, status: "pending", mfa_enabled: false)

        login = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
        enroll = login.as(Facet::IAM::Login::EnrollmentRequired)

        code = Facet::IAM::TOTP.generate(enroll.secret)
        result = Facet::IAM::Enroll.verify(db, enroll.enroll_token, code)
        result.should be_a(Facet::IAM::Enroll::TokensEmitted)

        content = db.query_one("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1",
          account_id, as: JSON::Any)
        content["status"].as_s.should eq("active")
      end
    end
  end
end

# The mfa_enroll_required payload comes back from `login_response` (which
# logs in through the HTTP route under `always`).

describe "POST /Api/iam/mfa/enroll/verify route" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      redis_cleanup
    end
  end

  before_each do
    with_db { |db| seed_iam_doctypes(db) }
  end

  it "holds the login at enrollment and completes it through the route" do
    with_mfa_enforcement("always") do
      with_db do |db|
        create_test_account(db, email: "enroll@example.com", password: "pw-pw-pw", mfa_enabled: false)

        payload = login_response("enroll@example.com", "pw-pw-pw")
        payload["mfa_enroll_required"].as_bool.should be_true
        payload["mfa_enforcement"].to_s.should eq("always")
        enroll_token = payload["enroll_token"].as_s
        secret = payload["secret"].as_s
        payload["otpauth_uri"].as_s.should start_with("otpauth://totp/")

        code = Facet::IAM::TOTP.generate(secret)
        body = %({"enroll_token": #{enroll_token.to_json}, "code": #{code.to_json}})
        headers = HTTP::Headers{
          "Content-Type"     => "application/json",
          "X-Requested-With" => "XMLHttpRequest",
        }
        resp = call_api(HTTP::Request.new("POST", "/Api/iam/mfa/enroll/verify", headers: headers, body: body))
        assert_http_status(resp, 200)

        json = JSON.parse(resp.body)
        json["token"].as_s.should_not be_empty

        # The raw recovery codes ride on the enroll response — shown once.
        json["backup_codes"].as_a.size.should eq(Facet::IAM::BackupCodes::COUNT)
      end
    end
  end

  it "rejects the request without the CSRF header" do
    with_mfa_enforcement("always") do
      with_db do |db|
        create_test_account(db, email: "csrf@example.com", password: "pw-pw-pw", mfa_enabled: false)
        payload = login_response("csrf@example.com", "pw-pw-pw")
        enroll_token = payload["enroll_token"].as_s

        body = %({"enroll_token": #{enroll_token.to_json}, "code": "123456"})
        headers = HTTP::Headers{"Content-Type" => "application/json"}
        resp = call_api_raw(HTTP::Request.new("POST", "/Api/iam/mfa/enroll/verify", headers: headers, body: body))
        JSON.parse(resp.body.to_s)["error"]?.to_s.should contain("CSRF")
      end
    end
  end

  it "returns 401 for a bad enroll token" do
    with_db do |db|
      create_test_account(db, email: "badtoken@example.com", password: "pw-pw-pw", mfa_enabled: false)

      body = %({"enroll_token": "not-a-real-token", "code": "123456"})
      headers = HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      }
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/mfa/enroll/verify", headers: headers, body: body))
      assert_http_status(resp, 401)
    end
  end
end
