# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../database"
require "../rbac/auth_context"
require "../mutation/provenance"
require "../doctype/definition_store"
require "../agent_tools"
require "./errors"
require "./discover"
require "./read"
require "./write"
require "./history"
require "./sidecar"
require "./artifacts"

module Facet
  module AgentTools
    # Registry core: tool records, role-filtered visibility, and dispatch.
    #
    # A tool is visible in `tools/list` when the active role's permission
    # map grants at least one permission of the tool's requirement class:
    #
    # - `read`   — at least one `read` (or `*`) permission line
    # - `write`  — at least one `create`/`update`/`delete` (or `*`) line
    # - `action` — at least one named-action or `*` permission line
    #
    # The `action` gate mirrors enforcement: `Permission#matches_action?`
    # accepts the wildcard `*` for any named action, so a role holding only
    # `{"action": "*", "on": "*.*"}` may execute every action — and must
    # therefore see the tool. Reserved CRUD actions (`read`, `create`,
    # `update`, `delete`) alone do not satisfy it.
    #
    # Visibility is a convenience for the agent, never a boundary: the
    # per-doctype enforcement stays in `ReadEnforcer` / `WriteEnforcer` at
    # call time, exactly as on REST.
    #
    # Handlers receive a `Context` (db connection + auth context + optional
    # root cause) and the parsed `arguments` object, and return the tool's
    # `data` payload. The shared envelope (`data` + `meta`) is applied by
    # `MCP::Routes.tools_call`.
    module Registry
      Log = ::Log.for("facet.agent_tools.registry")

      # The execution context handed to every tool handler.
      #
      # `cause` transports the calling surface's root-cause template into
      # the write services (`Document::Create` / `Update` / `Delete` take it
      # as their `cause:`). `nil` (the MCP path) keeps each service's own
      # default — a root `request` mutation; the workspace registrar passes
      # a root `assistant` cause so an LLM-driven write is auditable as
      # such. Read and history handlers ignore it.
      record Context,
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause? = nil

      # A registered tool: advertised metadata plus its handler.
      record Entry,
        name : String,
        description : String,
        input_schema : JSON::Any,
        requires : Symbol, # :read | :write | :action
        handler : Proc(Context, JSON::Any, JSON::Any)

      # ── Visibility ──────────────────────────────────────────────────────

      # True when the role holds at least one permission line whose action
      # matches any of `actions` (the wildcard `*` action matches all).
      private def self.role_grants_any?(auth_context : RBAC::AuthContext, actions : Array(String)) : Bool
        return false unless auth_context.principal.is_a?(RBAC::Principal::Real)
        role = auth_context.principal.as(RBAC::Principal::Real).active_role
        role.permissions.any? do |p|
          actions.includes?(p.action) || p.action == RBAC::Permission::WILDCARD_ACTION
        end
      end

      # Maps a tool's `requires` tag to the permission actions that satisfy it.
      private def self.required_actions(requires : Symbol) : Array(String)
        case requires
        when :read   then ["read"]
        when :write  then ["create", "update", "delete"]
        when :action then [] of String # any named action — handled below
        else              ["read"]
        end
      end

      # Role-filtered listing. `ping` is always visible to a Real principal;
      # every other tool must clear its permission gate.
      def self.visible_entries(auth_context : RBAC::AuthContext) : Array(Entry)
        entries.select do |entry|
          case entry.requires
          when :none   then true
          when :action then role_holds_action_grant?(auth_context)
          else              role_grants_any?(auth_context, required_actions(entry.requires))
          end
        end
      end

      # True when the role holds at least one permission line that satisfies
      # the action requirement: a named action such as `hire` or `promote`,
      # or the wildcard `*` (enforcement accepts `*` for every named action
      # via `Permission#matches_action?`). Reserved CRUD actions alone do
      # not qualify — a read-only role still does not see `call_action`.
      private def self.role_holds_action_grant?(auth_context : RBAC::AuthContext) : Bool
        return false unless auth_context.principal.is_a?(RBAC::Principal::Real)
        role = auth_context.principal.as(RBAC::Principal::Real).active_role
        reserved = ["read", "create", "update", "delete"]
        role.permissions.any? do |p|
          p.action == RBAC::Permission::WILDCARD_ACTION || !reserved.includes?(p.action)
        end
      end

      # ── Dispatch ────────────────────────────────────────────────────────

      # Executes a tool by name inside a pinned DB connection. Raises a
      # `ToolError` subclass on failure; the calling surface renders it.
      # `cause` rides through to the write services (see `Context`).
      def self.execute(auth_context : RBAC::AuthContext, name : String, arguments : JSON::Any, cause : Mutation::Cause? = nil) : JSON::Any
        entry = entries.find { |e| e.name == name }
        raise NotFound.new("Unknown tool: #{name}",
          data: JSON.parse(%({"reason": "unknown_tool", "tool": #{name.to_json}}))) unless entry

        validate_argument_keys!(entry, arguments)

        Database.with_db do |db|
          entry.handler.call(Context.new(db: db, auth_context: auth_context, cause: cause), arguments)
        end
      end

      # Rejects argument keys the tool's handler does not read, before
      # dispatch. A silent ignore reads as success to an agent — it cannot
      # tell a dropped `expand` from a honoured one. The schema's
      # `properties` is the accepted set; an entry with no properties (e.g.
      # `ping`) accepts no keys. One rule here covers every tool on every
      # surface — handlers never validate this themselves.
      private def self.validate_argument_keys!(entry : Entry, arguments : JSON::Any) : Nil
        obj = arguments.raw.nil? ? {} of String => JSON::Any : arguments.as_h?
        raise InvalidParams.new("Tool '#{entry.name}' arguments must be an object", data: AgentTools.invalid_params_data("arguments")) unless obj

        accepted = entry.input_schema.as_h?.try(&.["properties"]?).try(&.as_h?) || {} of String => JSON::Any
        unknown = obj.keys.reject { |key| accepted.has_key?(key) }
        return if unknown.empty?

        accepted_list = accepted.keys.sort!.join(", ")
        raise InvalidParams.new(
          "Unknown argument '#{unknown.first}' for tool '#{entry.name}' (accepted: #{accepted_list})",
          data: JSON.parse(%({"reason": "unknown_argument", "argument": #{unknown.first.to_json}, "tool": #{entry.name.to_json}})),
        )
      end

      # All registered entries (visibility-filtered by `list_for`).
      def self.entries : Array(Entry)
        [
          ping_entry,
        ] of Entry + Discover.entries + Read.entries + Write.entries + History.entries + Sidecar.entries + Artifacts.entries
      end

      # ── Built-in tools ──────────────────────────────────────────────────

      private def self.ping_entry : Entry
        Entry.new(
          name: "ping",
          description: "Health probe. Returns the server's identity and the role this session is mounted under.",
          input_schema: JSON.parse(%({"type": "object", "properties": {}, "required": []})),
          requires: :none,
          handler: ->(ctx : Context, _args : JSON::Any) {
            role_id = ctx.auth_context.principal.is_a?(RBAC::Principal::Real) ? ctx.auth_context.principal.as(RBAC::Principal::Real).active_role.role_id : ""
            JSON::Any.new({
              "server"  => JSON::Any.new("facet"),
              "role"    => JSON::Any.new(role_id),
              "account" => JSON::Any.new(ctx.auth_context.account_id),
            })
          },
        )
      end
    end
  end
end
