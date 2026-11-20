# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "../database"
require "../mutation/client"
require "../error"
require "../iam/helpers"
require "../iam/jwt"
require "../iam/redis_session"
require "../iam/token_emitter"
require "../rbac/active_role"
require "../rbac/grant_resolver"
require "./dpop"
require "./replay_cache"
require "./token"
require "../util/crypto"

module Facet
  module OAuth
    # Refreshes an app access token.
    #
    # App sessions share the existing `IAM::RedisSession` machinery with
    # browser sessions — refresh-token rotation and reuse detection are
    # *identical*. What diverges from `IAM::Refresh`:
    #
    # - No `role` parameter. The role the account elected on the consent screen is
    #   pinned for the life of the session. Switching roles requires a fresh
    #   `/OAuth/authorize` round-trip.
    # - No cookies. App refresh tokens are opaque bearer secrets held in memory
    #   on the client (cross-site cookies are unavailable for apps on a
    #   different origin). The response mirrors the body shape of the
    #   token endpoint's `authorization_code` response.
    # - Live-state re-validation. On every refresh the account, the role, the app,
    #   and the resolved grant are re-read from `projections`. Any failure
    #   invalidates the session instead of returning a fresh token. This is the
    #   sole enforcement point — the access token itself stays stateless and
    #   dies on its ≤15-minute TTL. The trade-off: disabling an account or an app
    #   takes effect on the next refresh, not immediately.
    # - Refresh floor. A refresh presented sooner than `REFRESH_FLOOR_S` after
    #   the current refresh token was issued fails with `slow_down` (429).
    #   Refresh runs on a clock (CLIs and agents poll on a schedule); the floor
    #   stops a tight loop from hammering Redis rotation and replaying the
    #   grace window. It replaces per-request rate limiting on this grant —
    #   see `OAuth::RateLimiter` for the scope split.
    #
    # ## Reuse detection
    #
    # A presented `refresh_id` that matches neither the current value nor the
    # `prev_refresh_id` (within the configured grace window) is treated as
    # theft: the session is deleted and a `refresh_reuse` `iam.LoginEvent` is
    # written. The same machinery backs `IAM::Refresh`.
    module Refresh
      # The refresh endpoint's error type. The shared `OAuth::EndpointError`
      # with a 401 default — a failed refresh is an authentication failure
      # (the base's default of 400 is the right fit for the other endpoints).
      class Error < EndpointError
        def initialize(error_code : String, message : String, status : Int32 = 401)
          super(error_code, message, status)
        end
      end

      # The minimum interval (seconds) between two refreshes of the same
      # session. A refresh presented sooner than this after the current
      # refresh token was issued fails with `slow_down` (429). Mirrors the
      # OAuth `slow_down` signal: the client backs off and retries.
      REFRESH_FLOOR_S = 10

      # The successful refresh response. Same shape as `Token::Issued` so the
      # app treats initial issuance and refresh uniformly. No `scope` member —
      # see `Token::Issued`.
      record Issued,
        access_token : String,
        token_type : String,
        expires_in : Int32,
        refresh_token : String

      # Refreshes an app session. Raises `Error` on any failure path.
      #
      # * `db` — database connection (used to re-read live state and to write
      #   the `refresh_reuse` audit event when theft is detected).
      # * `refresh_token` — the opaque `session_id.refresh_id` pair returned
      #   by the token endpoint.
      # * `client_id` — the OAuth client presenting the grant. An app
      #   refresh token is bound to the client that exchanged the code; the
      #   presented value must equal the session's. A missing or different
      #   value answers `invalid_grant` (401) and the session survives — the
      #   check runs before the floor and before reuse detection.
      # * `dpop_proof` (optional): a DPoP proof, required when the
      #   session was bound at issuance (`session.dpop_jkt` present). The
      #   proof's thumbprint must match the bound one (constant-time). When
      #   the session was never bound, the proof is ignored — a non-bound
      #   session stays bearer on refresh.
      # * `htu` — reconstructed public token URL (`OAuth::HTU.reconstruct`).
      #
      # `ath` is **never** verified here. Refresh presents a refresh token, not
      # an access token; `ath` is meaningless in this grant.
      def self.call(
        db : DB::Connection,
        refresh_token : String,
        client_id : String? = nil,
        ip : String? = nil,
        dpop_proof : String? = nil,
        htu : String? = nil,
      ) : Issued
        session_id, presented_refresh_id, session = load_and_validate_session(refresh_token)

        # An app refresh token must carry a populated `app` field. A
        # browser-session refresh token reaching this code path is a contract
        # violation (browser refreshes go through `IAM::Refresh`, which does not
        # re-validate the grant).
        if session.app.empty?
          raise Error.new("invalid_grant", "Session is not an app session")
        end

        # ── 1. Client binding ───────────────────────────────────────
        # The refresh grant is redeemable only by the client that exchanged
        # the code. The check runs before the floor and before reuse
        # detection: a wrong-client attempt must NOT revoke the session it
        # names — the check answers here and the session survives.
        presented_client = client_id
        if presented_client.nil? || presented_client.empty?
          raise Error.new("invalid_grant", "Missing 'client_id'")
        end
        unless presented_client == session.client_id
          raise Error.new("invalid_grant", "Refresh token is not bound to this client")
        end

        # ── 2. Refresh floor ─────────────────────────────────────────
        check_refresh_floor(session)

        # ── 3. Reuse detection ───────────────────────────────────────
        case IAM::RedisSession.validate_refresh_id(session, presented_refresh_id)
        when :valid
          # Normal refresh.
        when :grace
          # Parallel refresh — tolerated within the grace window. The rotation
          # below moves the freshly-issued `refresh_id` to `prev_refresh_id`,
          # narrowing the window a third caller could ride.
        when :stale
          # Theft detected — invalidate the session and audit.
          revoke_failed(db, session_id, session.account_id,
            "App refresh token reuse detected for session #{session_id}",
            app: session.app, event: "refresh_reuse",
            message: "Session revoked due to token reuse")
        end

        # ── 4. DPoP key binding check ──────────────────────────────
        # If the session was bound at issuance (`dpop_jkt` set), the client
        # MUST present a DPoP proof signed by the same private key. A missing
        # proof, a different key, or a replayed proof is theft — the session
        # is revoked and the refresh fails.
        #
        # The upgrade path is closed: a session created without `dpop_jkt` is
        # never bound, and a session created with it stays bound across
        # rotation (rotate does not touch the field), so a holder cannot
        # downgrade a bound session to bearer on refresh.
        cnf_jkt = check_dpop_binding(db, session, session_id, dpop_proof, htu)

        # ── 5. Re-validate live state ─────────────────────────
        # An app access token is stateless; refresh is the sole enforcement
        # point. Every live-state axis is re-read here. Each failure
        # writes a `refresh_failed` LoginEvent with app attribution
        # so an admin can answer why an app session died. The returned
        # effective scope is not echoed — the token response carries no scope
        # member (see `Token::Issued`); the empty-scope rejection runs inside.
        revalidate_live_state(db, session, session_id)

        # ── 6. Rotate ─────────────────────────────────────────
        # No `active_role` passed — the role never changes on app refresh.
        new_refresh_id = IAM::RedisSession.rotate(session_id)
        unless new_refresh_id
          raise Error.new("invalid_grant", "Session rotation failed")
        end

        # ── 7. Re-issue the app JWT ─────────────────────────────────
        # The `sid` is the same session id — `AuthHandler` continues to never
        # look it up on the access-token path. Only `jti`/`iat`/`exp` change.
        # `cnf.jkt` is re-stamped when the session is bound so the rotated
        # access token stays sender-constrained (a downgrade to bearer on
        # rotation is impossible by construction).
        payload, _exp = IAM::JWT.build_app_payload(
          account_id: session.account_id,
          sid: session_id,
          role: session.active_role,
          app_id: session.app,
          cnf_jkt: cnf_jkt,
        )

        IAM::Helpers.write_login_event(db, session.account_id, "app_refresh",
          "Role=#{session.active_role}", app: session.app)

        issue(session_id, new_refresh_id, payload, cnf_jkt)
      end

      # Refreshes an MCP session. The token endpoint's `refresh_token` grant
      # dispatches here when the session is browser-session-shaped but was
      # minted on the MCP branch. Revalidates account-active + role-held with
      # **no grant revalidation** (there are no grants — decision D5). The
      # rotated access token carries `aud` + `role` and no `app` claim.
      def self.call_mcp(
        db : DB::Connection,
        refresh_token : String,
        ip : String? = nil,
        dpop_proof : String? = nil,
        htu : String? = nil,
      ) : Issued
        session_id, presented_refresh_id, session = load_and_validate_session(refresh_token)

        # The floor applies on the MCP path too — MCP agents poll on a
        # schedule just like a CLI.
        check_refresh_floor(session)

        case IAM::RedisSession.validate_refresh_id(session, presented_refresh_id)
        when :valid, :grace
          # Normal or parallel-within-grace refresh.
        when :stale
          revoke_failed(db, session_id, session.account_id,
            "MCP refresh token reuse detected for session #{session_id}",
            event: "refresh_reuse",
            message: "Session revoked due to token reuse")
        end

        cnf_jkt = check_dpop_binding(db, session, session_id, dpop_proof, htu)

        # Live-state revalidation: account-active + role-held only. No app row,
        # no GrantResolver — the MCP session shape.
        account = IAM::Helpers.find_account_by_id(db, session.account_id)
        unless account
          revoke_failed(db, session_id, session.account_id, "Account not found")
        end
        unless account_status_active?(db, session.account_id)
          revoke_failed(db, session_id, session.account_id, "Account is not active")
        end
        unless account[:roles].includes?(session.active_role)
          revoke_failed(db, session_id, session.account_id,
            "Role is no longer assigned to the account")
        end
        mcp_role_content = IAM::Helpers.find_role_content(db, session.active_role)
        if mcp_role_content.nil?
          revoke_failed(db, session_id, session.account_id, "Role no longer exists")
        end

        # The MCP channel gate (connectivity): a role whose `connectivity`
        # list excludes `mcp` loses its MCP sessions at the next refresh.
        # Access tokens are stateless and bounded by their TTL — refresh is
        # the sole enforcement point, matching the account/role revalidation
        # directly above.
        mcp_channels = mcp_role_content.try(&.["connectivity"]?.try(&.as_a?))
        mcp_ok = mcp_channels.try(&.any?(&.as_s?.try(&.==("mcp")))) == true
        unless mcp_ok
          revoke_failed(db, session_id, session.account_id,
            "Role's connectivity excludes the 'mcp' channel")
        end

        new_refresh_id = IAM::RedisSession.rotate(session_id, ip: ip)
        unless new_refresh_id
          raise Error.new("invalid_grant", "Session rotation failed")
        end

        resource = MCP.resource_identifier(session.active_role)
        payload, _exp = IAM::JWT.build_access_payload(
          account_id: session.account_id,
          session_id: session_id,
          role: session.active_role,
          aud: resource,
        )

        IAM::Helpers.write_login_event(db, session.account_id, "mcp_refresh",
          "Role=#{session.active_role}")

        issue(session_id, new_refresh_id, payload, cnf_jkt)
      end

      # ── Internals ─────────────────────────────────────────────────────

      # Signs the rotated JWT and assembles the `Issued` response — the
      # shared tail behind the app and MCP refresh paths. `cnf_jkt` selects
      # the token type: a bound session flips `token_type` to `DPoP`.
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

      # Raises `slow_down` (429) when the session's current refresh token was
      # issued sooner than `REFRESH_FLOOR_S` ago. A missing or unparseable
      # stamp fails open — the floor is a pacing guard, not a security
      # boundary; rotation + reuse detection + live-state re-validation stay
      # the enforcement points.
      private def self.check_refresh_floor(session : IAM::RedisSession::Session) : Nil
        return if session.refresh_issued_at.empty?
        issued = begin
          Time.parse_rfc3339(session.refresh_issued_at)
        rescue
          nil
        end
        return if issued.nil?
        if Time.utc - issued < REFRESH_FLOOR_S.seconds
          raise Error.new("slow_down",
            "Refresh requested sooner than the #{REFRESH_FLOOR_S}-second floor. " \
            "Wait and retry.", 429)
        end
      end

      # Splits the `session_id.refresh_id` pair, loads the session from
      # Redis, and raises on a malformed token or a missing session.
      # Shared prologue of `call` and `call_mcp`.
      private def self.load_and_validate_session(refresh_token : String) : {String, String, IAM::RedisSession::Session}
        parts = refresh_token.split('.', 2)
        if parts.size != 2 || parts[0].empty? || parts[1].empty?
          raise Error.new("invalid_grant", "Invalid refresh token format")
        end
        session_id, presented_refresh_id = parts

        session = IAM::RedisSession.load(session_id)
        unless session
          raise Error.new("invalid_grant", "Session expired or not found")
        end

        {session_id, presented_refresh_id, session}
      end

      # Revokes a failed refresh: deletes the session, writes the audit
      # LoginEvent, and raises the uniform `invalid_grant` error. The
      # standard failure writes a `refresh_failed` event whose detail is
      # the raised message; the reuse-detection paths override `event`
      # and `message`. `app` attributes the event to an app session and
      # stays nil on the MCP path.
      private def self.revoke_failed(
        db : DB::Connection,
        session_id : String,
        account_id : String,
        detail : String,
        app : String? = nil,
        event : String = "refresh_failed",
        message : String? = nil,
      ) : NoReturn
        IAM::RedisSession.delete(session_id)
        IAM::Helpers.write_login_event(db, account_id, event, detail, app: app)
        raise Error.new("invalid_grant", message || detail)
      end

      # Enforces the DPoP key binding on a bound session. Returns the bound
      # `jkt` to re-stamp on the rotated access token, or `nil` when the
      # session was never bound. Any mismatch (missing proof, wrong key, or
      # replayed proof) revokes the session and raises.
      private def self.check_dpop_binding(
        db : DB::Connection,
        session : IAM::RedisSession::Session,
        session_id : String,
        dpop_proof : String?,
        htu : String?,
      ) : String?
        bound_jkt = session.dpop_jkt
        return nil unless bound_jkt

        unless dpop_proof
          revoke_failed(db, session_id, session.account_id,
            "Bound session refreshed without a DPoP proof", app: session.app)
        end
        expected_htu = htu || raise(Error.new("invalid_request",
          "DPoP proof presented but htu not provided by caller"))
        verified = OAuth::DPoP.verify_bound(dpop_proof, "POST", expected_htu, nil, "invalid_grant") do |code, message|
          Error.new(code, message)
        end
        unless Util::Crypto.constant_time_eq?(verified.jkt, bound_jkt)
          revoke_failed(db, session_id, session.account_id,
            "DPoP proof key does not match the session binding", app: session.app)
        end
        bound_jkt
      end

      # Re-reads every live-state axis a refresh depends on (account, role, app,
      # grant) and returns the resolved effective scope. Each failure revokes
      # the session and raises.
      private def self.revalidate_live_state(
        db : DB::Connection,
        session : IAM::RedisSession::Session,
        session_id : String,
      ) : RBAC::EffectiveScope
        # User: still exists, still enabled.
        account = IAM::Helpers.find_account_by_id(db, session.account_id)
        unless account
          revoke_failed(db, session_id, session.account_id, "Account not found", app: session.app)
        end
        # `find_account_by_id` does not surface status directly; a deleted
        # account returns nil (the projection row's `deleted_at` filter). A
        # disabled-but-present account is rare in this phase but we still gate
        # on it defensively by re-reading status from the projection row.
        unless account_status_active?(db, session.account_id)
          revoke_failed(db, session_id, session.account_id, "Account is not active", app: session.app)
        end

        # Role: still assigned to the account, still exists as a projection row.
        unless account[:roles].includes?(session.active_role)
          revoke_failed(db, session_id, session.account_id,
            "Role is no longer assigned to the account", app: session.app)
        end
        role_content = IAM::Helpers.find_role_content(db, session.active_role)
        unless role_content
          revoke_failed(db, session_id, session.account_id, "Role no longer exists", app: session.app)
        end

        # App: still exists (non-deleted projection), still `active`.
        app_row = db.query_one?(
          "SELECT id, content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          session.app,
        ) do |rs|
          {id: rs.read(String), content: rs.read(JSON::Any)}
        end
        unless app_row
          revoke_failed(db, session_id, session.account_id, "App no longer exists", app: session.app)
        end
        status = app_row[:content].as_h["status"]?.try(&.as_s?) || "draft"
        unless status == "active"
          revoke_failed(db, session_id, session.account_id,
            "App is not active (status=#{status})", app: session.app)
        end

        # Grant: still usable + still produces a non-empty effective scope
        # against the *current* grant set. A grant narrowed between two
        # refreshes fails right here.
        active_role = RBAC::ActiveRole.from_projection_content(role_content)
        app_scope = RBAC::AppScope.from_content(app_row[:id], app_row[:content])
        unless RBAC::GrantResolver.role_usable?(app_scope, active_role)
          revoke_failed(db, session_id, session.account_id,
            "Role is no longer usable with this app", app: session.app)
        end
        effective = RBAC::GrantResolver.resolve(app_scope, active_role)
        if effective.empty?
          revoke_failed(db, session_id, session.account_id,
            "Effective scope is empty for this role/app", app: session.app)
        end
        effective
      end

      # Reads the account's `status` field directly from the projection. We do
      # this instead of trusting `find_account_by_id`'s implicit "deleted →
      # nil" semantic because an admin may disable (not delete) an account
      # mid-session by setting `status` to e.g. `"disabled"`.
      private def self.account_status_active?(db : DB::Connection, account_id : String) : Bool
        row = db.query_one?(
          "SELECT content->>'status' FROM projections WHERE id = $1 AND deleted_at IS NULL",
          account_id,
          as: String?,
        )
        row.nil? || row == "active"
      end
    end
  end
end
