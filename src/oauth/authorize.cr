# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "../database"
require "../mutation/client"
require "../iam/helpers"
require "../mcp/protected_resource"
require "../rbac/active_role"
require "../rbac/grant_resolver"
require "./code_store"
require "./endpoint_error"
require "./redirect_uri"

module Facet
  module OAuth
    # Validates an incoming authorize request, lists the account's usable roles
    # for the app, and (after consent + role election) issues an
    # authorization code into the `CodeStore`.
    #
    # The consent screen is **always** displayed: an account may hold several
    # roles, and logging into an app explicitly elects one. There is no
    # "silent consent because you consented before" path.
    #
    # ## Endpoint contract
    #
    # `GET /OAuth/authorize` (browser session required) — renders consent:
    # returns the app metadata + the list of usable roles + the resolved
    # effective scope per role. Never issues a code; never redirects with one.
    #
    # `POST /OAuth/authorize` (consent confirm; browser session required)
    # — body carries the authorize params + the elected `role`. Validates the
    # role is one of the usable candidates, then issues a code and returns
    # `{redirect_uri, code, state}` for the caller to redirect the browser.
    #
    # ## Security properties
    #
    # - `redirect_uri` matches the registered list exactly, except a
    #   registered entry whose port is `*` (http loopback hosts only — see
    #   `OAuth::RedirectUri`) matches any port. A mismatch → `InvalidRequest`
    #   rendered as an error (never redirected — see brief on the classic
    #   code-theft vector).
    # - `code_challenge_method` must be `S256`. `plain` → `InvalidRequest`.
    # - `client_id` must resolve to an `app.App` whose `status == "active"`.
    # - The authorized `role` must be `role_usable?(app, role)` — an account can
    #   only elect a role they actually hold and that satisfies the app's
    #   required actions.
    module Authorize
      # Standard OAuth authorize parameters, parsed and validated.
      #
      # `resource` (RFC 8707) is present only on the MCP branch — it names the
      # resource identifier the token is minted for and becomes its `aud`.
      record Params,
        client_id : String,
        redirect_uri : String,
        state : String?,
        code_challenge : String,
        scope : String?,
        resource : String? = nil

      # The metadata response for the consent screen.
      record ConsentScreen,
        app : App,
        roles : Array(UsableRole),
        params : Params,
        requested_scope : String?

      # A Facet application registration as the authorize flow sees it.
      record App,
        id : String, # the projection id (ULID)
        client_id : String,
        slug : String,
        display_name : String,
        description : String?,
        redirect_uris : Array(String),
        allowed_origins : Array(String),
        status : String

      # A role the account holds that is usable with this app + its resolved
      # effective scope. The account elects one on the consent screen.
      record UsableRole,
        role_id : String, # the `iam.Roles.name`
        display_name : String?,
        effective_scope : RBAC::EffectiveScope

      # A request-scoped error: returned to the caller as an HTTP 4xx with
      # `{error, error_description}` JSON. Never triggers a redirect. It is
      # the authorize-surface name of the shared `OAuth::EndpointError`.
      class InvalidRequest < EndpointError
      end

      # `access_denied` is a redirect-eligible outcome: the client is known,
      # the redirect_uri is valid, but the account has zero usable roles for
      # this app. The route returns a redirect with `error=access_denied`.
      class AccessDenied < Exception
        getter redirect_uri : String
        getter state : String?

        def initialize(@redirect_uri : String, @state : String?)
          super("access_denied")
        end
      end

      # ── Parameter parsing & validation ──────────────────────────────────

      # Parses the standard OAuth authorize params from a flat hash (works
      # for both query-string and form bodies). Raises `InvalidRequest` on
      # any malformed/missing input.
      def self.parse_params(
        client_id : String?,
        redirect_uri : String?,
        state : String?,
        code_challenge : String?,
        code_challenge_method : String?,
        scope : String?,
        resource : String? = nil,
      ) : Params
        client_id = require_present(client_id, "client_id")
        redirect_uri = require_present(redirect_uri, "redirect_uri")
        code_challenge = require_present(code_challenge, "code_challenge")
        if code_challenge_method != "S256"
          raise InvalidRequest.new("invalid_request",
            "'code_challenge_method' must be S256", 400)
        end

        Params.new(
          client_id: client_id,
          redirect_uri: redirect_uri,
          state: normalize_optional(state),
          code_challenge: code_challenge,
          scope: normalize_optional(scope),
          resource: normalize_optional(resource),
        )
      end

      # Returns the value when present and non-empty; raises `InvalidRequest`
      # otherwise. Used for required OAuth params. Delegates to the shared
      # `OAuth.require_present`.
      private def self.require_present(value : String?, name : String) : String
        OAuth.require_present(value, name)
      end

      # Returns the value when present and non-empty; nil otherwise. Used
      # for optional OAuth params (`state`, `scope`) that are absent vs. blank.
      private def self.normalize_optional(value : String?) : String?
        return nil if value.nil? || value.empty?
        value
      end

      # Loads the `app.App` projection by `client_id` and validates the
      # redirect_uri against the registered list — exact match, plus the
      # `*` loopback-port rule (`OAuth::RedirectUri.match?`). Raises
      # `InvalidRequest` if the app is missing, not `active`, or the
      # redirect_uri is not registered.
      def self.load_app(db : DB::Connection, params : Params) : App
        row = db.query_one?(
          <<-SQL,
            SELECT id, content
            FROM projections
            WHERE domain = 'app' AND doc_type = 'App'
              AND content->>'client_id' = $1
              AND deleted_at IS NULL
          SQL
          params.client_id,
        ) do |rs|
          {id: rs.read(String), content: rs.read(JSON::Any)}
        end
        # No echo of the submitted value beyond the error code: the value is
        # untrusted input. The description names the mistake instead — the
        # document id is not the client_id — and points at the surface that
        # shows the real value. A `register` (RFC 7591) client has no app.App
        # row at all: its valid branch is the MCP one, so the message names
        # it too (B-388). The contract is public — discovery and
        # doc/backend/oauth.md both carry it.
        raise InvalidRequest.new("invalid_client",
          "No app.App document matches this client_id; copy client_id from the app's Credentials screen, not the document id (or authorize through the MCP branch with resource=<base>/Api/_mcp/<role_slug>)", 400) unless row

        content = row[:content].as_h
        status = content["status"]?.try(&.as_s?) || "draft"
        unless status == "active"
          raise InvalidRequest.new("unauthorized_client",
            "App is not active (status=#{status})", 403)
        end

        redirect_uris = string_array(content["redirect_uris"]?)
        unless RedirectUri.match?(redirect_uris, params.redirect_uri)
          # Never redirect on redirect_uri mismatch — the target is
          # unvalidated. Render as an error.
          raise InvalidRequest.new("invalid_request",
            "redirect_uri does not match any registered URI", 400)
        end

        App.new(
          id: row[:id],
          client_id: params.client_id,
          slug: content["slug"]?.try(&.as_s?) || "",
          display_name: content["name"]?.try(&.as_s?) || "",
          description: content["description"]?.try(&.as_s?),
          redirect_uris: redirect_uris,
          allowed_origins: string_array(content["allowed_origins"]?),
          status: status,
        )
      end

      # ── Consent screen (GET /OAuth/authorize) ───────────────────────

      # Builds the consent screen data: the app metadata and, for every role
      # the account actually holds, whether it is usable for this app and (when
      # usable) its resolved `EffectiveScope`.
      #
      # Returns the screen even when no role is usable — the route will then
      # turn it into an `access_denied` redirect. This keeps the screen's
      # contract stable and lets the frontend show "no eligible role" when
      # the account reaches the endpoint manually.
      def self.build_consent(
        db : DB::Connection,
        account_id : String,
        params : Params,
      ) : ConsentScreen
        app = load_app(db, params)
        app_scope = RBAC::AppScope.from_content(app.id,
          JSON.parse(%({"grants": #{content_grants_or_empty(db, app.id)}})))

        account = IAM::Helpers.find_account_by_id(db, account_id)
        raise InvalidRequest.new("invalid_request", "Unknown account", 400) unless account

        usable = [] of UsableRole
        account[:roles].each do |role_id|
          role_content = IAM::Helpers.find_role_content(db, role_id)
          next unless role_content
          active_role = RBAC::ActiveRole.from_projection_content(role_content)
          next unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
          effective = RBAC::GrantResolver.resolve(app_scope, active_role)
          next if effective.empty?
          display_name = role_content["description"]?.try(&.as_s?)
          usable << UsableRole.new(
            role_id: role_id,
            display_name: display_name,
            effective_scope: effective,
          )
        end

        ConsentScreen.new(
          app: app,
          roles: usable,
          params: params,
          requested_scope: params.scope,
        )
      end

      # ── Code issuance (POST /OAuth/authorize) ───────────────────

      # Validates the election shared by both issuance branches: the account
      # must exist, must hold the elected role, and the role projection
      # must still be live. Raises `InvalidRequest` for an unknown account
      # and `AccessDenied` (redirect-eligible) when the role is not held
      # or has vanished. Returns the role content for branch-specific
      # grant checks.
      private def self.validate_election(
        db : DB::Connection,
        account_id : String,
        params : Params,
        elected_role : String,
      ) : JSON::Any
        account = IAM::Helpers.find_account_by_id(db, account_id)
        raise InvalidRequest.new("invalid_request", "Unknown account", 400) unless account
        raise AccessDenied.new(params.redirect_uri, params.state) unless account[:roles].includes?(elected_role)

        role_content = IAM::Helpers.find_role_content(db, elected_role)
        unless role_content
          # The role disappeared between GET and POST. Treat as access_denied
          # (redirect) — the account's state is genuinely not eligable anymore.
          raise AccessDenied.new(params.redirect_uri, params.state)
        end

        role_content
      end

      # The inputs one code issuance shares across both authorize branches:
      # the elected consent plus the app binding and the audit attribution.
      # The MCP branch leaves `app` nil and sets `resource` / `mcp_role`.
      record Issuance,
        account_id : String,
        params : Params,
        elected_role : String,
        app_id : String,
        client_id : String,
        event_detail : String,
        app : String?,
        resource : String? = nil,
        mcp_role : String? = nil

      # Issues the code, writes the `consent_granted` audit event, and
      # builds the response. `app_id` is the app the code is bound to
      # ("" on the MCP branch). `app` on the audit event is nil on the
      # MCP branch — the MCP story is told by origin attribution in
      # mutations.meta, not by LoginEvent.app.
      private def self.issue_and_record(db : DB::Connection, iss : Issuance) : IssuedCode
        code = CodeStore.issue(
          account_id: iss.account_id,
          role_id: iss.elected_role,
          app_id: iss.app_id,
          client_id: iss.client_id,
          redirect_uri: iss.params.redirect_uri,
          code_challenge: iss.params.code_challenge,
          resource: iss.resource,
          mcp_role: iss.mcp_role,
        )
        IAM::Helpers.write_login_event(db, iss.account_id, "consent_granted", iss.event_detail, app: iss.app)
        IssuedCode.new(
          code: code,
          redirect_uri: iss.params.redirect_uri,
          state: iss.params.state,
          app_id: iss.app_id,
          role_id: iss.elected_role,
        )
      end

      # Issues an authorization code after the account has elected a role on
      # the consent screen. Validates the elected role is one of the usable
      # candidates (the account cannot self-escalate to a role they don't hold
      # or that fails the app's required actions), then delegates to
      # `CodeStore.issue`.
      #
      # A `consent_granted` `iam.LoginEvent` is written with app
      # attribution so an admin can answer "who authorized this app, under
      # which role, when" from the audit log alone.
      def self.issue_code(
        db : DB::Connection,
        account_id : String,
        params : Params,
        elected_role : String,
      ) : IssuedCode
        app = load_app(db, params)

        role_content = validate_election(db, account_id, params, elected_role)

        app_scope = RBAC::AppScope.from_content(app.id,
          JSON.parse(%({"grants": #{content_grants_or_empty(db, app.id)}})))
        active_role = RBAC::ActiveRole.from_projection_content(role_content)
        unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
          raise AccessDenied.new(params.redirect_uri, params.state)
        end

        issue_and_record(db, Issuance.new(
          account_id: account_id,
          params: params,
          elected_role: elected_role,
          app_id: app.id,
          client_id: app.client_id,
          event_detail: "Role: #{elected_role} | App: #{app.slug}",
          app: app.id,
        ))
      end

      record IssuedCode,
        code : String,
        redirect_uri : String,
        state : String?,
        app_id : String,
        role_id : String

      # ── MCP branch ──────────────────────────────────────────────────

      # Builds the consent screen for the MCP branch of the authorize flow.
      # Skips `app.App` loading and `GrantResolver` entirely (decision D5):
      # MCP is not an app, so no grant intersection applies. Every role the
      # account holds is a candidate; the pinned `role` parameter narrows the
      # screen to it when present.
      #
      # `redirect_origin` is displayed on the consent screen as part of what
      # the account approves ("this will redirect to …") — the phase-1 control
      # for authorization-code solicitation.
      def self.build_mcp_consent(
        db : DB::Connection,
        account_id : String,
        params : Params,
        role : String?,
        redirect_origin : String,
      ) : MCPScreen
        account = IAM::Helpers.find_account_by_id(db, account_id)
        raise InvalidRequest.new("invalid_request", "Unknown account", 400) unless account

        if role
          # A value that names no role document is a malformed request, not a
          # consent denial (B-157) — the client likely derived it from a stale
          # or hand-built resource URL. Answer `invalid_request` so the client
          # can fix the value. `access_denied` stays for a real role the
          # account does not hold.
          role_content = IAM::Helpers.find_role_content(db, role)
          unless role_content
            # B-201: the 400 names the required shape — bare role names are
            # ambiguous across domains, the parameter always carries the
            # qualified projection id.
            raise InvalidRequest.new("invalid_request",
              "Unknown role '#{role}' — the role parameter is the qualified role id, e.g. `iam.Roles.admin`", 400)
          end
          unless account[:roles].includes?(role)
            # No silent fallback to default_role — reject outright.
            raise InvalidRequest.new("access_denied",
              "User does not hold the requested role '#{role}'", 403)
          end
          # A role whose connectivity excludes `mcp` cannot open the MCP
          # channel at all — the pinned screen denies with the same shape
          # as an unheld role.
          channels = role_content["connectivity"]?.try(&.as_a?)
          mcp_ok = channels.try(&.any?(&.as_s?.try(&.==("mcp")))) == true
          unless mcp_ok
            raise InvalidRequest.new("access_denied",
              "Role '#{role}' does not exist or is not usable", 403)
          end
        end

        roles = mcp_usable_roles(db, account[:roles])
        unless roles.empty?
          held_ids = roles.map(&.role_id)
          if role && !held_ids.includes?(role)
            raise InvalidRequest.new("access_denied",
              "Role '#{role}' does not exist or is not usable", 403)
          end
        end

        MCPScreen.new(
          resource: required_resource(params),
          roles: roles,
          pinned_role: role,
          redirect_origin: redirect_origin,
          params: params,
        )
      end

      # Issues an authorization code on the MCP branch after consent.
      # Validates the elected role against the account's held roles (no silent
      # fallback), records `resource` + `mcp_role` into the code so the token
      # endpoint can bind `aud` without re-running app machinery.
      def self.issue_mcp_code(
        db : DB::Connection,
        account_id : String,
        params : Params,
        elected_role : String,
      ) : IssuedCode
        raise InvalidRequest.new("invalid_request", "Missing 'resource'", 400) if params.resource.nil?
        resource = params.resource.as(String)

        role_content = validate_election(db, account_id, params, elected_role)

        # The MCP branch is a connectivity channel: a role whose
        # `connectivity` list excludes `mcp` cannot elect into an MCP code.
        # Same denial shape as a role the account does not hold — a real
        # consent denial, not a malformed request. The gate lives here, not
        # in `validate_election`: delegated app tokens are never gated by
        # the field (see `doc/backend/oauth.md`).
        channels = role_content["connectivity"]?.try(&.as_a?)
        mcp_ok = channels.try(&.any?(&.as_s?.try(&.==("mcp")))) == true
        raise AccessDenied.new(params.redirect_uri, params.state) unless mcp_ok

        # The URL pins the role: dispatch compares the token's `role` claim
        # against the `:role_slug` in the URL the token's `aud` points at, so
        # a code electing a role other than the resource names could only
        # mint a dead token. Runs after `validate_election` — a role the
        # account does not hold stays a redirect-eligible `access_denied`;
        # this gate is for an account that holds two roles and elects the
        # wrong one for this resource.
        resource_slug = MCP::ProtectedResource.role_slug_from_resource(resource)
        if resource_slug && resource_slug != elected_role
          raise InvalidRequest.new("invalid_request",
            "Role '#{elected_role}' does not match the requested resource", 403)
        end

        # `app` stays nil on MCP events — the MCP story is told by origin
        # attribution in mutations.meta, not by LoginEvent.app.
        issue_and_record(db, Issuance.new(
          account_id: account_id,
          params: params,
          elected_role: elected_role,
          app_id: "",
          client_id: params.client_id,
          event_detail: "Role: #{elected_role} | Resource: #{resource}",
          app: nil,
          resource: resource,
          mcp_role: elected_role,
        ))
      end

      # The MCP consent screen payload. `roles` lists every role the account
      # holds (each with its live effective scope for display); when the
      # request pins a role, `pinned_role` names it and the UI pre-elects it.
      record MCPScreen,
        resource : String,
        roles : Array(UsableRole),
        pinned_role : String?,
        redirect_origin : String,
        params : Params

      # Resolves every held role into a `UsableRole` without any app-scope
      # intersection — the role's own permission map is authoritative (the
      # narrowing-selector invariant).
      private def self.mcp_usable_roles(db : DB::Connection, held_roles : Array(String)) : Array(UsableRole)
        held_roles.compact_map do |role_id|
          role_content = IAM::Helpers.find_role_content(db, role_id)
          next nil unless role_content
          active_role = RBAC::ActiveRole.from_projection_content(role_content)
          display_name = role_content["description"]?.try(&.as_s?)
          UsableRole.new(
            role_id: role_id,
            display_name: display_name,
            effective_scope: RBAC::EffectiveScope.from_active_role(active_role),
          )
        end
      end

      private def self.required_resource(params : Params) : String
        raise InvalidRequest.new("invalid_request", "Missing 'resource'", 400) if params.resource.nil?
        params.resource.as(String)
      end

      # ── Internals ──────────────────────────────────────────────────────

      # Loads the `grants` array (or empty JSON array) from the app
      # projection. COALESCE maps an absent `grants` key to `[]` — the key is
      # optional on `app.App`, and a SQL NULL column fails the JSON::Any read
      # (B-270). Tolerates the Lua-round-trip empty-Hash quirk on `app.App`
      # documented in `doc/backend/app-system.md` → Quirks. Shared with the
      # token endpoint (`OAuth::Token`), which re-resolves the grant at
      # redemption time.
      def self.content_grants_or_empty(db : DB::Connection, app_id : String) : String
        row = db.query_one?(
          "SELECT COALESCE(content->'grants', '[]'::jsonb) FROM projections WHERE id = $1 AND deleted_at IS NULL",
          app_id,
          as: JSON::Any,
        )
        return "[]" if row.nil?
        case row.raw
        when Array then row.to_json
        when Hash  then row.as_h.empty? ? "[]" : row.to_json
        else            "[]"
        end
      end

      private def self.string_array(raw : JSON::Any?) : Array(String)
        return [] of String if raw.nil?
        case raw.raw
        when Array
          raw.as_a.compact_map(&.as_s?)
        else
          [] of String
        end
      end
    end
  end
end
