# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "openssl"
require "jwt"
require "json"
require "http/cookie"
require "log"

module Facet
  module IAM
    # Emits access and refresh tokens after successful authentication.
    #
    # This is the shared output path for login, challenge (MFA), and refresh.
    # It handles creation of the JWT access token, session management, and
    # building the response body or setting cookies.
    module TokenEmitter
      Log = ::Log.for("facet.iam.token_emitter")

      # The ES256 signing key. The `JWT_SIGNING_KEY` environment variable
      # holds a P-256 private key in PEM form and is the production source:
      # instances that share the variable verify each other's tokens. When
      # the variable is unset, each process generates its own key at first
      # use (dev/test convenience) — a restart then invalidates every
      # outstanding access token. See `doc/backend/iam.md` → `Facet::IAM::JWT`.
      @@signing_key : String?

      # Memoized for the process lifetime, so the resolve branch (and its
      # warning) runs exactly once per process.
      def self.signing_key : String
        @@signing_key ||= resolve_signing_key
      end

      # Clears the memoized signing key, so the next `signing_key` call
      # re-resolves from the environment. Spec support only — the runtime
      # memoizes one key per process and nothing calls this outside specs.
      def self.reset_signing_key! : Nil
        @@signing_key = nil
      end

      private def self.resolve_signing_key : String
        if env_key = ENV["JWT_SIGNING_KEY"]?
          env_key
        else
          Log.warn do
            "JWT_SIGNING_KEY is not set: this process generated a temporary ES256 signing key. " \
            "Tokens signed with it stop verifying after a restart, and a multi-instance deployment " \
            "cannot verify tokens from other instances. Set JWT_SIGNING_KEY to a P-256 private key " \
            "in PEM form, for example: openssl ecparam -name prime256v1 -genkey -noout"
          end
          JWT.generate_key_pem
        end
      end

      # Returns a hash of kid → PEM key for verification.
      # Two entries when env-var is set, one entry when using generated key.
      def self.keys : Hash(String, String)
        keys = {} of String => String
        keys["facet-1"] = signing_key
        if env_key = ENV["JWT_SIGNING_KEY"]?
          keys["env-0"] = env_key
        end
        keys
      end

      class_getter kid : String { "facet-1" }

      # Result of emitting tokens.
      record Result,
        account_id : String,
        email : String,
        display_name : String,
        mfa_enabled : Bool,
        active_role : String,
        available_roles : Array(String),
        session_id : String,
        refresh_id : String,
        access_token : String,
        refresh_token : String,
        expires_at : Int64,
        permissions : Hash(String, Array(String))?,
        scopes : Hash(String, Hash(String, Array(String)))?,
        visible_tags : Array(String)?,
        cookie : Bool

      # Emits tokens for a successful authentication.
      def self.emit(
        cookie : Bool,
        account_id : String,
        email : String,
        display_name : String,
        mfa_enabled : Bool,
        active_role : String,
        available_roles : Array(String),
        permissions : Hash(String, Array(String))?,
        session_id : String,
        refresh_id : String,
        scopes : Hash(String, Hash(String, Array(String)))? = nil,
        visible_tags : Array(String)? = nil,
      ) : Result
        # Build the JWT access token
        payload, expires_at = JWT.build_access_payload(account_id, session_id, active_role)
        access_token = JWT.sign(payload, signing_key, kid)

        # Build the refresh token (opaque: session_id.refresh_id)
        refresh_token = "#{session_id}.#{refresh_id}"

        Result.new(
          account_id: account_id,
          email: email,
          display_name: display_name,
          mfa_enabled: mfa_enabled,
          active_role: active_role,
          available_roles: available_roles,
          session_id: session_id,
          refresh_id: refresh_id,
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: expires_at,
          permissions: permissions,
          scopes: scopes,
          visible_tags: visible_tags,
          cookie: cookie,
        )
      end

      # Builds the response body fields shared by both cookie and full
      # (token-bearing) responses.
      private def self.base_body(result : Result)
        {
          "account" => {
            "id"           => result.account_id,
            "email"        => result.email,
            "display_name" => result.display_name,
            "mfa_enabled"  => result.mfa_enabled,
          },
          "active_role"     => result.active_role,
          "available_roles" => result.available_roles,
          "expires_at"      => result.expires_at,
        }
      end

      # Builds the JSON response body when cookies are used. `backup_codes`
      # rides along only on the enroll-at-login response — the raw recovery
      # codes are shown exactly once, so they travel with the session.
      def self.response_body(result : Result, backup_codes : Array(String)? = nil) : String
        body = base_body(result)

        if perms = result.permissions
          body = body.merge({"permissions" => perms})
        end

        if scopes = result.scopes
          body = body.merge({"scopes" => scopes})
        end

        if tags = result.visible_tags
          body = body.merge({"visible_tags" => tags})
        end

        if codes = backup_codes
          body = body.merge({"backup_codes" => codes})
        end

        body.to_json
      end

      # Builds the full response body when `cookie == false`.
      def self.full_body(result : Result, backup_codes : Array(String)? = nil) : String
        body = base_body(result).merge({"token" => result.access_token, "refresh_token" => result.refresh_token})

        if perms = result.permissions
          body = body.merge({"permissions" => perms})
        end

        if scopes = result.scopes
          body = body.merge({"scopes" => scopes})
        end

        if tags = result.visible_tags
          body = body.merge({"visible_tags" => tags})
        end

        if codes = backup_codes
          body = body.merge({"backup_codes" => codes})
        end

        body.to_json
      end

      # Sets HttpOnly cookies on the response.
      #
      # Both cookies use `path: "/"` so that the browser sends them on every
      # same-origin request — including SvelteKit SSR page loads. SSR runs in
      # the context of the page URL (e.g. `/`), and SvelteKit's `event.fetch`
      # can only forward cookies that were present on the incoming request;
      # scoping `refresh_token` to `/Api/iam/refresh` made it invisible to SSR,
      # so server-side refresh-on-401 always received "Missing refresh token".
      # The `HttpOnly` flag prevents JavaScript access; the backend only reads
      # `refresh_token` on the `/Api/iam/refresh` route.
      def self.set_cookies(env, result : Result) : Nil
        secure = Config.secure_cookies
        env.response.cookies << ::HTTP::Cookie.new(
          "auth_token",
          result.access_token,
          path: "/",
          http_only: true,
          secure: secure,
          samesite: ::HTTP::Cookie::SameSite::Lax,
        )
        env.response.cookies << ::HTTP::Cookie.new(
          "refresh_token",
          result.refresh_token,
          path: "/",
          http_only: true,
          secure: secure,
          samesite: ::HTTP::Cookie::SameSite::Lax,
        )
      end
    end
  end
end
