# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/secrets/codec"

describe Facet::Secrets::Codec do
  describe "hash" do
    it "round-trips hash_payload / verify_hash" do
      payload = Facet::Secrets::Codec.hash_payload("correct horse battery staple")
      Facet::Secrets::Codec.verify_hash("correct horse battery staple", payload).should be_true
    end

    it "rejects a wrong candidate" do
      payload = Facet::Secrets::Codec.hash_payload("correct horse battery staple")
      Facet::Secrets::Codec.verify_hash("wrong horse", payload).should be_false
    end

    it "produces a bcrypt modular-crypt payload starting with $2" do
      payload = Facet::Secrets::Codec.hash_payload("anything")
      payload.should start_with("$2")
    end

    it "verifies a payload produced with the same pre-hash contract" do
      # The pre-hash (SHA-256 + strict base64) is shared by create and
      # verify — a payload hashes the input the same way on both sides.
      payload = Facet::Secrets::Codec.hash_payload("shared-contract")
      Facet::Secrets::Codec.verify_hash("shared-contract", payload).should be_true
    end
  end

  describe "sealed" do
    it "round-trips seal / open" do
      payload = Facet::Secrets::Codec.seal("s3cr3t", "secretstore.Widget.01ABCDEF", "api_key")
      Facet::Secrets::Codec.open(payload, "secretstore.Widget.01ABCDEF", "api_key").should eq("s3cr3t")
    end

    it "raises when one ciphertext byte is tampered with" do
      payload = Facet::Secrets::Codec.seal("s3cr3t", "secretstore.Widget.01ABCDEF", "api_key")
      parts = payload.split(".")
      ciphertext = Base64.decode(parts[3])
      ciphertext[0] = (ciphertext[0] ^ 0x01).to_u8!
      parts[3] = Base64.strict_encode(ciphertext)

      expect_raises(ArgumentError) do
        Facet::Secrets::Codec.open(parts.join("."), "secretstore.Widget.01ABCDEF", "api_key")
      end
    end

    it "raises when opened under a different (doc_ref, slot) — AAD binding" do
      payload = Facet::Secrets::Codec.seal("s3cr3t", "secretstore.Widget.01ABCDEF", "api_key")

      expect_raises(ArgumentError) do
        Facet::Secrets::Codec.open(payload, "otherdomain.Widget.01ABCDEF", "api_key")
      end
      expect_raises(ArgumentError) do
        Facet::Secrets::Codec.open(payload, "secretstore.Widget.01ABCDEF", "other_slot")
      end
    end

    it "bakes the algorithm, kid, nonce, ciphertext, and tag into the payload" do
      payload = Facet::Secrets::Codec.seal("s3cr3t", "secretstore.Widget.01ABCDEF", "api_key")
      parts = payload.split(".")
      parts.size.should eq(5)
      parts[0].should eq("gcm-v1")
      parts[1].should eq("default")
      Base64.decode(parts[2]).size.should eq(12) # 96-bit GCM nonce
      Base64.decode(parts[4]).size.should eq(16) # GCM tag
    end

    it "raises on a payload sealed under an unknown kid" do
      parts = Facet::Secrets::Codec.seal("s3cr3t", "secretstore.Widget.01ABCDEF", "api_key").split(".")
      parts[1] = "rotated-2026"
      expect_raises(ArgumentError, /key id/) do
        Facet::Secrets::Codec.open(parts.join("."), "secretstore.Widget.01ABCDEF", "api_key")
      end
    end
  end

  describe "token" do
    it "matches sha256.<64 hex>" do
      payload = Facet::Secrets::Codec.token_payload("raw-token-abc")
      payload.should match(/\Asha256\.[0-9a-f]{64}\z/)
    end

    it "produces equal payloads for equal raw tokens" do
      Facet::Secrets::Codec.token_payload("same-token")
        .should eq(Facet::Secrets::Codec.token_payload("same-token"))
    end

    it "produces different payloads for different raw tokens" do
      Facet::Secrets::Codec.token_payload("one")
        .should_not eq(Facet::Secrets::Codec.token_payload("two"))
    end

    it "round-trips the digest through token_digest_from_payload" do
      payload = Facet::Secrets::Codec.token_payload("raw-token-abc")
      decoded = Facet::Secrets::Codec.token_digest_from_payload(payload)
      decoded.should_not be_nil
      decoded.should eq(Facet::Secrets::Codec.token_digest("raw-token-abc"))
    end

    it "returns nil from token_digest_from_payload on a malformed payload" do
      Facet::Secrets::Codec.token_digest_from_payload("sha256.zzz").should be_nil
      Facet::Secrets::Codec.token_digest_from_payload("bcrypt.$2b$04$x").should be_nil
    end
  end

  describe "parse_mode" do
    it "classifies the three modes and unknown payloads" do
      Facet::Secrets::Codec.parse_mode(
        Facet::Secrets::Codec.hash_payload("x")
      ).should eq("hash")
      Facet::Secrets::Codec.parse_mode(
        Facet::Secrets::Codec.seal("x", "d.T.i", "s")
      ).should eq("sealed")
      Facet::Secrets::Codec.parse_mode(
        Facet::Secrets::Codec.token_payload("x")
      ).should eq("token")
      Facet::Secrets::Codec.parse_mode("random-garbage").should eq("unknown")
    end
  end

  describe "constant_time_equal" do
    it "returns true for equal digests" do
      a = Facet::Secrets::Codec.token_digest("same input")
      b = Facet::Secrets::Codec.token_digest("same input")
      Facet::Secrets::Codec.constant_time_equal(a, b).should be_true
    end

    it "returns false for different digests of the same size" do
      a = Facet::Secrets::Codec.token_digest("one")
      b = Facet::Secrets::Codec.token_digest("two")
      Facet::Secrets::Codec.constant_time_equal(a, b).should be_false
    end

    it "returns false for different sizes" do
      a = Slice(UInt8).new(4, 0_u8)
      b = Slice(UInt8).new(8, 0_u8)
      Facet::Secrets::Codec.constant_time_equal(a, b).should be_false
    end
  end
end
