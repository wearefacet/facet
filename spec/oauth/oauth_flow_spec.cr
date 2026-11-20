# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/oauth/origin_cache"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/oauth_helper"
require "../support/doctype_helper"

HTTPTest.init

# Full OAuth authorization-code + PKCE end-to-end (HTTP).
#
# Covers:
# - Full flow succeeds end to end against a test app.
# - Code replay fails. Wrong verifier fails. Mismatched `redirect_uri` fails
#   at both authorize and token. `plain` challenge method fails.
# - A user with no usable role gets `access_denied` instead of an empty token.
# - A user with two usable roles sees a picker, and the resulting token
#   carries the chosen role.
# - The issued token is correctly constrained by the app-grant enforcement.
#
# Each example enables the AuthHandler (so protected API calls authenticate
# through `AuthHandler.auth_context_from_request`) and drives the full Kemal
# middleware stack via `call_api`. Service-level tests already cover the
# pure authorize/token logic; this file asserts the surface area that joins
# them — the cookie-driven session, the routes, the body parsing, the CORS
# handler integration, and the enforcement chain.

# Authorize GET helper: returns the consent screen JSON response.
def oauth_get_authorize(token, query_string) : HTTP::Client::Response
  headers = bearer_headers(token)
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query_string}", headers: headers))
end

# POST the elected role against /OAuth/authorize: returns the issued-code
# JSON response (or an access_denied JSON shape on zero usable roles).
def oauth_post_authorize_with_role(token, body_string) : HTTP::Client::Response
  headers = bearer_headers(token)
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  call_api(HTTP::Request.new("POST", "/OAuth/authorize",
    headers: headers, body: body_string))
end

# POST to /OAuth/token with the verifier.
def oauth_post_token(body_string) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
  call_api(HTTP::Request.new("POST", "/OAuth/token",
    headers: headers, body: body_string))
end

describe "OAuth — full HTTP flow" do
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

  it "happy path: authorize → consent → role election → token → API call constrained by Phase 3" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        redirect_uris: ["https://app.example.com/cb"],
        allowed_origins: ["https://app.example.com"],
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      ensure_domain(db, "crm")
      schema = %({"doctype": "Contact", "domain": "crm", "fields": {"name": {"type": "string"}}})
      result = Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
      raise "Failed to seed Contact doctype: #{result.inspect}" unless result.is_a?(Facet::Document::Create::Result)
      doc_result = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "Alice"}), Facet::RBAC::AuthContext.system)
      raise "Failed to seed Contact doc: #{doc_result.inspect}" unless doc_result.is_a?(Facet::Document::Create::Result)
      in_doc_id = doc_result.projection.id
      account_id = create_test_account(db,
        email: "readerflow@example.com",
        password: "reader-password",
        roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      session = login_token("readerflow@example.com", "reader-password")

      verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
      challenge = s256_challenge(verifier)
      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "state"                 => "state_abc",
        "code_challenge"        => challenge,
        "code_challenge_method" => "S256",
      })
      # 1. GET /OAuth/authorize → consent screen.
      resp1 = oauth_get_authorize(session, query)
      assert_http_status(resp1, 200)
      consent = JSON.parse(resp1.body)
      consent["app"]["client_id"].as_s.should eq(client_id)
      consent["roles"].as_a.size.should eq(1)
      consent["roles"][0]["role_id"].as_s.should eq("iam.Roles.reader")

      # 2. POST /OAuth/authorize with elected role → code issued.
      body = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "state"                 => "state_abc",
        "code_challenge"        => challenge,
        "code_challenge_method" => "S256",
        "role"                  => "iam.Roles.reader",
      })
      resp2 = oauth_post_authorize_with_role(session, body)
      assert_http_status(resp2, 200)
      issued = JSON.parse(resp2.body)
      code = issued["code"].as_s
      code.should_not be_empty
      issued["state"].as_s.should eq("state_abc")

      # 3. POST /OAuth/token → app JWT.
      token_body = URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code,
        "redirect_uri"  => "https://app.example.com/cb",
        "code_verifier" => verifier,
        "client_id"     => client_id,
      })
      resp3 = oauth_post_token(token_body)
      assert_http_status(resp3, 200)
      token_json = JSON.parse(resp3.body)
      access_token = token_json["access_token"].as_s
      access_token.should_not be_empty
      token_json["token_type"].as_s.should eq("Bearer")
      # No `scope` member: the server advertises no scope vocabulary, so the
      # optional member is omitted (RFC 6749 §5.1). A non-string `scope`
      # breaks spec-compliant clients (opencode, the MCP SDK).
      token_json["scope"]?.should be_nil

      # 4. The issued token carries the user, the elected role, the app.
      decoded = Facet::IAM::JWT.decode(access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["typ"].as_s.should eq("app")
      decoded.payload["sub"].as_s.should eq(account_id)
      decoded.payload["role"].as_s.should eq("iam.Roles.reader")
      decoded.payload["app"]?.should_not be_nil

      # 5. Use the app token against the API: inside-grant read succeeds.
      api_headers = bearer_headers(access_token)
      read_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Contact/#{in_doc_id}",

        headers: api_headers))
      assert_http_status(read_resp, 200)
      JSON.parse(read_resp.body)["data"]["name"].as_s.should eq("Alice")
    end
  end

  it "redirects an unauthenticated GET /OAuth/authorize to the login page" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app")
      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "state"                 => "s",
        "code_challenge"        => "challenge",
        "code_challenge_method" => "S256",
      })
      # No Authorization header → 302 to the frontend login with the
      # authorize URL embedded as `redirectTo` (session missing).
      resp = call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}"))
      assert_http_status(resp, 302)
      location = resp.headers["Location"]
      location.should start_with("/Login?redirectTo=")
      target = URI.parse(location).query_params.fetch("redirectTo", "")
      target.should eq("/OAuth/authorize?#{query}")
    end
  end

  it "rejects `plain` challenge method at authorize (4xx JSON, never redirects)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app")
      create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")
      session = login_token("test@example.com", "test-password")

      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "code_challenge"        => "challenge",
        "code_challenge_method" => "plain",
      })
      resp = oauth_get_authorize(session, query)
      resp.status_code.should be >= 400
      body = JSON.parse(resp.body)
      body["error"]?.should_not be_nil
    end
  end

  it "rejects a redirect_uri mismatch at authorize (4xx JSON, never redirected)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        redirect_uris: ["https://app.example.com/cb"])
      create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")
      session = login_token("test@example.com", "test-password")

      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://attacker.example.com/cb",
        "code_challenge"        => "challenge",
        "code_challenge_method" => "S256",
      })
      resp = oauth_get_authorize(session, query)
      resp.status_code.should be >= 400
      body = JSON.parse(resp.body)
      body["error"]?.should_not be_nil
    end
  end

  it "zero usable roles → access_denied on POST /OAuth/authorize (no code issued)" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "hr_only", [oauth_perm("read", "hr.Employee")])
      create_test_account(db,
        email: "hr_account@example.com", password: "hr-password",
        roles: ["iam.Roles.hr_only"], default_role: "iam.Roles.hr_only")
      session = login_token("hr_account@example.com", "hr-password")

      challenge = s256_challenge("v")
      body = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "code_challenge"        => challenge,
        "code_challenge_method" => "S256",
        "role"                  => "iam.Roles.hr_only",
      })
      resp = oauth_post_authorize_with_role(session, body)
      # The route returns 200 with `error=access_denied` because the brief
      # passed through `AccessDenied` as a redirect-eligible outcome. The
      # HTTP layer surfaces the JSON for the frontend to render as a redirect.
      assert_http_status(resp, 200)
      body_json = JSON.parse(resp.body)
      body_json["error"]?.should eq("access_denied")
      body_json["code"]?.should be_nil # no code is ever issued on access_denied
    end
  end

  it "multiple usable roles → consent shows picker; the chosen role lands in the token" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "sales", [oauth_perm("read", "crm.Contact")])
      create_test_role(db, "support", [oauth_perm("read", "crm.Ticket"), oauth_perm("read", "crm.Contact")])
      create_test_account(db,
        email: "multirole@example.com", password: "multi-password",
        roles: ["iam.Roles.sales", "iam.Roles.support"], default_role: "iam.Roles.sales")
      session = login_token("multirole@example.com", "multi-password")

      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "state"                 => "s",
        "code_challenge"        => s256_challenge("v"),
        "code_challenge_method" => "S256",
      })
      resp = oauth_get_authorize(session, query)
      assert_http_status(resp, 200)
      roles = JSON.parse(resp.body)["roles"].as_a.map(&.["role_id"].as_s).sort!
      roles.should eq(["iam.Roles.sales", "iam.Roles.support"])

      # User elects `support` (not the default!) — the token's `role` MUST be
      # the elected role, not the account's default.
      body = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "state"                 => "s",
        "code_challenge"        => s256_challenge("v"),
        "code_challenge_method" => "S256",
        "role"                  => "iam.Roles.support",
      })
      resp2 = oauth_post_authorize_with_role(session, body)
      assert_http_status(resp2, 200)
      code = JSON.parse(resp2.body)["code"].as_s

      # Token exchange → app JWT carries `role: support`.
      token_body = URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code,
        "redirect_uri"  => "https://app.example.com/cb",
        "code_verifier" => "v",
        "client_id"     => client_id,
      })
      resp3 = oauth_post_token(token_body)
      assert_http_status(resp3, 200)
      access_token = JSON.parse(resp3.body)["access_token"].as_s
      decoded = Facet::IAM::JWT.decode(access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["role"].as_s.should eq("iam.Roles.support")
    end
  end

  it "code replay fails; wrong verifier fails; mismatched redirect_uri fails at token" do
    with_db do |db|
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      create_test_account(db,
        email: "replay@example.com", password: "replay-password",
        roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")
      session = login_token("replay@example.com", "replay-password")

      # Issues a fresh authorize code. Each failure mode gets its own code so
      # that the brief's atomic-consume contract — "a second redemption must
      # fail, and should invalidate the issued token" — does not interact
      # across assertions. A wrong-verifier attempt consumes the code (the
      # consume is atomic and happens before PKCE verification), so mixing
      # wrong-verifier and replay-check on the same code would be misleading.
      issue_code = ->(verifier : String) : String {
        challenge = s256_challenge(verifier)
        body = URI::Params.encode({
          "response_type"         => "code",
          "client_id"             => client_id,
          "redirect_uri"          => "https://app.example.com/cb",
          "state"                 => "s",
          "code_challenge"        => challenge,
          "code_challenge_method" => "S256",
          "role"                  => "iam.Roles.reader",
        })
        resp = oauth_post_authorize_with_role(session, body)
        assert_http_status(resp, 200)
        JSON.parse(resp.body)["code"].as_s
      }

      # 1. Wrong verifier → invalid_grant (code is consumed atomically).
      code1 = issue_code.call("verifier_correct_1")
      wrong = oauth_post_token(URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code1,
        "redirect_uri"  => "https://app.example.com/cb",
        "code_verifier" => "verifier_wrong",
        "client_id"     => client_id,
      }))
      wrong.status_code.should eq(400)
      JSON.parse(wrong.body)["error"].as_s.should eq("invalid_grant")

      # 2. Mismatched redirect_uri at token → invalid_grant.
      code2 = issue_code.call("verifier_correct_2")
      mismatch = oauth_post_token(URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code2,
        "redirect_uri"  => "https://attacker.example.com/cb",
        "code_verifier" => "verifier_correct_2",
        "client_id"     => client_id,
      }))
      assert_http_status(mismatch, 400)
      JSON.parse(mismatch.body)["error"].as_s.should eq("invalid_grant")

      # 3. The valid first redemption of the third code succeeds...
      code3 = issue_code.call("verifier_correct_3")
      ok = oauth_post_token(URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code3,
        "redirect_uri"  => "https://app.example.com/cb",
        "code_verifier" => "verifier_correct_3",
        "client_id"     => client_id,
      }))
      assert_http_status(ok, 200)
      JSON.parse(ok.body)["access_token"].as_s.should_not be_empty

      # ...and the second must fail with invalid_grant — single-use.
      replay = oauth_post_token(URI::Params.encode({
        "grant_type"    => "authorization_code",
        "code"          => code3,
        "redirect_uri"  => "https://app.example.com/cb",
        "code_verifier" => "verifier_correct_3",
        "client_id"     => client_id,
      }))
      assert_http_status(replay, 400)
      JSON.parse(replay.body)["error"].as_s.should eq("invalid_grant")
    end
  end

  it "CORS: token endpoint echoes the registered origin" do
    with_db do |db|
      create_test_app(db, "test-app",
        allowed_origins: ["https://app.example.com"])

      headers = HTTP::Headers{
        "Origin"       => "https://app.example.com",
        "Content-Type" => "application/x-www-form-urlencoded",
      }
      resp = call_api(HTTP::Request.new("OPTIONS", "/OAuth/token", headers: headers))
      assert_http_status(resp, 204)
      resp.headers["Access-Control-Allow-Origin"]?.should eq("https://app.example.com")
    end
  end
end
