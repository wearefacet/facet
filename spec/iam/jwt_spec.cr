# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/jwt"

describe Facet::IAM::JWT do
  it "signs and verifies a token" do
    pem_key = Facet::IAM::JWT.generate_key_pem
    payload, _exp = Facet::IAM::JWT.build_access_payload("account_123", "session_abc", "admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "test-key-1")
    decoded = Facet::IAM::JWT.decode(token, {"test-key-1" => pem_key})
    decoded.payload["sub"].should eq(JSON::Any.new("account_123"))
    decoded.payload["role"].should eq(JSON::Any.new("admin"))
    decoded.payload["typ"].should eq(JSON::Any.new("access"))
    decoded.kid.should eq("test-key-1")
  end

  it "rejects a token with wrong key" do
    pem_key = Facet::IAM::JWT.generate_key_pem
    payload, _exp = Facet::IAM::JWT.build_access_payload("account_123", "session_abc", "admin")
    token = Facet::IAM::JWT.sign(payload, pem_key, "test-key-1")
    wrong_key = Facet::IAM::JWT.generate_key_pem
    expect_raises(Facet::IAM::JWT::Error) do
      Facet::IAM::JWT.decode(token, {"test-key-1" => wrong_key})
    end
  end

  it "rejects a token with alg:none" do
    pem_key = Facet::IAM::JWT.generate_key_pem
    payload, _exp = Facet::IAM::JWT.build_access_payload("account_123", "session_abc", "admin")
    # Manually craft a token with alg: none
    header_b64 = Base64.urlsafe_encode(%({"alg":"none","typ":"JWT"}))
    payload_b64 = Base64.urlsafe_encode(payload.to_json)
    token = "#{header_b64}.#{payload_b64}."
    expect_raises(Facet::IAM::JWT::Error, /ES256/) do
      Facet::IAM::JWT.decode(token, {"test-key-1" => pem_key})
    end
  end

  it "rejects a token with a different algorithm" do
    pem_key = Facet::IAM::JWT.generate_key_pem
    payload, _exp = Facet::IAM::JWT.build_access_payload("account_123", "session_abc", "admin")
    header_b64 = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}))
    payload_b64 = Base64.urlsafe_encode(payload.to_json)
    token = "#{header_b64}.#{payload_b64}.fakesignature"
    expect_raises(Facet::IAM::JWT::Error, /ES256/) do
      Facet::IAM::JWT.decode(token, {"test-key-1" => pem_key})
    end
  end

  it "rejects an expired token" do
    pem_key = Facet::IAM::JWT.generate_key_pem
    now = Time.utc.to_unix
    expired_payload = {
      "sub"  => JSON::Any.new("account_123"),
      "sid"  => JSON::Any.new("session_abc"),
      "role" => JSON::Any.new("admin"),
      "jti"  => JSON::Any.new("uuid-123"),
      "typ"  => JSON::Any.new("access"),
      "iat"  => JSON::Any.new(now - 2000),
      "exp"  => JSON::Any.new(now - 1000),
    }
    token = Facet::IAM::JWT.sign(expired_payload, pem_key, "test-key-1")
    expect_raises(Facet::IAM::JWT::Error) do
      Facet::IAM::JWT.decode(token, {"test-key-1" => pem_key})
    end
  end

  it "builds a payload with standard claims" do
    payload, exp = Facet::IAM::JWT.build_access_payload("account_123", "session_abc", "admin")
    payload["sub"].should eq(JSON::Any.new("account_123"))
    payload["sid"].should eq(JSON::Any.new("session_abc"))
    payload["role"].should eq(JSON::Any.new("admin"))
    payload["typ"].should eq(JSON::Any.new("access"))
    payload.keys.should contain("jti")
    payload.keys.should contain("iat")
    payload.keys.should contain("exp")
    exp.should be > Time.utc.to_unix
  end

  it "generates a PEM-encoded P-256 key" do
    pem = Facet::IAM::JWT.generate_key_pem
    pem.should be_a(String)
    pem.should contain("BEGIN EC PRIVATE KEY")
  end
end
