# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

# B-113 — wrong Content-Type must not be a 5xx on the nested document routes.
#
# The media-type gate sits at the nested POST/PATCH entry points, before any
# body parse: `multipart/form-data` and every other non-JSON media type
# answer `415` (the documented intake is the standalone artifact upload plus
# a JSON sidecar create), and a malformed body under a JSON media type
# answers `400` at the earliest parse point. A wrong Content-Type is a
# caller error, never a server fault.
HTTPTest.init

describe "RestRoutes content-type gate" do
  it "answers 415 for a multipart POST on a nested route" do
    body = "--bnd\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--bnd--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=bnd"}
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", headers, body: body))

    resp.status_code.should eq 415
    resp.body.should contain "multipart/form-data"
    resp.body.should contain "/Api/core/artifacts"
  end

  it "answers 415 for a multipart POST on a nested sidecar route" do
    body = "--bnd\r\nContent-Disposition: form-data; name=\"$content\"\r\n\r\n{}\r\n--bnd--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=bnd"}
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/comments", headers, body: body))

    resp.status_code.should eq 415
  end

  it "answers 415 for a multipart PATCH on a nested route" do
    body = "--bnd\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--bnd--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=bnd"}
    resp = call_api(HTTP::Request.new("PATCH", "/Api/no-such-domain/NoSuch/01AB/lines/02CD", headers, body: body))

    resp.status_code.should eq 415
  end

  it "answers 415 for any non-JSON content type on POST and PATCH" do
    {"POST", "PATCH"}.each do |method|
      headers = HTTP::Headers{"Content-Type" => "text/plain"}
      resp = call_api(HTTP::Request.new(method, "/Api/no-such-domain/NoSuch/01AB/lines", headers, body: "plain"))

      resp.status_code.should eq 415
      resp.body.should contain "application/json"
    end
  end

  it "lets a body with no Content-Type header through the gate (flat-route tolerance)" do
    # No Content-Type at all: the gate passes the body through to the
    # resolvers — an unknown path answers the resolver's 404, not 415.
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", body: "{\"qty\": 1}"))
    resp.status_code.should eq 404

    # A malformed body under no content type still answers 400, not 5xx.
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", body: "{broken"))
    resp.status_code.should eq 400
    resp.body.should contain "Invalid JSON body"
  end

  it "answers 400 for malformed JSON with a JSON content type on POST" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", headers, body: "{\"qty\": "))

    resp.status_code.should eq 400
    resp.body.should contain "Invalid JSON body"
  end

  it "answers 400 for malformed JSON with a JSON content type on PATCH" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = call_api(HTTP::Request.new("PATCH", "/Api/no-such-domain/NoSuch/01AB/lines/02CD", headers, body: "not json"))

    resp.status_code.should eq 400
    resp.body.should contain "Invalid JSON body"
  end

  it "answers 415 before path resolution — an unknown doctype never reaches the services" do
    body = "--bnd\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--bnd--\r\n"
    headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=bnd"}
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", headers, body: body))

    # The gate precedes the parent/child resolvers: a multipart body answers
    # 415, never the resolver's 404 and never a 5xx.
    resp.status_code.should eq 415
    resp.status_code.should be < 500
  end

  it "keeps the empty-body 422 for a JSON POST" do
    headers = HTTP::Headers{"Content-Type" => "application/json"}
    resp = call_api(HTTP::Request.new("POST", "/Api/no-such-domain/NoSuch/01AB/lines", headers, body: ""))

    resp.status_code.should eq 422
    resp.body.should contain "Request body is required"
  end
end
