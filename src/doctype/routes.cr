# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../rbac"
require "../rbac/write_enforcer"
require "./check"
require "./update"

module Facet
  module Doctype
    # HTTP routes for doctype management.
    #
    # Registered by `HTTP::Server.routes`.
    module Routes
      def self.register : Nil
        put "/Api/core/DocType/:id" do |env|
          handle_update(env)
        end

        get "/Api/core/DocType/:id/check" do |env|
          handle_check(env)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.handle_update(env)
        return unless HTTP::Helpers.require_csrf(env)

        body = HTTP::Helpers.require_body(env) || return
        result = Database.with_transaction do |db|
          HTTP::Helpers.lock_projection_for_update(db, "core", "DocType", env.params.url["id"])
          Facet::Doctype::Update.call(db, env.params.url["id"], body, HTTP::Helpers.auth_context(env))
        end
        Event::Publisher.flush
        HTTP::Helpers.write_result(env, result)
      end

      private def self.handle_check(env)
        auth_ctx = HTTP::Helpers.auth_context(env)
        doctype_id = env.params.url["id"]

        result = Database.with_db(:read_only) do |db|
          unless Facet::RBAC::WriteEnforcer.authorize_update(db, "core", "DocType", doctype_id, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end
          Facet::Doctype::Check.call(db, doctype_id)
        end

        case result
        in Facet::Doctype::Check::Result
          env.response.status_code = 200
          issues_json = result.issues.map do |issue|
            h = {
              "severity" => issue.severity.to_s,
              "category" => issue.category.to_s,
              "message"  => issue.message,
            }
            if f = issue.field
              h["field"] = f
            end
            h
          end
          {data: {doctype_id: result.doctype_id, issues: issues_json}}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end
    end
  end
end
