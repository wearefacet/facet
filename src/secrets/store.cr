# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./config"
require "./codec"
require "../config"

module Facet
  # Generalized secret store — durable secrets keyed by document + slot,
  # stored out-of-band from the event-sourced doctype system.
  #
  # A secret never enters `mutations` or `projections.content`. Values are
  # written only through this module (or staged out-of-band and adopted
  # during a mutation), so no read path — HTTP, MCP, Lua, export, copy —
  # can disclose a secret value.
  #
  # The `mode` enum is closed and selects the consumer operation:
  #
  # | mode      | consumer | payload                                          |
  # |-----------|----------|--------------------------------------------------|
  # | `hash`    | `verify` | bcrypt modular-crypt string (SHA-256 pre-hashed)  |
  # | `sealed`  | `reveal` | AES-256-GCM, bound to `(doc_ref, slot)` via AAD   |
  # | `token`   | `consume`| SHA-256 digest; consumed exactly once             |
  #
  # Slot names `password`, `mfa`, and `reset` are reserved for IAM on
  # `iam.Account` documents.
  #
  # Every method takes a `DB::Connection`; callers wrap them in their own
  # transaction where atomicity with a mutation matters.
  module Secrets
    BATCH_SIZE = 500

    # The closed mode enum. Anything else fails closed at `set` time.
    MODES = %w[hash sealed token]

    record DocRef, domain : String, doc_type : String, doc_id : String
    record Consumed, domain : String, doc_type : String, doc_id : String, meta : JSON::Any

    @@dummy_hash : {Int32, String}? = nil

    # ── doc_ref parsing ───────────────────────────────────────────────

    # Parses the qualified reference `"domain.DocType.id"`. One parser
    # serves the whole module — `secrets`, `auth_state`, and callers all
    # speak the same document key.
    def self.resolve(doc_ref : String) : DocRef
      parts = doc_ref.split(".", limit: 3)
      unless parts.size == 3
        raise ArgumentError.new("Malformed doc_ref '#{doc_ref}' — expected 'domain.DocType.id'")
      end
      DocRef.new(parts[0], parts[1], parts[2])
    end

    # ── writes ────────────────────────────────────────────────────────

    # Upserts one slot. Returns the new version (1 on insert, existing + 1
    # on update).
    #
    # `hash` forbids a TTL and `token` requires one — both fail closed.
    # `sealed` takes an optional TTL (`reveal` rejects expired rows).
    def self.set(
      db : DB::Connection,
      doc_ref : String,
      slot : String,
      value : String,
      mode : String,
      set_by : String,
      ttl : Time::Span? = nil,
      meta : ::Hash(String, String)? = nil,
    ) : Int32
      ref = resolve(doc_ref)
      validate_mode!(mode, ttl)
      payload = encode!(mode, value, doc_ref, slot)
      expires_at = ttl ? Time.utc + ttl : nil
      meta_json = meta ? meta.to_json : "{}"

      upsert(db, ref, slot, mode, payload, meta_json, expires_at, set_by)
    end

    # Upserts one slot from an already-encoded payload.
    #
    # The adoption step uses this: a staged handle carries a codec payload
    # (bcrypt string, GCM payload, token digest), so re-encoding through
    # `set` would corrupt it. Versioning, TTL validation, and the closed
    # mode enum behave exactly like `set`.
    def self.set_payload(
      db : DB::Connection,
      doc_ref : String,
      slot : String,
      payload : String,
      mode : String,
      set_by : String,
      ttl : Time::Span? = nil,
      meta_json : String = "{}",
    ) : Int32
      ref = resolve(doc_ref)
      validate_mode!(mode, ttl)
      expires_at = ttl ? Time.utc + ttl : nil
      upsert(db, ref, slot, mode, payload, meta_json, expires_at, set_by)
    end

    # Clears one slot. No-op when the slot is empty.
    def self.clear(db : DB::Connection, doc_ref : String, slot : String) : Nil
      ref = resolve(doc_ref)
      db.exec(
        "DELETE FROM secrets WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
        ref.domain, ref.doc_type, ref.doc_id, slot,
      )
    end

    # Copies one slot from one document to another.
    #
    # - `hash`: the payload copies as-is (bcrypt is position-independent).
    # - `sealed`: the payload is opened under the source binding and
    #   re-sealed under the target binding — the AAD binding requires it.
    # - `token`: refused. A token must not serve two documents.
    def self.copy_slot(db : DB::Connection, from_ref : String, to_ref : String, slot : String) : Nil
      src = resolve(from_ref)
      dst = resolve(to_ref)

      row = db.query_one?(
        "SELECT mode, value, meta, expires_at, set_by FROM secrets " \
        "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
        src.domain, src.doc_type, src.doc_id, slot,
        as: {String, String, JSON::Any, Time?, String},
      )
      raise ArgumentError.new("No secret at slot '#{slot}' on #{from_ref}") if row.nil?

      mode, value, meta, expires_at, set_by = row
      case mode
      when "token"
        raise ArgumentError.new(
          "Refusing to copy token slot '#{slot}' — a token must not serve two documents"
        )
      when "hash"
        # Copy the payload as-is at the database level, carrying meta,
        # expiry, and authorship unchanged.
        db.exec(
          <<-SQL,
            INSERT INTO secrets (domain, doc_type, doc_id, slot, mode, value, meta, expires_at, set_by, set_at)
            SELECT $4, $5, $6, slot, mode, value, meta, expires_at, set_by, now()
            FROM secrets
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $7
            ON CONFLICT (domain, doc_type, doc_id, slot) DO UPDATE SET
              mode = EXCLUDED.mode,
              value = EXCLUDED.value,
              meta = EXCLUDED.meta,
              expires_at = EXCLUDED.expires_at,
              version = secrets.version + 1,
              set_by = EXCLUDED.set_by,
              set_at = now()
          SQL
          src.domain, src.doc_type, src.doc_id,
          dst.domain, dst.doc_type, dst.doc_id, slot,
        )
      when "sealed"
        plaintext = Codec.open(value, from_ref, slot)
        payload = Codec.seal(plaintext, to_ref, slot)
        upsert(db, dst, slot, mode, payload, meta.to_json, expires_at, set_by)
      else
        raise ArgumentError.new("Unknown secret mode '#{mode}'")
      end
    end

    # ── reads ─────────────────────────────────────────────────────────

    # Compares a candidate against a stored secret.
    #
    # Returns `nil` when no row exists (the caller decides what a missing
    # slot means), `false` on mismatch, `true` on match. When the row is
    # missing, a dummy bcrypt comparison burns the same time as a real
    # verify so an unknown account and a wrong password cost the same.
    #
    # `sealed` secrets are never compared — reveal is the only consumer.
    def self.verify(db : DB::Connection, doc_ref : String, slot : String, candidate : String) : Bool?
      ref = resolve(doc_ref)
      row = db.query_one?(
        "SELECT mode, value FROM secrets " \
        "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4",
        ref.domain, ref.doc_type, ref.doc_id, slot,
        as: {String, String},
      )

      if row.nil?
        burn_dummy_verify(candidate)
        return nil
      end

      mode, value = row
      case mode
      when "hash"
        Codec.verify_hash(candidate, value)
      when "token"
        stored = Codec.token_digest_from_payload(value)
        return false if stored.nil?
        Codec.constant_time_equal(Codec.token_digest(candidate), stored)
      else
        raise ArgumentError.new("verify is not valid for '#{mode}' secrets (slot '#{slot}')")
      end
    end

    # Reveals a `sealed` secret. Returns `nil` when the slot is missing or
    # past its TTL. Raises when the payload fails to open (tamper, AAD
    # mismatch, unknown key) — fail loud, never fall back.
    def self.reveal(db : DB::Connection, doc_ref : String, slot : String) : String?
      ref = resolve(doc_ref)
      row = db.query_one?(
        "SELECT mode, value FROM secrets " \
        "WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND slot = $4 " \
        "AND (expires_at IS NULL OR expires_at > now())",
        ref.domain, ref.doc_type, ref.doc_id, slot,
        as: {String, String},
      )
      return nil if row.nil?

      mode, value = row
      unless mode == "sealed"
        raise ArgumentError.new("reveal is only valid for sealed secrets (slot '#{slot}' is '#{mode}')")
      end

      Codec.open(value, doc_ref, slot)
    end

    # Consumes a `token` by value alone — the caller holds only the token
    # and does not know the document.
    #
    # One atomic `DELETE … RETURNING` with the TTL in the same statement.
    # Zero rows means missing, expired, or already used: the caller fails
    # closed. The digest doubles as the lookup key (unique partial index on
    # token payloads).
    def self.consume(
      db : DB::Connection,
      slot : String,
      raw_token : String,
      domain : String? = nil,
    ) : Consumed?
      payload = Codec.token_payload(raw_token)

      row = if domain
              db.query_one?(
                "DELETE FROM secrets WHERE slot = $1 AND value = $2 AND mode = 'token' " \
                "AND expires_at > now() AND domain = $3 " \
                "RETURNING domain, doc_type, doc_id, meta",
                slot, payload, domain,
                as: {String, String, String, JSON::Any},
              )
            else
              db.query_one?(
                "DELETE FROM secrets WHERE slot = $1 AND value = $2 AND mode = 'token' " \
                "AND expires_at > now() " \
                "RETURNING domain, doc_type, doc_id, meta",
                slot, payload,
                as: {String, String, String, JSON::Any},
              )
            end
      return nil if row.nil?

      doc_domain, doc_type, doc_id, meta = row
      Consumed.new(doc_domain, doc_type, doc_id, meta)
    end

    # ── pruning ───────────────────────────────────────────────────────

    # Deletes secret rows past their retention window:
    #
    # - rows whose document is tombstoned (a hard delete cascades already;
    #   tombstones keep the rows until this pass),
    # - expired `token` rows past the same window,
    # - expired `secret_staging` rows (the stage-handle TTL sweep — a
    #   staging row is TTL-bound, not retention-bound, so the window does
    #   not apply).
    #
    # Returns the number of rows deleted. Batched like
    # `Cron::TombstoneContentPrune` so a failure never rolls back earlier
    # batches and a rerun resumes.
    def self.prune(db : DB::Connection, retention_days : Int32) : Int32
      prune_tombstoned(db, retention_days) +
        prune_expired_tokens(db, retention_days) +
        sweep_expired_staging(db)
    end

    # ── Private ───────────────────────────────────────────────────────

    private def self.validate_mode!(mode : String, ttl : Time::Span?) : Nil
      unless MODES.includes?(mode)
        raise ArgumentError.new("Unknown secret mode '#{mode}' (allowed: #{MODES.join(", ")})")
      end
      raise ArgumentError.new("A 'token' secret requires a ttl") if mode == "token" && ttl.nil?
      raise ArgumentError.new("A 'hash' secret must not carry a ttl") if mode == "hash" && ttl
    end

    private def self.encode!(mode : String, value : String, doc_ref : String, slot : String) : String
      case mode
      when "hash"   then Codec.hash_payload(value)
      when "sealed" then Codec.seal(value, doc_ref, slot)
      when "token"  then Codec.token_payload(value)
      else               raise ArgumentError.new("Unknown secret mode '#{mode}'")
      end
    end

    private def self.upsert(
      db : DB::Connection,
      ref : DocRef,
      slot : String,
      mode : String,
      payload : String,
      meta_json : String,
      expires_at : Time?,
      set_by : String,
    ) : Int32
      db.query_one(
        <<-SQL,
          INSERT INTO secrets (domain, doc_type, doc_id, slot, mode, value, meta, expires_at, set_by, set_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now())
          ON CONFLICT (domain, doc_type, doc_id, slot) DO UPDATE SET
            mode = EXCLUDED.mode,
            value = EXCLUDED.value,
            meta = EXCLUDED.meta,
            expires_at = EXCLUDED.expires_at,
            version = secrets.version + 1,
            set_by = EXCLUDED.set_by,
            set_at = now()
          RETURNING version
        SQL
        ref.domain, ref.doc_type, ref.doc_id, slot,
        mode, payload, meta_json, expires_at, set_by,
        as: Int32,
      )
    end

    private def self.prune_tombstoned(db : DB::Connection, retention_days : Int32) : Int32
      total = 0
      loop do
        keys = db.query_all(
          <<-SQL,
            SELECT DISTINCT s.domain, s.doc_type, s.doc_id
            FROM secrets s
            JOIN projections p
              ON p.domain = s.domain AND p.doc_type = s.doc_type AND p.id = s.doc_id
            WHERE p.deleted_at IS NOT NULL
              AND p.deleted_at < now() - make_interval(days => $1)
            LIMIT #{BATCH_SIZE}
          SQL
          retention_days,
          as: {String, String, String},
        )
        break if keys.empty?

        domains = keys.map { |k| k[0] }
        doc_types = keys.map { |k| k[1] }
        doc_ids = keys.map { |k| k[2] }
        result = db.exec(
          <<-SQL,
            DELETE FROM secrets s
            USING unnest($1::varchar[], $2::varchar[], $3::text[]) AS k(domain, doc_type, doc_id)
            WHERE s.domain = k.domain
              AND s.doc_type = k.doc_type
              AND s.doc_id = k.doc_id
          SQL
          domains, doc_types, doc_ids,
        )
        total += result.rows_affected
        break if keys.size < BATCH_SIZE
      end
      total
    end

    private def self.prune_expired_tokens(db : DB::Connection, retention_days : Int32) : Int32
      db.exec(
        <<-SQL,
          DELETE FROM secrets
          WHERE mode = 'token'
            AND expires_at IS NOT NULL
            AND expires_at < now() - make_interval(days => $1)
        SQL
        retention_days,
      ).rows_affected.to_i32
    end

    # Deletes staging rows whose TTL has passed. Single statement — the
    # table holds only short-lived rows by construction.
    private def self.sweep_expired_staging(db : DB::Connection) : Int32
      db.exec(
        "DELETE FROM secret_staging WHERE expires_at < now()",
      ).rows_affected.to_i32
    end

    # Burns one bcrypt comparison against a memoized dummy hash so a
    # missing slot costs the same as a wrong password (invariant 4). The
    # hash is created once per cost value; every call after that is a
    # verify — the same operation a real comparison performs.
    private def self.burn_dummy_verify(candidate : String) : Nil
      Codec.verify_hash(candidate, dummy_hash)
    end

    private def self.dummy_hash : String
      cost = Facet::Config.instance.secrets.bcrypt_cost
      cached = @@dummy_hash
      return cached[1] if cached && cached[0] == cost

      payload = Codec.hash_payload("facet-secrets-dummy-verify-burn")
      @@dummy_hash = {cost, payload}
      payload
    end
  end
end
