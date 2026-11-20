# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/token_emitter"
require "../../src/iam/jwt"

describe Facet::IAM::TokenEmitter do
  # `Config.reset!` re-reads the config file between examples; it does not
  # touch the token emitter. The signing-key memo has its own reset, which
  # the `.signing_key / .keys` examples use to stay order-independent —
  # other specs (login flows) may have resolved the key earlier in the
  # process.
  before_each do
    Facet::Config.reset!
  end

  describe ".signing_key / .keys" do
    after_each do
      ENV.delete("JWT_SIGNING_KEY")
      Facet::IAM::TokenEmitter.reset_signing_key!
    end

    it "uses JWT_SIGNING_KEY when the variable is set" do
      Facet::IAM::TokenEmitter.reset_signing_key!
      pem = Facet::IAM::JWT.generate_key_pem
      ENV["JWT_SIGNING_KEY"] = pem

      Facet::IAM::TokenEmitter.signing_key.should eq(pem)
      keys = Facet::IAM::TokenEmitter.keys
      keys["facet-1"]?.should eq(pem)
      keys["env-0"]?.should eq(pem)
    end

    it "generates a PEM after the variable is removed" do
      Facet::IAM::TokenEmitter.reset_signing_key!
      ENV.delete("JWT_SIGNING_KEY")

      Facet::IAM::TokenEmitter.signing_key.should contain("BEGIN")
      Facet::IAM::TokenEmitter.keys.has_key?("env-0").should be_false
    end
  end

  it "emits tokens with the given parameters" do
    result = Facet::IAM::TokenEmitter.emit(
      cookie: true,
      account_id: "account_123",
      email: "test@example.com",
      display_name: "Test User",
      mfa_enabled: false,
      active_role: "iam.Roles.admin",
      available_roles: ["iam.Roles.admin", "iam.Roles.editor"],
      permissions: {"iam.Account" => ["read"]},
      session_id: "session_abc",
      refresh_id: "refresh_xyz",
    )

    result.account_id.should eq("account_123")
    result.email.should eq("test@example.com")
    result.display_name.should eq("Test User")
    result.mfa_enabled.should be_false
    result.active_role.should eq("iam.Roles.admin")
    result.available_roles.should eq(["iam.Roles.admin", "iam.Roles.editor"])
    result.cookie.should be_true
    result.access_token.should_not be_empty
    result.refresh_token.should eq("session_abc.refresh_xyz")
    result.expires_at.should be > Time.utc.to_unix
    result.permissions.should eq({"iam.Account" => ["read"]})
  end

  it "builds a valid JWT access token" do
    result = Facet::IAM::TokenEmitter.emit(
      cookie: false,
      account_id: "account_123",
      email: "test@example.com",
      display_name: "Test User",
      mfa_enabled: false,
      active_role: "iam.Roles.admin",
      available_roles: ["iam.Roles.admin"],
      permissions: nil,
      session_id: "session_abc",
      refresh_id: "refresh_xyz",
    )

    # Verify the access token can be decoded
    decoded = Facet::IAM::JWT.decode(result.access_token, Facet::IAM::TokenEmitter.keys)
    decoded.payload["sub"].should eq(JSON::Any.new("account_123"))
    decoded.payload["sid"].should eq(JSON::Any.new("session_abc"))
    decoded.payload["role"].should eq(JSON::Any.new("iam.Roles.admin"))
    decoded.payload["typ"].should eq(JSON::Any.new("access"))
    decoded.kid.should eq(Facet::IAM::TokenEmitter.kid)
  end

  describe ".response_body" do
    it "returns JSON without tokens when cookie=true" do
      result = Facet::IAM::TokenEmitter.emit(
        cookie: true,
        account_id: "account_123",
        email: "test@example.com",
        display_name: "Test User",
        mfa_enabled: false,
        active_role: "iam.Roles.admin",
        available_roles: ["iam.Roles.admin"],
        permissions: nil,
        session_id: "session_abc",
        refresh_id: "refresh_xyz",
      )

      body = Facet::IAM::TokenEmitter.response_body(result)
      parsed = JSON.parse(body)
      parsed["account"]["id"].should eq("account_123")
      parsed["account"]["email"].should eq("test@example.com")
      parsed["active_role"].should eq("iam.Roles.admin")
      parsed["expires_at"].as_i.should be > Time.utc.to_unix
      parsed.as_h.keys.should_not contain("token")
      parsed.as_h.keys.should_not contain("refresh_token")
    end

    it "includes permissions when present" do
      result = Facet::IAM::TokenEmitter.emit(
        cookie: true,
        account_id: "account_123",
        email: "test@example.com",
        display_name: "Test User",
        mfa_enabled: false,
        active_role: "iam.Roles.admin",
        available_roles: ["iam.Roles.admin"],
        permissions: {"iam.Account" => ["read"]},
        session_id: "session_abc",
        refresh_id: "refresh_xyz",
      )

      body = Facet::IAM::TokenEmitter.response_body(result)
      parsed = JSON.parse(body)
      parsed["permissions"]["iam.Account"].should eq(["read"])
    end
  end

  describe ".full_body" do
    it "returns JSON with tokens when cookie=false" do
      result = Facet::IAM::TokenEmitter.emit(
        cookie: false,
        account_id: "account_123",
        email: "test@example.com",
        display_name: "Test User",
        mfa_enabled: false,
        active_role: "iam.Roles.admin",
        available_roles: ["iam.Roles.admin"],
        permissions: nil,
        session_id: "session_abc",
        refresh_id: "refresh_xyz",
      )

      body = Facet::IAM::TokenEmitter.full_body(result)
      parsed = JSON.parse(body)
      parsed["token"].should eq(result.access_token)
      parsed["refresh_token"].should eq(result.refresh_token)
      parsed["expires_at"].as_i.should be > Time.utc.to_unix
    end
  end
end
