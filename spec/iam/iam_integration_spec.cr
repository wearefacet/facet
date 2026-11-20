# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/iam/totp"
require "../../src/http/server"
require "../support/http_helper"
require "json"

# Initialize HTTP handler chain once (idempotent across spec files)
HTTPTest.init

describe "IAM HTTP Integration" do
  before_each do
    redis_cleanup
  end

  after_each do
    redis_cleanup
  end

  it "POST /Api/iam/login succeeds for valid credentials" do
    with_db do |db|
      create_test_account(db)
    end

    body = %({"email": "test@example.com", "password": "test-password", "cookie": false})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["token"]?.should_not be_nil
    json["token"].to_s.should_not be_empty
    json["refresh_token"]?.should_not be_nil
    json["refresh_token"].to_s.should_not be_empty
    json["active_role"].to_s.should eq("iam.Roles.admin")
    json["expires_at"]?.should_not be_nil
    json["expires_at"].as_i.should be > Time.utc.to_unix
    account = json["account"].as_h
    account["id"]?.should_not be_nil
    account["id"].to_s.should_not be_empty
    account["email"]?.should_not be_nil
    account["mfa_enabled"].as_bool.should be_false
  end

  it "POST /Api/iam/login rejects invalid credentials" do
    with_db do |db|
      create_test_account(db)
    end

    body = %({"email": "test@example.com", "password": "wrong-password", "cookie": false})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 401)
    json = JSON.parse(response.body).as_h
    json["error"]?.should_not be_nil
  end

  it "POST /Api/iam/login requires X-Requested-With header" do
    body = %({"email": "test@example.com", "password": "test-password", "cookie": false})
    request = HTTP::Request.new("POST", "/Api/iam/login", body: body)
    response = call_api_raw(request)

    assert_http_status(response, 403)
    json = JSON.parse(response.body).as_h
    json["error"]?.should_not be_nil
    json["error"].to_s.should contain("CSRF")
  end

  it "POST /Api/iam/login returns mfa challenge when the account has MFA enabled" do
    with_db do |db|
      account_id = create_test_account(db, mfa_enabled: true)
      secret = Facet::IAM::TOTP.generate_secret
      doc_ref = "iam.Account.#{account_id}"
      Facet::Secrets.set(db, doc_ref, "mfa", secret,
        mode: "sealed", set_by: "system", meta: {"mfa_type" => "totp"})
      Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, 0_i64)
    end

    body = %({"email": "test@example.com", "password": "test-password", "cookie": false})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["mfa"].as_bool.should be_true
    json["challenge_id"]?.should_not be_nil
    json["challenge_id"].to_s.should_not be_empty
    json["type"].to_s.should eq("totp")
  end

  it "POST /Api/iam/challenge completes the MFA flow" do
    secret = Facet::IAM::TOTP.generate_secret
    account_id = nil
    with_db do |db|
      uid = create_test_account(db, mfa_enabled: true)
      account_id = uid
      doc_ref = "iam.Account.#{account_id}"
      Facet::Secrets.set(db, doc_ref, "mfa", secret,
        mode: "sealed", set_by: "system", meta: {"mfa_type" => "totp"})
      Facet::IAM::AuthState.try_advance_totp_step(db, doc_ref, 0_i64)
    end

    challenge_id = Facet::Util::ScriptHelpers.ulid
    uid_val = account_id.as(String)
    with_redis do |r|
      r.hset("challenge:#{challenge_id}",
        "account_id", uid_val,
        "active_role", "iam.Roles.admin",
        "type", "totp",
        "cookie_requested", "false",
        "attempts_remaining", "5")
      r.expire("challenge:#{challenge_id}", 300)
    end

    code = Facet::IAM::TOTP.generate(secret)
    body = %({"challenge_id": "#{challenge_id}", "result": "#{code}"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/challenge", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["token"]?.should_not be_nil
    json["token"].to_s.should_not be_empty
    json["refresh_token"]?.should_not be_nil
    json["refresh_token"].to_s.should_not be_empty
  end

  it "POST /Api/iam/refresh rotates tokens" do
    refresh_token = nil
    with_db do |db|
      result = create_session_and_refresh_token(db)
      refresh_token = result[:refresh_token]
    end

    # No `cookie` flag — the session is cookie-mode, so the flag defaults
    # to true and the rotated tokens ride the Set-Cookie headers.
    body = %({"refresh_token": "#{refresh_token}"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/refresh", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["token"]?.should be_nil
    json["refresh_token"]?.should be_nil
    json["expires_at"]?.should_not be_nil
    json["expires_at"].as_i.should be > Time.utc.to_unix
    response.headers["Set-Cookie"]?.should_not be_nil
  end

  it "POST /Api/iam/refresh keeps a body-mode login refreshable with cookie: false (B-278)" do
    with_db do |db|
      create_test_account(db)
    end

    login_body = %({"email": "test@example.com", "password": "test-password", "cookie": false})
    login_headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    login_resp = call_api(HTTP::Request.new("POST", "/Api/iam/login", headers: login_headers, body: login_body))
    assert_http_status(login_resp, 200)
    login_json = JSON.parse(login_resp.body).as_h
    refresh_token = login_json["refresh_token"].to_s

    # The trap: an unflagged refresh on a body-mode session answers 422 and
    # rotates nothing — the same token still works afterwards.
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    wrong_resp = call_api(HTTP::Request.new("POST", "/Api/iam/refresh",
      headers: headers, body: %({"refresh_token": "#{refresh_token}"})))
    assert_http_status(wrong_resp, 422)

    refresh_resp = call_api(HTTP::Request.new("POST", "/Api/iam/refresh",
      headers: headers, body: %({"refresh_token": "#{refresh_token}", "cookie": false})))
    assert_http_status(refresh_resp, 200)
    refresh_json = JSON.parse(refresh_resp.body).as_h
    refresh_json["token"]?.should_not be_nil
    refresh_json["refresh_token"]?.should_not be_nil
    refresh_json["refresh_token"].to_s.should_not eq(refresh_token)
  end

  it "POST /Api/iam/logout destroys the session" do
    session_id = nil
    account_id = nil
    with_db do |db|
      uid = create_test_account(db)
      sid, _ = Facet::IAM::RedisSession.create(account_id: uid, active_role: "iam.Roles.admin")
      account_id = uid
      session_id = sid
    end

    uid_val = account_id.as(String)
    sid_val = session_id.as(String)
    pem_key = Facet::IAM::TokenEmitter.signing_key
    payload, _exp = Facet::IAM::JWT.build_access_payload(uid_val, sid_val, "iam.Roles.admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")

    headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{token}",
    }
    request = HTTP::Request.new("POST", "/Api/iam/logout", headers: headers)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["ok"].as_bool.should be_true

    Facet::IAM::RedisSession.load(sid_val).should be_nil
  end

  it "POST /Api/iam/mfa/disable rejects non-admin users" do
    account_id = nil
    with_db do |db|
      account_id = create_test_account(db)
    end

    pem_key = Facet::IAM::TokenEmitter.signing_key
    payload, _exp = Facet::IAM::JWT.build_access_payload(account_id.as(String), "fake-session", "iam.Roles.editor")
    token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")

    headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{token}",
    }
    body = %({"account_id": "#{account_id.as(String)}"})
    request = HTTP::Request.new("POST", "/Api/iam/mfa/disable", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 403)
    response.body.should contain("Forbidden")
  end

  it "POST /Api/iam/mfa/totp/setup returns secret and URI" do
    account_id = nil
    with_db do |db|
      account_id = create_test_account(db)
    end

    pem_key = Facet::IAM::TokenEmitter.signing_key
    payload, _exp = Facet::IAM::JWT.build_access_payload(account_id.as(String), "fake-sid", "iam.Roles.admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")

    headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{token}",
    }
    body = %({"account": "test@example.com"})
    request = HTTP::Request.new("POST", "/Api/iam/mfa/totp/setup", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["secret"]?.should_not be_nil
    json["secret"].to_s.should_not be_empty
    json["otpauth_uri"]?.should_not be_nil
    json["otpauth_uri"].to_s.should start_with("otpauth://totp/")
  end

  it "POST /Api/iam/mfa/totp/verify enables MFA" do
    account_id = nil
    secret = nil
    with_db do |db|
      uid = create_test_account(db)
      result = Facet::IAM::MFA.setup(db, uid, "test@example.com")
      case result
      in Facet::IAM::MFA::SetupResult
        secret = result.secret
      in Facet::ServiceError
        raise "MFA setup failed: #{result.message}"
      end
      account_id = uid
    end

    code = Facet::IAM::TOTP.generate(secret.not_nil!)

    pem_key = Facet::IAM::TokenEmitter.signing_key
    payload, _exp = Facet::IAM::JWT.build_access_payload(account_id.as(String), "fake-sid", "iam.Roles.admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")

    headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{token}",
    }
    body = %({"code": "#{code}"})
    request = HTTP::Request.new("POST", "/Api/iam/mfa/totp/verify", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["mfa_enabled"].as_bool.should be_true
    # The enrollment response carries the raw backup codes shown once.
    json["backup_codes"].as_a.size.should eq(Facet::IAM::BackupCodes::COUNT)
  end

  # ── GET /Api/iam/me ───────────────────────────────────────────────────

  it "GET /Api/iam/me returns account profile, permissions, and expires_at" do
    account_id = nil
    with_db do |db|
      account_id = create_test_account(db)
    end

    pem_key = Facet::IAM::TokenEmitter.signing_key
    payload, exp = Facet::IAM::JWT.build_access_payload(account_id.as(String), "fake-sid", "iam.Roles.admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "facet-1")

    request = HTTP::Request.new("GET", "/Api/iam/me", headers: HTTP::Headers{"Cookie" => "auth_token=#{token}"})
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["account"]["id"].to_s.should eq(account_id.as(String))
    json["account"]["display_name"].should_not be_nil
    json["active_role"].to_s.should eq("iam.Roles.admin")
    json["available_roles"].as_a.map(&.as_s).should eq(["iam.Roles.admin", "iam.Roles.editor"])
    json["expires_at"].as_i.should eq(exp)
    json["permissions"]?.should_not be_nil
    json["account"]["mfa_enabled"].as_bool.should be_false
    # The enforcement value is the effective policy (the SystemSettings
    # document pins it when set; the file value is the fallback). The spec
    # suite runs with the seed document all-null, so the file tier — read
    # through the policy module — is what surfaces.
    effective = Facet::Database.with_db { |db| Facet::IAM::Policy.mfa_enforcement(db) }
    json["account"]["mfa_enforcement"].to_s.should eq(effective)
    effective_type = Facet::Database.with_db { |db| Facet::IAM::Policy.mfa_type(db) }
    json["account"]["mfa_type"].to_s.should eq(effective_type)
    # The active role's field-tag visibility set (B-176) rides the response:
    # the seeded admin carries the wildcard tag, so every field is visible.
    json["visible_tags"].as_a.map(&.as_s).should contain("*")
  end

  it "GET /Api/iam/me returns 401 when not authenticated" do
    request = HTTP::Request.new("GET", "/Api/iam/me")
    response = call_api(request)

    # AuthHandler is disabled in test mode, so the route itself checks for
    # the token and returns 401 when extract_account_id returns nil.
    assert_http_status(response, 401)
  end

  it "GET /Api/iam/me reports assistant access off for a role whose connectivity excludes it" do
    account_id = nil
    with_db do |db|
      # A role with an explicit empty connectivity list — the browser-only
      # shape. `seed_test_roles` gives its fixtures the full list, so this
      # one is written directly.
      content = {
        "name"         => "channelless",
        "description"  => "Browser-only role",
        "permissions"  => [{"action" => "read", "on" => "*.*"}],
        "connectivity" => [] of String,
      }
      Facet::Mutation::Client.create(
        db, "iam", "Roles",
        doc_id: "iam.Roles.channelless",
        content: content.to_json,
        actioner_id: "system",
      )
      account_id = create_test_account(db, roles: ["iam.Roles.channelless"], default_role: "iam.Roles.channelless")
    end

    token = me_token(account_id.as(String), "iam.Roles.channelless")
    request = HTTP::Request.new("GET", "/Api/iam/me", headers: HTTP::Headers{"Cookie" => "auth_token=#{token}"})
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    assistant = json["assistant"].as_h
    assistant["access"].as_bool.should be_false
    assistant["token_budget"].raw.should be_nil
    # The active role's connectivity rides the payload — the browser-only
    # shape is an empty list (the frontend hides the channel affordances).
    json["connectivity"].as_a.should be_empty
    # `configured` is installation-wide, not role-shaped: no API key
    # resolves in the suite's file tier (config.test.yml) and nothing is
    # pinned — the unconfigured posture the frontend disables on.
    assistant["configured"].as_bool.should be_false
  end

  it "GET /Api/iam/me reports assistant access on and mirrors the role budget" do
    account_id = nil
    with_db do |db|
      # A custom role carrying the flag and a budget. Created through the
      # same low-level path `seed_test_roles` uses — the mutation pipeline
      # needs no doctype definition.
      content = {
        "name"                   => "budgeted",
        "description"            => "Assistant-enabling role with a budget",
        "permissions"            => [{"action" => "read", "on" => "*.*"}],
        "connectivity"           => ["assistant"],
        "assistant_token_budget" => 25000,
      }
      Facet::Mutation::Client.create(
        db, "iam", "Roles",
        doc_id: "iam.Roles.budgeted",
        content: content.to_json,
        actioner_id: "system",
      )
      account_id = create_test_account(db, roles: ["iam.Roles.budgeted"], default_role: "iam.Roles.budgeted")
    end

    token = me_token(account_id.as(String), "iam.Roles.budgeted")
    request = HTTP::Request.new("GET", "/Api/iam/me", headers: HTTP::Headers{"Cookie" => "auth_token=#{token}"})
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    assistant = json["assistant"].as_h
    assistant["access"].as_bool.should be_true
    assistant["token_budget"].as_i.should eq(25000)
    # The display name always resolves — the file tier carries the
    # "Assistant" default when no document pin exists.
    assistant["name"].as_s.should eq("Assistant")
    json["connectivity"].as_a.map(&.as_s).should eq(["assistant"])
    # `configured` stays off with the suite's unset file key — access and
    # configuration are independent signals.
    assistant["configured"].as_bool.should be_false
  end

  # ── Optional-field type safety (DF-2 regression class) ──────────────
  #
  # The auth routes read their optional fields with `as_s?` / `as_bool?`:
  # a wrong-typed value is treated as absent instead of raising through
  # the JSON cast and answering 500. One example per endpoint pins the
  # normal status for the malformed-input shape.

  it "POST /Api/iam/login ignores a wrong-typed role hint and cookie flag" do
    with_db do |db|
      create_test_account(db)
    end

    body = %({"email": "test@example.com", "password": "test-password", "role": 42, "cookie": "yes"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body)
    response = call_api(request)

    # `cookie: "yes"` is treated as absent — the default cookie mode
    # engages, so the tokens ride the Set-Cookie headers, not the body.
    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["account"]?.should_not be_nil
    response.headers["Set-Cookie"]?.should_not be_nil
  end

  it "POST /Api/iam/refresh treats a wrong-typed body token as absent (401, not 500)" do
    body = %({"refresh_token": 42, "role": 42, "cookie": "yes"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/refresh", headers: headers, body: body)
    response = call_api(request)

    # No cookie fallback either — the normal missing-token answer.
    assert_http_status(response, 401)
    response.body.should contain("Missing refresh token")
  end

  it "POST /Api/iam/refresh ignores wrong-typed role and cookie fields" do
    refresh_token = nil
    with_db do |db|
      result = create_session_and_refresh_token(db)
      refresh_token = result[:refresh_token]
    end

    body = %({"refresh_token": "#{refresh_token}", "role": 42, "cookie": "yes"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/refresh", headers: headers, body: body)
    response = call_api(request)

    # `cookie: "yes"` is treated as absent — the default cookie mode
    # engages, so the rotated tokens ride the Set-Cookie headers.
    assert_http_status(response, 200)
    response.headers["Set-Cookie"]?.should_not be_nil
  end

  it "POST /Api/iam/mfa/totp/setup falls back to the account id on a wrong-typed account field" do
    account_id = nil
    with_db do |db|
      account_id = create_test_account(db)
    end

    token = me_token(account_id.as(String), "iam.Roles.admin")
    headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{token}",
    }
    body = %({"account": 42})
    request = HTTP::Request.new("POST", "/Api/iam/mfa/totp/setup", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["secret"]?.should_not be_nil
    json["otpauth_uri"]?.should_not be_nil
  end

  it "POST /Api/iam/change-password treats a wrong-typed change_token as absent (401, not 500)" do
    body = %({"change_token": 42, "old_password": "test-password", "new_password": "new-password-123"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/change-password", headers: headers, body: body)
    response = call_api(request)

    # No session either — the normal unauthenticated answer.
    assert_http_status(response, 401)
  end

  it "POST /Api/iam/change-password tells a retry that the change succeeded when the token was already used" do
    account_id = with_db do |db|
      create_test_account(db)
    end

    token = Facet::IAM::PwdChangeToken.create_pwd_change_token(account_id, 3600)
    body = %({"change_token": "#{token}", "old_password": "test-password", "new_password": "new-password-123"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/change-password", headers: headers, body: body)
    response = call_api(request)
    assert_http_status(response, 200)

    # The retry finds no token but the used marker. It answers a distinct
    # message instead of "invalid or expired" — the change committed.
    retry_response = call_api(HTTP::Request.new("POST", "/Api/iam/change-password", headers: headers, body: body))
    assert_http_status(retry_response, 401)
    retry_response.body.should contain("already used")
    retry_response.body.should_not contain("invalid or expired")
  end

  it "POST /Api/iam/password-reset/confirm ignores a wrong-typed cookie flag (422, not 500)" do
    # The missing required token answers 422 before anything else — the
    # point is that the wrong-typed `cookie` field does not raise first.
    body = %({"token": 42, "new_password": "new-password-123", "cookie": "yes"})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/password-reset/confirm", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 422)
    response.body.should contain("token")
  end

  it "POST /Api/iam/password-reset/confirm accepts a roleless invite under the anonymous role (B-120)" do
    token = with_db do |db|
      # The anonymous role is a production seed; the lighter `seed_test_roles`
      # does not create it, so seed the full role set first.
      ensure_seed_roles_with_dependencies(db)
      account_id = create_test_account(db, email: "invitee@example.com", status: "pending",
        roles: [] of String, default_role: nil)
      # A first-invite account holds no `password` slot yet.
      Facet::Secrets.clear(db, "iam.Account.#{account_id}", "password")
      mint_reset_token(db, account_id)
    end

    body = %({"token": #{token.to_json}, "new_password": "new-password-123", "cookie": false})
    headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    request = HTTP::Request.new("POST", "/Api/iam/password-reset/confirm", headers: headers, body: body)
    response = call_api(request)

    assert_http_status(response, 200)
    json = JSON.parse(response.body).as_h
    json["active_role"].to_s.should eq(Facet::IAM::ANONYMOUS_ROLE_ID)
    json["available_roles"].as_a.should be_empty
    json["token"].to_s.should_not be_empty
  end
end

# Signs a test access token for the `/Api/iam/me` cookie flow — same
# construction the happy-path `me` example uses, parameterized on the
# role claim.
private def me_token(account_id : String, role : String) : String
  pem_key = Facet::IAM::TokenEmitter.signing_key
  payload, _exp = Facet::IAM::JWT.build_access_payload(account_id, "fake-sid", role)
  Facet::IAM::JWT.sign(payload, pem_key, "facet-1")
end
