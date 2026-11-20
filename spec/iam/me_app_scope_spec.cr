# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam"
require "../../src/oauth"
require "../../src/http/server"
require "../support/app_helper"
require "../support/oauth_helper"
require "../support/http_helper"
require "../support/http_helpers"
require "../support/iam_helper"
require "../support/redis_helper"

HTTPTest.init

# `GET /Api/iam/me` — the credential-aware permission manifest.
#
# An app-scoped caller (an app token `typ: "app"` or an app-owned API key)
# carries the resolved grant ∩ role on its auth context (`AuthHandler`
# re-resolves it per request). The manifest the route returns is built from
# that effective scope: from the app's perspective, a document its grant does
# not name does not exist, so no `*.*` fallback and no doctype outside the
# grant may appear. A session caller keeps the active role's own manifest.
#
# The `assistant` block follows the same rule the create route enforces
# (`Assistant::App::Gate.allowed?`): for an app-scoped caller, `access` is
# the AND of the role's `assistant_access` and the app's own
# `assistant_enabled` flag.
describe "GET /Api/iam/me — app-scoped manifest" do
  around_each do |example|
    redis_cleanup
    Facet::HTTP::AuthHandler.enabled = true
    Facet::OAuth::OriginCache.reset
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      Facet::OAuth::OriginCache.reset
      redis_cleanup
    end
  end

  before_each do
    with_db do |db|
      seed_app_doctypes(db)
      seed_iam_doctypes(db)
    end
  end

  it "serves the effective scope to an app token: only the granted doctypes, no wildcard fallback" do
    with_db do |db|
      # A wildcard role (admin-shaped) — everything the app can reach comes
      # from the grant alone.
      role_id = create_test_role(db, "app_wildcard_reader", [oauth_perm("read", "*.*")])
      app_id, _client_id = create_test_app(db, "me-scope-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)

      token = sign_app_token(account_id, role_id, app_id)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body)
      perms = body["permissions"].as_h
      # Only the grant target — no `*.*`, no other doctype.
      perms.keys.should eq(["crm.Contact"])
      perms["crm.Contact"].as_a.map(&.as_s).should eq(["read"])
      body["channel"].as_s.should eq("api")
    end
  end

  it "unions concrete grants over the role's doctypes" do
    with_db do |db|
      role_id = create_test_role(db, "app_crm_reader", [
        oauth_perm("read", "crm.Contact"),
        oauth_perm("create", "crm.Contact"),
        oauth_perm("read", "hr.Employee"),
      ])
      app_id, _client_id = create_test_app(db, "me-domain-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)

      token = sign_app_token(account_id, role_id, app_id)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      perms = JSON.parse(resp.body)["permissions"].as_h
      # The grant narrows the role to the granted doctype; hr never appears.
      perms.keys.should eq(["crm.Contact"])
      perms["crm.Contact"].as_a.map(&.as_s).should eq(["read"])
    end
  end

  it "drops a carved doctype and folds descendant carve-outs under except.action" do
    with_db do |db|
      # The role reads everything except two doctypes. The Contact grant is
      # served (the carve-outs miss it, and the fold rides the except key);
      # the Secret grant is fully carved — its only line excepts the target,
      # so the doctype does not exist in the manifest at all. The Secret
      # action stays optional: a required action the role carves never
      # issues a token (usability gate, fail closed).
      role_id = create_test_role(db, "app_excepting_reader", [
        {"action" => "read", "on" => "*.*", "except" => ["crm.Secret", "crm.Hidden"]},
      ])
      app_id, _client_id = create_test_app(db, "me-except-app",
        grants: [
          oauth_grant("crm.Contact", [oauth_action("read", required: true)]),
          oauth_grant("crm.Secret", [oauth_action("read")]),
        ])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)

      token = sign_app_token(account_id, role_id, app_id)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      perms = JSON.parse(resp.body)["permissions"].as_h
      perms.keys.sort!.should eq(["crm.Contact", "crm.Contact.except.read"])
      perms["crm.Contact"].as_a.map(&.as_s).should eq(["read"])
      perms["crm.Contact.except.read"].as_a.map(&.as_s).sort!.should eq(["crm.Hidden", "crm.Secret"])
      perms.has_key?("crm.Secret").should be_false
    end
  end

  it "keeps the scope aliases in the scopes map for a scoped role line" do
    with_db do |db|
      role_id = create_test_role(db, "app_scoped_reader", [
        {"action" => "read", "on" => "crm.Contact", "scope" => ["$own"]},
      ])
      app_id, _client_id = create_test_app(db, "me-scoped-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)

      token = sign_app_token(account_id, role_id, app_id)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body)
      scopes = body["scopes"].as_h
      scopes["crm.Contact"]["read"].as_a.map(&.as_s).should eq(["own"])
    end
  end

  it "ANDs the app assistant_enabled flag into assistant.access for an app token" do
    with_db do |db|
      role_id = create_test_role(db, "app_assistant_reader", [oauth_perm("read", "crm.Contact")])
      app_id, _client_id = create_test_app(db, "me-assistant-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)
      token = sign_app_token(account_id, role_id, app_id)

      # Default fixture: the flag is absent — reads as off.
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["assistant"]["access"].raw.should be_falsey

      # Flip the app flag on — the role flag holds, so access turns true.
      flip = Facet::Document::Update.call(db, "app", "App", app_id,
        %({"assistant_enabled": true}))
      raise "Failed to flip assistant_enabled: #{flip.inspect}" unless flip.is_a?(Facet::Document::Update::Result)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me", headers: bearer_headers(token)))
      assert_http_status(resp, 200)
      JSON.parse(resp.body)["assistant"]["access"].raw.should be_truthy
    end
  end

  it "keeps the full role manifest for a session caller" do
    with_db do |db|
      role_id = create_test_role(db, "session_wildcard_reader", [oauth_perm("read", "*.*")])
      # An app exists, but the session caller does not use it.
      create_test_app(db, "me-session-app",
        grants: [oauth_grant("crm.Contact", [oauth_action("read", required: true)])])
      account_id = create_test_account(db, roles: [role_id], default_role: role_id)

      token = me_token(account_id, role_id)
      resp = call_api(HTTP::Request.new("GET", "/Api/iam/me",
        headers: HTTP::Headers{"Cookie" => "auth_token=#{token}"}))
      assert_http_status(resp, 200)

      body = JSON.parse(resp.body)
      body["permissions"].as_h.keys.should eq(["*.*"])
      body["channel"].as_s.should eq("session")
    end
  end
end

# Signs a test access token for the `/Api/iam/me` cookie flow — the same
# construction `iam_integration_spec` uses, scoped to this file.
private def me_token(account_id : String, role : String) : String
  pem_key = Facet::IAM::TokenEmitter.signing_key
  payload, _exp = Facet::IAM::JWT.build_access_payload(account_id, "fake-sid", role)
  Facet::IAM::JWT.sign(payload, pem_key, "facet-1")
end
