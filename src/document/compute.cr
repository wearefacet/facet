# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "db"
require "../lua"
require "../doctype/doctype_definition"
require "../error"
require "../mutation/provenance"
require "./script_context"

module Facet
  module Document
    # Runs computed (`data`) fields for a document after mutation.
    #
    # For each computed field whose `compute_when` list intersects with the
    # set of changed field names, the corresponding Lua function
    # `compute_{suffix}` is called in a shared Lua engine with the same
    # `ctx` table. `ctx.root` is updated after each computed field so that
    # subsequent compute functions see the latest values.
    #
    # This module does **not** handle validation — it merges computed
    # values into the document and returns any errors.
    #
    # **Evaluation order:** Computed fields are sorted topologically so that
    # fields whose `compute_when` references other computed fields are
    # evaluated after those dependencies. This ensures that e.g.
    # `total = subtotal - discount` is computed after `subtotal`.
    #
    # **Script surface:** when `db` and `domain` are supplied, the sandbox
    # exposes a **read-only** `document` global — `document.get` and
    # `document.list` work; the three writers refuse with a clear Lua error
    # (a compute runs mid-mutation; a write from it would re-enter the
    # pipeline and blur the cause chain). See
    # `LuaDocumentHelpers.register_read_only`.
    #
    # **Children in context:** when `children` is supplied, the ctx table
    # carries `ctx.children.<relationship>` — an array of the live child
    # rows' content, deleted rows excluded. Use `stage_children` to build
    # the table: one indexed query per relationship the to-run fields'
    # `compute_when` names. A relationship-named field on the create pass
    # (`changed_fields: nil`, parent id not yet resolved) sees an empty
    # table per named relationship.
    #
    # **Document id in context:** when `doc_id` is supplied, the ctx table
    # carries `ctx.doc_id` — the id of the document whose field is computed
    # — so a script can scope a `document.list` filter to that document.
    # The update, action, and parent-recompute passes supply it. The create
    # pass cannot (the id is generated at persist time), so a
    # relationship-named field re-runs with the id once the children land.
    module Compute
      # Runs computed fields based on changed field names.
      #
      # When `changed_fields` is `nil`, **all** computed fields are
      # evaluated (used on initial create where everything is new).
      # Otherwise a field runs when its `compute_when` list intersects the
      # changed names — a field with no `compute_when` runs on every call.
      #
      # Returns a tuple of `{enriched_document, error_messages}`.
      def self.call(
        script : String,
        definition : Doctype::DoctypeDefinition,
        document : JSON::Any,
        changed_fields : Set(String)?,
        actioner_id : String = "system",
        now : Time = Time.utc,
        db : DB::Connection? = nil,
        domain : String? = nil,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        children : Hash(String, Array(JSON::Any))? = nil,
        doc_id : String? = nil,
      ) : {JSON::Any, Array(ValidationError)}
        Facet::Telemetry.trace "document.compute" do |span|
          # Collect candidate computed fields
          candidates = [] of Tuple(String, String, Array(String)?)
          candidate_fields(definition, changed_fields).each do |field_name|
            field = definition.fields[field_name]
            compute_fn = field.compute
            next if compute_fn.nil?
            candidates << {field_name, compute_fn, field.compute_when}
          end

          # Sort candidates topologically: fields that depend on other computed
          # fields (in compute_when) are evaluated after those dependencies.
          to_compute = topological_sort(candidates, definition)

          if to_compute.empty?
            span["field_count"] = "0"
            next {document, [] of ValidationError}
          end

          span["field_count"] = to_compute.size.to_s

          errors = [] of ValidationError
          current = document

          # Spin up a single Lua engine for all computed fields in this batch.
          begin
            sandbox = Lua::Sandbox.new
            # The JSON helpers ride along: `document.get` / `document.list`
            # return `content` as a JSON string, and a compute function that
            # reads through them needs `util.json_decode` to use it.
            sandbox.register_util_globals!(json_helpers: true)
            engine = sandbox.engine
            if db && domain
              LuaDocumentHelpers.register_read_only(engine, db, domain, cause, provenance)
            end
            wrapped = ScriptContext.wrap_script(script)
            engine.run(wrapped)

            # Register error function
            sandbox.register_error_global(errors, "compute")

            # We'll set up ctx once and update ctx.root between fields.
            ctx = Hash(String, Lua::Engine::Value).new
            ctx["actor_id"] = actioner_id
            ctx["now"] = now.to_rfc3339
            ctx["doc_id"] = doc_id if doc_id
            if children
              ctx["children"] = ScriptContext.json_to_lua_value(children_to_json(children))
            end
            engine.set_global("ctx", ctx)
            engine.run("ctx.error = error")

            to_compute.each do |field_name, compute_fn|
              # Update ctx.root to the current document state
              engine.set_global("ctx", update_root(ctx, current))
              # Re-wire ctx.error after replacing the ctx global
              engine.run("ctx.error = error")

              # Compute functions follow the convention: compute_{suffix}
              lua_function = "compute_#{compute_fn}"

              # Call the compute function. `_ROOT` captures ctx.root after
              # the call so the Crystal side can honour a hook-style write
              # to the computed field when the function returns nil.
              engine.run(<<-LUA)
              _G._ROOT = ctx.root
              if _MODULE ~= nil and _MODULE.#{lua_function} ~= nil then
                local result = _MODULE.#{lua_function}(ctx)
                if result ~= nil then
                  _G._COMPUTED = result
                else
                  _G._COMPUTED = nil
                end
              else
                _G._COMPUTED = nil
              end
            LUA

              unless errors.empty?
                break
              end

              # Read the computed result and merge it into the document.
              computed = engine.get_global("_COMPUTED")
              value = computed.nil? ? nil : ScriptContext.lua_value_to_json(computed)
              resolved = computed_value(value, engine.get_global("_ROOT"), current, field_name)
              current = merge_value(current, field_name, resolved)
            end

            if errors.empty?
              {current, errors}
            else
              Telemetry.record_error(span, errors.map(&.message).join("; "), status: 422)
              {document, errors}
            end
          rescue ex : Lua::Engine::Error
            # The module chunk carries the `wrap_script` line, so rebase one
            # more line onto the author's numbering (B-318).
            msg = "Compute function raised: #{Lua::Engine::Error.rebase_position(ex.message, 1)}"
            errors << ValidationError.new(
              field: nil,
              message: msg,
              code: "compute_runtime",
            )
            Telemetry.record_error(span, msg, status: 500)
            {document, errors}
          ensure
            sandbox.try(&.close)
          end
        end
      end

      # ── Public: selection + children staging ─────────────────────

      # Returns the computed-field names that run for a changed-field set —
      # the same selection rule `call` applies. `changed_fields == nil`
      # selects every computed field (the create pass); otherwise a field
      # runs when its `compute_when` list intersects the changed names, and
      # a field with no `compute_when` runs on every call. Shared with
      # `stage_children` and the parent-recompute walk so both see the
      # identical rule.
      def self.candidate_fields(
        definition : Doctype::DoctypeDefinition,
        changed_fields : Set(String)?,
      ) : Array(String)
        definition.computed_field_names.select do |field_name|
          field = definition.fields[field_name]
          next false if field.compute.nil?
          compute_when = field.compute_when
          next true if changed_fields.nil? || compute_when.nil?
          compute_when.to_set.intersects?(changed_fields)
        end
      end

      # Stages the `ctx.children` table for one compute run: for every
      # candidate field whose `compute_when` names a child relationship of
      # this doctype, one indexed query fetches the live child rows'
      # content (tombstones excluded). `parent_doc_id` nil — the create
      # pass, before the document id is resolved — stages empty tables
      # without querying. One query per relationship per run.
      def self.stage_children(
        db : DB::Connection?,
        domain : String?,
        definition : Doctype::DoctypeDefinition,
        parent_doc_id : String?,
        changed_fields : Set(String)?,
      ) : Hash(String, Array(JSON::Any))
        staged = {} of String => Array(JSON::Any)
        return staged if db.nil? || domain.nil?

        candidate_fields(definition, changed_fields).each do |field_name|
          compute_when = definition.fields[field_name].compute_when
          next if compute_when.nil?

          compute_when.each do |trigger|
            next if staged.has_key?(trigger)
            rel = definition.children[trigger]?
            next if rel.nil?
            staged[trigger] = if parent_doc_id.nil?
                                [] of JSON::Any
                              else
                                fetch_live_children(db, domain, rel.doctype, parent_doc_id)
                              end
          end
        end
        staged
      end

      # ── Private ──────────────────────────────────────────────────

      # Live child rows of one parent, oldest first. Uses the composite
      # index on `(domain, doc_type, meta->>'parent_id')`.
      private def self.fetch_live_children(
        db : DB::Connection,
        domain : String,
        child_doctype : String,
        parent_id : String,
      ) : Array(JSON::Any)
        rows = [] of JSON::Any
        db.query_each(
          "SELECT content FROM projections WHERE domain = $1 AND doc_type = $2 AND meta->>'parent_id' = $3 AND deleted_at IS NULL ORDER BY id",
          domain, child_doctype, parent_id,
        ) do |rs|
          rows << rs.read(JSON::Any)
        end
        rows
      end

      # Converts the staged children map into the JSON shape handed to the
      # ctx table: `{relationship => [child content, ...]}`.
      private def self.children_to_json(children : Hash(String, Array(JSON::Any))) : JSON::Any
        JSON::Any.new(children.to_h { |rel, rows| {rel, JSON::Any.new(rows)} })
      end

      # Resolves the value that lands in the computed field. The function's
      # return value is the primary contract; when it is nil, a `ctx.root`
      # write to the field is honoured so the natural hook-style form works
      # too. The write only counts when it differs from the pre-call value —
      # `ctx.root` starts from the current content, so an untouched field
      # must still clear (a nil return keeps its conditional-compute
      # meaning).
      private def self.computed_value(
        returned : JSON::Any?,
        root_after : Lua::Engine::Value?,
        current : JSON::Any,
        field_name : String,
      ) : JSON::Any?
        return returned unless returned.nil?
        return nil if root_after.nil?

        mutated = ScriptContext.lua_value_to_json(root_after)
        written = mutated.as_h?.try(&.[field_name]?)
        return nil if written.nil? || written == current.as_h?.try(&.[field_name]?)
        written
      end

      # Topologically sorts computed fields so that dependencies
      # (fields listed in `compute_when` that are themselves computed)
      # are evaluated before their dependents.
      #
      # Fields with no inter-computed-field dependencies retain their
      # original relative order.
      private def self.topological_sort(
        candidates : Array(Tuple(String, String, Array(String)?)),
        definition : Doctype::DoctypeDefinition,
      ) : Array(Tuple(String, String))
        computed_set = definition.computed_field_names.to_set

        # Build adjacency: for each field, which computed fields does it depend on?
        deps = {} of String => Set(String)
        names = Set(String).new
        candidates.each do |field_name, _compute_fn, compute_when|
          names << field_name
          depends = Set(String).new
          if compute_when
            compute_when.each do |trigger|
              if computed_set.includes?(trigger)
                depends << trigger
              end
            end
          end
          deps[field_name] = depends
        end

        # Kahn's algorithm: process fields with no remaining dependencies first
        remaining = deps.dup
        sorted = [] of Tuple(String, String)
        lookup = candidates.to_h { |fn, cf, _| {fn, cf} }

        loop do
          # Find fields with no (remaining) dependencies among computed fields
          ready = remaining.select { |_fn, depends| depends.empty? }.keys.sort!
          break if ready.empty?

          ready.each do |field_name|
            compute_fn = lookup[field_name]
            sorted << {field_name, compute_fn}
            remaining.delete(field_name)

            # Remove this field from other fields' dependency sets
            remaining.each do |_other_fn, other_deps|
              other_deps.delete(field_name)
            end
          end
        end

        # Any remaining fields have circular dependencies — add them anyway
        # in their original order to avoid silent omission.
        remaining.each_key do |field_name|
          sorted << {field_name, lookup[field_name]}
        end

        sorted
      end

      # Returns a fresh ctx hash with the updated root.
      private def self.update_root(
        ctx_base : Hash(String, Lua::Engine::Value),
        document : JSON::Any,
      ) : Hash(String, Lua::Engine::Value)
        ctx = ctx_base.dup
        ctx["root"] = ScriptContext.json_to_lua_value(document)
        ctx
      end

      # Merges a computed value into the document at the given field name.
      private def self.merge_value(
        document : JSON::Any,
        field_name : String,
        value : JSON::Any?,
      ) : JSON::Any
        hash = document.as_h.dup
        if value.nil?
          hash.delete(field_name)
        else
          hash[field_name] = value
        end
        JSON::Any.new(hash)
      end
    end
  end
end
