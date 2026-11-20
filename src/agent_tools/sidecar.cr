# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../doctype/definition_store"
require "../document/presenter"
require "../document/sidecar_handler"
require "../event"
require "../agent_tools"
require "./discover"
require "./errors"
require "./read"

module Facet
  module AgentTools
    # Host-scoped sidecar tools — the MCP shape of the nested sidecar
    # routes, generic over every sidecar doctype (comments, attachments,
    # and any later one).
    #
    # A sidecar record hangs off a host document through the host's
    # `sidecars` map (segment → sidecar doctype + reference column), not
    # through `parent_id`, and it is reachable only through the host-scoped
    # REST routes (`POST`/`GET /Api/:domain/:doctype/:id/:segment`). The
    # generic document tools cannot express that shape — `create_document`
    # rejects the flat create of a sidecar doctype, and `list_documents` on
    # the sidecar doctype serves the flat endpoint's grants and scopes only
    # — so these tools own the host-scoped path:
    #
    # - `create_sidecar` — `Document::SidecarHandler.create`: attaches one
    #   record to a host document through the segment the caller names.
    # - `list_sidecars` — `Document::SidecarHandler.list`: lists one host's
    #   segment, paged.
    #
    # Both run the REST route's two-gate contract inside the handler: the
    # caller must be able to read the host record (a missing or invisible
    # host is the non-disclosing `NotFound`; no read grant on the host
    # doctype at all is `RbacDenied`) and hold the nested grant on
    # the host-scoped path (`create`/`read production.Project.Comment`) —
    # a host grant implies it by prefix matching. Flat grants on the
    # sidecar doctype do not participate, exactly as on REST.
    module Sidecar
      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "create_sidecar",
            description: "Create one sidecar record attached to a host document — the host-scoped nested-sidecar create (REST: POST /Api/:domain/:doctype/:id/:segment), generic over every sidecar doctype (comments, attachments, ...). Pass the host's 'domain', 'doctype' and 'doc_id', the 'segment' (a key of the host's sidecars map — get_schema lists them; e.g. 'comments' or 'attachments'), and 'content', the sidecar body (e.g. {\"body\": \"...\"} for a comment). The host's reference column (usually 'target') is set by the route and must not appear in content. Gates match the REST route: the caller must be able to read the host record (missing or invisible → NotFound; no read grant on the host doctype → RbacDenied) and hold the nested create grant — a host create grant implies it; flat grants on the sidecar doctype do not. Returns {data, meta} with the created sidecar.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":  {"type": "string", "description": "Host domain, e.g. 'production'"},
                "doctype": {"type": "string", "description": "Host doctype, e.g. 'Project'"},
                "doc_id":  {"type": "string", "description": "Host document id"},
                "segment": {"type": "string", "description": "Sidecar segment — a key of the host's sidecars map (get_schema lists them), e.g. 'comments'"},
                "content": {"type": "object", "description": "The sidecar body — for a comment, its 'body' text. The host's reference column (usually 'target') is set by the route — omit it."}
              },
              "required": ["domain", "doctype", "doc_id", "segment", "content"]
            })),
            requires: :write,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { create_sidecar(ctx, args) },
          ),
          Registry::Entry.new(
            name: "list_sidecars",
            description: "List the sidecar records of one segment attached to a host document — the host-scoped nested-sidecar list (REST: GET /Api/:domain/:doctype/:id/:segment), generic over every sidecar doctype. Pass the host's 'domain', 'doctype' and 'doc_id' plus the 'segment' (a key of the host's sidecars map — get_schema lists them). Returns {data, meta} with the same envelope as list_documents (total, page, items, truncated, next_cursor — page with page=next_cursor). The nested read grant applies — a host read grant implies it; flat grants on the sidecar doctype do not.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":  {"type": "string", "description": "Host domain"},
                "doctype": {"type": "string", "description": "Host doctype"},
                "doc_id":  {"type": "string", "description": "Host document id"},
                "segment": {"type": "string", "description": "Sidecar segment — a key of the host's sidecars map (get_schema lists them)"},
                "page":    {"type": "integer", "minimum": 1},
                "items":   {"type": "integer", "minimum": 1}
              },
              "required": ["domain", "doctype", "doc_id", "segment"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { list_sidecars(ctx, args) },
          ),
        ]
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.create_sidecar(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")
        segment = Discover.string_arg(args, "segment")
        content = Discover.object_arg(args, "content")

        resolve_segment!(ctx, domain, doctype, segment)

        result = Database.with_transaction do |db|
          Facet::Document::SidecarHandler.create(db, domain, doctype, doc_id, segment, content, ctx.auth_context, cause: ctx.cause)
        end
        Facet::Event::Publisher.flush

        case result
        in Facet::Document::Create::Result
          definition = Facet::Doctype::DefinitionStore.fetch(ctx.db, "#{result.projection.domain}.#{result.projection.doc_type}")
          content = Facet::Document::Presenter.present_content(result.projection.content, ctx.auth_context, definition)
          JSON::Any.new({
            "data" => content,
            "meta" => Read.projection_meta(result.projection, mutation_id: result.mutation_id),
          } of String => JSON::Any)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      private def self.list_sidecars(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")
        segment = Discover.string_arg(args, "segment")
        page = Read.page_arg(args)
        items = Read.items_arg(args)

        resolve_segment!(ctx, domain, doctype, segment)

        result = Facet::Document::SidecarHandler.list(ctx.db, domain, doctype, doc_id, segment, ctx.auth_context, page: page, items_per_page: items)
        case result
        in Document::List::Result
          # The service caps its count at `items + 1` past the page offset;
          # reaching the cap means at least one more page exists.
          Read.list_result_payload(result, page, result.total > items)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # ── Segment resolution ──────────────────────────────────────────────

      # Validates the caller's segment against the host's `sidecars` map.
      # Raises `NotFound` for an unknown host doctype and `InvalidParams`
      # naming the declared segments when the segment is missing — more
      # actionable than the handler's bare "Unknown sidecar" 404, and safe:
      # the map is schema metadata, which get_schema serves ungated.
      private def self.resolve_segment!(ctx : Registry::Context, domain : String, doctype : String, segment : String) : Nil
        definition = Read.fetch_definition!(ctx, domain, doctype)
        return if definition.sidecars.has_key?(segment)

        declared = definition.sidecars.keys.join(", ")
        hint = declared.empty? ? "its sidecars map is empty" : "declared segments: #{declared}"
        raise InvalidParams.new("#{domain}.#{doctype} declares no sidecar segment '#{segment}' — #{hint} (get_schema lists the host's segments)",
          data: AgentTools.invalid_params_data("segment"))
      end
    end
  end
end
