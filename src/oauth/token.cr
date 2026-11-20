# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "openssl"
require "../database"
require "../mutation/client"
require "../iam/helpers"
require "../iam/jwt"
require "../iam/redis_session"
require "../iam/token_emitter"
require "../rbac/active_role"
require "../rbac/grant_resolver"
require "./code_store"
require "./authorize"
require "./dpop"
require "./endpoint_error"
require "./replay_cache"
require "../util/crypto"

module Facet
  module OAuth
    # Verifies PKCE, consumes the authorization code, and issues an ES256
    # app JWT. The endpoint is `POST /OAuth/token` (`grant_type=
    # authorization_code`).
    #
    # ## Security properties
    #
    # - **Code replay fails.** `CodeStore.consume` is an atomic Lua-driven
    #   read-then-delete. A second redemption returns `nil` → `invalid_grant`.
    # - **A failed DPoP proof does not consume the code.** The proof is
    #   verified before `CodeStore.consume`, so a client that presented a
    #   bad proof can retry the exchange with the same code and a corrected
    #   proof. The `client_id` / `redirect_uri` / PKCE checks keep their
    #   consume-on-failure order — a deliberate anti-phish measure.
    # - **Wrong verifier fails.** The stored `code_challenge` is the SHA-256
    #   of the original verifier (S256). The server recomputes the digest
    #   from the presented `code_verifier` and compares in constant time.
    # - **`redirect_uri` echoed.** `Token` re-validates the redirect_uri
    #   against the one bound to the code (must equal the value seen at
    #   authorize). Mismatch → `invalid_grant`.
    # - **App active.** The app document is re-read; non-`active` apps are
    #   rejected. Defense in depth — `Authorize` already gated on this, but
    #   an app could be disabled between authorize and token.
    # - **Role usable.** Grant resolution re-runs at the token endpoint
    #   too, mirroring `AuthHandler` on `typ: "app"` access. A disabled
    #   grant or rotated role between authorize and token yields an empty
    #   effective scope → `invalid_grant`.
    module Token
      # The token endpoint's error type. The shared `OAuth::EndpointError`
      # with a 400 default; the per-module name keeps the existing rescue
      # sites and specs working.
      class Error < EndpointError
      end

      # Raises `Token::Error` — NOT the shared base. The route rescues
      # `EndpointError` now, but a raise of the base class from this module
      # bypassed the old per-module rescues and surfaced as a 500 with the
      # message in the `error` slot; keeping the raise in the module's own
      # type keeps the failure inside the RFC 6749 §5.2 contract (B-24).
      private def self.require_present(value : String?, name : String) : String
        raise Error.new("invalid_request", "Missing '#{name}'", 400) if value.nil? || value.empty?
        value
      end

      # The successful token response, serializable as JSON. No `scope` member:
      # the authorization server advertises no scope vocabulary
      # (`scopes_supported: []`), so there is nothing to echo — the member is
      # omitted per RFC 6749 §5.1. A spec-compliant client (opencode, the MCP
      # SDK) zod-validates the body and rejects a non-string `scope`.
      record Issued,
        access_token : String,
        token_type : String,
        expires_in : Int32,
        refresh_token : String

      # Verifies PKCE + code, loads the role/app, resolves the grant, and
      # issues the app JWT. Raises `Error` on any failure path.
      #
      # `dpop_proof` (optional): a DPoP proof presented by the client
      # in the `DPoP` header. When present, the issued access token carries a
      # `cnf.jkt` claim (RFC 7800) bound to the proof's JWK thumbprint, the
      # session stores `dpop_jkt` so refreshes require a matching proof, and
      # `token_type` is `"DPoP"` instead of `"Bearer"`. When absent, the
      # issuance is a plain bearer token (backward-compatible). The proof
      # is verified **before** the authorization code is consumed (B-55):
      # a failed proof answers 400 and leaves the code available, so the
      # client can retry the same code with a corrected proof.
      #
      # `htu` is the reconstructed public token URL (`OAuth::HTU.reconstruct`) —
      # passed by the caller so the verifier stays free of Kemal coupling.
      #
      # `ath` is intentionally **never** verified here. RFC 9449 §7.1 — `ath`
      # is meaningful only when a proof accompanies an access token; the token
      # endpoint consumes an authorization code, not a token, so there is no
      # access token to hash. Verifying `ath` here makes the grant fail.
      def self.call(
        db : DB::Connection,
        grant_type : String,
        code : String?,
        redirect_uri : String?,
        code_verifier : String?,
        client_id : String?,
        dpop_proof : String? = nil,
        htu : String? = nil,
      ) : Issued
        if grant_type != "authorization_code"
          raise Error.new("unsupported_grant_type",
            "Only grant_type=authorization_code is handled by this path; refresh_token is dispatched at the route", 400)
        end
        code = require_present(code, "code")
        redirect_uri = require_present(redirect_uri, "redirect_uri")
        code_verifier = require_present(code_verifier, "code_verifier")
        client_id = require_present(client_id, "client_id")

        # The DPoP proof is verified before the code is consumed (B-55): a
        # failed proof must not consume the single-use code, so the client
        # can correct the proof and exchange the same code again. This is
        # also the only verification pass — the replay cache marks the proof
        # here, so the grant branches below thread the returned thumbprint
        # and must not verify again (a second pass fails as a replay).
        cnf_jkt, _token_type = verify_issuance_binding(dpop_proof, htu)

        record = CodeStore.consume(code)
        unless record
          raise Error.new("invalid_grant",
            "Authorization code is invalid, expired, or already used", 400)
        end

        # The code was bound to its issuance context. Re-check every field
        # the brief requires.
        unless record.client_id == client_id
          raise Error.new("invalid_grant", "client_id mismatch", 400)
        end
        unless record.redirect_uri == redirect_uri
          raise Error.new("invalid_grant", "redirect_uri mismatch", 400)
        end

        # PKCE: recompute S256(code_verifier) and compare in constant time.
        computed_challenge = pkce_s256_challenge(code_verifier)
        unless Util::Crypto.constant_time_eq?(computed_challenge, record.code_challenge)
          raise Error.new("invalid_grant", "PKCE verification failed", 400)
        end

        # RFC 8707 branch point: a code issued with a `resource` parameter
        # belongs to the MCP flow and never touches app machinery (decision
        # D5). The app branch follows unchanged below.
        if record.resource
          return call_mcp(db, record, cnf_jkt)
        end

        # Re-load the app and role. Both could have changed in the 60-second
        # window. The app must still be active; the role must still be usable
        # against the app's *current* grant set. `Authorize.load_app` raises
        # `Authorize::InvalidRequest` (e.g. redirect_uri mismatch, non-active
        # app, unknown client_id) — we translate it to `invalid_grant` so the
        # token endpoint's error contract stays uniform. The brief's token
        # acceptance list expects every failure path at the token endpoint to
        # surface as `invalid_grant`.
        begin
          app = Authorize.load_app(
            db,
            Authorize::Params.new(
              client_id: record.client_id,
              redirect_uri: record.redirect_uri,
              state: nil,
              code_challenge: record.code_challenge,
              scope: nil,
            ),
          )
        rescue ex : Authorize::InvalidRequest
          raise Error.new("invalid_grant", ex.message || "App authorization failed", 400)
        end

        role_content = IAM::Helpers.find_role_content(db, record.role_id)
        unless role_content
          raise Error.new("invalid_grant",
            "Role '#{record.role_id}' no longer exists", 400)
        end

        active_role = RBAC::ActiveRole.from_projection_content(role_content)
        app_scope = RBAC::AppScope.from_content(app.id,
          JSON.parse(%({"grants": #{Authorize.content_grants_or_empty(db, app.id)}})))

        unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
          raise Error.new("invalid_grant",
            "Role is no longer usable with this app", 400)
        end

        effective = RBAC::GrantResolver.resolve(app_scope, active_role)
        if effective.empty?
          # Defense in depth — role_usable? with required grants already
          # prevents this, but an all-optional grant resolving empty still
          # has no useful reach.
          raise Error.new("invalid_grant",
            "Effective scope is empty for this role/app", 400)
        end

        # A verifiable app session lives in Redis so the refresh
        # rotation + reuse-detection machinery (`IAM::Refresh` already uses it
        # for browser sessions) applies identically to apps. The session id
        # *is* the JWT `sid` claim — `OAuth::Refresh` re-traces this lookup on
        # every refresh, never on the access-token path (the access token stays
        # stateless and dies on its ≤15-min TTL).
        #
        # DPoP: the proof was verified before the code was consumed (B-55);
        # the resulting thumbprint binds the session and JWT. `ath` is not
        # verified — there is no access token at the token endpoint.
        session_id, refresh_id = IAM::RedisSession.create_app_session(
          account_id: record.account_id,
          active_role: record.role_id,
          app: app.id,
          client_id: client_id,
          dpop_jkt: cnf_jkt,
        )
        payload, _exp = IAM::JWT.build_app_payload(
          account_id: record.account_id,
          sid: session_id,
          role: record.role_id,
          app_id: app.id,
          cnf_jkt: cnf_jkt,
        )

        issue(session_id, refresh_id, payload, cnf_jkt)
      end

      # ── MCP branch ──────────────────────────────────────────────

      # Redeems an MCP-branch code. Skips `app.App` loading and `GrantResolver`
      # entirely; re-validates that the account still holds the pinned role, then
      # mints an access token carrying `aud` (= resource) + `role` and **no
      # `app` claim**. The session is browser-session-shaped — no `app` field.
      #
      # `cnf_jkt` is the DPoP thumbprint `call` verified before the code was
      # consumed (nil = plain bearer issuance) — threaded through so the proof
      # is never verified twice (the replay cache would reject a second pass).
      private def self.call_mcp(
        db : DB::Connection,
        record : CodeStore::Code,
        cnf_jkt : String?,
      ) : Issued
        resource = record.resource
        unless resource
          raise Error.new("invalid_grant", "Code is missing its resource binding", 400)
        end
        role_id = record.mcp_role || record.role_id

        # Defense in depth at the token endpoint: the account must still hold
        # the role (it was validated at authorize). No grant revalidation —
        # there are no grants.
        account = IAM::Helpers.find_account_by_id(db, record.account_id)
        raise Error.new("invalid_grant", "Account not found", 400) unless account
        unless account[:roles].includes?(role_id)
          raise Error.new("invalid_grant",
            "Role '#{role_id}' is no longer assigned to the account", 400)
        end
        role_content = IAM::Helpers.find_role_content(db, role_id)
        raise Error.new("invalid_grant",
          "Role '#{role_id}' no longer exists", 400) unless role_content

        session_id, refresh_id = IAM::RedisSession.create(
          account_id: record.account_id,
          active_role: role_id,
          dpop_jkt: cnf_jkt,
        )
        payload, _exp = IAM::JWT.build_access_payload(
          account_id: record.account_id,
          session_id: session_id,
          role: role_id,
          aud: resource,
        )

        issue(session_id, refresh_id, payload, cnf_jkt)
      end

      # ── Internals ────────────────────────────────────────────────────────

      # Verifies the DPoP proof presented at the token endpoint and returns
      # the `(cnf_jkt, token_type)` pair for the issued token: the thumbprint
      # binds the session and JWT, and `token_type` flips to `"DPoP"`. A nil
      # proof is a plain bearer issuance. Called exactly once, before
      # `CodeStore.consume` (B-55) so a failed proof does not consume the
      # code — the grant branches thread the returned thumbprint instead of
      # re-verifying, because a second verification of the same proof fails
      # the `(jkt, jti)` replay cache. The htu-not-provided failure is a
      # caller contract violation, so it surfaces as a 500.
      private def self.verify_issuance_binding(dpop_proof : String?, htu : String?) : {String?, String}
        cnf_jkt = nil
        token_type = "Bearer"
        if proof = dpop_proof
          expected_htu = htu || raise(Error.new("invalid_request",
            "DPoP proof presented but htu not provided by caller", 500))
          verified = OAuth::DPoP.verify_bound(proof, "POST", expected_htu, nil, "invalid_dpop_proof") do |code, message|
            Error.new(code, message, 400)
          end
          cnf_jkt = verified.jkt
          token_type = "DPoP"
        end
        {cnf_jkt, token_type}
      end

      # Signs the app JWT and assembles the `Issued` response — the shared
      # tail behind both grant branches. `cnf_jkt` selects the token type:
      # a bound session flips `token_type` to `DPoP`.
      private def self.issue(
        session_id : String,
        refresh_id : String,
        payload : Hash(String, JSON::Any),
        cnf_jkt : String?,
      ) : Issued
        access_token = IAM::JWT.sign(payload, IAM::TokenEmitter.signing_key, IAM::TokenEmitter.kid)
        Issued.new(
          access_token: access_token,
          token_type: cnf_jkt.nil? ? "Bearer" : "DPoP",
          expires_in: IAM::JWT::ACCESS_TOKEN_EXP.call.to_i32,
          refresh_token: "#{session_id}.#{refresh_id}",
        )
      end

      # S256 code challenge: `Base64URL(SHA-256(verifier))` with no padding,
      # as specified by RFC 7636 §4.2.
      private def self.pkce_s256_challenge(verifier : String) : String
        digest = OpenSSL::Digest.new("SHA256")
        digest.update(verifier)
        Base64.urlsafe_encode(digest.final, padding: false)
      end
    end

    # Serializes a resolved `EffectiveScope` to the informational JSON shape
    # the consent screen renders (`effective_scope` per usable role). The
    # shape is purely informational: the app (which is internal and trusted)
    # reads it to render affordances; it is never an enforcement input.
    # Enforcement re-resolves the grant from `app.App` in `AuthHandler` on
    # every request. The token response carries no scope member — see
    # `Token::Issued`.
    def self.serialize_scope(scope : RBAC::EffectiveScope) : JSON::Any
      entries : Array(JSON::Any) = scope.entries.map do |e|
        JSON::Any.new({
          "target"  => JSON::Any.new(e.target),
          "domain"  => JSON::Any.new(e.domain),
          "path"    => JSON::Any.new(e.path.map { |p| JSON::Any.new(p) }),
          "actions" => JSON::Any.new(e.actions.to_a.map { |a| JSON::Any.new(a) }),
        })
      end
      JSON::Any.new(entries)
    end
  end
end
