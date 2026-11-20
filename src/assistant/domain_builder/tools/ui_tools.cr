# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  module Assistant
    module DomainBuilder
      module Registrar
        # ── UI tools ─────────────────────────────────────────────────
        #
        # Tools whose real effect happens in the frontend chat UI, not on
        # the backend. The callback only validates the arguments and
        # returns an ack; the frontend intercepts the `tool_call` chunk
        # (which carries the raw `arguments` for these names — see
        # `Stream::ToolTraceHandler#argument_tools`) and renders the
        # matching surface or navigates.
        #
        # These tools are registered on every domain-builder conversation,
        # before the draft-domain check: the model may preview a template
        # it has not created yet, and navigation does not depend on the
        # draft being verified.
        UI_TOOL_NAMES = ["preview_view", "go_to_page"] of String

        # Shows a Document View Template (DVT) or a collection surface to
        # the user inside the chat, rendered with fake data. The frontend
        # owns rendering; the callback only validates the payload shape.
        private def self.register_preview_view(agent : Agent) : Nil
          agent.register_tool(
            "preview_view",
            "Show the user a live preview of a document view template (DVT) or a collection listing surface, rendered inside the chat with fake data. Use after (or before) authoring a view so the user can see the result. kind='document' renders a single-document template tree; kind='collection' renders a listing surface.",
            schema_object(
              properties: {
                "kind"        => {"type" => "string", "description" => "Preview kind: 'document' (single-document DVT) or 'collection' (listing surface)"},
                "template"    => {"type" => "object", "description" => "For kind='document': the template node tree (same shape as a core.DocumentView template field)"},
                "surface"     => {"type" => "string", "description" => "Collection surface when kind='collection': 'table' or 'calendar'"},
                "config"      => {"type" => "object", "description" => "Collection view config: {columns: [{key, label?, width?}]} for table; a CalendarViewConfig for calendar"},
                "sample_data" => {"type" => "object", "description" => "Optional plausible field values for the preview document (field key -> value). The frontend generates missing values"},
                "title"       => {"type" => "string", "description" => "Optional human title shown on the preview card"},
              },
              required: ["kind"],
            ),
          ) do |args|
            kind = req_s("kind")
            case kind
            when "document"
              template = req_any("template")
              next Tools.error("'template' must be an object when kind='document'") unless template.as_h?
            when "collection"
              surface = req_s("surface")
              unless surface == "table" || surface == "calendar"
                next Tools.error("Unknown surface '#{surface}' — expected 'table' or 'calendar'")
              end
            else
              next Tools.error("Unknown kind '#{kind}' — expected 'document' or 'collection'")
            end
            Tools.ok({rendered: true, kind: kind})
          end
        end

        # Navigates the builder UI to a page. The frontend builds the URL
        # from the conversation's draft domain; the callback only validates
        # the target page.
        private def self.register_go_to_page(agent : Agent) : Nil
          agent.register_tool(
            "go_to_page",
            "Navigate the builder UI to a page. page: 'overview' | 'doctypes' | 'check' | 'grants' | 'doctype' (needs doctype_id, optional tab) | 'preview' (optional path array). Use to bring the user to what you are talking about.",
            schema_object(
              properties: {
                "page"       => {"type" => "string", "description" => "Target page: overview, doctypes, check, grants, doctype, preview"},
                "doctype_id" => {"type" => "string", "description" => "Qualified doctype id (required for page='doctype')"},
                "tab"        => {"type" => "string", "description" => "Doctype editor tab to open (optional)"},
                "path"       => {"type" => "array", "description" => "Optional path segments for page='preview'", "items" => {"type" => "string"}},
              },
              required: ["page"],
            ),
          ) do |args|
            page = req_s("page")
            allowed = Set{"overview", "doctypes", "check", "grants", "doctype", "preview"}
            unless allowed.includes?(page)
              next Tools.error("Unknown page '#{page}' — expected one of #{allowed.to_a.sort.join(", ")}")
            end
            Tools.ok({navigated: true, page: page})
          end
        end

        def self.register_ui_tools(agent : Agent) : Nil
          register_preview_view(agent)
          register_go_to_page(agent)
        end
      end
    end
  end
end
