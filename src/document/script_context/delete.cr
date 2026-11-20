# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./base"

module Facet
  module Document
    module ScriptContext
      # ── DeleteContext ─────────────────────────────────────────────────

      # Context for the `delete` lifecycle hook.
      #
      # Calls `_MODULE.delete(ctx)` where `ctx.root` is the current
      # document state. The hook may validate (via `ctx.error()`) before
      # deletion.
      class Delete < Base
        # Yields the context to the block and closes the Lua engine.
        def initialize(
          script : String,
          before : JSON::Any,
          actor_id : String = "system",
          now : Time = Time.utc,
          db : DB::Connection? = nil,
          domain : String? = nil,
          doc_type : String? = nil,
          doc_id : String? = nil,
          cause : Mutation::Cause? = nil,
          provenance : Mutation::Provenance? = nil,
          auth_context : RBAC::AuthContext? = nil,
          rbac_doctype_path : Array(String)? = nil,
          & : Delete -> _
        )
          super(Lua::Sandbox.new, script, db, domain, doc_type, cause: cause, provenance: provenance, actor_id: actor_id, auth_context: auth_context, rbac_action: "delete", rbac_doctype_path: rbac_doctype_path)
          setup_ctx(before, actor_id, now, doc_id)
          yield self
        ensure
          close
        end

        # Runs `_MODULE.validate(ctx)` (if defined) then `_MODULE.delete(ctx)`.
        # Returns the list of validation error messages (empty if valid).
        def run : Array(ValidationError)
          run_hooks("delete")
        end
      end
    end
  end
end
