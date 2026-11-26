# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/notifications"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# Route identity must come from the verified auth context, never from an
# unverified token claim (S1).
#
# The attack: a caller sends their own valid bearer token in `Authorization`
# and a forged `auth_token` cookie naming another account in `sub`.
# `AuthHandler` verifies the bearer token and passes the caller as
# themselves; before the fix the route helpers read the cookie's `sub` with
# no signature check and acted on the victim's account.
#
# These specs drive the real `AuthHandler` (enabled for the example) so the
# fiber context is the verified principal, and pin the `auth_token` cookie
# to a forged value.

# Builds an unsigned JWT with the given payload — the shape of a forged
# `auth_token` cookie. The signature segment is present but invalid.
private def forged_unsigned_jwt(payload : Hash(String, JSON::Any)) : String
  header = Base64.urlsafe_encode(%({"alg": "none", "typ": "JWT"}), padding: false)
  body = Base64.urlsafe_encode(payload.to_json, padding: false)
  "#{header}.#{body}.forged-signature"
end

# Headers for the attack: a verified bearer token plus a forged cookie that
# names `victim_id` in `sub`.
private def forged_cookie_headers(bearer : String, victim_id : String) : HTTP::Headers
  forged = forged_unsigned_jwt({
    "sub"  => JSON::Any.new(victim_id),
    "role" => JSON::Any.new("iam.Roles.admin"),
    "typ"  => JSON::Any.new("access"),
  } of String => JSON::Any)
  HTTP::Headers{
    "Authorization"    => "Bearer #{bearer}",
    "Cookie"           => "auth_token=#{forged}",
    "X-Requested-With" => "XMLHttpRequest",
  }
end

describe "IAM route identity comes from the verified context (S1)" do
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

  it "GET /Api/iam/me answers the verified caller, not the forged cookie's sub" do
    with_db do |db|
      attacker_id = create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")
      create_test_account(db, email: "victim@example.com", password: "pw-pw-pw")

      token = login_token("attacker@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me",
        headers: forged_cookie_headers(token, "victim@example.com")))

      assert_http_status(resp, 200)
      body = JSON.parse(resp.body).as_h
      body["account"]["id"].to_s.should eq(attacker_id.to_s)
      body["account"]["email"].to_s.should eq("attacker@example.com")
    end
  end

  it "GET /Api/iam/sessions lists the verified caller's sessions, not the forged sub's" do
    with_db do |db|
      attacker_id = create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")
      victim_id = create_test_account(db, email: "victim@example.com", password: "pw-pw-pw")
      victim_sid, _ = Facet::IAM::RedisSession.create(account_id: victim_id, active_role: "admin")

      token = login_token("attacker@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/sessions",
        headers: forged_cookie_headers(token, victim_id)))

      assert_http_status(resp, 200)
      ids = JSON.parse(resp.body)["sessions"].as_a.map(&.["session_id"].as_s)
      # The attacker's own login session is listed; the victim's is not.
      ids.should_not contain(victim_sid)
      Facet::IAM::RedisSession.list_account_sessions(attacker_id).should_not be_empty
    end
  end

  it "DELETE /Api/iam/sessions/:id cannot revoke the victim's session via a forged cookie" do
    with_db do |db|
      create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")
      victim_id = create_test_account(db, email: "victim@example.com", password: "pw-pw-pw")
      victim_sid, _ = Facet::IAM::RedisSession.create(account_id: victim_id, active_role: "admin")

      token = login_token("attacker@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions/#{victim_sid}",
        headers: forged_cookie_headers(token, victim_id)))

      # The verified caller is not the session owner — non-disclosing 403.
      assert_http_status(resp, 403)
      Facet::IAM::RedisSession.load(victim_sid).should_not be_nil
    end
  end

  it "GET /Api/notifications answers the verified caller's rows, not the forged sub's" do
    with_db do |db|
      attacker_id = create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")
      victim_id = create_test_account(db, email: "victim@example.com", password: "pw-pw-pw")
      Facet::Notification::Send.send(db, victim_id, "hr", "LeaveRequest",
        Facet::Util::ScriptHelpers.ulid, "test", "victim-only")

      token = login_token("attacker@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("GET", "/Api/notifications",
        headers: forged_cookie_headers(token, victim_id)))

      assert_http_status(resp, 200)
      titles = JSON.parse(resp.body)["data"].as_a.map(&.["title"].as_s)
      titles.should_not contain("victim-only")
      Facet::Notification::List.unread_count(db, attacker_id).should eq(0)
    end
  end

  it "POST /Api/iam/mfa/totp/setup targets the verified caller, not the forged sub's account" do
    with_db do |db|
      attacker_id = create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")
      victim_id = create_test_account(db, email: "victim@example.com", password: "pw-pw-pw")

      token = login_token("attacker@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/mfa/totp/setup",
        headers: forged_cookie_headers(token, victim_id), body: "{}"))

      assert_http_status(resp, 200)
      # The secret lands on the attacker's `mfa` slot — the victim's stays empty.
      Facet::Secrets.reveal(db, "iam.Account.#{attacker_id}", "mfa").should_not be_nil
      Facet::Secrets.reveal(db, "iam.Account.#{victim_id}", "mfa").should be_nil
    end
  end

  it "GET /Api/iam/apps answers the verified caller's role, not the forged role claim" do
    with_db do |db|
      create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw")

      token = login_token("attacker@example.com", "pw-pw-pw")
      # The forged cookie claims an admin role for a victim sub. The route
      # must still answer the verified caller — a 200 list, not a 401.
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/apps",
        headers: forged_cookie_headers(token, "victim@example.com")))

      assert_http_status(resp, 200)
    end
  end
end

describe "IAM route identity — verified JWT claim helpers (S1)" do
  it "rejects a forged token's claims" do
    forged = forged_unsigned_jwt({"sub" => JSON::Any.new("victim")} of String => JSON::Any)
    Facet::IAM::Helpers.verified_jwt_claim(forged, "sub").should be_nil
  end

  it "reads claims from a correctly signed token" do
    payload, _exp = Facet::IAM::JWT.build_access_payload(
      account_id: "real-account", session_id: "sid-1", role: "iam.Roles.admin")
    token = Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)

    Facet::IAM::Helpers.verified_jwt_claim(token, "sub").should eq("real-account")
    Facet::IAM::Helpers.verified_jwt_claim(token, "role").should eq("iam.Roles.admin")
  end
end
