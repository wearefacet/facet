# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../error"
require "./roles"

module Facet
  module IAM
    # Handles token rotation (refresh) with optional role change.
    #
    # ## Reuse detection
    #
    # If a presented `refresh_id` matches neither the stored `refresh_id`
    # nor `prev_refresh_id` (grace window), the session is considered
    # stolen: the session is deleted and a `refresh_reuse` event is written.
    #
    # ## Delivery mode
    #
    # The session stores how login delivered its tokens (cookie vs body).
    # Refresh enforces the same channel: a body-mode session refreshes only
    # with `cookie: false`; a cookie-mode session rejects `cookie: false`.
    # A mismatch answers `422` before any state changes: no rotation, no
    # grace entry, no delete, no event (B-278).
    #
    # A successful refresh writes no LoginEvent — it runs on a clock, so the
    # rows would flood the audit log. The backend log carries the trace.
    module Refresh
      Log = ::Log.for("facet.iam.refresh")

      record TokensEmitted,
        result : TokenEmitter::Result

      # Rotates tokens and optionally changes the active role.
      #
      # * `db` — database connection
      # * `refresh_token` — the opaque `session_id.refresh_id` token
      # * `role` — optional new role to switch to
      # * `cookie` — whether to set cookies (vs. returning tokens in body).
      #   Must match the delivery mode the session stored at login; a
      #   mismatch answers 422 and rotates nothing.
      def self.call(
        db : DB::Connection,
        refresh_token : String,
        role : String? = nil,
        cookie : Bool = true,
      ) : TokensEmitted | Facet::ServiceError
        # 1. Parse the refresh token
        parts = refresh_token.split('.', 2)
        if parts.size != 2
          return Facet::ServiceError.new(401, "Invalid refresh token format")
        end
        session_id, presented_refresh_id = parts

        # 2. Load the session from Redis
        session = RedisSession.load(session_id)
        if session.nil?
          return Facet::ServiceError.new(401, "Session expired or not found")
        end

        # 3. Delivery-mode gate. Runs before reuse detection so a mismatched
        # request never mutates session state — not even the theft response.
        if err = delivery_mismatch(session, cookie)
          return err
        end

        # 4. Reuse detection
        case RedisSession.validate_refresh_id(session, presented_refresh_id)
        when :valid
          # Normal case — proceed
        when :grace
          # Parallel refresh — also valid, proceed. The client may retry
          # with either the old or new refresh_id during the grace window.
        when :stale
          # Theft detected — delete the session and write a security event
          RedisSession.delete(session_id)
          Helpers.write_login_event(db, session.account_id, "refresh_reuse",
            "Refresh token reuse detected for session #{session_id}",
            app: app_for_event(session))
          return Facet::ServiceError.new(401, "Session revoked due to token reuse")
        end

        # 5. Re-run login checks: account must exist and be enabled
        account = Helpers.find_account_by_id(db, session.account_id)
        if account.nil?
          RedisSession.delete(session_id)
          return Facet::ServiceError.new(401, "Account not found")
        end

        # 6. Resolve the active role. A roleless account's session runs under
        # the anonymous role (B-120); an explicit role switch to a role the
        # account does not hold still fails.
        effective_role = role || session.active_role
        assigned_roles = account[:roles]
        unless role_servable?(assigned_roles, effective_role, !role.nil?)
          return Facet::ServiceError.new(403, "Role not assigned")
        end

        # 7. Verify the role document exists
        role_content = Helpers.find_role_content(db, effective_role)
        if role_content.nil?
          return Facet::ServiceError.new(403, "Role not found or disabled")
        end

        # 8. Rotate the session
        new_refresh_id = RedisSession.rotate(session_id, active_role: effective_role)
        if new_refresh_id.nil?
          return Facet::ServiceError.new(500, "Session rotation failed")
        end

        # 9. Build permission manifest
        manifest = Helpers.build_permission_manifest(role_content)
        visible_tags = Helpers.build_visible_tags(role_content)

        # 10. Emit new tokens
        emit_result = TokenEmitter.emit(
          cookie: cookie,
          account_id: session.account_id,
          email: account[:email],
          display_name: account[:display_name],
          mfa_enabled: account[:mfa_enabled],
          active_role: effective_role,
          available_roles: assigned_roles,
          permissions: manifest[:permissions],
          session_id: session_id,
          refresh_id: new_refresh_id,
          scopes: manifest[:scopes],
          visible_tags: visible_tags,
        )

        # Successful refreshes write no LoginEvent: a session refreshes on a
        # clock (the access-token TTL), so per-refresh rows would flood the
        # audit log. Retention never frees those rows — a LoginEvent document
        # holds a single mutation, and compaction refuses a cut at idx 1.
        # This log line is the per-refresh trace; the reuse and failure
        # events keep their LoginEvent rows.
        Log.info { refresh_trace(session, session_id, effective_role) }

        TokensEmitted.new(result: emit_result)
      end

      # ── Private ──────────────────────────────────────────────────

      # The per-refresh trace line. App-scoped sessions carry the app id.
      private def self.refresh_trace(session : RedisSession::Session, session_id : String, effective_role : String) : String
        app = app_for_event(session)
        app_part = app ? ", app=#{app}" : ""
        "Refresh ok (account_id=#{session.account_id}, " \
        "session=#{session_id}, role=#{effective_role}#{app_part})"
      end

      # Returns the `422` error when the request's `cookie` flag does not
      # match the session's stored delivery mode; `nil` when the request may
      # proceed. A body-mode session refreshes only with `cookie: false`. A
      # cookie-mode session refreshes with the flag absent or `true`.
      private def self.delivery_mismatch(session : RedisSession::Session, cookie : Bool) : Facet::ServiceError?
        if session.token_delivery == RedisSession::DELIVERY_BODY && cookie
          Facet::ServiceError.new(422,
            "Token delivery mismatch: this session uses body mode. Send \"cookie\": false.")
        elsif session.token_delivery == RedisSession::DELIVERY_COOKIE && !cookie
          Facet::ServiceError.new(422,
            "Token delivery mismatch: this session uses cookie mode. Do not send \"cookie\": false.")
        end
      end

      # True when `effective_role` may serve the session: it is assigned to
      # the account, or it is the anonymous fallback for a roleless account
      # (B-120). An explicit role switch (`explicit` true) to a role the
      # account does not hold is never servable.
      private def self.role_servable?(assigned_roles : Array(String), effective_role : String, explicit : Bool) : Bool
        return true if assigned_roles.includes?(effective_role)
        !explicit && effective_role == ANONYMOUS_ROLE_ID
      end

      # Returns the `app` for a LoginEvent: the app id when the session is
      # app-scoped, `nil` for ordinary browser sessions. The session stores
      # `app` as an empty string (not nil) for browser sessions, so the empty
      # case is normalized here to keep call sites branch-free.
      private def self.app_for_event(session : RedisSession::Session) : String?
        session.app.empty? ? nil : session.app
      end
    end
  end
end
