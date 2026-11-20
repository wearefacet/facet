# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/token"
require "../../src/oauth/code_store"
require "../../src/oauth/refresh"
require "../../src/mcp/dispatch"
require "../../src/mcp"
require "../support/oauth_helper"

# MCP branch of the OAuth flow (`doc/backend/mcp.md`).
#
# End-to-end, service-level: authorize (resource + role) → code → token
# (`aud` minted, no `app` claim) → refresh (account-active + role-held only).
#
# Acceptance:
# - `build_mcp_consent` lists held roles without app machinery; rejects a
#   pinned role the user does not hold (no silent fallback).
# - `issue_mcp_code` records resource + role into the code.
# - Token mints an access token with `aud` = resource and **no** `app`
#   claim; the session is browser-session-shaped.
# - User losing the role between authorize and token → `invalid_grant`.
# - Refresh revalidates account-active + role-held; suspended account or revoked
#   role kills the session.
def mcp_params(redirect_uri = "http://localhost:4004/callback") : Facet::OAuth::Authorize::Params
  Facet::OAuth::Authorize.parse_params(
    client_id: "mcp-client",
    redirect_uri: redirect_uri,
    state: nil,
    code_challenge: s256_challenge("mcp_verifier"),
    code_challenge_method: "S256",
    scope: nil,
    resource: Facet::MCP.resource_identifier("iam.Roles.editor"),
  )
end

describe "OAuth MCP branch" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "runs authorize → token end to end and mints aud with no app claim" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      params = mcp_params
      screen = Facet::OAuth::Authorize.build_mcp_consent(db, account_id, params, nil, "http://localhost:4004")
      screen.resource.should eq(Facet::MCP.resource_identifier("iam.Roles.editor"))
      screen.roles.map(&.role_id).should contain("iam.Roles.editor")

      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued_code.app_id.should eq("")

      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      decoded = Facet::IAM::JWT.decode(issued.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["typ"].as_s.should eq("access")
      decoded.payload["aud"].as_s.should eq(Facet::MCP.resource_identifier("iam.Roles.editor"))
      decoded.payload["role"].as_s.should eq("iam.Roles.editor")
      decoded.payload["app"]?.should be_nil

      # The session is browser-session-shaped: no `app` field.
      sid = decoded.payload["sid"].as_s
      session = Facet::IAM::RedisSession.load(sid)
      session.should_not be_nil
      session.not_nil!.app.should be_empty
    end
  end

  it "rejects consent for a pinned role the account does not hold" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")

      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /does not hold/) do
        Facet::OAuth::Authorize.build_mcp_consent(db, account_id, mcp_params, "iam.Roles.editor", "http://localhost:4004")
      end
      # The role document exists — the answer stays the consent denial (B-157).
      ex.error_code.should eq("access_denied")
      ex.status.should eq(403)
    end
  end

  it "answers invalid_request (400) for a pinned role that does not exist (B-157)" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      # `iam.Roles.ghost` names no role document — a malformed request, not
      # a consent denial.
      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /Unknown role/) do
        Facet::OAuth::Authorize.build_mcp_consent(db, account_id, mcp_params, "iam.Roles.ghost", "http://localhost:4004")
      end
      ex.error_code.should eq("invalid_request")
      ex.status.should eq(400)
    end
  end

  it "answers access_denied for a pinned role whose connectivity excludes mcp" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      # The role exists and is held, but its connectivity list excludes the
      # `mcp` channel — the pinned screen denies with the same shape as an
      # unheld role, never a malformed request.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.editor' AND deleted_at IS NULL")

      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /not usable/) do
        Facet::OAuth::Authorize.build_mcp_consent(db, account_id, mcp_params, "iam.Roles.editor", "http://localhost:4004")
      end
      ex.error_code.should eq("access_denied")
      ex.status.should eq(403)
    end
  end

  it "rejects issue_mcp_code when the elected role is not held" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      expect_raises(Facet::OAuth::Authorize::AccessDenied) do
        Facet::OAuth::Authorize.issue_mcp_code(db, account_id, mcp_params, "iam.Roles.admin")
      end
    end
  end

  it "rejects issue_mcp_code when the elected role's connectivity excludes mcp" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      # A held, live role that lost the `mcp` channel cannot elect into an
      # MCP code — a redirect-eligible consent denial.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.editor' AND deleted_at IS NULL")

      expect_raises(Facet::OAuth::Authorize::AccessDenied) do
        Facet::OAuth::Authorize.issue_mcp_code(db, account_id, mcp_params, "iam.Roles.editor")
      end
    end
  end

  it "rejects issue_mcp_code without a resource parameter" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client", redirect_uri: "http://localhost:4004/callback",
        state: nil, code_challenge: "c", code_challenge_method: "S256", scope: nil,
        resource: nil,
      )
      expect_raises(Facet::OAuth::Authorize::InvalidRequest, /Missing 'resource'/) do
        Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      end
    end
  end

  it "rejects token redemption when the account lost the role between authorize and token" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")

      # Strip the role from the account projection.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{roles}', '[]'::jsonb) WHERE id = $1", account_id)

      ex = expect_raises(Facet::OAuth::Token::Error) do
        Facet::OAuth::Token.call(
          db,
          grant_type: "authorization_code",
          code: issued_code.code,
          redirect_uri: params.redirect_uri,
          code_verifier: "mcp_verifier",
          client_id: "mcp-client",
        )
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "refreshes an MCP session with account-active + role-held revalidation only" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      backdate_refresh_issued_at(issued.refresh_token)
      refreshed = Facet::OAuth::Refresh.call_mcp(db, issued.refresh_token)

      decoded = Facet::IAM::JWT.decode(refreshed.access_token, Facet::IAM::TokenEmitter.keys)
      decoded.payload["aud"].as_s.should eq(Facet::MCP.resource_identifier("iam.Roles.editor"))
      decoded.payload["app"]?.should be_nil
      # Rotation produced a fresh refresh token.
      refreshed.refresh_token.should_not eq(issued.refresh_token)
    end
  end

  it "kills the MCP session on refresh when the account is suspended" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      db.exec("UPDATE projections SET content = jsonb_set(content, '{status}', '\"suspended\"') WHERE id = $1", account_id)

      backdate_refresh_issued_at(issued.refresh_token)
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call_mcp(db, issued.refresh_token)
      end
      ex.error_code.should eq("invalid_grant")

      # The session is gone — reuse of the same refresh token cannot revive it.
      sid = issued.refresh_token.split('.', 2)[0]
      Facet::IAM::RedisSession.load(sid).should be_nil
    end
  end

  it "kills the MCP session on refresh when the role was revoked" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      db.exec("UPDATE projections SET content = jsonb_set(content, '{roles}', '[]'::jsonb) WHERE id = $1", account_id)

      backdate_refresh_issued_at(issued.refresh_token)
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call_mcp(db, issued.refresh_token)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end

  it "kills the MCP session on refresh when the role's connectivity drops the mcp channel" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      # Flip the role down to browser-only. Refresh is the sole enforcement
      # point — the still-live access token stays valid until its TTL.
      db.exec("UPDATE projections SET content = jsonb_set(content, '{connectivity}', '[]'::jsonb) " \
              "WHERE domain = 'iam' AND doc_type = 'Roles' AND id = 'iam.Roles.editor' AND deleted_at IS NULL")

      backdate_refresh_issued_at(issued.refresh_token)
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call_mcp(db, issued.refresh_token)
      end
      ex.error_code.should eq("invalid_grant")

      # The session is gone — reuse of the same refresh token cannot revive it.
      sid = issued.refresh_token.split('.', 2)[0]
      Facet::IAM::RedisSession.load(sid).should be_nil
    end
  end

  it "applies the refresh floor on the MCP path" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )

      # No backdate — the token was issued just now, inside the floor.
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call_mcp(db, issued.refresh_token)
      end
      ex.error_code.should eq("slow_down")
      ex.status.should eq(429)
    end
  end

  it "rejects stale refresh tokens on the MCP path (reuse detection)" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
      params = mcp_params
      issued_code = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")
      issued = Facet::OAuth::Token.call(
        db,
        grant_type: "authorization_code",
        code: issued_code.code,
        redirect_uri: params.redirect_uri,
        code_verifier: "mcp_verifier",
        client_id: "mcp-client",
      )
      old_refresh = issued.refresh_token

      # Rotate once — the presented token becomes prev_refresh_id but the
      # grace window has not started ticking in our favor for a *third*
      # presentation. Presenting a fabricated value must fail as stale.
      # Backdate the floor — the rotate below re-stamped it.
      backdate_refresh_issued_at(old_refresh)
      Facet::OAuth::Refresh.call_mcp(db, old_refresh)
      forged = "#{old_refresh.split('.', 2)[0]}.#{Random::Secure.hex(32)}"
      backdate_refresh_issued_at(forged)
      ex = expect_raises(Facet::OAuth::Refresh::Error) do
        Facet::OAuth::Refresh.call_mcp(db, forged)
      end
      ex.error_code.should eq("invalid_grant")
    end
  end
end
