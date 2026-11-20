# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::MFA do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  describe ".setup" do
    it "generates a provisional secret and returns setup result" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        result = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        result.should be_a(Facet::IAM::MFA::SetupResult)
        setup = result.as(Facet::IAM::MFA::SetupResult)
        setup.secret.should match(/^[A-Z2-7]+$/)
        setup.secret.size.should eq(32)
        setup.otpauth_uri.should start_with("otpauth://totp/")
        setup.otpauth_uri.should contain("secret=#{setup.secret}")

        # Verify it was stored provisionally: a sealed slot write only —
        # the document field stays untouched, the payload is NOT plaintext.
        row = db.query_one?("SELECT mode, value FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'mfa'",
          account_id, as: {String, String})
        row.should_not be_nil
        mode, payload = row.not_nil!
        mode.should eq("sealed")
        payload.should start_with("gcm-v1.")
        payload.should_not contain(setup.secret)
        Facet::Secrets::Codec.open(payload, "iam.Account.#{account_id}", "mfa").should eq(setup.secret)

        content = db.query_one("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1",
          account_id, as: JSON::Any)
        content["mfa_enabled"].as_bool.should be_false
      end
    end

    it "returns a SetupResult when the effective MFA type is totp" do
      with_db do |db|
        account_id = create_test_account(db)
        result = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        result.should be_a(Facet::IAM::MFA::SetupResult)
      end
    end

    it "refuses with 422 when the policy type is none" do
      with_db do |db|
        ensure_settings_doc(db)
        pin_settings(db, %({"iam": {"mfa": {"type": "none"}}}))
        account_id = create_test_account(db)

        result = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(422)
        err.message.should eq("MFA is disabled on this server")
      end
    ensure
      Facet::SystemSettings.reset_cache!
    end
  end

  describe ".verify" do
    it "verifies a valid TOTP code and enables MFA" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        # Setup MFA
        setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        setup.should be_a(Facet::IAM::MFA::SetupResult)
        secret = setup.as(Facet::IAM::MFA::SetupResult).secret

        # Generate a valid code
        code = Facet::IAM::TOTP.generate(secret)

        # Verify
        result = Facet::IAM::MFA.verify(db, account_id, code)
        result.should be_a(Facet::IAM::MFA::VerifyResult)

        # The success mints the single-use backup codes shown once.
        codes = result.as(Facet::IAM::MFA::VerifyResult).backup_codes
        codes.size.should eq(Facet::IAM::BackupCodes::COUNT)
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(Facet::IAM::BackupCodes::COUNT)

        # Check the account document field is now enabled
        content = db.query_one("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1",
          account_id, as: JSON::Any)
        content["mfa_enabled"].as_bool.should be_true
      end
    end

    it "rejects an invalid code" do
      with_db do |db|
        account_id = create_test_account(db)

        Facet::IAM::MFA.setup(db, account_id, "test@example.com")

        result = Facet::IAM::MFA.verify(db, account_id, "000000")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(401)
        err.message.should eq("Invalid code")
      end
    end

    it "returns error when no MFA secret is configured" do
      with_db do |db|
        account_id = create_test_account(db)

        result = Facet::IAM::MFA.verify(db, account_id, "123456")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.message.should eq("No MFA secret configured. Run setup first.")
      end
    end

    it "writes an mfa_enabled event on success" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        secret = setup.as(Facet::IAM::MFA::SetupResult).secret
        code = Facet::IAM::TOTP.generate(secret)

        Facet::IAM::MFA.verify(db, account_id, code)

        events = db.query_all(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
          as: JSON::Any
        )
        events.any? { |e| e["event"]?.try(&.as_s) == "mfa_enabled" }.should be_true
      end
    end
    it "rejects a replayed code via atomic step check" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        setup.should be_a(Facet::IAM::MFA::SetupResult)
        secret = setup.as(Facet::IAM::MFA::SetupResult).secret

        code = Facet::IAM::TOTP.generate(secret)

        # First verify succeeds and advances last_totp_step.
        result1 = Facet::IAM::MFA.verify(db, account_id, code)
        result1.should be_a(Facet::IAM::MFA::VerifyResult)

        # Re-presenting the same code is rejected as a replay.
        result2 = Facet::IAM::MFA.verify(db, account_id, code)
        result2.should be_a(Facet::ServiceError)
        err = result2.as(Facet::ServiceError)
        err.status.should eq(401)
        err.message.should eq("Code already used")
      end
    end

    it "rate-limits after 5 invalid attempts" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        Facet::IAM::MFA.setup(db, account_id, "test@example.com")

        # First 4 attempts return 401 "Invalid code".
        4.times do
          result = Facet::IAM::MFA.verify(db, account_id, "000000")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          err.status.should eq(401)
          err.message.should eq("Invalid code")
        end

        # 5th attempt exhausts the counter and returns 429.
        result5 = Facet::IAM::MFA.verify(db, account_id, "000000")
        result5.should be_a(Facet::ServiceError)
        err5 = result5.as(Facet::ServiceError)
        err5.status.should eq(429)
        err5.message.should contain("Too many attempts")

        # Subsequent calls are short-circuited by the brute-force guard.
        result6 = Facet::IAM::MFA.verify(db, account_id, "000000")
        result6.should be_a(Facet::ServiceError)
        err6 = result6.as(Facet::ServiceError)
        err6.status.should eq(429)
      end
    end

    it "resets the attempt counter on success" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        secret = setup.as(Facet::IAM::MFA::SetupResult).secret

        # Burn 2 attempts.
        2.times { Facet::IAM::MFA.verify(db, account_id, "000000") }

        Facet::IAM::LoginThrottle.get_mfa_verify_attempts(account_id).should eq(2)

        # A successful verify resets the counter.
        code = Facet::IAM::TOTP.generate(secret)
        Facet::IAM::MFA.verify(db, account_id, code).should be_a(Facet::IAM::MFA::VerifyResult)
        Facet::IAM::LoginThrottle.get_mfa_verify_attempts(account_id).should eq(0)
      end
    end
  end

  describe ".disable" do
    it "disables MFA and writes an event" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: true)
        doc_ref = "iam.Account.#{account_id}"

        # First enable MFA
        Facet::Secrets.set(db, doc_ref, "mfa", "SECRET",
          mode: "sealed", set_by: "system", meta: {"mfa_type" => "totp"})
        Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, 100_i64)

        Facet::IAM::MFA.disable(db, account_id)

        slot = db.query_one?("SELECT 1 FROM secrets WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1 AND slot = 'mfa'",
          account_id, as: Int32)
        slot.should be_nil
        step = db.query_one?("SELECT last_totp_step FROM auth_state WHERE domain = 'iam' AND doc_type = 'Account' AND doc_id = $1",
          account_id, as: Int64?)
        step.should be_nil
        content = db.query_one("SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Account' AND id = $1",
          account_id, as: JSON::Any)
        content["mfa_enabled"].as_bool.should be_false

        events = db.query_all(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' AND deleted_at IS NULL",
          as: JSON::Any
        )
        events.any? { |e| e["event"]?.try(&.as_s) == "mfa_disabled" }.should be_true
      end
    end

    it "deletes the backup codes with the rest of the MFA state" do
      with_db do |db|
        account_id = create_test_account(db, mfa_enabled: false)

        setup = Facet::IAM::MFA.setup(db, account_id, "test@example.com")
        secret = setup.as(Facet::IAM::MFA::SetupResult).secret
        Facet::IAM::MFA.verify(db, account_id, Facet::IAM::TOTP.generate(secret))
        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(Facet::IAM::BackupCodes::COUNT)

        Facet::IAM::MFA.disable(db, account_id)

        Facet::IAM::BackupCodes.remaining(db, account_id).should eq(0)
      end
    end
  end
end
