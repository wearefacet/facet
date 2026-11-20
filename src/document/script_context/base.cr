# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../../lua"
require "../../util/script_helpers"
require "../../error"
require "../lua_document_helpers"
require "../lua_notification_helpers"

module Facet
  module Document
    module ScriptContext
      # Raised when the Lua script has a syntax error or raises an
      # unhandled runtime error (as opposed to calling the `error()`
      # helper, which is the expected validation path). The driving
      # service maps it to a `ServiceError` through
      # `refusal_or_script_error` — never a bare 500.
      class Error < ::RuntimeError
        getter engine_error : Lua::Engine::Error

        # `wrap_script` prepends one line to the script before the engine
        # wraps it again, so the engine-rebased line is still one line past
        # the author's source. Rebase once more so the message points at
        # the author's line (B-318).
        def initialize(@engine_error : Lua::Engine::Error)
          super(Lua::Engine::Error.rebase_position(@engine_error.message, 1))
        end
      end

      # Maps a script unwind to the refused-write `ServiceError` a
      # `document.*` helper recorded before raising — surfaced with its
      # native status (flat-create guard → 422, missing target → 404)
      # instead of an opaque 500. When no helper recorded a refusal, the
      # unwind is a script bug: return a 422 carrying the Lua error
      # message, so the builder sees what their script did wrong instead
      # of a bare 500.
      def self.refusal_or_script_error(ctx : Base?, ex : Error) : Facet::ServiceError
        se = ctx.try(&.service_errors.last?)
        return se if se
        Facet::ServiceError.new(422, "Script error: #{ex.message}")
      end

      # ── Script wrapper ────────────────────────────────────────────────

      # Wraps the user's script so that its return value is captured in
      # a global `_MODULE` table.
      def self.wrap_script(script : String) : String
        <<-LUA
          local _module = (function()
            #{script}
          end)()
          _MODULE = _module
        LUA
      end

      # ── Base context (shared setup) ──────────────────────────────────

      # Base initialisation shared by all context classes.
      # Registers the `error` global function, wraps and runs the script,
      # and sets up the `ctx` table (with `ctx.error` wired to the global).
      abstract class Base
        getter engine : Lua::Engine?

        # Notifications enqueued by `notification.send` during this script
        # evaluation. One queue per `ScriptContext`: a nested
        # `document.create` inside a hook drains its own queue when the
        # child operation persists; this queue stays pending until the
        # owning flow's own operation persists (see
        # `Notification::Queue.drain`).
        getter notification_queue : Array(Notification::Pending) = [] of Notification::Pending

        # Error accumulator filled by the Lua `error(msg)` global and the
        # lifecycle hooks. Returned by `#error_list`.
        @errors : Array(ValidationError) = [] of ValidationError

        # Service errors recorded by the `document.*` helpers before they
        # raise. When a helper refuses a nested write (flat-create guard,
        # validation, missing target) the script driver surfaces the error
        # with its native status instead of an opaque 500. Only consulted
        # when a `ScriptContext::Error` actually unwinds the script — a
        # script that recovers through `pcall` is unaffected.
        @service_errors : Array(Facet::ServiceError) = [] of Facet::ServiceError

        # Returns the error accumulator (initialized at declaration).
        def error_list : Array(ValidationError)
          @errors
        end

        # Service errors the `document.*` helpers recorded before raising.
        getter service_errors : Array(Facet::ServiceError)

        # Request-scoped auth context, exposed to Lua as `ctx.actor`.
        # Nil for migration contexts (which run as `system:migration` and
        # have no real principal) and for unit tests that don't pass one.
        @auth_context : RBAC::AuthContext?
        # The RBAC action name this hook represents ("create", "update",
        # "delete", or a named action). Used to look up the authorizing
        # permission whose scope alias is exposed as `ctx.actor.scope`.
        @rbac_action : String?
        # The doctype path the enforcer authorized this operation with — the
        # composition path (`["DocType", "CollectionView"]`) on nested child
        # routes, the bare path on flat routes. `scope_aliases_for` must
        # re-derive the matched permissions on the SAME path, or a scoped
        # nested-route create would see `ctx.actor.scope == nil` and the
        # force-ownership hook pattern silently does nothing.
        @rbac_doctype_path : Array(String)?
        @db : DB::Connection?
        @domain : String?
        @doc_type : String?

        def initialize(
          sandbox : Lua::Sandbox,
          script : String,
          db : DB::Connection? = nil,
          domain : String? = nil,
          doc_type : String? = nil,
          cause : Mutation::Cause? = nil,
          provenance : Mutation::Provenance? = nil,
          actor_id : String? = nil,
          auth_context : RBAC::AuthContext? = nil,
          rbac_action : String? = nil,
          rbac_doctype_path : Array(String)? = nil,
        )
          @engine = sandbox.engine
          @auth_context = auth_context
          @rbac_action = rbac_action
          @rbac_doctype_path = rbac_doctype_path
          @db = db
          @domain = domain
          @doc_type = doc_type
          register_script_helpers!(sandbox, db, domain, doc_type, cause, provenance, actor_id)
          wrapped = ScriptContext.wrap_script(script)
          sandbox.engine.run(wrapped)
          sandbox.register_error_global(@errors)
        rescue ex : Lua::Engine::Error
          raise Error.new(ex)
        end

        # Registers `__ctx_get_children` as a raw Lua function, which is later
        # wired to `ctx.get_children` in `setup_ctx`. Lists child documents by
        # looking up the doctype's children definition and filtering by `parent_id`.
        private def register_get_children!(
          engine : Lua::Engine,
          db : DB::Connection,
          domain : String,
          doc_type : String?,
        ) : Nil
          captured_db = db
          captured_domain = domain
          captured_doc_type = doc_type
          captured_auth = RBAC::AuthContext.system

          engine.raw_function("__ctx_get_children") do |s|
            if LibLua.gettop(s) < 1
              LibLua.pushstring(s, "get_children requires a relation name argument")
              LibLua.error(s)
              next 0
            end

            relation_name = get_children_relation_arg(s)
            if relation_name.nil?
              LibLua.createtable(s, 0, 0)
              next 1
            end

            # Fetch current doctype definition
            definition = Doctype::DefinitionStore.fetch(captured_db, "#{captured_domain}.#{captured_doc_type}")
            if definition.nil?
              LibLua.pushstring(s, "Cannot resolve children: doctype #{captured_domain}.#{captured_doc_type} not found")
              LibLua.error(s)
              next 0
            end

            # Look up the children definition
            child_doctype = get_children_doctype(definition, relation_name)
            if child_doctype.nil?
              LibLua.createtable(s, 0, 0)
              next 1
            end

            # Read doc_id from the Lua global ctx table
            doc_id = get_children_doc_id(s)
            if doc_id.nil?
              LibLua.createtable(s, 0, 0)
              next 1
            end

            # List children with parent_id filter
            push_children_result(s, captured_db, captured_domain, child_doctype, doc_id, captured_auth)
          end
        end

        # Reads the relation name argument from the Lua stack. Returns nil
        # when the argument is not a string.
        private def get_children_relation_arg(s : LibLua::State) : String?
          ptr = LibLua.tolstring(s, 1, nil)
          ptr.null? ? nil : String.new(ptr)
        end

        # Returns the child doctype for `relation_name`. Returns nil when
        # the children definition has no entry for it.
        private def get_children_doctype(
          definition : Doctype::DoctypeDefinition,
          relation_name : String,
        ) : String?
          definition.children[relation_name]?.try(&.doctype)
        end

        # Reads `doc_id` from the global `ctx` table. Returns nil when the
        # value is absent or not a string.
        private def get_children_doc_id(s : LibLua::State) : String?
          LibLua.getglobal(s, "ctx")
          LibLua.pushstring(s, "doc_id")
          LibLua.gettable(s, -2)
          doc_id = if LibLua.type(s, -1) == 4
                     ptr = LibLua.tolstring(s, -1, nil)
                     ptr.null? ? nil : String.new(ptr)
                   else
                     nil
                   end
          LibLua.settop(s, -3) # pop doc_id and ctx
          doc_id
        end

        # Lists the children and pushes the result table. Pushes an empty
        # table when the list service fails. Returns 1; the table on the
        # stack is the return value.
        private def push_children_result(
          s : LibLua::State,
          db : DB::Connection,
          domain : String,
          child_doctype : String,
          doc_id : String,
          auth : RBAC::AuthContext,
        ) : Int32
          result = Document::List.call(
            db, domain, child_doctype,
            filters: {} of String => JSON::Any,
            sort: ["id"],
            page: 1,
            items_per_page: 1000,
            auth_context: auth,
            parent_id: doc_id,
          )

          case result
          in Document::List::Result
            # Push as a Lua array of IDs (strings)
            LibLua.createtable(s, result.items.size, 0)
            result.items.each_with_index do |item, i|
              LibLua.pushstring(s, item.id)
              LibLua.rawseti(s, -2, i + 1)
            end
            1
          in Facet::ServiceError
            LibLua.createtable(s, 0, 0)
            1
          in Document::List::AggregateResult
            # Unreachable: no aggregate is requested on this path. The union
            # member exists because `Document::List.call` can return one.
            LibLua.createtable(s, 0, 0)
            1
          end
        end

        # Registers the `util.*`, `date.*`, `math.clamp`, and `document.*` globals.
        # Crystal-backed functions are registered via `engine.function`;
        # pure-Lua helpers (`is_empty`, `coalesce`) are injected via `engine.run`.
        # The `document.*` helpers require a database connection and domain.
        private def register_script_helpers!(
          sandbox : Lua::Sandbox,
          db : DB::Connection? = nil,
          domain : String? = nil,
          doc_type : String? = nil,
          cause : Mutation::Cause? = nil,
          provenance : Mutation::Provenance? = nil,
          actor_id : String? = nil,
        ) : Nil
          engine = sandbox.engine

          # ── util, date, math and JSON globals (shared with Compute) ──
          sandbox.register_util_globals!(json_helpers: true, db: db)

          # ── ctx.get_children (only when db available) ──
          register_get_children!(engine, db, domain, doc_type) if db && domain

          # ── Register document.* helpers ──
          # `cause` is the cause template for writes the script performs
          # (e.g. an `hire` action's Lua calling `document.update`): the
          # driver binds `parent`/`trace` so nested mutations link to the
          # driving mutation. `provenance` carries the original caller's
          # channel — the system auth context here only bypasses RBAC, it
          # must not stamp `internal` over a user/app/MCP channel.
          if db && domain
            sandbox.register_document_helpers!(db, domain, cause, provenance, actor_id, service_errors: @service_errors)
            sandbox.register_notification_helpers!(db, notification_queue, service_errors: @service_errors)
          end
        end

        # Builds the `ctx` table and sets it as a global,
        # after registering `error` so `ctx.error = error` works.
        #
        # When an `@auth_context` is present, a read-only `ctx.actor` table
        # is attached exposing the caller's identity, role, visible tags,
        # the create-permission scope alias, and resolved context sets —
        # so Lua `create(ctx)` hooks can enforce row-content rules RBAC
        # cannot express at create time (e.g. force `author_id`).
        #
        # `patch` is only set on `ScriptContext::Update`. It exposes the
        # partial PATCH body the caller submitted (before deep-merge) so
        # the `update(ctx)` hook can distinguish "caller asked to change
        # this field" from "the field kept its existing value". Absent on
        # every other hook type.
        #
        # `action` is only set on `ScriptContext::Action`. It names the
        # driving action, so a lifecycle hook can tell an action-driven
        # run from a plain PATCH (`ctx.action ~= nil`).
        def setup_ctx(root_document : JSON::Any, actor_id : String, now : Time, doc_id : String? = nil, patch : JSON::Any? = nil, action : String? = nil) : Nil
          engine = @engine.as(Lua::Engine)
          ctx = Hash(String, Lua::Engine::Value).new
          ctx["root"] = ScriptContext.json_to_lua_value(root_document)
          ctx["actor_id"] = actor_id
          ctx["now"] = now.to_rfc3339
          ctx["doc_id"] = doc_id if doc_id
          ctx["patch"] = ScriptContext.json_to_lua_value(patch) unless patch.nil?
          ctx["action"] = action unless action.nil?

          actor_table = build_actor_table
          ctx["actor"] = actor_table if actor_table

          engine.set_global("ctx", ctx)

          # Wire ctx.error to the registered error global
          # Wire ctx.get_children if the helper was registered (only with db)
          engine.run(<<-LUA)
            ctx.error = error
            if __ctx_get_children then
              ctx.get_children = __ctx_get_children
              __ctx_get_children = nil
            end
          LUA
        end

        # Runs the standard validate + hook Lua block for `hook_name`:
        # calls `_MODULE.validate(ctx)` when defined, then
        # `_MODULE.{hook_name}(ctx)` — with `args` appended when
        # `with_args` is true (named actions). Returns a copy of the error
        # accumulator. A Lua runtime error is re-raised as `Error`.
        protected def run_hooks(hook_name : String, with_args : Bool = false) : Array(ValidationError)
          args_suffix = with_args ? ", args" : ""
          engine!.run(<<-LUA)
            if _MODULE ~= nil and _MODULE.validate ~= nil then
              _MODULE.validate(ctx)
            end
            if _MODULE ~= nil and _MODULE.#{hook_name} ~= nil then
              _MODULE.#{hook_name}(ctx#{args_suffix})
            end
          LUA
          @errors.dup
        rescue ex : Lua::Engine::Error
          raise Error.new(ex)
        end

        # Reads back `ctx.root` from the Lua state.
        def read_root : JSON::Any
          engine = @engine.as(Lua::Engine)
          ctx_val = engine.get_global("ctx")
          ctx_hash = ctx_val.as?(Hash(String, Lua::Engine::Value))
          if ctx_hash.nil?
            return JSON::Any.new({} of String => JSON::Any)
          end

          root_val = ctx_hash["root"]?
          if root_val.nil?
            return JSON::Any.new({} of String => JSON::Any)
          end

          ScriptContext.lua_value_to_json(root_val)
        end

        # Returns the engine (guaranteed non-nil after initialize).
        def engine! : Lua::Engine
          @engine.as(Lua::Engine)
        end

        # Closes the engine.
        def close : Nil
          @engine.try(&.close)
        end
      end
    end
  end
end
