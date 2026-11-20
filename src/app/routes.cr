# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../error"
require "../http/helpers"
require "../rbac"
require "./api_keys"

module Facet
  module App
    # HTTP surface for app-owned API keys (backend apps).
    #
    # - POST   /Api/app/:id/api-key — issue; rotates when an active key exists
    # - GET    /Api/app/:id/api-key — active key status (no secret)
    # - DELETE /Api/app/:id/api-key — soft-revoke (idempotent)
    #
    # Both mutating routes are gated by the standard model — `update` on
    # `app.App` — and accept **operator sessions only**: an API-key or
    # app-token principal can never mint or revoke its own credentials (the
    # same channel separation the OAuth authorize surface enforces). The
    # mutating routes are CSRF-checked like the IAM routes — browser sessions
    # are cookie-authenticated, so a cross-site request without the
    # `X-Requested-With` header must not reach the handler.
    module Routes
      def self.register : Nil
        register_issue
        register_status
        register_revoke
      end

      # ── Route registration ─────────────────────────────────────────────

      # POST /Api/app/:id/api-key — issues the app's API key. When an active
      # key exists this is a rotation: the old row is revoked and the new one
      # issued in one transaction. The raw key is returned exactly once.
      private def self.register_issue : Nil
        post "/Api/app/:id/api-key" do |env|
          next unless Facet::HTTP::Helpers.require_csrf(env)

          app_id = Facet::HTTP::Helpers.require_path_param(env, "id") || next
          context = require_operator(env) || next

          result = Database.with_db do |db|
            unless RBAC::WriteEnforcer.authorize_update(db, "app", "App", app_id, context)
              next Facet::ServiceError.new(403, "Forbidden")
            end
            ApiKeys.issue(db, app_id)
          end
          Event::Publisher.flush

          case result
          in Facet::ServiceError
            HTTP::Helpers.error_response(env, result.status, result.message)
          in ApiKeys::Issued
            HTTP::Helpers.write_json(env, 201, {
              id:                 result.id,
              key:                result.key,
              display_prefix:     result.display_prefix,
              service_account_id: result.service_account_id,
              role_id:            result.role_id,
            })
          end
        end
      end

      # GET /Api/app/:id/api-key — the app's active key status: display
      # prefix, pinned role, usage timestamps. Never secret material.
      private def self.register_status : Nil
        get "/Api/app/:id/api-key" do |env|
          app_id = HTTP::Helpers.require_path_param(env, "id") || next
          context = require_operator(env) || next

          result = Database.with_db(:read_only) do |db|
            unless RBAC::ReadEnforcer.authorized?(db, "app", "App", app_id, context)
              next Facet::ServiceError.new(403, "Forbidden")
            end
            next Facet::ServiceError.new(404, "App not found") unless app_exists?(db, app_id)

            ApiKeys.active_key(db, app_id)
          end

          case result
          in Facet::ServiceError
            HTTP::Helpers.error_response(env, result.status, result.message)
          in Nil
            HTTP::Helpers.write_json(env, 200, {active: false})
          in ApiKeys::Active
            HTTP::Helpers.write_json(env, 200, {
              active:         true,
              id:             result.id,
              display_prefix: result.display_prefix,
              role_id:        result.role_id,
              created_at:     result.created_at.to_rfc3339,
              last_used_at:   result.last_used_at.try(&.to_rfc3339),
            })
          end
        end
      end

      # DELETE /Api/app/:id/api-key — soft-revokes the app's active key.
      # Idempotent: a repeated delete still returns 200 with `revoked: false`.
      private def self.register_revoke : Nil
        delete "/Api/app/:id/api-key" do |env|
          next unless Facet::HTTP::Helpers.require_csrf(env)

          app_id = Facet::HTTP::Helpers.require_path_param(env, "id") || next
          context = require_operator(env) || next

          result = Database.with_db do |db|
            unless RBAC::WriteEnforcer.authorize_update(db, "app", "App", app_id, context)
              next Facet::ServiceError.new(403, "Forbidden")
            end
            next Facet::ServiceError.new(404, "App not found") unless app_exists?(db, app_id)

            ApiKeys.revoke(db, app_id)
          end
          Event::Publisher.flush

          case result
          in Facet::ServiceError
            HTTP::Helpers.error_response(env, result.status, result.message)
          in Bool
            HTTP::Helpers.write_json(env, 200, {revoked: result})
          end
        end
      end

      # ── Private ────────────────────────────────────────────

      # True when the live `app.App` projection row exists.
      private def self.app_exists?(db : DB::Connection, app_id : String) : Bool
        !db.query_one?("SELECT 1 FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL", app_id, as: Int32).nil?
      end

      # Operator session only: a real principal that authenticated through
      # neither the API-key nor the app-token channel. System and preview
      # principals are refused too — key management is a console action.
      private def self.require_operator(env) : RBAC::AuthContext?
        context = Fiber.current.auth_context
        if context.nil? || context.system? || context.preview?
          HTTP::Helpers.error_response(env, 401, "Authentication required")
          return nil
        end
        unless context.api_key_id.nil? && context.app_id.nil?
          HTTP::Helpers.error_response(env, 403, "Forbidden")
          return nil
        end
        context
      end
    end
  end
end
