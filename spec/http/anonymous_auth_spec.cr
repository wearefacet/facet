# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/doctype/seed"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# The anonymous role fallback (AuthHandler).
#
# A protected route that receives NO credential runs under the seeded
# `iam.Roles.anonymous` role: the handler pins an anonymous AuthContext and
# the request flows through the standard RBAC enforcers, so the role's read
# grants are the public API surface. A presented-but-invalid credential
# answers 401 — a broken token never downgrades to the anonymous principal.
# A missing (or deleted) role projection also answers 401 — fail closed.
#
# Each example enables the AuthHandler and drives the full Kemal stack via
# `call_api`, like the OAuth flow spec. The per-example truncation wipes the
# seed, so `before_each` re-ensures the doctypes the seeded roles documents
# resolve against: the roles documents validate their permission scopes
# against registered doctype definitions, so the definition pass must cover
# every referenced doctype (`core.Comment`, `core.Attachment`) before the
# roles seed — the same dependency order the seed runner guarantees.

# Creates the USD currency row the anonymous-read examples assert on. The
# suite excludes `core.Currency` seed documents from re-seeding (money
# validation uses the in-memory registry), so this file seeds the one row it
# needs through the same pipeline path `spec/currency_spec.cr` uses.
def seed_anonymous_usd(db : DB::Connection) : Nil
  result = Facet::Document::Create.create_from_parsed(
    db, "core", "Currency",
    JSON.parse(%({"ticker": "USD", "name": "US Dollar", "symbol": "$", "digits": 2, "favorite": true, "active": true})),
    Facet::RBAC::AuthContext.system,
    "system",
    doc_id: "USD",
    skip_authorization: true,
  )
  result.should be_a(Facet::Document::Create::Result)
end

describe "HTTP anonymous role fallback" do
  around_each do |example|
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      Fiber.current.auth_context = nil
    end
  end

  before_each do
    with_db do |db|
      %w[core.DocType core.Domain].each do |dir|
        domain, doctype = dir.split(".", 2)
        Facet::Doctype::Seed.ensure_doctype(db, domain, doctype)
      end
      ensure_seed_roles_with_dependencies(db)
      seed_anonymous_usd(db)
      Facet::Doctype::DefinitionStore.cache.clear
    end
  end

  it "serves a granted doctype to a credential-less request" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/Currency?filters[ticker__eq]=USD"))
    assert_http_status(resp, 200)

    body = parse_body(resp)
    body["meta"]["count"].as_i.should eq(1)
    body["data"].as_a.first["meta"]["id"].as_s.should eq("USD")
  end

  it "denies a not-granted doctype: class-level 403 on list and read" do
    # The anonymous role holds no read permission on `iam.Roles` at all —
    # the class-level denial both the list and the single read answer
    # with 403 (one gate result, one answer per operation class).
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/Roles"))
    assert_http_status(resp, 403)

    resp = call_api(HTTP::Request.new("GET", "/Api/iam/Roles/iam.Roles.admin"))
    assert_http_status(resp, 403)
  end

  it "denies a write to a credential-less request (403)" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = call_api(HTTP::Request.new("POST", "/Api/iam/Roles",
      headers: headers, body: %({"name": "intruder", "permissions": []})))
    assert_http_status(resp, 403)
  end

  it "denies a credential-less domain create (403) — the generic path runs the enforcer" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = call_api(HTTP::Request.new("POST", "/Api/core/Domain",
      headers: headers, body: %({"id": "squat"})))
    assert_http_status(resp, 403)
  end

  it "answers 401 for a presented-but-invalid token (never the anonymous data)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/Currency?items=5",
      headers: bearer_headers("not-a-jwt")))
    assert_http_status(resp, 401)
  end

  it "answers 401 for an Authorization header without a scheme (never anonymous)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/Currency?items=5",
      headers: HTTP::Headers{"Authorization" => "raw-token-without-scheme"}))
    assert_http_status(resp, 401)
  end

  it "answers 401 for an Authorization header with an unknown scheme (never anonymous)" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/Currency?items=5",
      headers: HTTP::Headers{"Authorization" => "Basic dXNlcjpwYXNz"}))
    assert_http_status(resp, 401)
  end

  it "answers 401 when the anonymous role projection is deleted" do
    with_db do |db|
      # The projection id of a role document is the qualified form.
      Facet::Mutation::Client.delete(db, "iam", "Roles", "iam.Roles.anonymous", actioner_id: "system")
    end

    resp = call_api(HTTP::Request.new("GET", "/Api/core/Currency?items=5"))
    assert_http_status(resp, 401)
  end

  it "keeps identity routes credential-only" do
    resp = call_api(HTTP::Request.new("GET", "/Api/iam/me"))
    assert_http_status(resp, 401)
  end
end
