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

# `/Api/iam/sessions*` HTTP endpoints.
#
# Three routes surface per-app revocation in the account's own session list:
# - GET    /Api/iam/sessions               — list the caller's sessions
# - DELETE /Api/iam/sessions/:session_id    — revoke one of the caller's sessions
# - DELETE /Api/iam/apps/:app_id/sessions   — revoke all the caller's sessions
#                                            for one app
#
# All three are AuthHandler-protected (401 without a token). The two DELETEs
# are CSRF-checked. Deleting an in-flight access token's session does NOT
# kill the access token — it dies on its ≤15-min TTL on the next refresh.

describe "IAM /Api/iam/sessions*" do
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

  it "GET /Api/iam/sessions requires authentication" do
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/sessions"))
    assert_http_status(resp, 401)
  end

  it "GET /Api/iam/sessions lists the caller's browser and app sessions" do
    with_db do |db|
      account_id = create_test_account(db, email: "sessions@example.com", password: "pw-pw-pw")
      # Create one browser session + one app session directly via RedisSession.
      browser_sid, _ = Facet::IAM::RedisSession.create(
        account_id: account_id, active_role: "admin",
      )
      app_sid, _ = Facet::IAM::RedisSession.create_app_session(
        account_id: account_id, active_role: "admin", app: "01FAKEAPP0000000000000",
        client_id: "cid_fake_app",
      )

      token = login_token("sessions@example.com", "pw-pw-pw")
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/sessions",
        headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      sessions = JSON.parse(resp.body)["sessions"].as_a
      session_ids = sessions.map(&.["session_id"].as_s)
      session_ids.should contain(browser_sid)
      session_ids.should contain(app_sid)

      # The app session is tagged with the app id; the browser session reports
      # `app: null` so the frontend can render "this app is signed in".
      app_entry = sessions.find!(&.["session_id"].as_s.==(app_sid))
      app_entry["app"].as_s.should eq("01FAKEAPP0000000000000")
      browser_entry = sessions.find!(&.["session_id"].as_s.==(browser_sid))
      browser_entry["app"]?.try(&.as_s?).should be_nil
    end
  end

  it "DELETE /Api/iam/sessions/:session_id revokes one of the caller's sessions" do
    with_db do |db|
      account_id = create_test_account(db, email: "revoke@example.com", password: "pw-pw-pw")
      sid, _ = Facet::IAM::RedisSession.create(account_id: account_id, active_role: "admin")

      token = login_token("revoke@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions/#{sid}", headers: headers))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["ok"].as_bool.should be_true
      body["revoked"].as_bool.should be_true

      Facet::IAM::RedisSession.load(sid).should be_nil
    end
  end

  it "DELETE /Api/iam/sessions/:session_id is idempotent on a missing session" do
    with_db do |db|
      create_test_account(db, email: "idem@example.com", password: "pw-pw-pw")
      token = login_token("idem@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions/nonexistent", headers: headers))
      assert_http_status(resp, 200)
      # Idempotent but visible: the body reports that nothing was revoked.
      body = JSON.parse(resp.body)
      body["ok"].as_bool.should be_true
      body["revoked"].as_bool.should be_false
    end
  end

  it "DELETE /Api/iam/sessions/:session_id rejects another user's session (non-disclosing 403)" do
    with_db do |db|
      owner_id = create_test_account(db, email: "owner@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")
      _attacker_id = create_test_account(db, email: "attacker@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

      victim_sid, _ = Facet::IAM::RedisSession.create(account_id: owner_id, active_role: "admin")

      attacker_token = login_token("attacker@example.com", "pw-pw-pw")
      headers = bearer_headers(attacker_token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/sessions/#{victim_sid}", headers: headers))
      assert_http_status(resp, 403)

      # The victim's session is still alive.
      Facet::IAM::RedisSession.load(victim_sid).should_not be_nil
    end
  end

  it "DELETE /Api/iam/sessions/:session_id requires the CSRF header" do
    with_db do |db|
      create_test_account(db, email: "csrf@example.com", password: "pw-pw-pw")
      token = login_token("csrf@example.com", "pw-pw-pw")
      # Cookie session, no X-Requested-With — the ambient credential stays
      # CSRF-checked. Raw dispatch — `call_api` would add the browser
      # default header. (A Bearer credential is exempt: non-ambient.)
      headers = HTTP::Headers{"Cookie" => "auth_token=#{token}"}
      resp = call_api_raw(HTTP::Request.new("DELETE", "/Api/iam/sessions/some-id", headers: headers))
      # CSRF check runs before the route handler — the response still carries
      # 200 (matches `next env.response.print(...)` pattern) but the JSON
      # body contains the CSRF error. Auth status is the gate the frontend
      # reads.
      JSON.parse(resp.body.to_s)["error"]?.to_s.should contain("CSRF")
    end
  end

  it "DELETE /Api/iam/apps/:app_id/sessions revokes the caller's sessions for the app" do
    with_db do |db|
      account_id = create_test_account(db, email: "apprevoke@example.com", password: "pw-pw-pw")
      app_a = "01FAKEAPP_A_000000000000"
      app_b = "01FAKEAPP_B_000000000000"

      a1, _ = Facet::IAM::RedisSession.create_app_session(account_id: account_id, active_role: "admin", app: app_a, client_id: "cid_fake_app_a")
      a2, _ = Facet::IAM::RedisSession.create_app_session(account_id: account_id, active_role: "admin", app: app_a, client_id: "cid_fake_app_a")
      b1, _ = Facet::IAM::RedisSession.create_app_session(account_id: account_id, active_role: "admin", app: app_b, client_id: "cid_fake_app_b")

      token = login_token("apprevoke@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("DELETE", "/Api/iam/apps/#{app_a}/sessions", headers: headers))
      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["ok"].as_bool.should be_true
      body["revoked"].as_i.should eq(2)

      Facet::IAM::RedisSession.load(a1).should be_nil
      Facet::IAM::RedisSession.load(a2).should be_nil
      # Other-app session survives.
      Facet::IAM::RedisSession.load(b1).should_not be_nil
    end
  end
end
