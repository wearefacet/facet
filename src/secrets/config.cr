# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"
require "base64"

module Facet
  module Secrets
    # Tunable knobs for the generalized secret store.
    #
    # Loaded from the `secrets:` section of `config.{env}.yml`. Unlike most
    # sections, `master_key` is **hard-required**: the store fails closed at
    # config load time when the key is missing or too short — a typo must
    # never degrade into silently storing secrets under weak key material.
    #
    # - `master_key` — base64 of 32 random bytes. The AES-256 key for
    #   `sealed` payloads. Production supplies it via `!env
    #   SECRETS_MASTER_KEY`; dev and test configs carry literal keys.
    # - `bcrypt_cost` — cost parameter for `hash` mode payloads. Defaults
    #   to 12; test configs set a low value so the suite stays fast.
    # - `staging_ttl_seconds` — stage-handle TTL for the out-of-band stage
    #   route (used by the doctype `secret` field pipeline). Defaults 900.
    # - `prune_after_days` — retention window for `Cron::SecretsPrune`.
    #   Defaults 30.
    # - `prune_cron` — cron expression for the prune task. Defaults to
    #   daily at 04:45, offset from the tombstone prune at 04:15.
    struct Config
      # Key identifier baked into `sealed` payloads. The key map has one
      # entry today (`default`); the `kid` field exists so a future key
      # rotation can mint payloads under a new id while old payloads still
      # open with the old key.
      DEFAULT_KID = "default"

      # Minimum decoded size of `master_key` in bytes. 32 bytes = AES-256.
      MIN_KEY_BYTES = 32

      getter master_key : String
      getter bcrypt_cost : Int32
      getter staging_ttl_seconds : Int32
      getter prune_after_days : Int32
      getter prune_cron : String

      def initialize(
        @master_key : String = "",
        @bcrypt_cost : Int32 = 12,
        @staging_ttl_seconds : Int32 = 900,
        @prune_after_days : Int32 = 30,
        @prune_cron : String = "45 4 * * *",
      )
      end

      # Fails closed when the key material is missing or too short. Called
      # by `Facet::Config.load_secrets` — a config file without real key
      # material must fail at load time, never degrade into storing secrets
      # under weak keys.
      def validate! : Nil
        decoded = begin
          Base64.decode(@master_key)
        rescue
          raise ArgumentError.new(
            "Invalid 'secrets.master_key' — the value must be base64. " \
            "Generate one with: openssl rand -base64 32"
          )
        end

        if decoded.size < MIN_KEY_BYTES
          raise ArgumentError.new(
            "'secrets.master_key' decodes to #{decoded.size} bytes; at least " \
            "#{MIN_KEY_BYTES} are required (AES-256). " \
            "Generate one with: openssl rand -base64 32 and supply it via " \
            "!env SECRETS_MASTER_KEY in production."
          )
        end
      end

      # Parses the `secrets:` section of `config.{env}.yml`. The record
      # itself stays permissive (programmatic `Config` construction in specs
      # and tools may omit the section); the fail-closed check lives in
      # `validate!`, which `Facet::Config.load_secrets` calls on every config
      # file load. A present-but-empty section wraps nil — treat it like an
      # absent section, so `validate!` raises the fail-closed message and a
      # raw YAML error never escapes.
      def self.from_yaml(raw : YAML::Any?) : self
        return new if raw.nil? || raw.raw.nil?

        new(
          master_key: raw["master_key"]?.try(&.as_s) || "",
          bcrypt_cost: read_int(raw["bcrypt_cost"]?, 12),
          staging_ttl_seconds: read_int(raw["staging_ttl_seconds"]?, 900),
          prune_after_days: read_int(raw["prune_after_days"]?, 30),
          prune_cron: raw["prune_cron"]?.try(&.as_s) || "45 4 * * *",
        )
      end

      # Returns the AES key bytes for a payload `kid`. Unknown ids raise —
      # a payload sealed under a key this instance does not hold must fail
      # loud, never decrypt to garbage.
      def key_bytes(kid : String = DEFAULT_KID) : Bytes
        raise ArgumentError.new("Unknown secret key id '#{kid}'") unless kid == DEFAULT_KID
        key = Base64.decode(@master_key)
        if key.size < MIN_KEY_BYTES
          raise ArgumentError.new(
            "'secrets.master_key' is not usable — run validate! at load time"
          )
        end
        key
      end

      # ── Private ───────────────────────────────────────────────────────

      private def self.read_int(value : YAML::Any?, default : Int32) : Int32
        return default if value.nil? || value.raw.nil?
        value.as_i
      end
    end
  end
end
