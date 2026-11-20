# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "base64"
require "json"
require "openssl/hmac"
require "redis"
require "../config"
require "../database"
require "../iam/helpers"
require "../rbac/auth_context"
require "../util/crypto"
require "../util/script_helpers"

module Facet
  module Artifact
    # Single-use signed upload capability for agent surfaces (MCP).
    #
    # An MCP session cannot call the REST upload route: its bearer token
    # carries the MCP resource `aud`, which the REST audience rule rejects.
    # The bridge is a capability URL minted by the `request_artifact_upload`
    # tool — the agent's HTTP client POSTs the multipart body to it, and the
    # bytes enter through the standard `Artifact::Uploader.upload` machinery.
    # No file content ever rides the JSON-RPC channel.
    #
    # Three properties (the `OAuth::CodeStore` contract, applied to uploads):
    #
    # - **Single-use**: consume is a read-then-delete executed atomically
    #   through a Lua script. A second POST answers `already_used`.
    # - **TTL-bounded**: `artifact.upload_grant_ttl_seconds` (default 300).
    #   The Redis key expires on its own; the URL `exp` check answers
    #   `expired` with a body the agent can act on.
    # - **Bound to its issuance context**: the record carries the minting
    #   principal's `account_id` and `role_id`. Consume revalidates live
    #   state (account active, role still held, role still exists) before
    #   the upload runs — a mint does not freeze a stale principal.
    #
    # ## Why Redis, not PostgreSQL
    #
    # Same rationale as `OAuth::CodeStore`: the capability is ephemeral
    # transport state, not auditable policy. It has no value beyond its TTL
    # window — replay only succeeds while it is live, and only for one
    # upload. The resulting artifact carries its own durable provenance
    # (the `_account` owner row), which is the audit record that matters.
    module UploadGrants
      Log = ::Log.for("facet.artifact.upload_grants")

      KEY_PREFIX = "artifact_upload:"

      # The minted capability, as the tool returns it to the agent.
      record Minted,
        uid : String,
        url : String,
        expires_at : Time

      # The capability payload, as consumed by the upload route.
      record Capability,
        uid : String,
        account_id : String,
        role_id : String,
        expires_at : Time

      # Every consume failure names its cause. The URL is the caller's own
      # capability, so the distinction is not a disclosure: a caller cannot
      # forge a correctly signed URL for a uid it does not own (the HMAC
      # gate comes first), so the only reachable failures are the ones
      # below. Every failure answers the same 403 status.
      enum Failure
        InvalidSignature
        Expired
        AlreadyUsed
        Stale
      end

      # Read-then-delete, atomic — two concurrent consumes cannot both see
      # the record. Same script shape as `OAuth::CodeStore`.
      CONSUME_LUA = <<-LUA
        local k = KEYS[1]
        if redis.call("EXISTS", k) == 0 then
          return nil
        end
        local fields = redis.call("HGETALL", k)
        redis.call("DEL", k)
        return fields
      LUA

      # The Redis key lives five seconds past the signed expiry so the `exp`
      # check — not the key's disappearance — stays the authority on why a
      # late POST failed. A key that dies first would misreport an expired
      # capability as `already_used`.
      KEY_GRACE_S = 5

      # Mints a one-time upload capability for the calling principal. The
      # pinned role is the principal's active role — on the MCP surface
      # that is the URL-pinned role, so the upload's dedup readability
      # matches the session's view.
      def self.mint(auth_context : ::Facet::RBAC::AuthContext) : Minted
        if auth_context.system?
          raise "System principal cannot mint upload capabilities"
        end
        principal = auth_context.principal
        unless principal.is_a?(::Facet::RBAC::Principal::Real)
          raise "Only a real principal can mint upload capabilities"
        end

        uid = ::Facet::Util::ScriptHelpers.ulid
        # The qualified projection id — the form `iam.Helpers.find_role_content`
        # and the account document's `roles` array both use (the same
        # convention `Assistant::Access` and `ImportExport::CallerContext`
        # apply to `active_role.role_id`).
        role_id = "iam.Roles.#{principal.active_role.role_id}"
        ttl = ::Facet::Config.instance.artifact.upload_grant_ttl_seconds
        expires_at = Time.utc + ttl.seconds
        exp_unix = expires_at.to_unix.to_s

        r = redis
        r.hset(key_for(uid),
          "account_id", principal.account_id,
          "role_id", role_id,
          "exp", exp_unix,
          "created_at", Time.utc.to_rfc3339,
        )
        r.expire(key_for(uid), ttl + KEY_GRACE_S)

        Minted.new(uid: uid, url: signed_url(uid, exp_unix), expires_at: expires_at)
      end

      # Consumes a capability presented on the upload route. Verification
      # order is deliberate:
      #
      # 1. Signature and expiry (stateless, over the URL's own `(uid, exp)`)
      #    — a tampered URL never reaches Redis and never burns the real
      #    capability.
      # 2. Atomic consume — the first POST wins; every later POST of the
      #    same URL answers `already_used`.
      #
      # The record's stored `exp` must equal the URL's `exp`; a mismatch is
      # tampering and fails closed.
      def self.consume(uid : String, exp_param : String?, sig_param : String?) : Capability | Failure
        exp = verify_url(uid, exp_param, sig_param)
        return exp if exp.is_a?(Failure)

        record = consume_record(uid)
        return Failure::AlreadyUsed unless record
        return Failure::InvalidSignature unless record["exp"]? == exp_param

        account_id = record["account_id"]?
        role_id = record["role_id"]?
        return Failure::Stale unless account_id && role_id

        expires_at = Time.unix(exp)
        Log.debug { "Upload capability consumed (uid=#{uid}, role=#{role_id})" }
        Capability.new(uid: uid, account_id: account_id, role_id: role_id, expires_at: expires_at)
      end

      # Stateless URL verification: signature (HMAC over `(uid, exp)` under
      # `artifact_grant_secret`, constant-time compared) then expiry. Returns
      # the parsed `exp` unix value, or the `Failure` the route answers.
      private def self.verify_url(uid : String, exp_param : String?, sig_param : String?) : Int64 | Failure
        sig = sig_param.presence
        exp_raw = exp_param.presence
        return Failure::InvalidSignature if uid.empty? || sig.nil? || exp_raw.nil?

        exp = exp_raw.to_i64?
        return Failure::InvalidSignature unless exp

        secret = ::Facet::Config.instance.artifact_grant_secret
        unless ::Facet::Util::Crypto.constant_time_eq?(compute_hmac(uid, exp_raw, secret), sig)
          return Failure::InvalidSignature
        end

        return Failure::Expired if exp < Time.utc.to_unix
        exp
      end

      # Atomically reads and deletes the capability record (the Lua script
      # makes read-then-delete atomic). Returns `nil` for an unknown key —
      # expired, never minted, or already consumed.
      private def self.consume_record(uid : String) : Hash(String, String)?
        result = redis.eval(CONSUME_LUA, keys: [key_for(uid)], args: [] of String)
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
        h.empty? ? nil : h
      end

      # Rebuilds the `AuthContext` for a consumed capability, revalidating
      # live state — the same checks `MCP::Dispatch.load_verified_principal`
      # and `OAuth::Refresh.call_mcp` run on every request: the account row
      # exists (the reader filters tombstones), is `active`, still holds the
      # role, and the role projection still exists. Returns `nil` on any
      # failure — the route maps that to the `stale` reason.
      def self.build_auth_context(
        db : DB::Connection,
        capability : Capability,
      ) : ::Facet::RBAC::AuthContext?
        account = ::Facet::IAM::Helpers.find_account_by_id(db, capability.account_id)
        return nil unless account
        return nil unless account[:status] == "active"
        return nil unless account[:roles].includes?(capability.role_id)

        role_content = ::Facet::IAM::Helpers.find_role_content(db, capability.role_id)
        return nil unless role_content

        active_role = ::Facet::RBAC::ActiveRole.from_projection_content(role_content)
        ::Facet::RBAC::AuthContext.authenticated(capability.account_id, active_role)
      end

      # The underscore reason string the 403 body carries (`expired`,
      # `already_used`, …) — the field an agent reads to decide its next
      # step (re-mint vs give up).
      def self.failure_reason(failure : Failure) : String
        failure.to_s.underscore
      end

      # ── Internals ──────────────────────────────────────────────────────

      private def self.key_for(uid : String) : String
        "#{KEY_PREFIX}#{uid}"
      end

      # HMAC over `(uid, exp)` under `artifact_grant_secret` — the same
      # secret and shape family as the download grants (`Grants.compute_hmac`,
      # without the artifact-id/epoch segments a not-yet-existing artifact
      # cannot carry). Base64url without padding, constant-time compared.
      private def self.compute_hmac(uid : String, exp : String, secret : String) : String
        digest = ::OpenSSL::HMAC.digest(:sha256, secret, "#{uid}|#{exp}")
        Base64.urlsafe_encode(digest, padding: false)
      end

      private def self.signed_url(uid : String, exp : String) : String
        secret = ::Facet::Config.instance.artifact_grant_secret
        sig = compute_hmac(uid, exp, secret)
        base = ::Facet::Config.instance.artifact_base_url
        "#{base}/A/upload/#{uid}?exp=#{exp}&sig=#{sig}"
      end

      private def self.redis : ::Redis::Client
        Facet::Redis.client
      end
    end
  end
end
