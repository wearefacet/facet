# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "openssl"
require "jwt"
require "json"
require "base64"
require "../util/script_helpers"

module Facet
  module IAM
    # ES256 JWT access token sign/verify.
    #
    # Wraps the `crystal-community/jwt` shard with **mandatory alg pinning**
    # to ES256. The token header is never trusted to select the algorithm
    # (prevents alg:none and algorithm-confusion attacks).
    #
    # ## Security properties
    #
    # - `alg` is always pinned to `ES256` on decode — the JWT header is
    #   verified before any signature check.
    # - Keys are identified by `kid` in the JWT header for rotation.
    # - The `openssl_ext` shard (transitive dep) provides ECDSA operations
    #   that stdlib alone doesn't expose.
    module JWT
      ES256_ALG         = ::JWT::Algorithm::ES256
      ACCESS_TOKEN_TYP  = "access"
      APP_TOKEN_TYP     = "app"
      PREVIEW_TOKEN_TYP = "preview"
      ACCESS_TOKEN_EXP  = -> { Facet::Config.instance.iam.jwt.access_token_ttl }

      # A parsed JWT with verified payload.
      record Decoded,
        payload : Hash(String, JSON::Any),
        header : Hash(String, JSON::Any),
        kid : String?

      # ── Signing ──────────────────────────────────────────────────────

      # Signs a payload hash into a JWT access token using the PEM-encoded
      # EC private key.
      def self.sign(
        payload : Hash(String, JSON::Any),
        pem_key : String,
        kid : String = "facet-1",
      ) : String
        # Convert payload to plain hash (JSON::Any.raw)
        raw_payload = payload.transform_values(&.raw)

        ::JWT.encode(raw_payload, pem_key, ES256_ALG, kid: kid)
      end

      # ── Verification ─────────────────────────────────────────────────

      # Decodes and verifies a JWT access token.
      #
      # Accepts a hash of kid → PEM key. The token's `kid` header selects
      # the key. If `kid` is missing or unknown, each key is tried in order
      # (backward compat for tokens issued before multi-key support).
      #
      # Returns `Decoded` on success, or raises `Error` on failure.
      # **Always pins the algorithm to ES256** — the token's `alg` header
      # is never trusted.
      def self.decode(token : String, keys : Hash(String, String)) : Decoded
        # Step 1: Read the header without verification to check alg and kid
        raw_header_json = Base64.decode_string(token.split('.')[0])
        raw_header = JSON.parse(raw_header_json).as_h
        alg = raw_header["alg"]?.try(&.as_s)

        # Step 2: Pin the algorithm — reject anything that isn't ES256
        unless alg == "ES256"
          raise Error.new("JWT algorithm mismatch: expected ES256, got #{alg}")
        end

        kid = raw_header["kid"]?.try(&.as_s)

        # Step 3: Select the key by kid, or try all keys for backward compat
        candidate_keys = if kid && keys.has_key?(kid)
                           {keys[kid]}
                         else
                           keys.values
                         end

        if candidate_keys.empty?
          raise Error.new("JWT verification failed: no matching key found (kid=#{kid || "missing"})")
        end

        last_error = nil
        candidate_keys.each do |pem_key|
          begin
            payload_raw, header_raw = ::JWT.decode(
              token,
              pem_key,
              ES256_ALG,
              verify: true,
              validate: true,
            )
            # Convert to JSON::Any hashes
            payload = payload_raw.as_h
            header = header_raw
            return Decoded.new(payload: payload, header: header, kid: kid)
          rescue error
            last_error = error
          end
        end

        raise Error.new("JWT verification failed: #{last_error.as(Exception).message}")
      end

      # ── Token building helper ────────────────────────────────────────

      # Builds the base claims shared by every token type: subject, session
      # id, role, a fresh `jti`, the token `typ`, and the issued-at/expiry
      # timestamps. Returns the claims hash and the `exp` timestamp separately
      # so callers can add type-specific claims and surface `expires_at` in
      # the response body without re-parsing the JWT.
      private def self.base_claims(
        account_id : String,
        sid : String,
        role : String,
        typ : String,
      ) : {Hash(String, JSON::Any), Int64}
        now = Time.utc.to_unix
        exp = now + ACCESS_TOKEN_EXP.call
        claims = {
          "sub"  => JSON::Any.new(account_id),
          "sid"  => JSON::Any.new(sid),
          "role" => JSON::Any.new(role),
          "jti"  => JSON::Any.new(Util::ScriptHelpers.ulid),
          "typ"  => JSON::Any.new(typ),
          "iat"  => JSON::Any.new(now),
          "exp"  => JSON::Any.new(exp),
        }
        {claims, exp}
      end

      # Builds the access token payload with standard claims.
      #
      # `aud` (RFC 8707 resource indicator, optional) pins the token to one
      # resource identifier. Minted on the MCP authorize path; absent on
      # ordinary browser-session tokens until the transitional rollout
      # (decision 9.5) flips the REST path to require it.
      #
      # Returns the payload hash and the `exp` timestamp separately so
      # callers (TokenEmitter) can include `expires_at` in the response body
      # without re-parsing the JWT.
      def self.build_access_payload(
        account_id : String,
        session_id : String,
        role : String,
        aud : String? = nil,
      ) : {Hash(String, JSON::Any), Int64}
        payload, exp = base_claims(account_id, session_id, role, ACCESS_TOKEN_TYP)
        payload["aud"] = JSON::Any.new(aud) if aud
        {payload, exp}
      end

      # Builds the app-token payload. Carries the same base claims as an
      # access token plus `app` (the `app.App` projection id) and `typ: "app"`
      # so `AuthHandler` can branch on it. The `sid` is a fresh opaque id — it
      # is **not** a `RedisSession` session id; app sessions are independent
      # from the browser session that authorized them (see App System brief →
      # Concepts and Vocabulary).
      #
      # `cnf_jkt` (RFC 7800 / RFC 7638 JWK thumbprint, optional) sender-
      # constrains the token: when present, `AuthHandler` requires a DPoP
      # proof whose embedded JWK has the same thumbprint.
      def self.build_app_payload(
        account_id : String,
        sid : String,
        role : String,
        app_id : String,
        cnf_jkt : String? = nil,
      ) : {Hash(String, JSON::Any), Int64}
        payload, exp = base_claims(account_id, sid, role, APP_TOKEN_TYP)
        payload["app"] = JSON::Any.new(app_id)
        if jkt = cnf_jkt
          # RFC 7800 confirmation: binds the token to the holder of the
          # DPoP private key whose thumbprint is `cnf.jkt`. `AuthHandler`
          # enforces proof presence and key match on receipt; absence of
          # `cnf` when no proof was presented at issuance leaves the token
          # a plain bearer (downgrade never happens once a token is bound:
          # `cnf` cannot be stripped without invalidating the signature).
          payload["cnf"] = JSON::Any.new({"jkt" => JSON::Any.new(jkt)})
        end
        {payload, exp}
      end

      # Builds a preview-mode capability token payload. Carries the caller's
      # real `sub` (so mutations stay attributed to them), an opaque `sid`
      # (NOT an `iam.RedisSession` id — preview sessions are stateless and
      # die with the token's TTL), the `role` claim retained for OpenTelemetry
      # attribution only (the preview principal does not consult the role),
      # and `preview_domain` naming the draft domain the principal is bound
      # to. `typ` is `"preview"` so `AuthHandler` branches into the preview
      # context builder.
      #
      # The capability model: the caller proved at issuance time (against
      # their real identity, via the standard `read`/`create core.DocType`
      # permission) that they may edit the draft's doctype definitions; from
      # here the enforcers gate purely on `preview_domain`.
      def self.build_preview_payload(
        account_id : String,
        sid : String,
        role : String,
        preview_domain : String,
      ) : {Hash(String, JSON::Any), Int64}
        payload, exp = base_claims(account_id, sid, role, PREVIEW_TOKEN_TYP)
        payload["preview_domain"] = JSON::Any.new(preview_domain)
        {payload, exp}
      end

      # ── Key generation ──────────────────────────────────────────────

      # Generates a PEM-encoded ES256 (P-256) private key.
      # Uses the openssl_ext shard which patches OpenSSL::PKey::EC.
      def self.generate_key_pem : String
        key = OpenSSL::PKey::EC.generate("P-256")
        io = IO::Memory.new
        key.to_pem(io)
        io.rewind
        io.to_s
      end

      # ── Error type ───────────────────────────────────────────────────

      class Error < ::RuntimeError
        def initialize(message : String)
          super(message)
        end
      end
    end
  end
end
