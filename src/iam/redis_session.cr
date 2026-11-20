# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "redis"
require "log"

module Facet
  module IAM
    # Manages sessions in Redis.
    #
    # ## Key structure
    #
    # - `session:{session_id}` — hash: `{refresh_id, prev_refresh_id, account_id,
    #   active_role, created_at, last_used_at, refresh_issued_at, user_agent, ip,
    #   app, client_id, dpop_jkt}`
    # - `account_sessions:{account_id}` — set of session_id strings (device enumeration)
    #
    # ## Security model
    #
    # Session security comes from the `refresh_id` comparison and rotation,
    # not a signature. A session is a lookup key; the `refresh_id` is the
    # bearer secret presented by the client alongside the `session_id`.
    module RedisSession
      Log = ::Log.for("facet.iam.redis_session")
      # Ruby-compatible Redis key prefixes.
      #
      # `APP_SESSIONS_PREFIX` (`app_sessions:{app_id}`) is maintained only for
      # sessions created with a non-empty `app` field. Browser sessions leave
      # `app` empty and never touch that set.
      SESSION_PREFIX          = "session:"
      ACCOUNT_SESSIONS_PREFIX = "account_sessions:"
      APP_SESSIONS_PREFIX     = "app_sessions:"
      REFRESH_LIFETIME        = -> { Facet::Config.instance.iam.jwt.refresh_token_ttl }

      # Token-delivery mode of a session: how the login that created it
      # delivered the tokens. `DELIVERY_COOKIE` is the historical default —
      # the hash field is written only for body mode, so sessions without
      # the field read as cookie mode.
      TOKEN_DELIVERY_FIELD = "token_delivery"
      DELIVERY_COOKIE      = "cookie"
      DELIVERY_BODY        = "body"

      # An active session loaded from Redis.
      #
      # `app` is the `app.App` projection id for app sessions, or the
      # empty string for ordinary browser sessions. It is *not* consulted on the
      # access-token path — `AuthHandler` stays stateless. It is consulted only
      # at refresh (re-validation) and by the per-app revocation endpoints.
      #
      # `dpop_jkt` is the RFC 7638 JWK thumbprint the session's
      # tokens are bound to, or `nil` for plain bearer sessions. Set only at
      # app-session creation when the client presented a DPoP proof at
      # `/OAuth/token` (the opt-in path). Persisted across refreshes —
      # `rotate` never touches it. `OAuth::Refresh` requires a matching proof
      # whenever it is set.
      #
      # `refresh_issued_at` is the RFC-3339 stamp of the moment the current
      # `refresh_id` was issued (create or rotate). It backs the refresh
      # floor: `OAuth::Refresh` rejects a refresh presented sooner than
      # `REFRESH_FLOOR_S` after this moment. `last_used_at` would couple the
      # floor to the grace-window clock, so the floor reads this field
      # instead. A missing value fails open (the floor is skipped).
      #
      # `client_id` is the OAuth client that exchanged the code for an app
      # session. `OAuth::Refresh` requires the refresh grant to present the
      # same value; a mismatch answers `invalid_grant` and the session
      # survives. Browser sessions carry the empty string. `rotate` never
      # touches the field.
      #
      # `token_delivery` records how the login that created the session
      # delivered its tokens: `DELIVERY_BODY` when they rode the JSON body,
      # `DELIVERY_COOKIE` when they rode HttpOnly cookies. `IAM::Refresh`
      # gates on it — a body-mode session refreshes only with `cookie: false`.
      # The field is written only for body mode; absence reads as
      # `DELIVERY_COOKIE` (the historical default). Persists across
      # rotations — `rotate` never touches it.
      record Session,
        session_id : String,
        refresh_id : String,
        prev_refresh_id : String?,
        account_id : String,
        active_role : String,
        created_at : String,
        last_used_at : String,
        user_agent : String?,
        ip : String?,
        app : String,
        client_id : String,
        dpop_jkt : String?,
        refresh_issued_at : String,
        token_delivery : String

      # ── Redis connection ─────────────────────────────────────────────

      # Returns a Redis client bound to the configured event Redis URL.
      # IAM shares the event system's Redis instance — there is no separate
      # IAM Redis config, and `event.url` is the single source of truth.
      # Exposed publicly so other IAM modules reuse the same accessor.
      def self.redis : ::Redis::Client
        Facet::Redis.client
      end

      # ── Create ─────────────────────────────────────────────────────

      # Creates a new browser session and stores it in Redis.
      #
      # Returns `{session_id, refresh_id}`. The session's `app` field is empty;
      # a browser-session refresh token never reaches `OAuth::Refresh`. MCP
      # sessions are also browser-session-shaped (no `app` field) and are
      # created through this path — the token endpoint's resource branch
      # passes `dpop_jkt` when the client presented a DPoP proof.
      def self.create(
        account_id : String,
        active_role : String,
        user_agent : String? = nil,
        ip : String? = nil,
        dpop_jkt : String? = nil,
        cookie_delivery : Bool = true,
      ) : {String, String}
        create_session(account_id, active_role, "", "", user_agent, ip, dpop_jkt, cookie_delivery)
      end

      # Creates a new app session. The session carries the `app.App`
      # projection id so `OAuth::Refresh` can re-load the app projection on the
      # next refresh. The opaque refresh token returned to the caller is the
      # same `{session_id}.{refresh_id}` shape as a browser-session token —
      # public clients hold it in memory only (no cross-site
      # cookie transport); reload costs one silent `/OAuth/authorize`
      # round-trip.
      #
      # `client_id` (required): the OAuth client that exchanged the code.
      # Stored on the session; `OAuth::Refresh` requires the refresh grant
      # to present the same value, so the token stays bound to the client
      # that earned it.
      #
      # `dpop_jkt` (optional): when the client presented a DPoP proof
      # at `/OAuth/token`, the JWK thumbprint is bound to the session and
      # required on every subsequent refresh. `nil` (the default) leaves a
      # plain bearer app session.
      def self.create_app_session(
        account_id : String,
        active_role : String,
        app : String,
        client_id : String,
        user_agent : String? = nil,
        ip : String? = nil,
        dpop_jkt : String? = nil,
      ) : {String, String}
        create_session(account_id, active_role, app, client_id, user_agent, ip, dpop_jkt)
      end

      # Shared write path. Writes the hash, sets the TTL, and adds the session
      # to the account's session set plus — when `app` is non-empty — the app's
      # session set (used by the per-app revocation endpoint). `dpop_jkt` is
      # written only when non-nil to avoid polluting browser sessions with an
      # empty field.
      private def self.create_session(
        account_id : String,
        active_role : String,
        app : String,
        client_id : String,
        user_agent : String?,
        ip : String?,
        dpop_jkt : String? = nil,
        cookie_delivery : Bool = true,
      ) : {String, String}
        session_id = Random::Secure.hex(32)
        refresh_id = Random::Secure.hex(32)
        now = Time.utc.to_rfc3339

        r = redis
        r.hset(
          "#{SESSION_PREFIX}#{session_id}",
          "refresh_id", refresh_id,
          "account_id", account_id,
          "active_role", active_role,
          "created_at", now,
          "last_used_at", now,
          "refresh_issued_at", now,
          "user_agent", user_agent || "",
          "ip", ip || "",
          "app", app,
        )
        # Client binding — written only when non-empty, so browser-session
        # hashes carry no `client_id` field at all. `rotate` does not touch
        # it; `build_session` reads it.
        r.hset("#{SESSION_PREFIX}#{session_id}", "client_id", client_id) unless client_id.empty?
        # DPoP binding — optional field written only for proof-of-possession
        # sessions. `rotate` does not touch it; `build_session` reads it.
        r.hset("#{SESSION_PREFIX}#{session_id}", "dpop_jkt", dpop_jkt) if dpop_jkt
        # Token-delivery mode — written only for body mode, the non-default.
        # `rotate` does not touch it; `build_session` reads it.
        r.hset("#{SESSION_PREFIX}#{session_id}", TOKEN_DELIVERY_FIELD, DELIVERY_BODY) unless cookie_delivery
        lifetime = REFRESH_LIFETIME.call
        r.expire("#{SESSION_PREFIX}#{session_id}", lifetime)

        # Add to the account's session set
        r.sadd("#{ACCOUNT_SESSIONS_PREFIX}#{account_id}", session_id)
        r.expire("#{ACCOUNT_SESSIONS_PREFIX}#{account_id}", lifetime)

        # App sessions also register in the app's session set, so the per-app
        # revocation endpoint can enumerate without scanning every account.
        unless app.empty?
          r.sadd("#{APP_SESSIONS_PREFIX}#{app}", session_id)
          r.expire("#{APP_SESSIONS_PREFIX}#{app}", lifetime)
        end

        {session_id, refresh_id}
      end

      # ── Load ─────────────────────────────────────────────────────────

      # Loads a session by ID.
      #
      # Returns `nil` if the session does not exist or is expired.
      def self.load(session_id : String) : Session?
        r = redis
        raw = r.hgetall("#{SESSION_PREFIX}#{session_id}")
        return nil if raw.is_a?(Array) && raw.empty?

        data = ::Redis.to_hash(raw.as(Array))
        return nil if data.empty?

        to_s = ->(v : ::Redis::Value) { v.is_a?(String) ? v : v.to_s }
        build_session(session_id, data, to_s)
      end

      # Extracts a `Session` record from the parsed Redis hash. Pulled out of
      # `load` so ameba's cyclomatic-complexity check stays satisfied (`load`
      # drops to ~5 once the eight optional fields live in their own method).
      private def self.build_session(
        session_id : String,
        data : Hash(String, ::Redis::Value),
        to_s : ::Redis::Value -> String,
      ) : Session
        Session.new(
          session_id: session_id,
          refresh_id: to_s.call(data["refresh_id"]? || ""),
          prev_refresh_id: data["prev_refresh_id"]?.try { |v| to_s.call(v) },
          account_id: to_s.call(data["account_id"]? || ""),
          active_role: to_s.call(data["active_role"]? || ""),
          created_at: to_s.call(data["created_at"]? || ""),
          last_used_at: to_s.call(data["last_used_at"]? || ""),
          user_agent: data["user_agent"]?.try { |v| to_s.call(v) }.try(&.presence),
          ip: data["ip"]?.try { |v| to_s.call(v) }.try(&.presence),
          app: to_s.call(data["app"]? || ""),
          client_id: to_s.call(data["client_id"]? || ""),
          dpop_jkt: data["dpop_jkt"]?.try { |v| to_s.call(v) }.try(&.presence),
          refresh_issued_at: to_s.call(data["refresh_issued_at"]? || ""),
          token_delivery: to_s.call(data[TOKEN_DELIVERY_FIELD]? || DELIVERY_COOKIE),
        )
      end

      # ── Rotation ─────────────────────────────────────────────────────

      # Rotates the refresh token: stores the current `refresh_id` as
      # `prev_refresh_id`, generates a new one, and resets the TTL.
      #
      # Returns the new `refresh_id`.
      #
      # ## Grace window
      #
      # After rotation, the previous `refresh_id` is accepted for a short
      # window (configured via `refresh_grace_window`) to handle parallel
      # refresh requests from legitimate clients.
      #
      # ## Atomicity
      #
      # The whole read-compare-write runs as one Lua script. The MCP workload
      # refreshes in parallel by default (agents fire concurrent tool calls);
      # the previous multi-round-trip implementation let two concurrent
      # rotations interleave their HSETs, and a third racing refresh could
      # trip reuse detection and revoke a legitimate session mid-conversation.
      # The script makes rotate atomic for REST and MCP alike.
      ROTATE_LUA = <<-LUA
        local k = KEYS[1]
        if redis.call("EXISTS", k) == 0 then
          return nil
        end
        local current = redis.call("HGET", k, "refresh_id")
        if not current or current == "" then
          return nil
        end
        redis.call("HSET", k, "prev_refresh_id", current)
        for i = 1, #ARGV - 2, 2 do
          redis.call("HSET", k, ARGV[i], ARGV[i + 1])
        end
        redis.call("EXPIRE", k, tonumber(ARGV[#ARGV]))
        return ARGV[#ARGV - 1]
      LUA

      def self.rotate(
        session_id : String,
        active_role : String? = nil,
        user_agent : String? = nil,
        ip : String? = nil,
      ) : String?
        r = redis
        key = "#{SESSION_PREFIX}#{session_id}"

        new_refresh = Random::Secure.hex(32)
        now = Time.utc.to_rfc3339

        args = ["refresh_id", new_refresh, "last_used_at", now,
                "refresh_issued_at", now]
        args << "active_role" << active_role if active_role
        args << "user_agent" << user_agent if user_agent
        args << "ip" << ip if ip
        args << new_refresh                # returned by the script on success
        args << REFRESH_LIFETIME.call.to_s # EXPIRE TTL

        result = r.eval(ROTATE_LUA, keys: [key], args: args)
        result.is_a?(String) && result == new_refresh ? new_refresh : nil
      rescue ex
        Log.error { "RedisSession.rotate failed: #{ex.message}" }
        nil
      end

      # ── Validation / Reuse detection ─────────────────────────────────

      # Validates a presented `refresh_id` against a loaded session.
      #
      # Returns:
      # - `:valid` — the presented ID matches the current `refresh_id`.
      # - `:grace` — the presented ID matches `prev_refresh_id` and is within
      #   the configured grace window (default 10 seconds).
      # - `:stale` — no match (possible theft).
      def self.validate_refresh_id(session : Session, presented : String) : Symbol
        if session.refresh_id == presented
          :valid
        elsif session.prev_refresh_id == presented
          grace_window = Facet::Config.instance.iam.jwt.refresh_grace_window
          last_used = Time.parse_rfc3339(session.last_used_at)
          if Time.utc - last_used <= grace_window.seconds
            :grace
          else
            :stale
          end
        else
          :stale
        end
      end

      # ── Delete ─────────────────────────────────────────────────────

      # Deletes a session and removes it from the account's session set and —
      # when the session was app-scoped — the app's session set. Idempotent.
      def self.delete(session_id : String) : Nil
        r = redis
        key = "#{SESSION_PREFIX}#{session_id}"

        # Capture account_id and app before deleting so the membership sets can
        # be cleaned. The `app` field is empty for browser sessions.
        account_id = r.hget(key, "account_id")
        app = r.hget(key, "app")
        r.del(key)

        if account_id && !account_id.empty?
          r.srem("#{ACCOUNT_SESSIONS_PREFIX}#{account_id}", session_id)
        end
        if app.is_a?(String) && !app.empty?
          r.srem("#{APP_SESSIONS_PREFIX}#{app}", session_id)
        end
      end

      # Deletes every session bound to an app. Used by the per-app revocation
      # endpoint — the live access tokens remain valid until their ≤15-minute
      # TTL; the next refresh fails because the session is
      # gone. Idempotent.
      def self.delete_app_sessions(app : String) : Int32
        r = redis
        members = r.smembers("#{APP_SESSIONS_PREFIX}#{app}")
        arr = members.is_a?(Array) ? members : [] of ::Redis::Value
        count = 0
        arr.each do |sid|
          sid_str = sid.to_s
          # `delete` re-reads `account_id`/`app` from the hash and cleans both
          # membership sets — that's slightly more work than deleting the key
          # directly, but it keeps a single code path and avoids leaving stale
          # `account_sessions:{account_id}` entries behind.
          delete(sid_str)
          count += 1
        end
        r.del("#{APP_SESSIONS_PREFIX}#{app}")
        count
      end

      # Lists the session ids an account holds for a specific app. The
      # app session set (`app_sessions:{app_id}`) is maintained only on app
      # sessions; this returns the intersection with the account's own session set
      # so the listing is scoped to the caller's sessions. Empty array when the
      # account holds no matching sessions. Returned in arbitrary order.
      def self.list_account_app_sessions(account_id : String, app : String) : Array(String)
        r = redis
        account_members = r.smembers("#{ACCOUNT_SESSIONS_PREFIX}#{account_id}")
        account_arr = account_members.is_a?(Array) ? account_members : [] of ::Redis::Value
        return [] of String if account_arr.empty?
        app_members = r.smembers("#{APP_SESSIONS_PREFIX}#{app}")
        app_arr = app_members.is_a?(Array) ? app_members : [] of ::Redis::Value
        return [] of String if app_arr.empty?
        app_set = app_arr.map(&.to_s).to_set
        account_arr.map(&.to_s).select { |sid| app_set.includes?(sid) }
      end

      # ── List account sessions ───────────────────────────────────────────

      # Returns all session IDs for an account (device enumeration).
      def self.list_account_sessions(account_id : String) : Array(String)
        r = redis
        result = r.smembers("#{ACCOUNT_SESSIONS_PREFIX}#{account_id}")
        arr = result.is_a?(Array) ? result : [] of ::Redis::Value
        arr.map(&.to_s)
      end
    end
  end
end
