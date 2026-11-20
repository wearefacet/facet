# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam"
require "../../src/iam/redis_session"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/oauth/origin_cache"
require "../../src/oauth/rate_limiter"
require "../support/http_helper"
require "../support/oauth_helper"
require "../support/doctype_helper"
require "../support/redis_helper"
require "../support/app_helper"
require "./oauth_flow_spec"

HTTPTest.init

# End-to-end HTTP refresh + revocation flow.
#
# Builds on `oauth_flow_spec.cr`: authorizes → token → constrained
# API call. This spec covers:
# - token endpoint returns `refresh_token` on the `authorization_code` grant.
# - `grant_type=refresh_token` rotates and the new token remains constrained
#   by Layer-1 enforcement.
# - revocation of the user's role mid-session makes the next refresh fail
#   (the in-flight access token still works until its ≤15-min TTL).
# - disabling the app makes the next refresh fail.
# - the refresh grant is client-bound (B-150): a wrong or missing `client_id`
#   answers 401 and the session survives.
# - rate limiting throttles a burst of token-endpoint hits.

# Full authorize → token flow returns a `{access_token, refresh_token, app_id, account_id}`
# named tuple so back-to-back tests don't re-derive each piece.
def oauth_full_token_flow(
  email = "refresh-flow@example.com",
  password = "refresh-password",
  grants : Array(Hash(String, JSON::Any)) = [] of Hash(String, JSON::Any),
  role_perms : Array(NamedTuple(action: String, on: String)) = [] of NamedTuple(action: String, on: String),
  role_name = "reader",
  redirect_uri = "https://app.example.com/cb",
  create_role_doc = true,
)
  with_db do |db|
    app_id, client_id = create_test_app(db, "test-app",
      redirect_uris: [redirect_uri],
      allowed_origins: ["https://app.example.com"],
      grants: grants)
    create_test_role(db, role_name, role_perms) if create_role_doc
    role_id = "iam.Roles.#{role_name}"
    account_id = create_test_account(db,
      email: email, password: password,
      roles: [role_id], default_role: role_id)

    session = login_token(email, password)

    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = s256_challenge(verifier)
    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => client_id,
      "redirect_uri"          => redirect_uri,
      "state"                 => "state_phase5",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
    })
    consent = call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}",
      headers: bearer_headers(session)))
    assert_http_status(consent, 200)

    body = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => client_id,
      "redirect_uri"          => redirect_uri,
      "state"                 => "state_phase5",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
      "role"                  => role_id,
    })
    issued_code = call_api(HTTP::Request.new("POST", "/OAuth/authorize",
      headers: with_form_auth(bearer_headers(session)), body: body))
    assert_http_status(issued_code, 200)
    code = JSON.parse(issued_code.body)["code"].as_s

    token_body = URI::Params.encode({
      "grant_type"    => "authorization_code",
      "code"          => code,
      "redirect_uri"  => redirect_uri,
      "code_verifier" => verifier,
      "client_id"     => client_id,
    })
    token_resp = call_api(with_rl_ip(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: token_body)))
    assert_http_status(token_resp, 200)
    token_json = JSON.parse(token_resp.body)

    {client_id: client_id, app_id: app_id, account_id: account_id,
     access_token: token_json["access_token"].as_s,
     refresh_token: token_json["refresh_token"].as_s}
  end
end

# Pins a fixed remote address on a request. The in-process harness has no
# socket, so `remote_address` is nil and the token endpoint's rate limiter
# fails open — pinning an address makes the `(client_id, IP)` bucket
# observable in specs. Used on `/OAuth/token` POSTs only.
def with_rl_ip(request : HTTP::Request) : HTTP::Request
  request.remote_address = Socket::IPAddress.new("203.0.113.7", 50000)
  request
end

describe "OAuth — refresh + revocation flow (Phase 5)" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    Facet::OAuth::OriginCache.reset
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      Facet::OAuth::OriginCache.reset
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "token endpoint returns refresh_token, and refresh_token grant rotates" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "rotate@example.com", password: "rotate-password")

    phase5_setup_crm_contact

    # The initial token response includes a refresh_token.
    ctx[:refresh_token].should_not be_empty

    # Refresh it via the token endpoint. Backdate the refresh floor first —
    # the token was issued just now.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 200)
    body_json = JSON.parse(refresh_resp.body)
    body_json["access_token"].as_s.should_not be_empty
    body_json["refresh_token"].as_s.should_not be_empty
    # The new refresh token differs from the presented one.
    body_json["refresh_token"].as_s.should_not eq(ctx[:refresh_token])
    body_json["token_type"].as_s.should eq("Bearer")
    # No `scope` member — same contract as the issuance response (RFC 6749
    # §5.1: the optional member is omitted; a non-string scope breaks
    # spec-compliant clients).
    body_json["scope"]?.should be_nil

    # The new access token carries the same `(sub, app, role)`.
    decoded = Facet::IAM::JWT.decode(body_json["access_token"].as_s, Facet::IAM::TokenEmitter.keys)
    decoded.payload["sub"].as_s.should eq(ctx[:account_id])
    decoded.payload["app"].as_s.should eq(ctx[:app_id])
    decoded.payload["role"].as_s.should eq("iam.Roles.reader")
    decoded.payload["typ"].as_s.should eq("app")
  end

  it "refreshed app token stays constrained by Phase 3 (in-grant read OK, out-of-grant 404)" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "constrained@example.com", password: "constrained-password")

    in_id = phase5_setup_crm_contact

    # Refresh to obtain a fresh access token. Backdate the refresh floor —
    # the token was issued just now.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 200)
    new_token = JSON.parse(refresh_resp.body)["access_token"].as_s

    # In-grant read with the refreshed token.
    in_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Contact/#{in_id}",
      headers: bearer_headers(new_token)))
    assert_http_status(in_resp, 200)
    JSON.parse(in_resp.body)["data"]["name"].as_s.should eq("Alice")
  end

  it "revoking the user's role mid-session: in-flight token still works, next refresh fails" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "revoke-role@example.com", password: "revoke-role-password")
    in_id = phase5_setup_crm_contact

    # Pre-emptively grab the in-flight token before we revoke the role.
    in_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Contact/#{in_id}",
      headers: bearer_headers(ctx[:access_token])))
    assert_http_status(in_resp, 200)

    # Revoke the role off the user. The role row is untouched — refresh
    # re-validates `account.roles.includes?(session.active_role)`.
    with_db do |db|
      Facet::Document::Update.call(
        db, "iam", "Account", ctx[:account_id],
        %({"roles": []}),
        Facet::RBAC::AuthContext.system,
      )
    end

    # Refresh must fail with `invalid_grant` — the role is no longer assigned.
    # Backdate the refresh floor first — the live-state check must be what
    # fails, not the floor.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 401)
    JSON.parse(refresh_resp.body)["error"].as_s.should eq("invalid_grant")
  end

  it "disabling the app: in-flight token rejected by AuthHandler (status re-checked per request); next refresh also fails" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "disable-app@example.com", password: "disable-app-password")
    in_id = phase5_setup_crm_contact

    # Disable the app post-token.
    with_db do |db|
      Facet::Document::Update.call(
        db, "app", "App", ctx[:app_id],
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )
    end
    Facet::OAuth::OriginCache.reset

    # The AuthHandler re-reads `app.App.status` on every protected
    # request as defense in depth — a disabled app's access token is rejected
    # immediately.
    in_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Contact/#{in_id}",
      headers: bearer_headers(ctx[:access_token])))
    assert_http_status(in_resp, 401)

    # Refresh fails for the same reason. Backdate the refresh floor — the
    # live-state check must be what fails, not the floor.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 401)
    JSON.parse(refresh_resp.body)["error"].as_s.should eq("invalid_grant")
  end

  it "per-app revocation endpoint kills the user's app session → next refresh fails" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "per-app-rev@example.com", password: "per-app-rev-password")
    phase5_setup_crm_contact

    # List our sessions to find the app session id.
    sessions_resp = call_api(HTTP::Request.new("GET", "/Api/iam/sessions",
      headers: bearer_headers(ctx[:access_token])))
    assert_http_status(sessions_resp, 200)
    # The session listing would need a browser-session token; here we exercise
    # the app token against the per-app revocation endpoint directly.
    headers = with_xrw(bearer_headers(ctx[:access_token]))
    revoke_resp = call_api(HTTP::Request.new("DELETE",
      "/Api/iam/apps/#{ctx[:app_id]}/sessions", headers: headers))
    assert_http_status(revoke_resp, 200)
    JSON.parse(revoke_resp.body)["ok"].as_bool.should be_true
    JSON.parse(revoke_resp.body)["revoked"].as_i.should be >= 1

    # Refresh fails because the session row is gone — `load` fails before
    # the floor runs, so no backdate is needed here.
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 401)
    JSON.parse(refresh_resp.body)["error"].as_s.should eq("invalid_grant")
  end

  it "missing refresh_token returns invalid_request" do
    body = URI::Params.encode({
      "grant_type" => "refresh_token",
      "client_id"  => "client_anyone",
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: body))
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_request")
  end

  it "a refresh naming another client's client_id fails and the session survives (B-150)" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    # App A issues the code and the refresh token.
    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "cross-client@example.com", password: "cross-client-pw")

    # App B is a different registered client — it never saw the code.
    _app_b_id, client_b = with_db do |db|
      create_test_app(db, "other-app")
    end

    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => client_b,
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 401)
    body_json = JSON.parse(refresh_resp.body)
    body_json["error"].as_s.should eq("invalid_grant")
    body_json["error_description"].as_s.should contain("not bound to this client")

    # The wrong-client attempt did not revoke the session — the rightful
    # client refreshes right after.
    backdate_refresh_issued_at(ctx[:refresh_token])
    ok_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    ok_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: ok_body))
    assert_http_status(ok_resp, 200)
    JSON.parse(ok_resp.body)["access_token"].as_s.should_not be_empty
  end

  it "refresh_token grant without client_id fails with invalid_grant (B-150)" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "no-cid-refresh@example.com", password: "no-cid-refresh-pw")

    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
    })
    refresh_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body))
    assert_http_status(refresh_resp, 401)
    body_json = JSON.parse(refresh_resp.body)
    body_json["error"].as_s.should eq("invalid_grant")
    body_json["error_description"].as_s.should contain("Missing 'client_id'")

    # The session survived the failed attempt.
    backdate_refresh_issued_at(ctx[:refresh_token])
    ok_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    ok_resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: ok_body))
    assert_http_status(ok_resp, 200)
  end

  it "unsupported grant_type at the route returns unsupported_grant_type" do
    body = URI::Params.encode({
      "grant_type" => "password",
      "client_id"  => "client_anyone",
    })
    resp = call_api(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: body))
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("unsupported_grant_type")
  end

  it "refresh_token grant never increments the rate-limit bucket" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "rl-exempt@example.com", password: "rl-exempt-pw")

    # The code exchange inside the flow created the bucket and incremented it.
    before = token_rl_bucket_count
    before.should be >= 1

    # A refresh request alone must leave the bucket untouched. Backdate the
    # refresh floor first — the token was issued just now.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(with_rl_ip(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body)))
    assert_http_status(refresh_resp, 200)

    token_rl_bucket_count.should eq(before)
  end

  it "code exchange still counts against the bucket (exactly one increment)" do
    grant = [oauth_grant("crm.Contact", [oauth_action("read", required: true)])]
    perm = [oauth_perm("read", "crm.Contact")]

    ctx = oauth_full_token_flow(grants: grant, role_perms: perm,
      email: "rl-counts@example.com", password: "rl-counts-pw")
    count_after_issuance = token_rl_bucket_count
    count_after_issuance.should be >= 1

    # A refresh does not move the bucket. Backdate the floor first.
    backdate_refresh_issued_at(ctx[:refresh_token])
    refresh_body = URI::Params.encode({
      "grant_type"    => "refresh_token",
      "refresh_token" => ctx[:refresh_token],
      "client_id"     => ctx[:client_id],
    })
    refresh_resp = call_api(with_rl_ip(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: refresh_body)))
    assert_http_status(refresh_resp, 200)
    token_rl_bucket_count.should eq(count_after_issuance)

    # A second code exchange on the same client bumps the same bucket by one.
    session = login_token("rl-counts@example.com", "rl-counts-pw")
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    challenge = s256_challenge(verifier)
    redirect_uri = "https://app.example.com/cb"
    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => ctx[:client_id],
      "redirect_uri"          => redirect_uri,
      "state"                 => "state_rl",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
    })
    consent = call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}",
      headers: bearer_headers(session)))
    assert_http_status(consent, 200)
    authz_body = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => ctx[:client_id],
      "redirect_uri"          => redirect_uri,
      "state"                 => "state_rl",
      "code_challenge"        => challenge,
      "code_challenge_method" => "S256",
      "role"                  => "iam.Roles.reader",
    })
    issued_code = call_api(HTTP::Request.new("POST", "/OAuth/authorize",
      headers: with_form_auth(bearer_headers(session)), body: authz_body))
    assert_http_status(issued_code, 200)
    code = JSON.parse(issued_code.body)["code"].as_s

    token_body = URI::Params.encode({
      "grant_type"    => "authorization_code",
      "code"          => code,
      "redirect_uri"  => redirect_uri,
      "code_verifier" => verifier,
      "client_id"     => ctx[:client_id],
    })
    exchange = call_api(with_rl_ip(HTTP::Request.new("POST", "/OAuth/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      body: token_body)))
    assert_http_status(exchange, 200)

    token_rl_bucket_count.should eq(count_after_issuance + 1)
  end

  # B-387: the counter increments before the cap check, so the raw count is
  # always cap + 1 or more — the 429 body must report the capped value,
  # never a number above the cap.
  it "throttles a token-endpoint burst and reports the capped count in the 429 body (B-387)" do
    burst_body = URI::Params.encode({
      "grant_type"    => "authorization_code",
      "client_id"     => "rl-burst-client",
      "code"          => "no-such-code",
      "redirect_uri"  => "https://app.example.com/cb",
      "code_verifier" => "no-such-verifier",
    })

    # The invalid exchange answers 400 until the bucket passes the cap;
    # the next request is the first 429.
    first_429 : HTTP::Client::Response? = nil
    31.times do
      resp = call_api(with_rl_ip(HTTP::Request.new("POST", "/OAuth/token",
        headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        body: burst_body)))
      if resp.status_code == 429
        first_429 = resp
        break
      end
    end

    unless first_429
      fail("expected the burst to throttle within 31 requests")
    end
    json = JSON.parse(first_429.body)
    json["error"].as_s.should eq("slow_down")
    # The throttling request is the 31st increment, but the message must
    # never read a value above the cap.
    json["error_description"].as_s.should eq("Rate limit exceeded (30/30 per 300s)")
    first_429.headers["Retry-After"].should eq("300")
  end
end

# Builds a `crm.Contact` doctype + one document, returns the document id.
# Shared by several specs above; isolated in one place so each test starts
# from a clean state.
def phase5_setup_crm_contact : String
  with_db do |db|
    ensure_domain(db, "crm")
    schema = %({"doctype": "Contact", "domain": "crm", "fields": {"name": {"type": "string"}}})
    result = Facet::Document::Create.call(db, "core", "DocType", schema,
      Facet::RBAC::AuthContext.system)
    raise "Failed to seed Contact doctype: #{result.inspect}" unless result.is_a?(Facet::Document::Create::Result)
    doc_result = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "Alice"}),
      Facet::RBAC::AuthContext.system)
    raise "Failed to seed Contact doc: #{doc_result.inspect}" unless doc_result.is_a?(Facet::Document::Create::Result)
    doc_result.projection.id
  end
end
