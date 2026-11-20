# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "base64"
require "../database"
require "../config"
require "../mutation/client"
require "../event"
require "../http/helpers"
require "../fiber_state"
require "../assistant/access"
require "../assistant/app/gate"
require "../system_settings"
require "../util/client_ip"
require "../util/time_helper"
require "./policy"
require "./oidc/providers"

module Facet
  module IAM
    # HTTP routes for the IAM subsystem.
    #
    # All routes are under `/Api/iam`. State-changing requests require an
    # `X-Requested-With` header (CSRF defense for cookie auth) — enforced by
    # `HTTP::Helpers.require_csrf` with the API-key-bearer bypass. A rejected
    # request answers `403` with the shared JSON error body.
    module Routes
      # Registers all IAM routes on the Kemal router. Grouped by concern —
      # one private method per group, each holding only the route
      # declarations. Each route block calls one `handle_*` method that
      # holds the endpoint body.
      def self.register : Nil
        register_session_routes
        register_profile_routes
        register_api_key_routes
        register_account_admin_routes
        register_mfa_routes
        register_password_routes
        register_session_admin_routes
      end

      # ── Login / challenge / refresh / logout ────────────────────────────

      private def self.register_session_routes : Nil
        post "/Api/iam/login" do |env|
          handle_login(env)
        end
        post "/Api/iam/challenge" do |env|
          handle_challenge(env)
        end
        post "/Api/iam/refresh" do |env|
          handle_refresh(env)
        end
        post "/Api/iam/logout" do |env|
          handle_logout(env)
        end
      end

      # ── POST /Api/iam/login ───────────────────────────────────────────
      private def self.handle_login(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        email = require_field(env, parsed, "email") || return
        password = require_field(env, parsed, "password") || return
        cookie = parsed["cookie"]?.try(&.as_bool?) != false
        role = parsed["role"]?.try(&.as_s?)

        result = Database.with_db do |db|
          Facet::IAM::Login.call(
            db,
            email: email,
            password: password,
            cookie: cookie,
            role: role,
            ip: Facet::Util::ClientIp.resolve(env.request.headers, env.request.remote_address, Facet::Config.instance.trusted_proxies),
            user_agent: env.request.headers["User-Agent"]?,
          )
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Login::TokensEmitted
          emit_http_response(env, result.result, cookie)
        in Facet::IAM::Login::MFARequired
          Facet::HTTP::Helpers.write_json(env, 200, {mfa: true, challenge_id: result.challenge_id, type: "totp"})
        in Facet::IAM::Login::EnrollmentRequired
          enforcement = Database.with_db do |db|
            Facet::IAM::Policy.mfa_enforcement(db)
          end
          Facet::HTTP::Helpers.write_json(env, 200, {mfa_enroll_required: true, enroll_token: result.enroll_token,
                                                     secret: result.secret, otpauth_uri: result.otpauth_uri,
                                                     mfa_enforcement: enforcement})
        in Facet::IAM::Login::PasswordChangeRequired
          Facet::HTTP::Helpers.write_json(env, 200, {must_change_password: true, change_token: result.change_token})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/challenge ───────────────────────────────────────
      private def self.handle_challenge(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        challenge_id = require_field(env, parsed, "challenge_id") || return
        code = require_field(env, parsed, "result") || return
        method = parsed["method"]?.try(&.as_s?) || "totp"
        unless method == "totp" || method == "backup_code"
          return Facet::HTTP::Helpers.error_response(env, 422, "Unknown challenge method")
        end

        result = Database.with_db do |db|
          Facet::IAM::Challenge.call(db, challenge_id, code, method)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Challenge::TokensEmitted
          emit_http_response(env, result.result, result.result.cookie)
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/refresh ────────────────────────────────────────
      private def self.handle_refresh(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return

        # Get the refresh token from body or cookie
        refresh_token = parsed["refresh_token"]?.try(&.as_s?) ||
                        env.request.cookies["refresh_token"]?.try(&.value)
        if refresh_token.nil? || refresh_token.empty?
          return Facet::HTTP::Helpers.error_response(env, 401, "Missing refresh token")
        end

        role = parsed["role"]?.try(&.as_s?)
        cookie = parsed["cookie"]?.try(&.as_bool?) != false

        result = Database.with_db do |db|
          Facet::IAM::Refresh.call(
            db,
            refresh_token: refresh_token,
            role: role,
            cookie: cookie,
          )
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Refresh::TokensEmitted
          emit_http_response(env, result.result, cookie)
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/logout ────────────────────────────────────────
      private def self.handle_logout(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        # Extract session_id from the access token cookie or Authorization header
        session_id = extract_session_id(env)

        if session_id
          Database.with_db { |db| Facet::IAM::Logout.call(db, session_id) }
        end
        Event::Publisher.flush

        # Clear cookies
        env.response.cookies << ::HTTP::Cookie.new("auth_token", "", path: "/", expires: Time.utc(2000, 1, 1))
        env.response.cookies << ::HTTP::Cookie.new("refresh_token", "", path: "/", expires: Time.utc(2000, 1, 1))

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
      end

      # ── Profile reads (me, apps, SSO providers) ─────────────────────────

      private def self.register_profile_routes : Nil
        get "/Api/iam/me" do |env|
          handle_me(env)
        end
        get "/Api/iam/apps" do |env|
          handle_apps(env)
        end
        get "/Api/iam/oidc/providers" do |env|
          handle_oidc_providers(env)
        end
      end

      # ── GET /Api/iam/me ─────────────────────────────────────────
      #
      # Returns the authenticated account's profile, token expiration,
      # permission manifest, and assistant availability. Used by the
      # frontend's universal layout load to build the sidebar nav model
      # (filtered by RBAC) and to gate the assistant dock on real data.
      #
      # The permission manifest follows the credential. A session caller
      # gets the active role's manifest. An app-scoped caller — an app
      # token (`typ: "app"`) or an app-owned API key — gets the effective
      # scope instead (`AuthContext#app_grant`, the grant ∩ role
      # intersection `AuthHandler` resolves per request): from the app's
      # perspective, a document its grant does not name does not exist, so
      # the manifest lists only the granted doctypes, with the
      # `{key}.except.{action}` carve-outs folded per key. The `assistant`
      # block for an app-scoped caller is the AND of the role's
      # `assistant_access` and the app's own `assistant_enabled` flag — the
      # same gate `Assistant::App::Gate` applies on the conversation create
      # route.
      #
      # The identity comes from the request's auth context, so both
      # authentication channels answer: a browser session (JWT cookie or
      # Bearer) and a static API key (`Bearer fct_…`, B-136). A session
      # caller also gets `expires_at` (the access token's `exp` claim); a
      # key caller has no token to expire, so the field reads null. The
      # `channel` field names the channel that served the request:
      # `"api"` for a key-authenticated (or otherwise machine-scoped)
      # principal, `"session"` for a plain browser session.
      #
      # Protected by AuthHandler — a 401 is returned automatically if the
      # access token is missing or invalid.
      private def self.handle_me(env) : Nil
        caller = require_caller(env) || return
        account_id = caller[:account_id]

        result = Database.with_db(:read_only) do |db|
          account = Facet::IAM::Helpers.find_account_by_id(db, account_id)
          if account.nil?
            nil
          else
            # The wire `active_role` is the qualified role reference
            # (`iam.Roles.admin`): the refresh response, the role-switch
            # request, and `find_role_content` all speak that form. Prefer
            # the access token's `role` claim — the exact reference the
            # login minted. A key caller carries no token, so the reference
            # is recovered from the account's assignment (see
            # `resolve_active_role_ref`).
            active_role = caller[:token_role] ||
                          resolve_active_role_ref(db, account[:roles], caller[:role_name])
            expires_at = extract_expires_at(env)
            role_content = active_role ? Facet::IAM::Helpers.find_role_content(db, active_role) : nil
            manifest = me_manifest(role_content, caller[:context].app_grant)
            # The active role's field-tag visibility set (B-176). Loaded from
            # the same content the manifest just consumed — no extra query.
            visible_tags = Facet::IAM::Helpers.build_visible_tags(role_content)
            core_settings = Facet::Settings::Service.get(db, account_id, Facet::Settings::CORE_APP)
            # Asymmetric by design: `access` rides the one active role (the
            # content is already loaded for the manifest — one role query),
            # while `token_budget` stays the account-wide MAX over held
            # roles (`Assistant::Access`). A missing role projection fails
            # closed.
            assistant_access = me_assistant_access(db, role_content, caller[:context].app_id)
            assistant_budget = Facet::Assistant::Access.effective_budget(db, account_id)
            assistant_name = Facet::SystemSettings::AssistantView.display_name(db)
            # Whether an API key resolves (sealed settings slot, then the
            # file's `!env?` value). Independent of the role gate: `access`
            # asks what the role may open, `configured` asks whether the
            # installation has a provider at all. `false` keeps the dock
            # visible but disables conversation creation client-side.
            assistant_configured = Facet::SystemSettings::AssistantView.configured?(db)
            # The active role's connectivity list — the same array the
            # assistant gate reads. The frontend hides the affordances the
            # channels govern (Settings → API keys, the assistant dock is
            # already gated on `assistant.access`). A missing role reads as
            # an empty list.
            connectivity = role_content.try(&.["connectivity"]?.try(&.as_a?).try(&.compact_map(&.as_s?))) || [] of String
            mfa_enforcement = Facet::IAM::Policy.mfa_enforcement(db)
            mfa_type = Facet::IAM::Policy.mfa_type(db)
            {
              account:      account,
              expires_at:   expires_at,
              permissions:  manifest[:permissions],
              scopes:       manifest[:scopes],
              active_role:  active_role,
              settings:     core_settings,
              assistant:    {access: assistant_access, configured: assistant_configured, token_budget: assistant_budget, name: assistant_name},
              connectivity: connectivity,
              enforcement:  mfa_enforcement,
              factor_type:  mfa_type,
              visible_tags: visible_tags,
              channel:      caller[:channel],
            }
          end
        end

        if result.nil?
          return Facet::HTTP::Helpers.error_response(env, 401, "Account not found")
        end

        response = {
          account: {
            id:              result[:account][:id],
            display_name:    result[:account][:display_name],
            email:           result[:account][:email],
            mfa_enabled:     result[:account][:mfa_enabled],
            mfa_enforcement: result[:enforcement],
            mfa_type:        result[:factor_type],
          },
          active_role:     result[:active_role],
          available_roles: result[:account][:roles],
          expires_at:      result[:expires_at],
          assistant:       result[:assistant],
          connectivity:    result[:connectivity],
          channel:         result[:channel],
        }
        if perms = result[:permissions]
          response = response.merge({permissions: perms})
        end
        if scopes = result[:scopes]
          response = response.merge({scopes: scopes})
        end
        if tags = result[:visible_tags]
          response = response.merge({visible_tags: tags})
        end
        response = response.merge({settings: result[:settings]})

        Facet::HTTP::Helpers.write_json(env, 200, response)
      end

      # The `/Api/iam/me` permission manifest follows the credential: an
      # app-scoped caller (an app token, an app-owned API key) reads the
      # resolved grant ∩ role — the app sees only the doctypes its grant
      # reaches, a document outside the grant does not exist for it — and
      # every other caller reads the active role's own manifest.
      private def self.me_manifest(
        role_content : JSON::Any?,
        app_grant : Facet::RBAC::EffectiveScope?,
      ) : NamedTuple(permissions: Hash(String, Array(String))?, scopes: Hash(String, Hash(String, Array(String)))?)
        return Facet::IAM::Helpers.build_effective_manifest(app_grant) if app_grant
        role_content ? Facet::IAM::Helpers.build_permission_manifest(role_content) : {permissions: nil, scopes: nil}
      end

      # The `/Api/iam/me` assistant availability. The role flag decides for
      # every caller; an app-scoped caller answers to the app's own
      # `assistant_enabled` flag too — the same AND
      # `Assistant::App::Gate.allowed?` applies on the conversation create
      # route. The token already names the app, so only the flag remains; a
      # missing app row fails closed.
      private def self.me_assistant_access(
        db : DB::Connection,
        role_content : JSON::Any?,
        app_id : String?,
      ) : Bool
        access = role_content ? Facet::Assistant::Access.role_enabled?(role_content) : false
        return false if app_id && !access
        return access unless app_id

        app_content = Facet::Assistant::App::Gate.load_app(db, app_id)
        app_content.try(&.["assistant_enabled"]?).try(&.as_bool?) == true
      end

      # ── GET /Api/iam/apps ───────────────────────────────────────────
      #
      # Returns the `app.App` registrations for the dashboard launcher list.
      # Every active app is listed (`AppLauncher.launcher_apps`) — client
      # type does not filter, and `no_launcher` hides a headless
      # registration. `usable` is false when the active role does not
      # satisfy every required grant action. The dashboard shows that card
      # in a disabled state with a notice.
      #
      # AuthHandler-protected: a 401 is returned automatically if the
      # access token is missing or invalid.
      private def self.handle_apps(env) : Nil
        Facet::HTTP::Helpers.require_account(env) || return
        active_role = require_role(env) || return

        apps = Database.with_db(:read_only) do |db|
          Facet::IAM::AppLauncher.launcher_apps(db, active_role)
        end

        payload = apps.map do |a|
          entry = {
            id:           a.id,
            slug:         a.slug,
            display_name: a.display_name,
            usable:       a.usable,
          }
          desc = a.description
          desc.nil? ? entry : entry.merge({description: desc})
        end

        Facet::HTTP::Helpers.write_json(env, 200, payload)
      end

      # ── GET /Api/iam/oidc/providers ────────────────────────────
      # Public: the login page fetches the SSO button list before any
      # session exists (exact entry in `AuthHandler::PUBLIC_ROUTES`).
      # The body carries the authentication mode next to the provider
      # list so one pre-auth read gates the whole page: under
      # `oidc_only` the password form and the reset link do not render.
      # Display names only — issuer, client id, and secret never leave
      # the server.
      private def self.handle_oidc_providers(env) : Nil
        result = Database.with_db(:read_only) do |db|
          {auth_mode: Facet::IAM::Policy.auth_mode(db), providers: Facet::IAM::OIDC::Providers.summaries(db)}
        end
        Facet::HTTP::Helpers.write_json(env, 200, result)
      end

      # ── API keys ───────────────────────────────────────────────────────

      private def self.register_api_key_routes : Nil
        post "/Api/iam/keys" do |env|
          handle_create_key(env)
        end
        get "/Api/iam/keys" do |env|
          handle_list_keys(env)
        end
        delete "/Api/iam/keys/:key_id" do |env|
          handle_delete_key(env)
        end
      end

      # ── POST /Api/iam/keys ─────────────────────────────────────────────
      #
      # Creates an API key for the caller. Self-service: the account id
      # comes from the auth context, never from the URL or body. The pair
      # {account, role} is fixed at creation — the role must already be
      # assigned to the caller. The raw key is returned exactly once.
      private def self.handle_create_key(env) : Nil
        body = guard(env) || return
        account_id = require_account_id(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return

        params = validate_key_params(env, parsed) || return

        result = create_key_result(account_id, params[:role], params[:name], params[:expires_at])
        Event::Publisher.flush

        case result
        in Facet::ServiceError
          error_response(env, result)
        in Facet::IAM::ApiKey::Created
          Facet::HTTP::Helpers.write_json(env, 201, {
            id:             result.id,
            key:            result.key,
            display_prefix: result.display_prefix,
            expires_at:     result.expires_at,
          })
        end
      end

      # Validates the create-key payload. Writes the 422 error and returns
      # `nil` when validation fails. Returns the name, the role, and the
      # normalized expiry.
      private def self.validate_key_params(env, parsed : Hash(String, JSON::Any)) : NamedTuple(name: String, role: String, expires_at: String?)?
        name = require_field(env, parsed, "name") || return nil
        role = require_field(env, parsed, "role") || return nil

        if name.empty? || name.size > Facet::IAM::ApiKey::NAME_MAX_LENGTH
          Facet::HTTP::Helpers.error_response(env, 422,
            "'name' must be between 1 and #{Facet::IAM::ApiKey::NAME_MAX_LENGTH} characters")
          return nil
        end

        # Optional expiry — normalized to UTC RFC-3339 per the project time
        # rule. Past dates are rejected.
        expires_at = nil
        if raw_expires = parsed["expires_at"]?.try(&.as_s?)
          normalized = Facet::Util::TimeHelper.to_utc_rfc3339(raw_expires)
          if normalized.nil?
            Facet::HTTP::Helpers.error_response(env, 422,
              "'expires_at' is not a valid ISO-8601 datetime")
            return nil
          end
          expires_time = Time.parse_iso8601(normalized)
          if expires_time <= Time.utc
            Facet::HTTP::Helpers.error_response(env, 422,
              "'expires_at' must be in the future")
            return nil
          end
          expires_at = normalized
        end

        {name: name, role: role, expires_at: expires_at}
      end

      # Creates the key in one database scope. Returns the created key, or
      # the service error naming the real cause: a role reference that is not
      # qualified, a role the account does not hold, a role that does not
      # exist, or a role whose connectivity excludes the `api` channel.
      private def self.create_key_result(account_id : String, role : String, name : String, expires_at : String?) : Facet::IAM::ApiKey::Created | Facet::ServiceError
        Database.with_db do |db|
          # Shape first: a bare name is a syntax problem, whatever the caller holds.
          unless role.starts_with?("iam.Roles.")
            next Facet::ServiceError.new(422,
              "role must be a fully-qualified role reference (iam.Roles.{name})")
          end

          account = Facet::IAM::Helpers.find_account_by_id(db, account_id)
          unless account && account[:roles].includes?(role)
            next Facet::ServiceError.new(422,
              "Role '#{role}' is not assigned to this account — assign it first, then create the key")
          end

          role_content = Facet::IAM::Helpers.find_role_content(db, role)
          unless role_content
            next Facet::ServiceError.new(422, "Role '#{role}' does not exist")
          end

          # The pinned role must open the `api` channel (connectivity).
          # Fail closed: a role without the field carries no channels.
          channels = role_content["connectivity"]?.try(&.as_a?)
          api_ok = channels.try(&.any?(&.as_s?.try(&.==("api")))) == true
          unless api_ok
            next Facet::ServiceError.new(422,
              "The role's connectivity excludes the 'api' channel — enable it on the role first")
          end

          created = Facet::IAM::ApiKey.generate(db, account_id, role, name, expires_at)
          Facet::IAM::Helpers.write_login_event(db, account_id, "api_key_created",
            "Name=#{name} Role=#{role} Prefix=#{created.display_prefix}")
          created
        end
      end

      # ── GET /Api/iam/keys ──────────────────────────────────────────────
      #
      # Lists the caller's keys. Never exposes the secret — only the
      # display prefix identifies a key.
      private def self.handle_list_keys(env) : Nil
        account_id = require_account_id(env) || return

        keys = Database.with_db(:read_only) do |db|
          Facet::IAM::ApiKey.list(db, account_id)
        end

        Facet::HTTP::Helpers.write_json(env, 200, keys.map do |row|
          {
            id:             row.id,
            name:           row.name,
            display_prefix: row.display_prefix,
            role_id:        row.role_id,
            created_at:     row.created_at.to_rfc3339,
            expires_at:     row.expires_at.try(&.to_rfc3339),
            last_used_at:   row.last_used_at.try(&.to_rfc3339),
            revoked_at:     row.revoked_at.try(&.to_rfc3339),
          }
        end)
      end

      # ── DELETE /Api/iam/keys/:id ───────────────────────────────────────
      #
      # Soft-revokes one of the caller's keys. Idempotent: a repeated
      # delete on an already-revoked key still returns 200. The caller
      # must own the key — a missing or foreign key is a non-disclosing
      # 404.
      private def self.handle_delete_key(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        account_id = require_account_id(env) || return
        key_id = Facet::HTTP::Helpers.require_path_param(env, "key_id") || return

        result = Database.with_db do |db|
          row = Facet::IAM::ApiKey.find_owned(db, account_id, key_id)
          unless row
            next nil
          end

          # Idempotent: a second delete on an already-revoked key is still
          # 200; only the first revoke writes the lifecycle event.
          revoked_now = Facet::IAM::ApiKey.revoke(db, account_id, key_id)
          if revoked_now
            Facet::IAM::Helpers.write_login_event(db, account_id, "api_key_revoked",
              "Name=#{row.name} Key=#{row.id}")
          end
          {revoked: revoked_now}
        end
        Event::Publisher.flush

        unless result
          return Facet::HTTP::Helpers.error_response(env, 404, "Not found")
        end

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
      end

      # ── Operator account administration ────────────────────────────────

      private def self.register_account_admin_routes : Nil
        post "/Api/iam/accounts/:id/temporary-password" do |env|
          handle_temporary_password(env)
        end
        post "/Api/iam/accounts/:id/invite" do |env|
          handle_invite(env)
        end
        get "/Api/iam/accounts/credential-states" do |env|
          handle_credential_states(env)
        end
      end

      # ── POST /Api/iam/accounts/:id/temporary-password ────────────────
      #
      # Operator action: generate a temporary password for an invited
      # account. The plaintext is returned exactly once — never stored,
      # emailed, or logged. Gate chain mirrors `mfa_disable`: CSRF check,
      # AuthHandler, `provision_credentials` on `iam.Account`, system
      # bypass rejected.
      private def self.handle_temporary_password(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        ac = authorize(env, "provision_credentials", "iam.Account") || return
        Facet::HTTP::Helpers.require_account(env) || return
        account_id = Facet::HTTP::Helpers.require_path_param(env, "id") || return

        result = Database.with_db do |db|
          Facet::IAM::Invite.generate_temporary_password(db, account_id, set_by: ac.account_id)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Invite::Generated
          Facet::HTTP::Helpers.write_json(env, 200, {temporary_password: result.password})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/accounts/:id/invite ────────────────────────────
      #
      # Operator action: email a single-use invite link. A second invite
      # replaces the pending link, so the previous email dies. Gate chain
      # mirrors `mfa_disable`.
      private def self.handle_invite(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        ac = authorize(env, "provision_credentials", "iam.Account") || return
        Facet::HTTP::Helpers.require_account(env) || return
        account_id = Facet::HTTP::Helpers.require_path_param(env, "id") || return

        result = Database.with_db do |db|
          Facet::IAM::Invite.send_invite(db, account_id, set_by: ac.account_id)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Invite::InviteSent
          Facet::HTTP::Helpers.write_json(env, 200, {ok: true, first_invite: result.first_invite})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── GET /Api/iam/accounts/credential-states ──────────────────────
      #
      # Operator read for the account admin table: one credential-state
      # entry per `id` query parameter. Gate chain mirrors `mfa_disable`
      # (minus the CSRF check — a GET carries no state change).
      private def self.handle_credential_states(env) : Nil
        authorize(env, "provision_credentials", "iam.Account") || return
        Facet::HTTP::Helpers.require_account(env) || return

        # Accepts repeated `id` parameters and comma-joined values. The
        # grammar matches the list `select` parameter.
        account_ids = env.request.query_params.fetch_all("id")
          .flat_map(&.split(','))
          .map(&.strip)
          .reject(&.empty?)
        if account_ids.empty?
          return Facet::HTTP::Helpers.error_response(env, 422, "Missing 'id' query parameter")
        end

        states = Database.with_db(:read_only) do |db|
          Facet::IAM::Invite.credential_states(db, account_ids)
        end

        Facet::HTTP::Helpers.write_json(env, 200, {states: states.map do |s|
          {
            id:             s.id,
            has_password:   s.has_password,
            must_change_pw: s.must_change_pw,
            mfa_enabled:    s.mfa_enabled,
            invite_pending: s.invite_pending,
            federated:      s.federated,
          }
        end})
      end

      # ── MFA ────────────────────────────────────────────────────────────

      private def self.register_mfa_routes : Nil
        post "/Api/iam/mfa/totp/setup" do |env|
          handle_mfa_setup(env)
        end
        post "/Api/iam/mfa/totp/verify" do |env|
          handle_mfa_verify(env)
        end
        post "/Api/iam/mfa/enroll/verify" do |env|
          handle_mfa_enroll_verify(env)
        end
        post "/Api/iam/mfa/disable" do |env|
          handle_mfa_disable(env)
        end
      end

      # ── POST /Api/iam/mfa/totp/setup ─────────────────────────────
      private def self.handle_mfa_setup(env) : Nil
        body = guard(env) || return
        account_id = Facet::HTTP::Helpers.require_account(env) || return

        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        account_name = parsed["account"]?.try(&.as_s?) || account_id

        result = Database.with_db do |db|
          Facet::IAM::MFA.setup(db, account_id, account_name)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::MFA::SetupResult
          Facet::HTTP::Helpers.write_json(env, 200, {secret: result.secret, otpauth_uri: result.otpauth_uri})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/mfa/totp/verify ────────────────────────────────
      private def self.handle_mfa_verify(env) : Nil
        body = guard(env) || return
        account_id = Facet::HTTP::Helpers.require_account(env) || return

        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        code = require_field(env, parsed, "code") || return

        result = Database.with_db do |db|
          Facet::IAM::MFA.verify(db, account_id, code)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::MFA::VerifyResult
          Facet::HTTP::Helpers.write_json(env, 200,
            {ok: true, mfa_enabled: true, backup_codes: result.backup_codes})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/mfa/enroll/verify ──────────────────────────────
      #
      # Completes the enroll-at-login flow (MFA enforcement `always`).
      # Public — no session exists yet; the one-shot enroll token returned
      # by the login branch is the authorization. CSRF-checked like every
      # state-changing route.
      private def self.handle_mfa_enroll_verify(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        enroll_token = require_field(env, parsed, "enroll_token") || return
        code = require_field(env, parsed, "code") || return

        result = Database.with_db do |db|
          Facet::IAM::Enroll.verify(db, enroll_token, code)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::Enroll::TokensEmitted
          emit_http_response(env, result.result, result.result.cookie, result.backup_codes)
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── POST /Api/iam/mfa/disable ────────────────────────────────────
      private def self.handle_mfa_disable(env) : Nil
        body = guard(env) || return
        Facet::HTTP::Helpers.require_account(env) || return

        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        target_account_id = require_field(env, parsed, "account_id") || return

        # RBAC gate: authorize via mfa_disable action on iam.Account.
        # System bypass is rejected — this is a user-facing admin action.
        authorize(env, "mfa_disable", "iam.Account") || return

        result = Database.with_db do |db|
          Facet::IAM::MFA.disable(db, target_account_id)
        end
        Event::Publisher.flush

        case result
        in Nil
          Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── Password change / reset ────────────────────────────────────────

      private def self.register_password_routes : Nil
        post "/Api/iam/change-password" do |env|
          handle_change_password(env)
        end
        post "/Api/iam/password-reset/request" do |env|
          handle_password_reset_request(env)
        end
        post "/Api/iam/password-reset/confirm" do |env|
          handle_password_reset_confirm(env)
        end
      end

      # ── POST /Api/iam/change-password ────────────────────────────────
      #
      # Two authorization paths, both CSRF-checked:
      #   1. Bootstrap: a one-shot `change_token` returned by login when
      #      `must_change_pw` is true. Consumed on use.
      #   2. Authenticated: a valid access token (session-based change).
      # The `old_password` is always verified against the stored hash to
      # keep the failure surface identical across both paths.
      private def self.handle_change_password(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        new_password = require_field(env, parsed, "new_password") || return
        if new_password.size < 8
          return Facet::HTTP::Helpers.error_response(env, 422,
            "New password must be at least 8 characters")
        end

        old_password = require_field(env, parsed, "old_password") || return

        # Resolve account_id from one of the two authorization paths.
        token = parsed["change_token"]?.try(&.as_s?)
        account_id = resolve_change_password_account(env, token) || return

        # Verify the old password against the stored hash. A missing slot
        # (`nil`) and a mismatch (`false`) both fail — the nil path burns a
        # dummy bcrypt comparison so both cost the same time.
        verified = Database.with_db do |db2|
          Facet::Secrets.verify(db2, "iam.Account.#{account_id}", "password", old_password)
        end
        unless verified
          return Facet::HTTP::Helpers.error_response(env, 403, "Current password is incorrect")
        end

        apply_password_change(account_id, new_password, token)
        Event::Publisher.flush

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
      end

      # Resolves the account id for a password change. A one-shot
      # `change_token` takes priority over the session. Writes the error
      # and returns `nil` when a path fails. A token that the used marker
      # names gets its own message: the change succeeded, so the caller
      # signs in with the new password.
      private def self.resolve_change_password_account(env, token : String?) : String?
        if token
          account_id = Facet::IAM::PwdChangeToken.consume_pwd_change_token(token)
          if account_id.nil?
            if Facet::IAM::PwdChangeToken.used_pwd_change_token?(token)
              Facet::HTTP::Helpers.error_response(env, 401,
                "Change token already used — the password change succeeded. Sign in with the new password.")
              return nil
            end
            Facet::HTTP::Helpers.error_response(env, 401, "Change token is invalid or expired")
            return nil
          end
          return account_id
        end

        Facet::HTTP::Helpers.require_account(env)
      end

      # Applies the password change in one transaction: the new hash, the
      # reset-link clear, and the status flag. Burns the used one-shot
      # change token after success and leaves a short-TTL marker, so a
      # retry can report the successful change.
      private def self.apply_password_change(account_id : String, new_password : String, token : String?) : Nil
        # The new hash and the flag flip must not split: a password set
        # without clearing `must_change_pw` would loop the account back into
        # the bootstrap on next login.
        Database.with_db do |db2|
          Facet::Database.with_transaction(db2, ignore_if_set: true) do |txn|
            Facet::Secrets.set(txn, "iam.Account.#{account_id}", "password", new_password,
              mode: "hash", set_by: account_id)
            # Convergence rule: a password write clears any pending reset
            # link in the same transaction — a slot write never touches
            # another slot, so the clear must be explicit.
            Facet::Secrets.clear(txn, "iam.Account.#{account_id}", "reset")
            Facet::IAM::AccountPatch.call(txn, account_id,
              {"must_change_pw" => JSON::Any.new(false)})
            # Bootstrap completion: a change through the one-shot
            # `change_token` path is the invited account's first
            # credential. The flip is idempotent — a no-op patch is a
            # success. The authenticated (session) path is not a login
            # and does not flip.
            if token
              Facet::IAM::AccountPatch.call(txn, account_id,
                {"status" => JSON::Any.new("active")})
            end
            Facet::IAM::Helpers.write_login_event(txn, account_id, "password_change")
          end
        end
        # Token is single-use. Mark the burn first, then delete: a crash
        # between the two steps still leaves the marker, so a retry can
        # tell "change succeeded" from "token never valid".
        if token
          Facet::IAM::PwdChangeToken.mark_pwd_change_token_used(token)
          Facet::IAM::PwdChangeToken.delete_pwd_change_token(token)
        end
      end

      # ── POST /Api/iam/password-reset/request ───────────────────────────
      #
      # Anti-enumeration: always returns 200 `{ok: true}` whether or not
      # the email exists. A reset link is emailed only when the account
      # exists. The link is valid for the effective
      # `iam.change_password_expiration` seconds (runtime key on
      # `core.SystemSettings`, the file value as fallback; default 24h);
      # the response carries it as `link_ttl_seconds` so the frontend
      # confirmation copy can state the effective window.
      # The link base is `Config#scheme_base_url`.
      # Under `oidc_only` the whole password path is refused (`422`) —
      # there is no password to reset, and minting a working reset flow
      # would contradict the mode.
      private def self.handle_password_reset_request(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        email = require_field(env, parsed, "email") || return

        mode_refused = Database.with_db do |db|
          Facet::IAM::Policy.oidc_only?(db)
        end
        if mode_refused
          return Facet::HTTP::Helpers.error_response(env, 422,
            "Password reset is unavailable: this server authenticates through SSO only",
            meta: {"reason" => "auth_mode"})
        end

        # Outbound email reset link. `Config#scheme_base_url` is the
        # scheme-normalized public base URL — handles both scheme-bearing
        # hosts (`https://localhost:3443`, the dev Caddy form) and
        # scheme-less ones (`localhost:3000`), so the reset link is always
        # fully-qualified regardless of the deployed topology.
        reset_link_base = "#{Facet::Config.instance.scheme_base_url}/ResetPassword"
        # The response states the same window the minted token carries —
        # read it the way the issuing paths do (`IAM::Policy`).
        link_ttl = Database.with_db do |db2|
          ttl = Facet::IAM::Policy.change_password_expiration(db2)
          Facet::IAM::PasswordReset.request(db2, email, reset_link_base)
          ttl
        end
        Event::Publisher.flush

        Facet::HTTP::Helpers.write_json(env, 200,
          {ok: true, link_ttl_seconds: link_ttl})
      end

      # ── POST /Api/iam/password-reset/confirm ─────────────────────────
      #
      # Validates the token, enforces password minimum length, then
      # updates the password. Token is single-use — consumed on the first
      # call regardless of success or failure. When the confirm sets the
      # account's FIRST credential (an operator invite accepted), a
      # session is emitted and the response carries the same body shape
      # as `/Api/iam/login` — except under MFA enforcement `always` with an
      # un-enrolled account: no session is emitted (B-141), the response is
      # `{ok: true}`, and the sign-in that follows holds at enrollment.
      # Otherwise `{ok: true}` and the account logs in with the new password.
      private def self.handle_password_reset_confirm(env) : Nil
        body = guard(env) || return
        parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || return
        token = require_field(env, parsed, "token") || return
        new_password = require_field(env, parsed, "new_password") || return
        cookie = parsed["cookie"]?.try(&.as_bool?) != false

        # `oidc_only` refuses before the token is consumed — the
        # first-credential branch auto-logs in, which would bypass the
        # mode. Provisioning goes through OIDC JIT instead; the invite
        # link mint routes stay open but the links cannot complete while
        # the mode holds.
        mode_refused = Database.with_db do |db2|
          Facet::IAM::Policy.oidc_only?(db2)
        end
        if mode_refused
          return Facet::HTTP::Helpers.error_response(env, 422,
            "Password setup is unavailable: this server authenticates through SSO only",
            meta: {"reason" => "auth_mode"})
        end

        result = Database.with_db do |db2|
          Facet::IAM::PasswordReset.confirm(db2, token, new_password, cookie: cookie)
        end
        Event::Publisher.flush

        case result
        in Facet::IAM::PasswordReset::SessionStarted
          emit_http_response(env, result.result, result.result.cookie)
        in Facet::IAM::PasswordReset::EnrollmentHeld
          # B-141: under `always` the un-enrolled invitee gets no session.
          # The client sends the account to the login step, where the
          # login pipeline holds at the enrollment step.
          Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
        in Facet::IAM::PasswordReset::Confirmed
          Facet::HTTP::Helpers.write_json(env, 200, {ok: true})
        in Facet::IAM::PasswordReset::Requested
          # Unreachable — confirm never returns Requested.
          Facet::HTTP::Helpers.error_response(env, 500, "Unexpected response")
        in Facet::ServiceError
          error_response(env, result)
        end
      end

      # ── Session inventory / revocation ─────────────────────────────────

      private def self.register_session_admin_routes : Nil
        get "/Api/iam/sessions" do |env|
          handle_list_sessions(env)
        end
        delete "/Api/iam/sessions" do |env|
          handle_revoke_all_sessions(env)
        end
        delete "/Api/iam/sessions/:session_id" do |env|
          handle_revoke_session(env)
        end
        delete "/Api/iam/apps/:app_id/sessions" do |env|
          handle_revoke_app_sessions(env)
        end
      end

      # ── GET /Api/iam/sessions ────────────────────────────────────────
      #
      # Lists the caller's own sessions (browser + app). The
      # response surfaces the `app` field for display (e.g. "this app is
      # signed in"). No refresh tokens are returned — only session ids +
      # metadata. AuthHandler-protected: 401 if no session.
      private def self.handle_list_sessions(env) : Nil
        account_id = Facet::HTTP::Helpers.require_account(env) || return

        sessions = Facet::IAM::RedisSession.list_account_sessions(account_id)
        results = sessions.compact_map do |sid|
          s = Facet::IAM::RedisSession.load(sid)
          next nil unless s
          {
            session_id: sid,
            created_at: s.created_at,
            last_used:  s.last_used_at,
            user_agent: s.user_agent,
            ip:         s.ip,
            app:        (s.app.empty? ? nil : s.app),
            role:       s.active_role,
          }
        end

        Facet::HTTP::Helpers.write_json(env, 200, {sessions: results})
      end

      # ── DELETE /Api/iam/sessions/:session_id ──────────────────────────
      #
      # Revokes one of the caller's own sessions. Authorization: the loaded
      # session's `account_id` must equal the caller's `sub`). State-changing
      # — CSRF-protected. The live access token (if any) stays valid until
      # its ≤15-min TTL — the next refresh fails because the session row is
      # gone.
      private def self.handle_revoke_session(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        caller_id = Facet::HTTP::Helpers.require_account(env) || return
        target_id = Facet::HTTP::Helpers.require_path_param(env, "session_id") || return

        session = Facet::IAM::RedisSession.load(target_id)
        if session.nil?
          # Idempotent: deleting a non-existent session is still a success,
          # but the body says so — `revoked: false` keeps a stale or mistyped
          # id visible to the caller.
          return Facet::HTTP::Helpers.write_json(env, 200, {ok: true, revoked: false})
        end

        target_session = session.as(Facet::IAM::RedisSession::Session)
        unless target_session.account_id == caller_id
          # Non-disclosing 403 — the caller may not revoke someone else's
          # session.
          return Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
        end

        Facet::IAM::RedisSession.delete(target_id)
        Database.with_db do |db|
          Facet::IAM::Helpers.write_login_event(db, target_session.account_id, "session_revoked",
            "Session=#{target_id}")
        end
        Event::Publisher.flush

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true, revoked: true})
      end

      # ── DELETE /Api/iam/sessions ──────────────────────────────────
      #
      # Revokes every session the caller holds EXCEPT the one serving this
      # request. A bulk "sign out everywhere else": the caller's current
      # browser session (or API-key request, which holds no session) must
      # survive the call or the revoke would immediately log the requester
      # out with no way to see the result. Each revoked session writes its
      # own `session_revoked` event, mirroring the single-session route.
      # State-changing — CSRF-protected. The live access tokens stay valid
      # until their ≤15-min TTL — the next refresh fails because the session
      # row is gone.
      private def self.handle_revoke_all_sessions(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        caller_id = Facet::HTTP::Helpers.require_account(env) || return
        current_sid = extract_session_id(env)

        revoked = [] of String
        Facet::IAM::RedisSession.list_account_sessions(caller_id).each do |sid|
          next if sid == current_sid
          Facet::IAM::RedisSession.delete(sid)
          revoked << sid
        end

        Database.with_db do |db|
          revoked.each do |sid|
            Facet::IAM::Helpers.write_login_event(db, caller_id, "session_revoked",
              "Session=#{sid}")
          end
        end
        Event::Publisher.flush

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true, revoked: revoked.size})
      end

      # ── DELETE /Api/iam/apps/:app_id/sessions ──────────────────────
      #
      # Revokes every session the caller holds for a given app.
      # This is the per-app revocation surface. Same tradeoff: the access
      # tokens remain valid until their TTL; the next refresh fails.
      private def self.handle_revoke_app_sessions(env) : Nil
        return unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)

        caller_id = Facet::HTTP::Helpers.require_account(env) || return
        app_id = Facet::HTTP::Helpers.require_path_param(env, "app_id") || return

        session_ids = Facet::IAM::RedisSession.list_account_app_sessions(caller_id, app_id)
        session_ids.each { |sid| Facet::IAM::RedisSession.delete(sid) }

        Database.with_db do |db|
          Facet::IAM::Helpers.write_login_event(db, caller_id, "app_sessions_revoked",
            "App=#{app_id} count=#{session_ids.size}")
        end
        Event::Publisher.flush

        Facet::HTTP::Helpers.write_json(env, 200, {ok: true, revoked: session_ids.size})
      end

      # ── Private helpers ─────────────────────────────────────────────────

      # Shared plumbing for state-changing IAM routes: reads the request body
      # and enforces the CSRF header (with the API-key-bearer bypass). Writes
      # the error response and returns `nil` when either step fails. Use with
      # `|| next`.
      private def self.guard(env) : String?
        body = Facet::HTTP::Helpers.require_body(env)
        return nil if body.nil?
        return nil unless Facet::HTTP::Helpers.require_csrf(env, api_key_bypass: true)
        body
      end

      # RBAC gate for the operator account routes. Reads the request's auth
      # context, so it also rejects a system principal before any account
      # lookup — the bypass is rejected even when no JWT is presented.
      # Writes the 403 JSON and returns nil when refused. Use with `|| next`.
      private def self.authorize(env, action : String, target : String) : Facet::RBAC::AuthContext?
        ac = Facet::HTTP::Helpers.auth_context(env)
        if ac.system? || !ac.can?(action, target).is_a?(Facet::RBAC::CanResult::All)
          Facet::HTTP::Helpers.error_response(env, 403, "Forbidden")
          return nil
        end
        ac
      end

      # Extracts a required string field from the parsed JSON body. Writes
      # the 422 error and returns `nil` when the field is missing or not
      # a string. Use with `|| next`.
      private def self.require_field(env, parsed : Hash(String, JSON::Any), name : String) : String?
        field = parsed[name]?.try(&.as_s?)
        return field unless field.nil?

        Facet::HTTP::Helpers.error_response(env, 422, "Missing '#{name}' field")
        nil
      end

      # Extracts the account id from the request's auth context (set by
      # AuthHandler for both browser sessions and Bearer API keys), or writes
      # the 401 error and returns `nil`. Use with `|| next`. Unlike
      # `HTTP::Helpers.require_account`, this works for API-key callers,
      # whose requests carry no JWT to decode.
      private def self.require_account_id(env) : String?
        context = Fiber.current.auth_context
        if context.nil? || context.system? || context.account_id == "anonymous"
          Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
          return nil
        end
        context.account_id
      end

      # Extracts the caller identity for the profile reads. The presented
      # access token (cookie or Bearer JWT) is the identity source when one
      # rides the request — its claims are the exact `sub` / `role` the login
      # minted, and this keeps the route answerable in test mode where
      # `AuthHandler` is disabled and no context is pinned on the fiber. A
      # static API key carries no JWT, so for those callers the auth context
      # (`Fiber.current.auth_context`, set by AuthHandler) is the only identity
      # source — unlike `HTTP::Helpers.require_account`, which decodes JWT
      # claims only and 401s a key caller. Writes the 401 and returns `nil`
      # when neither source names a real, non-anonymous account: the system
      # bypass, the preview capability, the anonymous fallback, and a missing
      # context all refuse.
      private def self.require_caller(env) : NamedTuple(account_id: String, role_name: String, channel: String, token_role: String?, context: Facet::RBAC::AuthContext)?
        context = Facet::HTTP::Helpers.auth_context(env)
        principal = context.principal
        token_account = Helpers.extract_account_id(env)
        token_role = Helpers.extract_role(env)
        token_typ = Helpers.decode_jwt_claim(env, "typ")

        machine_principal = principal.is_a?(Facet::RBAC::Principal::Real) &&
                            principal.account_id != "anonymous"
        context_role = machine_principal ? principal.as(Facet::RBAC::Principal::Real).active_role.role_id : ""
        account_id = token_account || (machine_principal ? principal.account_id : nil)
        unless account_id
          Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
          return nil
        end

        # One channel name per authentication channel: a `typ: "access"`
        # token is the browser session; any other presented token (an app
        # token, an MCP bearer) is machine-shaped. A key caller presents no
        # token, so the context provenance decides — an API key, an app
        # token, or an MCP session all read `api`, and a real principal
        # carrying none of those tags authenticated through a browser
        # session.
        machine = if token_account
                    !token_typ.nil? && token_typ != Facet::IAM::JWT::ACCESS_TOKEN_TYP
                  else
                    !(context.api_key_id || context.app_id || context.acting_role).nil?
                  end
        {account_id: account_id, role_name: context_role, channel: machine ? "api" : "session", token_role: token_role, context: context}
      end

      # Resolves the qualified role reference (`iam.Roles.admin`) for the
      # request's active role. The auth context carries only the role's
      # content name (`RBAC::ActiveRole.role_id`, e.g. `admin`), while the
      # profile read and `find_role_content` speak the qualified projection
      # id. Every auth path (login, refresh, API-key verify) checks that the
      # active role is one of the account's assigned roles, so matching the
      # content name over the assignment recovers the reference without a
      # new context field. Returns `nil` when no assigned role carries the
      # name — the profile then degrades exactly as for a missing role
      # projection (no manifest, no visibility set).
      private def self.resolve_active_role_ref(db, assigned_roles : Array(String), role_name : String) : String?
        assigned_roles.each do |ref|
          content = Facet::IAM::Helpers.find_role_content(db, ref)
          next unless content
          return ref if content.as_h["name"]?.try(&.as_s?) == role_name
        end
        nil
      end

      # Extracts the `role` claim from the access token, or writes the 401
      # error and returns `nil`. Use with `|| next`.
      private def self.require_role(env) : String?
        role = Helpers.extract_role(env)
        if role.nil?
          Facet::HTTP::Helpers.error_response(env, 401, "Authentication required")
          return nil
        end
        role
      end

      # Writes a `Facet::ServiceError` as its JSON error response. A thin
      # adapter over `HTTP::Helpers.error_response` that carries the
      # error's `details` and `meta`.
      private def self.error_response(env, result : Facet::ServiceError) : Nil
        Facet::HTTP::Helpers.error_response(env, result.status, result.message, result.details, result.meta)
      end

      # Extracts the session_id from the access token.
      private def self.extract_session_id(env) : String?
        Helpers.decode_jwt_claim(env, "sid")
      end

      # Extracts the `exp` (expiration) claim from the access token as an Int64.
      private def self.extract_expires_at(env) : Int64?
        Helpers.extract_expires_at(env)
      end

      # Emits the token response: sets cookies or returns tokens in body.
      # `backup_codes` rides along only on the enroll-at-login response —
      # the raw recovery codes are shown exactly once, so they travel with
      # the session emission.
      private def self.emit_http_response(env, result : TokenEmitter::Result, cookie : Bool, backup_codes : Array(String)? = nil) : Nil
        env.response.content_type = "application/json"
        if cookie
          TokenEmitter.set_cookies(env, result)
          Facet::HTTP::Helpers.write_json(env, 200, TokenEmitter.response_body(result, backup_codes))
        else
          Facet::HTTP::Helpers.write_json(env, 200, TokenEmitter.full_body(result, backup_codes))
        end
      end
    end
  end
end
