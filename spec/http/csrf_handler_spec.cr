# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"

# Global CSRF gate (`HTTP::CsrfHandler`).
#
# A cookie-session request on a method that can change state must carry a
# non-blank `X-Requested-With` header; the handler answers `403` with the
# shared CSRF body otherwise, one position in front of `AuthHandler`. A
# bearer credential without the session cookie is non-ambient and exempt,
# and so is a request with no cookie at all. The specs drive the raw request
# shape through `call_api_raw`: `call_api` adds the browser default header
# and would mask the negative paths.
#
# The probe path sits outside `/Api/` on purpose: `DomainGate` passes it
# through and no route matches it, so a request that passes the CSRF gate
# reaches the router and comes back as the JSON 404 — a deterministic
# downstream answer that never carries the CSRF body. No database is needed.
HTTPTest.init

describe "global CSRF handler" do
  it "answers 403 with the shared CSRF body for a cookie-session POST without the header" do
    request = HTTP::Request.new(
      "POST", "/CsrfSpec/Probe",
      HTTP::Headers{
        "Content-Type" => "application/json",
        "Cookie"       => "auth_token=spec-session-token",
      },
      "{}",
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should eq("CSRF: Missing X-Requested-With header")
  end

  it "lets the same POST through with the header" do
    request = HTTP::Request.new(
      "POST", "/CsrfSpec/Probe",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "Cookie"           => "auth_token=spec-session-token",
        "X-Requested-With" => "XMLHttpRequest",
      },
      "{}",
    )
    resp = call_api_raw(request)

    resp.status_code.should_not eq(403)
    resp.body.should_not contain("CSRF:")
  end

  it "does not gate a bearer-only POST without the header (non-ambient exemption)" do
    request = HTTP::Request.new(
      "POST", "/CsrfSpec/Probe",
      HTTP::Headers{
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer spec-non-ambient-token",
      },
      "{}",
    )
    resp = call_api_raw(request)

    resp.status_code.should_not eq(403)
    resp.body.should_not contain("CSRF:")
  end

  it "does not gate a GET that carries the cookie and no header" do
    request = HTTP::Request.new(
      "GET", "/CsrfSpec/Probe",
      HTTP::Headers{"Cookie" => "auth_token=spec-session-token"},
    )
    resp = call_api_raw(request)

    resp.status_code.should_not eq(403)
    resp.body.should_not contain("CSRF:")
  end

  it "answers 403 for an empty X-Requested-With value" do
    request = HTTP::Request.new(
      "POST", "/CsrfSpec/Probe",
      HTTP::Headers{
        "Content-Type"     => "application/json",
        "Cookie"           => "auth_token=spec-session-token",
        "X-Requested-With" => "",
      },
      "{}",
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should eq("CSRF: Missing X-Requested-With header")
  end

  it "keeps the cookie session gated beside a Bearer credential" do
    request = HTTP::Request.new(
      "POST", "/CsrfSpec/Probe",
      HTTP::Headers{
        "Content-Type"  => "application/json",
        "Authorization" => "Bearer spec-ambient-token",
        "Cookie"        => "auth_token=spec-session-token",
      },
      "{}",
    )
    resp = call_api_raw(request)

    assert_http_status(resp, 403)
    JSON.parse(resp.body)["error"].as_s.should eq("CSRF: Missing X-Requested-With header")
  end

  it "ships with no path exemptions" do
    Facet::HTTP::CsrfHandler::EXEMPT_PATHS.should be_empty
  end
end
