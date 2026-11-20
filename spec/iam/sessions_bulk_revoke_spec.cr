# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/iam/redis_session"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# B-140 — `DELETE /Api/iam/sessions` (bulk revoke).
#
# Revokes every session the caller holds EXCEPT the one serving the request
# — a "sign out everywhere else". The current session must survive so the
# requester stays signed in and sees the result. Each revoked session writes
# its own `session_revoked` LoginEvent, mirroring the single-session route.
describe "DELETE /Api/iam/sessions — bulk revoke (B-140)" do
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

  it "requires authentication" do
    resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions"))
    assert_http_status(resp, 401)
  end

  it "revokes every other session and keeps the calling session alive" do
    with_db do |db|
      account_id = create_test_account(db, email: "bulk@example.com", password: "pw-pw-pw")

      # Two satellite sessions created before the login that serves the call.
      other_a, _ = Facet::IAM::RedisSession.create(account_id: account_id, active_role: "admin")
      other_b, _ = Facet::IAM::RedisSession.create(account_id: account_id, active_role: "admin")

      token = login_token("bulk@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions", headers: headers))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body)
      body["ok"].as_bool.should be_true
      body["revoked"].as_i.should eq(2)

      Facet::IAM::RedisSession.load(other_a).should be_nil
      Facet::IAM::RedisSession.load(other_b).should be_nil

      # The calling session survives — its JWT still authenticates.
      me = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(me, 200)
    end
  end

  it "answers an empty revoke for an account holding only the calling session" do
    with_db do |db|
      create_test_account(db, email: "bulk-solo@example.com", password: "pw-pw-pw")
      token = login_token("bulk-solo@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"

      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions", headers: headers))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["revoked"].as_i.should eq(0)
    end
  end

  it "writes a session_revoked event per revoked session" do
    with_db do |db|
      account_id = create_test_account(db, email: "bulk-audit@example.com", password: "pw-pw-pw")
      other_a, _ = Facet::IAM::RedisSession.create(account_id: account_id, active_role: "admin")
      other_b, _ = Facet::IAM::RedisSession.create(account_id: account_id, active_role: "admin")

      token = login_token("bulk-audit@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"

      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions", headers: headers))
      assert_http_status(resp, 200)

      events = db.query_all(
        "SELECT content->>'details' FROM projections WHERE domain = 'iam' AND doc_type = 'LoginEvent' " \
        "AND content->>'event' = 'session_revoked' AND deleted_at IS NULL",
        as: String)
      details = events.join(" ")
      details.should contain(other_a)
      details.should contain(other_b)
    end
  end

  it "requires the CSRF header for cookie-authenticated calls" do
    with_db do |db|
      create_test_account(db, email: "bulk-csrf@example.com", password: "pw-pw-pw")
      token = login_token("bulk-csrf@example.com", "pw-pw-pw")
      headers = HTTP::Headers{"Cookie" => "auth_token=#{token}"}
      resp = call_api_raw(HTTP::Request.new("DELETE", "/Api/iam/sessions", headers: headers))
      JSON.parse(resp.body.to_s)["error"]?.to_s.should contain("CSRF")
    end
  end
end
