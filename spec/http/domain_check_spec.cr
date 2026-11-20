# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"

HTTPTest.init

describe "GET /Api/core/Domain/:id/check" do
  it "returns 200 with an empty per-doctype list and a :no_doctypes warning for an empty draft" do
    draft = create_draft_via_api

    resp = call_api(HTTP::Request.new("GET", "/Api/core/Domain/#{draft}/check"))
    assert_http_status(resp, 200)
    body = JSON.parse(resp.body)
    body["data"]["domain"].as_s.should eq(draft)
    body["data"]["doctypes"].as_a.should be_empty
    domain_issues = body["data"]["domain_issues"].as_a
    domain_issues.size.should eq(1)
    domain_issues[0]["category"].as_s.should eq("no_doctypes")

    # issue_count is the sum of domain_issues + per-doctype warning issues.
    body["data"]["issue_count"].as_i.should eq(1)
  end

  it "returns 404 for an unknown domain" do
    resp = call_api(HTTP::Request.new("GET", "/Api/core/Domain/does_not_exist/check"))
    assert_http_status(resp, 404)
    body = JSON.parse(resp.body)
    body["error"].as_s.should contain("not found")
  end

  # Per-doctype aggregation is exercised end-to-end through the
  # `spec/domain/check_spec.cr` unit spec, which calls `Check.call` directly
  # against draft doctypes. The HTTP route is a thin serializer on top —
  # testing it here would require reseeding `core.DocType` (wiped by the
  # global truncation) to create the doctype definition via the service
  # layer, which the unit spec sidesteps by calling `Mutation::Client.create`
  # directly.
end
