# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../database"
require "../event"
require "../http/helpers"
require "../rbac"
require "../rbac/write_enforcer"
require "../mutation/client"

module Facet
  module Grants
    # Activate / deactivate routes for `core.DomainGrant` documents.
    #
    # These are not document actions — the route performs the internal
    # mutation directly and runs no Lua (`core.DomainGrant` carries no
    # lifecycle script; the `read_only` flag on `active` is the gate the
    # routes bypass). The caller needs the named action (`activate` /
    # `deactivate`) on `core.DomainGrant` — the producer's acceptance
    # right, held doctype-global (D5). Every transition lands in the audit
    # log attributed to the caller.
    module Routes
      def self.register : Nil
        post "/Api/core/DomainGrant/:id/activate" do |env|
          handle_transition(env, "activate", true)
        end

        post "/Api/core/DomainGrant/:id/deactivate" do |env|
          handle_transition(env, "deactivate", false)
        end
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.handle_transition(env, action : String, active : Bool)
        return unless HTTP::Helpers.require_csrf(env)

        auth_ctx = HTTP::Helpers.auth_context(env)
        grant_id = env.params.url["id"]

        result = Database.with_transaction do |db|
          # The named-action gate — doctype-global by design (D5): any
          # holder can activate or deactivate any grant; the audit log
          # records every transition.
          unless RBAC::WriteEnforcer.authorize_action(db, "core", "DomainGrant", grant_id, action, auth_ctx)
            next Facet::ServiceError.new(403, "Forbidden")
          end

          transition(db, grant_id, active, auth_ctx)
        end
        Event::Publisher.flush

        case result
        in Mutation::Client::Projection
          env.response.status_code = 200
          env.response.content_type = "application/json"
          {data: result.content, meta: HTTP::Helpers.document_meta(result, mutation_id: result.state)}.to_json
        in Facet::ServiceError
          HTTP::Helpers.error_response(env, result.status, result.message)
        end
      end

      # Flips the `active` flag through the internal update path. The
      # reentrant form allows the write to the read_only field and marks
      # the emitted event reentrant — the flag flip is platform
      # bookkeeping, never a hook or replication trigger. A same-value
      # write persists nothing (the update pipeline's empty-diff path
      # returns the existing projection).
      private def self.transition(
        db : DB::Connection,
        grant_id : String,
        active : Bool,
        auth_ctx : RBAC::AuthContext,
      ) : Mutation::Client::Projection | Facet::ServiceError
        patch = {active: active}.to_json
        result = Document::Update.call(
          db, "core", "DomainGrant", grant_id, patch,
          RBAC::AuthContext.system, # the named-action gate ran above
          reentrant: true,
          actioner_id: auth_ctx.account_id,
          skip_authorization: true,
        )
        case result
        in Document::Update::Result then result.projection
        in Facet::ServiceError      then result
        end
      end
    end
  end
end
