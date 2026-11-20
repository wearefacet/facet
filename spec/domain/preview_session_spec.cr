# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/rbac"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../domain/draft_domains_spec"

HTTPTest.init

# HTTP endpoint `POST /Api/core/Domain/:id/preview-session` — issues a
# preview-mode capability token scoped to a draft domain.
#
# Coverage:
# 1. Happy path — issuing against an existing draft returns 201 with a
#    signed token whose decoded payload carries `preview_domain` and
#    `typ: preview`.
# 2. The issued token round-trips through `AuthHandler.auth_context_from_request`
#    to produce a `Principal::Preview`.
# 3. 404 when the named draft does not exist.
# 4. 422 when the named domain is not a draft (draft=false).
# 5. 403 when no real authenticated context is on the fiber (system bypass
#    cannot produce a capability token attributed to a real account).
# 6. 403 (401 under AuthHandler) when the caller lacks `create core.DocType`.

# Builds a real authenticated context with the editor-style permission set
# (create/read/update/delete on every domain). Mirrors the standard seeded
# `editor` role.
def editor_auth_context(account_id : String = "account_editor") : Facet::RBAC::AuthContext
  perms = [
    Facet::RBAC::Permission.new(action: "create", domain: "*", path: ["*"]),
    Facet::RBAC::Permission.new(action: "read", domain: "*", path: ["*"]),
    Facet::RBAC::Permission.new(action: "update", domain: "*", path: ["*"]),
    Facet::RBAC::Permission.new(action: "delete", domain: "*", path: ["*"]),
  ]
  role = Facet::RBAC::ActiveRole.new(
    role_id: "editor",
    visible_tags: Set{"default"},
    permissions: perms,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

# Builds a real authenticated context with NO permissions. Used to verify
# the `create core.DocType` gate fails closed for callers lacking the
# permission.
def no_perms_auth_context(account_id : String = "account_nobody") : Facet::RBAC::AuthContext
  role = Facet::RBAC::ActiveRole.new(
    role_id: "no_perms",
    visible_tags: Set{"default"},
    permissions: [] of Facet::RBAC::Permission,
  )
  Facet::RBAC::AuthContext.authenticated(account_id, role)
end

describe "POST /Api/core/Domain/:id/preview-session" do
  # AuthHandler is OFF — these specs inject real auth contexts through
  # `Fiber.current.auth_context` directly, like the collection_view specs.
  # The endpoint itself rejects `system`/denied principals regardless of
  # AuthHandler state (defense-in-depth), so the bypass is harmless.

  it "issues a preview token for an existing draft under an editor role" do
    draft = create_draft_via_api

    Fiber.current.auth_context = editor_auth_context
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 201)

    body = JSON.parse(resp.body)
    body["data"]["preview_domain"].as_s.should eq(draft)
    body["data"]["expires_at"].as_i.should be > 0

    token = body["data"]["token"].as_s
    token.should_not be_empty

    decoded = Facet::IAM::JWT.decode(token, Facet::IAM::TokenEmitter.keys)
    decoded.payload["typ"].as_s.should eq(Facet::IAM::JWT::PREVIEW_TOKEN_TYP)
    decoded.payload["preview_domain"].as_s.should eq(draft)
    decoded.payload["sub"].as_s.should eq("account_editor")
  end

  it "round-trips the issued token through AuthHandler to a Preview principal" do
    draft = create_draft_via_api

    Fiber.current.auth_context = editor_auth_context
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 201)
    token = JSON.parse(resp.body)["data"]["token"].as_s

    Facet::HTTP::AuthHandler.enabled = true
    begin
      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(
        HTTP::Server::Context.new(
          request: HTTP::Request.new("GET", "/Api/#{draft}/Widget", headers: bearer_headers(token)),
          response: HTTP::Server::Response.new(IO::Memory.new),
        )
      )
      ctx.should_not be_nil
      ctx = ctx.not_nil!
      ctx.preview?.should be_true
      ctx.preview_domain.should eq(draft)
      ctx.account_id.should eq("account_editor")
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end

  it "returns 404 for an unknown domain id" do
    Fiber.current.auth_context = editor_auth_context
    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/_does_not_exist/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 404)
    JSON.parse(resp.body)["error"].as_s.should contain("not found")
  end

  it "returns 422 when the named domain is not a draft (live domain)" do
    ensure_domain(with_db { |db| db }, "live")
    Fiber.current.auth_context = editor_auth_context

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/live/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 422)
    JSON.parse(resp.body)["error"].as_s.should contain("not a draft")
  end

  it "returns 403 when the caller is on the system bypass" do
    draft = create_draft_via_api
    # System bypass — the endpoint rejects because there is no real account
    # to attribute the capability to.
    Fiber.current.auth_context = Facet::RBAC::AuthContext.system

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 403)
  end

  it "returns 403 when the caller lacks create core.DocType" do
    draft = create_draft_via_api
    Fiber.current.auth_context = no_perms_auth_context

    resp = call_api(HTTP::Request.new(
      "POST",
      "/Api/core/Domain/#{draft}/preview-session",
      body: "{}",
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    ))
    assert_http_status(resp, 403)
  end
end
