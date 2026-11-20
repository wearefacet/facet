# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# `GET /Api/iam/me` — the authentication-channel contract (B-136).
#
# The route reads the request's auth context, so a static API key
# (`Authorization: Bearer fct_…`) gets the same profile a browser session
# gets — before B-136 it answered `401 "Authentication required"` because it
# decoded JWT claims only. The response names the channel that served the
# request: `api` for a key caller, `session` for a browser session.

describe "GET /Api/iam/me — auth channels (B-136)" do
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

  it "answers a valid static API key with the key-scoped identity and channel api" do
    with_db do |db|
      create_test_account(db, email: "me-key@example.com", password: "pw-pw-pw")
      token = login_token("me-key@example.com", "pw-pw-pw")

      key_headers = bearer_headers(token)
      key_headers["X-Requested-With"] = "XMLHttpRequest"
      key_headers["Content-Type"] = "application/json"
      created = call_api(HTTP::Request.new("POST", "/Api/iam/keys",
        headers: key_headers, body: %({"name": "me-probe", "role": "iam.Roles.admin"})))
      assert_http_status(created, 201)
      raw_key = JSON.parse(created.body)["key"].as_s

      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me",
        headers: bearer_headers(raw_key)))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body).as_h
      body["channel"].as_s.should eq("api")
      body["active_role"].to_s.should eq("iam.Roles.admin")
      body["account"]["email"].to_s.should eq("me-key@example.com")
      body["permissions"].as_h.should_not be_nil
      # A key caller has no access token to expire — the field reads null.
      body["expires_at"].raw.should be_nil
    end
  end

  it "answers a browser session with channel session and the token expiry" do
    with_db do |db|
      account_id = create_test_account(db, email: "me-session@example.com", password: "pw-pw-pw")
      token = login_token("me-session@example.com", "pw-pw-pw")

      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me",
        headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body).as_h
      body["channel"].as_s.should eq("session")
      body["account"]["id"].to_s.should eq(account_id.to_s)
      body["expires_at"].as_i.should be > Time.utc.to_unix
    end
  end

  it "refuses a presented but invalid credential (fail closed, no anonymous fallback)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me",
      headers: bearer_headers("#{Facet::IAM::ApiKey::PREFIX}#{"C" * 26}")))
    assert_http_status(resp, 401)
  end
end
