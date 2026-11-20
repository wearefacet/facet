# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./base"

module Facet
  module Document
    module ScriptContext
      # ── UpdateContext ─────────────────────────────────────────────────

      # Context for the `update` lifecycle hook.
      #
      # Calls `_MODULE.update(ctx)` where `ctx.root` is the merged
      # document state (current content with the patch applied). The
      # hook may validate and mutate `ctx.root`. `ctx.patch` exposes the
      # partial patch the caller submitted; combined with `ctx.root` it
      # lets the hook distinguish "caller asked to change this field"
      # from "the field kept its existing value" — necessary for any
      # write-once / immutability enforcement.
      class Update < Base
        # The (potentially mutated) root document after the hook runs.
        getter root_document : JSON::Any

        # Yields the context to the block and closes the Lua engine.
        #
        # `merged` is the post-merge document: the current content with
        # the patch applied. `patch` is the partial body the caller
        # submitted (the PATCH request, before deep-merge). Pass `nil`
        # only when the update path is not driven by a user PATCH (none
        # today); otherwise callers should always supply the patch so
        # the hook can read it.
        def initialize(
          script : String,
          merged : JSON::Any,
          actor_id : String = "system",
          now : Time = Time.utc,
          db : DB::Connection? = nil,
          domain : String? = nil,
          doc_type : String? = nil,
          doc_id : String? = nil,
          cause : Mutation::Cause? = nil,
          provenance : Mutation::Provenance? = nil,
          auth_context : RBAC::AuthContext? = nil,
          patch : JSON::Any? = nil,
          rbac_doctype_path : Array(String)? = nil,
          & : Update -> _
        )
          super(Lua::Sandbox.new, script, db, domain, doc_type, cause: cause, provenance: provenance, actor_id: actor_id, auth_context: auth_context, rbac_action: "update", rbac_doctype_path: rbac_doctype_path)
          @root_document = merged
          setup_ctx(merged, actor_id, now, doc_id, patch: patch)
          yield self
        ensure
          close
        end

        # Runs `_MODULE.validate(ctx)` (if defined) then `_MODULE.update(ctx)`.
        # Returns the list of validation error messages (empty if valid).
        def run : Array(ValidationError)
          errors = run_hooks("update")
          @root_document = read_root
          errors
        end
      end
    end
  end
end
