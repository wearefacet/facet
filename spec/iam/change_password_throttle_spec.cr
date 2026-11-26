# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# `/Api/iam/change-password` throttle (S1).
#
# The route is public (the bootstrap `change_token` needs no session), so a
# wrong `old_password` was an unbounded oracle — only bcrypt bounded guesses.
# A per-account counter now refuses with 429 after
# `Routes::MAX_CHANGE_PASSWORD_ATTEMPTS` failures, on both authorization
# paths.

# Builds a fresh one-shot change token for `account_id` (each consume burns
# one attempt of the token itself).
private def throttle_change_token(account_id : String) : String
  Facet::IAM::PwdChangeToken.create_pwd_change_token(account_id, 3600)
end

private def throttle_change_password(token : String, old_password : String, new_password : String = "new-password-123") : HTTP::Client::Response
  body = %({"change_token": #{token.to_json}, "old_password": #{old_password.to_json}, "new_password": #{new_password.to_json}})
  headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
  call_api(HTTP::Request.new("POST", "/Api/iam/change-password", headers: headers, body: body))
end

describe "POST /Api/iam/change-password throttle (S1)" do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "throttles wrong old_password guesses on the bootstrap token path" do
    account_id = with_db { |db| create_test_account(db) }

    Facet::IAM::Routes::MAX_CHANGE_PASSWORD_ATTEMPTS.times do
      resp = throttle_change_password(throttle_change_token(account_id), "wrong-password")
      assert_http_status(resp, 403)
    end

    # The next guess is refused before the bcrypt burn.
    resp = throttle_change_password(throttle_change_token(account_id), "wrong-password")
    assert_http_status(resp, 429)
    Facet::IAM::LoginThrottle.get_change_password_attempts(account_id)
      .should eq(Facet::IAM::Routes::MAX_CHANGE_PASSWORD_ATTEMPTS)
  end

  it "resets the counter on a successful change" do
    account_id = with_db { |db| create_test_account(db) }

    2.times do
      throttle_change_password(throttle_change_token(account_id), "wrong-password")
    end
    Facet::IAM::LoginThrottle.get_change_password_attempts(account_id).should eq(2)

    resp = throttle_change_password(throttle_change_token(account_id), "test-password")
    assert_http_status(resp, 200)
    Facet::IAM::LoginThrottle.get_change_password_attempts(account_id).should eq(0)
  end

  it "does not lock the account out of login" do
    account_id = with_db { |db| create_test_account(db) }

    Facet::IAM::Routes::MAX_CHANGE_PASSWORD_ATTEMPTS.times do
      throttle_change_password(throttle_change_token(account_id), "wrong-password")
    end

    Facet::IAM::LoginThrottle.locked_out?(account_id).should be_false
  end
end
