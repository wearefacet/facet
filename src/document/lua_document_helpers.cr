# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../mutation/client"
require "../event/publisher"
require "../grants"
require "./create"
require "./update"
require "./delete"
require "./list"
require "../rbac"

module Facet
  module Document
    # Crystal-backed Lua functions for inter-document operations within the
    # same domain.
    #
    # Provides `document.*` functions registered as raw C callbacks on a
    # `Lua::Engine`. Each operation uses `RBAC::AuthContext.system` and is
    # locked to the domain captured at registration time.
    #
    # ## Cross-domain read ceiling
    #
    # `document.get` / `document.list` accept a qualified `domain.Doctype`
    # first argument. A qualified form pointing at a **foreign** domain is
    # grant-gated: no active `core.DomainGrant` from that domain for the
    # registration domain raises a Lua error with a clear message; with a
    # grant, the returned content is projected down to the fields whose
    # tags the grant covers (untagged fields resolve to `["default"]`).
    # Same-domain reads keep full content (D7). Writes never accept the
    # override. The gate covers hook scripts and doctype action scripts
    # alike — both register through this shared helper.
    #
    # The denial is an ordinary catchable Lua error: every handler below
    # rescues Crystal exceptions escaping its body and re-raises them
    # through `LibLua.error`, so `pcall(document.list, "foreign.Thing", ...)`
    # sees `{false, message}` and the script can recover. When the script
    # does NOT catch it, the recorded `Facet::ServiceError` (422) is
    # surfaced by the script driver with its native status instead of an
    # opaque 500 — see `ScriptContext::Base#service_errors` (B-30).
    #
    # ## Registered functions
    #
    # | Lua function | Crystal backend | Returns |
    # |---|---|---|
    # | `document.create(doc_type, content_json)` | `Document::Create.create_from_parsed` | projection table \| `nil, err` |
    # | `document.get(doc_type, doc_id)` | `Mutation::Client.fetch_projection` | projection table \| `nil, err` |
    # | `document.update(doc_type, doc_id, content_json)` | `Document::Update.call` | projection table \| `nil, err` |
    # | `document.delete(doc_type, doc_id)` | `Document::Delete.call` | `true` \| `nil, err` |
    # | `document.list(doc_type, [filters], [sort], [page], [per_page])` | `Document::List.call` | `{items={...}, total=N}` \| `nil, err` |
    module LuaDocumentHelpers
      # Registers `document.*` Lua functions on the given engine.
      #
      # All operations are locked to `domain` and execute under the system
      # auth context (full RBAC bypass). The `db` connection is reused
      # from the parent transaction so child operations nest under
      # PG savepoints.
      #
      # `cause` is the cause template for the writes the script performs:
      # kind/name/event/source describe the driving context (action, hook)
      # and `parent`/`trace` are already bound by the driver — a nested
      # write points at the driving mutation id and inherits its causal
      # trace. `provenance` carries the ORIGINAL caller's channel (the
      # system auth context here only bypasses RBAC — it must not stamp
      # `internal` over a user/app/MCP channel). Both are stamped on the
      # resulting mutation's audit metadata so the audit log attributes the
      # side effect to the trigger that caused it.
      #
      # A global `document` Lua table is created with each function as a
      # field, so they can be called as `document.create(...)`,
      # `document.get(...)`, etc.
      def self.register(
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        actor_id : String? = nil,
        reentrant : Bool = false,
        service_errors : Array(Facet::ServiceError)? = nil,
      ) : Nil
        auth = RBAC::AuthContext.system
        state = engine.raw_state

        # Create the `document` table on the Lua stack
        LibLua.createtable(state, 0, 5)

        # Register each helper as a field on the table (table is at -1)
        register_document_create_on(state, engine, db, domain, auth, cause, provenance, actor_id, reentrant, service_errors)
        register_document_get_on(state, engine, db, domain, service_errors)
        register_document_update_on(state, engine, db, domain, auth, cause, provenance, actor_id, reentrant, service_errors)
        register_document_delete_on(state, engine, db, domain, auth, cause, provenance, actor_id, reentrant, service_errors)
        register_document_list_on(state, engine, db, domain, auth, service_errors)

        # Assign the completed table to the global `document`
        LibLua.setglobal(state, "document")
      end

      # Registers a **read-only** `document` table on the given engine: the
      # two read bindings (`document.get`, `document.list`) plus refusing
      # stubs for the three writers. The compute sandbox registers this — a
      # compute runs mid-mutation, and a write from it would re-enter the
      # pipeline and blur the cause chain (B-110 part 1). Writes are refused
      # with a catchable Lua error naming the sanctioned surfaces.
      #
      # `cause` and `provenance` are accepted for registration parity with
      # `register`; the read paths stamp no mutations, so they carry no
      # cause. Reads behave exactly as in the hook/action contexts: same
      # cross-domain grant ceiling, same projection table shape.
      def self.register_read_only(
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        service_errors : Array(Facet::ServiceError)? = nil,
      ) : Nil
        auth = RBAC::AuthContext.system
        state = engine.raw_state

        # Create the `document` table on the Lua stack
        LibLua.createtable(state, 0, 5)

        register_refusal_on(state, engine, "create")
        register_document_get_on(state, engine, db, domain, service_errors)
        register_refusal_on(state, engine, "update")
        register_refusal_on(state, engine, "delete")
        register_document_list_on(state, engine, db, domain, auth, service_errors)

        # Assign the completed table to the global `document`
        LibLua.setglobal(state, "document")
      end

      # ── Private: raw function registrations ────────────────────────────

      # Registers one write binding as a refusing stub. The message is the
      # compute sandbox's write rule: computed fields must not write — a
      # write from a compute would re-enter the mutation pipeline.
      private def self.register_refusal_on(state : LibLua::State, engine : Facet::Lua::Engine, name : String) : Nil
        engine.raw_function_in_table(state, name) do |s|
          LibLua.pushstring(s, "computed fields must not write — use an action or a hook")
          LibLua.error(s)
          0
        end
      end

      private def self.register_document_create_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        auth : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actor_id : String?,
        reentrant : Bool,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "create") do |s|
          doc_type = read_string_arg(s, 1)
          doc_type = resolve_write_doctype(domain, doc_type, service_errors)
          content = read_content_arg(s, 2)

          # `create_from_parsed` takes `actioner_id` as an explicit param,
          # so the propagated actor (or system fallback) is stamped on the
          # mutation while the system auth context still drives authorization.
          effective_actor = actor_id || auth.account_id

          result = Facet::Document::Create.create_from_parsed(
            db, domain, doc_type, content, auth, effective_actor,
            cause: cause, provenance: provenance, reentrant: reentrant)

          case result
          in Facet::Document::Create::Result
            push_projection_table(s, result.projection)
            1
          in Facet::ServiceError
            # Record the native status before raising so the script driver
            # can surface the refusal as its own status (422 etc.) instead
            # of an opaque 500 — see `ScriptContext::Base#service_errors`.
            service_errors.try(&.push(result))
            LibLua.pushstring(s, result.message)
            LibLua.error(s)
            0
          end
        rescue ex : Exception
          raise_lua_error(s, ex)
        end
      end

      private def self.register_document_get_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "get") do |s|
          doc_type = read_string_arg(s, 1)
          doc_id = read_string_arg(s, 2)

          # A qualified `domain.Doctype` first argument overrides the
          # registration domain — hooks may read across domains. Writes
          # never honor this override; only reads do.
          read_domain, read_doctype = split_qualified(domain, doc_type)

          # Grant ceiling (G4): a foreign read needs an active grant, and
          # the projection is reduced to the covered fields.
          assert_cross_domain_read(db, domain, read_domain, read_doctype, service_errors)

          proj = Facet::Mutation::Client.fetch_projection(db, read_domain, read_doctype, doc_id)

          push_projection_table(s, grant_projected(db, domain, read_domain, read_doctype, proj))
          1
        rescue PG::Error | DB::NoResultsError
          LibLua.pushstring(s, "Document #{domain}.#{doc_type}##{doc_id} not found")
          LibLua.error(s)
          0
        rescue ex : Exception
          raise_lua_error(s, ex)
        end
      end

      private def self.register_document_update_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        auth : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actor_id : String?,
        reentrant : Bool,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "update") do |s|
          doc_type = read_string_arg(s, 1)
          doc_type = resolve_write_doctype(domain, doc_type, service_errors)
          doc_id = read_string_arg(s, 2)
          content_json_str = read_content_arg_json_string(s, 3)

          result = Facet::Document::Update.call(
            db, domain, doc_type, doc_id, content_json_str, auth,
            cause: cause, provenance: provenance, actioner_id: actor_id,
            reentrant: reentrant)

          case result
          in Facet::Document::Update::Result
            push_projection_table(s, result.projection)
            1
          in Facet::ServiceError
            service_errors.try(&.push(result))
            LibLua.pushstring(s, result.message)
            LibLua.error(s)
            0
          end
        rescue ex : Exception
          raise_lua_error(s, ex)
        end
      end

      private def self.register_document_delete_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        auth : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actor_id : String?,
        reentrant : Bool,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "delete") do |s|
          doc_type = read_string_arg(s, 1)
          doc_type = resolve_write_doctype(domain, doc_type, service_errors)
          doc_id = read_string_arg(s, 2)

          result = Facet::Document::Delete.call(
            db, domain, doc_type, doc_id, auth,
            cause: cause, provenance: provenance, actioner_id: actor_id,
            reentrant: reentrant)

          case result
          in Facet::Document::Delete::Result
            LibLua.pushboolean(s, 1)
            1
          in Facet::ServiceError
            service_errors.try(&.push(result))
            LibLua.pushstring(s, result.message)
            LibLua.error(s)
            0
          end
        rescue ex : Exception
          raise_lua_error(s, ex)
        end
      end

      private def self.register_document_list_on(
        state : LibLua::State,
        engine : Facet::Lua::Engine,
        db : DB::Connection,
        domain : String,
        auth : RBAC::AuthContext,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        engine.raw_function_in_table(state, "list") do |s|
          nargs = LibLua.gettop(s)
          doc_type = read_string_arg(s, 1)

          # A qualified `domain.Doctype` first argument overrides the
          # registration domain for cross-domain reads (mirrors
          # `document.get`).
          read_domain, read_doctype = split_qualified(domain, doc_type)

          # Grant ceiling (G4): a foreign list needs an active grant, and
          # the rows are projected per covered tags.
          assert_cross_domain_read(db, domain, read_domain, read_doctype, service_errors)

          filters = if nargs >= 2 && type_is_table(s, 2)
                      parse_filters_table(s, 2)
                    else
                      {} of String => JSON::Any
                    end

          sort = if nargs >= 3 && type_is_table(s, 3)
                   parse_string_array(s, 3)
                 else
                   ["id"]
                 end

          page = if nargs >= 4 && type_is_number(s, 4)
                   LibLua.tointegerx(s, 4, out page_isnum).to_i32
                 else
                   1
                 end

          per_page = if nargs >= 5 && type_is_number(s, 5)
                       LibLua.tointegerx(s, 5, out perpage_isnum).to_i32
                     else
                       100
                     end

          result = Facet::Document::List.call(
            db, read_domain, read_doctype,
            filters: filters,
            sort: sort,
            page: page,
            items_per_page: per_page,
            auth_context: auth,
          )

          case result
          in Facet::Document::List::Result
            push_list_result_table(s, grant_projected_list(db, domain, read_domain, read_doctype, result))
            1
          in Facet::ServiceError
            service_errors.try(&.push(result))
            LibLua.pushstring(s, result.message)
            LibLua.error(s)
            0
          in Facet::Document::List::AggregateResult
            # Unreachable: no aggregate is requested on this path. The union
            # member exists because `Document::List.call` can return one.
            LibLua.pushstring(s, "document.list never returns an aggregate")
            LibLua.error(s)
            0
          end
        rescue ex : Exception
          # Without this conversion a Crystal exception (e.g. the G4
          # cross-domain denial) crosses the Lua-C boundary unconverted:
          # `pcall` cannot catch it and the action runner renders 500.
          raise_lua_error(s, ex)
        end
      end

      # ── Private: cross-domain grant ceiling ─────────────────────────

      # Raises (surfacing as a Lua error) when `read_domain` is foreign to
      # the registration domain and no active grant admits it on
      # `read_doctype`. Same-domain reads pass freely (D7).
      private def self.assert_cross_domain_read(
        db : DB::Connection,
        registration_domain : String,
        read_domain : String,
        read_doctype : String,
        service_errors : Array(Facet::ServiceError)?,
      ) : Nil
        return if read_domain == registration_domain

        unless Grants::Registry.active?(db, registration_domain, read_domain, read_doctype)
          message = "Cross-domain read denied: no active grant from '#{read_domain}' to '#{registration_domain}' on '#{read_doctype}'"
          # Record the refusal before raising so an uncaught unwind surfaces
          # it with its native 422 status instead of an opaque 500 (the B-30
          # driver contract, `ScriptContext::Base#service_errors`).
          service_errors.try(&.push(Facet::ServiceError.new(422, message)))
          raise message
        end
      end

      # Projects a fetched projection's content down to the fields the
      # registration domain's grant covers. Same-domain projections pass
      # through untouched. (The projection's own domain is `read_domain`
      # — the domain the read resolved to.)
      private def self.grant_projected(
        db : DB::Connection,
        registration_domain : String,
        read_domain : String,
        read_doctype : String,
        proj : Facet::Mutation::Client::Projection,
      ) : Facet::Mutation::Client::Projection
        return proj if read_domain == registration_domain

        projected = Grants::Registry.project(db, registration_domain, read_domain, read_doctype, proj.content)
        proj.with_content(projected)
      end

      # Projects every row of a list result through the grant mask. Rows
      # are plain content maps — `Grants::Registry.project` reduces each.
      private def self.grant_projected_list(
        db : DB::Connection,
        registration_domain : String,
        read_domain : String,
        read_doctype : String,
        result : Facet::Document::List::Result,
      ) : Facet::Document::List::Result
        return result if read_domain == registration_domain

        items = result.items.map do |item|
          item.with_content(Grants::Registry.project(db, registration_domain, read_domain, read_doctype, item.content))
        end
        Facet::Document::List::Result.new(items: items, total: result.total, more: result.more)
      end

      # Splits a `domain.Doctype` first argument. When the caller passes a
      # qualified form, the explicit domain/doctype override the registration
      # domain — this is the cross-domain read path used by hooks (plan
      # decision 3). A bare doctype (no `.`) keeps the registration domain.
      #
      # The id segment of a reference may itself contain a `.` — this helper
      # splits only on the first `.` of the *doctype* argument, so a doctype
      # name with a `.` (none today, but kept consistent with
      # `ReferenceType#split_qualified`) would not collide. Domain names never
      # contain `.`.
      private def self.split_qualified(
        registration_domain : String,
        doc_type_arg : String,
      ) : {String, String}
        parts = doc_type_arg.split('.', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          {registration_domain, doc_type_arg}
        end
      end

      # Resolves the doctype argument of a write (`document.create` / `update`
      # / `delete`). Writes mutate in the script's own domain: the accepted
      # form is a bare doctype, or a qualified `domain.Doctype` whose domain
      # equals the registration domain — the qualifier is stripped, so a
      # script written with qualified names still works unchanged. A
      # qualified name pointing at a foreign domain is refused fast; the
      # cross-domain grant path is read-only and does not exist for writes.
      #
      # The refusal is recorded before raising (same driver contract as
      # `assert_cross_domain_read`) so an uncaught unwind surfaces with its
      # native 422 status instead of an opaque 500.
      private def self.resolve_write_doctype(
        registration_domain : String,
        doc_type_arg : String,
        service_errors : Array(Facet::ServiceError)?,
      ) : String
        parts = doc_type_arg.split('.', 2)
        return doc_type_arg if parts.size == 1
        return parts[1] if parts[0] == registration_domain

        message = "Document writes take a bare same-domain doctype name: '#{doc_type_arg}' names domain '#{parts[0]}', but this script writes in its own domain '#{registration_domain}'"
        service_errors.try(&.push(Facet::ServiceError.new(422, message)))
        raise message
      end

      # ── Private: Lua stack helpers ─────────────────────────────────────

      # Reads a string argument from the Lua stack at the given index.
      # Raises if the argument is not a string.
      private def self.read_string_arg(state : LibLua::State, index : Int32) : String
        ptr = LibLua.tolstring(state, index, nil)
        raise "Expected string argument at position #{index}" if ptr.null?
        String.new(ptr)
      end

      # Pushes `nil` followed by `message` onto the Lua stack.
      private def self.push_nil_error(state : LibLua::State, message : String) : Nil
        LibLua.pushnil(state)
        LibLua.pushstring(state, message)
      end

      # Converts a Crystal exception escaping a `document.*` handler body
      # into a catchable Lua error — `pcall` sees `{false, message}`. This
      # honours the documented contract that every `document.*` function
      # raises a Lua error on failure; without the conversion the exception
      # crosses the Lua-C boundary unconverted and aborts the whole
      # action/hook as a 500.
      private def self.raise_lua_error(state : LibLua::State, ex : Exception) : Int32
        LibLua.pushstring(state, ex.message || "Unknown error")
        LibLua.error(state)
        0
      end

      # Returns `true` if the value at `index` is a table (or absent/nil).
      private def self.type_is_table(state : LibLua::State, index : Int32) : Bool
        idx = LibLua.absindex(state, index)
        LibLua.gettop(state) >= idx && LibLua.type(state, idx) == 5
      end

      # Returns `true` if the value at `index` is a number.
      private def self.type_is_number(state : LibLua::State, index : Int32) : Bool
        idx = LibLua.absindex(state, index)
        LibLua.gettop(state) >= idx && LibLua.type(state, idx) == 3
      end

      # Reads a content argument: accepts a Lua table (serialized to JSON)
      # or a JSON string. Returns JSON::Any.
      private def self.read_content_arg(state : LibLua::State, index : Int32) : JSON::Any
        idx = LibLua.absindex(state, index)
        if LibLua.type(state, idx) == 5
          # Lua table — convert via ScriptContext stack converter
          Facet::Document::ScriptContext.lua_stack_to_json_any(state, index)
        else
          ptr = LibLua.tolstring(state, index, nil)
          str = ptr.null? ? "{}" : String.new(ptr)
          begin
            JSON.parse(str)
          rescue JSON::ParseException
            JSON::Any.new({} of String => JSON::Any)
          end
        end
      end

      # Reads a content argument and returns a JSON string.
      # Used by `document.update` which requires a JSON string internally.
      private def self.read_content_arg_json_string(state : LibLua::State, index : Int32) : String
        idx = LibLua.absindex(state, index)
        if LibLua.type(state, idx) == 5
          Facet::Document::ScriptContext.lua_stack_to_json_string(state, index)
        else
          ptr = LibLua.tolstring(state, index, nil)
          ptr.null? ? "{}" : String.new(ptr)
        end
      end

      # ── Private: push projection as Lua table ──────────────────────────

      # Pushes a `Mutation::Client::Projection` onto the Lua stack as a table.
      private def self.push_projection_table(
        state : LibLua::State,
        proj : Facet::Mutation::Client::Projection,
      ) : Nil
        LibLua.createtable(state, 0, 9)

        LibLua.pushstring(state, proj.id)
        LibLua.setfield(state, -2, "id")

        LibLua.pushstring(state, proj.domain)
        LibLua.setfield(state, -2, "domain")

        LibLua.pushstring(state, proj.doc_type)
        LibLua.setfield(state, -2, "doc_type")

        LibLua.pushstring(state, proj.state)
        LibLua.setfield(state, -2, "state")

        LibLua.pushinteger(state, proj.version.to_i64)
        LibLua.setfield(state, -2, "version")

        # content pushed as JSON string; Lua code can parse with json.decode()
        LibLua.pushstring(state, proj.content.to_json)
        LibLua.setfield(state, -2, "content")

        # meta pushed as JSON string
        LibLua.pushstring(state, proj.meta.to_json)
        LibLua.setfield(state, -2, "meta")

        # Timestamps as ISO-8601 strings
        LibLua.pushstring(state, proj.created_at.to_rfc3339)
        LibLua.setfield(state, -2, "created_at")

        LibLua.pushstring(state, proj.updated_at.to_rfc3339)
        LibLua.setfield(state, -2, "updated_at")

        # deleted_at is nullable
        if da = proj.deleted_at
          LibLua.pushstring(state, da.to_rfc3339)
        else
          LibLua.pushnil(state)
        end
        LibLua.setfield(state, -2, "deleted_at")
      end

      # ── Private: parse Lua tables into Crystal types ───────────────────

      # Converts a Lua table at `index` into a `Hash(String, JSON::Any)`.
      # String keys become hash keys; number keys are stringified.
      private def self.parse_filters_table(
        state : LibLua::State,
        index : Int32,
      ) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        abs_idx = LibLua.absindex(state, index)

        LibLua.pushnil(state)
        while LibLua.next(state, abs_idx) != 0
          # key at -2, value at -1
          key_str = if LibLua.type(state, -2) == 4
                      ptr = LibLua.tolstring(state, -2, nil)
                      if ptr.null?
                        next_with_pop(state)
                        next
                      end
                      String.new(ptr)
                    else
                      LibLua.tonumberx(state, -2, out isnum)
                      next_with_pop(state)
                      next
                    end

          value = ScriptContext.lua_stack_to_json_any(state, -1)
          result[key_str] = value

          # Pop value, keep key for next iteration
          LibLua.settop(state, -2)
        end

        result
      end

      # Converts a Lua table at `index` into an `Array(String)`.
      # Only string values are collected; non-string values are skipped.
      private def self.parse_string_array(
        state : LibLua::State,
        index : Int32,
      ) : Array(String)
        result = [] of String
        abs_idx = LibLua.absindex(state, index)

        LibLua.pushnil(state)
        while LibLua.next(state, abs_idx) != 0
          ptr = LibLua.tolstring(state, -1, nil)
          unless ptr.null?
            result << String.new(ptr)
          end
          LibLua.settop(state, -2)
        end

        result
      end

      # Helper: pop the top of the stack and return nil, used inside
      # `lua_next` loops to skip a value.
      private def self.next_with_pop(state : LibLua::State) : Nil
        LibLua.settop(state, -2)
      end

      # ── Private: push List result as Lua table ─────────────────────────

      # Pushes a `Document::List::Result` onto the Lua stack as a table
      # with `items` (array of projection tables) and `total` (integer).
      private def self.push_list_result_table(
        state : LibLua::State,
        result : Facet::Document::List::Result,
      ) : Nil
        LibLua.createtable(state, 0, 2)

        # items array
        LibLua.createtable(state, result.items.size, 0)
        result.items.each_with_index do |item, i|
          push_projection_table(state, item)
          LibLua.rawseti(state, -2, i + 1)
        end
        LibLua.setfield(state, -2, "items")

        # total
        LibLua.pushinteger(state, result.total)
        LibLua.setfield(state, -2, "total")
      end
    end
  end
end
