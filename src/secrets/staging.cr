# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "./store"

module Facet
  module Secrets
    # Out-of-band staging for doctype `secret` fields.
    #
    # A stage handle is a **single-use bearer capability**: the client
    # stages a value through `POST /Api/secrets/stage`, receives a handle
    # (`sh_` + ULID), and puts the handle into the document body. The write
    # pipeline's adoption step (`Secrets::Adoption`) resolves the handle
    # inside the mutation's transaction: the slot row is upserted, the
    # staging row is deleted, and the content carries the marker only.
    #
    # A handle is bound to the account that staged it (`created_by`), to the
    # target field (`field_path` + `domain` + `doc_type`), to the declared
    # mode, and to a TTL (`expires_at`, config `secrets.staging_ttl_seconds`,
    # default 900 s). Expired rows are swept by `Cron::SecretsPrune`.
    #
    # A staged value is already a codec payload — the plaintext never
    # touches the staging table unencoded (invariant 1).
    #
    # `sealed` payloads are sealed under the staging binding
    # `("staging", handle)`; adoption opens them under that binding and
    # re-seals under the final `(doc_ref, slot)` binding, because the
    # AAD makes a payload valid for exactly one row.
    module Staging
      # The synthetic doc_ref under which `sealed` payloads are sealed while
      # staged. Adoption re-seals under the real document binding.
      STAGING_DOC_REF = "staging.staging.%s"

      # Shared raw-token generator constants (appendix: one shared constant,
      # not two). The 30-character alphabet is Crockford Base32 minus the
      # `0`/`1` confusables (`I L O U` are already absent from Crockford).
      # 16 characters over 30 symbols ≈ 78.5 bits of entropy. Draw each
      # character with `Random::Secure.rand(30)` — the `byte & 0x1F` trick
      # is only uniform for a power-of-two alphabet.
      RAW_TOKEN_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ"
      RAW_TOKEN_LENGTH   = 16

      record Row,
        id : String,
        mode : String,
        value : String,
        meta : JSON::Any,
        domain : String,
        doc_type : String,
        field_path : String,
        created_by : String,
        expires_at : Time

      # Generates a raw one-time token from the shared no-confusable
      # alphabet. The caller shows it once and stores only its digest.
      def self.generate_raw_token : String
        String.build(RAW_TOKEN_LENGTH) do |io|
          RAW_TOKEN_LENGTH.times do
            io << RAW_TOKEN_ALPHABET[Random::Secure.rand(RAW_TOKEN_ALPHABET.size)]
          end
        end
      end

      # The doc_ref a `sealed` payload is bound to while staged.
      def self.doc_ref(handle : String) : String
        STAGING_DOC_REF % handle
      end

      # Inserts one staging row and returns its handle. Pass `handle` when
      # the caller pre-minted it (the `sealed` path binds the payload's AAD
      # to the handle before insertion).
      #
      # `value` is the codec payload (hash bcrypt string, sealed GCM payload
      # sealed under `doc_ref(handle)`, or token digest). The TTL comes from
      # config (`secrets.staging_ttl_seconds`).
      def self.insert(
        db : DB::Connection,
        mode : String,
        value : String,
        domain : String,
        doc_type : String,
        field_path : String,
        created_by : String,
        meta : ::Hash(String, String)? = nil,
        handle : String? = nil,
      ) : String
        handle = "sh_" + Util::ScriptHelpers.ulid if handle.nil?
        ttl = Facet::Config.instance.secrets.staging_ttl_seconds

        db.exec(
          "INSERT INTO secret_staging (id, mode, value, meta, domain, doc_type, field_path, created_by, expires_at) " \
          "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now() + make_interval(secs => $9))",
          handle, mode, value, (meta || {} of String => String).to_json,
          domain, doc_type, field_path, created_by, ttl.to_f,
        )

        handle
      end

      # Loads one staging row, or `nil` when the handle is unknown.
      def self.load(db : DB::Connection, handle : String) : Row?
        db.query_one?(
          "SELECT id, mode, value, meta, domain, doc_type, field_path, created_by, expires_at " \
          "FROM secret_staging WHERE id = $1",
          handle,
          as: {String, String, String, JSON::Any, String, String, String, String, Time},
        ).try { |r| Row.new(*r) }
      end

      # Deletes one staging row. No-op when absent.
      def self.delete(db : DB::Connection, handle : String) : Nil
        db.exec("DELETE FROM secret_staging WHERE id = $1", handle)
      end
    end
  end
end
