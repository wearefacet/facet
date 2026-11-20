# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../../src/iam/jwt"
require "../../src/iam/token_emitter"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/oauth_helper"

HTTPTest.init

# Unauthenticated authorize → login redirect.
#
# When the browser session is missing or expired, GET/POST
# /OAuth/authorize must bounce to the frontend login page with the
# original authorize URL embedded as the `redirectTo` param (the param the
# login flow already consumes) — never a bare 401 JSON body, which would
# dead-end an MCP client's browser leg after session expiry.
#
# The redirect target is guarded: only a path-absolute URL whose path is
# exactly `/OAuth/authorize` is accepted. Anything else (scheme-relative,
# absolute, other paths) is rejected with 400 — no open redirect.

def oauth_authorize_unauthenticated(method : String, query_or_body : String) : HTTP::Client::Response
  headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
  if method == "GET"
    call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query_or_body}", headers: headers))
  else
    call_api(HTTP::Request.new("POST", "/OAuth/authorize", headers: headers, body: query_or_body))
  end
end

describe "OAuth — unauthenticated authorize login redirect" do
  around_each do |example|
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
    end
  end

  it "GET with no session → 302 to /Login with encoded redirectTo" do
    query = URI::Params.encode({
      "response_type"         => "code",
      "client_id"             => "some-client",
      "redirect_uri"          => "http://127.0.0.1:9999/cb",
      "state"                 => "st-123",
      "code_challenge"        => "a" * 43,
      "code_challenge_method" => "S256",
    })
    resp = oauth_authorize_unauthenticated("GET", query)
    assert_http_status(resp, 302)

    location = resp.headers["Location"]?
    location.should_not be_nil
    loc = location.not_nil!
    loc.should start_with("/Login?redirectTo=")

    # The embedded target must round-trip to the original authorize URL.
    target = URI.parse(loc).query_params.fetch("redirectTo", "")
    target.should eq("/OAuth/authorize?#{query}")
  end

  it "POST with no session → 303 to /Login (re-issued as GET)" do
    body = URI::Params.encode({
      "response_type" => "code",
      "client_id"     => "some-client",
      "redirect_uri"  => "http://127.0.0.1:9999/cb",
      "role"          => "iam.Roles.admin",
    })
    resp = oauth_authorize_unauthenticated("POST", body)
    assert_http_status(resp, 303)

    location = resp.headers["Location"]?
    location.should_not be_nil
    location.not_nil!.should start_with("/Login?redirectTo=")
  end

  it "GET with an expired/garbage session token → 302 to /Login" do
    headers = HTTP::Headers{
      "Authorization" => "Bearer not-a-real-jwt",
      "Content-Type"  => "application/x-www-form-urlencoded",
    }
    resp = call_api(HTTP::Request.new("GET", "/OAuth/authorize?client_id=x", headers: headers))
    assert_http_status(resp, 302)
    resp.headers["Location"].should start_with("/Login?redirectTo=")
  end

  it "authenticated request → consent JSON, no redirect" do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
      _, client_id = create_test_app(db, "redirect-app",
        redirect_uris: ["https://app.example.com/cb"],
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      create_test_role(db, "reader", [oauth_perm("read", "crm.Contact")])
      create_test_account(db,
        email: "redirectflow@example.com",
        password: "redirect-password",
        roles: ["iam.Roles.reader"], default_role: "iam.Roles.reader")

      body = %({"email": "redirectflow@example.com", "password": "redirect-password", "cookie": false})
      headers = HTTP::Headers{
        "Content-Type"     => "application/json",
        "X-Requested-With" => "XMLHttpRequest",
      }
      login = call_api(HTTP::Request.new("POST", "/Api/iam/login", headers: headers, body: body))
      assert_http_status(login, 200)
      session = JSON.parse(login.body)["token"].as_s

      query = URI::Params.encode({
        "response_type"         => "code",
        "client_id"             => client_id,
        "redirect_uri"          => "https://app.example.com/cb",
        "code_challenge"        => s256_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "code_challenge_method" => "S256",
      })
      resp = call_api(HTTP::Request.new("GET", "/OAuth/authorize?#{query}",
        headers: bearer_headers(session)))
      assert_http_status(resp, 200)
      consent = JSON.parse(resp.body)
      consent["app"]["client_id"].as_s.should eq(client_id)
      resp.headers["Location"]?.should be_nil
    end
  end
end

# Re-opening the namespace to pin the guard's contract. The guard is the
# open-redirect backstop for the login bounce; it must accept only the
# authorize path and reject every absolute/scheme-relative/other-path form.
module Facet
  module OAuth
    module Routes
      def self.guard(url : String) : Bool
        safe_return_to?(url)
      end
    end
  end
end

describe "OAuth — return_to guard (safe_return_to?)" do
  it "accepts the authorize path with and without a query" do
    Facet::OAuth::Routes.guard("/OAuth/authorize").should be_true
    Facet::OAuth::Routes.guard("/OAuth/authorize?client_id=x&state=y").should be_true
  end

  it "rejects scheme-relative, absolute, and other-path targets" do
    Facet::OAuth::Routes.guard("//evil.com/OAuth/authorize").should be_false
    Facet::OAuth::Routes.guard("https://evil.com/OAuth/authorize").should be_false
    Facet::OAuth::Routes.guard("http://localhost:3443/OAuth/authorize").should be_false
    Facet::OAuth::Routes.guard("/other/path?x=1").should be_false
    Facet::OAuth::Routes.guard("/OAuth/authorize/extra").should be_false
    Facet::OAuth::Routes.guard("").should be_false
  end
end
