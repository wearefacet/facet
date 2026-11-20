# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/redis_helper"

HTTPTest.init

# `POST /OAuth/register` — RFC 7591 dynamic client registration for MCP
# clients (`OAuth::Register`). The MCP authorization spec requires clients
# to self-register before the PKCE authorize flow; discovery advertises the
# endpoint as `registration_endpoint`.
#
# The registration is stateless: the MCP branch of authorize/token treats
# `client_id` as an opaque string bound to the code. These specs pin the
# wire contract — the minted public-client identity, the metadata echo, the
# RFC 7591 error codes, and the unauthenticated reachability (the exact
# `AuthHandler::PUBLIC_ROUTES` entry is guarded by the no-header requests
# below, with the handler enabled).

def post_register(body : String) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  call_api(HTTP::Request.new("POST", "/OAuth/register", headers: headers, body: body))
end

def valid_register_body : String
  {
    redirect_uris:              ["http://localhost:8765/callback"],
    client_name:                "opencode",
    client_uri:                 "https://opencode.ai",
    token_endpoint_auth_method: "none",
    grant_types:                ["authorization_code", "refresh_token"],
    response_types:             ["code"],
    software_id:                "mcp-client",
  }.to_json
end

describe "OAuth — register endpoint" do
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

  it "advertises the registration endpoint in the AS metadata" do
    resp = call_api(HTTP::Request.new("GET", "/.well-known/oauth-authorization-server"))
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["registration_endpoint"].as_s.should eq(
      "#{Facet::OAuth::Discovery.issuer}/OAuth/register")
  end

  it "registers a public client with no session (guards the PUBLIC_ROUTES entry)" do
    # No Authorization header, no cookie — the route itself is the authority.
    resp = post_register(valid_register_body)
    assert_http_status(resp, 201)

    body = JSON.parse(resp.body)
    body["client_id"].as_s.should match(/\A[A-Za-z0-9_-]{43}\z/)
    body["client_id_issued_at"].as_i.should be_close(Time.utc.to_unix, 10)
    body["redirect_uris"].as_a.map(&.as_s).should eq(["http://localhost:8765/callback"])
    body["token_endpoint_auth_method"].as_s.should eq("none")
    body["grant_types"].as_a.map(&.as_s).should eq(["authorization_code", "refresh_token"])
    body["response_types"].as_a.map(&.as_s).should eq(["code"])
    body["client_name"].as_s.should eq("opencode")
    body["client_secret"]?.should be_nil
  end

  it "mints a distinct client_id per registration" do
    first = JSON.parse(post_register(valid_register_body).body)["client_id"].as_s
    second = JSON.parse(post_register(valid_register_body).body)["client_id"].as_s
    first.should_not eq(second)
  end

  it "accepts an https redirect target and ignores unknown metadata members" do
    body = {
      redirect_uris: ["https://client.example.com/callback"],
      software_id:   "some-client",
      logo_uri:      "https://client.example.com/logo.png",
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 201)
    JSON.parse(resp.body)["redirect_uris"].as_a.map(&.as_s)
      .should eq(["https://client.example.com/callback"])
  end

  it "accepts the wildcard-port loopback redirect form" do
    body = {redirect_uris: ["http://127.0.0.1:*/callback", "http://facet.localhost:*/callback"]}.to_json
    resp = post_register(body)
    assert_http_status(resp, 201)
  end

  it "accepts http on loopback hosts, including *.localhost subdomains" do
    body = {
      redirect_uris: [
        "http://localhost:8765/cb",
        "http://facet.localhost:8765/cb",
        "http://127.0.0.1:8765/cb",
        "http://[::1]:8765/cb",
      ],
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 201)
  end

  it "accepts a grant_types subset of the supported grants" do
    body = {
      redirect_uris: ["http://localhost:9000/cb"],
      grant_types:   ["authorization_code"],
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 201)
  end

  it "rejects an http redirect target on a non-loopback host" do
    resp = post_register({redirect_uris: ["http://client.example.com/cb", "http://public.example.com/cb"]}.to_json)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_redirect_uri")
  end

  it "rejects a wildcard port on https" do
    resp = post_register({redirect_uris: ["https://client.example.com:*"]}.to_json)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_redirect_uri")
  end

  it "rejects a malformed redirect entry" do
    body = {
      redirect_uris: [
        "https://client.example.com/cb?x=1",
        "https://client.example.com/cb#x",
        "https://user@client.example.com/cb",
      ],
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_redirect_uri")
  end

  it "rejects a missing redirect_uris member" do
    resp = post_register({client_name: "no redirects"}.to_json)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end

  it "rejects a non-array redirect_uris member" do
    resp = post_register({redirect_uris: "http://localhost:1/cb"}.to_json)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end

  it "rejects a confidential client auth method" do
    body = {
      redirect_uris:              ["http://localhost:1/cb"],
      token_endpoint_auth_method: "client_secret_basic",
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end

  it "rejects an unsupported grant type" do
    body = {
      redirect_uris: ["http://localhost:1/cb"],
      grant_types:   ["client_credentials"],
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end

  it "rejects an unsupported response type" do
    body = {
      redirect_uris:  ["http://localhost:1/cb"],
      response_types: ["token"],
    }.to_json
    resp = post_register(body)
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end

  it "rejects a non-JSON body" do
    headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
    resp = call_api(HTTP::Request.new("POST", "/OAuth/register",
      headers: headers, body: "redirect_uris=http%3A%2F%2Flocalhost%3A1%2Fcb"))
    assert_http_status(resp, 400)
    JSON.parse(resp.body)["error"].as_s.should eq("invalid_client_metadata")
  end
end
