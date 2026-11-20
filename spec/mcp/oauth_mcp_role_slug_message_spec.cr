# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/document"
require "../../src/oauth/authorize"
require "../support/oauth_helper"

# B-201 — the MCP authorize branch's 400 for a role that names no role
# document must state the required shape: the `role` parameter carries the
# qualified projection id (`iam.Roles.admin`), never the bare role name.
#
# The contract is qualified-id-only (bare names are ambiguous across
# domains); the spec pins the message text and the unchanged 200 path for a
# qualified id.

def role_slug_params : Facet::OAuth::Authorize::Params
  Facet::OAuth::Authorize.parse_params(
    client_id: "mcp-client",
    redirect_uri: "http://localhost:4004/callback",
    state: nil,
    code_challenge: s256_challenge("mcp_verifier"),
    code_challenge_method: "S256",
    scope: nil,
    resource: Facet::MCP.resource_identifier("iam.Roles.admin"),
  )
end

describe "OAuth MCP authorize role parameter (B-201)" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }
  before_each do
    with_db do |db|
      seed_iam_doctypes(db)
    end
  end

  it "answers 400 naming the qualified-id shape for a bare role name" do
    with_db do |db|
      create_test_role(db, "admin", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

      ex = expect_raises(Facet::OAuth::Authorize::InvalidRequest, /Unknown role 'admin'/) do
        Facet::OAuth::Authorize.build_mcp_consent(db, account_id, role_slug_params, "admin", "http://localhost:4004")
      end
      # The message names the shape, so the client can fix the value.
      message = ex.message.not_nil!
      message.should contain("the role parameter is the qualified role id")
      message.should contain("`iam.Roles.admin`")
      ex.error_code.should eq("invalid_request")
      ex.status.should eq(400)
    end
  end

  it "keeps the 200 consent path unchanged for a qualified role id" do
    with_db do |db|
      create_test_role(db, "admin", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.admin"], default_role: "iam.Roles.admin")

      screen = Facet::OAuth::Authorize.build_mcp_consent(db, account_id, role_slug_params, "iam.Roles.admin", "http://localhost:4004")
      screen.resource.should eq(Facet::MCP.resource_identifier("iam.Roles.admin"))
      screen.roles.map(&.role_id).should contain("iam.Roles.admin")
      screen.pinned_role.should eq("iam.Roles.admin")
    end
  end
end
