# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/oauth_helper"
require "../support/doctype_helper"

HTTPTest.init

# ── WebSocket subprotocol transport helpers (file-local) ────────────────────

# Builds the upgrade-like context the subprotocol branch is called with. The
# app branch never reads the env on this path; the DPoP branch reads headers,
# which the subprotocol scheme does not provide by design.
private def ws_auth_env
  request = HTTP::Request.new("GET", "/Ws")
  HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
end

# Signs a JWT whose only distinguishing claim is the given `typ` value —
# used to prove the transport accepts `app` and nothing else.
private def ws_sign_typ(typ : String, account_id : String, role : String) : String
  now = Time.utc.to_unix
  payload = {
    "sub"  => JSON::Any.new(account_id),
    "sid"  => JSON::Any.new(Random::Secure.urlsafe_base64(24)),
    "role" => JSON::Any.new(role),
    "jti"  => JSON::Any.new(Facet::Util::ScriptHelpers.ulid),
    "typ"  => JSON::Any.new(typ),
    "iat"  => JSON::Any.new(now),
    "exp"  => JSON::Any.new(now + 900),
  }
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

# Synchronous warn-level sink for the auth log source. The suite-wide
# capture backend records ERROR only, and the empty-scope refusal logs at
# warn (F08-06).
private class AuthLogSink < ::Log::Backend
  getter messages = [] of String

  def initialize
    super(::Log::DispatchMode::Sync)
  end

  def write(entry : ::Log::Entry) : Nil
    @messages << entry.message
  end
end

# AuthHandler `typ: "app"` JWT acceptance.
#
# Contract:
# - **`AuthHandler` extension**: on `typ: "app"`, load the grant for the `app`
#   claim and attach it to `AuthContext`. Reject if the app is not `active`.
# - Farther: any code path that reaches a document service with an app-derived
#   identity but without the grant attached → structural negative test.
# - Layer-1 enforcement rejects out-of-grant targets.
#
# These specs craft an app token directly through `IAM::JWT.build_app_payload`
# (the same factory `OAuth::Token.call` uses), then hit AuthHandler-protected
# routes via `call_api`. They cover:
# 1. Happy path — active app + usable role → 200 from `/Api/iam/me`.
# 2. App is `draft` → 401 (AuthHandler fails closed).
# 3. App disabled between token issuance and request → 401.
# 4. Role removed → 401 (`find_role_content` returns nil).
# 5. Layer-1 enforcement: a document read inside theGranted grant succeeds;
#    outside it produces 403/404 (per `app_enforcement_spec.cr`'s contract).

describe "AuthHandler — app token (typ: app)" do
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

  # Signs an app token using the same backing key + factory as `OAuth::Token`.
  # (Helper lives in `spec/support/oauth_helper.cr` as `sign_app_token`.)

  it "accepts an active app + usable role → /Api/iam/me 200" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)
      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 200)
      body = JSON.parse(resp.body)
      body["active_role"].as_s.should eq("iam.Roles.reader")
    end
  end

  it "rejects a draft app with 401 (fail-closed)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        status: "draft",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      # The token is signed with the app id, but the app is `draft` — the
      # AuthHandler re-reads the projection and gates on `status == "active"`.
      token = sign_app_token(account_id, "iam.Roles.reader", app_id)
      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 401)
    end
  end

  it "rejects a disabled app with 401 (fail-closed)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)

      # Now disable the app — the token's signature is still valid, but the
      # AuthHandler re-reads `status` on every request from `app.App`.
      Facet::Document::Update.call(
        db, "app", "App", app_id,
        %({"status": "disabled"}),
        Facet::RBAC::AuthContext.system,
      )

      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 401)
    end
  end

  it "rejects a token whose role no longer exists with 401 (fail-closed)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      # The role projection id is the qualified role reference `iam.Roles.reader`.
      # Tombstone it directly: the public `Document::Delete` guard refuses to
      # delete a role still assigned to an account, and this spec only needs
      # the projection gone so `find_role_content` returns nil at AuthHandler.
      role_id = "iam.Roles.reader"
      Facet::Mutation::Client.delete(db, "iam", "Roles", role_id)

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)

      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 401)
    end
  end

  it "rejects a token whose effective scope is empty (all-optional grant, role covering nothing)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        # All-optional grant on crm.Contact. `role_usable?` is true (no
        # required actions), but the role covers nothing → `resolve` yields
        # empty → AuthContext.app_scoped is not constructed.
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: false)])])
      create_test_role(db, "reader", [oauth_perm("read", "hr.Employee")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)
      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      # Fail-closed: empty effective scope means no AuthContext → 401.
      assert_http_status(resp, 401)
    end
  end

  it "logs one WARN and tags the span when the effective scope is empty (F08-06)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: false)])])
      create_test_role(db, "reader", [oauth_perm("read", "hr.Employee")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)
      headers = bearer_headers(token)

      # The route answers a bare 401: the body names nothing beyond the
      # generic error (anti-enumeration).
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))
      assert_http_status(resp, 401)
      body = JSON.parse(resp.body)
      body.as_h.size.should eq(1)
      body["error"].as_s.should eq("Authentication required")

      # Drive the handler directly inside an OTel trace so a span is
      # current when the refusal runs (the same shape the app-audit spec
      # uses for span attributes). The bind window opens after the call_api
      # request, so exactly one WARN lands in the sink.
      Facet::Telemetry.init
      sink = AuthLogSink.new
      refused = nil
      ::Log.builder.bind("facet.http.auth", :warn, sink)
      begin
        OpenTelemetry.trace "test.app.token.empty.scope" do |_span|
          ctx = Facet::HTTP::AuthHandler.auth_context_from_request(
            HTTP::Server::Context.new(
              request: HTTP::Request.new("GET", "/Api/iam/me", headers: headers),
              response: HTTP::Server::Response.new(IO::Memory.new),
            )
          )
          ctx.should be_nil
          if inner = OpenTelemetry.current_span
            refused = inner["auth.refused"]?
          end
        end
      ensure
        ::Log.builder.unbind("facet.http.auth", :warn, sink)
      end

      refused.should eq("empty_scope")
      sink.messages.count(&.includes?("app token refused")).should eq(1)
      sink.messages.count(&.includes?("grant intersection with role iam.Roles.reader")).should eq(1)
      sink.messages.count(&.includes?(app_id)).should eq(1)
    end
  end

  it "Layer-1 enforcement: in-grant document read succeeds; out-of-grant returns 403" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      # Set up two doctypes: `crm.Contact` (in-grant) and `crm.Secret` (out)
      # so the grant enforcement can show both outcomes against the same token.
      ensure_domain(db, "crm")
      {"Contact", "Secret"}.each do |dt|
        schema = %({"doctype": "#{dt}", "domain": "crm", "fields": {"name": {"type": "string"}}})
        result = Facet::Document::Create.call(db, "core", "DocType", schema, Facet::RBAC::AuthContext.system)
        raise "Failed to seed #{dt} doctype: #{result.inspect}" unless result.is_a?(Facet::Document::Create::Result)
      end

      # The system creates both documents; the app-scoped token then attempts reads.
      in_id = Facet::Document::Create.call(db, "crm", "Contact", %({"name": "Inside"}), Facet::RBAC::AuthContext.system)
      raise "Failed to create Contact: #{in_id.inspect}" unless in_id.is_a?(Facet::Document::Create::Result)
      in_id = in_id.projection.id
      out_id = Facet::Document::Create.call(db, "crm", "Secret", %({"name": "Outside"}), Facet::RBAC::AuthContext.system)
      raise "Failed to create Secret: #{out_id.inspect}" unless out_id.is_a?(Facet::Document::Create::Result)
      out_id = out_id.projection.id

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)
      headers = bearer_headers(token)

      # Inside the grant → 200.
      in_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Contact/#{in_id}", headers: headers))
      assert_http_status(in_resp, 200)

      # Outside the grant → the layer-1 ceiling denies the read class:
      # no read permission on crm.Secret at all answers 403.
      out_resp = call_api(HTTP::Request.new("GET", "/Api/crm/Secret/#{out_id}", headers: headers))
      assert_http_status(out_resp, 403)
    end
  end

  it "rejects a token carrying an unknown app id (cannot resolve) with 401" do
    with_db do |db|
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      # No app.App row exists with this id. The AuthHandler's app-row query
      # returns nil → fail-closed 401.
      token = sign_app_token(account_id, "iam.Roles.reader", "01FAKEAPPPROJECTIONID00000")
      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 401)
    end
  end

  it "structural negative: missing 'app' claim on a 'typ: app' token → 401" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      # Build an access payload but strip out the `app` claim before signing
      # so AuthHandler has no app id to load. Fail-closed 401.
      payload, _exp = Facet::IAM::JWT.build_app_payload(
        account_id: account_id,
        sid: Random::Secure.urlsafe_base64(24),
        role: "iam.Roles.reader",
        app_id: app_id,
      )
      payload.delete("app")
      token = Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)

      headers = bearer_headers(token)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: headers))

      assert_http_status(resp, 401)
    end
  end
end

# WebSocket subprotocol transport (`WS_SUBPROTOCOL` scheme).
#
# Browser WebSocket handshakes cannot carry an `Authorization` header, and
# the `auth_token` cookie does not travel cross-site (`SameSite=Lax`). The
# route accepts the credential through the `Sec-WebSocket-Protocol` header
# instead (`Websocket::Route::TOKEN_PROTOCOL`), calling
# `auth_context_from_token` with the subprotocol scheme. That transport is
# pinned to `typ: "app"`: static keys never ride a handshake header, and the
# browser SDK has no use for the browser-session/preview token kinds.
describe "AuthHandler — WebSocket subprotocol transport" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "builds an app-scoped AuthContext from a typ: app token" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "ws-sub-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = sign_app_token(account_id, "iam.Roles.reader", app_id)

      ctx = Facet::HTTP::AuthHandler.auth_context_from_token(ws_auth_env, token, Facet::HTTP::AuthHandler::WS_SUBPROTOCOL)
      ctx.should_not be_nil
      ctx = ctx.not_nil!
      ctx.app_id.should eq(app_id)
      ctx.app_grant.should_not be_nil
    end
  end

  it "rejects a typ: access token (browser-session kind)" do
    with_db do |db|
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      token = ws_sign_typ("access", account_id, "iam.Roles.reader")

      Facet::HTTP::AuthHandler.auth_context_from_token(ws_auth_env, token, Facet::HTTP::AuthHandler::WS_SUBPROTOCOL).should be_nil
    end
  end

  it "rejects a static API key (never rides a handshake header)" do
    Facet::HTTP::AuthHandler.auth_context_from_token(ws_auth_env, "fct_000000000000000000000000", Facet::HTTP::AuthHandler::WS_SUBPROTOCOL).should be_nil
  end

  it "rejects a DPoP-bound app token (handshake cannot carry a proof)" do
    with_db do |db|
      app_id, _client_id = create_test_app(db, "ws-sub-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      pair = dpop_key_pair
      payload, _exp = Facet::IAM::JWT.build_app_payload(
        account_id: account_id,
        sid: Random::Secure.urlsafe_base64(24),
        role: "iam.Roles.reader",
        app_id: app_id,
        cnf_jkt: pair.jkt,
      )
      token = Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)

      Facet::HTTP::AuthHandler.auth_context_from_token(ws_auth_env, token, Facet::HTTP::AuthHandler::WS_SUBPROTOCOL).should be_nil
    end
  end
end
