# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../iam/helpers"
require "../http/helpers"
require "./service"

module Facet
  module Settings
    # HTTP routes for account preferences.
    #
    # All routes are under `/Api/settings`. They are self-service: the
    # authenticated account manages its own settings only, keyed off the
    # `sub` claim of the access token (no RBAC enforcer — the caller only
    # ever touches rows where `account_id` matches). State-changing requests
    # require the `X-Requested-With` header (CSRF defense, through the
    # shared `HTTP::Helpers.require_csrf` gate).
    module Routes
      # Registers all settings routes on the Kemal router. Split by concern
      # so each method's branch count stays small.
      def self.register : Nil
        register_read_routes
        register_write_routes
      end

      private def self.register_read_routes : Nil
        # ── GET /Api/settings ────────────────────────────────────────
        # Alias for the `core` application scope.
        get "/Api/settings" do |env|
          read_scope(env, CORE_APP)
        end

        # ── GET /Api/settings/:app ───────────────────────────────────
        get "/Api/settings/:app" do |env|
          read_scope(env, env.params.url["app"])
        end

        # ── GET /Api/settings/:app/:key ──────────────────────────────
        get "/Api/settings/:app/:key" do |env|
          account_id = Facet::HTTP::Helpers.require_account(env) || next
          app = env.params.url["app"]
          key = env.params.url["key"]

          result = Database.with_db(:read_only) do |db|
            Service.get_value(db, account_id, app, key)
          end

          if result.nil?
            next Facet::HTTP::Helpers.error_response(env, 404, "Unknown setting '#{app}.#{key}'")
          end

          value, updated_at = result
          if updated_at
            Facet::HTTP::Helpers.write_json(env, 200, {app: app, key: key, value: value, updated_at: updated_at})
          else
            Facet::HTTP::Helpers.write_json(env, 200, {app: app, key: key, value: value})
          end
        end
      end

      private def self.register_write_routes : Nil
        # ── DELETE /Api/settings/:app/:key ───────────────────────────
        #
        # Removes the account's row so the server default applies again.
        # Idempotent: a missing row still answers 204. An unregistered key
        # answers 404 — the same non-disclosing shape as the GET. CSRF
        # header required like the PUT (a DELETE is state-changing).
        delete "/Api/settings/:app/:key" do |env|
          next unless Facet::HTTP::Helpers.require_csrf(env)
          account_id = Facet::HTTP::Helpers.require_account(env) || next
          app = env.params.url["app"]
          key = env.params.url["key"]

          if Facet::Settings::Keys.descriptor?(app, key).nil?
            next Facet::HTTP::Helpers.error_response(env, 404, "Unknown setting '#{app}.#{key}'")
          end

          Database.with_db do |db|
            Service.clear(db, account_id, app, key)
          end

          env.response.status_code = 204
          ""
        end

        # ── PUT /Api/settings/:app/:key ──────────────────────────────
        put "/Api/settings/:app/:key" do |env|
          body = Facet::HTTP::Helpers.require_body(env) || next
          next unless Facet::HTTP::Helpers.require_csrf(env)

          account_id = Facet::HTTP::Helpers.require_account(env) || next
          app = env.params.url["app"]
          key = env.params.url["key"]

          parsed = Facet::HTTP::Helpers.parse_json_object(env, body) || next
          value = parsed["value"]?
          if value.nil?
            next Facet::HTTP::Helpers.error_response(env, 422, "Request body must include 'value'")
          end

          result = Database.with_db do |db|
            Service.update(db, account_id, app, key, value)
          end

          case result
          in Tuple(JSON::Any, Time)
            stored, updated_at = result
            Facet::HTTP::Helpers.write_json(env, 200, {app: app, key: key, value: stored, updated_at: updated_at})
          in Facet::ServiceError
            Facet::HTTP::Helpers.error_response(env, result.status, result.message, result.details, result.meta)
          end
        end
      end

      # Shared read path for the scoping-variants routes. The response
      # carries the merged values plus the `defaults` block — each
      # registered key's server-effective default (what an account with no
      # row resolves to), so the personal settings page can render a
      # "Server default ({value})" option.
      private def self.read_scope(env, app) : Nil
        account_id = Facet::HTTP::Helpers.require_account(env) || return

        values, defaults = Database.with_db(:read_only) do |db|
          {Service.get(db, account_id, app), Service.defaults(db, app)}
        end
        Facet::HTTP::Helpers.write_json(env, 200, {app: app, values: values, defaults: defaults})
      end
    end
  end
end
