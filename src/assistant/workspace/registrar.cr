# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "agent-cr"

require "../../agent_tools"
require "../../database"
require "../../mutation/provenance"
require "../../rbac/read_enforcer"
require "../tools"
require "../refusal_guard"
require "./context"
require "./skills"

module Facet
  module Assistant
    module Workspace
      # Registers the workspace tool set onto an `Agent`.
      #
      # Document tools are **delegated, not re-implemented**: the registrar
      # mounts every `AgentTools::Registry` entry except `ping` (a session
      # probe with no assistant use). Delegation keeps the two toolsets
      # identical — same handlers, same RBAC, same caps, same error
      # mapping — and new registry entries land here automatically. Tool
      # schemas flow through `Assistant::Tools.schema_parameters`, so a
      # schema is defined once, in the registry.
      #
      # Every delegated call runs with the caller's own `RBAC::AuthContext`,
      # so `ReadEnforcer` / `WriteEnforcer` apply exactly as on REST.
      #
      # On top of the document tools the registrar mounts the skill loader
      # (`read_skill`) and the two UI tools (`navigate`, `show_documents`)
      # whose real effect happens in the chat UI; their callbacks only
      # validate and acknowledge. UI tools register after the document
      # tools. A UI tool's raw arguments reach the frontend because the
      # streaming route lists them in `argument_tools` (see
      # `Stream::ToolTraceHandler#argument_tools`).
      #
      # All callbacks return a JSON string in the shared
      # `Assistant::Tools` envelope, except `read_skill`, whose success
      # path returns the raw markdown body (see `register_read_skill`).
      module Registrar
        # Tools whose raw `arguments` are forwarded to the frontend on the
        # `tool_call` chunk. The chat UI renders or navigates from them.
        UI_TOOL_NAMES = ["navigate", "show_documents"] of String

        # The registry entry the registrar deliberately excludes (an MCP
        # session probe; see the toolset rule in the design doc).
        private PING = "ping"

        # The name of the skill-loader tool.
        private SKILL_TOOL = "read_skill"

        # The full list of tool names registered by this registrar:
        # every registry entry except `ping`, plus `read_skill` and the
        # UI tools. Persisted onto `agent_conversations.enabled_tools` at
        # conversation-creation time so `Agent#load` can re-enable them on
        # resume. Skill names themselves are not tools — the model reaches
        # them through `read_skill`.
        #
        # A def, not a constant: the list reaches into
        # `AgentTools::Registry.entries`, whose descriptions read
        # `Config.instance`. A constant would load the config at require
        # time — before `main.cr` loads dotenv — so every `!env` value
        # would resolve to unset.
        def self.tool_names : Array(String)
          (document_tool_names + [SKILL_TOOL] + UI_TOOL_NAMES).sort!
        end

        # The registry-backed document tool names: every registry entry
        # except `ping`. The registrar spec pins toolset parity against
        # this list.
        def self.document_tool_names : Array(String)
          AgentTools::Registry.entries.reject { |e| e.name == PING }.map(&.name)
        end

        # Registers the full workspace tool set onto `agent`.
        #
        # The `db` connection is captured by the UI-tool callbacks; it must
        # be valid for the lifetime of the streaming turn that owns
        # `agent` (the streaming route runs the whole `session.run` inside
        # `Database.with_db do |db| ... end`). Document tools open their
        # own connection through `AgentTools::Registry.execute`. Every
        # delegated call carries a root `assistant` cause, so the mutations
        # its write tools make are auditable as assistant-driven (the REST
        # session channel alone does not distinguish them).
        def self.register(
          agent : Agent,
          db : DB::Connection,
          context : Context,
          auth_context : RBAC::AuthContext,
        ) : Nil
          register_document_tools(agent, auth_context)
          register_read_skill(agent)
          register_navigate(agent, db, auth_context)
          register_show_documents(agent, db, auth_context)
        end

        # ── Document tools (registry delegation) ────────────────────────

        private def self.register_document_tools(agent : Agent, auth_context : RBAC::AuthContext) : Nil
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

        # ── Skill loader ─────────────────────────────────────────────────

        # Reads a skill markdown body by name. Like the domain builder's
        # `read_skill`, the success path returns the raw markdown (no
        # envelope) — the body already begins with a `# Title` heading, and
        # returning it raw avoids JSON-escaping the markdown.
        private def self.register_read_skill(agent : Agent) : Nil
          agent.register_tool(
            SKILL_TOOL,
            "Read a workspace skill file by name (#{Skills.names.join(", ")}). Returns the skill's raw markdown body. Consult a skill before composing complex filters or aggregates, or before walking child and reference relations.",
            parameters: Assistant::Tools.schema_object(
              properties: {
                "name" => {"type" => "string", "description" => "Skill name"},
              },
              required: ["name"],
            ),
          ) do |args|
            name = args["name"]?.try(&.as_s?)
            next Assistant::Tools.error("Missing 'name' argument") if name.nil?

            skill = Skills.read(name)
            next Assistant::Tools.error("Skill '#{name}' not found") unless skill

            skill.body
          end
        end

        # ── UI tools ─────────────────────────────────────────────────────

        # Navigates the main application for the user. The callback
        # validates the target and — for a document target — confirms the
        # caller may actually read that document before acknowledging; the
        # frontend builds the URL from the forwarded arguments.
        private def self.register_navigate(agent : Agent, db : DB::Connection, auth_context : RBAC::AuthContext) : Nil
          agent.register_tool(
            "navigate",
            "Navigate the user's browser to a page. target: 'document' (needs domain, doctype, id), 'collection' (needs domain and doctype; optional view_slug for the collection view tab), or 'domain' (needs domain). Use it to open what you are talking about. A document target requires read access — an inaccessible target is refused.",
            parameters: Assistant::Tools.schema_object(
              properties: {
                "target"    => {"type" => "string", "description" => "Target kind: 'document', 'collection', or 'domain'"},
                "domain"    => {"type" => "string", "description" => "Domain of the target"},
                "doctype"   => {"type" => "string", "description" => "Doctype of the target (document and collection)"},
                "id"        => {"type" => "string", "description" => "Document id (document only)"},
                "view_slug" => {"type" => "string", "description" => "Collection view tab to open (collection only, optional)"},
              },
              required: ["target", "domain"],
            ),
          ) do |args|
            target = string_arg(args, "target")
            domain = string_arg(args, "domain")

            case target
            when "document"
              doctype = string_arg(args, "doctype")
              id = string_arg(args, "id")
              unless document_readable?(db, domain, doctype, id, auth_context)
                next Assistant::Tools.error("Document '#{domain}.#{doctype}.#{id}' is not available")
              end
              Assistant::Tools.ok({navigated: true, target: target, domain: domain, doctype: doctype, id: id})
            when "collection"
              doctype = string_arg(args, "doctype")
              view_slug = args["view_slug"]?.try(&.as_s?)
              if view_slug
                Assistant::Tools.ok({navigated: true, target: target, domain: domain, doctype: doctype, view_slug: view_slug})
              else
                Assistant::Tools.ok({navigated: true, target: target, domain: domain, doctype: doctype})
              end
            when "domain"
              # Shape only — the domain overview is reachable by every
              # authenticated caller; an unknown domain lands on the app's
              # own 404 surface.
              Assistant::Tools.ok({navigated: true, target: target, domain: domain})
            else
              Assistant::Tools.error("Unknown target '#{target}' — expected 'document', 'collection', or 'domain'")
            end
          end
        end

        # Shows documents to the user inside the chat as cards or compact
        # inline rows. The UI re-reads every document itself — the callback
        # only splits the given ids into readable and not-available, so the
        # model knows what the user will actually see. Unreadable,
        # missing, and tombstoned ids all land in the same `skipped`
        # report: it never says which of the three applied.
        private def self.register_show_documents(agent : Agent, db : DB::Connection, auth_context : RBAC::AuthContext) : Nil
          agent.register_tool(
            "show_documents",
            "Show documents of one doctype to the user inside the chat. Pass ids you received from a tool. display: 'card' (default) for an inspectable card grid, 'inline' for compact rows. Unreadable or unknown ids are dropped and reported back in 'skipped'.",
            parameters: Assistant::Tools.schema_object(
              properties: {
                "domain"  => {"type" => "string", "description" => "Domain of the documents"},
                "doctype" => {"type" => "string", "description" => "Doctype of the documents"},
                "ids"     => {"type" => "array", "description" => "Document ids to show", "items" => {"type" => "string"}, "minItems" => 1},
                "display" => {"type" => "string", "description" => "'card' or 'inline' (default 'card')"},
              },
              required: ["domain", "doctype", "ids"],
            ),
          ) do |args|
            domain = string_arg(args, "domain")
            doctype = string_arg(args, "doctype")
            display = args["display"]?.try(&.as_s?) || "card"
            unless display == "card" || display == "inline"
              next Assistant::Tools.error("'display' must be 'card' or 'inline'")
            end

            ids = ids_arg(args)
            next Assistant::Tools.error("Missing or invalid 'ids' argument (expected a non-empty array of string ids; got #{ids_problem(args)})") unless ids

            rendered, skipped = ids.partition { |id| document_readable?(db, domain, doctype, id, auth_context) }

            Assistant::Tools.ok({
              rendered: rendered,
              skipped:  skipped,
              display:  display,
              domain:   domain,
              doctype:  doctype,
            })
          end
        end

        # ── Guards and arg helpers ───────────────────────────────────────

        # True when the projection row exists, is not a tombstone, and the
        # caller's auth context may read it. Both checks are non-disclosing
        # — the pair collapses "missing" and "denied" into one `false`.
        private def self.document_readable?(
          db : DB::Connection,
          domain : String,
          doctype : String,
          doc_id : String,
          auth_context : RBAC::AuthContext,
        ) : Bool
          exists = db.query_one?(
            "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL LIMIT 1",
            domain, doctype, doc_id,
            as: Int32?,
          )
          return false if exists.nil?

          RBAC::ReadEnforcer.authorized?(db, domain, doctype, doc_id, auth_context)
        end

        # Reads a required non-empty string tool argument; emits the
        # standard missing-argument error — naming what arrived instead —
        # and returns from the callback otherwise.
        private macro string_arg(args, key)
          %value = {{args}}[{{key}}]?.try(&.as_s?)
          next Assistant::Tools.error("Missing or invalid '{{key.id}}' argument (got #{received_shape({{args}}, {{key}})})") if %value.nil? || %value.empty?
          %value
        end

        # Reads the required `ids` argument: a non-empty array of strings.
        # Returns `nil` when the argument is malformed.
        private def self.ids_arg(args : Hash(String, JSON::Any)) : Array(String)?
          arr = args["ids"]?.try(&.as_a?)
          return nil if arr.nil? || arr.empty?

          ids = [] of String
          arr.each do |v|
            s = v.as_s?
            return nil if s.nil?
            ids << s
          end
          ids
        end

        # Describes what arrived for one argument key, so a retrying model
        # sees whether it omitted the key (`nothing`) or sent the wrong
        # shape (`null`, `number`, …) instead of guessing why the call
        # did not parse.
        private def self.received_shape(args : Hash(String, JSON::Any), key : String) : String
          value = args[key]?
          return "nothing" if value.nil?
          return "null" if value.raw.nil?
          return "empty string" if value.as_s? == ""
          json_type_name(value)
        end

        # Describes the received `ids` value for the error message, so the
        # model can correct its call on the next try instead of guessing
        # why the argument did not parse.
        private def self.ids_problem(args : Hash(String, JSON::Any)) : String
          value = args["ids"]?
          return received_shape(args, "ids") if value.nil? || value.raw.nil?

          arr = value.as_a?
          return json_type_name(value) if arr.nil?
          return "empty array" if arr.empty?

          arr.each_with_index do |item, index|
            next if item.as_s?
            return "non-string item at index #{index} (#{json_type_name(item)})"
          end
          "array"
        end

        # The JSON type name of a value, for diagnostic messages.
        private def self.json_type_name(value : JSON::Any) : String
          case value.raw
          when String then "string"
          when Int    then "number"
          when Float  then "number"
          when Bool   then "boolean"
          when Array  then "array"
          when Hash   then "object"
          else             "null"
          end
        end
      end
    end
  end
end
