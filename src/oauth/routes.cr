# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "http"
require "../database"
require "../http/helpers"
require "../iam/helpers"
require "../iam/jwt"
require "./authorize"
require "./client_info"
require "./dpop"
require "./replay_cache"
require "./token"
require "./refresh"
require "./rate_limiter"
require "./discovery"
require "../util/client_ip"

module Facet
  module OAuth
    # HTTP routes for the Facet app authorization server.
    #
    # All endpoints live under `/OAuth/...`. This is **not** a general
    # OAuth provider — the endpoints serve Facet-registered applications
    # only. Discovery metadata at `/.well-known/oauth-authorization-server`
    # advertises this surface for off-the-shelf OAuth client libraries.
    module Routes
      # Renders the 429 body the two rate-limited endpoints share (the token
      # grant and dynamic client registration). B-387: the counter increments
      # before the cap check, so `Throttled.count` is always at least cap + 1 —
      # the message caps the reported count at the cap instead of showing the
      # post-increment value.
      private def self.rate_limit_description(throttled : RateLimiter::Throttled) : String
        "Rate limit exceeded (#{Math.min(throttled.count, throttled.cap)}/#{throttled.cap} per #{throttled.window_s}s)"
      end

      # Registers all OAuth routes on the Kemal router. OAuth 2.0 for Facet
      # apps. Uppercase first segment — an application route, not a domain id.
      def self.register : Nil
        # ── GET /OAuth/authorize ────────────────────────────────────
        #
        # Renders the consent screen. Requires the browser session so the
        # server knows who is consenting. The response is JSON describing
        # the app, the user's usable roles, and the resolved effective
        # scope per role — the frontend renders the consent UI from this
        # shape.
        #
        # When the request carries an RFC 8707 `resource` parameter naming a
        # per-role MCP resource, the MCP branch builds the screen instead:
        # no app metadata, every held role listed, and the redirect origin
        # displayed as part of what the user approves.
        get "/OAuth/authorize" do |env|
          account_id = current_account_id(env)
          unless account_id
            # No browser session — bounce to the frontend login. The login
            # page carries the user back to this authorize URL (with the full
            # query) after a successful sign-in via its `redirectTo` param.
            next redirect_to_login(env)
          end

          handle_authorize_get(env, account_id.as(String))
        end

        # ── POST /OAuth/authorize ───────────────────────────────────
        #
        # Consent confirm. The user has elected a role (and thus consented
        # to that role's effective scope with this app). The body carries
        # the same authorize params as the GET, plus `role` (the elected
        # role name). Issued codes are 60 seconds, single-use, bound to
        # the request context.
        post "/OAuth/authorize" do |env|
          account_id = current_account_id(env)
          unless account_id
            # 303 (not 302) so the browser re-issues the return trip as a GET
            # — a POST must never be replayed against the login page.
            next redirect_to_login(env, status: 303)
          end

          handle_authorize_post(env, account_id.as(String))
        end

        # ── POST /OAuth/token ──────────────────────────────────────
        #
        # Two grant types share this endpoint:
        # - `grant_type=authorization_code` — PKCE-protected; does not require
        #   a browser session.
        # - `grant_type=refresh_token` — rotates an existing app session. No
        #   PKCE; the refresh token is the bearer secret.
        #
        # The rate limiter counts `authorization_code` exchanges only;
        # `refresh_token` is exempt (the refresh floor is its guard). Both
        # grants return the same JSON body shape (`access_token`,
        # `token_type`, `expires_in`, `scope`, `refresh_token`). CORS
        # preflight handled by `OAuth::Cors`.
        post "/OAuth/token" do |env|
          handle_token_request(env)
        end

        # ── POST /OAuth/register ────────────────────────────────
        #
        # RFC 7591 dynamic client registration for MCP clients (see
        # `OAuth::Register`). Public by contract — a client holds no
        # session and no app registration before this call. Rate limited
        # per IP; CORS preflight handled by `OAuth::Cors`.
        post "/OAuth/register" do |env|
          handle_register_request(env)
        end

        # ── GET /.well-known/oauth-authorization-server ────────────────
        get "/.well-known/oauth-authorization-server" do |env|
          Facet::HTTP::Helpers.write_json(env, 200, Discovery.metadata)
        end

        # ── GET /OAuth/client-info ─────────────────────────────────
        #
        # Public client metadata for first-party CLI clients: the CLI
        # resolves its `client_id` by app slug before it starts the PKCE
        # authorize flow. No session — whitelisted in
        # `AuthHandler::PUBLIC_ROUTES`. Every failure path (unknown slug,
        # missing param, non-active app, missing `client_id`) returns the
        # same `404 unknown_client` body — no draft/disabled disclosure.
        get "/OAuth/client-info" do |env|
          handle_client_info(env)
        end
      end

      # ── GET /OAuth/client-info body ────────────────────────────────
      #
      # Extracted out of `register` to keep the Kemal-router method under
      # ameba's cyclomatic-complexity budget. `ClientInfo.find` folds all
      # failure paths into `nil`; this handler maps `nil` and the success
      # case onto their responses.
      private def self.handle_client_info(env) : Nil
        slug = env.params.query["slug"]?
        info = Database.with_db(:read_only) { |db| ClientInfo.find(db, slug) }
        return Facet::HTTP::Helpers.write_json(env, 404, {error: "unknown_client"}) unless info

        Facet::HTTP::Helpers.write_json(env, 200, {
          slug:        info.slug,
          client_id:   info.client_id,
          name:        info.name,
          client_type: info.client_type,
        })
      end

      # ── GET /OAuth/authorize body ──────────────────────────────
      #
      # Extracted out of `register` to keep the Kemal-router method under
      # ameba's cyclomatic-complexity budget. Branches on the RFC 8707
      # `resource` parameter: an MCP resource builds the MCP consent screen
      # (no app metadata, redirect origin displayed), otherwise the app
      # consent screen renders as before.
      private def self.handle_authorize_get(env, account_id : String) : Nil
        # Browser navigation (Accept: text/html) → hand off to the frontend
        # consent route. The frontend's own data fetch sends
        # `Accept: application/json` and receives the JSON payload below.
        # Content negotiation keeps `/OAuth/authorize` the single source
        # of truth for both the browser surface and the JSON API.
        if accepts_html?(env)
          redirect_to_consent(env)
          return
        end

        begin
          # The parse sits inside the guard: `Authorize.parse_params`
          # delegates required-field checks to `OAuth.require_present`, which
          # raises the base `EndpointError` — a missing `client_id` /
          # `redirect_uri` / `code_challenge` must answer the RFC 6749 error
          # body, never a 500 (B-151).
          params = parse_authorize_params(env)
          mcp_resource = params.resource.try { |r| MCP::ProtectedResource.role_slug_from_resource(r) }
          if mcp_resource
            source = parse_authorize_source(env)
            # The URL pins the role. An explicit `role` parameter wins; a
            # client that sends no `role` (every spec-following MCP client)
            # gets the resource's role slug — the consent screen pre-elects
            # it and issuance validates the match.
            pinned_role = source["role"]?.try(&.to_s) || mcp_resource
            redirect_origin = redirect_origin_of(params.redirect_uri)
            screen = Database.with_db(:read_only) do |db|
              Authorize.build_mcp_consent(db, account_id, params, pinned_role, redirect_origin)
            end
            Facet::HTTP::Helpers.write_json(env, 200, serialize_mcp_consent(screen))
            return
          end
          reject_bare_mcp_resource(params)
          screen = Database.with_db(:read_only) do |db|
            Authorize.build_consent(db, account_id, params)
          end
          Facet::HTTP::Helpers.write_json(env, 200, serialize_consent(screen))
        rescue ex : EndpointError
          # The base class, not `InvalidRequest`: the shared
          # `OAuth.require_present` raises the base for a missing parameter,
          # and the base escaping this handler answered 500 (B-151). A
          # missing authorize parameter is a client error (RFC 6749 §4.1.1),
          # never a server fault.
          error_response(env, ex)
        end
      end

      # ── POST /OAuth/authorize body ──────────────────────────────
      #
      # Extracted out of `register` to keep the Kemal-router method under
      # ameba's cyclomatic-complexity budget. Validates the elected `role`
      # and issues a single-use, 60-second code through the app branch or
      # the MCP branch. The code binds to the request context.
      private def self.handle_authorize_post(env, account_id : String) : Nil
        # Parse the body once — `env.request.body` is a one-shot IO. The
        # authorize params come from the body on POST (form-encoded or
        # JSON), and the elected `role` field lives in the same parsed
        # source rather than being read again from a possibly-empty body.
        # The role is NEVER taken from the query string on a POST — that
        # path would let a cached GET with `?role=...` silently elect a
        # role for the user without their explicit confirm.
        source = parse_authorize_source(env)
        begin
          params = Authorize.parse_params(
            client_id: source["client_id"]?,
            redirect_uri: source["redirect_uri"]?,
            state: source["state"]?,
            code_challenge: source["code_challenge"]?,
            code_challenge_method: source["code_challenge_method"]?,
            scope: source["scope"]?,
            resource: source["resource"]?,
          )
        rescue ex : EndpointError
          # The base class: `Authorize.parse_params` delegates required-field
          # checks to `OAuth.require_present`, which raises the base — a
          # rescue of `InvalidRequest` alone let it escape as a 500 (B-151).
          error_response(env, ex)
          return
        end
        elected_role = source["role"]?.try(&.to_s) || ""
        if elected_role.empty?
          return Facet::HTTP::Helpers.write_json(env, 422, {error: "Missing 'role' field"})
        end

        begin
          issued = Database.with_db do |db|
            if params.resource.try { |r| MCP::ProtectedResource.role_slug_from_resource(r) }
              Authorize.issue_mcp_code(db, account_id, params, elected_role)
            else
              reject_bare_mcp_resource(params)
              Authorize.issue_code(db, account_id, params, elected_role)
            end
          end
          Facet::HTTP::Helpers.write_json(env, 200, serialize_issued_code(issued))
        rescue ex : Authorize::AccessDenied
          # Redirect-eligible: zero usable roles or the elected role no
          # longer satisfies the app's required actions. `AccessDenied` does
          # not inherit `EndpointError` — it keeps its own rescue.
          Facet::HTTP::Helpers.write_json(env, 200, serialize_access_denied(ex))
        rescue ex : EndpointError
          # The base class, not `InvalidRequest` — same reason as the GET
          # handler (B-151): a missing authorize parameter must answer the
          # RFC 6749 error body, not a 500.
          error_response(env, ex)
        end
      end

      # ── POST /OAuth/register body ──────────────────────────
      #
      # Parses the RFC 7591 client-metadata JSON body, applies the per-IP
      # rate limit, and renders the 201 registration response. The body is
      # JSON only (RFC 7591 §2); a malformed body is
      # `invalid_client_metadata`. Extracted out of `register` to keep the
      # Kemal-router method under ameba's cyclomatic-complexity budget.
      private def self.handle_register_request(env) : Nil
        ip = Facet::Util::ClientIp.resolve(env.request.headers, env.request.remote_address, Facet::Config.instance.trusted_proxies)
        if throttled = RateLimiter.check_ip(ip, "register")
          env.response.headers["Retry-After"] = throttled.window_s.to_s
          return Facet::HTTP::Helpers.write_json(env, 429, {
            error:             "slow_down",
            error_description: rate_limit_description(throttled),
          })
        end

        begin
          registered = Register.call(parse_register_body(env))
          Facet::HTTP::Helpers.write_json(env, 201, Register.response(registered))
        rescue ex : Register::Error
          error_response(env, ex)
        end
      end

      # The registration request body is a JSON client-metadata document.
      private def self.parse_register_body(env) : JSON::Any
        body = env.request.body.try(&.gets_to_end) || ""
        JSON.parse(body)
      rescue JSON::ParseException
        raise Register::Error.new("invalid_client_metadata",
          "Request body is not a JSON client-metadata document", 400)
      end

      # Rejects an RFC 8707 `resource` that sits under the MCP prefix but
      # names no role (e.g. the bare `…/Api/_mcp`). Such a resource can never
      # satisfy the URL-pins-role dispatch contract — the token's `aud`
      # would fail the exact-match check against every `/Api/_mcp/:role_slug`
      # route — so it answers `invalid_target` (RFC 8707 §4) instead of the
      # misleading app-branch "Unknown client_id". Well-behaved clients get
      # the role-pinned resource from the path-carrying PRM (see
      # `MCP::Routes#unauthorized_with_prm`).
      private def self.reject_bare_mcp_resource(params : Authorize::Params) : Nil
        resource = params.resource
        return unless resource
        prefix = "#{MCP.base_url}#{MCP::PATH_PREFIX}"
        return unless resource.starts_with?(prefix)

        raise Authorize::InvalidRequest.new("invalid_target",
          "'resource' must name a role-pinned MCP endpoint (#{prefix}/<role_slug>)", 400)
      end

      # ── POST /OAuth/token body ─────────────────────────────────────
      #
      # Extracted out of `register` to keep the Kemal-router method under
      # ameba's cyclomatic-complexity budget. Two grant types share this
      # endpoint:
      # - `grant_type=authorization_code` — PKCE-protected; does not require
      #   a browser session.
      # - `grant_type=refresh_token` — rotates an existing app session. No
      #   PKCE; the refresh token is the bearer secret.
      #
      # The rate limiter (`OAuth::RateLimiter`, keyed on `(client_id, IP)`)
      # governs the `authorization_code` grant only. The counter targets
      # interactive exchanges — a one-shot, human-paced event an abuser can
      # hammer. Refresh runs on a clock: CLIs and agents renew on a
      # schedule, so counting refreshes would starve long-lived sessions.
      # The refresh grant is guarded instead by the refresh floor
      # (`OAuth::Refresh.REFRESH_FLOOR_S`) plus rotation and reuse
      # detection. Both grants return the same JSON body shape
      # (`access_token`, `token_type`, `expires_in`, `refresh_token`); no
      # `scope` member — the server advertises no scope vocabulary, so the
      # optional member is omitted (RFC 6749 §5.1). CORS preflight handled
      # by `OAuth::Cors`.
      private def self.handle_token_request(env) : Nil
        body_params = params_body(env)
        grant_type = body_params["grant_type"]?.try(&.to_s) || ""
        client_id = body_params["client_id"]?

        ip = Facet::Util::ClientIp.resolve(env.request.headers, env.request.remote_address, Facet::Config.instance.trusted_proxies)
        # The counter governs interactive exchanges only (see the module
        # header above). `refresh_token` is exempt — the floor is its guard.
        if grant_type == "authorization_code" && client_id && (throttled = RateLimiter.check(client_id, ip))
          env.response.headers["Retry-After"] = throttled.window_s.to_s
          return Facet::HTTP::Helpers.write_json(env, 429, {
            error:             "slow_down",
            error_description: rate_limit_description(throttled),
          })
        end

        # DPoP header + reconstructed `htu`. Both are derived from the Kemal
        # request only — `htu` does **not** consult `X-Forwarded-Proto` / -Host
        # (attacker-controlled when the proxy is misconfigured; see
        # `OAuth::HTU.reconstruct`). The same `htu` reaches `Token.call` and
        # `Refresh.call` so the verifier can compare it against the proof's
        # `htu` claim.
        dpop_proof = env.request.headers["DPoP"]?
        htu = OAuth::HTU.reconstruct(env.request.path)

        begin
          issued = Database.with_db do |db|
            dispatch_token_grant(db, grant_type, body_params, client_id, ip, dpop_proof, htu)
          end
          # `Token::Issued` and `Refresh::Issued` are structurally identical
          # (same fields, same JSON shape); serialize with the same helper
          # so the client treats issuance and refresh uniformly.
          Facet::HTTP::Helpers.write_json(env, 200, serialize_token_response(issued))
        rescue ex : EndpointError
          # The base class covers both per-module error types AND any raise
          # of the base itself (e.g. a shared helper) — a missing form field
          # is a client error (RFC 6749 §5.2 `invalid_request`, 400), never
          # a 500 the monitoring system counts as a server fault (B-24).
          error_response(env, ex)
        end
      end

      # Dispatches to the per-grant-type service. Pulled out so the
      # `begin … rescue` block in `handle_token_request` stays simple enough
      # for ameba's complexity check.
      private def self.dispatch_token_grant(
        db : DB::Connection,
        grant_type : String,
        body_params : URI::Params,
        client_id : String?,
        ip : String?,
        dpop_proof : String?,
        htu : String,
      ) : Token::Issued | Refresh::Issued
        case grant_type
        when "authorization_code"
          code = body_params["code"]?
          redirect_uri = body_params["redirect_uri"]?
          code_verifier = body_params["code_verifier"]?
          Token.call(db, grant_type, code, redirect_uri, code_verifier, client_id,
            dpop_proof: dpop_proof, htu: htu)
        when "refresh_token"
          refresh_token = body_params["refresh_token"]?
          if refresh_token.nil? || refresh_token.to_s.empty?
            raise Token::Error.new("invalid_request", "Missing 'refresh_token'", 400)
          end
          # MCP sessions are browser-session-shaped (no `app` field). The
          # refresh dispatch branches on that shape: an app session goes to
          # `Refresh.call` (client binding + grant revalidation), an MCP
          # session to `Refresh.call_mcp` (account-active + role-held only,
          # no client binding — MCP registration is stateless). A malformed
          # token fails in both paths identically. The body `client_id`
          # reaches the app path only: `Refresh.call` compares it against
          # the client the code was exchanged with (B-150).
          sid = refresh_token.to_s.split('.', 2)[0]?
          if sid && !sid.empty? && mcp_session?(sid)
            Refresh.call_mcp(db, refresh_token.to_s, ip: ip, dpop_proof: dpop_proof, htu: htu)
          else
            Refresh.call(db, refresh_token.to_s, client_id: client_id,
              ip: ip, dpop_proof: dpop_proof, htu: htu)
          end
        else
          raise Token::Error.new("unsupported_grant_type",
            "Only grant_type=authorization_code and grant_type=refresh_token are supported", 400)
        end
      end

      # True when the Redis session behind `sid` is browser-session-shaped
      # (empty `app` field) — i.e. an MCP session minted by the resource-
      # branch of the token endpoint. App sessions carry their `app.App` id
      # and route to the grant-revalidating refresh path instead.
      private def self.mcp_session?(sid : String) : Bool
        session = IAM::RedisSession.load(sid)
        return false unless session
        session.app.empty?
      end

      # ── Helpers ────────────────────────────────────────────────────────

      # Redirects an unauthenticated authorize request to the frontend login
      # page, embedding the original authorize URL (path + full query) as the
      # `redirectTo` param the login flow already understands.
      #
      # The Location is **relative** — same-origin by construction. The
      # backend never needs to know the frontend's address: in dev the Caddy
      # proxy serves both surfaces on one origin, and in production a reverse
      # proxy does the same. This is why no `frontend_url` config key exists.
      #
      # The target is built from the request itself, but it still passes
      # through `safe_return_to?` — the guard keeps the redirect contract
      # honest if a future change ever sources the target from client input.
      private def self.redirect_to_login(env, status : Int32 = 302) : Nil
        target = "/OAuth/authorize"
        unless env.request.query.to_s.empty?
          target += "?#{env.request.query}"
        end
        unless safe_return_to?(target)
          env.response.status_code = 400
          env.response.content_type = "application/json"
          return env.response.print({error: "Invalid return_to"}.to_json)
        end

        env.response.status_code = status
        env.response.headers["Location"] = "/Login?redirectTo=#{URI.encode_path_segment(target)}"
        env.response.content_type = "text/plain"
        env.response.print("Redirecting to login…")
      end

      # Redirects an authenticated browser navigation to the frontend consent
      # route, preserving the full authorize query so the page can re-fetch the
      # consent payload. Relative and same-origin by construction — mirrors the
      # `/Login` bounce; the backend never needs the frontend's address.
      private def self.redirect_to_consent(env) : Nil
        target = "/OAuthConsent"
        unless env.request.query.to_s.empty?
          target += "?#{env.request.query}"
        end
        env.response.status_code = 302
        env.response.headers["Location"] = target
        env.response.content_type = "text/plain"
        env.response.print("Redirecting to consent…")
      end

      # Content-negotiation discriminator: a browser navigation advertises
      # `text/html` in `Accept`; the frontend's consent fetch sends
      # `application/json`. Anything else (no header, `*/*`) is treated as a
      # JSON API call and returns the payload.
      private def self.accepts_html?(env) : Bool
        accept = env.request.headers["Accept"]?
        return false unless accept
        accept.includes?("text/html")
      end

      # Open-redirect guard for the login return path. Accepts only a
      # path-absolute URL whose path is exactly `/OAuth/authorize` —
      # same-origin, authorize-only. Rejects scheme-relative (`//host`),
      # absolute URLs to any origin, other paths, and control characters.
      private def self.safe_return_to?(url : String) : Bool
        return false if url.empty?
        return false if url.byte_at(0) != 0x2f # not '/'-prefixed
        return false if url.starts_with?("//") # scheme-relative
        return false if url.matches?(/[[:cntrl:]]/)

        uri = URI.parse(url)
        return false unless uri.host.nil? && uri.scheme.nil?
        uri.path == "/OAuth/authorize"
      end

      # Extracts the authenticated account_id from the browser session. Uses
      # the existing `auth_token` cookie JWT without going through the full
      # `AuthHandler` (which is by design disabled in tests and requires
      # the route to be on the protected list). Returns nil when there is no
      # session or the session is expired.
      private def self.current_account_id(env) : String?
        token = IAM::Helpers.decode_jwt_claim(env, "sub")
        return nil if token.nil? || token.empty?

        # Token integrity: a tampered `sub` must not yield a phantom account.
        # Decode through `IAM::JWT.decode` (signature-pinned) and read `sub`
        # from the verified payload. `Helpers.decode_jwt_claim(env, _)`
        # parses without signature verification — fast but not safe.
        bearer = bearer_token(env)
        return nil unless bearer
        decoded = IAM::JWT.decode(bearer, IAM::TokenEmitter.keys) rescue nil
        return nil unless decoded
        decoded.payload["sub"]?.try(&.as_s?)
      end

      # Pulls the raw access token from cookie or Authorization header —
      # the shared extractor restricted to the `Bearer` scheme.
      private def self.bearer_token(env) : String?
        Facet::HTTP::Helpers.extract_access_token(env, schemes: ["Bearer"])
      end

      # Parses the OAuth authorize params from the request. On a GET the
      # source is the query string; on a POST it is the form (or JSON) body.
      # Validates the S256 challenge method. The RFC 8707 `resource`
      # parameter selects the MCP branch when present.
      private def self.parse_authorize_params(env) : Authorize::Params
        source = parse_authorize_source(env)
        Authorize.parse_params(
          client_id: source["client_id"]?,
          redirect_uri: source["redirect_uri"]?,
          state: source["state"]?,
          code_challenge: source["code_challenge"]?,
          code_challenge_method: source["code_challenge_method"]?,
          scope: source["scope"]?,
          resource: source["resource"]?,
        )
      end

      # The single source-of-truth body parser. On a GET it returns the query
      # string params (no body to consume); on any other method it parses the
      # request body once into a `URI::Params`. Calling this twice on the same
      # request would yield an empty body the second time — handlers that need
      # both the OAuth params and the elected `role` field must capture the
      # return value once and reuse it.
      private def self.parse_authorize_source(env) : URI::Params
        if env.request.method == "GET"
          return env.request.query_params
        end
        params_body(env)
      end

      # Parses the POST body as URL-encoded form parameters. The token
      # endpoint receives `application/x-www-form-urlencoded` per RFC 6749.
      # The authorize POST accepts either form-encoded or JSON; both go
      # through this parser for simplicity.
      private def self.params_body(env) : URI::Params
        body = env.request.body.try(&.gets_to_end) || ""
        content_type = env.request.headers["Content-Type"]? || ""
        if content_type.includes?("application/json")
          begin
            parsed = JSON.parse(body).as_h
            params = URI::Params.new
            parsed.each do |k, v|
              params[k] = v.to_s
            end
            return params
          rescue JSON::ParseException
            return URI::Params.new
          end
        end
        URI::Params.parse(body)
      end

      # Renders an OAuth endpoint error response. All OAuth protocol errors
      # subclass `EndpointError` (`Authorize::InvalidRequest`, `Token::Error`,
      # `Refresh::Error`, `Register::Error`, and the base itself); the base
      # parameter type lets a single helper serve the authorize and token
      # endpoints. The body is the RFC 6749 §5.2 shape (`error` +
      # `error_description`), so this stays a local wrapper beside
      # `HTTP::Helpers.error_response`.
      private def self.error_response(env, ex : EndpointError) : Nil
        env.response.status_code = ex.status
        env.response.content_type = "application/json"
        env.response.print({
          error:             ex.error_code,
          error_description: ex.message,
        }.to_json)
      end

      private def self.serialize_consent(screen : Authorize::ConsentScreen)
        app = screen.app
        roles = screen.roles.map do |r|
          {
            "role_id"         => r.role_id,
            "display_name"    => r.display_name,
            "effective_scope" => Facet::OAuth.serialize_scope(r.effective_scope),
          }
        end
        {
          "app" => {
            "id"              => app.id,
            "client_id"       => app.client_id,
            "slug"            => app.slug,
            "display_name"    => app.display_name,
            "description"     => app.description,
            "redirect_uris"   => app.redirect_uris,
            "allowed_origins" => app.allowed_origins,
            "status"          => app.status,
          },
          "roles"           => roles,
          "state"           => screen.params.state,
          "requested_scope" => screen.requested_scope,
        }
      end

      # Serializes the MCP consent screen. Shape mirrors `serialize_consent`
      # minus the app block, plus the resource identifier and the redirect
      # origin the user is approving.
      private def self.serialize_mcp_consent(screen : Authorize::MCPScreen)
        roles = screen.roles.map do |r|
          {
            "role_id"         => r.role_id,
            "display_name"    => r.display_name,
            "effective_scope" => Facet::OAuth.serialize_scope(r.effective_scope),
          }
        end
        {
          "mcp"             => true,
          "resource"        => screen.resource,
          "roles"           => roles,
          "pinned_role"     => screen.pinned_role,
          "redirect_origin" => screen.redirect_origin,
          "state"           => screen.params.state,
          "requested_scope" => screen.params.scope,
        }
      end

      # The scheme + host + port of a redirect URI — what the consent screen
      # displays as the destination the code will be sent to.
      private def self.redirect_origin_of(redirect_uri : String) : String
        uri = URI.parse(redirect_uri)
        host = uri.host || ""
        if uri.port
          "#{uri.scheme}://#{host}:#{uri.port}"
        else
          "#{uri.scheme}://#{host}"
        end
      end

      private def self.serialize_issued_code(issued : Authorize::IssuedCode)
        {
          "redirect_uri" => issued.redirect_uri,
          "code"         => issued.code,
          "state"        => issued.state,
          "app_id"       => issued.app_id,
          "role_id"      => issued.role_id,
          # RFC 9207 — the issuer identifier travels with the authorization
          # response so the client can verify the code came from the AS it
          # talked to (AS mix-up defence). Clients validate this before
          # redeeming the code.
          "iss" => Facet::OAuth::Discovery.issuer,
        }
      end

      private def self.serialize_access_denied(denied : Authorize::AccessDenied)
        {
          "redirect_uri" => denied.redirect_uri,
          "error"        => "access_denied",
          "state"        => denied.state,
        }
      end

      # Serializes a token-endpoint success response. `Token::Issued` and
      # `Refresh::Issued` are structurally identical records; both define the
      # same four fields. The union parameter type lets the same serializer
      # serve the `authorization_code` and `refresh_token` grant types. No
      # `scope` member — see `Token::Issued`.
      private def self.serialize_token_response(issued : Token::Issued | Refresh::Issued) : JSON::Any
        JSON::Any.new({
          "access_token"  => JSON::Any.new(issued.access_token),
          "token_type"    => JSON::Any.new(issued.token_type),
          "expires_in"    => JSON::Any.new(issued.expires_in),
          "refresh_token" => JSON::Any.new(issued.refresh_token),
        })
      end
    end
  end
end
