# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/oauth/dpop"

# Common htu for specs that do not vary it. Mirrors the shape
# `OAuth::HTU.reconstruct` produces — scheme + host + path, no query.
HTU_ROOT = "https://localhost:3000/OAuth/token"

# DPoP (RFC 9449) verifier specs.
#
# Covers: header validation, private-key rejection, RFC 7638 thumbprint
# computation, signature verification (the JWT shard's raw ↔ ASN.1 conversion
# path), claim validation (htm/htu/iat/jti/ath), and the iat asymmetric skew.
#
# By generating ES256 proofs in Crystal and verifying them via the same code
# path that production takes (`JWT.decode`), these specs also exercise the
# raw-R‖S ↔ DER conversion — the JOSE interop concern flagged in the plan.
# A `panva/jose`-generated proof in Node hits the same code path; if these
# pass, JOSE proofs will verify too, since the encoding is fully determined
# by the JWS spec (RFC 7515 §3.4, RFC 7518 §3.3 ES256 = raw R‖S, 32 bytes
# each).
describe Facet::OAuth::DPoP do
  describe ".verify happy path" do
    it "verifies a well-formed proof and returns the thumbprint" do
      with_dpop_config do
        proof, pair = dpop_proof_for_token_endpoint(HTU_ROOT)
        result = Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        result.jkt.should eq(pair.jkt)
        result.htm.should eq("POST")
        result.htu.should eq(HTU_ROOT)
        result.ath.should be_nil
      end
    end

    it "verifies a proof with ath when caller supplies a matching ath" do
      with_dpop_config do
        pair = dpop_key_pair
        ath = Facet::OAuth::DPoP.compute_ath("fake.access.token")
        proof = sign_dpop_proof(pair, htm: "GET", htu: "https://localhost:3000/Api/foo", ath: ath)
        result = Facet::OAuth::DPoP.verify(proof, htm: "GET",
          htu: "https://localhost:3000/Api/foo", ath: ath)
        result.ath.should eq(ath)
      end
    end

    it "verifies a proof whose htu carries a query or fragment (RFC 9449 §4.3, B-21)" do
      with_dpop_config do
        pair = dpop_key_pair
        # The client signs the natural request URL; the server expects
        # origin + path. The comparison must ignore query and fragment.
        proof = sign_dpop_proof(pair, htm: "GET",
          htu: "https://localhost:3000/Api/foo?per_page=1")
        result = Facet::OAuth::DPoP.verify(proof, htm: "GET", htu: "https://localhost:3000/Api/foo")
        result.jkt.should eq(pair.jkt)

        proof2 = sign_dpop_proof(pair, htm: "GET",
          htu: "https://localhost:3000/Api/foo#section")
        result2 = Facet::OAuth::DPoP.verify(proof2, htm: "GET", htu: "https://localhost:3000/Api/foo")
        result2.jkt.should eq(pair.jkt)
      end
    end

    it "still rejects an htu whose path differs" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "GET", htu: "https://localhost:3000/Api/other")
        expect_raises(Facet::OAuth::DPoP::Error, /htu mismatch/) do
          Facet::OAuth::DPoP.verify(proof, htm: "GET", htu: "https://localhost:3000/Api/foo")
        end
      end
    end

    it "lowercases the expected htm before comparison" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT)
        result = Facet::OAuth::DPoP.verify(proof, htm: "post", htu: HTU_ROOT)
        result.htm.should eq("POST")
      end
    end
  end

  describe ".verify header errors" do
    it "rejects non-ES256 alg" do
      with_dpop_config do
        pair = dpop_key_pair
        # alg=RS256 in header but signed as ES256 — the alg in the header
        # is checked before signature verification, so a mismatched signature
        # never gets exercised.
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT, alg: "RS256")
        expect_dpop_error("invalid_dpop_proof") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects wrong typ" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT,
          override_header: {
            "typ" => JSON::Any.new("jwt"),
            "alg" => JSON::Any.new("ES256"),
            "jwk" => JSON::Any.new(pair.jwk),
          })
        expect_dpop_error("invalid_dpop_proof") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects missing jwk" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT,
          override_header: {
            "typ" => JSON::Any.new("dpop+jwt"),
            "alg" => JSON::Any.new("ES256"),
          })
        expect_dpop_error("invalid_dpop_proof") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects a jwk containing a `d` private key member" do
      with_dpop_config do
        pair = dpop_key_pair
        jwk_with_d = pair.jwk.merge({"d" => JSON::Any.new("cHJpdmF0ZQ")})
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT,
          override_header: {
            "typ" => JSON::Any.new("dpop+jwt"),
            "alg" => JSON::Any.new("ES256"),
            "jwk" => JSON::Any.new(jwk_with_d),
          })
        expect_dpop_error("private_key_in_jwk") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects a non-P-256 curve" do
      with_dpop_config do
        pair = dpop_key_pair
        other_curve = pair.jwk.merge({"crv" => JSON::Any.new("P-384")})
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT,
          override_header: {
            "typ" => JSON::Any.new("dpop+jwt"),
            "alg" => JSON::Any.new("ES256"),
            "jwk" => JSON::Any.new(other_curve),
          })
        expect_dpop_error("invalid_dpop_proof") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end
  end

  describe ".verify signature errors" do
    it "rejects a bad signature" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, bad_signature: true)
        expect_dpop_error("invalid_dpop_proof") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end
  end

  describe ".verify claim errors" do
    it "rejects htm mismatch" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "GET", htu: HTU_ROOT)
        end
      end
    end

    it "rejects htu mismatch with query string-style difference" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: "#{HTU_ROOT}?foo=bar")
        end
      end
    end

    it "rejects missing htm" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_proof_without_claim(pair, claim: "htm", htu: HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects missing htu" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_proof_without_claim(pair, claim: "htu", htu: HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects missing iat" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_proof_without_claim(pair, claim: "iat", htu: HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "rejects missing jti" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_proof_without_claim(pair, claim: "jti", htu: HTU_ROOT)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end
  end

  describe ".verify iat skew" do
    it "accepts iat slightly in the future" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix + 9)
        result = Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        result.iat.should be > Time.utc.to_unix
      end
    end

    it "rejects iat too far in the future (11s > 10s tolerance)" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix + 11)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "accepts iat slightly in the past" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix - 29)
        result = Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        result.iat.should be < Time.utc.to_unix
      end
    end

    it "rejects iat too old (31s > 30s tolerance)" do
      with_dpop_config do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix - 31)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end

    it "respects overridden future tolerance" do
      with_dpop_config(future: 60, past: 5) do
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix + 50)
        result = Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        result.iat.should be > Time.utc.to_unix
      end
    end

    it "respects overridden past tolerance" do
      with_dpop_config(future: 60, past: 5) do
        # past=5 → iat 10s ago rejected.
        proof, _pair = dpop_proof_for_token_endpoint(HTU_ROOT, iat: Time.utc.to_unix - 10)
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT)
        end
      end
    end
  end

  describe ".verify ath" do
    it "rejects ath in token-endpoint context" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "POST", htu: HTU_ROOT,
          ath: Facet::OAuth::DPoP.compute_ath("fake"))
        expect_dpop_error("invalid_claim") do
          # ath arg = nil so caller is not validating ath; the presence of ath
          # in the proof is rejected.
          Facet::OAuth::DPoP.verify(proof, htm: "POST", htu: HTU_ROOT, ath: nil)
        end
      end
    end

    it "rejects ath mismatch when caller requires it" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "GET", htu: "https://localhost:3000/Api/foo",
          ath: Facet::OAuth::DPoP.compute_ath("real"))
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "GET",
            htu: "https://localhost:3000/Api/foo",
            ath: Facet::OAuth::DPoP.compute_ath("different"))
        end
      end
    end

    it "rejects missing ath when caller requires it" do
      with_dpop_config do
        pair = dpop_key_pair
        proof = sign_dpop_proof(pair, htm: "GET", htu: "https://localhost:3000/Api/foo")
        expect_dpop_error("invalid_claim") do
          Facet::OAuth::DPoP.verify(proof, htm: "GET",
            htu: "https://localhost:3000/Api/foo",
            ath: Facet::OAuth::DPoP.compute_ath("real"))
        end
      end
    end
  end

  describe ".compute_ath" do
    it "returns base64url no-padding SHA-256 of the token" do
      ath = Facet::OAuth::DPoP.compute_ath("abc")
      digest = OpenSSL::Digest.new("SHA256")
      digest.update("abc")
      ath.should eq(Base64.urlsafe_encode(digest.final, padding: false))
      ath.should_not end_with("=")
    end
  end
end

# ── Spec helpers ────────────────────────────────────────────────────────────

# `OAuth::DPoP.verify` reads `Config.instance.iam.jwt` for clock skew. Specs
# override the config singleton per-example. This helper swaps in a temporary
# `JWTConfig` with the given tolerances (defaulting to the production values)
# and restores the prior config on exit.
private def with_dpop_config(future = 10, past = 30, &)
  original = Facet::Config.instance
  temp = Facet::Config::IAMConfig.new(jwt: Facet::Config::JWTConfig.new(
    access_token_ttl: original.iam.jwt.access_token_ttl,
    refresh_token_ttl: original.iam.jwt.refresh_token_ttl,
    refresh_grace_window: original.iam.jwt.refresh_grace_window,
    dpop_iat_future_tolerance: future,
    dpop_iat_past_tolerance: past,
  ))
  Facet::Config.instance = config_with_iam(original, temp)
  yield
ensure
  Facet::Config.instance = original if original
end

private def expect_dpop_error(error_code, &)
  yield
  fail "Expected OAuth::DPoP::Error with code=#{error_code}, but no error was raised"
rescue ex : Facet::OAuth::DPoP::Error
  ex.error_code.should eq(error_code), "Expected error_code=#{error_code}, got #{ex.error_code}: #{ex.message}"
end
