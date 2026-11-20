# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "../doctype/definition_store"
require "../document/list"
require "../document/read"
require "../document/resolve"
require "../rbac/read_enforcer"
require "../agent_tools"
require "./errors"
require "./caps"
require "./discover"

module Facet
  module AgentTools
    # Read tool group: document queries for an external agent.
    #
    # - `list_documents` — a filtered, sorted, paginated list through
    #   `Document::List`. Filters use the REST `field__op` grammar (plan
    #   D2); keys are validated against the doctype definition first so an
    #   unknown field raises `InvalidParams` instead of the service's
    #   silent drop.
    # - `get_document` — one document through `Document::Read`. No read
    #   grant on the doctype at all surfaces as `RbacDenied`; a grant
    #   holder who cannot see the document surfaces as `NotFound`
    #   (non-disclosing, same as REST 404); a tombstone surfaces as
    #   `NotFound` with a "deleted" note.
    #
    # Governance caps: `items` is clamped to `mcp.max_result_rows` and the
    # serialized result is checked against `mcp.max_response_bytes` — an
    # oversized result sets `meta.truncated` and carries a `next_cursor`
    # (the next page number) instead of failing.
    #
    # `aggregate_documents` runs one aggregate over the same filter
    # grammar: `count`, or `sum` / `avg` / `min` / `max` over a top-level
    # `integer`, `duration`, or `money` field. Both read tools accept an
    # optional `parent_id` to scope the call to one parent's children —
    # the same gate as the REST nested route: only a child doctype (one
    # with `member_of`) accepts it, and the parent must be readable by the
    # caller (`ReadEnforcer.parent_authorized?`) — a missing parent, or
    # one the caller cannot see, surfaces as the non-disclosing
    # `NotFound`, while a caller with no read grant on the parent doctype
    # at all gets `RbacDenied`. `Document::List`
    # keeps the row cap on `count`, the RBAC scope clauses, and the
    # field-visibility 403; the tool only parses arguments and renders the
    # envelope.
    module Read
      # Filter keys outside the doctype's field set that `Document::List`
      # accepts. Mirrors `Document::List::SYSTEM_TIMESTAMP_FIELDS`.
      SYSTEM_FILTER_FIELDS = ["search", "id", "created_at", "updated_at"]

      # Per-doctype match cap for `search_documents` — a wide fan-out must
      # not multiply the row cap by the doctype count.
      SEARCH_PER_DOCTYPE_CAP = 5

      def self.entries : Array(Registry::Entry)
        [
          Registry::Entry.new(
            name: "list_documents",
            description: "List documents of one doctype. Filters use the REST grammar: keys like 'salary__gte' or plain 'status' (equality). Per-field operator sets: typed scalars and text take eq, ne, match, starts_with, gt, gte, lt, lte, between, in (an array of values, max 100); system id takes eq, ne, match, gt, gte, lt, lte, between, in; created_at/updated_at take eq, ne, gt, gte, lt, lte, between; period/dateperiod take eq, contains, overlaps, within; money takes eq, gt, gte, lt, lte, between, currency; arrays take eq, contains, overlaps; references take eq, ne. An unsupported operator raises an error — it never silently matches nothing. Special keys: 'search' (substring match over the accent-folded search corpus — the doctype's search template; a doctype that declares no template matches nothing; bare key only — a suffixed form raises), 'id', 'created_at', 'updated_at'. Sort with fields like '-created_at'. Pass parent_id to list only the children of one parent document (child doctypes only; a missing or invisible parent raises NotFound, no read grant on its doctype raises RbacDenied). Each row is {data, meta} and meta.display_name carries the row's computed human label — null when the doctype declares no display_name template (then fall back to the first non-empty of the name/title/label content fields). Returns {data, meta} where meta carries total (on a truncated page: the rows returned — truncated=true + next_cursor means fetch the next page with page=next_cursor; on the final page: the exact count of matching rows from this page onward, i.e. the full match count when page=1), page, and the truncation info. aggregate_documents with aggregate='count' returns the capped overall match count.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":    {"type": "string"},
                "doctype":   {"type": "string"},
                "filters":   {"type": "object", "description": "Filter keys with optional __op suffix: field, field__eq, field__ne, field__match, field__starts_with, field__gt, field__gte, field__lt, field__lte, field__between"},
                "parent_id": {"type": "string", "description": "Parent document id — list only its children (child doctypes with member_of only)"},
                "sort":      {"type": "array", "items": {"type": "string"}, "description": "Field names, '-' prefix for descending"},
                "page":      {"type": "integer", "minimum": 1},
                "items":     {"type": "integer", "minimum": 1},
                "expand":    {"type": "array", "items": {"type": "string"}, "description": "Reference field names to resolve — adds a 'resolved' map (urn -> {id, domain, doc_type, display_name, data}) next to data. Depth 1."},
                "fields":    {"type": "array", "items": {"type": "string"}, "description": "Field names to project each document's content to (unknown names raise)"},
                "scope":     {"type": "string", "description": "A named scope from get_schema's 'scopes' map, applied as a query filter (e.g. 'mine' for my rows)"}
              },
              "required": ["domain", "doctype"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { list_documents(ctx, args) },
          ),
          Registry::Entry.new(
            name: "aggregate_documents",
            description: "Aggregate documents of one doctype with the same filter grammar as list_documents. 'count' returns the number of matching documents; 'sum', 'avg', 'min', 'max' run over one top-level integer, duration, or money field ('field', required except for count; money returns {currency: amount} per currency). Pass parent_id to aggregate over one parent's children only (child doctypes only). RBAC scope and field visibility apply.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":    {"type": "string"},
                "doctype":   {"type": "string"},
                "aggregate": {"type": "string", "enum": ["count", "sum", "avg", "min", "max"], "description": "Aggregate kind. 'count' needs no field; the others require 'field'."},
                "field":     {"type": "string", "description": "Top-level integer, duration, or money field to aggregate (required except for count)."},
                "filters":   {"type": "object", "description": "Filter keys with optional __op suffix: field, field__eq, field__ne, field__match, field__starts_with, field__gt, field__gte, field__lt, field__lte, field__between"},
                "parent_id": {"type": "string", "description": "Parent document id — aggregate over its children only (child doctypes with member_of only)"},
                "scope":     {"type": "string", "description": "A named scope from get_schema's 'scopes' map, applied as a query filter"}
              },
              "required": ["domain", "doctype", "aggregate"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { aggregate_documents(ctx, args) },
          ),
          Registry::Entry.new(
            name: "get_document",
            description: "Read one document by id. Returns {data, meta} with the document content and system metadata; meta.display_name carries the computed human label (null when the doctype declares no display_name template — fall back to the name/title/label content fields). Pass 'expand' (reference field names) to get a 'resolved' map next to data with the referenced documents. Pass 'fields' to project the content to the named fields. A deleted document or one outside the role's scope returns NotFound.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "domain":  {"type": "string"},
                "doctype": {"type": "string"},
                "doc_id":  {"type": "string"},
                "expand":  {"type": "array", "items": {"type": "string"}, "description": "Reference field names to resolve — adds a 'resolved' map (urn -> {id, domain, doc_type, display_name, data}) next to data. Depth 1."},
                "fields":  {"type": "array", "items": {"type": "string"}, "description": "Field names to project the content to (unknown names raise)"}
              },
              "required": ["domain", "doctype", "doc_id"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { get_document(ctx, args) },
          ),
          Registry::Entry.new(
            name: "resolve_refs",
            description: "Resolve a batch of document URNs (urn:facet:domain:Doctype:id — the inline links of longtext fields, links entries, or reference values) to documents in one call. Returns {data, meta}: one stub row per found document ({data: content, meta: {id, domain, doc_type, display_name, ...}}), tombstoned / denied / unknown URNs omitted (non-disclosing). Pass 'fields' to project each resolved content to the named fields. The list is capped at max_result_rows — a longer list raises.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "refs":   {"type": "array", "items": {"type": "string"}, "description": "Document URNs to resolve"},
                "fields": {"type": "array", "items": {"type": "string"}, "description": "Field names to project each resolved content to (unknown names raise)"}
              },
              "required": ["refs"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { resolve_refs(ctx, args) },
          ),
          Registry::Entry.new(
            name: "search_documents",
            description: "Search every readable doctype at once — use it when you do not know where a document lives. Pass 'query' (substring over the accent-folded search corpus — doctypes that declare no search template match nothing); optional 'domain' narrows to one domain, optional 'items' caps the per-doctype matches (max 5). Returns {data, meta}: one stub row per match ({domain, doc_type, id, display_name}, grouped per doctype), capped by max_result_rows. Follow up with list_documents/get_document on the doctype you found.",
            input_schema: JSON.parse(%({
              "type": "object",
              "properties": {
                "query":  {"type": "string", "description": "Search term (substring, accent-insensitive)"},
                "domain": {"type": "string", "description": "Optional domain — all live domains when omitted"},
                "items":  {"type": "integer", "minimum": 1, "description": "Per-doctype match cap (max 5)"}
              },
              "required": ["query"]
            })),
            requires: :read,
            handler: ->(ctx : Registry::Context, args : JSON::Any) { search_documents(ctx, args) },
          ),
        ]
      end

      # ── Handlers ────────────────────────────────────────────────────────

      private def self.list_documents(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        filters = filters_arg(args)
        sort = sort_arg(args)
        page = page_arg(args)
        items = items_arg(args)
        parent_id = optional_string_arg(args, "parent_id")
        expand = expand_arg(args)
        fields = fields_arg(args)
        scope = optional_string_arg(args, "scope")

        guard_parent_scope(ctx, domain, doctype, parent_id)
        validate_filter_keys(ctx, domain, doctype, filters)
        definition = validate_expand_fields!(ctx, domain, doctype, expand)
        defn = definition || fetch_definition!(ctx, domain, doctype)
        validate_field_projection!(defn, fields)
        validate_scope_name!(defn, scope)

        result = Document::List.call(
          ctx.db, domain, doctype,
          filters: filters, sort: sort, page: page, items_per_page: items,
          auth_context: ctx.auth_context, parent_id: parent_id, named_scope: scope,
        )
        case result
        in Document::List::Result
          # The service caps its count at `items + 1` past the page offset;
          # reaching the cap means at least one more page exists.
          list_result_payload(result, page, result.total > items,
            resolved: resolved_map(ctx, result.items, expand, definition),
            row_urns: row_urns(result.items, expand, definition),
            fields: fields,
          )
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}")
        in Document::List::AggregateResult
          # Unreachable: list_documents never requests an aggregate. The
          # union member exists because `Document::List.call` can return one.
          raise "list_documents never receives an aggregate result"
        end
      end

      private def self.aggregate_documents(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        aggregate = Discover.string_arg(args, "aggregate")
        field = optional_string_arg(args, "field")
        filters = filters_arg(args)
        parent_id = optional_string_arg(args, "parent_id")
        scope = optional_string_arg(args, "scope")

        guard_parent_scope(ctx, domain, doctype, parent_id)
        validate_filter_keys(ctx, domain, doctype, filters)
        validate_scope_name!(fetch_definition!(ctx, domain, doctype), scope)

        result = Document::List.call(
          ctx.db, domain, doctype,
          filters: filters, auth_context: ctx.auth_context,
          aggregate: aggregate, field: field, parent_id: parent_id, named_scope: scope,
        )
        case result
        in Document::List::AggregateResult
          aggregate_result_payload(aggregate, field, result)
        in Document::List::Result
          # Count mode: the service returns an empty items array with the
          # capped-at-1000 total — same envelope as a list page. No paging
          # signal: the count is the inclusive upper bound, not a page.
          list_result_payload(result, 1, has_more: false)
        in Facet::ServiceError
          raise AgentTools.service_error(result, context: "#{domain}.#{doctype}")
        end
      end

      private def self.get_document(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        domain = Discover.string_arg(args, "domain")
        doctype = Discover.string_arg(args, "doctype")
        doc_id = Discover.string_arg(args, "doc_id")
        expand = expand_arg(args)
        fields = fields_arg(args)

        result = Document::Read.call(ctx.db, domain, doctype, doc_id, ctx.auth_context)
        case result
        in Document::Read::Result
          definition = validate_expand_fields!(ctx, domain, doctype, expand)
          validate_field_projection!(Doctype::DefinitionStore.fetch(ctx.db, "#{domain}.#{doctype}"), fields)
          payload = {
            "data" => projected_content(result.projection.content, fields),
            "meta" => projection_meta(result.projection),
          } of String => JSON::Any
          if resolved = resolved_map(ctx, [result.projection], expand, definition)
            payload["resolved"] = JSON::Any.new(resolved)
          end
          JSON::Any.new(payload)
        in Facet::ServiceError
          # 403 — no read grant on the doctype at all. A grant holder that
          # cannot see the document (404) and a tombstone (410) surface as
          # NotFound; the tombstone adds a "deleted" note so the agent can
          # tell the two apart.
          raise RbacDenied.new if result.status == 403
          if result.status == 410
            raise NotFound.new("Document #{domain}.#{doctype}##{doc_id} not found (deleted)",
              data: JSON.parse(%({"reason": "not_found", "deleted": true})))
          end
          raise NotFound.new("Document #{domain}.#{doctype}##{doc_id} not found",
            data: JSON.parse(%({"reason": "not_found"})))
        end
      end

      # Resolves a caller-supplied batch of URNs through Document::Resolve
      # and renders the list_documents envelope: one stub row per found
      # document, capped input and capped output. Denied, tombstoned, and
      # unknown URNs are omitted — the same non-disclosure as a single
      # read — so `meta.items` can be smaller than the requested batch.
      private def self.resolve_refs(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        refs = string_array_arg(args, "refs")
        fields = fields_arg(args)

        cap = Facet::Config.instance.mcp.max_result_rows
        if refs.size > cap
          raise Capped.new(
            "Argument 'refs' holds #{refs.size} entries — the cap is #{cap}; page the list and retry",
            cap,
          )
        end

        # Validate the field projection against every doctype the batch
        # touches — a name must be declared on all of them (the projection
        # applies per row; a cross-doctype batch with mismatched schemas
        # is a caller error).
        resolved = Document::Resolve.call(ctx.db, refs, ctx.auth_context)
        unless fields.empty?
          resolved.each_value do |proj|
            definition = Doctype::DefinitionStore.fetch(ctx.db, "#{proj.domain}.#{proj.doc_type}")
            validate_field_projection!(definition, fields)
          end
        end

        items = resolved.values.sort_by!(&.id).map do |proj|
          JSON::Any.new({
            "data" => projected_content(proj.content, fields),
            "meta" => projection_meta(proj),
          } of String => JSON::Any)
        end
        payload = {
          "data" => JSON::Any.new(items),
          "meta" => JSON::Any.new({
            "total"       => JSON::Any.new(items.size.to_i64),
            "page"        => JSON::Any.new(1.to_i64),
            "items"       => JSON::Any.new(items.size.to_i64),
            "truncated"   => JSON::Any.new(false),
            "next_cursor" => JSON::Any.new(nil),
          } of String => JSON::Any),
        } of String => JSON::Any
        JSON::Any.new(AgentTools::Caps.apply_response_caps(payload, 1))
      end

      # Searches every readable doctype at once with the bare `search`
      # filter — the fan-out form of `list_documents`. Per doctype: one
      # `Document::List.call` with `filters: {search: query}`; the RBAC
      # scope clauses inside the service make denied doctypes contribute
      # nothing, but unreadable doctypes are skipped outright to save the
      # round trips. Stub rows (`{domain, doc_type, id, display_name}`)
      # group per doctype; the total is bounded by `max_result_rows` and
      # the serialized payload by `max_response_bytes`.
      private def self.search_documents(ctx : Registry::Context, args : JSON::Any) : JSON::Any
        query = Discover.string_arg(args, "query")
        domain_filter = optional_string_arg(args, "domain")
        items = items_arg(args)

        per_doctype = Math.min(items, SEARCH_PER_DOCTYPE_CAP)
        cap = Facet::Config.instance.mcp.max_result_rows

        items_json = [] of JSON::Any
        Read.readable_doctypes(ctx.db, ctx.auth_context).each do |(dt_domain, dt_doctype)|
          next if domain_filter && dt_domain != domain_filter
          break if items_json.size >= cap

          result = Document::List.call(
            ctx.db, dt_domain, dt_doctype,
            filters: {"search" => JSON::Any.new(query)} of String => JSON::Any,
            page: 1, items_per_page: per_doctype,
            auth_context: ctx.auth_context,
          )
          next unless result.is_a?(Document::List::Result)

          result.items.each do |proj|
            break if items_json.size >= cap
            h = {
              "domain"   => JSON::Any.new(proj.domain),
              "doc_type" => JSON::Any.new(proj.doc_type),
              "id"       => JSON::Any.new(proj.id),
              # Always present — null when the doctype declares no template.
              "display_name" => proj.display_name ? JSON::Any.new(proj.display_name) : JSON::Any.new(nil),
            } of String => JSON::Any
            items_json << JSON::Any.new(h)
          end
        end

        payload = {
          "data" => JSON::Any.new(items_json),
          "meta" => JSON::Any.new({
            "query"  => JSON::Any.new(query),
            "total"  => JSON::Any.new(items_json.size.to_i64),
            "domain" => domain_filter ? JSON::Any.new(domain_filter) : JSON::Any.new(nil),
          } of String => JSON::Any),
        } of String => JSON::Any
        JSON::Any.new(AgentTools::Caps.apply_response_caps(payload, 1))
      end

      # ── Parent scope ────────────────────────────────────────────────

      # Fetches a doctype definition or raises a non-disclosing `NotFound`.
      # Shared by the read tools and the write tools' parent gate.
      def self.fetch_definition!(ctx : Registry::Context, domain : String, doctype : String) : Doctype::DoctypeDefinition
        Doctype::DefinitionStore.fetch(ctx.db, "#{domain}.#{doctype}") ||
          raise NotFound.new("Unknown doctype: #{domain}.#{doctype}", data: JSON.parse(%({"reason": "not_found"})))
      end

      # Runs the nested REST route's parent read gate: a missing or denied
      # parent is one non-disclosing outcome. Shared by the read tools and
      # the write tools' parent gate.
      def self.ensure_parent_readable!(
        ctx : Registry::Context,
        domain : String,
        member_of : String,
        parent_id : String,
      ) : Nil
        # The parent gate mirrors the REST nested route: a caller with no
        # read grant on the parent doctype at all answers `RbacDenied`; a
        # missing parent — or one the caller cannot see — surfaces as the
        # non-disclosing `NotFound`.
        if RBAC::ReadEnforcer.read_denied?(domain, member_of, ctx.auth_context)
          raise RbacDenied.new
        end
        unless RBAC::ReadEnforcer.parent_authorized?(ctx.db, domain, member_of, parent_id, ctx.auth_context)
          raise NotFound.new("Parent document #{domain}.#{member_of}##{parent_id} is not available",
            data: JSON.parse(%({"reason": "not_found"})))
        end
      end

      # Runs the REST nested-route parent gate for a parent-scoped read:
      # only a child doctype (one declaring `member_of`) accepts `parent_id`,
      # and the parent document must exist, be live, and be readable by the
      # caller. A missing or denied parent and a doctype without `member_of`
      # all fail here, before the list service runs.
      def self.guard_parent_scope(
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        parent_id : String?,
      ) : Nil
        return if parent_id.nil?

        definition = fetch_definition!(ctx, domain, doctype)
        member_of = definition.member_of
        unless member_of
          raise InvalidParams.new("Argument 'parent_id' needs a child doctype — #{domain}.#{doctype} declares no member_of",
            data: AgentTools.invalid_params_data("parent_id"))
        end

        ensure_parent_readable!(ctx, domain, member_of, parent_id)
      end

      # ── readable-doctype enumeration ──────────────────────────

      # Shared by the cross-doctype read tools (`get_backrefs`,
      # `search_documents`). Delegates to the RBAC enumeration — the
      # implementation lives with the rest of the read-side gates.
      def self.readable_doctypes(db : DB::Connection, auth_context : RBAC::AuthContext) : Array({String, String})
        RBAC::ReadEnforcer.readable_doctypes(db, auth_context)
      end

      # ── Argument parsing ──────────────────────────────────────

      # Parses the optional `expand` argument: an array of reference field
      # names. A non-array or non-string entry raises `InvalidParams`.
      private def self.expand_arg(args : JSON::Any) : Array(String)
        string_array_arg(args, "expand")
      end

      # Parses the optional `fields` argument: an array of field names.
      private def self.fields_arg(args : JSON::Any) : Array(String)
        string_array_arg(args, "fields")
      end

      private def self.string_array_arg(args : JSON::Any, key : String) : Array(String)
        raw = args.as_h?.try(&.[key]?)
        return [] of String if raw.nil? || raw.raw.nil?
        arr = raw.as_a?
        raise InvalidParams.new("Argument '#{key}' must be an array of strings", data: AgentTools.invalid_params_data(key)) unless arr
        arr.map do |v|
          s = v.as_s?
          raise InvalidParams.new("Argument '#{key}' must contain only strings", data: AgentTools.invalid_params_data(key)) unless s
          s
        end
      end

      # ── expand: reference resolution ──────────────────────────

      # Validates every `expand` entry as a declared `reference` field on
      # the doctype and returns the definition (nil when nothing to
      # expand — no definition fetch for the common no-expand path).
      private def self.validate_expand_fields!(
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        expand : Array(String),
      ) : Doctype::DoctypeDefinition?
        return nil if expand.empty?

        definition = fetch_definition!(ctx, domain, doctype)
        expand.each do |name|
          field = definition.fields[name]?
          unless field && field.reference?
            raise InvalidParams.new(
              "Argument 'expand' entry '#{name}' is not a declared reference field on #{domain}.#{doctype}",
              data: AgentTools.invalid_params_data("expand"),
            )
          end
        end
        definition
      end

      # Collects the distinct target URNs the expand fields point at, over
      # the page's rows. Reference values are stored qualified
      # (`{domain}.{Doctype}.{id}`) but callers may hold bare ids —
      # `DocURI.from_projection_id` canonicalizes both forms.
      private def self.row_urns(
        items : Array(Mutation::Client::Projection),
        expand : Array(String),
        definition : Doctype::DoctypeDefinition?,
      ) : Array(Array(String))
        return items.map { [] of String } if expand.empty? || definition.nil?

        items.map do |proj|
          urns = [] of String
          content = proj.content.as_h?
          if content
            expand.each do |name|
              field = definition.fields[name]
              target = field.qualified_doctype
              next if target.nil?
              parts = target.split('.', 2)
              next unless parts.size == 2
              append_reference_urns(urns, content[name]?, parts[0], parts[1])
            end
          end
          urns.uniq!
          urns
        end
      end

      # Appends the canonical URN(s) for a reference field value — a single
      # string, or an array when the field is `collection: true`.
      private def self.append_reference_urns(urns : Array(String), value : JSON::Any?, domain : String, doctype : String) : Nil
        return if value.nil?
        case raw = value.raw
        when String
          append_urn(urns, raw, domain, doctype)
        when Array
          raw.each do |el|
            append_urn(urns, el.to_s, domain, doctype) if el.raw.is_a?(String)
          end
        end
      end

      private def self.append_urn(urns : Array(String), value : String, domain : String, doctype : String) : Nil
        return if value.empty?
        uri = Document::DocURI.from_projection_id(domain, doctype, value)
        urns << uri.to_s if uri.valid?
      end

      # Resolves the collected URNs through `Document::Resolve` and builds
      # the `resolved` side map (D1): rows keep their bare ids; each URN
      # maps to `{id, domain, doc_type, display_name, data}`. Returns nil
      # when there is nothing to resolve — the key stays off the payload.
      # Denied and tombstoned targets are absent (non-disclosing).
      private def self.resolved_map(
        ctx : Registry::Context,
        items : Array(Mutation::Client::Projection),
        expand : Array(String),
        definition : Doctype::DoctypeDefinition?,
      ) : Hash(String, JSON::Any)?
        return nil if expand.empty? || definition.nil?

        urns = row_urns(items, expand, definition).flatten.uniq!
        return nil if urns.empty?

        resolved = {} of String => JSON::Any
        Document::Resolve.call(ctx.db, urns, ctx.auth_context).each do |urn, proj|
          entry = {
            "id"           => JSON::Any.new(proj.id),
            "domain"       => JSON::Any.new(proj.domain),
            "doc_type"     => JSON::Any.new(proj.doc_type),
            "display_name" => proj.display_name ? JSON::Any.new(proj.display_name) : JSON::Any.new(nil),
            "data"         => proj.content,
          } of String => JSON::Any
          resolved[urn] = JSON::Any.new(entry)
        end
        resolved
      end

      # ── scope: query-time named scope ─────────────────────────

      # Validates the optional `scope` argument against the doctype's
      # declared scopes (unknown → `InvalidParams`). A single name (D6).
      private def self.validate_scope_name!(definition : Doctype::DoctypeDefinition, scope : String?) : Nil
        return if scope.nil?
        return if definition.scopes.has_key?(scope)

        declared = definition.scopes.keys.sort!.join(", ")
        raise InvalidParams.new(
          "Unknown scope '#{scope}' on #{definition.domain}.#{definition.doctype} (declared: #{declared})",
          data: AgentTools.invalid_params_data("scope"),
        )
      end

      # ── fields: content projection ────────────────────────────

      # Validates every `fields` entry against the doctype definition
      # (unknown raises `InvalidParams`). System meta is untouched.
      private def self.validate_field_projection!(
        definition : Doctype::DoctypeDefinition?,
        fields : Array(String),
      ) : Nil
        return if fields.empty?
        return if definition.nil?

        fields.each do |name|
          unless definition.fields.has_key?(name)
            raise InvalidParams.new(
              "Argument 'fields' entry '#{name}' is not a declared field on #{definition.domain}.#{definition.doctype}",
              data: AgentTools.invalid_params_data("fields"),
            )
          end
        end
      end

      # Projects a document's content to the named fields. Applied after
      # the read mask, so a masked field never reappears; an empty `fields`
      # list is a no-op. A nil definition (never validated) keeps content
      # as-is — the caller validated against a definition when one existed.
      private def self.projected_content(content : JSON::Any, fields : Array(String)) : JSON::Any
        return content if fields.empty?
        h = content.as_h?
        return content if h.nil?

        JSON::Any.new(fields.each_with_object({} of String => JSON::Any) do |name, acc|
          acc[name] = h[name] if h.has_key?(name)
        end)
      end

      private def self.filters_arg(args : JSON::Any) : Hash(String, JSON::Any)
        raw = args.as_h?.try(&.["filters"]?)
        return {} of String => JSON::Any if raw.nil? || raw.raw.nil?
        obj = raw.as_h?
        raise InvalidParams.new("Argument 'filters' must be an object", data: AgentTools.invalid_params_data("filters")) unless obj
        obj
      end

      # Reads an optional string argument. JSON null counts as absent; a
      # present non-string raises `InvalidParams` naming the argument.
      # Shared with the write tools (`create_document` parent_id).
      def self.optional_string_arg(args : JSON::Any, key : String) : String?
        raw = args.as_h?.try(&.[key]?)
        return nil if raw.nil? || raw.raw.nil?
        str = raw.as_s?
        raise InvalidParams.new("Argument '#{key}' must be a string", data: AgentTools.invalid_params_data(key)) unless str
        str
      end

      private def self.sort_arg(args : JSON::Any) : Array(String)
        raw = args.as_h?.try(&.["sort"]?)
        return ["id"] if raw.nil? || raw.raw.nil?
        arr = raw.as_a?
        raise InvalidParams.new("Argument 'sort' must be an array of field names", data: AgentTools.invalid_params_data("sort")) unless arr
        fields = arr.map do |v|
          s = v.as_s?
          raise InvalidParams.new("Argument 'sort' must contain only strings", data: AgentTools.invalid_params_data("sort")) unless s
          s
        end
        return ["id"] if fields.empty?
        fields
      end

      # Parses the `page` argument. Shared with the sidecar tools.
      def self.page_arg(args : JSON::Any) : Int32
        raw = args.as_h?.try(&.["page"]?)
        return 1 if raw.nil? || raw.raw.nil?
        n = int_value(raw)
        raise InvalidParams.new("Argument 'page' must be a positive integer", data: AgentTools.invalid_params_data("page")) unless n && n >= 1
        n
      end

      # Clamps `items` to `mcp.max_result_rows` so a single call can never
      # pull more rows than the governance cap allows. Shared with the
      # sidecar tools.
      def self.items_arg(args : JSON::Any) : Int32
        raw = args.as_h?.try(&.["items"]?)
        cap = Facet::Config.instance.mcp.max_result_rows
        return cap if raw.nil? || raw.raw.nil?
        n = int_value(raw)
        raise InvalidParams.new("Argument 'items' must be a positive integer", data: AgentTools.invalid_params_data("items")) unless n && n >= 1
        Math.min(n, cap)
      end

      def self.int_value(raw : JSON::Any) : Int32?
        case v = raw.raw
        when Int64
          i = v.to_i32
          i == v ? i : nil
        when Float64
          i = v.to_i32
          i == v ? i : nil
        when String
          v.to_i32?
        else
          nil
        end
      end

      # Validates filter keys against the doctype definition before the
      # service call. `Document::List` silently drops unknown fields and
      # compiles unservable operators to `FALSE` (or drops a wrong operator
      # on a range field) — both read as an empty page to an agent, so the
      # agent surface rejects them here: the field must be known, and the
      # operator suffix must be one the grammar serves for that field
      # (`Document::FilterCompiler.allowed_operators` — the same routing the
      # compiler itself uses). `search` is bare-key-only: every suffixed form
      # raises.
      private def self.validate_filter_keys(
        ctx : Registry::Context,
        domain : String,
        doctype : String,
        filters : Hash(String, JSON::Any),
      ) : Nil
        return if filters.empty?

        definition = Doctype::DefinitionStore.fetch(ctx.db, "#{domain}.#{doctype}")
        raise NotFound.new("Unknown doctype: #{domain}.#{doctype}", data: JSON.parse(%({"reason": "not_found"}))) unless definition

        filters.each do |key, value|
          field, op = Util::FilterSet.parse_filter_key(key)

          # `in` is bounded — an over-long array fails loud on the agent
          # surface (the service degrades to FALSE as the REST backstop).
          if op == "in" && (arr = value.as_a?) && arr.size > Util::FilterSet::MAX_IN_VALUES
            raise InvalidParams.new(
              "Filter '#{key}' accepts at most #{Util::FilterSet::MAX_IN_VALUES} values (got #{arr.size})",
              data: JSON.parse(%({"reason": "invalid_params", "argument": #{key.to_json}})),
            )
          end

          # `search` is an operator-keyword, not a column: only the bare key
          # is a production of the grammar — every suffixed form compiles to
          # `FALSE`, so it raises here instead.
          if field == "search"
            if key.includes?("__")
              raise InvalidParams.new(
                "Filter 'search' takes no operator suffix (got '#{key}') — pass the bare key",
                data: JSON.parse(%({"reason": "unsupported_operator", "field": "search", "operator": #{op.to_json}})),
              )
            end
            next
          end

          unless SYSTEM_FILTER_FIELDS.includes?(field) || definition.fields.has_key?(field)
            raise InvalidParams.new("Unknown filter field '#{field}' on #{domain}.#{doctype}",
              data: JSON.parse(%({"reason": "unknown_field", "field": #{field.to_json}})))
          end

          allowed = Document::FilterCompiler.allowed_operators(definition, field)
          next if allowed.nil?
          next if allowed.includes?(op)

          raise InvalidParams.new(
            "Filter operator '#{op}' is not supported for field '#{field}' on #{domain}.#{doctype} " \
            "(supported: #{allowed.to_a.sort.join(", ")})",
            data: JSON.parse(%({"reason": "unsupported_operator", "field": #{field.to_json}, "operator": #{op.to_json}})),
          )
        end
      end

      # ── Serialization ──────────────────────────────────────────────────

      # A list-style `{data, meta}` envelope: `data` holds the page items,
      # `meta` the total, page and truncation markers. Shared by
      # `list_documents`, `list_sidecars`, and the `count` branch of
      # `aggregate_documents`. `mcp.max_response_bytes` applies here.
      #
      # The service's count is capped at `items + 1` rows past the page
      # offset; reaching the cap is the has-more signal (`has_more`), and
      # the extra row is only a probe — it is not a returned row and never
      # reaches `data`. `total` therefore excludes it: on a truncated page
      # it is the rows the page returned; once the cap is not reached it is
      # the exact count of matching rows from this page onward (the full
      # match count when page = 1). The count branch passes
      # `has_more: false`, keeping its inclusive upper-bound total.
      def self.list_result_payload(
        result : Document::List::Result,
        page : Int32,
        has_more : Bool,
        resolved : Hash(String, JSON::Any)? = nil,
        row_urns : Array(Array(String))? = nil,
        fields : Array(String) = [] of String,
      ) : JSON::Any
        total = has_more ? result.items.size.to_i64 : result.total
        payload = {
          "data" => JSON::Any.new(result.items.map { |proj| projection_json(proj, fields) }),
          "meta" => JSON::Any.new({
            "total"       => JSON::Any.new(total),
            "page"        => JSON::Any.new(page.to_i64),
            "items"       => JSON::Any.new(result.items.size.to_i64),
            "truncated"   => JSON::Any.new(has_more),
            "next_cursor" => has_more ? JSON::Any.new((page + 1).to_i64) : JSON::Any.new(nil),
          } of String => JSON::Any),
        } of String => JSON::Any
        payload["resolved"] = JSON::Any.new(resolved) if resolved && !resolved.empty?
        JSON::Any.new(AgentTools::Caps.apply_response_caps(payload, page, row_urns))
      end

      # A field-aggregate envelope: `data` echoes the run (`aggregate`,
      # `field`) and carries the `value` plus the contributing-row `count`
      # from the same statement. `value` is a JSON number or decimal
      # string for integer/duration fields, a `{currency => amount}` bag
      # for money, or JSON null on an empty set — exactly as the service
      # emitted it. `field` is absent for `count`.
      private def self.aggregate_result_payload(aggregate : String, field : String?, result : Document::List::AggregateResult) : JSON::Any
        data = {
          "aggregate" => JSON::Any.new(aggregate),
          "value"     => result.value,
          "count"     => JSON::Any.new(result.count),
        } of String => JSON::Any
        data["field"] = JSON::Any.new(field) if field
        JSON::Any.new({
          "data" => JSON::Any.new(data),
          "meta" => JSON::Any.new({
            "truncated"   => JSON::Any.new(false),
            "next_cursor" => JSON::Any.new(nil),
          } of String => JSON::Any),
        })
      end

      private def self.projection_json(proj : Mutation::Client::Projection, fields : Array(String) = [] of String) : JSON::Any
        JSON::Any.new({
          "data" => projected_content(proj.content, fields),
          "meta" => projection_meta(proj),
        } of String => JSON::Any)
      end

      def self.projection_meta(proj : Mutation::Client::Projection, mutation_id : String? = nil) : JSON::Any
        h = {
          "id"         => JSON::Any.new(proj.id),
          "domain"     => JSON::Any.new(proj.domain),
          "doc_type"   => JSON::Any.new(proj.doc_type),
          "mid"        => JSON::Any.new(mutation_id || proj.state),
          "version"    => JSON::Any.new(proj.version.to_i64),
          "created_at" => JSON::Any.new(proj.created_at.to_rfc3339),
          "updated_at" => JSON::Any.new(proj.updated_at.to_rfc3339),
        } of String => JSON::Any
        # A child document reports its parent link so an agent can walk the
        # composition tree in both directions (same rule as REST meta).
        if pid = proj.meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
          h["parent_id"] = JSON::Any.new(pid)
        end
        # Always present, so an agent can tell the label field exists — null
        # when the doctype declares no display_name template (same shape as
        # the REST document meta).
        h["display_name"] = proj.display_name ? JSON::Any.new(proj.display_name) : JSON::Any.new(nil)
        JSON::Any.new(h)
      end
    end
  end
end
