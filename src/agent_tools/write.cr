# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../doctype/definition_store"
require "../document/action"
require "../document/create"
require "../document/delete"
require "../document/presenter"
require "../document/update"
require "../event"
require "../http/helpers"
require "../mutation/client"
require "../agent_tools"
require "./discover"
require "./errors"
require "./read"

module Facet
  module AgentTools
    # Write tool group: document mutations for an external agent.
    #
    # - `create_document` — `Document::Create.call` inside a transaction
    #   with `Event::Publisher.flush`. Validation errors surface as
    #   `InvalidParams` with per-field diagnostics.
    # - `update_document` — `Document::Update.call` with the same plumbing
    #   plus `lock_with_chain` (locks the document FOR UPDATE and the
    #   aggregate root FOR SHARE, mirroring REST).
    # - `delete_document` — `Document::Delete.call` (soft delete, tombstone).
    # - `call_action` — `Document::Action.call`. Unknown action → `NotFound`;
    #   bad args → `InvalidParams` with the action's arg diagnostics; RBAC
    #   denial → `RbacDenied`.
    #
    # Visibility: every write tool requires at least one create/update/delete
    # permission line (the `:write` requirement). `call_action` requires a
    # named-action permission (the `:action` requirement).
    module Write
      # Direct tool mutations carry no `cause` name — they are root
      # `request` mutations. The calling surface is stamped by the channel
      # (`"mcp"` for MCP sessions, from the auth context) and
      # `acting_role`. `call_action` keeps the action's cause — the
      # action name is the more precise provenance.

      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "create_document",
            description: "Create one document of the given doctype. 'content' is the full document body; read get_schema first to learn the required fields. For a child doctype (one declaring member_of), pass 'parent_id' — the id of the parent document, which must be readable by the caller. Sidecar doctypes cannot be created here — use create_sidecar with the host document and segment. Returns {data, meta} with the created document content and system metadata (meta.parent_id set for children).",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":    {"type": "string"},
                "doctype":   {"type": "string"},
                "content":   {"type": "object"},
                "parent_id": {"type": "string", "description": "Parent document id — required for child doctypes (member_of), invalid otherwise"}
              },
              "required": ["domain", "doctype", "content"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { create_document(ctx, args) },
          ),
          Registry::Entry.new(
            name: "update_document",
            description: "Partially update one document. 'patch' is a JSON merge patch (RFC 7386) merged over the existing content: new keys are set, a null value REMOVES the key from the document (the way to clear a field). Returns {data, meta} with the updated document content. A deleted document or one outside the role's scope returns NotFound.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string"},
                "doctype":  {"type": "string"},
                "doc_id":   {"type": "string"},
                "patch":    {"type": "object"}
              },
              "required": ["domain", "doctype", "doc_id", "patch"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { update_document(ctx, args) },
          ),
          Registry::Entry.new(
            name: "delete_document",
            description: "Soft-delete one document (tombstone, recoverable through audit replay). Returns {data: null, meta: {deleted: true}}. A missing document or one outside the role's scope returns NotFound.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string"},
                "doctype":  {"type": "string"},
                "doc_id":   {"type": "string"}
              },
              "required": ["domain", "doctype", "doc_id"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { delete_document(ctx, args) },
          ),
          Registry::Entry.new(
            name: "call_action",
            description: "Execute a named action on one document. Pass the action name from get_schema's 'actions' map, with typed 'args' when the action declares them. Returns {data, meta} with the updated document content and the mutation id.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string"},
                "doctype":  {"type": "string"},
                "doc_id":   {"type": "string"},
                "action":   {"type": "string"},
                "args":     {"type": "object"}
              },
              "required": ["domain", "doctype", "doc_id", "action"]
            })),
            requires: :action,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { call_action(ctx, args) },
          ),
          Registry::Entry.new(
            name: "batch",
            description: "Apply an ordered list of writes atomically — all land or nothing does. 'ops' is an array of {op, ...} objects: create (domain, doctype, content, parent_id?), update (domain, doctype, doc_id, patch), delete (domain, doctype, doc_id), action (domain, doctype, doc_id, action, args?) — the same bodies the single tools take. One failure rolls the whole batch back and the error names the failing op index. The direct-write ops (create/update/delete) share one causal trace (list_mutations filter: trace); an action op keeps the action's own cause, the same as the standalone call_action. Ops run in order and lock per aggregate — concurrent batches touching the same aggregates can deadlock; PostgreSQL resolves it and the error tells you to retry. Max #{Facet::Config.instance.mcp.max_batch_ops} ops.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "ops": {"type": "array", "items": {"type": "object"}, "description": "Ordered writes: {op: create|update|delete|action, ...} with the same body the single tools take"}
              },
              "required": ["ops"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { batch(ctx, args) },
          ),
        ]
      end

      # ── Handlers ────────────────────────────────────────────────────

      private def self.create_document(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        content = content_arg(args, "content")
        parent_id = Read.optional_string_arg(args, "parent_id")

        # Parent gate — the same one the nested REST route runs: a child
        # doctype (member_of) requires a readable parent; a root doctype
        # rejects parent_id outright. A child created without parent_id is
        # refused, mirroring the REST flat-create guard.
        meta_overrides, parent_doctype, parent_id = parent_args(ctx, domain, doctype, parent_id)

        result = Database.with_transaction do |db|
          create_in_tx(db, ctx, domain, doctype, content, meta_overrides, parent_doctype, parent_id)
        end
        Facet::Event::Publisher.flush

        case result
        in Facet::Document::Create::Result
          mutation_result(ctx, result.projection, result.mutation_id)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}")
        end
      end

      # The create body, inside a caller-owned transaction: the parent
      # live-lock (when parent-scoped) plus the service call. Shared by
      # the single `create_document` (its own `with_transaction`) and
      # `batch` (one transaction over all ops).
      private def self.create_in_tx(
        db : DB::Connection,
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        content : String,
        meta_overrides : Hash(String, JSON::Any)?,
        parent_doctype : String?,
        parent_id : String?,
      ) : Facet::Document::Create::Result | Facet::ServiceError
        if parent_doctype && parent_id
          # B-276: the child will link to this row, so the row must exist
          # and be live. `parent_args` checked readability before the
          # transaction; the lock answer closes the race to commit and
          # holds for the system bypass, whose parent gate answers true
          # with no row check.
          unless Facet::HTTP::Helpers.lock_live_projection_for_update(db, domain, parent_doctype, parent_id)
            return Facet::ServiceError.new(404, "Not found")
          end
        end
        Facet::Document::Create.call(db, domain, doctype, content, ctx.auth_context, cause: ctx.cause, meta_overrides: meta_overrides)
      end

      # Resolves the `parent_id` argument into the create meta overrides,
      # the parent doctype to lock, and the verified parent id. All three
      # are nil together (a root-doctype create) or non-nil together (a
      # parent-scoped create). Mirrors the nested REST route's gates: a
      # child doctype (member_of) needs a readable parent (non-disclosing
      # 404 on a missing or invisible one; `RbacDenied` without any read
      # grant on the parent doctype); a root doctype rejects parent_id;
      # a child created without parent_id is refused (the REST flat-create
      # guard).
      private def self.parent_args(
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        parent_id : String?,
      ) : {Hash(String, JSON::Any)?, String?, String?}
        definition = Read.fetch_definition!(ctx, domain, doctype)
        member_of = definition.member_of

        if parent_id.nil?
          if member_of
            raise InvalidParams.new("Doctype #{domain}.#{doctype} is a child of #{domain}.#{member_of} — pass 'parent_id' to create it under a parent",
              data: AgentTools.invalid_params_data("parent_id"))
          end
          return {nil, nil, nil}
        end

        unless member_of
          raise InvalidParams.new("Argument 'parent_id' needs a child doctype — #{domain}.#{doctype} declares no member_of",
            data: AgentTools.invalid_params_data("parent_id"))
        end

        Read.ensure_parent_readable!(ctx, domain, member_of, parent_id)
        meta = {"parent_id" => JSON::Any.new(parent_id)} of String => JSON::Any
        {meta, member_of, parent_id}
      end

      private def self.update_document(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")
        patch = content_arg(args, "patch")

        result = Database.with_transaction do |db|
          update_in_tx(db, ctx, domain, doctype, doc_id, patch)
        end
        Facet::Event::Publisher.flush

        case result
        in Facet::Document::Update::Result
          mutation_result(ctx, result.projection, result.mutation_id)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # The update body, inside a caller-owned transaction: the aggregate
      # lock chain plus the merge-patch service call. Shared by the single
      # `update_document` and `batch`.
      private def self.update_in_tx(
        db : DB::Connection,
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        doc_id : String,
        patch : String,
      ) : Facet::Document::Update::Result | Facet::ServiceError
        unless Facet::HTTP::Helpers.lock_with_chain(db, domain, doctype, doc_id)
          return Facet::ServiceError.new(404, "Not found")
        end
        Facet::Document::Update.call(db, domain, doctype, doc_id, patch, ctx.auth_context, cause: ctx.cause)
      end

      private def self.delete_document(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")

        result = Database.with_transaction do |db|
          delete_in_tx(db, ctx, domain, doctype, doc_id)
        end
        Facet::Event::Publisher.flush

        case result
        in Facet::Document::Delete::Result
          JSON::Any.new({
            "data" => JSON::Any.new(nil),
            "meta" => JSON::Any.new({
              "id"       => JSON::Any.new(doc_id),
              "domain"   => JSON::Any.new(domain),
              "doc_type" => JSON::Any.new(doctype),
              "mid"      => JSON::Any.new(result.mutation_id),
              "deleted"  => JSON::Any.new(true),
            } of String => JSON::Any),
          } of String => JSON::Any)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # The delete body, inside a caller-owned transaction. Shared by the
      # single `delete_document` and `batch`.
      private def self.delete_in_tx(
        db : DB::Connection,
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        doc_id : String,
      ) : Facet::Document::Delete::Result | Facet::ServiceError
        unless Facet::HTTP::Helpers.lock_with_chain(db, domain, doctype, doc_id)
          return Facet::ServiceError.new(404, "Not found")
        end
        Facet::Document::Delete.call(db, domain, doctype, doc_id, ctx.auth_context, cause: ctx.cause)
      end

      private def self.call_action(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")
        action = Discover.string_arg(args, "action")
        args_body = args.as_h?.try(&.["args"]?).try(&.to_json) || "{}"

        result = Database.with_transaction do |db|
          action_in_tx(db, ctx, domain, doctype, doc_id, action, args_body)
        end
        Facet::Event::Publisher.flush

        case result
        in Facet::Document::Action::Result
          mutation_result(ctx, result.projection, result.mutation_id)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id} action '#{action}'")
        end
      end

      # The action body, inside a caller-owned transaction. Shared by the
      # single `call_action` and `batch`.
      private def self.action_in_tx(
        db : DB::Connection,
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        doc_id : String,
        action : String,
        args_body : String,
      ) : Facet::Document::Action::Result | Facet::ServiceError
        unless Facet::HTTP::Helpers.lock_with_chain(db, domain, doctype, doc_id)
          return Facet::ServiceError.new(404, "Not found")
        end
        Facet::Document::Action.call(db, domain, doctype, doc_id, action, args_body, ctx.auth_context)
      end

      # ── batch: one transaction over an ordered op list ───────────────

      # A parsed batch op: the kind plus the exact body the matching single
      # tool would take. Built entirely in the validation pass — no lock,
      # no write. `doc_id` and `action` are empty for the kinds that do
      # not use them (a create has no target document yet).
      private record BatchOp,
        kind : String,
        domain : String,
        doctype : String,
        doc_id : String,
        body : String, # content / patch / action args (JSON)
        action : String,
        meta_overrides : Hash(String, JSON::Any)?,
        parent_doctype : String?,
        parent_id : String?

      # Applies every op in one transaction under one causal trace: all
      # land or nothing does. Op shapes are validated before the
      # transaction opens — an unknown kind or malformed body fails before
      # any lock. A service failure inside the transaction raises with the
      # failing op index; the rollback discards every earlier op. Events
      # flush once, after the commit.
      private def self.batch(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        raw_ops = args.as_h?.try(&.["ops"]?).try(&.as_a?)
        raise InvalidParams.new("Argument 'ops' must be an array of objects", data: AgentTools.invalid_params_data("ops")) unless raw_ops

        cap = Facet::Config.instance.mcp.max_batch_ops
        if raw_ops.empty? || raw_ops.size > cap
          raise Capped.new(
            "Argument 'ops' must hold between 1 and #{cap} entries (got #{raw_ops.size})",
            cap,
          )
        end

        commands = raw_ops.map_with_index { |op, i| parse_batch_op(ctx, op, i) }

        # One root cause per batch: every op's mutation carries the same
        # fresh trace id, so the whole batch is one causal cluster in the
        # audit log. The calling surface's kind rides (request for MCP,
        # assistant for the workspace registrar).
        base = ctx.cause || Mutation::Cause.root(Mutation::CauseKind::Request)
        trace_id = Mutation::Client.new_id
        batch_cause = Mutation::Cause.new(
          kind: base.kind, name: base.name, event: base.event,
          source: base.source, parent: base.parent, trace: trace_id,
        )
        batch_ctx = Registry::Context.new(db: ctx.db, auth_context: ctx.auth_context, cause: batch_cause)

        results = [] of JSON::Any
        Database.with_transaction do |db|
          commands.each_with_index do |cmd, i|
            results << run_batch_op(db, batch_ctx, cmd, i)
          end
          results.last
        end
        Facet::Event::Publisher.flush

        JSON::Any.new({
          "data" => JSON::Any.new(results),
          "meta" => JSON::Any.new({
            "ops"   => JSON::Any.new(results.size.to_i64),
            "trace" => JSON::Any.new(trace_id),
          } of String => JSON::Any),
        })
      end

      # Parses and validates one batch op — shape only, before any
      # transaction. The create parent gate runs here too: it is read-only
      # (definition + parent readability), so a malformed op fails before
      # any lock. Per-kind parsing lives in the `parse_<kind>_op` helpers
      # (this method only owns the shared shape checks).
      private def self.parse_batch_op(ctx : Registry::Context, raw : JSON::Any, index : Int32) : BatchOp
        obj = raw.as_h?
        raise InvalidParams.new("Batch op #{index} must be an object", data: batch_op_data(index)) unless obj

        kind = obj["op"]?.try(&.as_s?)
        unless kind && {"create", "update", "delete", "action"}.includes?(kind)
          raise InvalidParams.new(
            "Batch op #{index} has unknown kind '#{kind}' (expected create, update, delete, or action)",
            data: batch_op_data(index),
          )
        end

        domain = batch_string_field(obj, "domain", index, kind)
        doctype = batch_string_field(obj, "doctype", index, kind)

        case kind
        when "create" then parse_create_op(ctx, obj, domain, doctype, index)
        when "update" then parse_update_op(obj, domain, doctype, index)
        when "delete" then parse_delete_op(obj, domain, doctype, index)
        else               parse_action_op(obj, domain, doctype, index)
        end
      end

      # Reads a required non-empty string field off a batch op.
      private def self.batch_string_field(obj : Hash(String, JSON::Any), key : String, index : Int32, kind : String) : String
        value = obj[key]?.try(&.as_s?)
        if value.nil? || value.empty?
          raise InvalidParams.new("Batch op #{index} (#{kind}) needs '#{key}'", data: batch_op_data(index))
        end
        value
      end

      private def self.parse_create_op(
        ctx : Registry::Context,
        obj : Hash(String, JSON::Any),
        domain : String,
        doctype : String,
        index : Int32,
      ) : BatchOp
        content = obj["content"]?.try(&.as_h?)
        raise InvalidParams.new("Batch op #{index} (create) needs a 'content' object", data: batch_op_data(index)) unless content
        parent_id = obj["parent_id"]?.try(&.as_s?)
        meta_overrides, parent_doctype, parent_id = parent_args(ctx, domain, doctype, parent_id)
        BatchOp.new(kind: "create", domain: domain, doctype: doctype, doc_id: "",
          body: content.to_json, action: "", meta_overrides: meta_overrides,
          parent_doctype: parent_doctype, parent_id: parent_id)
      end

      private def self.parse_update_op(obj : Hash(String, JSON::Any), domain : String, doctype : String, index : Int32) : BatchOp
        doc_id = batch_string_field(obj, "doc_id", index, "update")
        patch = obj["patch"]?.try(&.as_h?)
        raise InvalidParams.new("Batch op #{index} (update) needs a 'patch' object", data: batch_op_data(index)) unless patch
        BatchOp.new(kind: "update", domain: domain, doctype: doctype, doc_id: doc_id,
          body: patch.to_json, action: "", meta_overrides: nil,
          parent_doctype: nil, parent_id: nil)
      end

      private def self.parse_delete_op(obj : Hash(String, JSON::Any), domain : String, doctype : String, index : Int32) : BatchOp
        doc_id = batch_string_field(obj, "doc_id", index, "delete")
        BatchOp.new(kind: "delete", domain: domain, doctype: doctype, doc_id: doc_id,
          body: "{}", action: "", meta_overrides: nil,
          parent_doctype: nil, parent_id: nil)
      end

      private def self.parse_action_op(obj : Hash(String, JSON::Any), domain : String, doctype : String, index : Int32) : BatchOp
        doc_id = batch_string_field(obj, "doc_id", index, "action")
        action = batch_string_field(obj, "action", index, "action")
        args_body = obj["args"]?.try(&.as_h?).try(&.to_json) || "{}"
        BatchOp.new(kind: "action", domain: domain, doctype: doctype, doc_id: doc_id,
          body: args_body, action: action, meta_overrides: nil,
          parent_doctype: nil, parent_id: nil)
      end

      private def self.batch_op_data(index : Int32) : JSON::Any
        JSON.parse(%({"reason": "invalid_params", "op_index": #{index}}))
      end

      # Runs one validated op inside the open transaction. A service
      # failure raises `InvalidParams` naming the op index (with the
      # structured per-field details for 422s); the raise rolls the whole
      # transaction back.
      private def self.run_batch_op(db : DB::Connection, ctx : Registry::Context, cmd : BatchOp, index : Int32) : JSON::Any
        result = case cmd.kind
                 when "create"
                   create_in_tx(db, ctx, cmd.domain, cmd.doctype, cmd.body, cmd.meta_overrides, cmd.parent_doctype, cmd.parent_id)
                 when "update"
                   update_in_tx(db, ctx, cmd.domain, cmd.doctype, cmd.doc_id, cmd.body)
                 when "delete"
                   delete_in_tx(db, ctx, cmd.domain, cmd.doctype, cmd.doc_id)
                 else # "action"
                   action_in_tx(db, ctx, cmd.domain, cmd.doctype, cmd.doc_id, cmd.action, cmd.body)
                 end

        case result
        when Facet::ServiceError
          context = "#{cmd.domain}.#{cmd.doctype}##{cmd.doc_id}"
          tool_err = AgentTools.service_error(result, context: context)
          data = JSON.parse(%({"reason": "batch_op_failed", "op_index": #{index}})).as_h
          tool_err.data.try(&.as_h.each { |k, v| data[k] = v })
          raise InvalidParams.new("Batch op #{index} (#{cmd.kind}) failed: #{tool_err.message}", data: JSON::Any.new(data))
        when Facet::Document::Create::Result
          presented = mutation_result(ctx, result.projection, result.mutation_id)
          JSON::Any.new({
            "op"    => JSON::Any.new(cmd.kind),
            "index" => JSON::Any.new(index.to_i64),
            "data"  => presented["data"],
            "meta"  => presented["meta"],
          } of String => JSON::Any)
        when Facet::Document::Update::Result
          presented = mutation_result(ctx, result.projection, result.mutation_id)
          JSON::Any.new({
            "op"    => JSON::Any.new(cmd.kind),
            "index" => JSON::Any.new(index.to_i64),
            "data"  => presented["data"],
            "meta"  => presented["meta"],
          } of String => JSON::Any)
        when Facet::Document::Delete::Result
          JSON::Any.new({
            "op"    => JSON::Any.new(cmd.kind),
            "index" => JSON::Any.new(index.to_i64),
            "data"  => JSON::Any.new(nil),
            "meta"  => JSON::Any.new({
              "id"       => JSON::Any.new(cmd.doc_id),
              "domain"   => JSON::Any.new(cmd.domain),
              "doc_type" => JSON::Any.new(cmd.doctype),
              "mid"      => JSON::Any.new(result.mutation_id),
              "deleted"  => JSON::Any.new(true),
            } of String => JSON::Any),
          } of String => JSON::Any)
        else # Facet::Document::Action::Result
          presented = mutation_result(ctx, result.projection, result.mutation_id)
          JSON::Any.new({
            "op"    => JSON::Any.new(cmd.kind),
            "index" => JSON::Any.new(index.to_i64),
            "data"  => presented["data"],
            "meta"  => presented["meta"],
          } of String => JSON::Any)
        end
      end

      # ── Shared serialization ───────────────────────────────────────────────

      # Presents a mutation result for the calling agent: content goes
      # through the shared presenter (invisible fields and unknown keys
      # omitted for Real principals), metadata unchanged. Read-shaped tool
      # results are already masked — presentation is idempotent.
      private def self.mutation_result(ctx : Registry::Context, proj : Facet::Mutation::Client::Projection, mutation_id : String) : JSON::Any
        definition = Facet::Doctype::DefinitionStore.fetch(ctx.db, "#{proj.domain}.#{proj.doc_type}")
        content = Facet::Document::Presenter.present_content(proj.content, ctx.auth_context, definition)
        JSON::Any.new({
          "data" => content,
          "meta" => Read.projection_meta(proj, mutation_id: mutation_id),
        } of String => JSON::Any)
      end

      # Extracts a required argument that must be a JSON object, returning
      # its canonical JSON string for service consumption. Delegates the
      # parse-and-raise to the shared `Discover.object_arg`.
      private def self.content_arg(args : JSON::Any, key : String) : String
        Discover.object_arg(args, key).to_json
      end
    end
  end
end
