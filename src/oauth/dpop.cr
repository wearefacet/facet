# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "openssl"
require "jwt"
require "../config"
require "./replay_cache"

module Facet
  module OAuth
    # DPoP (RFC 9449) proof-of-possession verifier for the App System.
    #
    # A DPoP proof is a short-lived ES256 JWT sent in the `DPoP` HTTP header.
    # Its signature binds the request to a client-held EC P-256 key pair whose
    # public half is embedded in the JWT header as a JWK. The verifier:
    #
    # 1. Pins `alg` to `ES256` (header read before any signature check — no
    #    algorithm confusion).
    # 2. Pins `typ` to `dpop+jwt` (RFC 9449 §4.2).
    # 3. Reads `jwk` from the header and rejects private keys — any proof whose
    #    JWK carries a `d` member (or any other private key parameter) is
    #    rejected with `private_key_in_jwk` before thumbprint computation.
    # 4. Computes the RFC 7638 JWK thumbprint (`jkt`), returned to callers so
    #    they can bind tokens to it (`cnf.jkt`) and compare it on subsequent
    #    requests.
    # 5. Verifies the signature with the JWK-as-PEM public key via
    #    `JWT.decode` (handles the JOSE raw R‖S ↔ OpenSSL DER conversion).
    # 6. Validates the payload claims `htm`, `htu`, `iat`, `jti`, and (when
    #    supplied) `ath`.
    #
    # **Replay defence** lives outside this module — the caller runs
    # `OAuth::ReplayCache.check_and_mark(jkt, jti)` after `verify` returns.
    # That keeps `verify` pure and lets the cache TTL track the configured `iat`
    # acceptance window instead of being coupled to signature logic.
    #
    # **`ath` scope.** `verify` accepts `ath` as an optional argument. When nil,
    # it parses `ath` from the proof (and validates it against the supplied
    # hash) but does not require it. Token-endpoint and refresh callers pass
    # `ath: nil` — neither grant presents an access token. The API-surface
    # caller (`AuthHandler`) passes the SHA-256 of the bearer token and
    # requires a match.
    module DPoP
      class Error < Exception
        getter error_code : String
        getter status : Int32

        def initialize(@error_code : String, message : String, @status : Int32 = 401)
          super(message)
        end
      end

      # A successfully verified DPoP proof. Callers bind `jkt` to tokens and
      # run replay-cache lookups on `jti`.
      record Proof,
        jkt : String,
        jti : String,
        iat : Int64,
        htm : String,
        htu : String,
        ath : String?

      # The validated payload claims of a DPoP proof, ready for `Proof`
      # construction after the claim checks pass.
      private record VerifiedClaims,
        jti : String,
        iat : Int64,
        htm : String,
        htu : String,
        ath : String?

      # Private JWK members that must never appear in a DPoP `jwk` header.
      # RFC 9449 §4.2 — clients send only public keys; sending a private key
      # hands the verifier the signing material, which would defeat
      # proof-of-possession entirely.
      PRIVATE_JWK_MEMBERS = {"d", "p", "q", "dp", "dq", "qi", "oth", "k"}

      # Verifies a DPoP proof.
      #
      # - `proof` — the raw JWT string from the `DPoP` header.
      # - `htm` — the expected HTTP method (uppercase).
      # - `htu` — the expected HTTP URI, reconstructed by the caller from the
      #   configured public origin (no query, no fragment).
      # - `ath` — when non-nil, the base64url SHA-256 of the access token the
      #   proof accompanies. Required to match the proof's `ath` claim if
      #   present; the API surface always passes it and treats a missing
      #   `ath` claim as `invalid_claim`. Token/refresh callers pass nil and
      #   accept proofs that omit `ath` (the verifier still validates any
      #   `ath` the proof carries against this value when both are present).
      def self.verify(
        proof : String,
        htm : String,
        htu : String,
        ath : String? = nil,
      ) : Proof
        # ── 1–3. Structural split, header parse, JOSE header checks ───
        jwk = parse_proof_header(proof)

        # ── 4. JWK thumbprint (RFC 7638) ────────────────────────
        jkt = jwk_thumbprint(jwk)

        # ── 5. Signature verification via JWT.decode ───────────────
        # The shard handles the JOSE raw-R‖S ↔ OpenSSL DER conversion. We
        # pass a single-element key hash keyed by an arbitrary `kid`; the
        # shard falls back to trying all keys when `kid` is absent from the
        # header (DPoP proofs carry no `kid`).
        pem = jwk_to_ec_pem(jwk)
        begin
          decoded = ::JWT.decode(proof, pem, ::JWT::Algorithm::ES256, verify: true, validate: false)
          payload = decoded[0].as_h
        rescue ex
          raise Error.new("invalid_dpop_proof", "DPoP signature verification failed: #{ex.message}")
        end

        # ── 6–7. Required payload claims, iat skew, ath ──────────────
        claims = validate_proof_claims(payload, htm, htu, ath)

        Proof.new(
          jkt: jkt,
          jti: claims.jti,
          iat: claims.iat,
          htm: claims.htm,
          htu: claims.htu,
          ath: claims.ath,
        )
      end

      # Splits the proof, parses the header, and enforces the JOSE header
      # constraints before any signature trust: `alg` pinned to `ES256` (no
      # algorithm confusion), `typ` pinned to `dpop+jwt` (RFC 9449 §4.2), a
      # `jwk` present, and no private-key material in the JWK. Returns the
      # header's JWK for thumbprint and signature use.
      private def self.parse_proof_header(proof : String) : Hash(String, JSON::Any)
        parts = proof.split('.')
        unless parts.size == 3
          raise Error.new("invalid_dpop_proof", "Malformed DPoP proof (expected 3 segments)")
        end
        header_json, _, _ = parts

        header = parse_json_segment(header_json, "header")
        alg = header["alg"]?.try(&.as_s?)
        unless alg == "ES256"
          raise Error.new("invalid_dpop_proof", "DPoP alg must be ES256, got #{alg || "missing"}")
        end
        typ = header["typ"]?.try(&.as_s?)
        unless typ == "dpop+jwt"
          raise Error.new("invalid_dpop_proof", "DPoP typ must be dpop+jwt, got #{typ || "missing"}")
        end
        jwk = header["jwk"]?.try(&.as_h?)
        unless jwk
          raise Error.new("invalid_dpop_proof", "DPoP header missing 'jwk'")
        end

        # Reject any JWK carrying private-key material. This runs before
        # thumbprint computation — a private key must never be accepted even
        # if the rest of the proof is valid.
        reject_private_jwk!(jwk)
        jwk
      end

      # Validates the payload claims against the expected request context:
      # non-empty `jti`, `htm`/`htu` match, the asymmetric per-config `iat`
      # skew window, and the `ath` contract (required and matching when the
      # caller supplies one, fail-closed when the proof carries one the
      # caller cannot compare). Raises `Error` on the first violating claim.
      # Returns the validated claim values for `Proof` construction.
      private def self.validate_proof_claims(
        payload : Hash(String, JSON::Any),
        htm : String,
        htu : String,
        ath : String?,
      ) : VerifiedClaims
        proof_htm = string_claim(payload, "htm")
        proof_htu = string_claim(payload, "htu")
        proof_jti = string_claim(payload, "jti")
        proof_iat = int_claim(payload, "iat")

        # A collision on `jti` between two clients must not evict a peer's
        # cache entry; the cache is scoped by `jkt`. An empty `jti` would
        # collide with every other empty `jti` under the same thumbprint.
        if proof_jti.empty?
          raise Error.new("invalid_claim", "DPoP 'jti' must be non-empty")
        end

        unless proof_htm == htm.upcase
          raise Error.new("invalid_claim", "DPoP htm mismatch: expected #{htm.upcase}, got #{proof_htm}")
        end
        # RFC 9449 §4.3: the server compares `htu` ignoring the query and
        # fragment components. A client that signs the natural request URL
        # (query included) still verifies — strip fragment first, then query,
        # so a `?` inside the fragment goes with the fragment. The expected
        # value is origin + path only (see `OAuth::HTU.reconstruct`).
        proof_htu = proof_htu.split('#', 2)[0].split('?', 2)[0]
        unless proof_htu == htu
          raise Error.new("invalid_claim", "DPoP htu mismatch: expected #{htu}, got #{proof_htu}")
        end

        # ── iat skew (asymmetric, per config) ──────────────────
        now = Time.utc.to_unix
        cfg = Facet::Config.instance.iam.jwt
        if proof_iat > now + cfg.dpop_iat_future_tolerance
          raise Error.new("invalid_claim", "DPoP iat is too far in the future")
        end
        if proof_iat < now - cfg.dpop_iat_past_tolerance
          raise Error.new("invalid_claim", "DPoP iat is too old")
        end

        # ── ath (optional claim, validated when caller supplies it) ─
        proof_ath = payload["ath"]?.try(&.as_s?)
        if ath
          # API-surface caller: proof MUST carry a matching `ath`.
          unless proof_ath == ath
            raise Error.new("invalid_claim", "DPoP ath does not match the access token")
          end
        elsif proof_ath
          # Caller does not care about `ath`; if the proof carries one
          # anyway we have nothing to compare it to, so we fail closed —
          # a proof with `ath` in a context that does not provide one is
          # malformed, since `ath` is only meaningful for token-bearing
          # requests.
          raise Error.new("invalid_claim", "DPoP 'ath' present but not expected here")
        end

        VerifiedClaims.new(
          jti: proof_jti,
          iat: proof_iat,
          htm: proof_htm,
          htu: proof_htu,
          ath: proof_ath,
        )
      end

      # Verifies a proof and rejects replays by consulting the replay cache
      # scoped by `(jkt, jti)` — the shared post-verify step of the token and
      # refresh grants. `replay_error_code` is the OAuth error code used when
      # a replayed proof is detected (the two grants differ). Any failure —
      # including the replay — raises via `build_error.call(error_code,
      # message)` so each grant keeps its own error type and HTTP status.
      def self.verify_bound(
        proof : String,
        htm : String,
        htu : String,
        ath : String?,
        replay_error_code : String,
        &build_error : String, String -> Exception
      ) : Proof
        verified = verify(proof, htm: htm, htu: htu, ath: ath)
        unless ReplayCache.check_and_mark(verified.jkt, verified.jti)
          raise build_error.call(replay_error_code, "DPoP proof replayed")
        end
        verified
      rescue ex : Error
        raise build_error.call(ex.error_code, ex.message || "DPoP proof invalid")
      end

      # ── Internals ──────────────────────────────────────────────────────

      # Parses a Base64URL segment into a `Hash`. Raises `invalid_dpop_proof`
      # for any structural error so callers get a uniform error type.
      private def self.parse_json_segment(b64 : String, name : String) : Hash(String, JSON::Any)
        decoded = Base64.decode_string(b64)
        parsed = JSON.parse(decoded)
        unless parsed.as_h?
          raise Error.new("invalid_dpop_proof", "DPoP #{name} is not a JSON object")
        end
        parsed.as_h
      rescue Base64::Error
        raise Error.new("invalid_dpop_proof", "DPoP #{name} is not valid Base64URL")
      rescue JSON::ParseException
        raise Error.new("invalid_dpop_proof", "DPoP #{name} is not valid JSON")
      end

      # Rejects a JWK that carries private-key material before thumbprint
      # computation. RFC 9449 §4.2 — the header `jwk` is the *public* key.
      private def self.reject_private_jwk!(jwk : Hash(String, JSON::Any)) : Nil
        PRIVATE_JWK_MEMBERS.each do |member|
          if jwk[member]?
            raise Error.new("private_key_in_jwk", "DPoP jwk must not contain '#{member}' (private key material)")
          end
        end
      end

      # RFC 7638 §3 canonical thumbprint: SHA-256 over the JSON serialization
      # of `{ "crv", "kty", "x", "y" }` with no whitespace and lexicographic
      # member ordering, base64url-encoded without padding. Only valid for the
      # EC `P-256` keys that DPoP allows — the caller has already gated `kty`
      # implicitly via `jwk_to_ec_pem`.
      private def self.jwk_thumbprint(jwk : Hash(String, JSON::Any)) : String
        kty = jwk["kty"]?.try(&.as_s?)
        crv = jwk["crv"]?.try(&.as_s?)
        x = jwk["x"]?.try(&.as_s?)
        y = jwk["y"]?.try(&.as_s?)
        unless kty && crv && x && y
          raise Error.new("invalid_dpop_proof", "DPoP jwk is missing required EC members (kty, crv, x, y)")
        end
        unless kty == "EC" && crv == "P-256"
          raise Error.new("invalid_dpop_proof", "DPoP jwk must be EC P-256, got #{kty}/#{crv}")
        end
        canonical = %({"crv":"#{crv}","kty":"#{kty}","x":"#{x}","y":"#{y}"})
        digest = OpenSSL::Digest.new("SHA256")
        digest.update(canonical)
        Base64.urlsafe_encode(digest.final, padding: false)
      end

      # Reconstructs the JWK into a PEM-encoded EC public key. Mirrors the
      # construction in `JWT::JWKS::JWK#jwk_ec_to_pem` but operates directly
      # on the raw parsed JSON (the JWK struct requires `kid`, which DPoP
      # proofs do not carry — the binding is by thumbprint, not `kid`).
      private def self.jwk_to_ec_pem(jwk : Hash(String, JSON::Any)) : String
        x_b64 = jwk["x"]?.try(&.as_s?)
        y_b64 = jwk["y"]?.try(&.as_s?)
        raise Error.new("invalid_dpop_proof", "DPoP jwk missing x/y coordinates") unless x_b64 && y_b64

        x_bytes = Base64.decode(x_b64)
        y_bytes = Base64.decode(y_b64)

        # Uncompressed point: 0x04 || x || y
        point = Bytes.new(1 + x_bytes.size + y_bytes.size)
        point[0] = 0x04_u8
        x_bytes.copy_to(point + 1)
        y_bytes.copy_to(point + 1 + x_bytes.size)

        # SubjectPublicKeyInfo DER for id-ecPublicKey + prime256v1.
        der = build_ec_public_key_der(point)
        pem_encode_public_key(der)
      end

      # SubjectPublicKeyInfo DER for EC P-256. OIDs are fixed:
      # id-ecPublicKey = 1.2.840.10045.2.1
      # prime256v1     = 1.2.840.10045.3.1.7
      EC_PUBLIC_KEY_OID = Bytes[0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
      P256_CURVE_OID    = Bytes[0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]

      private def self.build_ec_public_key_der(point : Bytes) : Bytes
        alg_id_content = Bytes.new(EC_PUBLIC_KEY_OID.size + P256_CURVE_OID.size)
        EC_PUBLIC_KEY_OID.copy_to(alg_id_content)
        P256_CURVE_OID.copy_to(alg_id_content + EC_PUBLIC_KEY_OID.size)
        alg_id = encode_der_sequence(alg_id_content)

        bit_string_content = Bytes.new(1 + point.size)
        bit_string_content[0] = 0x00_u8
        point.copy_to(bit_string_content + 1)
        bit_string = encode_der_bitstring(bit_string_content)

        spki_content = Bytes.new(alg_id.size + bit_string.size)
        alg_id.copy_to(spki_content)
        bit_string.copy_to(spki_content + alg_id.size)
        encode_der_sequence(spki_content)
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

      # Extracts a string claim, raising `invalid_claim` when missing or
      # non-string. Keeps callers free of nil-checks.
      private def self.string_claim(payload : Hash(String, JSON::Any), name : String) : String
        value = payload[name]?
        case value
        when JSON::Any
          str = value.as_s?
          raise Error.new("invalid_claim", "DPoP '#{name}' must be a string") unless str
          str
        else
          raise Error.new("invalid_claim", "DPoP '#{name}' is missing")
        end
      rescue TypeCastError
        raise Error.new("invalid_claim", "DPoP '#{name}' must be a string")
      end

      # Extracts an integer claim. The shard decodes JSON numbers as `Int64`
      # inside `JSON::Any` — any other shape is rejected.
      private def self.int_claim(payload : Hash(String, JSON::Any), name : String) : Int64
        value = payload[name]?
        unless value
          raise Error.new("invalid_claim", "DPoP '#{name}' is missing")
        end
        case v = value.raw
        when Int64 then v
        when Int32 then v.to_i64
        else
          raise Error.new("invalid_claim", "DPoP '#{name}' must be an integer")
        end
      end

      # Computes `ath` per RFC 9449 §4.3 — base64url(SHA-256(access_token))
      # with no padding. Exposed so `AuthHandler` does not hand-roll it.
      def self.compute_ath(access_token : String) : String
        digest = OpenSSL::Digest.new("SHA256")
        digest.update(access_token)
        Base64.urlsafe_encode(digest.final, padding: false)
      end
    end
  end
end
