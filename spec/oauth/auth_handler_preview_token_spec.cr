# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../../src/rbac"
require "../../src/mutation/json_diff"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/doctype_helper"
require "../support/oauth_helper"

HTTPTest.init

# AuthHandler `typ: "preview"` JWT acceptance.
#
# The preview token is a short-lived capability token issued by
# `POST /Api/core/Domain/:id/preview-session` after the caller's real
# identity proved `create core.DocType` against the draft. On receipt,
# the AuthHandler:
# 1. Verifies the JWT signature (ES256, like every other token type).
# 2. Loads the named `preview_domain` `core.Domain` projection and
#    confirms `draft = true` — a published-then-dropped draft's token
#    must fail-closed immediately.
# 3. Constructs `AuthContext.preview(account_id, preview_domain)`.
#
# These specs craft a preview token directly via `IAM::JWT.build_preview_payload`
# (same factory the issuance endpoint uses), then exercise
# `AuthHandler.auth_context_from_request` to verify the resulting principal.
# The end-to-end issuance flow (`POST /Api/core/Domain/:id/preview-session`)
# is covered by `spec/domain/preview_session_spec.cr`.

# Builds a preview token bound to the given draft domain id.
def sign_preview_token(account_id : String, preview_domain : String) : String
  payload, _exp = Facet::IAM::JWT.build_preview_payload(
    account_id: account_id,
    sid: Random::Secure.urlsafe_base64(24),
    role: "editor",
    preview_domain: preview_domain,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

# Builds an `HTTP::Server::Context` carrying the token in the Bearer
# header, matching how the frontend forwards preview tokens.
def request_with_token(token : String, path = "/Api/_abc/Widget")
  HTTP::Server::Context.new(
    request: HTTP::Request.new("GET", path, headers: bearer_headers(token)),
    response: HTTP::Server::Response.new(IO::Memory.new),
  )
end

# Signs a regular `typ: "access"` token (the same shape `auth_token` cookies
# carry). Used by the cookie / Bearer precedence spec to mirror the wire
# shape of a same-origin SSR call during preview (which carries BOTH the
# user's `auth_token` cookie and the preview Bearer header).
def sign_access_token(account_id : String, role : String) : String
  payload, _exp = Facet::IAM::JWT.build_access_payload(
    account_id: account_id,
    session_id: Random::Secure.urlsafe_base64(24),
    role: role,
  )
  Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)
end

# Builds a request carrying BOTH the `auth_token` cookie AND a Bearer header.
# Mirrors the SSR-during-preview wire shape: SvelteKit's `event.fetch` forwards
# cookies on same-origin server-side requests, and `apiFetch` overlays the
# preview Bearer header (so the AuthHandler must prefer the preview Bearer
def request_with_cookie_and_bearer(cookie_token : String, bearer_token : String)
  ctx = HTTP::Server::Context.new(
    request: HTTP::Request.new("GET", "/Api/_abc/Widget"),
    response: HTTP::Server::Response.new(IO::Memory.new),
  )
  ctx.request.cookies["auth_token"] = cookie_token
  ctx.request.headers["Authorization"] = "Bearer #{bearer_token}"
  ctx
end

# Helper local to this spec file: creates a `core.Domain` row with
# draft=true. Mirrors what `Domain::Draft.create` writes (a draft row
# whose `content.draft == true`), without going through the full
# Domain::Draft service so the AuthHandler spec stays focused on token
# decoding.
def create_draft_domain_row(db : DB::Connection, name : String) : Nil
  Facet::Mutation::Client.create(
    db, "core", "Domain",
    doc_id: name,
    content: %({"draft": true}),
    actioner_id: "system",
  )
end

describe "AuthHandler — preview token (typ: preview)" do
  around_each do |example|
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end

  before_each do
    with_db do |db|
      create_draft_domain_row(db, "_abc")
    end
  end

  it "constructs a Preview principal bound to the draft domain" do
    with_db do |_db|
      token = sign_preview_token("account_1", "_abc")
      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(request_with_token(token))

      ctx.should_not be_nil
      ctx = ctx.not_nil!
      ctx.preview?.should be_true
      ctx.system?.should be_false
      ctx.account_id.should eq("account_1")
      ctx.preview_domain.should eq("_abc")
      ctx.principal.should be_a(Facet::RBAC::Principal::Preview)
    end
  end

  it "fail-closed (401) when the draft was deleted between issuance and use" do
    with_db do |db|
      token = sign_preview_token("account_1", "_abc")
      # Tombstone the draft domain — defense-in-depth check kicks in.
      Facet::Mutation::Client.delete(db, "core", "Domain", "_abc", actioner_id: "system:test")

      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(request_with_token(token))
      ctx.should be_nil
    end
  end

  it "fail-closed (401) when the draft flag was flipped to false (published)" do
    with_db do |db|
      token = sign_preview_token("account_1", "_abc")
      # Simulate the publish action's flag flip — the row stays, draft=false.
      current = Facet::Mutation::Client.fetch_content(db, "core", "Domain", "_abc")
      new_content = JSON.parse(%({"draft": false}))
      diff = Facet::Mutation::JsonDiff.diff(current, new_content)
      Facet::Mutation::Client.update(
        db, "core", "Domain", "_abc",
        diff_json: diff.to_json,
        actioner_id: "system:test",
      )

      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(request_with_token(token))
      ctx.should be_nil
    end
  end

  it "fail-closed (401) when the named preview_domain does not exist" do
    with_db do |_db|
      token = sign_preview_token("account_1", "_never_existed")
      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(request_with_token(token))
      ctx.should be_nil
    end
  end

  it "fail-closed (401) when the preview_domain claim is missing from the token" do
    with_db do |_db|
      # Hand-craft a token with the right typ but no preview_domain.
      now = Time.utc.to_unix
      payload = {
        "sub"  => JSON::Any.new("account_1"),
        "sid"  => JSON::Any.new("sid"),
        "role" => JSON::Any.new("editor"),
        "jti"  => JSON::Any.new("jti"),
        "typ"  => JSON::Any.new(Facet::IAM::JWT::PREVIEW_TOKEN_TYP),
        "iat"  => JSON::Any.new(now),
        "exp"  => JSON::Any.new(now + 900),
      } of String => JSON::Any
      token = Facet::IAM::JWT.sign(payload, Facet::IAM::TokenEmitter.signing_key, Facet::IAM::TokenEmitter.kid)

      ctx = Facet::HTTP::AuthHandler.auth_context_from_request(request_with_token(token))
      ctx.should be_nil
    end
  end

  describe "cookie / Bearer precedence" do
    # The Builder preview overlay sends its capability token as a Bearer
    # header (set by the frontend's `apiFetch`), but the same request ALSO
    # carries the user's `auth_token` cookie (SvelteKit's `event.fetch`
    # forwards cookies on same-origin SSR calls during a full reload of
    # `/_abc`). The handler must let the preview Bearer win — otherwise the
    # cookie real-user principal would shadow it, draft reads would be
    # authorised as the real user, and the preview would 403/404.

    it "prefers a preview Bearer header over the auth_token cookie" do
      with_db do |_db|
        access = sign_access_token("account_1", "iam.Roles.editor")
        preview = sign_preview_token("account_1", "_abc")
        ctx = Facet::HTTP::AuthHandler.auth_context_from_request(
          request_with_cookie_and_bearer(access, preview)
        )

        ctx.should_not be_nil
        ctx = ctx.not_nil!
        ctx.preview?.should be_true
        ctx.preview_domain.should eq("_abc")
        ctx.principal.should be_a(Facet::RBAC::Principal::Preview)
      end
    end

    it "gives the Authorization header precedence over the auth_token cookie" do
      # An explicit header credential must never be shadowed by the ambient
      # session cookie — a DPoP-bound token presented beside the cookie
      # would otherwise authenticate as the human (see
      # `extract_token_and_scheme`). The same rule makes every explicit
      # Bearer header authoritative: the cookie wins only in the
      # header's absence.
      with_db do |db|
        create_test_role(db, "editor", [{action: "*", on: "*.*"}])

        access_cookie = sign_access_token("account_1", "iam.Roles.editor")
        access_bearer = sign_access_token("account_2", "iam.Roles.editor")
        ctx = Facet::HTTP::AuthHandler.auth_context_from_request(
          request_with_cookie_and_bearer(access_cookie, access_bearer)
        )

        ctx.should_not be_nil
        ctx = ctx.not_nil!
        ctx.preview?.should be_false
        # Header-wins: the account comes from the Bearer header
        # (`account_2`), not the cookie (`account_1`).
        ctx.account_id.should eq("account_2")
      end
    end
  end
end
