# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../error"
require "./roles"

module Facet
  module IAM
    # Shared session-emit step for the login pipeline: every path that
    # authenticates an account without a session yet (password login, MFA
    # challenge, enroll-at-login) ends here.
    #
    # Loads the account, verifies the active role is still assigned (the
    # anonymous fallback excepted — see below), creates the Redis session,
    # builds the permission manifest, and emits the token pair. The emitted
    # shape is identical across callers.
    module SessionEmit
      # Emits tokens and creates the session for an authenticated account.
      #
      # * `db` — database connection
      # * `account_id` — the authenticated account id
      # * `active_role` — the role resolved for this login. `nil` selects
      #   the bootstrap mode: the role resolves like a login
      #   (`default_role` → first assigned) and falls back to the anonymous
      #   role when the account holds none (B-120). The password-reset
      #   first-credential confirm uses this mode.
      # * `cookie_requested` — whether tokens go into cookies (vs. the body).
      #   The session stores the mode, so refresh enforces the same channel
      #   later (B-278).
      # * `user_agent`, `ip` — session metadata (available only on the
      #   password-login path, which sees the request)
      def self.call(
        db : DB::Connection,
        account_id : String,
        active_role : String? = nil,
        cookie_requested : Bool = true,
        user_agent : String? = nil,
        ip : String? = nil,
      ) : TokenEmitter::Result | Facet::ServiceError
        # Fetch account details
        account = Helpers.find_account_by_id(db, account_id)
        if account.nil?
          return Facet::ServiceError.new(401, "Account not found")
        end

        # Get assigned roles
        assigned_roles = account[:roles]
        if active_role
          # Explicit election: verify the role is still assigned. The
          # anonymous fallback is not an assignment — a roleless account may
          # still run under it (B-120).
          unless assigned_roles.includes?(active_role) || (assigned_roles.empty? && active_role == ANONYMOUS_ROLE_ID)
            return Facet::ServiceError.new(403, "Role no longer assigned")
          end
        else
          # Bootstrap: resolve the role like a login. A roleless account
          # runs under the anonymous role (B-120) — it can authenticate, so
          # it must be able to connect; the frontend renders the no-role
          # screen from the emitted `available_roles` / `active_role` pair.
          active_role = Helpers.default_active_role(assigned_roles, account[:default_role])
          active_role ||= ANONYMOUS_ROLE_ID
        end

        # Create session. The stored delivery mode lets refresh pin the
        # request flag to the channel the tokens used at issuance.
        session_id, refresh_id = RedisSession.create(
          account_id: account_id,
          active_role: active_role,
          user_agent: user_agent,
          ip: ip,
          cookie_delivery: cookie_requested,
        )

        # Build permission manifest
        role_content = Helpers.find_role_content(db, active_role)
        manifest = role_content ? Helpers.build_permission_manifest(role_content) : {permissions: nil, scopes: nil}
        visible_tags = Helpers.build_visible_tags(role_content)

        TokenEmitter.emit(
          cookie: cookie_requested,
          account_id: account_id,
          email: account[:email],
          display_name: account[:display_name],
          mfa_enabled: account[:mfa_enabled],
          active_role: active_role,
          available_roles: assigned_roles,
          permissions: manifest[:permissions],
          session_id: session_id,
          refresh_id: refresh_id,
          scopes: manifest[:scopes],
          visible_tags: visible_tags,
        )
      end
    end
  end
end
