# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "random/secure"
require "pg"
require "log"
require "../database"
require "../error"
require "./helpers"
require "../util/script_helpers"
require "../util/crypto"
require "../util/time_helper"

module Facet
  module IAM
    # Static bearer API keys for machine-to-machine access.
    #
    # A key pins one `{account, role}` pair and is self-service: an
    # authenticated account creates, lists, and revokes its own keys through
    # `/Api/iam/keys`. Storage keeps only a SHA-256 hash of the full token —
    # the raw key is shown once in the create response.
    #
    # Keys are verified per request (no cache): the row is looked up by hash,
    # then liveness is checked — not revoked, not expired, account projection
    # live and `active`, role still assigned to the account, role document
    # still present, and the role's connectivity still carries the `api`
    # channel. A key therefore dies with its pair: revocation, expiry,
    # role unassignment, role deletion, channel removal, account deletion,
    # or account disablement all invalidate it immediately.
    #
    # Not event-sourced — same precedent as the `secrets` store
    # (migration 0018): credential material never enters the event log.
    module ApiKey
      # Token prefix — never collides with a JWT (`a.b.c` shape) or an opaque
      # `session_id.refresh_id` pair, so `AuthHandler` can branch on it alone.
      PREFIX = "fct_"

      # Body length in Crockford Base32 chars (26 × 5 bits = 130 bits).
      BODY_LENGTH = 26

      # Total token length: `fct_` + 26 body chars.
      TOKEN_LENGTH = PREFIX.size + BODY_LENGTH

      # Display prefix: `fct_` + the first 6 body chars. Lets list views
      # identify a key without the secret.
      DISPLAY_PREFIX_LENGTH = PREFIX.size + 6

      # Human-label cap for `name`.
      NAME_MAX_LENGTH = 100

      # One `last_used_at` write per minute per key — an automated client
      # would otherwise turn every request into a write path.
      LAST_USED_THROTTLE = "1 minute"

      # A freshly generated key. `key` is the raw token — shown exactly once.
      record Created,
        id : String,
        key : String,
        display_prefix : String,
        expires_at : String?

      # Verification result: everything `AuthHandler` needs to build the
      # request's `AuthContext`. `role_content` is the live role projection
      # content (already loaded during verification) so the caller does not
      # re-query it. Carries the row id — never the secret.
      #
      # App-owned rows (an `app_id` from the key route) also carry the app's
      # live content, so the handler can resolve the grant without re-reading
      # the projection. `app_id` and `app_content` are always set together.
      record Verified,
        key_id : String,
        account_id : String,
        role_id : String,
        role_content : JSON::Any,
        app_id : String? = nil,
        app_content : JSON::Any? = nil

      # A listed key row — never contains the secret hash or any usable
      # token material.
      record Row,
        id : String,
        name : String,
        display_prefix : String,
        role_id : String,
        created_at : Time,
        expires_at : Time?,
        last_used_at : Time?,
        revoked_at : Time?

      # ── Token generation ───────────────────────────────────────────────

      # Generates a full token: `fct_` + 26 Crockford Base32 chars.
      #
      # 130 bits of entropy from `Random::Secure`. Each char draws one random
      # byte masked to 5 bits — uniform, because 256 divides evenly into 32
      # buckets. Not a ULID: keys are random, not sortable, and carry no
      # timestamp.
      def self.generate_token : String
        bytes = Random::Secure.random_bytes(BODY_LENGTH)
        String.build(TOKEN_LENGTH) do |io|
          io << PREFIX
          bytes.each do |byte|
            io << Util::ScriptHelpers::CROCKFORD[byte & 0x1F]
          end
        end
      end

      # True if the token has the `fct_` shape (prefix + 26 body chars).
      # Used by `AuthHandler` to branch before JWT decoding.
      def self.token?(value : String) : Bool
        value.size == TOKEN_LENGTH && value.starts_with?(PREFIX)
      end

      # ── Generate ───────────────────────────────────────────────────────

      # Creates a key row for the `{account_id, role_id}` pair and returns
      # the one-time response. `expires_at` is a normalized UTC RFC-3339
      # string (already validated by the route) or `nil` for no expiry.
      # `app_id` tags an app-owned key (backend apps); `nil` is a normal
      # self-service key.
      def self.generate(
        db : DB::Connection,
        account_id : String,
        role_id : String,
        name : String,
        expires_at : String? = nil,
        app_id : String? = nil,
      ) : Created
        token = generate_token
        id = Util::ScriptHelpers.ulid
        hash = Util::ScriptHelpers.sha256(token)
        prefix = token[0, DISPLAY_PREFIX_LENGTH]

        db.exec(
          <<-SQL,
            INSERT INTO api_keys (id, account_id, role_id, name, secret_hash, display_prefix, expires_at, app_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
          SQL
          id, account_id, role_id, name, hash, prefix, expires_at, app_id
        )

        Created.new(id: id, key: token, display_prefix: prefix, expires_at: expires_at)
      end

      # ── Verify ─────────────────────────────────────────────────────────

      # Verifies a presented token and runs every liveness check. Returns
      # `nil` on any failure — callers translate that into a bare 401 with
      # no detail (anti-enumeration).
      #
      # Pipeline:
      # 1. SHA-256 lookup by unique index. Missing, revoked, or expired → nil.
      # 2. Account projection live (`deleted_at IS NULL`), `status == "active"`,
      #    and `role_id ∈ account.roles` → else nil.
      # 3. Role projection present, and its `connectivity` carries the `api`
      #    channel → else nil (a role edited down to browser-only kills every
      #    key pinned to it on their next use; a malformed list fails closed).
      # 4. App-owned rows: the named `app.App` projection must be live and
      #    `status == "active"` (mirrors the OAuth branch's app gate).
      # 5. Touch `last_used_at` (throttled to one write per minute).
      def self.verify(db : DB::Connection, token : String) : Verified?
        return nil unless token?(token)

        row = verify_row(db, token)
        return nil unless row

        return nil if row[:revoked_at]
        if expires_at = row[:expires_at]
          return nil if expires_at <= Time.utc
        end

        account_id = row[:account_id]
        role_id = row[:role_id]

        # Account liveness + status + role assignment, in one projection read.
        # The role-assignment check is what makes a key die when the account
        # loses the pinned role (mirrors `Refresh` "Role not assigned").
        account = Helpers.find_account_by_id(db, account_id)
        return nil unless account
        return nil unless account[:status] == "active"
        return nil unless account[:roles].includes?(role_id)

        # Role document must still exist (deleted role → dead key), and its
        # connectivity must still carry the `api` channel. Verify is
        # uncached, so a channel flip applies on the next request.
        role_content = Helpers.find_role_content(db, role_id)
        return nil unless role_content
        return nil unless role_api_enabled?(role_content)

        # App-owned key: the named app must be live and active — a disabled
        # app's key is dead, the same contract the OAuth branch enforces.
        app_gate = verify_app_gate(db, row[:app_id], row[:id])
        return nil unless app_gate
        app_id, app_content = app_gate

        # Escalation (§4.6.1): verify runs on the ro pin, and the throttled
        # `last_used_at` touch is the one sanctioned write here. It opens a
        # nested rw block of its own — its own connection, its own
        # transaction, never atomic with anything the caller does.
        # `ignore_if_set` lets the touch join a caller's transaction when
        # verification runs inside a rw scope (the pin-reuse contract
        # returns the held rw connection); the timestamp is informational,
        # so losing the touch to an outer rollback is acceptable.
        Database.with_db(:read_write) do |rw_db|
          Database.with_transaction(rw_db, ignore_if_set: true) do |txn|
            touch_last_used_at(txn, row[:id])
          end
        end
        Verified.new(
          key_id: row[:id],
          account_id: account_id,
          role_id: role_id,
          role_content: role_content,
          app_id: app_id,
          app_content: app_content,
        )
      end

      # The app-owned liveness gate: a key with an `app_id` must name a live,
      # active `app.App` (a disabled app's key is dead). A self-service key
      # passes through with nil content. Returns nil when the gate fails.
      # The 401 body names nothing (anti-enumeration); the WARN log names
      # the reason for the operator, like the refusals in `AuthHandler`.
      private def self.verify_app_gate(db : DB::Connection, app_id : String?, key_id : String)
        return {nil, nil} unless app_id
        app_content = active_app_content(db, app_id, key_id)
        return nil unless app_content
        {app_id, app_content}
      end

      # Looks the key row up by the token's SHA-256 (unique index). Returns
      # nil for a token that names no row — liveness checks run in `verify`.
      private def self.verify_row(db : DB::Connection, token : String)
        db.query_one?(
          <<-SQL,
            SELECT id, account_id, role_id, expires_at, revoked_at, app_id
            FROM api_keys
            WHERE secret_hash = $1
          SQL
          Util::ScriptHelpers.sha256(token)
        ) do |rs|
          {
            id:         rs.read(String),
            account_id: rs.read(String),
            role_id:    rs.read(String),
            expires_at: rs.read(Time?),
            revoked_at: rs.read(Time?),
            app_id:     rs.read(String?),
          }
        end
      end

      # True when the role content's `connectivity` list carries the `api`
      # channel. A missing or malformed list reads as empty — fail closed:
      # a role whose list cannot be read never opens the channel.
      private def self.role_api_enabled?(role_content : JSON::Any) : Bool
        channels = role_content["connectivity"]?.try(&.as_a?) || return false
        channels.any?(&.as_s?.try(&.==("api")))
      end

      # Loads the `app.App` projection for an app-owned key and gates on its
      # status. Returns nil when the app row is missing or not active — a
      # disabled app's key is dead, the same contract the OAuth branch
      # enforces. Each refusal logs one WARN line and tags the span; the
      # response body stays opaque.
      private def self.active_app_content(db : DB::Connection, app_id : String, key_id : String) : JSON::Any?
        app_row = db.query_one?(
          "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          app_id,
          as: JSON::Any,
        )
        unless app_row
          Log.warn { "app-owned API key refused: app projection is missing (app #{app_id}, key #{key_id})" }
          if span = OpenTelemetry.current_span
            span["auth.refused"] = "app_missing"
          end
          return nil
        end

        app_status = app_row.as_h["status"]?.try(&.as_s?) || "draft"
        unless app_status == "active"
          Log.warn { "app-owned API key refused: app status is #{app_status}, expected active (app #{app_id}, key #{key_id})" }
          if span = OpenTelemetry.current_span
            span["auth.refused"] = "app_status"
          end
          return nil
        end

        app_row
      end

      # ── List / Revoke ──────────────────────────────────────────────────

      # Lists the caller's keys, newest first. Never exposes the secret.
      def self.list(db : DB::Connection, account_id : String) : Array(Row)
        db.query_all(
          <<-SQL,
            SELECT id, name, display_prefix, role_id, created_at, expires_at, last_used_at, revoked_at
            FROM api_keys
            WHERE account_id = $1
            ORDER BY created_at DESC
          SQL
          account_id
        ) do |rs|
          Row.new(
            id: rs.read(String),
            name: rs.read(String),
            display_prefix: rs.read(String),
            role_id: rs.read(String),
            created_at: rs.read(Time),
            expires_at: rs.read(Time?),
            last_used_at: rs.read(Time?),
            revoked_at: rs.read(Time?)
          )
        end
      end

      # Loads one key row owned by the caller. Returns `nil` when the row
      # does not exist or belongs to another account (ownership gate for the
      # revoke route).
      def self.find_owned(db : DB::Connection, account_id : String, key_id : String) : Row?
        list(db, account_id).find { |row| row.id == key_id }
      end

      # Soft-revokes a key. Idempotent: a second call on an already-revoked
      # key is a no-op. Returns `true` when this call performed the revoke
      # (first time only), `false` when the key was already revoked.
      def self.revoke(db : DB::Connection, account_id : String, key_id : String) : Bool
        result = db.exec(
          <<-SQL,
            UPDATE api_keys
            SET revoked_at = now()
            WHERE id = $1 AND account_id = $2 AND revoked_at IS NULL
          SQL
          key_id, account_id
        )
        result.rows_affected > 0
      end

      # ── Private ────────────────────────────────────────────────────────

      # Throttled `last_used_at` touch: writes at most once per minute per
      # key. The timestamp is informational — a stale value never blocks
      # verification. The caller owns the transaction: the auth handler's
      # verification path wraps this in a nested rw escalation (§4.6.1),
      # write-path callers already hold a rw transaction.
      private def self.touch_last_used_at(db : DB::Connection, key_id : String) : Nil
        db.exec(
          <<-SQL,
            UPDATE api_keys
            SET last_used_at = now()
            WHERE id = $1
              AND (last_used_at IS NULL OR last_used_at < now() - interval '#{LAST_USED_THROTTLE}')
          SQL
          key_id
        )
      end
    end
  end
end
