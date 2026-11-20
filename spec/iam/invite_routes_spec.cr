# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/http/server"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"

HTTPTest.init

# Route-level specs for the credential-bootstrap endpoints:
#
# - POST /Api/iam/accounts/:id/temporary-password
# - POST /Api/iam/accounts/:id/invite
# - GET  /Api/iam/accounts/credential-states
#
# The gate chain mirrors `mfa_disable`: AuthHandler session + CSRF header +
# `provision_credentials` on `iam.Account` with the system bypass rejected.

describe "IAM credential-bootstrap routes" do
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

  before_each do
    with_db { |db| seed_iam_doctypes(db) }
  end

  it "POST /accounts/:id/temporary-password returns the plaintext once for an operator with provision_credentials" do
    with_db do |db|
      operator_id = create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      target_id = create_test_account(db, email: "target@example.com")
      token = login_token("operator@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/temporary-password", headers: headers))
      assert_http_status(resp, 200)

      password = JSON.parse(resp.body)["temporary_password"].as_s
      password.should match(/^[2-9A-HJKMNP-TV-Z]{4}(-[2-9A-HJKMNP-TV-Z]{4}){3}$/)
      Facet::Secrets.verify(db, "iam.Account.#{target_id}", "password", password).should be_true

      operator_id.should_not be_empty
    end
  end

  it "POST /accounts/:id/temporary-password is 403 for a role without provision_credentials" do
    with_db do |db|
      create_test_account(db, email: "viewer@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      target_id = create_test_account(db, email: "target@example.com")
      token = login_token("viewer@example.com", "pw-pw-pw")

      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/temporary-password", headers: headers))
      assert_http_status(resp, 403)
    end
  end

  it "POST /accounts/:id/temporary-password skips the CSRF header for a Bearer credential (non-ambient)" do
    with_db do |db|
      create_test_account(db, email: "csrf@example.com", password: "pw-pw-pw")
      target_id = create_test_account(db, email: "target@example.com")
      token = login_token("csrf@example.com", "pw-pw-pw")

      # A Bearer credential without a session cookie cannot ride a
      # cross-site browser request, so the CSRF check does not apply —
      # the route proceeds to its RBAC gate and answers 200.
      headers = bearer_headers(token)
      resp = call_api_raw(HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/temporary-password", headers: headers))
      assert_http_status(resp, 200)
    end
  end

  it "POST /accounts/:id/temporary-password rejects the system bypass" do
    with_db do |db|
      target_id = create_test_account(db, email: "target@example.com")

      Facet::HTTP::AuthHandler.enabled = false
      request = HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/temporary-password",
        headers: HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"})
      resp = call_api_as(request, Facet::RBAC::AuthContext.system)
      assert_http_status(resp, 403)
    end
  end

  it "POST /accounts/:id/invite is gated by provision_credentials" do
    with_db do |db|
      target_id = create_test_account(db, email: "target@example.com")

      # Allowed: admin wildcard covers the action.
      create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      token = login_token("operator@example.com", "pw-pw-pw")
      headers = bearer_headers(token)
      headers["X-Requested-With"] = "XMLHttpRequest"
      resp = call_api(HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/invite", headers: headers))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["first_invite"].as_bool.should be_false

      # Denied: read-only role.
      create_test_account(db, email: "viewer2@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      viewer_token = login_token("viewer2@example.com", "pw-pw-pw")
      viewer_headers = bearer_headers(viewer_token)
      viewer_headers["X-Requested-With"] = "XMLHttpRequest"
      resp2 = call_api(HTTP::Request.new("POST", "/Api/iam/accounts/#{target_id}/invite", headers: viewer_headers))
      assert_http_status(resp2, 403)
    end
  end

  it "GET /accounts/credential-states is gated and returns one entry per id" do
    with_db do |db|
      target_id = create_test_account(db, email: "target@example.com")

      create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      token = login_token("operator@example.com", "pw-pw-pw")

      resp = call_api(HTTP::Request.new("GET", "/Api/iam/accounts/credential-states?id=#{target_id}",
        headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      states = JSON.parse(resp.body)["states"].as_a
      states.size.should eq(1)
      states.first["id"].as_s.should eq(target_id)
      states.first["has_password"].as_bool.should be_true
      states.first["federated"].as_bool.should be_false

      # Denied: read-only role.
      create_test_account(db, email: "viewer3@example.com", password: "pw-pw-pw",
        roles: ["iam.Roles.viewer"], default_role: "iam.Roles.viewer")
      viewer_token = login_token("viewer3@example.com", "pw-pw-pw")
      resp2 = call_api(HTTP::Request.new("GET", "/Api/iam/accounts/credential-states?id=#{target_id}",

        headers: bearer_headers(viewer_token)))

      assert_http_status(resp2, 403)
    end
  end

  # A comma join is a natural guess at the grammar — the list `select`
  # parameter comma-splits its values. The route must split them, or the
  # joined string becomes one bogus id that matches no row (F04-04).
  it "GET /accounts/credential-states splits a comma-joined id value" do
    with_db do |db|
      id_a = create_test_account(db, email: "comma-a@example.com")
      id_b = create_test_account(db, email: "comma-b@example.com")

      create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      token = login_token("operator@example.com", "pw-pw-pw")

      resp = call_api(HTTP::Request.new("GET",
        "/Api/iam/accounts/credential-states?id=#{id_a},#{id_b}",
        headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      states = JSON.parse(resp.body)["states"].as_a
      state_ids = states.map(&.["id"].as_s)
      state_ids.should eq([id_a, id_b])
    end
  end

  it "GET /accounts/credential-states accepts repeated and comma-joined ids together and skips empties" do
    with_db do |db|
      id_a = create_test_account(db, email: "comma-c@example.com")
      id_b = create_test_account(db, email: "comma-d@example.com")

      create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      token = login_token("operator@example.com", "pw-pw-pw")

      resp = call_api(HTTP::Request.new("GET",
        "/Api/iam/accounts/credential-states?id=#{id_a},#{id_b}&id=#{id_a},",
        headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      states = JSON.parse(resp.body)["states"].as_a
      state_ids = states.map(&.["id"].as_s)
      state_ids.sort!
      state_ids.should eq([id_a, id_b].sort)
    end
  end

  it "GET /accounts/credential-states still refuses an id set that is empty after the split" do
    with_db do |db|
      create_test_account(db, email: "operator@example.com", password: "pw-pw-pw")
      token = login_token("operator@example.com", "pw-pw-pw")

      resp = call_api(HTTP::Request.new("GET",
        "/Api/iam/accounts/credential-states?id=,,",
        headers: bearer_headers(token)))
      assert_http_status(resp, 422)
    end
  end
end
