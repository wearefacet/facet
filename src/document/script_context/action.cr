# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../../mutation/json_diff"
require "./base"

module Facet
  module Document
    module ScriptContext
      # ── ActionContext ────────────────────────────────────────────────

      # Context for executing a named action on a document.
      #
      # Calls, in order: `_MODULE.validate(ctx)` (pre-action state),
      # `_MODULE.{action_name}(ctx, args)` (may mutate `ctx.root` by
      # setting fields directly, e.g. `ctx.root.status = "terminated"`),
      # then `_MODULE.update(ctx)` against the post-action state (B-291)
      # so a state-machine guard written in the update hook binds named
      # actions too. Before the update hook runs, `ctx.changed` lists the
      # fields the action mutated; `ctx.action` names the driving action
      # on every hook in the run. After `run`, `#root_document` holds the
      # final document.
      class Action < Base
        @action_name : String
        @original_document : JSON::Any

        # The (potentially mutated) root document after the action and
        # the update hook run.
        getter root_document : JSON::Any

        # Yields the context to the block and closes the Lua engine.
        def initialize(
          script : String,
          action_name : String,
          document : JSON::Any,
          args : JSON::Any,
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
          & : Action -> _
        )
          super(Lua::Sandbox.new, script, db, domain, doc_type, cause: cause, provenance: provenance, actor_id: actor_id, auth_context: auth_context, rbac_action: action_name, rbac_doctype_path: rbac_doctype_path)
          @original_document = document
          @root_document = document
          @action_name = action_name
          setup_ctx(document, actor_id, now, doc_id, action: action_name)
          engine = engine!
          engine.set_global("args", ScriptContext.json_to_lua_value(args))
          yield self
        ensure
          close
        end

        # Runs `_MODULE.validate(ctx)` (if defined), then
        # `_MODULE.{action_name}(ctx, args)`, then `_MODULE.update(ctx)`
        # (if defined) against the final state. Returns the list of
        # validation error messages (empty if valid).
        def run : Array(ValidationError)
          run_hooks(@action_name, with_args: true)
          run_update_hook
          @root_document = read_root
          error_list.dup
        end

        # Runs the `update` lifecycle hook against the post-action state.
        # Publishes `ctx.changed` — the fields the action mutated — right
        # before the call, and only when the hook is defined, so doctypes
        # without one keep the exact pre-B-291 behaviour. No `validate`
        # re-run: it already ran against the pre-action state.
        private def run_update_hook : Nil
          changed = Mutation::JsonDiff.changed_fields(@original_document, read_root).to_a.sort
          changed_json = JSON::Any.new(changed.map { |field| JSON::Any.new(field) })
          engine = engine!
          engine.set_global("__action_changed", ScriptContext.json_to_lua_value(changed_json))
          engine.run(<<-LUA)
            if _MODULE ~= nil and _MODULE.update ~= nil then
              ctx.changed = __action_changed
              _MODULE.update(ctx)
            end
            __action_changed = nil
          LUA

        rescue ex : Lua::Engine::Error
          raise Error.new(ex)
        end
      end
    end
  end
end
