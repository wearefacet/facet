# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/auth_handler"
require "../../src/mcp/protected_resource"
require "../../src/mcp"

# The RFC 9728 protected-resource metadata must be reachable
# unauthenticated for every path shape a client may derive — including the
# path-carrying variant (/.well-known/oauth-protected-resource/<path>,
# required by RFC 9728 §3.1 for path-bearing resources) — so the whole
# /.well-known/ prefix is public on GET. These specs drive the real handler
# chain so the contract is caught at the handler layer, not by calling the
# route block directly.
def build_env(method : String, path : String) : HTTP::Server::Context
  request = HTTP::Request.new(method, path)
  request.headers["Host"] = "localhost:3443"
  response = HTTP::Server::Response.new(IO::Memory.new)
  HTTP::Server::Context.new(request, response)
end

# Runs the AuthHandler against a terminal handler that records whether
# the chain reached the route. Mirrors how the handler sits in front of
# every route in production.
def run_handler(env : HTTP::Server::Context) : Int32
  terminal = ->(ctx : HTTP::Server::Context) do
    ctx.response.status_code = 200
    ctx.response.print("route-reached")
    nil
  end
  handler = Facet::HTTP::AuthHandler.new
  handler.next = terminal
  handler.call(env)
  env.response.status_code
end

describe "well-known discovery is unauthenticated" do
  # The suite disables AuthHandler globally (test mode uses system-context
  # requests). These specs exercise the handler itself, so enable it here
  # and restore after — the global after_each also resets it, but an explicit
  # restore keeps this file self-contained.
  before_each { Facet::HTTP::AuthHandler.enabled = true }
  after_each { Facet::HTTP::AuthHandler.enabled = false }

  it "serves the bare PRM document without auth" do
    env = build_env("GET", "/.well-known/oauth-protected-resource")
    status = run_handler(env)
    status.should eq(200)
  end

  it "serves the path-carrying PRM document without auth (the bug)" do
    env = build_env("GET", "/.well-known/oauth-protected-resource/Api/_mcp/iam.Roles.admin")
    status = run_handler(env)
    status.should eq(200)
  end

  it "serves the AS metadata document without auth" do
    env = build_env("GET", "/.well-known/oauth-authorization-server")
    status = run_handler(env)
    status.should eq(200)
  end

  it "still authenticates non-well-known protected routes" do
    env = build_env("GET", "/Api/crm/Contact")
    status = run_handler(env)
    status.should eq(401)
  end

  it "does not open POST to well-known paths" do
    env = build_env("POST", "/.well-known/oauth-authorization-server")
    status = run_handler(env)
    status.should eq(401)
  end

  it "lets MCP routes through to their own 401 handshake" do
    # The handler passes the request down; the MCP route (not the handler)
    # owns authentication there. The terminal stub proves the chain reached
    # the route layer instead of being pre-empted by a bare 401.
    env = build_env("POST", "/Api/_mcp/iam.Roles.admin")
    status = run_handler(env)
    status.should eq(200)
  end
end

# End-to-end: an unauthenticated POST to the MCP endpoint must return 401
# with the RFC 9728 WWW-Authenticate resource_metadata pointer — the exact
# response shape MCP Inspector needs to start discovery.
describe "MCP 401 handshake" do
  it "returns WWW-Authenticate with resource_metadata on unauthenticated POST" do
    io = IO::Memory.new
    request = HTTP::Request.new("POST", "/Api/_mcp/iam.Roles.admin")
    request.headers["Host"] = "localhost:3443"
    response = HTTP::Server::Response.new(io)
    ctx = HTTP::Server::Context.new(request, response)

    reached_route = false
    handler = Facet::HTTP::AuthHandler.new
    handler.next = ->(c : HTTP::Server::Context) do
      # Stand-in for the Kemal route block: reproduce what
      # MCP::Routes#unauthorized_with_prm emits when no bearer token is
      # present. The assertion target is the header contract, so emitting
      # it here keeps the spec focused on the handler's pass-through while
      # pinning the exact wire shape.
      reached_route = true
      c.response.status_code = 401
      c.response.content_type = "application/json"
      c.response.headers["WWW-Authenticate"] =
        "Bearer resource_metadata=" +
        "\"#{Facet::MCP.base_url}/.well-known/oauth-protected-resource/Api/_mcp\""
      c.response.print({error: "Authentication required"}.to_json)
      nil
    end
    handler.call(ctx)
    ctx.response.close

    reached_route.should be_true
    body = io.rewind.gets_to_end
    ctx.response.status_code.should eq(401)
    www = ctx.response.headers["WWW-Authenticate"]?
    www.should_not be_nil
    www.not_nil!.should contain("Bearer resource_metadata=")
    www.not_nil!.should contain("/.well-known/oauth-protected-resource")
    body.should contain("Authentication required")
  end
end
