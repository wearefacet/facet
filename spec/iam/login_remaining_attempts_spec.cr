# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"

# B-139 — the password path surfaces the remaining-attempts count on the
# 401, from the same Redis counter (`LoginThrottle`) the MFA challenge path
# uses — the MFA challenge answers "N attempts remaining"; the password path
# now exposes the same signal in the error `meta`, so the login form can
# render the same inline warning.
describe "Login remaining attempts (B-139)" do
  around_each do |example|
    redis_cleanup
    begin
      example.run
    ensure
      redis_cleanup
    end
  end

  it "carries remaining_attempts on the 401 meta, decrementing per failure" do
    with_db do |db|
      create_test_account(db, email: "tries@example.com", password: "correct-password")

      r1 = Facet::IAM::Login.call(db, email: "tries@example.com",
        password: "wrong-password", cookie: false)
      r1.should be_a(Facet::ServiceError)
      meta1 = r1.as(Facet::ServiceError).meta
      meta1.should_not be_nil
      meta1.not_nil!["remaining_attempts"]?.should eq("9")

      r2 = Facet::IAM::Login.call(db, email: "tries@example.com",
        password: "wrong-password", cookie: false)
      r2.as(Facet::ServiceError).meta.not_nil!["remaining_attempts"]?.should eq("8")
    end
  end

  it "clamps the count at zero once the window is exhausted" do
    with_db do |db|
      account_id = create_test_account(db, email: "exhaust@example.com", password: "correct-password")

      # Burn all but the last window slot (10) directly through the counter.
      # The pre-auth threshold check reads 9 < 10 and lets the request
      # through to the password path — no lockout ever trips.
      9.times { Facet::IAM::LoginThrottle.increment_pwd_attempts(account_id) }

      # This wrong password is attempt 10: the 401 reports the clamped
      # remainder — the count must never go negative.
      result = Facet::IAM::Login.call(db, email: "exhaust@example.com",
        password: "wrong-password", cookie: false)
      result.should be_a(Facet::ServiceError)
      err = result.as(Facet::ServiceError)
      err.status.should eq(401)
      err.meta.not_nil!["remaining_attempts"]?.should eq("0")
    end
  end

  it "resets the counter after a successful login" do
    with_db do |db|
      create_test_account(db, email: "reset-tries@example.com", password: "correct-password")

      Facet::IAM::Login.call(db, email: "reset-tries@example.com",
        password: "wrong-password", cookie: false)
      Facet::IAM::LoginThrottle.get_pwd_attempts(
        Facet::IAM::Helpers.find_account_by_email(db, "reset-tries@example.com").not_nil![:id]
      ).should eq(1)

      ok = Facet::IAM::Login.call(db, email: "reset-tries@example.com",
        password: "correct-password", cookie: false)
      ok.should be_a(Facet::IAM::Login::TokensEmitted)

      Facet::IAM::LoginThrottle.get_pwd_attempts(
        Facet::IAM::Helpers.find_account_by_email(db, "reset-tries@example.com").not_nil![:id]
      ).should eq(0)
    end
  end
end
