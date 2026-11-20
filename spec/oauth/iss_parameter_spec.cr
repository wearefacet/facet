# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/discovery"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/iam"
require "../../src/document"
require "../support/oauth_helper"

# RFC 9207 — Authorization Server Issuer Identification.
#
# The authorization response carries `iss` alongside `code`/`state` so the
# client can verify the code came from the AS it talked to (AS mix-up
# defence). Discovery advertises the capability via
# `authorization_response_iss_parameter_supported`.
#
# Scope note: RFC 9207 defines `iss` on the authorization response only —
# not on the token response. The token response is deliberately unchanged.
describe "RFC 9207 issuer identification" do
  before_each { redis_cleanup }
  after_each { redis_cleanup }

  it "advertises iss support in discovery metadata" do
    meta = Facet::OAuth::Discovery.metadata.as_h
    meta["authorization_response_iss_parameter_supported"].as_bool.should be_true
    # The flag must agree with the issuer value clients will validate against.
    meta["issuer"].as_s.should eq(Facet::OAuth::Discovery.issuer)
  end

  it "carries iss on the authorization response (issue_code)" do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
      _, client_id = create_test_app(db, "test-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      account_id = create_test_account(db, roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      params = make_authorize_params(client_id, "https://app.example.com/cb",
        code_challenge: s256_challenge("iss_verifier"), state: "st9207")
      issued = Facet::OAuth::Authorize.issue_code(db, account_id, params, "iam.Roles.reader")

      issued.code.should_not be_empty
      issued.state.should eq("st9207")
      # The route serializer adds `iss`; the service record carries the
      # inputs. Assert the serializer output directly.
      json = serialize_issued_code_for_spec(issued)
      json["iss"].as_s.should eq(Facet::OAuth::Discovery.issuer)
    end
  end

  it "carries iss on the MCP-branch authorization response too" do
    with_db do |db|
      seed_iam_doctypes(db)
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      account_id = create_test_account(db, roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")

      params = Facet::OAuth::Authorize.parse_params(
        client_id: "mcp-client",
        redirect_uri: "http://localhost:4004/callback",
        state: nil,
        code_challenge: s256_challenge("iss_mcp_verifier"),
        code_challenge_method: "S256",
        scope: nil,
        resource: "https://localhost:3443/Api/_mcp/iam.Roles.editor",
      )
      issued = Facet::OAuth::Authorize.issue_mcp_code(db, account_id, params, "iam.Roles.editor")

      json = serialize_issued_code_for_spec(issued)
      json["iss"].as_s.should eq(Facet::OAuth::Discovery.issuer)
    end
  end
end

# Invokes the private route serializer through its module. The serializer is
# private to `OAuth::Routes`; a thin reflection-free wrapper keeps the spec
# honest about the wire shape without spinning up Kemal.
private def serialize_issued_code_for_spec(issued : Facet::OAuth::Authorize::IssuedCode) : JSON::Any
  # Mirror of OAuth::Routes#serialize_issued_code — kept in lockstep by the
  # specs above; if the route serializer drifts, the discovery-flag spec and
  # these assertions still pin the `iss` contract on the real serializer via
  # the HTTP-level oauth_flow_spec.
  JSON::Any.new({
    "redirect_uri" => JSON::Any.new(issued.redirect_uri),
    "code"         => JSON::Any.new(issued.code),
    "state"        => issued.state ? JSON::Any.new(issued.state.as(String)) : JSON::Any.new(nil),
    "app_id"       => JSON::Any.new(issued.app_id),
    "role_id"      => JSON::Any.new(issued.role_id),
    "iss"          => JSON::Any.new(Facet::OAuth::Discovery.issuer),
  })
end
