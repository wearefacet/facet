# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "base64"
require "redis"

module Facet
  module OAuth
    # Redis-backed authorization code store.
    #
    # A code is issued by `Authorize` after the user confirms role election +
    # consent, and consumed once by `Token` to redeem an app JWT. The store
    # enforces three security properties:
    #
    # - **Single-use**: `consume` is a read-then-delete executed atomically
    #   through a Lua script. A second redemption returns `nil`; `Token`
    #   rejects with `invalid_grant`.
    # - **TTL-bounded**: 60 seconds. A code that is
    #   never redeemed expires on its own.
    # - **Bound to its issuance context**: every claim the token endpoint
    #   must re-check (`account_id`, `role_id`, `app_id`, `client_id`,
    #   `redirect_uri`, `code_challenge`) is stored on the code record.
    #
    # ## Why Redis, not PostgreSQL
    #
    # A code is ephemeral transport state, not auditable policy. It has no
    # value beyond its 60-second window — replay only succeeds while it is
    # live. PostgreSQL would add latency and write amplification for no gain.
    module CodeStore
      KEY_PREFIX = "oauth_code:"
      CODE_TTL_S = 60

      # A code record, as issued by `Authorize` and consumed by `Token`.
      #
      # `resource` (RFC 8707) and `mcp_role` are set only on the MCP branch
      # of the authorize flow: `resource` becomes the token's `aud` claim,
      # `mcp_role` is the role the MCP URL pins. Both are nil on app-branch
      # codes.
      record Code,
        code : String,
        account_id : String,
        role_id : String,
        app_id : String,
        client_id : String,
        redirect_uri : String,
        code_challenge : String, # SHA-256 digest, base64url-encoded by the client (S256)
        created_at : String,
        resource : String? = nil,
        mcp_role : String? = nil

      # Atomically reads the code record and deletes the key. Returns the
      # record on first redemption; returns `nil` on every subsequent call
      # (replay), for unknown codes, and for expired codes. The Lua script
      # makes the read-then-delete atomic — two concurrent `consume` calls
      # cannot both see the record.
      #
      # Redis Lua script semantics: returns a flat array `[k1, v1, k2, v2, …]`
      # (the result of `HGETALL`) or `nil` when the key did not exist.
      CONSUME_LUA = <<-LUA
        local k = KEYS[1]
        if redis.call("EXISTS", k) == 0 then
          return nil
        end
        local fields = redis.call("HGETALL", k)
        redis.call("DEL", k)
        return fields
      LUA

      # Persists a fresh code record. Returns the public code string (the
      # Redis key suffix) the caller appends to the `redirect_uri` as
      # `?code=...`.
      def self.issue(
        account_id : String,
        role_id : String,
        app_id : String,
        client_id : String,
        redirect_uri : String,
        code_challenge : String,
        resource : String? = nil,
        mcp_role : String? = nil,
      ) : String
        code = Random::Secure.urlsafe_base64(32)
        key = key_for(code)
        now = Time.utc.to_rfc3339

        r = redis
        r.hset(key,
          "account_id", account_id,
          "role_id", role_id,
          "app_id", app_id,
          "client_id", client_id,
          "redirect_uri", redirect_uri,
          "code_challenge", code_challenge,
          "created_at", now,
        )
        r.hset(key, "resource", resource) if resource
        r.hset(key, "mcp_role", mcp_role) if mcp_role
        r.expire(key, CODE_TTL_S)
        code
      end

      # Atomically consumes a code. Returns the record on first redemption;
      # returns `nil` on every subsequent call (replay) and for unknown /
      # expired codes.
      def self.consume(code : String) : Code?
        key = key_for(code)
        r = redis
        result = r.eval(CONSUME_LUA, keys: [key], args: [] of String)
        return nil if result.nil?
        return nil unless result.is_a?(Array)
        return nil if result.empty?

        h = {} of String => String
        vals = result
        i = 0
        while i + 1 < vals.size
          k = vals[i]
          v = vals[i + 1]
          if k.is_a?(String) && v.is_a?(String)
            h[k] = v
          end
          i += 2
        end
        return nil if h.empty?
        build_record(code, h)
      end

      # ── Internals ──────────────────────────────────────────────────────

      private def self.key_for(code : String) : String
        "#{KEY_PREFIX}#{code}"
      end

      private def self.redis : ::Redis::Client
        Facet::Redis.client
      end

      private def self.build_record(code : String, h : Hash(String, String)) : Code?
        account_id = h["account_id"]?
        role_id = h["role_id"]?
        app_id = h["app_id"]?
        client_id = h["client_id"]?
        redirect_uri = h["redirect_uri"]?
        code_challenge = h["code_challenge"]?
        created_at = h["created_at"]? || Time.utc.to_rfc3339
        return nil unless account_id && role_id && app_id && client_id &&
                          redirect_uri && code_challenge
        Code.new(
          code: code,
          account_id: account_id,
          role_id: role_id,
          app_id: app_id,
          client_id: client_id,
          redirect_uri: redirect_uri,
          code_challenge: code_challenge,
          created_at: created_at,
          resource: h["resource"]?.try(&.presence),
          mcp_role: h["mcp_role"]?.try(&.presence),
        )
      end
    end
  end
end
