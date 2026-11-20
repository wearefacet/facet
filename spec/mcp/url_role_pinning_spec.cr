# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/token"
require "../../src/mcp/dispatch"
require "../../src/mcp"
require "../support/oauth_helper"

# URL-pinned role invariant (`doc/backend/mcp.md`).
#
# - A token minted for role A cannot dispatch against `/Api/_mcp/B`, even
#   when the account holds both roles.
# - An account that does not hold role B cannot authorize for role B's resource.
# - The aud gate alone is not the pin: slug/role equality is checked
#   independently.
def sign_pinned_token(account_id : String, role : String, aud : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: Random::Secure.hex(16),
    role: role,
    aud: aud,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

describe "MCP URL role pinning" do
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "refuses a token minted for role A against role B's URL even when both are held" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor", "iam.Roles.viewer"],
        default_role: "iam.Roles.editor")

      token = sign_pinned_token(account_id, "iam.Roles.editor",
        Facet::MCP.resource_identifier("iam.Roles.editor"))

      expect_raises(Facet::MCP::Dispatch::Unauthorized) do
        Facet::MCP::Dispatch.verify(token, "iam.Roles.viewer")
      end
    end
  end

  it "accepts a token against its own pinned URL" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      token = sign_pinned_token(account_id, "iam.Roles.editor",
        Facet::MCP.resource_identifier("iam.Roles.editor"))

      verified = Facet::MCP::Dispatch.verify(token, "iam.Roles.editor")
      verified.role_id.should eq("iam.Roles.editor")
    end
  end

  it "rejects authorize outright when the account does not hold the pinned role" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "admin", [oauth_perm("*", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client",
        redirect_uri: "http://localhost:4004/callback",
        state: nil,
        code_challenge: s256_challenge("pin_verifier"),
        code_challenge_method: "S256",
        scope: nil,
        resource: Facet::MCP.resource_identifier("iam.Roles.admin"),
      )

      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /does not hold/) do
        Facet::OAuth::Authorize.build_mcp_consent(db, account_id, params, "iam.Roles.admin", "http://localhost:4004")
      end
      ex.status.should eq(403)
    end
  end

  it "rejects issue_mcp_code for a resource naming a role the account does not hold" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client",
        redirect_uri: "http://localhost:4004/callback",
        state: nil,
        code_challenge: s256_challenge("pin_verifier"),
        code_challenge_method: "S256",
        scope: nil,
        resource: Facet::MCP.resource_identifier("iam.Roles.viewer"),
      )

      expect_raises(Facet::OAuth::Authorize::AccessDenied) do
        Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.viewer")
      end
    end
  end

  it "rejects issue_mcp_code when the elected role differs from the resource's role" do
    with_db do |db|
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor", "iam.Roles.viewer"],
        default_role: "iam.Roles.editor")

      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client",
        redirect_uri: "http://localhost:4004/callback",
        state: nil,
        code_challenge: s256_challenge("pin_verifier"),
        code_challenge_method: "S256",
        scope: nil,
        resource: Facet::MCP.resource_identifier("iam.Roles.editor"),
      )

      # Both roles are held — the election would pass validate_election, but
      # the minted token's `role` claim could never satisfy the slug check at
      # dispatch against the resource's URL.
      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /does not match the requested resource/) do
        Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.viewer")
      end
      ex.status.should eq(403)
    end
  end
end
