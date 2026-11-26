# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

# MFA challenge hardening (S3).
#
# Each challenge caps at 5 attempts, but before this change nothing capped the
# number of live challenges: every correct-password login minted a fresh
# challenge with a fresh budget. These specs pin the two guards:
# - an account holds at most one live challenge (a new login replaces the old);
# - the login refuses to open more than `Login::MAX_CHALLENGE_ISSUES`
#   challenges in the window, and sets the lockout when it does;
# - a lockout raised by an exhausted challenge blocks every live challenge.
describe "MFA challenge hardening (S3)" do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "a second login replaces the first challenge — only one live challenge per account" do
    with_db do |db|
      create_test_account(db, email: "mfa@example.com", password: "pw-pw-pw", mfa_enabled: true)

      first = Facet::IAM::Login.call(db, email: "mfa@example.com", password: "pw-pw-pw", cookie: false)
      first.should be_a(Facet::IAM::Login::MFARequired)
      first_id = first.as(Facet::IAM::Login::MFARequired).challenge_id

      second = Facet::IAM::Login.call(db, email: "mfa@example.com", password: "pw-pw-pw", cookie: false)
      second.should be_a(Facet::IAM::Login::MFARequired)
      second_id = second.as(Facet::IAM::Login::MFARequired).challenge_id
      second_id.should_not eq(first_id)

      r = Facet::IAM::RedisSession.redis
      # The first challenge is gone — it cannot be answered in parallel.
      r.hgetall("challenge:#{first_id}").as?(Array).try(&.empty?).should be_true
      r.hgetall("challenge:#{second_id}").as?(Array).try(&.empty?).should be_false
    end
  end

  it "refuses a login that would open more challenges than the cap, and locks out" do
    with_db do |db|
      account_id = create_test_account(db, email: "mfa@example.com", password: "pw-pw-pw", mfa_enabled: true)

      # Open challenges up to the cap. Each replaces the previous live one.
      Facet::IAM::Login::MAX_CHALLENGE_ISSUES.times do
        Facet::IAM::Login.call(db, email: "mfa@example.com", password: "pw-pw-pw", cookie: false)
          .should be_a(Facet::IAM::Login::MFARequired)
      end

      refused = Facet::IAM::Login.call(db, email: "mfa@example.com", password: "pw-pw-pw", cookie: false)
      refused.should be_a(Facet::ServiceError)
      refused.as(Facet::ServiceError).status.should eq(429)

      Facet::IAM::LoginThrottle.locked_out?(account_id).should be_true
      Facet::IAM::LoginThrottle.get_challenge_issues(account_id)
        .should eq(Facet::IAM::Login::MAX_CHALLENGE_ISSUES)
    end
  end

  it "a passed challenge resets the creation counter" do
    with_db do |db|
      ctx = create_mfa_account(db)
      account_id = ctx[:account_id]

      login = Facet::IAM::Login.call(db, email: "test@example.com", password: "test-password", cookie: false)
      login.should be_a(Facet::IAM::Login::MFARequired)
      challenge_id = login.as(Facet::IAM::Login::MFARequired).challenge_id

      code = Facet::IAM::TOTP.generate(ctx[:secret])
      Facet::IAM::Challenge.call(db, challenge_id, code)
        .should be_a(Facet::IAM::Challenge::TokensEmitted)

      Facet::IAM::LoginThrottle.get_challenge_issues(account_id).should eq(0)
      # The active-challenge tracking key is cleared too.
      Facet::IAM::RedisSession.redis.get("challenge_active:#{account_id}").should be_nil
    end
  end

  it "a lockout from an exhausted challenge blocks the other live challenges" do
    with_db do |db|
      ctx = create_mfa_account(db)
      account_id = ctx[:account_id]
      r = Facet::IAM::RedisSession.redis

      # Two challenges exist (e.g. opened before the single-live rule landed).
      stale_id = Facet::Util::ScriptHelpers.ulid
      r.hset("challenge:#{stale_id}",
        "account_id", account_id, "active_role", "iam.Roles.admin", "type", "totp",
        "cookie_requested", "false", "attempts_remaining", "5")
      r.expire("challenge:#{stale_id}", 300)

      burn_id = Facet::Util::ScriptHelpers.ulid
      r.hset("challenge:#{burn_id}",
        "account_id", account_id, "active_role", "iam.Roles.admin", "type", "totp",
        "cookie_requested", "false", "attempts_remaining", "1")
      r.expire("challenge:#{burn_id}", 300)

      # Exhausting one challenge sets the lockout.
      Facet::IAM::Challenge.call(db, burn_id, "000000")
        .as(Facet::ServiceError).status.should eq(429)
      Facet::IAM::LoginThrottle.locked_out?(account_id).should be_true

      # The stale challenge is refused even with a valid code.
      code = Facet::IAM::TOTP.generate(ctx[:secret])
      result = Facet::IAM::Challenge.call(db, stale_id, code)
      result.should be_a(Facet::ServiceError)
      result.as(Facet::ServiceError).status.should eq(429)
    end
  end
end
