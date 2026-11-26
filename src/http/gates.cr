# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./list_request"
require "./auth_handler"
require "./responders"
require "../iam/api_key"
require "../iam/helpers"
require "../rbac"

module Facet
  module HTTP
    # Request admission gates: body parsing, QUERY parsing, CSRF, path
    # params, and access-token reading. A failed gate writes its error
    # through `Responders` and returns nil or false.
    module Gates
      extend self

      # ── Body parsing ──────────────────────────────────────────────────────

      # Parses the JSON body from a Kemal request env.
      # Returns `nil` when the body is empty or missing.
      def parse_body(env) : String?
        env.request.body.try(&.gets_to_end)
      end

      # Parses the body from env, or writes a 422 JSON error and returns nil.
      # Use with `|| next` in route handlers.
      def require_body(env) : String?
        body = parse_body(env)
        if body.nil? || body.empty?
          Responders.write_json_error(env, 422, "Request body is required")
          return nil
        end
        body
      end

      # ── QUERY method (RFC 10008) ──────────────────────────────────────────

      # Parses a QUERY request into a `ListRequest`.
      #
      # QUERY is a safe, cacheable request whose query rides the body, so
      # the contract is body-only:
      #
      # - Query-string parameters are rejected with `422`. A caller whose
      #   `?page=2` was silently dropped would read wrong results — the
      #   error keeps the transport split loud.
      # - An empty body means the defaults (page 1, items 100, sort id).
      # - A present body must declare a JSON media type (`415` otherwise).
      #   Kemal already rejects a body with no `Content-Type` at all with
      #   `400` (RFC 10008), before this helper runs.
      # - The body must be a JSON object → `422` otherwise.
      # - The body keys are admitted strictly (the B-169 remainder): a key
      #   outside the list grammar answers `422` naming it, never a silent
      #   drop. `admitted_keys` narrows the grammar to the keys the route
      #   reads; the default is the whole grammar.
      #
      # Returns `nil` after writing the error response — use with
      # `|| return` in route handlers. The optional block receives the
      # parsed body JSON (`nil` when the body is empty) so a route can read
      # keys beyond the list-request contract (`include` on the history
      # routes, `status` on the webhook-calls route).
      def query_list_request(env) : ListRequest?
        query_list_request_with(env, ListRequest::ALL_BODY_KEYS, ->(_body : JSON::Any?) { nil })
      end

      # Body-only QUERY parse with a narrowed admitted set and no handler
      # block — the shape the global audit list runs.
      def query_list_request(env, admitted_keys : Set(String)) : ListRequest?
        query_list_request_with(env, admitted_keys, ->(_body : JSON::Any?) { nil })
      end

      # `admitted_keys` narrows the body grammar to the keys the route
      # reads (the global audit list drops `field`, `select`, and
      # `aggregate`); the default is the whole grammar. `extra_body_keys`
      # names the body keys a route reads beyond the grammar (`include` on
      # the history routes, `status` on the webhook-calls route) — the same
      # role `extra_query_keys` plays on the GET transport.
      def query_list_request(
        env,
        admitted_keys : Set(String) = ListRequest::ALL_BODY_KEYS,
        extra_body_keys : Set(String) = Set(String).new,
        &block : JSON::Any? -> Nil
      ) : ListRequest?
        query_list_request_with(env, admitted_keys + extra_body_keys, block)
      end

      private def query_list_request_with(
        env,
        admitted_keys : Set(String),
        block : Proc(JSON::Any?, Nil),
      ) : ListRequest?
        if (raw_query = env.request.query) && !raw_query.empty?
          Responders.error_response(env, 422, "QUERY does not accept query parameters; put them in the request body")
          return nil
        end

        raw = parse_body(env)
        return ListRequest.new if raw.nil? || raw.empty?

        unless json_content_type?(env.request.headers["Content-Type"]?)
          Responders.error_response(env, 415, "Unsupported media type — the QUERY body must be application/json")
          return nil
        end

        parsed = begin
          JSON.parse(raw)
        rescue
          Responders.error_response(env, 422, "Invalid JSON body")
          return nil
        end
        unless parsed.as_h?
          Responders.error_response(env, 422, "Invalid JSON body — the QUERY body must be a JSON object")
          return nil
        end

        block.call(parsed)
        result = ListRequest.from_json(parsed, strict: true, admitted_keys: admitted_keys)
        if result.is_a?(Facet::ServiceError)
          Responders.error_response(env, result.status, result.message)
          return nil
        end
        result
      end

      # Parses a GET list request through `ListRequest.from_request`, which
      # accepts parameters from the query string and, when a body is
      # present, merges a JSON body. The body holds the same shape gate as
      # every other body-consuming route (B-59): a non-object body — or
      # unparseable JSON — is answered with `422` here instead of escaping
      # the parser as a 500.
      #
      # `strict` turns on strict admission (the B-169 remainder): a query
      # parameter outside the known set answers `422` naming it, instead of
      # a silent drop. `extra_query_keys` names the keys the handler reads
      # beyond the list-request grammar (`include` on the document history,
      # `status` on the webhook-calls route); the strict scan admits them.
      # `admitted_body_keys` / `admitted_query_keys` narrow the grammar to
      # the keys the route reads on each transport (the global audit list
      # drops `field`, `select`, and `aggregate`). The scans run only when
      # `strict` is true, so the sets are a no-op on the lenient default.
      #
      # Returns `nil` after writing the error response — use with
      # `|| return` in route handlers, matching `query_list_request`.
      def get_list_request(
        env,
        strict : Bool = false,
        extra_query_keys : Set(String) = Set(String).new,
        admitted_body_keys : Set(String) = ListRequest::ALL_BODY_KEYS,
        admitted_query_keys : Set(String) = ListRequest::ALL_QUERY_KEYS,
      ) : ListRequest?
        result = ListRequest.from_request(env, strict, extra_query_keys, admitted_body_keys, admitted_query_keys)
        if result.is_a?(Facet::ServiceError)
          Responders.error_response(env, result.status, result.message)
          return nil
        end
        result
      end

      # Parses a QUERY request body as a JSON object under the same
      # transport contract `query_list_request` enforces, for routes whose
      # body is not a list request:
      #
      # - Query-string parameters are rejected with `422` (body-only).
      # - An empty body yields an empty object — the route's defaults.
      # - A present body must declare a JSON media type (`415` otherwise)
      #   and be a JSON object (`422` otherwise).
      #
      # Returns `nil` after writing the error response — use with
      # `|| return` in route handlers.
      def query_body_json(env) : JSON::Any?
        if (raw_query = env.request.query) && !raw_query.empty?
          Responders.error_response(env, 422, "QUERY does not accept query parameters; put them in the request body")
          return nil
        end

        raw = parse_body(env)
        return JSON.parse("{}") if raw.nil? || raw.empty?

        unless json_content_type?(env.request.headers["Content-Type"]?)
          Responders.error_response(env, 415, "Unsupported media type — the QUERY body must be application/json")
          return nil
        end

        parsed = begin
          JSON.parse(raw)
        rescue
          Responders.error_response(env, 422, "Invalid JSON body")
          return nil
        end
        unless parsed.as_h?
          Responders.error_response(env, 422, "Invalid JSON body — the QUERY body must be a JSON object")
          return nil
        end
        parsed
      end

      # True when the Content-Type header names a JSON media type:
      # `application/json` (with optional parameters) or a structured
      # syntax suffix `application/*+json`. Public so feature routes with
      # structured JSON POST payloads (e.g. the import/export view export)
      # hold the same media-type gate the QUERY method does.
      def json_content_type?(header : String?) : Bool
        return false if header.nil?
        ct = header.downcase
        ct.starts_with?("application/json") || (ct.starts_with?("application/") && ct.ends_with?("+json"))
      end

      # Advertises the QUERY body format the route accepts (RFC 10008
      # §2.2). Set on the GET and QUERY responses of the list surfaces
      # that support both.
      def accept_query(env) : Nil
        env.response.headers["Accept-Query"] = "application/json"
      end

      # ── Request gates ────────────────────────────────────────────────────
      #
      # Shared gates for the feature route modules (iam, settings,
      # notifications, app, assistant, import_export). Each gate writes its
      # own JSON error through `Responders.error_response` — status, content
      # type, and `Cache-Control: no-store` are always set — and returns
      # nil/false when the caller must stop. Use with `|| next` /
      # `next unless`.

      # CSRF defense: browser sessions are cookie-authenticated, so a
      # cross-site POST cannot legitimately carry the `X-Requested-With`
      # header. State-changing routes must require it.
      #
      # The header must be present AND non-blank — an empty value fails
      # the same as an absent one.
      #
      # A request that presents an Authorization credential (`Bearer` or
      # `DPoP` — the schemes `AuthHandler.extract_token_and_scheme`
      # accepts, parsed through `parse_authorization`) **without** an
      # `auth_token` cookie is exempt. Browsers never attach an
      # Authorization header to cross-site requests, so such a credential
      # is non-ambient by construction and cannot be replayed by a CSRF
      # forgery. This subsumes the static-API-key bypass: every `fct_`
      # key rides `Bearer`. The `api_key_bypass` argument is kept for the
      # call sites that still pass it; the exemption below already covers
      # its case.
      #
      # A request with the cookie present stays CSRF-checked even when an
      # Authorization header rides beside it — the cookie is the ambient
      # credential this defense exists for.
      def csrf_check(env, api_key_bypass : Bool = false) : Bool
        return true if api_key_bypass && api_key_bearer?(env)
        return true if non_ambient_credential?(env)
        header = env.request.headers["X-Requested-With"]?
        !(header.nil? || header.blank?)
      end

      # Enforces `csrf_check` and writes the shared 403 error response on
      # failure. Returns false when the caller must stop — use with
      # `next unless` / `return unless`.
      def require_csrf(env, api_key_bypass : Bool = false) : Bool
        return true if csrf_check(env, api_key_bypass)
        Responders.error_response(env, 403, "CSRF: Missing X-Requested-With header")
        false
      end

      # True when the request presents a well-formed API-key bearer token and
      # no session cookie — i.e. the request authenticates through the API-key
      # channel alone.
      def api_key_bearer?(env) : Bool
        return false if env.request.cookies["auth_token"]?
        token = extract_access_token(env, schemes: ["Bearer"], cookie: false)
        return false unless token
        IAM::ApiKey.token?(token)
      end

      # True when the request carries a `Bearer`/`DPoP` Authorization
      # credential and no `auth_token` cookie. Such a credential cannot
      # ride a cross-site browser request, so the caller is not exposed to
      # CSRF and the `X-Requested-With` check does not apply.
      def non_ambient_credential?(env) : Bool
        return false if env.request.cookies["auth_token"]?
        !parse_authorization(env.request.headers["Authorization"]?, ["Bearer", "DPoP"]).nil?
      end

      # Reads the raw access token for route handlers: the `auth_token`
      # cookie first (when `cookie` is true and the stored value is not
      # empty), then the Authorization header restricted to the named
      # schemes, matched case-insensitively. Returns nil when neither
      # source yields a token.
      #
      # Transport only. The value is NOT verified here, so a route must never
      # trust a claim read from it. Read the identity from the verified auth
      # context instead (`require_account` / `require_role`, or
      # `IAM::Helpers.verified_jwt_claim` for a claim the context does not
      # carry).
      def extract_access_token(env, schemes : Array(String) = ["Bearer", "DPoP"], cookie : Bool = true) : String?
        if cookie && (stored = env.request.cookies["auth_token"]?.try(&.value)) && !stored.empty?
          return stored
        end
        parse_authorization(env.request.headers["Authorization"]?, schemes).try(&.[0])
      end

      # Parses an Authorization header value against the named schemes
      # (case-insensitive). Returns `{token, downcased scheme}`, or nil
      # when the header is absent or carries none of the schemes. One
      # header-parse rule for both token extractors — callers choose
      # their own precedence between this and the `auth_token` cookie
      # (route helpers read the cookie first; `AuthHandler` reads the
      # header first so an explicit caller is never shadowed by an
      # ambient cookie).
      def parse_authorization(header : String?, schemes : Array(String)) : {String, String}?
        return nil unless header
        header.match(Regex.new("^\\s*(#{schemes.join("|")})\\s+(.+)$", Regex::Options::IGNORE_CASE))
          .try { |m| {m[2], m[1].downcase} }
      end

      # Extracts the caller's account id from the verified auth context
      # (`Fiber.current.auth_context`, set by `AuthHandler` after the JWT
      # signature check), or writes the 401 JSON error and returns nil. Use
      # with `|| next`.
      #
      # The identity never comes from an unverified token claim. A forged
      # `auth_token` cookie must not name another account: `AuthHandler`
      # verified the credential it accepted, and this gate reads that result.
      # The system bypass, the preview capability, and the anonymous fallback
      # all refuse.
      def require_account(env) : String?
        account_id = verified_account_id(env)
        return account_id if account_id
        Responders.error_response(env, 401, "Authentication required")
        nil
      end

      # Extracts the caller's active role id (the role content name, e.g.
      # `admin`) from the verified auth context, or writes the 401 JSON error
      # and returns nil. Use with `|| next`. Mirrors `require_account`.
      def require_role(env) : String?
        context = Fiber.current.auth_context
        if context
          return principal_role(context) unless context.system? || context.preview?
        else
          # Test mode (no pinned context): verify the signature, then read
          # the role claim. Production always has the context.
          role = IAM::Helpers.extract_role(env) unless HTTP::AuthHandler.enabled?
          return role if role
        end
        Responders.error_response(env, 401, "Authentication required")
        nil
      end

      # The role content name of a real, non-anonymous principal, or nil.
      private def principal_role(context : Facet::RBAC::AuthContext) : String?
        principal = context.principal
        return nil unless principal.is_a?(Facet::RBAC::Principal::Real)
        return nil if principal.account_id == "anonymous"
        principal.active_role.role_id
      end

      # The account id of a real, non-anonymous principal pinned on the
      # fiber by `AuthHandler`, or nil for every other shape (system bypass,
      # preview capability, anonymous fallback, missing context).
      #
      # With `AuthHandler` disabled (test mode) no context is pinned. The
      # gate then verifies the presented token's signature itself
      # (`IAM::Helpers.extract_account_id` — ES256, never a raw claim decode)
      # so a route spec keeps a real identity. Production always has the
      # context, so this fallback never runs there.
      private def verified_account_id(env) : String?
        context = Fiber.current.auth_context
        return test_mode_account_id(env) unless context
        return nil if context.system? || context.preview?
        principal = context.principal
        return nil unless principal.is_a?(Facet::RBAC::Principal::Real)
        account_id = principal.account_id
        account_id == "anonymous" ? nil : account_id
      end

      # The verified JWT `sub` for a test-mode request (no pinned context).
      private def test_mode_account_id(env) : String?
        return nil if HTTP::AuthHandler.enabled?
        IAM::Helpers.extract_account_id(env)
      end

      # Extracts a required path parameter, or writes the 422 JSON error and
      # returns nil when it is missing or empty. Use with `|| next`.
      def require_path_param(env, name : String) : String?
        value = env.params.url[name]?.try(&.to_s)
        return value unless value.nil? || value.empty?
        Responders.error_response(env, 422, "Missing '#{name}' path parameter")
        nil
      end

      # Parses a JSON request body as a `JSON::Any`. Writes the 422 error
      # response and returns nil when the body is malformed. Use with
      # `|| next`.
      def parse_json_body(env, body : String) : JSON::Any?
        JSON.parse(body)
      rescue ex : JSON::Error
        Responders.error_response(env, 422, "Invalid JSON: #{ex.message}")
        nil
      end

      # Parses a request body that must be a JSON object. Writes the 422
      # error response and returns nil when the body is malformed or is not
      # an object. Use with `|| next`.
      def parse_json_object(env, body : String) : Hash(String, JSON::Any)?
        JSON.parse(body).as_h? || begin
          Responders.error_response(env, 422, "Request body must be a JSON object")
          nil
        end
      rescue ex : JSON::Error
        Responders.error_response(env, 422, "Invalid JSON: #{ex.message}")
        nil
      end

      # ── Auth context extraction ─────────────────────────────────────────

      # Extracts the auth context from the request env.
      #
      # - When `AuthHandler` is enabled (production): if the fiber-local
      #   context is nil (misconfiguration, missing middleware), returns
      #   `AuthContext.denied` — fail-closed.
      # - When `AuthHandler` is disabled (test mode): returns
      #   `AuthContext.system` so tests run unrestricted.
      def auth_context(env) : Facet::RBAC::AuthContext
        if ctx = Fiber.current.auth_context
          ctx
        elsif HTTP::AuthHandler.enabled?
          Facet::RBAC::AuthContext.denied
        else
          Facet::RBAC::AuthContext.system
        end
      end
    end
  end
end
