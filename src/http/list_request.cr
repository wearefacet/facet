# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http"
require "json"
require "../error"
require "../doctype/definition_error"

module Facet
  module HTTP
    # Parses list-request parameters from JSON bodies and query strings.
    #
    # Acceptable shapes (JSON body or query string):
    #
    # ```json
    # {
    #   "page": 1,
    #   "items": 100,
    #   "filters": { "field__eq": 1 },
    #   "sort": ["-created_at", "id"]
    # }
    # ```
    #
    # Query-string equivalent:
    #   /Api/resource?page=1&items=100&filters[field__eq]=1&sort=-created_at,id
    #
    class ListRequest
      MAX_ITEMS     = 1000
      DEFAULT_ITEMS =  100
      DEFAULT_PAGE  =    1

      # Regex that a single sort field must match.
      # - An optional leading `-` indicates descending order.
      # - The remainder must be one or more characters from `[a-z_.]`.
      # An entry outside this shape answers `422` (B-158) — the parser never
      # drops it silently.
      SORT_FIELD_RE = /^-?[a-z_\.]+$/

      # Allowed values for the `aggregate` query parameter. Kept as a
      # constant so the rejection branch in `Document::List` stays in sync
      # with the parser if more aggregates are added later.
      AGGREGATES = Set{"count", "sum", "avg", "min", "max"}

      # The keys the list-parameter grammar knows. Strict admission (the
      # B-169 remainder) rejects any other key with a `422` naming it — a
      # parameter the route does not read must never vanish into a `200`.
      # The query-string form also admits the `filters[field__op]=value`
      # bracket shape; the body carries `filters` as an object. Admission
      # stays lenient by default. A strict route that reads query keys
      # beyond the list contract names them as `extra_query_keys`
      # (`include` on the audit history route, `status` on the
      # webhook-calls route); the body grammar has no extras.
      KNOWN_BODY_KEYS  = Set{"page", "items", "sort", "filters", "select", "aggregate", "field", "scope", "deleted"}
      KNOWN_QUERY_KEYS = Set{"page", "items", "sort", "select", "aggregate", "field", "scope", "deleted"}

      # ── Accessors ──────────────────────────────────────────────────────

      getter page : Int32
      getter items : Int32
      getter filters : Hash(String, JSON::Any)
      getter sort : Array(String)
      getter select : Array(String)?
      getter aggregate : String?
      getter field : String?
      getter scope : String?
      getter? include_deleted : Bool

      # ── Constructor ────────────────────────────────────────────────────

      def initialize(
        @page : Int32 = DEFAULT_PAGE,
        @items : Int32 = DEFAULT_ITEMS,
        @filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        @sort : Array(String) = ["id"],
        @select : Array(String)? = nil,
        @aggregate : String? = nil,
        @field : String? = nil,
        @scope : String? = nil,
        @include_deleted : Bool = false,
      )
        # Constructor invariants. The parse sites answer `422` for a `page`
        # / `items` value below 1 (the B-169 residual) before they get
        # here; these clamps only guard direct `new` callers. The
        # above-`MAX_ITEMS` clamp is the historical behaviour and stays.
        @page = Math.max(1, @page)
        @items = Math.max(1, Math.min(MAX_ITEMS, @items))
      end

      # ── JSON parsing ───────────────────────────────────────────────────

      # Parses a list request from a parsed JSON body. Returns a `422`
      # `Facet::ServiceError` when a present `sort` or `select` value is not
      # an array of strings (B-100), when a `sort` entry sits outside the
      # `SORT_FIELD_RE` shape (B-158), or when a present `page` / `items`
      # value is not an integer (B-169) — the same shape gate the `filters`
      # value holds, so a parseable body can never escape the parser as a
      # 500 from `JSON::Any#as_a` and no wrong-typed value vanishes into
      # the default. A `page` / `items` value below 1 answers `422` too (the
      # B-169 residual): the value is present and well-shaped but out of
      # range, so it is a caller error, not a clamp. With `strict: true` a
      # body key outside the known set answers `422` as well (the B-169
      # remainder). Strict routes that read keys beyond the list contract
      # carry them on the query string and name them as `extra_query_keys`;
      # the body grammar has no extras.
      def self.from_json(json : JSON::Any, strict : Bool = false) : ListRequest | Facet::ServiceError
        if strict
          err = strict_body_error(json)
          return err if err
        end

        pair = page_and_items(json)
        return pair if pair.is_a?(Facet::ServiceError)

        sort = ["id"]
        if sort_value = json["sort"]?
          checked = string_array(sort_value, "sort")
          return checked if checked.is_a?(Facet::ServiceError)
          sort = checked
        end

        filters = {} of String => JSON::Any
        if (filters_obj = json["filters"]?) && filters_obj.raw.is_a?(Hash)
          filters_obj.as_h.each { |k, v| filters[k] = v }
        end

        sel = nil
        if select_value = json["select"]?
          checked = string_array(select_value, "select")
          return checked if checked.is_a?(Facet::ServiceError)
          sel = checked
        end

        agg = parse_aggregate(json["aggregate"]?)
        field = parse_field(json["field"]?)
        scope = parse_optional_string(json["scope"]?)
        deleted = parse_bool_flag(json["deleted"]?)

        validated = validated_sort(sort)
        return validated if validated.is_a?(Facet::ServiceError)
        page, items = pair
        new(page, items, filters, validated, sel, agg, field, scope, deleted)
      end

      # String entry point. Rides the same shape gate as every
      # body-consuming route (B-59/B-80): the body must parse as JSON and
      # be a JSON object — anything else answers a `422` ServiceError the
      # route layer renders, never a 500 from `JSON.parse` (B-160: the
      # document read route parses its optional body here).
      def self.from_json(body : String, strict : Bool = false) : ListRequest | Facet::ServiceError
        parsed = parse_body_object(body)
        return parsed if parsed.is_a?(Facet::ServiceError)
        from_json(parsed, strict)
      end

      # ── HTTP request parsing (body + query merge) ───────────────────

      # Parses and shape-gates the request body (B-59). Returns the parsed
      # JSON object, or a `422` ServiceError when the body does not parse
      # or is not a JSON object.
      private def self.parse_body_object(raw : String) : JSON::Any | Facet::ServiceError
        parsed = begin
          JSON.parse(raw)
        rescue ex : JSON::ParseException
          return Facet::ServiceError.new(422, "Invalid JSON body: #{ex.message}")
        end
        return parsed if parsed.as_h?

        Facet::ServiceError.new(
          422,
          "Body must be a JSON object (got #{Doctype::StrictKeys.json_kind(parsed)})"
        )
      end

      # Parses and range-gates the `page` / `items` pair (B-169): a
      # non-integer value answers `422` naming the parameter, and so does a
      # well-shaped value below 1 (the B-169 residual) — the caller error
      # is never clamped into the first page.
      private def self.page_and_items(json : JSON::Any) : {Int32, Int32} | Facet::ServiceError
        page = json_int(json["page"]?, "page", DEFAULT_PAGE)
        return page if page.is_a?(Facet::ServiceError)
        return below_range_error("page", page) if page < 1
        items = json_int(json["items"]?, "items", DEFAULT_ITEMS)
        return items if items.is_a?(Facet::ServiceError)
        return below_range_error("items", items) if items < 1
        {page, items}
      end

      # Parses a list request from a Kemal HTTP env.
      # Merges JSON body with query-string params; query params take precedence.
      #
      # A present body rides the same shape gate as every other
      # body-consuming route (B-59): it must parse as JSON and be a JSON
      # object. Either transport can answer `422` — a non-object body (B-59),
      # a `sort` / `select` value of the wrong shape (B-100), a sort entry
      # outside the field shape (B-158), or a non-integer `page` / `items`
      # value (B-169) — and `from_request` surfaces the first failure to
      # the route layer.
      def self.from_request(env, strict : Bool = false, extra_query_keys : Set(String) = Set(String).new) : ListRequest | Facet::ServiceError
        raw = env.request.body.try(&.gets_to_end)
        if raw.nil? || raw.empty?
          return from_query(env.params.query, strict, extra_query_keys)
        end

        parsed = parse_body_object(raw)
        return parsed if parsed.is_a?(Facet::ServiceError)

        body_req = from_json(parsed, strict)
        return body_req if body_req.is_a?(Facet::ServiceError)

        query_req = from_query(env.params.query, strict, extra_query_keys)
        return query_req if query_req.is_a?(Facet::ServiceError)
        merge_requests(body_req, query_req)
      end

      # Merges the body and query-string parses of one request. The
      # query-string value wins on every colliding key — the merge
      # precedence the HTTP transport documents.
      private def self.merge_requests(body_req : ListRequest, query_req : ListRequest) : ListRequest
        new(
          page: query_req.page > 1 ? query_req.page : body_req.page,
          items: query_req.items != DEFAULT_ITEMS ? query_req.items : body_req.items,
          filters: body_req.filters.merge(query_req.filters),
          sort: query_req.sort != ["id"] ? query_req.sort : body_req.sort,
          select: query_req.select || body_req.select,
          aggregate: query_req.aggregate || body_req.aggregate,
          field: query_req.field || body_req.field,
          scope: query_req.scope || body_req.scope,
          include_deleted: query_req.include_deleted? || body_req.include_deleted?,
        )
      end

      # ── Query-string parsing ───────────────────────────────────────────

      # Parses a list request from query-string params. Returns a `422`
      # `Facet::ServiceError` when a `sort` entry sits outside the
      # `SORT_FIELD_RE` shape (B-158), when a present, non-empty
      # `page` / `items` value is not an integer (B-169), when a present,
      # non-empty `page` / `items` value sits below 1 (the B-169 residual),
      # or — with `strict: true` — when a parameter outside the known set
      # rides the query string (the B-169 remainder): the caller propagates
      # all of them the same way the JSON-body path does. `extra_query_keys`
      # names the keys a strict route reads beyond the grammar; the strict
      # scan admits them. The scan runs only when `strict` is true, so the
      # extra set is a no-op on the lenient default.
      def self.from_query(params : URI::Params, strict : Bool = false, extra_query_keys : Set(String) = Set(String).new) : ListRequest | Facet::ServiceError
        if strict
          err = strict_query_error(params, extra_query_keys)
          return err if err
        end

        pair = query_page_and_items(params)
        return pair if pair.is_a?(Facet::ServiceError)

        # filters[field__op]=value. A value that parses as a JSON array is
        # decoded into a real array — the query string cannot carry an array
        # as a scalar, so array-valued filters (`__between` bounds, array
        # `__overlaps`) ride JSON-encoded (`["USD 25000","USD 100000"]`), the
        # encoding the frontend DataSource emits. Every other value keeps the
        # raw string form — the historical contract numeric-string comparison
        # filters rely on.
        filters = {} of String => JSON::Any
        params.each do |key, value|
          if key.starts_with?("filters[") && key.ends_with?("]")
            filter_key = key[8..-2] # strip "filters[" prefix and "]" suffix
            filters[filter_key] = decode_filter_value(value)
          end
        end

        # sort=-created_at,id  (comma-separated, or repeated)
        sort = ["id"]
        if params.has_key?("sort")
          raw = params.fetch_all("sort").flat_map(&.split(',')).reject(&.empty?)
          sort = raw unless raw.empty?
        end

        sel = params.fetch("select", "").split(',').map(&.strip).reject(&.empty?)
        sel = nil if sel.empty?

        agg = parse_aggregate(params.fetch("aggregate", ""))
        field = parse_field(params.fetch("field", ""))
        scope = parse_optional_string(params.fetch("scope", ""))
        deleted = parse_bool_flag(params.fetch("deleted", ""))

        validated = validated_sort(sort)
        return validated if validated.is_a?(Facet::ServiceError)
        page, items = pair
        new(page, items, filters, validated, sel, agg, field, scope, deleted)
      end

      # Parses and range-gates the query-string `page` / `items` pair — the
      # query-string twin of `page_and_items`.
      private def self.query_page_and_items(params : URI::Params) : {Int32, Int32} | Facet::ServiceError
        page = query_int(params, "page", DEFAULT_PAGE)
        return page if page.is_a?(Facet::ServiceError)
        return below_range_error("page", page) if page < 1
        items = query_int(params, "items", DEFAULT_ITEMS)
        return items if items.is_a?(Facet::ServiceError)
        return below_range_error("items", items) if items < 1
        {page, items}
      end

      # Canonical JSON serialization of this request.
      #
      # Used by `Helpers.list_request_fingerprint` to compute a digest
      # that is stable across equivalent requests regardless of transport —
      # the list endpoint accepts parameters via JSON body, query string,
      # or a merge of both, and `Hash#to_json` in Crystal preserves insertion
      # order, so naive serialization would produce different digests for
      # semantically-equal filter sets that arrived in different key orders.
      #
      # This implementation emits a deterministic shape with `filters` keys
      # sorted. `select` is omitted when `nil` to keep the digest stable for
      # the common no-projection case.
      # `aggregate` is included in the canonical form when set, so a count
      # request and a data request with otherwise-identical parameters do
      # not share an ETag. `field` follows the same rule for the field
      # aggregates (`sum` / `avg` / `min` / `max`): two aggregates over
      # different fields must not share an ETag, so the field is emitted
      # whenever set. Both feed `Helpers.list_request_fingerprint` and
      # therefore the collection ETag.
      # `scope` is emitted when set — a query-time named scope narrows the
      # result set, so a scoped request and its unscoped form must never
      # share an ETag. The parse layer carries the value verbatim;
      # `Document::List` validates the name against the doctype's declared
      # scopes (422 on an unknown name).
      # `include_deleted` is emitted only when true — the trash listing
      # (`?deleted=true`) and the live list must never share an ETag, while
      # requests without the flag serialize exactly as before (no digest
      # churn for existing clients).
      def to_json : String
        JSON.build do |json|
          json.object do
            json.field "page", @page
            json.field "items", @items
            json.field "sort", @sort
            json.field "filters" do
              json.object do
                @filters.to_a.sort_by(&.first).each do |k, v|
                  json.field k, v
                end
              end
            end
            if sel = @select
              json.field "select", sel
            end
            if agg = @aggregate
              json.field "aggregate", agg
            end
            if field = @field
              json.field "field", field
            end
            if sc = @scope
              json.field "scope", sc
            end
            if @include_deleted
              json.field "deleted", true
            end
          end
        end
      end

      # ── Helpers ────────────────────────────────────────────────────────

      # Reads one integer from a JSON value. Accepted shapes: a JSON
      # integer, a JSON number (truncated), and a numeric string. Every
      # other shape, and `nil`, returns `nil`. A number outside the Int32
      # range also returns `nil` — `json_int` turns that into the same
      # `422` the query path answers for a too-large numeric string
      # (`String#to_i?` fails there), so a huge value can never escape as
      # a 500.
      private def self.extract_int(value : JSON::Any?) : Int32?
        return nil if value.nil?
        case raw = value.raw
        when Int, Float
          begin
            raw.to_i32
          rescue OverflowError
            nil
          end
        when String then raw.to_i?
        else             nil
        end
      end

      # Reads one integer body parameter. `null` (or an absent key) keeps
      # `default` — the body form of "not given". A present value that
      # `extract_int` rejects (a non-numeric string, bool, array, object)
      # answers `422` naming the parameter (B-169): the parser never drops
      # it silently, the same rule the sort shape check holds (B-158).
      private def self.json_int(value : JSON::Any?, name : String, default : Int32) : Int32 | Facet::ServiceError
        return default if value.nil? || value.raw.nil?
        parsed = extract_int(value)
        return parsed if parsed
        Facet::ServiceError.new(422, "Parameter '#{name}' must be an integer")
      end

      # The `422` for a present, well-shaped `page` / `items` value below 1
      # (the B-169 residual): the value names a real page position no
      # listing serves, so it is a caller error rather than a silent clamp
      # to the first page.
      private def self.below_range_error(name : String, value : Int32) : Facet::ServiceError
        Facet::ServiceError.new(422, "Parameter '#{name}' must be at least 1 (got #{value})")
      end

      # The `422` for the first body key outside the known set, or nil —
      # the strict admission scan (the B-169 remainder). A body that never
      # reached the object gate (direct callers) skips the scan; the shape
      # gate downstream answers for it as before.
      private def self.strict_body_error(json : JSON::Any) : Facet::ServiceError?
        obj = json.as_h? || return nil
        obj.each_key do |key|
          return unknown_key_error(key, KNOWN_BODY_KEYS) unless KNOWN_BODY_KEYS.includes?(key)
        end
        nil
      end

      # The `422` for a query parameter outside the known set, or nil — the
      # strict admission scan (the B-169 remainder). The well-shaped
      # `filters[field__op]=value` bracket form is part of the grammar, and
      # `extra_query_keys` names the handler-contract keys a strict route
      # reads outside it (`include` on the document history, `status` on
      # the webhook-calls list). A malformed bracket key is neither and
      # answers like any unknown parameter.
      private def self.strict_query_error(params : URI::Params, extra_query_keys : Set(String)) : Facet::ServiceError?
        params.each do |key, _values|
          next if key.starts_with?("filters[") && key.ends_with?("]")
          next if extra_query_keys.includes?(key)
          return unknown_key_error(key, KNOWN_QUERY_KEYS + extra_query_keys) unless KNOWN_QUERY_KEYS.includes?(key)
        end
        nil
      end

      # The `422` for a key outside the list-parameter grammar (the B-169
      # remainder, strict admission): the value would be silently dropped,
      # so a misspelled parameter must fail the request instead. The
      # message names the accepted set — the same shape the filter-grammar
      # `422` uses on the same surfaces — so a misspelled parameter (say
      # `limit` for `items`) does not need a doc lookup per retry.
      private def self.unknown_key_error(key : String, accepted : Set(String)) : Facet::ServiceError
        Facet::ServiceError.new(422, "Unknown parameter '#{key}' (accepted: #{accepted.join(", ")})")
      end

      # Reads one integer query parameter. Absent or empty keeps `default`
      # — an empty value is the query-string form of "not given". A present,
      # non-empty value that is not an integer answers `422` naming the
      # parameter (B-169). A value below 1 answers `422` at the parse site
      # (the B-169 residual); the `initialize` clamps stay as the
      # constructor invariant for direct callers, and the above-`MAX_ITEMS`
      # clamp keeps its historical behaviour.
      private def self.query_int(params : URI::Params, name : String, default : Int32) : Int32 | Facet::ServiceError
        raw = params.fetch(name, "")
        return default if raw.empty?
        parsed = raw.to_i?
        return parsed if parsed
        Facet::ServiceError.new(422, "Parameter '#{name}' must be an integer")
      end

      # Parses an optional string parameter from either a JSON any
      # (body path) or a raw string (query-string path). Returns `nil` when
      # absent or empty; returns the string otherwise. The value is
      # surfaced verbatim — existence and shape are validated downstream
      # (`Document::List`), not here.
      private def self.parse_optional_string(value : JSON::Any?) : String?
        return nil if value.nil?
        raw = value.raw
        s = case raw
            when String then raw
            else             raw.to_s
            end
        s.empty? ? nil : s
      end

      private def self.parse_optional_string(value : String) : String?
        s = value.strip
        s.empty? ? nil : s
      end

      # Parses the `aggregate` parameter. See `parse_optional_string` —
      # unknown aggregates surface as a 422 in `Document::List`.
      private def self.parse_aggregate(value : JSON::Any?) : String?
        parse_optional_string(value)
      end

      private def self.parse_aggregate(value : String) : String?
        parse_optional_string(value)
      end

      # Parses the `field` parameter (the target field of the field
      # aggregates `sum` / `avg` / `min` / `max`). See `parse_optional_string`.
      private def self.parse_field(value : JSON::Any?) : String?
        parse_optional_string(value)
      end

      private def self.parse_field(value : String) : String?
        parse_optional_string(value)
      end

      # Parses a boolean flag from either a JSON any (body path) or a raw
      # string (query-string path). Only a JSON `true` or the string "true"
      # enables the flag — any other value (absent, empty, "false", "1") is
      # off, so a client cannot accidentally request tombstones.
      private def self.parse_bool_flag(value : JSON::Any?) : Bool
        return false if value.nil?
        case raw = value.raw
        when Bool   then raw
        when String then raw == "true"
        else             false
        end
      end

      private def self.parse_bool_flag(value : String) : Bool
        value.strip == "true"
      end

      # Shape-gates the sort list against SORT_FIELD_RE. A `422`
      # `ServiceError` names any entry outside the shape — the silent drop
      # (the old fallback to `["id"]` when no entry survived) hid caller
      # typos behind the default order (B-158), so nothing is dropped
      # anymore. An absent (or wholly empty) sort keeps the `["id"]`
      # default.
      private def self.validated_sort(fields : Array(String)) : Array(String) | Facet::ServiceError
        fields.each do |field|
          next if field.matches?(SORT_FIELD_RE)

          return Facet::ServiceError.new(
            422,
            "Invalid sort field: '#{field}' (allowed: an optional '-' prefix, then characters from [a-z_.])"
          )
        end
        fields.empty? ? ["id"] : fields
      end

      # Decodes one query-string filter value. JSON-array text (`[...]` that
      # parses) becomes a real array; anything else keeps the raw string —
      # including `[`-prefixed text that is not valid JSON (a literal string
      # filter value). Only arrays are decoded: scalars must keep their
      # string form, or a numeric-string filter (`age__gt=18`) would bind as
      # a JSON number and change the compiled SQL.
      #
      # Public so the export route parses its query-string filters through
      # the same decoder (B-108): both routes must accept the same filter
      # grammar with the same wire encoding.
      def self.decode_filter_value(value : String) : JSON::Any
        return JSON::Any.new(value) unless value.starts_with?('[')
        JSON.parse(value)
      rescue JSON::ParseException
        JSON::Any.new(value)
      end

      # Shape-gates an array-of-strings parameter (`sort`, `select`).
      # Returns a `422` ServiceError when the value is present but is not a
      # JSON array of strings — a parseable body with a wrong shape is a
      # caller error (B-100), never a 500 from `JSON::Any#as_a`.
      private def self.string_array(value : JSON::Any, name : String) : Array(String) | Facet::ServiceError
        arr = value.as_a?
        return Facet::ServiceError.new(422, "#{name} must be an array of strings") if arr.nil?

        strings = [] of String
        arr.each do |element|
          s = element.as_s?
          return Facet::ServiceError.new(422, "#{name} must be an array of strings") if s.nil?
          strings << s
        end
        strings
      end
    end
  end
end
