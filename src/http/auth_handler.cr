# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../iam/jwt"
require "../iam/token_emitter"
require "../iam/helpers"
require "../iam/roles"
require "../oauth/dpop"
require "../oauth/replay_cache"
require "../rbac/auth_context"
require "../rbac/active_role"
require "../rbac/grant_resolver"
require "../rbac/app_scope"
require "../mutation/client"
require "../util/crypto"
require "../mcp"

module Facet
  module HTTP
    # Kemal handler that extracts the JWT access token from the request,
    # validates it, loads the active role, and builds an `RBAC::AuthContext`
    # that is injected into `env` for downstream route handlers.
    #
    # ## Public routes (no auth required)
    #
    # These routes pass through without authentication:
    # - POST /Api/iam/login
    # - POST /Api/iam/challenge
    # - POST /Api/iam/refresh
    # - POST /Api/iam/change-password (bootstraps must_change_pw before a session exists)
    # - POST /Api/iam/password-reset/request (anti-enumeration, no auth)
    # - POST /Api/iam/password-reset/confirm (token-gated, no session)
    # - GET /Healthcheck (liveness + dependency probe for dev.sh / orchestration)
    # - POST /A/upload/:uid (one-time signed upload capability — the URL
    #   signature is the only credential; a presented token is ignored)
    #
    # ## Cookie vs Bearer
    #
    # The handler checks `auth_token` cookie first, then `Authorization: Bearer <token>`.
    #
    # ## Missing credentials (anonymous fallback)
    #
    # A protected route that receives NO credential does not answer 401
    # right away. The handler loads the seeded `iam.Roles.anonymous` role
    # and pins an anonymous `AuthContext` (the reserved `"anonymous"`
    # identity carrying that role's permissions — the seed grants read on
    # `core.Currency`). The request then runs through the standard RBAC
    # enforcers: the anonymous role's grants decide what is readable. When
    # the role projection does not exist (or is deleted), the handler
    # answers 401 — fail closed.
    #
    # ## On failure
    #
    # - A presented but invalid token on a protected route → 401 JSON
    #   error. A broken credential never downgrades to the anonymous
    #   principal — only the complete absence of a credential does.
    # - Valid token but role not found → 401 JSON error (fail closed).
    class AuthHandler < Kemal::Handler
      # Routes that do not require authentication.
      PUBLIC_ROUTES = {
        "GET" => {
          "/Healthcheck" => true,
          # Liveness probe — answers while the process is alive, no
          # dependency checks (readiness is `/Healthcheck` itself).
          "/Healthcheck/live" => true,
          # Prometheus scrape endpoint. Unauthenticated by decision: the
          # dev Caddyfile does not proxy it, so it is reachable only on
          # the backend origin of the private network.
          "/metrics"                                => true,
          "/.well-known/oauth-authorization-server" => true,
          # The login page fetches the SSO button list before any session
          # exists. Display names only — issuer / client data stays inside.
          "/Api/iam/oidc/providers" => true,
          # The authorize GET reads the browser session itself (cookie or
          # Bearer) and redirects to the frontend login when it is missing —
          # a bare 401 here would dead-end the browser leg of the OAuth flow.
          "/OAuth/authorize" => true,
          # Client metadata for first-party CLI clients. The CLI holds no
          # session before it starts the PKCE flow — this lookup is how it
          # resolves its `client_id`. Active apps only.
          "/OAuth/client-info" => true,
          # Caddy On-Demand TLS ask endpoint. Caddy calls it before it
          # issues a certificate for an unknown SNI name — it holds no
          # session, and the check must run before any certificate
          # exists. See `App::HostAsk`.
          "/Edge/HostAsk" => true,
        },
        "POST" => {
          "/Api/iam/login"     => true,
          "/Api/iam/challenge" => true,
          # Enroll-at-login (`always` enforcement): the caller holds no
          # session yet — the one-shot enroll token is the authorization.
          "/Api/iam/mfa/enroll/verify"      => true,
          "/Api/iam/refresh"                => true,
          "/Api/iam/change-password"        => true,
          "/Api/iam/password-reset/request" => true,
          "/Api/iam/password-reset/confirm" => true,
          # The token endpoint is PKCE-protected; it carries its own code
          # verifier + redirect_uri binding. No session required.
          "/OAuth/token" => true,
          # RFC 7591 dynamic client registration for MCP clients. The client
          # holds no session before this call — that is the point of the
          # endpoint. Rate limited per IP; see `OAuth::Register`.
          "/OAuth/register" => true,
          # Same as the GET: the route reads the session itself and bounces
          # to the login page when it is missing.
          "/OAuth/authorize" => true,
        },
      }

      # Disable auth handling (used in test mode where requests come
      # without JWT tokens and AuthContext.system is used instead).
      class_property? enabled : Bool = true

      # Token transport scheme value used by the WebSocket route when the
      # credential rides the `Sec-WebSocket-Protocol` handshake header (a
      # browser cannot set `Authorization` on a WebSocket upgrade and the
      # session cookie does not travel cross-site). Only `typ: "app"` JWTs
      # are accepted on that transport — see `auth_context_from_token`.
      WS_SUBPROTOCOL = "ws-subprotocol"

      # Qualified projection id of the role served to credential-less
      # requests (see `build_anonymous_auth_context`). The document is the
      # feature's only switch: grants on it are what an unauthenticated
      # caller may read, and deleting it re-disables the fallback (401).
      # Shared with the IAM session paths, which elect it for a roleless
      # account (B-120).
      ANONYMOUS_ROLE_ID = IAM::ANONYMOUS_ROLE_ID

      Log = ::Log.for("facet.http.auth")

      def call(env)
        # Skip all auth checks when disabled (test mode)
        if AuthHandler.enabled?
          method = env.request.method
          path = env.request.path

          # Surfaces that process their own credential (or need none) —
          # each rule's rationale lives on `auth_exempt?`.
          return call_next(env) if auth_exempt?(method, path)

          # Public routes pass through without auth
          if public_route?(method, path)
            return call_next(env)
          end

          # A missing credential falls back to the anonymous role (see
          # `build_anonymous_auth_context`). A presented-but-invalid token
          # answers 401 — a broken credential never downgrades to the
          # anonymous principal. The same applies to an Authorization
          # header that fails to parse (raw token without a scheme, an
          # unknown scheme like Basic, an empty bearer token): the caller
          # presented a credential, so answering with anonymous data — or
          # with the ambient session cookie's principal — would silently
          # ignore it. The cookie fallback serves a request that presents
          # NO explicit credential; a broken explicit one fails closed.
          raw_authorization = env.request.headers["Authorization"]?
          # A blank header value carries no credential — treat it as absent
          # so the cookie and anonymous fallbacks keep their documented
          # meaning (see `extract_token_and_scheme`).
          raw_authorization = nil if raw_authorization.try(&.blank?)
          token, scheme = AuthHandler.extract_token_and_scheme(env)
          auth_context = if token
                           AuthHandler.auth_context_from_token(env, token, scheme)
                         elsif raw_authorization
                           # Header present but unparseable — fail closed even
                           # when a session cookie rides beside it. The cookie
                           # never rescues a broken explicit credential: a
                           # machine request must not land in the audit log as
                           # the human's session.
                           nil
                         else
                           AuthHandler.build_anonymous_auth_context
                         end
          unless auth_context
            return unauthorized(env)
          end

          Fiber.current.auth_context = auth_context
        end

        call_next(env)
      end

      # Requests that bypass auth processing entirely — `call_next` runs
      # without a pinned auth context. Four surfaces, each authorized
      # elsewhere or public by contract:
      #
      # - GET /.well-known/* — discovery documents are unauthenticated by
      #   contract. The RFC 9728 protected-resource metadata carries a
      #   per-resource path suffix (/.well-known/oauth-protected-resource/<path>),
      #   so the whole well-known prefix is public rather than an
      #   exact-path entry.
      # - GET /auth/oidc/* — inbound OIDC browser redirects (start +
      #   callback) are public by contract. Both respond with a 302; the
      #   callback authorizes through the one-shot Redis state row, not
      #   through a session — an exact-match PUBLIC_ROUTES entry cannot
      #   express the parametric `:provider` path.
      # - MCP prefix — the MCP surface performs its own bearer verification
      #   in MCP::Dispatch, including the RFC 9728 401 handshake with the
      #   WWW-Authenticate resource_metadata pointer. The generic handler
      #   must not pre-empt it with a bare 401 or clients lose discovery.
      # - POST /A/upload/* — the artifact upload capability route carries
      #   its own credential: the one-time HMAC signature in the URL (see
      #   `Artifact::UploadGrants`). The route ignores the ambient auth
      #   context and rebuilds the principal from the consumed record, so
      #   a caller that naturally attaches its MCP bearer — an `aud` token
      #   REST must reject (see `auth_context_from_token`) — must not
      #   dead-end on the presented-token 401 below. The route answers
      #   415/403 itself for a bad body or a bad, expired, or used
      #   capability.
      private def auth_exempt?(method : String, path : String) : Bool
        return true if method == "GET" && path.starts_with?("/.well-known/")
        return true if method == "GET" && path.starts_with?("/auth/oidc/")
        return true if path.starts_with?("#{Facet::MCP::PATH_PREFIX}/")
        return true if method == "POST" && path.starts_with?("/A/upload/")
        false
      end

      # ── Transport-independent helpers (reusable from WS) ───────────────

      # Builds an RBAC::AuthContext from the request's auth_token cookie or
      # Authorization: Bearer/DPoP header. Returns nil if the token is missing
      # or invalid, or if the referenced role does not exist. All branch logic
      # lives in `auth_context_from_token` and is shared with the WebSocket
      # subprotocol transport.
      def self.auth_context_from_request(env) : RBAC::AuthContext?
        # Extract the token AND the scheme the client used, so the `cnf` check
        # can reject `Bearer`-presented bound tokens (`#use_dpop_proof`).
        token, scheme = extract_token_and_scheme(env)
        return nil unless token

        auth_context_from_token(env, token, scheme)
      end

      # Builds an AuthContext from a raw token plus the transport scheme that
      # carried it. `auth_context_from_request` is the cookie/header entry
      # point; the WebSocket route calls this directly when the credential
      # rides the `Sec-WebSocket-Protocol` handshake header (scheme
      # `WS_SUBPROTOCOL`) — a browser cannot set `Authorization` on an
      # upgrade, and the `auth_token` cookie does not travel cross-site.
      #
      # Branches on the JWT `typ` claim:
      # - "access" (existing browser-session token) → authenticated. Never
      #   DPoP-bound — `cnf` is absent so no proof check runs.
      # - "app" (app token) → loads the `iam.Roles` projection by
      #   `role`, the `app.App` projection by `app`, verifies the app is
      #   `active`, resolves the grant via `GrantResolver.resolve`, and
      #   constructs `AuthContext.app_scoped`. Fail-closed on missing role,
      #   missing/inactive app, or unresolvable grant.
      #
      # The WebSocket subprotocol transport is app-token-only: a static API
      # key never rides a URL-adjacent header, and the browser SDK has no use
      # for the other token kinds. Preview and access tokens presented on
      # that transport are rejected outright.
      #
      # An `aud`-bearing token is rejected outright (see inside the method).
      #
      # DPoP: when the decoded payload carries `cnf.jkt`, the
      # request is sender-constrained. A `DPoP` header is required, the
      # proof's `jkt` must match `cnf.jkt` (constant-time), the `htm`/`htu`/
      # `iat`/`jti` claims must verify, and `ath` must equal
      # base64url(SHA-256(access_token)). A bound token presented under the
      # `Bearer` scheme is rejected (downgrade guard). A bound token on the
      # WebSocket subprotocol transport is rejected too — the handshake
      # cannot carry a proof, so there is nothing to verify against.
      # An unbound token carries no proof contract at all; presenting it
      # under the `DPoP` scheme names a credential type that does not exist
      # for that token — see `dpop_unbound_or_verified?` (B-338).
      def self.auth_context_from_token(
        env,
        token : String,
        scheme : String?,
      ) : RBAC::AuthContext?
        if IAM::ApiKey.token?(token)
          return api_key_context_for_transport(scheme, token)
        end

        decoded = IAM::JWT.decode(token, IAM::TokenEmitter.keys) rescue nil
        return nil unless decoded

        payload = decoded.payload

        if aud = payload["aud"]?.try(&.as_s?)
          Log.warn { "REST rejected an aud-bearing token (aud=#{aud}) — MCP tokens must use /Api/_mcp/:role_slug" }
          return nil
        end

        return nil unless subprotocol_transport_allowed?(scheme, payload)

        account_id = payload["sub"]?.try(&.as_s)
        role_name = payload["role"]?.try(&.as_s)
        return nil unless account_id && role_name

        return nil unless dpop_unbound_or_verified?(env, payload, token, scheme)

        typ = payload["typ"]?.try(&.as_s) || IAM::JWT::ACCESS_TOKEN_TYP
        case typ
        when IAM::JWT::APP_TOKEN_TYP
          build_app_auth_context(account_id, role_name, payload)
        when IAM::JWT::PREVIEW_TOKEN_TYP
          build_preview_auth_context(account_id, payload)
        else
          build_auth_context(account_id, role_name)
        end
      end

      # Dispatches a static API key for the transport it arrived on. The
      # WebSocket subprotocol handshake never accepts one: the header is
      # line-logged by proxies, and a long-lived key must not ride a request
      # line the way a short-TTL JWT may. Every failure is nil — no detail
      # about which check failed (anti-enumeration).
      private def self.api_key_context_for_transport(scheme : String?, token : String) : RBAC::AuthContext?
        if scheme == WS_SUBPROTOCOL
          Log.warn { "WS subprotocol rejected a static API key" }
          return nil
        end

        build_api_key_auth_context(token)
      end

      # Transport gate for a decoded JWT: the WebSocket subprotocol handshake
      # is pinned to app tokens. A static key never reaches here, and the
      # browser-session/preview kinds are rejected with the transport reason.
      # Non-WS schemes pass through unchanged.
      private def self.subprotocol_transport_allowed?(scheme : String?, payload : Hash(String, JSON::Any)) : Bool
        return true unless scheme == WS_SUBPROTOCOL

        typ = payload["typ"]?.try(&.as_s)
        unless typ == IAM::JWT::APP_TOKEN_TYP
          Log.warn { "WS subprotocol rejected a typ=#{typ ? typ : "(missing)"} token" }
          return false
        end
        true
      end

      # DPoP gate: an unbound token passes without a proof, but only under
      # its real `Bearer` scheme (or the cookie / subprotocol transports).
      # Under the `DPoP` scheme an unbound token is a client-side scheme
      # mismatch — the token is a bearer token, so the DPoP scheme carries
      # no meaning and the gate answers 401 with a `WWW-Authenticate: Bearer`
      # challenge (B-338, strict option). A `cnf`-bound token needs a
      # verified proof on the `DPoP` scheme. Cookie- and subprotocol-
      # transported tokens cannot carry a proof, so bound tokens fail closed
      # on those transports (see `verify_dpop_for_payload?`).
      private def self.dpop_unbound_or_verified?(env, payload, token, scheme) : Bool
        cnf = payload["cnf"]?.try(&.as_h?)
        jkt = cnf ? cnf["jkt"]?.try(&.as_s?) : nil

        unless cnf && jkt
          # Strict scheme gate: an unbound token is a bearer token, so the
          # DPoP scheme carries no meaning here. Challenge with the Bearer
          # scheme the client actually holds.
          if scheme == "dpop"
            env.response.headers["WWW-Authenticate"] = "Bearer"
            Log.warn { "DPoP scheme presented an unbound token — challenged with Bearer" }
            return false
          end

          return true
        end

        verify_dpop_for_payload?(env, payload, token, jkt, scheme)
      end

      # Extracts the token from cookie or Authorization header. Returns the
      # token string and the scheme used (`"Bearer"`, `"DPoP"`, or `"cookie"`
      # when the cookie supplied the token). Header parsing delegates to
      # `Helpers.parse_authorization`.
      #
      # Precedence: the Authorization header wins whenever it parses. A
      # caller that explicitly sends credentials must never be shadowed by a
      # ambient cookie — a DPoP-bound token presented beside the human's
      # session cookie would otherwise authenticate as the human (cookie),
      # silently bypassing the sender-constraint (fixed by making the header
      # authoritative). A Bearer-presented bound token still fails closed:
      # the DPoP gate rejects any bound token whose scheme is not `DPoP`.
      #
      # A non-blank header that fails to parse (empty bearer token, raw
      # token without a scheme, an unknown scheme) yields NO token — the
      # caller fails closed with 401 instead of falling back to the cookie.
      # A blank header value carries no credential and is treated as
      # absent, so the cookie and anonymous fallbacks keep their meaning.
      def self.extract_token_and_scheme(env) : {String?, String?}
        raw_header = env.request.headers["Authorization"]?
        if raw_header && !raw_header.blank?
          if parsed = Helpers.parse_authorization(raw_header, ["Bearer", "DPoP"])
            return {parsed[0], parsed[1]}
          end

          # An explicit credential that fails to parse never downgrades to
          # the ambient cookie — a machine request must not inherit the
          # human's session (see the anti-downgrade rule in `#call`).
          return {nil, nil}
        end

        cookie_value = env.request.cookies["auth_token"]?.try(&.value)
        return {cookie_value, "cookie"} if cookie_value

        {nil, nil}
      end

      # Backward-compatible extractor — returns just the token. Older callers
      # (e.g. WebSocket subscription resolver) do not need the scheme.
      def self.extract_token(env) : String?
        token, _ = extract_token_and_scheme(env)
        token
      end

      # ── Private ──────────────────────────────────────────────────────

      private def public_route?(method : String, path : String) : Bool
        route_map = PUBLIC_ROUTES[method]?
        return true if route_map && route_map.has_key?(path)
        false
      end

      # Verifies a DPoP proof on a `cnf`-bearing access-token request.
      # Returns true on success, false on any failure (so the caller returns
      # 401). Fail-closed: a missing proof, mismatched key, mismatched `ath`,
      # or replayed `jti` all fail here.
      #
      # § Bearer downgrade guard: a `cnf`-bearing token MUST be presented
      # under the `DPoP` scheme. A `Bearer`-presented bound token is rejected
      # — the downgrade path is closed by construction. The scheme is `nil`
      # when the cookie supplied the token; that case also fails (cookies
      # cannot transport a DPoP proof).
      private def self.verify_dpop_for_payload?(
        env,
        payload : Hash(String, JSON::Any),
        token : String,
        bound_jkt : String,
        scheme : String?,
      ) : Bool
        unless scheme == "dpop"
          # Downgrade attempt or cookie-transported bound token — reject.
          return false
        end

        proof = env.request.headers["DPoP"]?
        return false unless proof

        # `htu` is the public origin + request path (no query, no fragment).
        # Constructed from `Config.host` — never from forward headers (see
        # `OAuth::HTU.reconstruct` for the rationale).
        htu = OAuth::HTU.reconstruct(env.request.path)
        ath = OAuth::DPoP.compute_ath(token)

        # Each refusal answers the same generic 401, but the log carries the
        # reason: a failing client can read its own server log and correct the
        # proof. The response body never distinguishes the causes.
        verified = begin
          OAuth::DPoP.verify(proof, htm: env.request.method, htu: htu, ath: ath)
        rescue ex : OAuth::DPoP::Error
          Log.warn { "DPoP proof refused (#{ex.error_code}): #{ex.message}" }
          return false
        rescue
          Log.warn { "DPoP proof refused: the proof is malformed" }
          return false
        end

        # Constant-time comparison of the proof's thumbprint with the bound
        # thumbprint. Avoids short-circuit timing leaks.
        unless Util::Crypto.constant_time_eq?(verified.jkt, bound_jkt)
          Log.warn { "DPoP proof refused (invalid_dpop_proof): the proof's jkt does not match the token's cnf.jkt" }
          return false
        end

        # Replay defence — scoped by `jkt` so two clients picking the same
        # `jti` cannot evict each other's cache entry.
        unless OAuth::ReplayCache.check_and_mark(verified.jkt, verified.jti)
          Log.warn { "DPoP proof refused (invalid_dpop_proof): the jti was already used" }
          return false
        end

        true
      end

      # Builds an AuthContext from a static API key (`Bearer fct_…`).
      # `IAM::ApiKey.verify` runs the full liveness pipeline (hash lookup,
      # revocation, expiry, account status, role assignment, role existence)
      # and returns the row id plus the live role content — never the secret.
      #
      # Two shapes result:
      # - A plain self-service key yields the same `authenticated`-equivalent
      #   principal a browser session gets, plus the `api_key_id` provenance
      #   tag for mutation attribution.
      # - An app-owned key (`app_id` on the row) yields an `app_scoped`
      #   principal: the service account's reach is grant ∩ pinned role — the
      #   exact sequence of `build_app_auth_context` (`role_usable?`, `resolve`,
      #   fail-closed on empty). The `api_key_id` provenance stays ON the
      #   context: an app-owned key is the `app_api_key` channel, so audit
      #   metadata carries both the app id and the key id.
      # Every failure returns nil → 401, with no detail about which check
      # failed (anti-enumeration).
      private def self.build_api_key_auth_context(token : String) : RBAC::AuthContext?
        verified = Database.with_db(:read_only) do |db|
          IAM::ApiKey.verify(db, token)
        end
        return nil unless verified

        # Attach key provenance to the current span so an admin can answer
        # "which key served this request" from traces alone. Mirrors the
        # app-token attribution pattern.
        if span = OpenTelemetry.current_span
          span["auth.type"] = "api_key"
          span["api_key"] = verified.key_id
        end

        active_role = RBAC::ActiveRole.from_projection_content(verified.role_content)

        if app_id = verified.app_id
          app_content = verified.app_content
          return nil unless app_content

          if span = OpenTelemetry.current_span
            span["app"] = app_id
          end

          app_scope = RBAC::AppScope.from_content(app_id, app_content)
          unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
            # The 401 body names nothing (anti-enumeration: a leaked key must
            # learn nothing about role state) — the server-side log is the
            # operator's signal. Mirrors the OAuth refresh path, which names
            # its reason in the `refresh_failed` login event.
            missing = RBAC::GrantResolver.missing_required_actions(app_scope, active_role)
            Log.warn do
              "app-owned API key refused: role #{verified.role_id} is missing required grant " \
              "actions #{missing.join(", ")} (app #{app_id}, key #{verified.key_id})"
            end
            if span = OpenTelemetry.current_span
              span["auth.refused"] = "role_unusable"
              span["auth.missing_actions"] = missing.join(",")
            end
            return nil
          end
          effective = RBAC::GrantResolver.resolve(app_scope, active_role)
          if effective.empty?
            Log.warn do
              "app-owned API key refused: grant intersection with role #{verified.role_id} " \
              "is empty (app #{app_id}, key #{verified.key_id})"
            end
            if span = OpenTelemetry.current_span
              span["auth.refused"] = "empty_scope"
            end
            return nil
          end

          return RBAC::AuthContext.app_scoped(verified.account_id, active_role, effective, app_id, verified.key_id)
        end

        RBAC::AuthContext.api_key(verified.account_id, active_role, verified.key_id)
      rescue ArgumentError
        nil
      end

      # Builds an AuthContext for the given user and role.
      private def self.build_auth_context(account_id : String, role_name : String) : RBAC::AuthContext?
        Database.with_db(:read_only) do |db|
          role_content = IAM::Helpers.find_role_content(db, role_name)
          return nil unless role_content

          active_role = RBAC::ActiveRole.from_projection_content(role_content)
          RBAC::AuthContext.authenticated(account_id, active_role)
        end
      rescue ArgumentError
        nil
      end

      # Builds the anonymous context for a credential-less request: loads
      # the seeded `iam.Roles.anonymous` role and wraps it in the reserved
      # `"anonymous"` identity (see `RBAC::AuthContext.anonymous`).
      # Returns nil when the role projection is missing or deleted — the
      # caller answers 401 (fail closed).
      #
      # The lookup runs on every unauthenticated request (one indexed read
      # on `projections`), so role edits take effect on the next request.
      # Public like the other transport-independent helpers — the instance
      # `#call` cannot resolve a private class method by receiver.
      def self.build_anonymous_auth_context : RBAC::AuthContext?
        role_content = Database.with_db(:read_only) do |db|
          IAM::Helpers.find_role_content(db, ANONYMOUS_ROLE_ID)
        end
        return nil unless role_content

        if span = OpenTelemetry.current_span
          span["auth.type"] = "anonymous"
        end

        active_role = RBAC::ActiveRole.from_projection_content(role_content)
        RBAC::AuthContext.anonymous(active_role)
      rescue ArgumentError
        nil
      end

      # Builds an app-scoped AuthContext (`typ: "app"` JWT).
      # Loads the role, the app, verifies the app is `active`, resolves
      # the grant, and constructs `AuthContext.app_scoped`. Fail-closed on
      # missing role/app, non-active app, or empty effective scope.
      #
      # Attaches the `app`, `role`, and `sid` claims to the current
      # OpenTelemetry span so an admin can answer "what has this app done, on
      # whose behalf, under which role" from traces alone.
      private def self.build_app_auth_context(
        account_id : String,
        role_name : String,
        payload : Hash(String, JSON::Any),
      ) : RBAC::AuthContext?
        app_id = payload["app"]?.try(&.as_s)
        return nil unless app_id

        # Attach app attribution to the current span. The root
        # request span is already open at this point; `current_span` is nil
        # only when telemetry is fully disabled (NullExporter still creates
        # spans, so this is the no-config case).
        if span = OpenTelemetry.current_span
          span["app"] = app_id
          span["role"] = role_name
          payload["sid"]?.try { |sid| span["sid"] = sid.as_s }
        end

        Database.with_db(:read_only) do |db|
          role_content = IAM::Helpers.find_role_content(db, role_name)
          return nil unless role_content

          # Re-load the app and gate on status. A disabled app's token must
          # be rejected immediately — defense in depth alongside the
          # fail-closed empty-scope denial.
          app_row = db.query_one?(
            "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
            app_id,
            as: JSON::Any,
          )
          return nil unless app_row

          status = app_row.as_h["status"]?.try(&.as_s?) || "draft"
          return nil unless status == "active"

          active_role = RBAC::ActiveRole.from_projection_content(role_content)
          app_scope = RBAC::AppScope.from_content(app_id, app_row)

          # role_usable? gates against required actions; resolve yields the
          # ceiling the token may attempt. Both must hold — an unusable role
          # must never produce a token, even if the grant would otherwise
          # resolve to a non-empty scope (it cannot if the role lacks the
          # required actions, but we double-check for defense in depth).
          return nil unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
          effective = RBAC::GrantResolver.resolve(app_scope, active_role)
          if effective.empty?
            # The 401 body names nothing (anti-enumeration) — the log and
            # the span are the operator's signal. Mirrors the app-key path.
            Log.warn do
              "app token refused: grant intersection with role #{role_name} " \
              "is empty (app #{app_id})"
            end
            if span = OpenTelemetry.current_span
              span["auth.refused"] = "empty_scope"
            end
            return nil
          end

          RBAC::AuthContext.app_scoped(account_id, active_role, effective, app_id)
        end
      rescue ArgumentError
        nil
      end

      # Builds a preview-mode capability AuthContext (preview-session token,
      # `typ: "preview"`). Loads the named `preview_domain` from the token,
      # verifies the `core.Domain` projection row exists and still has
      # `draft = true` (defense-in-depth — a published-then-dropped draft's
      # token must stop working immediately), and constructs
      # `AuthContext.preview`. Fail-closed on missing draft, draft flag
      # false, or a deleted projection.
      #
      # `role_name` is retained on the payload purely for OpenTelemetry
      # attribution; the preview principal does not consult the role's
      # permissions (the capability was issued after the caller's real
      # identity proved `read`/`create core.DocType` on the draft).
      private def self.build_preview_auth_context(
        account_id : String,
        payload : Hash(String, JSON::Any),
      ) : RBAC::AuthContext?
        preview_domain = payload["preview_domain"]?.try(&.as_s)
        return nil unless preview_domain

        # Attach the preview session id to the current span so an admin can
        # answer "who previewed this draft, under which role" from traces
        # alone. Mirrors the app-token attribution pattern.
        if span = OpenTelemetry.current_span
          span["preview"] = preview_domain
          payload["role"]?.try { |r| span["role"] = r.as_s }
          payload["sid"]?.try { |sid| span["sid"] = sid.as_s }
        end

        Database.with_db(:read_only) do |db|
          row = db.query_one?(
            "SELECT content FROM projections " \
            "WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 " \
            "AND deleted_at IS NULL",
            preview_domain,
            as: JSON::Any,
          )
          return nil unless row

          content_h = row.as_h?
          return nil unless content_h
          draft_flag = content_h["draft"]?.try(&.raw)
          return nil unless draft_flag == true

          RBAC::AuthContext.preview(account_id, preview_domain)
        end
      end

      private def unauthorized(env) : Nil
        env.response.status_code = 401
        env.response.content_type = "application/json"
        Helpers.no_store(env)
        env.response.print({error: "Authentication required"}.to_json)
      end
    end
  end
end
