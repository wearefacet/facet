# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../error"
require "../system_settings"
require "./keys"

module Facet::Settings
  # Read and write per-account, per-application preference rows in `account_settings`.
  #
  # The service keys every call off `account_id` — the caller is responsible for
  # supplying the authenticated account id (extracted from the JWT in the HTTP
  # layer). It performs no RBAC; the user only ever touches rows with a
  # matching `account_id`, enforced in SQL.
  module Service
    # Read all registered settings for one application scope.
    #
    # Returns the persisted values with defaults merged in for missing keys,
    # so a brand-new account gets a complete, well-typed response without a
    # prior write. The default chain per key: the server default (the
    # effective `core.SystemSettings` value — see `default_for`), then the
    # registry default.
    def self.get(db : DB::Connection, account_id : String, app : String = CORE_APP) : Hash(String, JSON::Any)
      persisted = read_all(db, account_id, app)

      keys = Keys.for_app(app)
      result = {} of String => JSON::Any
      keys.each do |descriptor|
        result[descriptor.key] = persisted[descriptor.key]? || default_for(db, descriptor)
      end
      result
    end

    # The server-effective defaults for one application scope: every
    # registered key resolved through its default chain (no account row is
    # read). The settings page renders these as the "Server default
    # ({value})" option label and `GET /Api/settings/:app` carries them in
    # the `defaults` block.
    def self.defaults(db : DB::Connection, app : String = CORE_APP) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      Keys.for_app(app).each do |descriptor|
        result[descriptor.key] = default_for(db, descriptor)
      end
      result
    end

    # Read a single setting value. Returns the resolved default if no row
    # exists (same chain as `get`). Returns `nil` if the key is not
    # registered.
    def self.get_value(db : DB::Connection, account_id : String, app : String, key : String) : {JSON::Any, Time?}?
      descriptor = Keys.descriptor?(app, key)
      return nil unless descriptor

      row = read_one(db, account_id, app, key)
      value = row ? row[:value] : default_for(db, descriptor)
      updated_at = row ? row[:updated_at] : nil
      {value, updated_at}
    end

    # The default value for one registered key — the first tier of the
    # chain that yields a value:
    # 1. the server default — the effective `core.SystemSettings` value at
    #    the mapped path (`Keys::SERVER_DEFAULTS`), when the key has one;
    # 2. the static registry default.
    # A key with no mapping (e.g. the pinned lists) keeps its registry
    # default — there is no server-level policy for it.
    private def self.default_for(db : DB::Connection, descriptor : Keys::Descriptor) : JSON::Any
      if path = Keys::SERVER_DEFAULTS[{descriptor.app, descriptor.key}]?
        if server = SystemSettings.value_at(db, path)
          return server unless server.raw.nil?
        end
      end
      descriptor.default
    end

    # Removes the account's row for one key so the server default applies
    # again. Idempotent — a missing row is a no-op success. Returns the
    # number of rows deleted.
    def self.clear(db : DB::Connection, account_id : String, app : String, key : String) : Int64
      descriptor = Keys.descriptor?(app, key)
      return 0i64 unless descriptor

      db.exec(
        "DELETE FROM account_settings WHERE account_id = $1 AND app = $2 AND key = $3",
        account_id, app, key,
      ).rows_affected
    end

    # Upsert a single setting. Validates against the registry before writing.
    # Returns the persisted value and its `updated_at` timestamp, or a
    # `ServiceError` for an unregistered key or a value that fails validation.
    def self.update(db : DB::Connection, account_id : String, app : String, key : String, value : JSON::Any) : {JSON::Any, Time} | Facet::ServiceError
      error = Keys.validate(app, key, value)
      return Facet::ServiceError.new(422, error) if error

      db.query(
        "INSERT INTO account_settings (account_id, app, key, value, updated_at)
         VALUES ($1, $2, $3, $4, now())
         ON CONFLICT (account_id, app, key) DO UPDATE
           SET value = EXCLUDED.value, updated_at = now()
         RETURNING value, updated_at",
        account_id, app, key, value.to_json,
      ) do |rs|
        rs.each do
          stored = rs.read(JSON::Any)
          # `value` column is jsonb; rs.read(JSON::Any) parses it. The returned
          # JSON is the canonical stored form, so we prefer it over the input.
          updated_at = rs.read(Time)
          return {stored, updated_at}
        end
      end

      # ON CONFLICT DO UPDATE always returns a row; this is unreachable.
      Facet::ServiceError.new(500, "Setting upsert returned no row")
    end

    # Reads every persisted row for one (account, app) scope.
    private def self.read_all(db : DB::Connection, account_id : String, app : String) : Hash(String, JSON::Any)
      result = {} of String => JSON::Any
      db.query(
        "SELECT key, value FROM account_settings WHERE account_id = $1 AND app = $2",
        account_id, app,
      ) do |rs|
        rs.each do
          key = rs.read(String)
          value = rs.read(JSON::Any)
          result[key] = value
        end
      end
      result
    end

    private def self.read_one(db : DB::Connection, account_id : String, app : String, key : String) : {value: JSON::Any, updated_at: Time}?
      db.query_one?(
        "SELECT value, updated_at FROM account_settings WHERE account_id = $1 AND app = $2 AND key = $3",
        account_id, app, key,
      ) do |rs|
        {
          value:      rs.read(JSON::Any),
          updated_at: rs.read(Time),
        }
      end
    end
  end
end
