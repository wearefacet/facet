# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/iam/totp"

describe Facet::IAM::TOTP do
  describe ".generate_secret" do
    it "returns a base32 string of 32 characters (160 bits)" do
      secret = Facet::IAM::TOTP.generate_secret
      secret.should be_a(String)
      # 20 bytes -> 32 base32 chars (no padding)
      secret.size.should eq(32)
      secret.should match(/^[A-Z2-7]+$/)
    end

    it "returns different secrets on each call" do
      s1 = Facet::IAM::TOTP.generate_secret
      s2 = Facet::IAM::TOTP.generate_secret
      s1.should_not eq(s2)
    end
  end

  describe ".generate" do
    it "produces a 6-digit string" do
      secret = Facet::IAM::TOTP.generate_secret
      code = Facet::IAM::TOTP.generate(secret)
      code.should match(/^\d{6}$/)
    end

    it "produces deterministic output for the same secret and time" do
      secret = "JBSWY3DPEHPK3PXP"
      time = 1_700_000_000_i64
      code1 = Facet::IAM::TOTP.generate(secret, time)
      code2 = Facet::IAM::TOTP.generate(secret, time)
      code1.should eq(code2)
    end
  end

  describe ".validate" do
    it "accepts the current time step" do
      secret = Facet::IAM::TOTP.generate_secret
      code = Facet::IAM::TOTP.generate(secret)
      step = Facet::IAM::TOTP.validate(secret, code)
      step.should_not be_nil
    end

    it "rejects an incorrect code" do
      secret = Facet::IAM::TOTP.generate_secret
      step = Facet::IAM::TOTP.validate(secret, "000000")
      step.should be_nil
    end

    it "accepts a code from one step in the future (window)" do
      secret = Facet::IAM::TOTP.generate_secret
      now = Time.utc.to_unix
      future_time = now + 30 # one step ahead
      code = Facet::IAM::TOTP.generate(secret, future_time)
      step = Facet::IAM::TOTP.validate(secret, code, now, window: 1)
      step.should_not be_nil
    end

    it "accepts a code from one step in the past (window)" do
      secret = Facet::IAM::TOTP.generate_secret
      now = Time.utc.to_unix
      past_time = now - 30 # one step behind
      code = Facet::IAM::TOTP.generate(secret, past_time)
      step = Facet::IAM::TOTP.validate(secret, code, now, window: 1)
      step.should_not be_nil
    end
  end

  describe ".otpauth_uri" do
    it "builds a valid otpauth URI with the given parameters" do
      secret = "JBSWY3DPEHPK3PXP"
      uri = Facet::IAM::TOTP.otpauth_uri(secret, "user@example.com", "TestApp")
      uri.should start_with("otpauth://totp/")
      uri.should contain("secret=JBSWY3DPEHPK3PXP")
      uri.should contain("issuer=TestApp")
      uri.should contain("algorithm=SHA1")
      uri.should contain("digits=6")
      uri.should contain("period=30")
    end

    it "URL-encodes the account and issuer" do
      secret = "JBSWY3DPEHPK3PXP"
      uri = Facet::IAM::TOTP.otpauth_uri(secret, "user name@example.com", "My App")
      uri.should contain("My+App")
      uri.should contain("user+name%40example.com")
    end
  end
end
