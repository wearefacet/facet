# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "openssl"
require "jwt"
require "json"
require "base64"
require "crypto/subtle"
require "./discovery"

module Facet
  module IAM
    module OIDC
      # id_token verification for inbound OIDC logins.
      #
      # The header is never trusted to select the algorithm:
      # `alg` must be in the pinned allowlist {RS256, ES256}
      # — `none` and every HMAC variant are rejected before any key is
      # touched — and the selected JWK's `kty` must match the pinned
      # algorithm (RSA for RS256, EC P-256 for ES256), which closes the
      # algorithm-confusion window. Unlike `IAM::JWT` (ES256-only, for our
      # own tokens), this verifier is a separate concern by design.
      module Verify
        ALLOWED_ALGS = %w[RS256 ES256]

        # An id_token issued more than a day ago is rejected even when its
        # signature is valid — it bounds replay of a captured token beyond
        # the `exp` check.
        IAT_MAX_AGE = 24.hours

        # Verifies an id_token against the provider's JWKS, refreshing the
        # key set exactly once when the token's `kid` is unknown (rotation).
        # Returns the verified payload; raises `Error` on any failure.
        def self.call(
          token : String,
          provider : Provider,
          nonce : String,
        ) : Hash(String, JSON::Any)
          endpoints = Discovery.endpoints(provider.issuer)
          keys = Discovery.keys(provider.issuer, endpoints.jwks_uri)
          begin
            verify_with_keys(token, provider, nonce, keys)
          rescue ex : Error
            if ex.code == "unknown_kid"
              refreshed = Discovery.keys(provider.issuer, endpoints.jwks_uri, refresh: true)
              return verify_with_keys(token, provider, nonce, refreshed)
            end
            raise ex
          end
        end

        # Verifies against an explicit key set. Exposed for specs — the
        # verification matrix exercises claim and signature failures
        # without an HTTP round-trip.
        def self.verify_with_keys(
          token : String,
          provider : Provider,
          nonce : String,
          keys : Hash(String, JWK),
        ) : Hash(String, JSON::Any)
          parts = token.split('.')
          unless parts.size == 3
            raise Error.new("invalid_token", "Malformed id_token (expected 3 segments)")
          end

          header = parse_segment(parts[0])
          alg = header["alg"]?.try(&.as_s?) || ""
          unless ALLOWED_ALGS.includes?(alg)
            raise Error.new("invalid_alg", "id_token alg '#{alg}' is not allowed")
          end

          key = select_key(keys, header["kid"]?.try(&.as_s?), provider)
          check_key_matches_alg(key, alg)

          pem = jwk_to_pem(key)
          jwt_alg = alg == "RS256" ? ::JWT::Algorithm::RS256 : ::JWT::Algorithm::ES256
          decoded = ::JWT.decode(token, pem, jwt_alg, verify: true, validate: true)
          payload = decoded[0].as_h

          check_claims(payload, provider, nonce)
          payload
        rescue ex : Error
          raise ex
        rescue ::JWT::ExpiredSignatureError
          raise Error.new("expired_token", "id_token is expired")
        rescue ::JWT::Error
          raise Error.new("invalid_signature", "id_token signature verification failed")
        rescue JSON::ParseException
          raise Error.new("invalid_token", "id_token header or payload is not valid JSON")
        end

        # ── Private ────────────────────────────────────────────────────────

        private def self.parse_segment(segment : String) : Hash(String, JSON::Any)
          JSON.parse(Base64.decode_string(segment)).as_h? ||
            raise Error.new("invalid_token", "id_token segment is not a JSON object")
        end

        private def self.select_key(keys : Hash(String, JWK), kid : String?, provider) : JWK
          if kid
            return keys[kid]? || raise Error.new("unknown_kid", "id_token kid '#{kid}' is not in the JWKS of #{provider.name}")
          end
          # Tokens without a `kid` are only unambiguous when the key set
          # holds exactly one key.
          if keys.size == 1
            return keys.values.first
          end
          raise Error.new("invalid_token", "id_token carries no kid and the JWKS holds #{keys.size} keys")
        end

        private def self.check_key_matches_alg(key : JWK, alg : String) : Nil
          expected_kty = alg == "RS256" ? "RSA" : "EC"
          unless key.kty == expected_kty
            raise Error.new("invalid_token", "JWK kty '#{key.kty}' does not match pinned alg #{alg}")
          end
          if alg == "ES256" && key.crv != "P-256"
            raise Error.new("invalid_token", "ES256 requires an EC P-256 key, got curve '#{key.crv}'")
          end
        end

        private def self.check_claims(
          payload : Hash(String, JSON::Any),
          provider : Provider,
          nonce : String,
        ) : Nil
          iss = payload["iss"]?.try(&.as_s?)
          unless iss == provider.issuer
            raise Error.new("invalid_iss", "id_token iss does not match the provider issuer")
          end

          aud = payload["aud"]?.try(&.as_s?)
          unless aud == provider.client_id
            raise Error.new("invalid_aud", "id_token aud does not match this client")
          end

          exp = int_claim(payload, "exp")
          unless exp > Time.utc.to_unix
            raise Error.new("expired_token", "id_token exp is not in the future")
          end

          iat = int_claim(payload, "iat")
          unless iat >= Time.utc.to_unix - IAT_MAX_AGE.total_seconds.to_i64
            raise Error.new("invalid_iat", "id_token iat is too far in the past")
          end

          token_nonce = payload["nonce"]?.try(&.as_s?) || ""
          unless Crypto::Subtle.constant_time_compare(token_nonce, nonce)
            raise Error.new("invalid_nonce", "id_token nonce does not match the stored nonce")
          end
        end

        private def self.int_claim(payload : Hash(String, JSON::Any), claim : String) : Int64
          value = payload[claim]?.try(&.as_i64?) ||
                  payload[claim]?.try(&.as_s?.try(&.to_i64?))
          unless value
            raise Error.new("invalid_token", "id_token is missing the '#{claim}' claim")
          end
          value
        end

        # ── JWK → PEM ─────────────────────────────────────────────────────

        # Reconstructs a JWK into a PEM-encoded SubjectPublicKeyInfo. EC
        # conversion mirrors `OAuth::DPoP#jwk_to_ec_pem`; RSA is built here.
        private def self.jwk_to_pem(key : JWK) : String
          der = case key.kty
                when "RSA"
                  build_rsa_public_key_der(decode_member(key.n, "n"), decode_member(key.e, "e"))
                else
                  build_ec_public_key_der(decode_member(key.x, "x"), decode_member(key.y, "y"))
                end
          pem_encode_public_key(der)
        end

        private def self.decode_member(value : String?, member : String) : Bytes
          unless value
            raise Error.new("invalid_token", "JWK is missing the '#{member}' member")
          end
          Base64.decode(value)
        rescue ArgumentError
          raise Error.new("invalid_token", "JWK member '#{member}' is not valid base64")
        end

        # SubjectPublicKeyInfo DER for rsaEncryption:
        # SEQUENCE { SEQUENCE { OID 1.2.840.113549.1.1.1, NULL }, BIT STRING }
        # where the bit string wraps SEQUENCE { INTEGER n, INTEGER e }.
        RSA_PUBLIC_KEY_OID = Bytes[0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]
        DER_NULL           = Bytes[0x05, 0x00]

        private def self.build_rsa_public_key_der(n : Bytes, e : Bytes) : Bytes
          rsa_key = encode_der_sequence(encode_der_integer(n) + encode_der_integer(e))
          alg_id = encode_der_sequence(RSA_PUBLIC_KEY_OID + DER_NULL)
          bit_string = encode_der_bitstring(Bytes[0x00] + rsa_key)
          encode_der_sequence(alg_id + bit_string)
        end

        # SubjectPublicKeyInfo DER for EC P-256 (same OIDs as `OAuth::DPoP`):
        # id-ecPublicKey = 1.2.840.10045.2.1, prime256v1 = 1.2.840.10045.3.1.7.
        EC_PUBLIC_KEY_OID = Bytes[0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
        P256_CURVE_OID    = Bytes[0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

        private def self.build_ec_public_key_der(x_bytes : Bytes, y_bytes : Bytes) : Bytes
          # Uncompressed point: 0x04 || x || y
          point = Bytes.new(1 + x_bytes.size + y_bytes.size)
          point[0] = 0x04_u8
          x_bytes.copy_to(point + 1)
          y_bytes.copy_to(point + 1 + x_bytes.size)

          alg_id = encode_der_sequence(EC_PUBLIC_KEY_OID + P256_CURVE_OID)
          bit_string = encode_der_bitstring(Bytes[0x00] + point)
          encode_der_sequence(alg_id + bit_string)
        end

        private def self.encode_der_integer(bytes : Bytes) : Bytes
          # Strip redundant leading zeros, then keep one when the value's
          # top bit is set (DER INTEGERs are signed).
          first = 0
          while first < bytes.size - 1 && bytes[first] == 0
            first += 1
          end
          content = bytes[first..]
          content = Bytes[0x00] + content if !content.empty? && (content[0] & 0x80) != 0
          encode_der_tlv(0x02, content)
        end

        private def self.encode_der_sequence(content : Bytes) : Bytes
          encode_der_tlv(0x30, content)
        end

        private def self.encode_der_bitstring(content : Bytes) : Bytes
          encode_der_tlv(0x03, content)
        end

        private def self.encode_der_tlv(tag : UInt8, content : Bytes) : Bytes
          length = content.size
          if length < 128
            result = Bytes.new(2 + length)
            result[0] = tag
            result[1] = length.to_u8
            content.copy_to(result + 2)
            return result
          end
          byte_count = 0
          temp = length
          while temp > 0
            byte_count += 1
            temp >>= 8
          end
          result = Bytes.new(1 + 1 + byte_count + length)
          result[0] = tag
          result[1] = (0x80 | byte_count).to_u8
          byte_count.times do |i|
            result[2 + byte_count - 1 - i] = (length & 0xFF).to_u8
            length >>= 8
          end
          content.copy_to(result + 2 + byte_count)
          result
        end

        private def self.pem_encode_public_key(der : Bytes) : String
          b64 = Base64.strict_encode(der)
          lines = ["-----BEGIN PUBLIC KEY-----"]
          offset = 0
          while offset < b64.size
            line_length = Math.min(64, b64.size - offset)
            lines << b64[offset, line_length]
            offset += line_length
          end
          lines << "-----END PUBLIC KEY-----"
          lines.join("\n") + "\n"
        end
      end
    end
  end
end
