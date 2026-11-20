# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "agent-cr"

require "../../agent_tools"
require "../../mutation/provenance"
require "../../rbac/auth_context"
require "../tools"
require "../refusal_guard"

module Facet
  module Assistant
    module App
      # Registers the app assistant's tool set on an `Agent`.
      #
      # Document tools are **delegated, not re-implemented**: the registrar
      # mounts every `AgentTools::Registry` entry except `ping` (a session
      # probe with no assistant use) — the same toolset the workspace
      # assistant mounts. Delegation keeps the toolsets identical — same
      # handlers, same RBAC, same caps, same error mapping — and new
      # registry entries land here automatically. Tool schemas flow through
      # `Assistant::Tools.schema_parameters`, so a schema is defined once,
      # in the registry.
      #
      # Every delegated call runs with the caller's own app-scoped
      # `RBAC::AuthContext`: the app grant ceiling (Layer-1), the role's
      # permission map, read scoping, and field visibility apply exactly as
      # on a REST call by the same account. Each write also carries a root
      # `assistant` cause, so the mutations its write tools make are
      # auditable as assistant-driven.
      #
      # No skills (the skill corpus is main-application guidance) and no UI
      # tools in v1 — the chat package renders none. Document tools open
      # their own connection through `AgentTools::Registry.execute`, so the
      # registrar captures no connection.
      module Registrar
        # The registry entry the registrar deliberately excludes (an MCP
        # session probe; see the toolset rule in the design doc).
        private PING = "ping"

        # The full list of tool names registered by this registrar: every
        # registry entry except `ping`. Persisted onto
        # `agent_conversations.enabled_tools` at conversation-creation time
        # so `Agent#load` can re-enable them on resume.
        #
        # A def, not a constant: the list reaches into
        # `AgentTools::Registry.entries`, whose descriptions read
        # `Config.instance`. A constant would load the config at require
        # time — before `main.cr` loads dotenv — so every `!env` value
        # would resolve to unset.
        def self.tool_names : Array(String)
          AgentTools::Registry.entries.reject { |e| e.name == PING }.map(&.name).sort!
        end

        # Registers the document tool set onto `agent`. The callbacks close
        # over the caller's `auth_context`; the streaming turn that owns
        # `agent` runs under the same app-scoped identity, so the grant
        # ceiling holds for the whole turn.
        def self.register(agent : Agent, auth_context : RBAC::AuthContext) : Nil
          cause = Mutation::Cause.root(Mutation::CauseKind::Assistant)
          # One guard per turn: the registrar runs once per streaming turn,
          # so the refusal counts never outlive the turn. Tool callbacks run
          # sequentially in the agent fiber, so no lock is needed.
          guard = RefusalGuard.new

          AgentTools::Registry.entries.each do |entry|
            next if entry.name == PING

            agent.register_tool(
              entry.name,
              entry.description,
              parameters: Assistant::Tools.schema_parameters(entry.input_schema),
            ) do |args|
              begin
                result = AgentTools::Registry.execute(auth_context, entry.name, JSON::Any.new(args), cause)
                Assistant::Tools.ok(result)
              rescue e : AgentTools::ToolError
                guard.result(entry.name, args, tool_error_envelope(e))
              end
            end
          end
        end

        # Renders a failed registry call as the tool error envelope. The
        # registry's message is already non-disclosing where REST is
        # (a class-level denial surfaces as a bare refusal, an invisible
        # document as not-found). The structured payload rides as `details`
        # so the model keeps the per-field diagnostics of validation failures.
        private def self.tool_error_envelope(e : AgentTools::ToolError) : String
          message = e.message || "Tool failed"
          if data = e.data
            {ok: false, error: message, details: data}.to_json
          else
            Assistant::Tools.error(message)
          end
        end
      end
    end
  end
end
