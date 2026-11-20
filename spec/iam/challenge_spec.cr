# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

describe Facet::IAM::Challenge do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "completes challenge with valid TOTP code" do
    with_db do |db|
      ctx = create_mfa_account(db)
      account_id = ctx[:account_id]
      secret = ctx[:secret]

      # Create a challenge in Redis
      challenge_id = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id}",
        "account_id", account_id,
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id}", 300)

      # Generate a valid TOTP code
      code = Facet::IAM::TOTP.generate(secret)

      # Complete the challenge
      result = Facet::IAM::Challenge.call(db, challenge_id, code)
      result.should be_a(Facet::IAM::Challenge::TokensEmitted)
      token_result = result.as(Facet::IAM::Challenge::TokensEmitted).result
      token_result.account_id.should eq(account_id)
      token_result.active_role.should eq("iam.Roles.admin")
      token_result.access_token.should_not be_empty
    end
  end

  it "rejects challenge with invalid code" do
    with_db do |db|
      ctx = create_mfa_account(db)

      challenge_id = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id}",
        "account_id", ctx[:account_id],
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id}", 300)

      result = Facet::IAM::Challenge.call(db, challenge_id, "000000")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should contain("Invalid code")
    end
  end

  it "renders the singular form on the last attempt" do
    with_db do |db|
      ctx = create_mfa_account(db)

      challenge_id = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id}",
        "account_id", ctx[:account_id],
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "2",
      )
      r.expire("challenge:#{challenge_id}", 300)

      result = Facet::IAM::Challenge.call(db, challenge_id, "000000")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should eq("Invalid code. 1 attempt remaining.")
    end
  end

  it "rejects expired challenge" do
    with_db do |db|
      result = Facet::IAM::Challenge.call(db, "nonexistent-challenge", "123456")
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.message.should contain("Challenge not found or expired")
    end
  end

  it "enforces replay protection" do
    with_db do |db|
      ctx = create_mfa_account(db)
      secret = ctx[:secret]

      challenge_id = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id}",
        "account_id", ctx[:account_id],
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id}", 300)

      code = Facet::IAM::TOTP.generate(secret)

      # First use succeeds
      result1 = Facet::IAM::Challenge.call(db, challenge_id, code)
      result1.should be_a(Facet::IAM::Challenge::TokensEmitted)

      # Second use with same code should be rejected (challenge was deleted)
      result2 = Facet::IAM::Challenge.call(db, challenge_id, code)
      result2.should be_a(Facet::ServiceError)
      err = result2.as(Facet::ServiceError)
      err.message.should contain("Challenge not found or expired")
    end
  end

  it "rejects a replayed TOTP code via atomic step check" do
    with_db do |db|
      ctx = create_mfa_account(db)
      account_id = ctx[:account_id]
      secret = ctx[:secret]

      # First challenge — consume the TOTP code successfully.
      challenge_id_1 = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id_1}",
        "account_id", account_id,
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id_1}", 300)

      code = Facet::IAM::TOTP.generate(secret)
      result1 = Facet::IAM::Challenge.call(db, challenge_id_1, code)
      result1.should be_a(Facet::IAM::Challenge::TokensEmitted)

      # A second challenge for the same account presenting the same code must be
      # rejected as a replay (last_totp_step already advanced), even though
      # this is a fresh challenge_id.
      challenge_id_2 = Facet::Util::ScriptHelpers.ulid
      r.hset(
        "challenge:#{challenge_id_2}",
        "account_id", account_id,
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id_2}", 300)

      result2 = Facet::IAM::Challenge.call(db, challenge_id_2, code)
      result2.should be_a(Facet::ServiceError)
      err = result2.as(Facet::ServiceError)
      err.status.should eq(401)
      err.message.should contain("Code already used")

      # The replayed challenge should have been deleted.
      remaining = r.hgetall("challenge:#{challenge_id_2}")
      (remaining.is_a?(Array) && remaining.empty?).should be_true
    end
  end

  it "decrements attempts and locks out after 5 failures" do
    with_db do |db|
      ctx = create_mfa_account(db)

      challenge_id = Facet::Util::ScriptHelpers.ulid
      r = Facet::IAM::RedisSession.redis
      r.hset(
        "challenge:#{challenge_id}",
        "account_id", ctx[:account_id],
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5",
      )
      r.expire("challenge:#{challenge_id}", 300)

      # Use up all attempts — the 5th attempt triggers lockout + deletes the challenge
      lockout_reached = false
      5.times do |_|
        result = Facet::IAM::Challenge.call(db, challenge_id, "000000")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        if err.status == 429
          lockout_reached = true
          err.message.should contain("Too many attempts")
          break
        end
        # First 4 attempts get 401 with remaining count
        err.status.should eq(401)
        err.message.should match(/attempts? remaining/)
      end
      lockout_reached.should be_true

      # Lockout should also be set on the account
      Facet::IAM::LoginThrottle.locked_out?(ctx[:account_id]).should be_true
    end
  end

  describe "backup_code method" do
    it "completes the challenge with a valid backup code" do
      with_db do |db|
        ctx = create_mfa_account(db)
        account_id = ctx[:account_id]
        code = Facet::IAM::BackupCodes.generate(db, account_id).codes.first

        challenge_id = Facet::Util::ScriptHelpers.ulid
        r = Facet::IAM::RedisSession.redis
        r.hset(
          "challenge:#{challenge_id}",
          "account_id", account_id,
          "active_role", "iam.Roles.admin",
          "type", "totp",
          "cookie_requested", "false",
          "attempts_remaining", "5",
        )
        r.expire("challenge:#{challenge_id}", 300)

        result = Facet::IAM::Challenge.call(db, challenge_id, code, "backup_code")
        result.should be_a(Facet::IAM::Challenge::TokensEmitted)
        token_result = result.as(Facet::IAM::Challenge::TokensEmitted).result
        token_result.account_id.should eq(account_id)
        token_result.access_token.should_not be_empty

        # The code is single-use, and the challenge is gone.
        Facet::IAM::BackupCodes.consume(db, account_id, code).should be_false
        remaining = r.hgetall("challenge:#{challenge_id}")
        (remaining.is_a?(Array) && remaining.empty?).should be_true
      end
    end

    it "accepts the dashed display form and rejects it on replay" do
      with_db do |db|
        ctx = create_mfa_account(db)
        account_id = ctx[:account_id]
        code = Facet::IAM::BackupCodes.generate(db, account_id).codes.first

        challenge_id = Facet::Util::ScriptHelpers.ulid
        r = Facet::IAM::RedisSession.redis
        r.hset(
          "challenge:#{challenge_id}",
          "account_id", account_id,
          "active_role", "iam.Roles.admin",
          "type", "totp",
          "cookie_requested", "false",
          "attempts_remaining", "5",
        )
        r.expire("challenge:#{challenge_id}", 300)

        result = Facet::IAM::Challenge.call(db, challenge_id, code.delete('-').upcase, "backup_code")
        result.should be_a(Facet::IAM::Challenge::TokensEmitted)

        # A second challenge presenting the same code burns an attempt —
        # the consume already happened, so the limiter treats it as a guess.
        challenge_id_2 = Facet::Util::ScriptHelpers.ulid
        r.hset(
          "challenge:#{challenge_id_2}",
          "account_id", account_id,
          "active_role", "iam.Roles.admin",
          "type", "totp",
          "cookie_requested", "false",
          "attempts_remaining", "5",
        )
        r.expire("challenge:#{challenge_id_2}", 300)

        replay = Facet::IAM::Challenge.call(db, challenge_id_2, code, "backup_code")
        replay.should be_a(Facet::ServiceError)
        err = replay.as(Facet::ServiceError)
        err.status.should eq(401)
        err.message.should contain("Invalid code")
      end
    end

    it "rejects an invalid backup code and burns a challenge attempt" do
      with_db do |db|
        ctx = create_mfa_account(db)
        Facet::IAM::BackupCodes.generate(db, ctx[:account_id])

        challenge_id = Facet::Util::ScriptHelpers.ulid
        r = Facet::IAM::RedisSession.redis
        r.hset(
          "challenge:#{challenge_id}",
          "account_id", ctx[:account_id],
          "active_role", "iam.Roles.admin",
          "type", "totp",
          "cookie_requested", "false",
          "attempts_remaining", "5",
        )
        r.expire("challenge:#{challenge_id}", 300)

        result = Facet::IAM::Challenge.call(db, challenge_id, "0000-0000", "backup_code")
        result.should be_a(Facet::ServiceError)
        err = result.as(Facet::ServiceError)
        err.status.should eq(401)
        err.message.should contain("Invalid code")

        # The attempt was counted on the live challenge.
        attempts = r.hget("challenge:#{challenge_id}", "attempts_remaining")
        attempts.to_s.should eq("4")
      end
    end

    it "locks the account after too many backup-code failures" do
      with_db do |db|
        ctx = create_mfa_account(db)
        Facet::IAM::BackupCodes.generate(db, ctx[:account_id])

        challenge_id = Facet::Util::ScriptHelpers.ulid
        r = Facet::IAM::RedisSession.redis
        r.hset(
          "challenge:#{challenge_id}",
          "account_id", ctx[:account_id],
          "active_role", "iam.Roles.admin",
          "type", "totp",
          "cookie_requested", "false",
          "attempts_remaining", "5",
        )
        r.expire("challenge:#{challenge_id}", 300)

        lockout_reached = false
        5.times do
          result = Facet::IAM::Challenge.call(db, challenge_id, "0000-0000", "backup_code")
          result.should be_a(Facet::ServiceError)
          err = result.as(Facet::ServiceError)
          if err.status == 429
            lockout_reached = true
            err.message.should contain("Too many attempts")
            break
          end
          err.status.should eq(401)
        end
        lockout_reached.should be_true
        Facet::IAM::LoginThrottle.locked_out?(ctx[:account_id]).should be_true
      end
    end
  end
end
