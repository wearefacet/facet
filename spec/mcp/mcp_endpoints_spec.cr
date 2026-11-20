# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/http/server"
require "../../src/mcp"
require "../support/http_helper"
require "../support/oauth_helper"
require "../support/doctype_helper"

HTTPTest.init

# GET /Api/_mcp/endpoints — the browser-facing directory of the caller's
# held-role MCP endpoints (Settings page).
#
# The route authenticates through `AuthHandler.auth_context_from_request`
# (cookie or Bearer — the session machinery), because AuthHandler skips the
# `/Api/_mcp/` prefix entirely: the resource server verifies MCP tokens
# itself on POST and must not be pre-empted with a bare 401.
#
# Acceptance:
# - A browser-session token lists every held role, sorted, with the exact
#   resource identifier dispatch compares `aud` against.
# - Unauthenticated → 401.
# - An MCP-branch token (`aud` present) → 401 — role-pinned tokens must
#   not enumerate the account's other roles.
# - An account with no roles → an empty list, not an error.

def sign_session_token_for_endpoints(account_id : String, role : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: Random::Secure.hex(16),
    role: role,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

def sign_mcp_token_for_endpoints(account_id : String, role : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: Random::Secure.hex(16),
    role: role,
    aud: Facet::MCP.resource_identifier(role),
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

def endpoints_request(token : String?) : HTTP::Client::Response
  headers = HTTP::Headers.new
  headers["Authorization"] = "Bearer #{token}" if token
  call_api(HTTP::Request.new("GET", "#{Facet::MCP::PATH_PREFIX}/endpoints", headers: headers))
end

describe "GET /Api/_mcp/endpoints" do
  it "lists one endpoint per held role with the exact resource identifier" do
    with_db do |db|
      seed_iam_doctypes(db)
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor", "iam.Roles.viewer"], default_role: "iam.Roles.editor")

      token = sign_session_token_for_endpoints(account_id, "iam.Roles.editor")
      resp = endpoints_request(token)

      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      endpoints = body["endpoints"].as_a
      endpoints.map(&.as_h["role"].as_s).should eq(["iam.Roles.editor", "iam.Roles.viewer"])
      endpoints.map(&.as_h["url"].as_s).should eq([
        Facet::MCP.resource_identifier("iam.Roles.editor"),
        Facet::MCP.resource_identifier("iam.Roles.viewer"),
      ])
    end
  end

  it "rejects an unauthenticated call with 401" do
    resp = endpoints_request(nil)
    resp.status_code.should eq(401)
  end

  it "rejects an MCP-branch token (aud present) with 401" do
    with_db do |db|
      seed_iam_doctypes(db)
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      token = sign_mcp_token_for_endpoints(account_id, "iam.Roles.editor")
      resp = endpoints_request(token)

      resp.status_code.should eq(401)
    end
  end

  it "returns an empty list for an account with no roles" do
    with_db do |db|
      seed_iam_doctypes(db)
      # The token's role must exist for the auth context to build; the
      # account itself holds no roles, so the directory is empty.
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: [] of String, default_role: nil)

      token = sign_session_token_for_endpoints(account_id, "iam.Roles.editor")
      resp = endpoints_request(token)

      resp.status_code.should eq(200)
      body = JSON.parse(resp.body)
      body["endpoints"].as_a.should be_empty
    end
  end
end
