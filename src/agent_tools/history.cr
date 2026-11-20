# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../audit/list"
require "../config"
require "../database"
require "../document/read"
require "../document/backrefs"
require "../mutation/client"
require "../agent_tools"
require "./caps"
require "./discover"
require "./errors"
require "./read"

module Facet
  module AgentTools
    # History tool group: inspection of the append-only mutation log and
    # of document back-references for an external agent.
    #
    # - `list_mutations` — `Audit::List.call` in document-history mode
    #   (domain+doctype+doc_id pinned). The target document read is
    #   gated by `Audit::List`'s built-in authorization: no read grant
    #   on the doctype surfaces as `RbacDenied`; a grant holder who
    #   cannot see the target surfaces as `NotFound` (non-disclosing),
    #   mirroring REST.
    # - `get_links` — the projection's precomputed `links` column (the
    #   urn:facet:… references this document points to), read-gated by
    #   `Document::Read`.
    module History
      # Filter keys `Audit::List` accepts on the `mutations` table, with the
      # operator suffixes its column builder serves per column. Used to give
      # a clear `InvalidParams` on unknown fields and unsupported operators
      # rather than let the service silently drop them.
      KNOWN_FILTER_FIELDS    = ["action", "actioner_id", "app", "channel", "kind", "trace", "emitted_at"]
      EQUALITY_FILTER_FIELDS = Set{"action", "actioner_id", "app", "channel", "kind", "trace"}
      EQUALITY_OPERATORS     = Set{"eq", "ne"}
      EMITTED_AT_OPERATORS   = Set{"gte", "lte"}

      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "list_mutations",
            description: "List the mutation history of one document, or — with no doc_id — the recent mutations of the whole workspace (domain/doctype narrow as filters; needs the wildcard read grant). Filters: action (eq/ne), actioner_id (eq/ne), app (eq/ne), channel (eq/ne), kind (eq/ne — cause kind), trace (eq/ne — causal cluster id), emitted_at (gte/lte). An unsupported operator raises an error — it never silently matches nothing. Sort with field names, '-' prefix for descending (default -emitted_at). Returns {data, meta} with the mutation records and pagination info.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string", "description": "Domain — required with doc_id; optional workspace filter without it"},
                "doctype":  {"type": "string", "description": "Doctype — required with doc_id; optional workspace filter without it"},
                "doc_id":   {"type": "string", "description": "Document id — omit for the workspace-wide view"},
                "filters":  {"type": "object", "description": "Keys: action, actioner_id, app, emitted_at with __op suffix (eq, ne for the first three; gte, lte for emitted_at)"},
                "sort":     {"type": "array", "items": {"type": "string"}},
                "page":     {"type": "integer", "minimum": 1},
                "items":    {"type": "integer", "minimum": 1}
              },
              "required": []
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { list_mutations(ctx, args) },
          ),
          Registry::Entry.new(
            name: "get_links",
            description: "Get the outbound links of one document — the urn:facet:… references this document points to (from its reference fields and inline longtext links). Document references only: urn:facet:artifact:<id> links and file-field values are never included — use list_artifact_refs for those. Read-gated. For the inverse query (which documents point at this one) use get_backrefs. Returns {data, meta} where data is the links array and meta carries the document's system metadata.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string"},
                "doctype":  {"type": "string"},
                "doc_id":   {"type": "string"}
              },
              "required": ["domain", "doctype", "doc_id"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { get_links(ctx, args) },
          ),
          Registry::Entry.new(
            name: "get_backrefs",
            description: "Find the live documents that point at one document — the inverse of get_links. Pass the target's domain, doctype and doc_id. A target you cannot see (missing, deleted, or outside your scope) raises NotFound; no read grant on its doctype raises RbacDenied. Searches every doctype the caller can read and returns stub rows ({id, domain, doc_type, display_name}); unreadable doctypes are skipped silently and tombstoned referrers are excluded — the same non-disclosure as list. Use it before a delete to see what would break. A state-pinned URN (urn:facet:...?state=...) is a distinct reference and does not match the live document. Documents only — to find which documents embed a file artifact, use list_artifact_refs.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":   {"type": "string"},
                "doctype":  {"type": "string"},
                "doc_id":   {"type": "string"}
              },
              "required": ["domain", "doctype", "doc_id"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { get_backrefs(ctx, args) },
          ),
        ]
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.list_mutations(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = optional_string(args, "domain")
        doctype = optional_string(args, "doctype")
        doc_id = optional_string(args, "doc_id")
        filters = filters_arg(args)
        sort = sort_arg(args)
        page = page_arg(args)
        items = items_arg(args)

        # Document mode requires all three pins; the global mode takes
        # domain/doctype as optional filters (validated by Audit::List).
        if doc_id
          if domain.nil? || doctype.nil?
            raise InvalidParams.new("Document history needs 'domain' and 'doctype' together with 'doc_id'",
              data: AgentTools.invalid_params_data("doc_id"))
          end
        end

        validate_filter_keys(filters)

        result = Facet::Audit::List.call(
          ctx.db,
          domain: domain, doc_type: doctype, doc_id: doc_id,
          filters: filters, sort: sort, page: page, items_per_page: items,
          auth_context: ctx.auth_context,
        )
        case result
        in Facet::Audit::List::Result
          payload = {
            "data" => JSON::Any.new(result.items.map { |m| mutation_json(m) }),
            "meta" => JSON::Any.new({
              "total"       => JSON::Any.new(result.total),
              "page"        => JSON::Any.new(page.to_i64),
              "items"       => JSON::Any.new(result.items.size.to_i64),
              "truncated"   => JSON::Any.new(false),
              "next_cursor" => JSON::Any.new(nil),
            } of String => JSON::Any),
          } of String => JSON::Any
          JSON::Any.new(AgentTools::Caps.apply_response_caps(payload, page))
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # Reads an optional string argument (JSON null counts as absent).
      private def self.optional_string(args : JSON::Any, key : String) : String?
        raw = args.as_h?.try(&.[key]?)
        return nil if raw.nil? || raw.raw.nil?
        str = raw.as_s?
        raise InvalidParams.new("Argument '#{key}' must be a string", data: AgentTools.invalid_params_data(key)) unless str
        str
      end

      private def self.get_links(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")

        result = Facet::Document::Read.call(ctx.db, domain, doctype, doc_id, ctx.auth_context)
        case result
        in Facet::Document::Read::Result
          JSON::Any.new({
            "data" => result.projection.links,
            "meta" => Read.projection_meta(result.projection),
          } of String => JSON::Any)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # Finds the live documents whose `links` column contains the target
      # URN — the inverse of `get_links`. Delegates to `Document::Backrefs`,
      # which owns the contract: the target read gate runs first (missing
      # or invisible → non-disclosing NotFound; no read grant on the
      # doctype at all → RbacDenied — the same split as get_links); the
      # referrer side skips doctypes the caller cannot read and AND-composes
      # each readable doctype's list scope clauses, so a referrer row can
      # never leak past the caller's list visibility. Matched on the exact
      # URN string — a `?state=`-pinned link is a distinct URN. `capped`
      # reports honestly when the result set reaches the
      # `mcp.max_result_rows` cap.
      private def self.get_backrefs(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")

        result = Document::Backrefs.call(
          ctx.db, ctx.auth_context, domain, doctype, doc_id,
          limit: Facet::Config.instance.mcp.max_result_rows,
        )
        case result
        in Document::Backrefs::Result
          JSON::Any.new({
            "data" => JSON::Any.new(result.items.map { |item| backref_json(item) }),
            "meta" => JSON::Any.new({
              "target" => JSON::Any.new(result.target_urn),
              "total"  => JSON::Any.new(result.items.size.to_i64),
              "capped" => JSON::Any.new(result.capped),
            } of String => JSON::Any),
          })
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}##{doc_id}")
        end
      end

      # Maps one service item to the stub-row shape the tool contract
      # carries (`display_name` null when the doctype declares no template).
      private def self.backref_json(item : Document::Backrefs::Item) : JSON::Any
        JSON::Any.new({
          "id"           => JSON::Any.new(item.id),
          "domain"       => JSON::Any.new(item.domain),
          "doc_type"     => JSON::Any.new(item.doc_type),
          "display_name" => item.display_name.nil? ? JSON::Any.new(nil) : JSON::Any.new(item.display_name),
        } of String => JSON::Any)
      end

      # ── Argument parsing ────────────────────────────────────────────────

      private def self.filters_arg(args : JSON::Any) : Hash(String, JSON::Any)
        raw = args.as_h?.try(&.["filters"]?)
        return {} of String => JSON::Any if raw.nil? || raw.raw.nil?
        obj = raw.as_h?
        raise InvalidParams.new("Argument 'filters' must be an object", data: AgentTools.invalid_params_data("filters")) unless obj
        obj
      end

      private def self.sort_arg(args : JSON::Any) : Array(String)
        raw = args.as_h?.try(&.["sort"]?)
        return ["-emitted_at"] if raw.nil? || raw.raw.nil?
        arr = raw.as_a?
        raise InvalidParams.new("Argument 'sort' must be an array of field names", data: AgentTools.invalid_params_data("sort")) unless arr
        fields = arr.map do |v|
          s = v.as_s?
          raise InvalidParams.new("Argument 'sort' must contain only strings", data: AgentTools.invalid_params_data("sort")) unless s
          s
        end
        return ["-emitted_at"] if fields.empty?
        fields
      end

      private def self.page_arg(args : JSON::Any) : Int32
        raw = args.as_h?.try(&.["page"]?)
        return 1 if raw.nil? || raw.raw.nil?
        n = Read.int_value(raw)
        raise InvalidParams.new("Argument 'page' must be a positive integer", data: AgentTools.invalid_params_data("page")) unless n && n >= 1
        n
      end

      # Clamps `items` to `mcp.max_result_rows` so a single call cannot pull
      # more rows than the governance cap allows.
      private def self.items_arg(args : JSON::Any) : Int32
        raw = args.as_h?.try(&.["items"]?)
        cap = Facet::Config.instance.mcp.max_result_rows
        return cap if raw.nil? || raw.raw.nil?
        n = Read.int_value(raw)
        raise InvalidParams.new("Argument 'items' must be a positive integer", data: AgentTools.invalid_params_data("items")) unless n && n >= 1
        Math.min(n, cap)
      end

      # Validates filter keys against `Audit::List`'s accepted column set
      # and the operators its column builder serves per column. The service
      # answers `422` for unknown fields and unsupported operators; the
      # agent surfaces reject them up front so an agent typo surfaces
      # immediately.
      private def self.validate_filter_keys(filters : Hash(String, JSON::Any)) : Nil
        return if filters.empty?
        filters.each do |key, _value|
          field, op = Util::FilterSet.parse_filter_key(key)

          unless KNOWN_FILTER_FIELDS.includes?(field)
            raise InvalidParams.new("Unknown filter field '#{field}' (valid: #{KNOWN_FILTER_FIELDS.join(", ")})",
              data: JSON.parse(%({"reason": "unknown_field", "field": #{field.to_json}})))
          end

          supported = field == "emitted_at" ? EMITTED_AT_OPERATORS : EQUALITY_OPERATORS
          next if supported.includes?(op)

          raise InvalidParams.new(
            "Filter operator '#{op}' is not supported for field '#{field}' " \
            "(supported: #{supported.to_a.sort.join(", ")})",
            data: JSON.parse(%({"reason": "unsupported_operator", "field": #{field.to_json}, "operator": #{op.to_json}})),
          )
        end
      end

      # ── Serialization ───────────────────────────────────────────────────

      private def self.mutation_json(m : Facet::Audit::List::MutationRecord) : JSON::Any
        h = {
          "id"          => JSON::Any.new(m.id),
          "doc_id"      => JSON::Any.new(m.doc_id),
          "idx"         => JSON::Any.new(m.idx.to_i64),
          "action"      => JSON::Any.new(m.action),
          "actioner_id" => JSON::Any.new(m.actioner_id),
          "arguments"   => m.arguments,
          "redacted"    => JSON::Any.new(m.redacted.map { |path| JSON::Any.new(path.map { |seg| JSON::Any.new(seg) }) }),
          "channel"     => JSON::Any.new(m.channel),
          "cause_kind"  => JSON::Any.new(m.cause_kind),
          "cause_trace" => JSON::Any.new(m.cause_trace),
          "emitted_at"  => JSON::Any.new(m.emitted_at.to_rfc3339),
          "domain"      => JSON::Any.new(m.domain),
          "doc_type"    => JSON::Any.new(m.doc_type),
        } of String => JSON::Any
        h["app"] = JSON::Any.new(m.app) if m.app
        h["api_key"] = JSON::Any.new(m.api_key) if m.api_key
        h["acting_role"] = JSON::Any.new(m.acting_role) if m.acting_role
        h["cause_name"] = JSON::Any.new(m.cause_name) if m.cause_name
        h["cause_event"] = JSON::Any.new(m.cause_event) if m.cause_event
        h["cause_source"] = JSON::Any.new(m.cause_source) if m.cause_source
        h["cause_parent"] = JSON::Any.new(m.cause_parent) if m.cause_parent
        JSON::Any.new(h)
      end
    end
  end
end
