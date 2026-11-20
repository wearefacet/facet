# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../../spec_helper"
require "json"
require "../../../src/http/server"
require "../../support/http_helper"
require "../../support/http_helpers"
require "../../support/iam_helper"
require "../../support/doctype_helper"

# Initialize the HTTP handler chain once (idempotent across spec files)
HTTPTest.init

describe "Full authentication journey" do
  around_each do |example|
    redis_cleanup
    # Enable AuthHandler so JWT tokens are validated and RBAC is enforced
    Facet::HTTP::AuthHandler.enabled = true
    begin
      example.run
    ensure
      Facet::HTTP::AuthHandler.enabled = false
      redis_cleanup
    end
  end

  it "admin creates account → user login → refresh → read → RBAC denies read → logout" do
    # ── Setup: admin (via system auth) creates doctypes, docs, role, and account ──
    person_id = nil
    secret_id = nil

    with_db do |db|
      ensure_domain(db, "identity")

      # Create Person doctype (from shared test data)
      person_defn = load_doctype_schema("identity.Person/definition.yml")
      person_defn_result = Facet::Document::Create.call(db, "core", "DocType",
        person_defn.to_json, Facet::RBAC::AuthContext.system)
      person_defn_result.should be_a(Facet::Document::Create::Result)

      # Create a simple SecretData doctype in the same domain (not readable by custom role)
      secret_defn = Facet::Doctype::DoctypeDefinition.new(
        doctype: "SecretData",
        domain: "identity",
        schema_version: 1,
        fields: {
          "name" => Facet::Doctype::FieldDefinition.new(
            type: Facet::Doctype::StringType.new, required: true),
        },
      )
      secret_defn_result = Facet::Document::Create.call(db, "core", "DocType",
        secret_defn.to_json, Facet::RBAC::AuthContext.system)
      secret_defn_result.should be_a(Facet::Document::Create::Result)

      # Create a Person document (this WILL be readable by the custom role)
      person_content = %({"full_name": "Journey User", "email": "journey@test.com", "date_of_birth": "1990-01-01"})
      person_result = Facet::Document::Create.call(db, "identity", "Person",
        person_content, Facet::RBAC::AuthContext.system)
      person_result.should be_a(Facet::Document::Create::Result)
      person_id = person_result.as(Facet::Document::Create::Result).projection.id

      # Create a SecretData document (this will NOT be readable by the custom role)
      secret_content = %({"name": "top-secret"})
      secret_result = Facet::Document::Create.call(db, "identity", "SecretData",
        secret_content, Facet::RBAC::AuthContext.system)
      secret_result.should be_a(Facet::Document::Create::Result)
      secret_id = secret_result.as(Facet::Document::Create::Result).projection.id

      # Create a custom role "person_reader" that can only read identity.Person
      role_content = {
        "name"         => "person_reader",
        "level"        => 20,
        "description"  => "Can only read Person documents in identity domain",
        "visible_tags" => ["default"],
        "permissions"  => [
          {action: "read", on: "identity.Person"},
        ],
      }.to_json
      Facet::Mutation::Client.create(db, "iam", "Roles",
        doc_id: "iam.Roles.person_reader",
        content: role_content, actioner_id: "system")

      # Create Account with the person_reader role
      account_id = Facet::Util::ScriptHelpers.ulid
      account_content = {
        "email"        => "reader@journey.test",
        "name"         => "Reader User",
        "status"       => "active",
        "roles"        => ["iam.Roles.person_reader"],
        "default_role" => "iam.Roles.person_reader",
        "mfa_enabled"  => false,
      }.to_json
      Facet::Mutation::Client.create(db, "iam", "Account",
        doc_id: account_id, content: account_content, actioner_id: "system")
      Facet::Secrets.set(db, "iam.Account.#{account_id}", "password", "reader-password",
        mode: "hash", set_by: "system")
    end

    # Guard: ensure identifiers were captured
    person_id.should_not be_nil
    secret_id.should_not be_nil
    pid = person_id.not_nil!
    sid = secret_id.not_nil!

    # ── Step 1: Login with the new user ──────────────────────────────────
    login_body = %({"email": "reader@journey.test", "password": "reader-password", "cookie": false})
    login_headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    login_resp = call_api(HTTP::Request.new("POST", "/Api/iam/login",
      headers: login_headers, body: login_body))

    assert_http_status(login_resp, 200)
    login_json = JSON.parse(login_resp.body).as_h
    login_json["token"]?.should_not be_nil
    login_json["refresh_token"]?.should_not be_nil
    # Store token for later steps
    access_token = login_json["token"].to_s
    login_json["active_role"].to_s.should eq("iam.Roles.person_reader")
    login_json["account"]["id"].to_s.should_not be_empty

    refresh_token = login_json["refresh_token"].to_s

    # ── Step 2: Refresh the token ────────────────────────────────────────
    refresh_body = %({"refresh_token": "#{refresh_token}", "cookie": false})
    refresh_headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    refresh_resp = call_api(HTTP::Request.new("POST", "/Api/iam/refresh",
      headers: refresh_headers, body: refresh_body))

    assert_http_status(refresh_resp, 200)
    refresh_json = JSON.parse(refresh_resp.body).as_h
    refresh_json["token"]?.should_not be_nil
    refresh_json["token"].to_s.should_not eq(access_token)
    refresh_json["refresh_token"]?.should_not be_nil
    refresh_json["refresh_token"].to_s.should_not eq(refresh_token)
    new_access_token = refresh_json["token"].to_s
    new_auth_headers = bearer_headers(new_access_token)

    # ── Step 3: Read the Person document (should succeed) ────────────────
    read_person_resp = call_api(HTTP::Request.new("GET",
      "/Api/identity/Person/#{pid}", headers: new_auth_headers))
    assert_http_status(read_person_resp, 200)
    person_body = JSON.parse(read_person_resp.body).as_h
    person_body["data"]["full_name"].to_s.should eq("Journey User")

    # ── Step 4: Read the SecretData document (RBAC denies access) ────────
    read_secret_resp = call_api(HTTP::Request.new("GET",
      "/Api/identity/SecretData/#{sid}", headers: new_auth_headers))
    # The role holds no read permission on SecretData at all — the
    # class-level denial answers 403.
    assert_http_status(read_secret_resp, 403)

    # ── Step 5: Logout ───────────────────────────────────────────────────
    # Logout reads session_id from the auth_token cookie (not Bearer header)
    logout_headers = HTTP::Headers{
      "X-Requested-With" => "XMLHttpRequest",
      "Cookie"           => "auth_token=#{new_access_token}",
    }
    logout_resp = call_api(HTTP::Request.new("POST", "/Api/iam/logout",
      headers: logout_headers))
    assert_http_status(logout_resp, 200)
    logout_json = JSON.parse(logout_resp.body).as_h
    logout_json["ok"].as_bool.should be_true

    # ── Verify: session is destroyed, refresh token no longer works ──────
    stale_refresh_body = %({"refresh_token": "#{refresh_token}", "cookie": false})
    stale_refresh_headers = HTTP::Headers{"X-Requested-With" => "XMLHttpRequest"}
    stale_refresh_resp = call_api(HTTP::Request.new("POST", "/Api/iam/refresh",
      headers: stale_refresh_headers, body: stale_refresh_body))
    assert_http_status(stale_refresh_resp, 401)
  end
end
