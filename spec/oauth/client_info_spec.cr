# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/http/server"
require "../support/http_helper"
require "../support/app_helper"
require "../support/iam_helper"
require "../support/oauth_helper"

HTTPTest.init

# `GET /OAuth/client-info` — public client metadata for first-party CLI
# clients. The CLI resolves its `client_id` by app slug before it starts the
# PKCE authorize flow, so the endpoint must answer without any session (the
# exact `AuthHandler::PUBLIC_ROUTES` entry is guarded by the no-header
# requests below, with the handler enabled).
#
# Every failure path — unknown slug, missing param, draft/disabled app,
# content without `client_id` — returns the same `404 {"error":
# "unknown_client"}` body: no draft/disabled disclosure.

def get_client_info(query : String = "") : HTTP::Client::Response
  call_api(HTTP::Request.new("GET", "/OAuth/client-info#{query}"))
end

describe "OAuth — client-info endpoint" do
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
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
      seed_test_roles(db)
    end
  end

  it "resolves the seeded facet-cli app with no session (guards the PUBLIC_ROUTES entry)" do
    with_db { |db| seed_facet_cli_app(db) }

    # No Authorization header, no cookie — the route itself is the authority.
    resp = get_client_info("?slug=facet-cli")
    assert_http_status(resp, 200)

    body = JSON.parse(resp.body)
    body["slug"].as_s.should eq("facet-cli")
    body["name"].as_s.should eq("Facet CLI")
    body["client_type"].as_s.should eq("public")
    body["client_id"].as_s.should match(/^[0-9A-HJKMNP-TV-Z]{26}$/)
  end

  it "returns 404 unknown_client for an unknown slug" do
    resp = get_client_info("?slug=no-such-app")
    assert_http_status(resp, 404)
    JSON.parse(resp.body).should eq(JSON.parse(%({"error": "unknown_client"})))
  end

  it "returns 404 when the slug param is missing" do
    resp = get_client_info
    assert_http_status(resp, 404)
    JSON.parse(resp.body).should eq(JSON.parse(%({"error": "unknown_client"})))
  end

  it "returns 404 for a draft app, body identical to the unknown case" do
    slug = with_db do |db|
      _, _client_id = create_test_app(db, "draft-app", display_name: "Draft Probe", status: "draft")
      db.query_one(
        "SELECT content->>'slug' FROM projections WHERE domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL AND content->>'name' = 'Draft Probe'",
        as: String)
    end
    resp = get_client_info("?slug=#{slug}")
    assert_http_status(resp, 404)
    JSON.parse(resp.body).should eq(JSON.parse(%({"error": "unknown_client"})))
  end

  it "returns 404 for a disabled app" do
    slug = with_db do |db|
      _, _client_id = create_test_app(db, "disabled-app", display_name: "Disabled Probe", status: "disabled")
      db.query_one(
        "SELECT content->>'slug' FROM projections WHERE domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL AND content->>'name' = 'Disabled Probe'",
        as: String)
    end
    resp = get_client_info("?slug=#{slug}")
    assert_http_status(resp, 404)
    JSON.parse(resp.body).should eq(JSON.parse(%({"error": "unknown_client"})))
  end

  it "returns 404 when the app content carries no client_id" do
    # `Mutation::Client.create` skips script execution, so the create hook
    # never assigns `client_id` — the exact malformed-registration shape.
    slug = "no-cid-#{Facet::Util::ScriptHelpers.ulid.downcase[0..12]}"
    with_db do |db|
      Facet::Mutation::Client.create(
        db, "app", "App",
        content: {
          slug:         slug,
          display_name: "No CID App",
          status:       "active",
        }.to_json,
        actioner_id: "system",
        meta: %({"parent_id": "app"}),
      )
    end
    resp = get_client_info("?slug=#{slug}")
    assert_http_status(resp, 404)
    JSON.parse(resp.body).should eq(JSON.parse(%({"error": "unknown_client"})))
  end
end
