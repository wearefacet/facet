# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./base"

module Facet
  module Document
    module ScriptContext
      # ── CreateContext ─────────────────────────────────────────────────

      # Context for the `create` lifecycle hook.
      #
      # Calls `_MODULE.create(ctx)` where `ctx.root` is the input document.
      # The hook may both validate (via `ctx.error()`) and mutate
      # `ctx.root`. After `run`, access `#root_document` for the mutated
      # document.
      class Create < Base
        # The (potentially mutated) root document after the hook runs.
        getter root_document : JSON::Any

        # Yields the context to the block and closes the Lua engine.
        def initialize(
          script : String,
          document : JSON::Any,
          actor_id : String = "system",
          now : Time = Time.utc,
          db : DB::Connection? = nil,
          domain : String? = nil,
          doc_type : String? = nil,
          cause : Mutation::Cause? = nil,
          provenance : Mutation::Provenance? = nil,
          auth_context : RBAC::AuthContext? = nil,
          rbac_doctype_path : Array(String)? = nil,
          & : Create -> _
        )
          super(Lua::Sandbox.new, script, db, domain, doc_type, cause: cause, provenance: provenance, actor_id: actor_id, auth_context: auth_context, rbac_action: "create", rbac_doctype_path: rbac_doctype_path)
          @root_document = document
          setup_ctx(document, actor_id, now)
          yield self
        ensure
          close
        end

        # Runs `_MODULE.validate(ctx)` (if defined) then `_MODULE.create(ctx)`.
        # Returns the list of validation error messages (empty if valid).
        def run : Array(ValidationError)
          errors = run_hooks("create")
          @root_document = read_root
          errors
        end
      end
    end
  end
end
