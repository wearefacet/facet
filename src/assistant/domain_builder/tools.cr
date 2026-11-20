# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "agent-cr"
require "db"
require "../tools"
require "../../mutation/provenance"
require "./context"

module Facet
  module Assistant
    module DomainBuilder
      # Registers the domain-builder tool set onto an `Agent`.
      #
      # Every tool callback returns a JSON string. Success and error payloads
      # use the shared `Facet::Assistant::Tools` envelope (`ok` / `error`),
      # and write tools run through `Tools.tool_mutation`.
      #
      # Exception: `read_skill` returns the skill's raw markdown body on
      # success (no envelope) — see `register_read_skill`.
      #
      # The assistant runs as a system-tier principal. RBAC is fully
      # bypassed; the draft-domain scoping is enforced inside each tool
      # callback via the `ensure_*` helpers below. Write mutations are
      # attributed to the conversation owner (`Auth.auth_context_for`) and
      # stamped with the `assistant` cause named `domain-builder`
      # (`WRITE_CAUSE`) so the audit log shows who asked, not which
      # principal executed the write.
      module Registrar
        # Cause stamped on every write-tool mutation: the write is an
        # LLM-driven tool call, and `name` carries the assistant surface
        # so audit can tell the domain builder from the workspace
        # assistant (whose rows carry a nameless `assistant` cause).
        WRITE_CAUSE = Mutation::Cause.root(Mutation::CauseKind::Assistant, name: "domain-builder")

        # The full list of tool names registered by this registrar. Persisted
        # onto the `agent_conversations.enabled_tools` jsonb column at
        # conversation-creation time so `Agent#load` can re-enable them on
        # resume (it skips names not registered by the registrar).
        TOOL_NAMES = [
          # Read-only
          "list_domains",
          "list_doctypes",
          "get_doctype",
          "get_domain",
          "list_documents",
          "get_document",
          "list_document_views",
          "get_document_view",
          "list_collection_views",
          "get_collection_view",
          "check_doctype",
          "read_skill",
          # Write — doctype definitions
          "create_doctype",
          "update_doctype",
          "delete_doctype",
          # Write — document view templates
          "create_document_view",
          "update_document_view",
          "delete_document_view",
          # Write — collection view templates
          "create_collection_view",
          "update_collection_view",
          "delete_collection_view",
          # Write — sample documents
          "create_document",
          "delete_document",
          # UI — frontend-rendered tools (raw arguments forwarded on the
          # `tool_call` chunk; see `Stream::ToolTraceHandler#argument_tools`)
          "preview_view",
          "go_to_page",
        ] of String

        # Registers every tool onto `agent`. The `db` connection is captured
        # by tool callbacks; it must be valid for the lifetime of the
        # streaming turn that owns `agent` (the streaming route runs the
        # whole `session.run` inside `Database.with_db do |db| ... end`).
        #
        # Write tools are only registered once `context.draft_domain` has
        # been verified to actually point at a draft `core.Domain`
        # projection (`Context#verify_draft_domain?`). Without this check, a
        # forged `context` payload (e.g. created via the generic
        # conversation-create route with `draft_domain` pointing at a live
        # production domain) would give the system-tier assistant tools
        # unfettered write access — RBAC is fully bypassed for the assistant
        # principal.
        def self.register(agent : Agent, db : DB::Connection, context : Context) : Nil
          # Read-only tools
          register_list_domains(agent, db)
          register_list_doctypes(agent, db, context)
          register_get_doctype(agent, db)
          register_get_domain(agent, db)
          register_list_documents(agent, db, context)
          register_get_document(agent, db, context)
          register_list_document_views(agent, db, context)
          register_get_document_view(agent, db, context)
          register_list_collection_views(agent, db, context)
          register_get_collection_view(agent, db, context)
          register_check_doctype(agent, db)
          register_read_skill(agent)
          register_ui_tools(agent)

          return unless context.verify_draft_domain?(db)

          # Write tools (draft-domain scoped)
          register_create_doctype(agent, db, context)
          register_update_doctype(agent, db, context)
          register_delete_doctype(agent, db, context)
          register_create_document_view(agent, db, context)
          register_update_document_view(agent, db, context)
          register_delete_document_view(agent, db, context)
          register_create_collection_view(agent, db, context)
          register_update_collection_view(agent, db, context)
          register_delete_collection_view(agent, db, context)
          register_create_document(agent, db, context)
          register_delete_document(agent, db, context)
        end

        # ── Guard helpers ──────────────────────────────────────────────

        # Returns `nil` when `domain` matches the conversation's draft
        # domain; otherwise an error string suitable for a tool-callback
        # error payload. Used by write tools whose payload carries the
        # logical domain directly (e.g. doctype definitions).
        private def self.ensure_draft_domain(context : Context, domain : String) : String?
          return nil if domain == context.draft_domain
          "Domain '#{domain}' is not the conversation's draft domain '#{context.draft_domain}'"
        end

        # Verifies a doctype definition row's `content.domain` field
        # matches the draft. Returns `nil` on success, an error string
        # otherwise. Used by tools that operate on draft-domain doctypes
        # looked up by `doctype_id` (e.g. `update_doctype`).
        #
        # Storage identity is always `core.DocType`; the logical domain is
        # in the definition's `content.domain` field.
        private def self.ensure_doctype_in_draft!(db : DB::Connection, context : Context, doctype_id : String) : String?
          row = db.query_one?(
            "SELECT content->>'domain' FROM projections WHERE domain='core' AND doc_type='DocType' AND id=$1 AND deleted_at IS NULL",
            doctype_id,
            as: String?,
          )
          return "Doctype '#{doctype_id}' not found" if row.nil?
          return nil if row == context.draft_domain
          "Doctype '#{doctype_id}' belongs to domain '#{row}', not the draft '#{context.draft_domain}'"
        end

        # Verifies a `core.DocumentView` row belongs to a doctype whose
        # `content.domain` matches the draft. Returns `nil` on success,
        # an error string otherwise.
        private def self.ensure_view_in_draft!(db : DB::Connection, context : Context, doc_id : String) : String?
          parent = db.query_one?(
            "SELECT content->>'parent_doctype' FROM projections WHERE domain='core' AND doc_type='DocumentView' AND id=$1 AND deleted_at IS NULL",
            doc_id,
            as: String?,
          )
          return "DocumentView '#{doc_id}' not found" if parent.nil?
          ensure_doctype_in_draft!(db, context, parent)
        end

        # Verifies a `core.CollectionView` row belongs to a doctype whose
        # `content.domain` matches the draft. CollectionView carries no
        # `parent_doctype` content field — the parent is `meta.parent_id`.
        private def self.ensure_collection_view_in_draft!(db : DB::Connection, context : Context, doc_id : String) : String?
          parent = db.query_one?(
            "SELECT meta->>'parent_id' FROM projections WHERE domain='core' AND doc_type='CollectionView' AND id=$1 AND deleted_at IS NULL",
            doc_id,
            as: String?,
          )
          return "CollectionView '#{doc_id}' not found" if parent.nil?
          ensure_doctype_in_draft!(db, context, parent)
        end

        # Verifies a document projection's `domain` column matches the draft.
        private def self.ensure_doc_in_draft!(db : DB::Connection, context : Context, domain : String, doc_type : String, doc_id : String) : String?
          err = ensure_draft_domain(context, domain)
          return err if err

          exists = db.query_one?(
            "SELECT 1 FROM projections WHERE domain=$1 AND doc_type=$2 AND id=$3 AND deleted_at IS NULL",
            domain, doc_type, doc_id,
            as: Int32?,
          )
          return "Document '#{domain}.#{doc_type}.#{doc_id}' not found" if exists.nil?
          nil
        end

        # Structural check result for a DocumentView `template` argument:
        # `errors` block the mutation, `warnings` are reported on success.
        record ViewTemplateCheck,
          errors : Array(ValidationError),
          warnings : Array(String) do
          def errors_empty? : Bool
            errors.empty?
          end
        end

        # Runs `Doctype::ViewTemplateValidator.validate` on a template argument and
        # maps the issues to the tool envelope: `:error` issues become
        # `ValidationError` details, `:warning` issues become messages the
        # agent can fix with `update_document_view`. The definition-aware
        # pass checks input bindings against the parent doctype schema.
        private def self.check_view_template(template : JSON::Any?, definition : Facet::Doctype::DoctypeDefinition?) : ViewTemplateCheck
          issues = Facet::Doctype::ViewTemplateValidator.validate(template, definition)
          error_details = Facet::Doctype::ViewTemplateValidator.errors(issues).map do |i|
            ValidationError.new(i.message, i.path, "template")
          end
          warnings = issues.reject(&.severity.==(:error)).map(&.message)
          ViewTemplateCheck.new(error_details, warnings)
        end

        # Builds a JSON-Schema object for tool parameters. The canonical
        # implementation lives on the shared `Assistant::Tools` envelope
        # module; this delegate keeps the registrar's call sites unchanged.
        private def self.schema_object(
          properties : Hash(String, Hash(String, V)),
          required : Array(String),
        ) : Hash(String, JSON::Any) forall V
          Tools.schema_object(properties, required)
        end

        # Reads a required string tool argument. Emits the standard
        # missing-argument error and returns from the tool callback when
        # the key is absent or not a string. The error names the keys the
        # call actually carried — an intermittent missing argument is
        # almost always a truncated or mis-shaped tool-call payload, and
        # the key list decides that in one look.
        private macro req_s(key)
          %raw = args[{{key}}]?
          %value = %raw.try(&.as_s?)
          if %value.nil?
            next Tools.error("Argument '{{key.id}}' must be a string") if %raw
            %keys = args.keys
            %received = %keys.empty? ? "none" : %keys.join(", ")
            next Tools.error("Missing '{{key.id}}' argument (received: #{%received})")
          end
          %value
        end

        # Reads a required object/array tool argument. Same contract as
        # `req_s` but returns the raw `JSON::Any`.
        private macro req_any(key)
          %value = args[{{key}}]?
          if %value.nil?
            %keys = args.keys
            %received = %keys.empty? ? "none" : %keys.join(", ")
            next Tools.error("Missing '{{key.id}}' argument (received: #{%received})")
          end
          %value
        end
      end
    end
  end
end

# ── Tool registration implementations ─────────────────────────────────────
#
# Each `register_*` function calls `agent.register_tool` with a name,
# description, JSON-Schema parameters, and a callback that returns a
# JSON string. The callback is responsible for:
# 1. Validating its arguments.
# 2. Enforcing the draft-domain guard for write tools.
# 3. Delegating to the appropriate service (`Doctype::Create`,
#    `Document::Read`, etc.).
# 4. Formatting the result as `{ok:true, data:...}` or
#    `{ok:false, error:...}`.

require "./tools/read_tools"
require "./tools/write_tools"
require "./tools/ui_tools"
