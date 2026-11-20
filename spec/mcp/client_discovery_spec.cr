# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/oauth/authorize"
require "../../src/oauth/code_store"
require "../../src/mcp"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"
require "../support/oauth_helper"

HTTPTest.init

# How a spec-following MCP client (opencode, MCP Inspector, …) walks the
# Facet flow, and where it can go wrong:
#
# 1. `POST /Api/_mcp/<role_slug>` unauthenticated → 401 whose
#    `WWW-Authenticate` points at the **path-carrying** PRM document (the
#    well-known segment inserted between host and the request path — RFC
#    9728 §3.1). A bare pointer would make the client advertise the bare
#    `/Api/_mcp` resource, whose RFC 8707 `resource` parameter can never
#    satisfy the URL-pins-role dispatch contract.
# 2. The path-carrying PRM advertises the role-pinned resource identifier.
# 3. `GET /OAuth/authorize` with that resource (no `role` parameter —
#    the client does not know the param) → the consent screen pins the
#    election to the resource's role slug.
# 4. A client-side election of a different role is rejected at issuance —
#    such a code could only mint a token whose `role` claim fails the
#    slug check at dispatch.
# 5. A `resource` under the MCP prefix that names no role answers
#    `invalid_target`, not the misleading app-branch "Unknown client_id".

def discovery_mcp_post(path : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("POST", path))
end

def discovery_get_prm(metadata_path : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", metadata_path))
end

def discovery_authorize_get(token : String, query : String) : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}", headers: bearer_headers(token)))
end

def discovery_authorize_post(token : String, body : String) : HTTP::Client::Response
  headers = bearer_headers(token)
  headers["Content-Type"] = "application/x-www-form-urlencoded"
  call_api(HTTP::Request.new("POST", "/OAuth/authorize", headers: headers, body: body))
end

describe "MCP client discovery over HTTP" do
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
    with_db do |db|
      seed_iam_doctypes(db)
      create_test_role(db, "editor", [oauth_perm("read", "*.*")])
      create_test_role(db, "viewer", [oauth_perm("read", "*.*")])
    end
  end

  it "points the 401 WWW-Authenticate at the path-carrying PRM document" do
    resp = discovery_mcp_post("/Api/_mcp/iam.Roles.editor")
    assert_http_status(resp, 401)

    www = resp.headers["WWW-Authenticate"]?
    www.should_not be_nil
    www.not_nil!.should eq(
      "Bearer resource_metadata=\"#{Facet::MCP.base_url}" +
      "/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.editor\"")
  end

  it "advertises the role-pinned resource through the path-carrying PRM" do
    resp = discovery_get_prm("/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.editor")
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["resource"].as_s.should eq(Facet::MCP.resource_identifier("iam.Roles.editor"))
    body["authorization_servers"].as_a.map(&.as_s).should contain(Facet::MCP.base_url)
  end

  it "pins the consent election to the resource's role when no role param is sent" do
    email = "mcp-discover-#{Facet::Util::ScriptHelpers.ulid.downcase[0..8]}@example.com"
    with_db do |db|
      create_test_account(db, email: email, password: "discovery-password",
        roles: ["iam.Roles.editor", "iam.Roles.viewer"], default_role: "iam.Roles.editor")
    end
    session = login_token(email, "discovery-password")

    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => "mcp-client",
      "redirect_uri"          => "http://127.0.0.1:36169/callback",
      "state"                 => "st",
      "code_challenge"        => s256_challenge("discovery_verifier"),
      "code_challenge_method" => "S256",
      "resource"              => Facet::MCP.resource_identifier("iam.Roles.editor"),
    })
    resp = discovery_authorize_get(session, query)
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["mcp"].as_bool.should be_true
    body["pinned_role"].as_s.should eq("iam.Roles.editor")
    body["resource"].as_s.should eq(Facet::MCP.resource_identifier("iam.Roles.editor"))
    body["roles"].as_a.map(&.as_h["role_id"].as_s).should contain("iam.Roles.editor")
  end

  it "rejects an election that does not match the resource's role" do
    email = "mcp-mismatch-#{Facet::Util::ScriptHelpers.ulid.downcase[0..8]}@example.com"
    with_db do |db|
      create_test_account(db, email: email, password: "mismatch-password",
        roles: ["iam.Roles.editor", "iam.Roles.viewer"], default_role: "iam.Roles.editor")
    end
    session = login_token(email, "mismatch-password")

    body = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => "mcp-client",
      "redirect_uri"          => "http://127.0.0.1:36169/callback",
      "state"                 => "st",
      "code_challenge"        => s256_challenge("discovery_verifier"),
      "code_challenge_method" => "S256",
      "resource"              => Facet::MCP.resource_identifier("iam.Roles.editor"),
      "role"                  => "iam.Roles.viewer",
    })
    resp = discovery_authorize_post(session, body)
    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_request")
  end

  it "answers invalid_target for a resource under the MCP prefix that names no role" do
    email = "mcp-bare-#{Facet::Util::ScriptHelpers.ulid.downcase[0..8]}@example.com"
    with_db do |db|
      create_test_account(db, email: email, password: "bare-password",
        roles: ["iam.Roles.editor"], default_role: "iam.Roles.editor")
    end
    session = login_token(email, "bare-password")

    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => "mcp-client",
      "redirect_uri"          => "http://127.0.0.1:36169/callback",
      "state"                 => "st",
      "code_challenge"        => s256_challenge("discovery_verifier"),
      "code_challenge_method" => "S256",
      "resource"              => "#{Facet::MCP.base_url}#{Facet::MCP::PATH_PREFIX}",
    })
    resp = discovery_authorize_get(session, query)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_target")
  end

  it "issues a usable code when the elected role matches the resource's role" do
    email = "mcp-issue-#{Facet::Util::ScriptHelpers.ulid.downcase[0..8]}@example.com"
    with_db do |db|
      create_test_account(db, email: email, password: "issue-password",
        roles: ["iam.Roles.editor", "iam.Roles.viewer"], default_role: "iam.Roles.editor")
    end
    session = login_token(email, "issue-password")

    body = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => "mcp-client",
      "redirect_uri"          => "http://127.0.0.1:36169/callback",
      "state"                 => "st",
      "code_challenge"        => s256_challenge("discovery_verifier"),
      "code_challenge_method" => "S256",
      "resource"              => Facet::MCP.resource_identifier("iam.Roles.editor"),
      "role"                  => "iam.Roles.editor",
    })
    resp = discovery_authorize_post(session, body)
    assert_http_status(resp, 200)

    issued = JSON.parse(resp.body)
    issued["redirect_uri"].as_s.should eq("http://127.0.0.1:36169/callback")
    issued["code"].as_s.should_not be_empty
    issued["role_id"].as_s.should eq("iam.Roles.editor")
  end
end
