# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./config"
require "./rbac/auth_context"
require "./mutation/provenance"
require "./agent_tools/errors"
require "./agent_tools/registry"
require "./agent_tools/skills"

module Facet
  # Shared tool catalogue for LLM agents. Serves the MCP resource server
  # (external agents) and the assistant registrars (in-process agents) from
  # one definition: a tool's name, description, input schema, and handler
  # exist once, in `AgentTools::Registry`, so every surface exposes the same
  # capabilities with the same RBAC, caps, and error mapping.
  #
  # The listing is role-filtered — `list_for` returns only what the
  # active role permits (MCP's URL-pinned role makes that deterministic
  # per session). Visibility is a convenience, never a boundary; the
  # per-doctype enforcement stays in `ReadEnforcer` / `WriteEnforcer` at
  # call time, exactly as on REST.
  #
  # Cache invalidation: `RoleCache` (the `fanout:iam.Roles:*` subscriber)
  # calls `mark_stale` on every roles mutation; the next listing rebuilds.
  # Open MCP sessions learn about the change through
  # `notifications/tools/list_changed`, emitted by the dispatch layer when
  # it observes a generation bump.
  module AgentTools
    Log = ::Log.for("facet.agent_tools")

    # A single tool definition as advertised by `tools/list`.
    record Definition,
      name : String,
      description : String,
      input_schema : JSON::Any

    # ── Role-filtered listing ─────────────────────────────────────────────

    # Generation counter bumped on every `mark_stale`. Dispatch compares
    # its cached generation against this to decide whether to emit
    # `notifications/tools/list_changed`.
    @@generation : Int64 = 0

    def self.mark_stale : Nil
      @@generation += 1
      Log.debug { "Agent tools cache marked stale (generation=#{@@generation})" }
    end

    def self.current_generation : Int64
      @@generation
    end

    # Returns the tools visible to the given auth context. Every tool
    # clears its permission gate in `Registry.visible_entries`; the system
    # check stays here so the fail-closed invariant (D6) lives in one place.
    def self.list_for(auth_context : RBAC::AuthContext) : Array(Definition)
      return [] of Definition if auth_context.system?
      Registry.visible_entries(auth_context).map do |entry|
        Definition.new(
          name: entry.name,
          description: entry.description,
          input_schema: entry.input_schema,
        )
      end
    end

    # Executes a tool call. Returns the JSON payload for the tool's
    # `result.content`. Raises a `ToolError` subclass on tool-level failure.
    # `cause` rides through to the write services (see `Registry::Context`).
    def self.call(auth_context : RBAC::AuthContext, name : String, arguments : JSON::Any, cause : Mutation::Cause? = nil) : JSON::Any
      Registry.execute(auth_context, name, arguments, cause)
    end

    # Maps a `Facet::ServiceError` returned by a Document or Audit service
    # to the tool-error taxonomy. Keeps the per-doctype non-disclosing rule:
    # a denied read or write surfaces as `RbacDenied`; a missing or
    # tombstoned document surfaces as `NotFound`; validation failures
    # surface as `InvalidParams` with per-field diagnostics.
    #
    # The 422 message folds in a compact summary of the validation details
    # (`field: message (code)`), so a client that renders only the message
    # still learns which field failed and why. The full structured array
    # rides in `error.data.details` for clients that render it.
    def self.service_error(err : Facet::ServiceError, context : String) : ToolError
      case err.status
      when 403
        RbacDenied.new
      when 404, 410
        deleted = err.status == 410
        NotFound.new(
          "#{context} not found#{deleted ? " (deleted)" : ""}",
          data: JSON.parse(%({"reason": "not_found"#{deleted ? ", \"deleted\": true" : ""}})),
        )
      when 422
        data = if d = err.details
                 JSON::Any.new({"details" => JSON.parse(d.to_json)} of String => JSON::Any)
               end
        InvalidParams.new(validation_message(err), data)
      else
        ToolError.new(err.message.empty? ? "Tool failed (status #{err.status})" : err.message)
      end
    end

    # Builds the 422 tool-error message: the service message plus a compact
    # per-field summary of the validation details, capped at 3 entries with
    # a count of the rest. `ValidationError#field` is nil for non-field
    # errors (script rejections, RBAC) — those render message-only.
    private def self.validation_message(err : Facet::ServiceError) : String
      base = err.message.empty? ? "Validation failed" : err.message
      details = err.details
      return base if details.nil? || details.empty?

      summary = details.first(3).map do |e|
        entry = e.field ? "#{e.field}: #{e.message}" : e.message
        e.code ? "#{entry} (#{e.code})" : entry
      end.join("; ")
      more = details.size > 3 ? " (+#{details.size - 3} more)" : ""
      "#{base}: #{summary}#{more}"
    end
  end
end
