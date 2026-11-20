# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "big"
require "../util/diacritic_fold"
require "../util/filter_set"
require "../util/filter_clauses"
require "../util/like_escape"
require "../util/time_helper"
require "../util/money"
require "../util/money_filter_value"
require "../doctype/doctype_definition"

module Facet
  module Document
    # Shared compiler for the document filter grammar.
    #
    # Takes a doctype definition and a raw filter hash and produces the
    # WHERE-clause fragments plus their bound parameters. `Document::List`
    # calls this as its only filter-compile step; the partition, the
    # datetime UTC normalization, and every clause family live here so all
    # callers compile filters the same way.
    #
    # Clause families, in compile order (the order fixes placeholder
    # numbering; the clauses AND-compose, so the order does not change
    # semantics):
    # 1. range (`period` / `dateperiod` GiST LHS),
    # 2. system columns (`id`, `created_at`, `updated_at`, `deleted_at`),
    # 3. typed comparisons (`integer` / `duration` / `boolean` via
    #    `jsonb_as_numeric` / `jsonb_as_boolean`),
    # 4. money (`facet_money_value_as_numeric` + `__currency`),
    # 5. container (`array` membership via JSONB `@>` / `&&`),
    # 6. plain scalars via `Util::FilterSet` (text extraction),
    # 7. `search` (trigram ILIKE over the accent-folded corpus; bare key
    #    only — `validate_filters!` rejects a suffixed `search__*` form
    #    before routing, so the router's `FALSE` for it is a defensive
    #    fallback, never the HTTP answer).
    #
    # Malformed filter values degrade to an always-false (`FALSE`) clause —
    # a bad filter is a no-match, not a 500. The one exception is money:
    # a malformed amount or an unregistered ticker raises
    # `Util::FilterClauses::MoneyFilterError` so the service layer can
    # surface a 422 with the param named.
    module FilterCompiler
      # System-provided columns that are queryable as filter targets even
      # though they are not part of the doctype's `fields` schema. Listed in
      # `Document::List.build_order_clause` too (sorts already accept them)
      # and exposed by the table UI for filtering. `id` is the short document
      # id on `projections`; the timestamps are tz-naive UTC `timestamp`
      # columns, so filter values are normalized to UTC RFC-3339 in
      # `normalize_datetime_query_filters` (matching the `datetime` field
      # contract). `deleted_at` is only meaningful on the trash listing
      # (`include_deleted: true`) — live rows always have it NULL.
      SYSTEM_TIMESTAMP_FIELDS = Set{"id", "created_at", "updated_at", "deleted_at"}

      # Operator suffixes the compiler serves for each filter-target family.
      # The sets mirror the routing exactly — `allowed_operators` derives its
      # answer from the same rules `partition_filters` routes by, so a
      # validated query never hits a silent drop or a compiled `FALSE`.
      # The per-type ceilings live with the type tables
      # (`Doctype.supported_operators` in `src/doctype/filter_capability.cr`)
      # so the derived `operators` metadata and this routing stay one source
      # of truth; the system-column sets below are the compiler's own.
      ID_OPERATORS        = Set{"eq", "ne", "match", "gt", "gte", "lt", "lte", "between", "in"}
      TIMESTAMP_OPERATORS = Set{"eq", "ne", "gt", "gte", "lt", "lte", "between"} # `match` has no timestamp semantics

      # Returns the operator suffixes the grammar serves for `field`, or
      # `nil` when the doctype does not declare it (the caller decides the
      # error). An empty set means the field is not filterable: it declares
      # no `filters` capability, so it has no index. `search` is the one
      # bare-key-only production; `validate_filters!` raises
      # `unsupported_filter_operator` for every suffixed form.
      #
      # The authored `filters` capabilities are the queryability signal.
      # The derived operator set is intersected with the type's runtime
      # ceiling (`type_supported_operators`), so a capability never offers
      # an operator the clause builder cannot compile.
      def self.allowed_operators(
        definition : Doctype::DoctypeDefinition,
        field : String,
        skip_capability_check : Bool = false,
      ) : Set(String)?
        if field == "search"
          return Set(String).new
        end
        if SYSTEM_TIMESTAMP_FIELDS.includes?(field)
          return field == "id" ? ID_OPERATORS : TIMESTAMP_OPERATORS
        end

        field_def = definition.fields[field]?
        return nil if field_def.nil?

        # Internal integrity filters (the reference check's declared filter,
        # the sidecar `target` lookup) are not user queries: they run against
        # a known row and need no index, so they bypass the authored-capability
        # gate and validate against the type's runtime ceiling only.
        return type_supported_operators(field_def) if skip_capability_check

        # `in` is the set-membership form of equality and rides the same
        # btree, so it is declared whenever `eq` is. `ne` is the negation of
        # equality and rides the same btree too. The intersection with the
        # type ceiling drops both where the builder does not serve them
        # (money, containers, ranges).
        declared = field_def.operators.map(&.to_s.underscore).to_set
        if declared.includes?("eq")
          declared << "in"
          declared << "ne"
        end
        declared & type_supported_operators(field_def)
      end

      # The operators the field type's clause builder can compile. This is
      # the runtime ceiling; `allowed_operators` intersects it with the
      # authored `filters` capabilities. Delegates to the shared type table
      # (`Doctype.supported_operators`) — the same ceiling the derived
      # `operators` metadata is intersected with.
      private def self.type_supported_operators(field_def : Doctype::FieldDefinition) : Set(String)
        Doctype.supported_operators(field_def.type.try(&.type_name))
      end

      # Compiles the raw filter hash against the doctype definition.
      #
      # Returns `{clauses, params}` — the SQL fragments (AND-composed by the
      # caller) and their bound parameters. `offset` is the number of bind
      # parameters the caller has already bound before these clauses; the
      # filter placeholders start at `offset + 1`.
      #
      # Raises `Util::FilterClauses::MoneyFilterError` on a malformed money
      # filter (non-decimal amount, unknown ticker, mixed-currency
      # `__between` bounds) and `Util::FilterClauses::FilterGrammarError`
      # when a filter key names an unknown field or an unserved operator,
      # or an array-valued operator receives a value of the wrong shape
      # (reason `malformed_filter_value`, B-41).
      def self.compile(
        definition : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        offset : Int32 = 0,
        skip_capability_check : Bool = false,
      ) : {Array(String), Array(::DB::Any)}
        validate_filters!(filters, definition, skip_capability_check: skip_capability_check)
        normalized_filters = normalize_datetime_query_filters(filters, definition)
        buckets = partition_filters(normalized_filters, definition)

        where_clauses = [] of String
        all_params = [] of ::DB::Any

        # 1. Add range filters (GiST-range LHS)
        range_clauses, range_params = Util::FilterClauses.range_clauses(buckets.range_filters, definition, offset + all_params.size)
        where_clauses.concat(range_clauses)
        all_params.concat(range_params)

        # 2. Add system-column filters (id, created_at, updated_at) against
        # the projection columns directly. `created_at`/`updated_at` are
        # tz-naive UTC `timestamp` columns, so the bound value is cast to
        # `::timestamp` (not `::timestamptz`) — the matching stored form.
        system_clauses, system_params = build_system_clauses(buckets.system_filters, offset + all_params.size)
        where_clauses.concat(system_clauses)
        all_params.concat(system_params)

        # 3. Add typed comparison filters (numeric eq/ne/gt/gte/lt/lte/
        # between/in, boolean gt/gte/lt/lte/between/in) against
        # `jsonb_as_numeric` / `jsonb_as_boolean`. Kept
        # separate from the schema-agnostic `FilterSet` (which only knows
        # the text-extract `content->>'field'`) — type awareness lives here
        # where the doctype definition is in scope.
        typed_clauses, typed_params = Util::FilterClauses.typed_clauses(buckets.typed_filters, definition, offset + all_params.size)
        where_clauses.concat(typed_clauses)
        all_params.concat(typed_params)

        # 3'. Add money field filters — `facet_money_value_as_numeric`
        # LHS with optional currency predicate, plus the `__currency`
        # operator. May raise `MoneyFilterError`.
        money_clauses, money_params = Util::FilterClauses.money_clauses(buckets.money_filters, definition, offset + all_params.size)
        where_clauses.concat(money_clauses)
        all_params.concat(money_params)

        # 3''. Add container (array `membership`) filters — JSONB `@>` /
        # `&&` containment over `content->'field'`. Served by `gin_jsonb`.
        container_clauses, container_params = Util::FilterClauses.container_clauses(buckets.container_filters, definition, offset + all_params.size)
        where_clauses.concat(container_clauses)
        all_params.concat(container_params)

        # 3'''. Add reference-field scalar filters — the dual-form match
        # (qualified stored form OR bare row id) described at
        # `reference_clauses`.
        reference_clauses, reference_params = Util::FilterClauses.reference_clauses(buckets.reference_filters, definition, offset + all_params.size)
        where_clauses.concat(reference_clauses)
        all_params.concat(reference_params)

        # 4. Add scalar field filters via FilterSet (schema-agnostic)
        filter_set = Util::FilterSet.new(buckets.scalar_filters, offset: offset + all_params.size)
        unless filter_set.empty?
          where_clauses << filter_set.to_sql
          all_params.concat(filter_set.values)
        end

        # 5. Add search filter
        add_search_filter(where_clauses, all_params, buckets.search_filter, offset)

        {where_clauses, all_params}
      end

      # ── Private ──────────────────────────────────────────────────────────

      # Rejects every filter key the partition below would drop silently:
      # a field that is not declared on the doctype (and is not a system
      # column or `search`), a known field whose operator suffix its
      # family does not serve, or an array-valued operator given a value
      # of the wrong shape. The strictness mirrors
      # `agent_tools/read.cr`'s filter validation — a typo must answer 422,
      # never return unfiltered rows (B-20), and a malformed array value
      # must answer 422, never read as "nothing matches" (B-41).
      #
      # A bare key (no `__` separator) is its own production: `parse_filter_key`
      # maps it to the `eq` suffix, so it is checked against
      # `allowed_operators` like any suffixed key. `search` is the one
      # exception — its bare key is the production and its allowed set is
      # empty. Only a key carrying a `__` suffix is checked against the
      # value-shape contract.
      def self.validate_filters!(
        filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        skip_capability_check : Bool = false,
      ) : Nil
        filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          allowed = allowed_operators(definition, field, skip_capability_check: skip_capability_check)
          if allowed.nil?
            raise Util::FilterClauses::FilterGrammarError.new(key, "unknown_filter_field",
              "Unknown filter field '#{field}' (filterable: #{filterable_fields(definition).join(", ")})")
          end

          # `search` is the bare-key-only production. Its allowed set is
          # empty, so every suffixed form fails the check below; the bare
          # key passes.
          if field == "search"
            next if key == "search"
            raise unsupported_operator_error(key, field, op_suffix, allowed, search_field: true)
          end

          unless allowed.includes?(op_suffix)
            raise unsupported_operator_error(key, field, op_suffix, allowed)
          end

          validate_value_shape!(key, op_suffix, value, definition) if key.includes?("__")
        end
      end

      private def self.unsupported_operator_error(
        key : String,
        field : String,
        op_suffix : String,
        allowed : Set(String),
        search_field : Bool = false,
      ) : Util::FilterClauses::FilterGrammarError
        # An empty allowed set has two causes: `search` is bare-key-only,
        # and a field that declares no `filters` capability has no operator.
        # `(allowed: )` names no remedy, so state the fix instead.
        message = if !allowed.empty?
                    "Filter operator '#{op_suffix}' is not served for field '#{field}' (allowed: #{allowed.to_a.sort.join(", ")})"
                  elsif search_field
                    "Filter operator '#{op_suffix}' is not served for field '#{field}': `search` takes a bare key only (for example `search=<text>`)."
                  else
                    "Filter operator '#{op_suffix}' is not served for field '#{field}': the field declares no filter capability. Add a `filters:` capability to the field in the doctype definition (for example `filters: [equality]`), then re-deploy the doctype."
                  end
        Util::FilterClauses::FilterGrammarError.new(key, "unsupported_filter_operator", message)
      end

      # Every filter target the compiler serves for the doctype: fields
      # that declare a `filters` capability, the system columns, and
      # `search`.
      private def self.filterable_fields(definition : Doctype::DoctypeDefinition) : Array(String)
        fields = definition.fields.select { |_, field_def| !field_def.operators.empty? }.keys
        (fields + SYSTEM_TIMESTAMP_FIELDS.to_a + ["search"]).sort
      end

      # Enforces the value-shape contract for one served filter key.
      # Array-valued operators (`__in`, `__between`, the range intervals)
      # degrade a non-array value to a `FALSE` clause downstream, so a
      # malformed value would silently empty the result — raise a 422 that
      # names the filter key and the required shape instead (B-41).
      # Operators that also serve a scalar form (container membership, the
      # range point `__contains`) accept that scalar, but reject shapes with
      # no containment meaning (objects, `null`) on the same channel.
      private def self.validate_value_shape!(
        key : String,
        op_suffix : String,
        value : JSON::Any,
        definition : Doctype::DoctypeDefinition,
      ) : Nil
        shape = value_shape_requirement(definition, key.split("__", 2)[0], op_suffix)
        return if shape.nil?

        raw = value.raw
        ok = case shape
             when :array           then raw.is_a?(Array(JSON::Any))
             when :point_or_array  then raw.is_a?(Array(JSON::Any) | String)
             when :scalar_or_array then raw.is_a?(Array(JSON::Any) | String | Int64 | Float64 | Bool)
             else                       true
             end
        return if ok

        raise Util::FilterClauses::FilterGrammarError.new(key, "malformed_filter_value",
          "Filter '#{key}' requires #{shape_message(shape)} (got #{describe_json_kind(raw)})")
      end

      # Returns the value-shape contract the compiler serves for `field`
      # with `op_suffix`, or `nil` when the operator takes a single scalar
      # value with no shape constraint:
      #
      # - `:array` — only a JSON array is a valid value (`__in`, `__between`,
      #   the range `__eq` / `__overlaps` / `__within` intervals, system
      #   `id__in` / `id__between`, timestamp `__between`).
      # - `:point_or_array` — an ISO-8601 string (point) or a JSON array
      #   (interval) on a `period` / `dateperiod` `__contains`.
      # - `:scalar_or_array` — any scalar or array on array-field
      #   membership (`__eq` / `__contains` / `__overlaps`); a scalar is the
      #   single-element form `container_bound_array` wraps.
      #
      # The family routing mirrors `partition_filters` and the clause
      # builders — by the time this runs, the operator check has already
      # rejected every suffix a family does not serve, so the fallthrough
      # only sees the typed and scalar families (both serve `__in` /
      # `__between` through `Util::FilterSet`).
      private def self.value_shape_requirement(
        definition : Doctype::DoctypeDefinition,
        field : String,
        op_suffix : String,
      ) : Symbol?
        if SYSTEM_TIMESTAMP_FIELDS.includes?(field)
          return :array if {"between", "in"}.includes?(op_suffix)
          return nil
        end
        if Util::FilterClauses.range_field_type(definition, field)
          return :array if {"eq", "overlaps", "within"}.includes?(op_suffix)
          return :point_or_array if op_suffix == "contains"
          return nil
        end
        if Util::FilterClauses.money_field?(definition, field)
          return :array if op_suffix == "between"
          return nil
        end
        if Util::FilterClauses.container_field?(definition, field)
          return :scalar_or_array if {"eq", "contains", "overlaps"}.includes?(op_suffix)
          return nil
        end
        return :array if {"in", "between"}.includes?(op_suffix)
        nil
      end

      # The required-shape phrase for one shape contract, embedded in the
      # `malformed_filter_value` message.
      private def self.shape_message(shape : Symbol) : String
        case shape
        when :array          then "a JSON array value"
        when :point_or_array then "an ISO-8601 string or a JSON array value"
        else                      "a scalar or a JSON array value"
        end
      end

      # Names the JSON kind of a rejected value for the error message.
      private def self.describe_json_kind(raw) : String
        case raw
        when Array(JSON::Any) then "an array"
        when String           then "a string"
        when Int64, Float64   then "a number"
        when Bool             then "a boolean"
        when Nil              then "null"
        else                       "an object"
        end
      end

      # Pre-processes the raw filter hash: for every filter targeting
      # a `datetime` field (or a system timestamp column — `created_at` /
      # `updated_at`), normalizes the supplied ISO‑8601 value (which
      # may carry a timezone offset) to its UTC RFC‑3339 form so that the
      # subsequent text-based comparison against the tz‑naive UTC stored
      # value succeeds. Other filters are passed through unchanged.
      private def self.normalize_datetime_query_filters(
        filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
      ) : Hash(String, JSON::Any)
        result = {} of String => JSON::Any
        filters.each do |key, value|
          field, _op_suffix = Util::FilterSet.parse_filter_key(key)
          field_type = definition.fields[field]?.try(&.type)
          if field_type && field_type.type_name == "datetime"
            result[key] = normalize_datetime_filter_value(value)
          elsif field == "created_at" || field == "updated_at" || field == "deleted_at"
            # System-managed timestamp columns: same UTC RFC-3339 contract
            # as `datetime` fields — see AGENTS.md → Time / Timezone.
            result[key] = normalize_datetime_filter_value(value)
          else
            result[key] = value
          end
        end
        result
      end

      # Normalizes a single `datetime` field filter value to UTC RFC‑3339.
      # Handles both scalar string values (for `eq`/`ne`/`gt`/`gte`/`lt`/`lte`/
      # `match`) and two‑element array values (for `between`). Non‑string and
      # unparseable values are returned as‑is — `FilterSet` and the validator
      # surface the resulting mismatch as a no‑match rather than a 500.
      private def self.normalize_datetime_filter_value(value : JSON::Any) : JSON::Any
        case raw = value.raw
        when String
          normalized = Util::TimeHelper.to_utc_rfc3339(raw)
          normalized ? JSON::Any.new(normalized) : value
        when Array(JSON::Any)
          new_arr = raw.map do |item|
            case sub = item.raw
            when String
              sub_normalized = Util::TimeHelper.to_utc_rfc3339(sub)
              sub_normalized ? JSON::Any.new(sub_normalized) : item
            else
              item
            end
          end
          JSON::Any.new(new_arr)
        else
          value
        end
      end

      # One field per filter family. `partition_filters` fills the
      # buckets; `compile` reads them and the routers mutate them. Each
      # hash field is a reference type, so mutation through the struct
      # updates the shared hash. `search_filter` stays nil until a
      # `search` key arrives.
      private struct Buckets
        property search_filter : NamedTuple(key: String, value: JSON::Any)? = nil
        property range_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property system_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property typed_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property money_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property container_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property reference_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
        property scalar_filters : Hash(String, JSON::Any) = {} of String => JSON::Any
      end

      # Partitions raw filters into `Buckets`:
      # - a search filter (if present),
      # - a hash of range filters keyed by their original filter key
      #   (only those whose field is `period`/`dateperiod` and whose
      #   operator is range-aware: `eq`, `contains`, `overlaps`, `within`),
      # - a hash of system-column filters (`id`, `created_at`, `updated_at`)
      #   whose LHS targets the projection column rather than JSONB content,
      # - a hash of typed comparison filters (`__eq`/`__ne`/`__gt`/`__gte`/
      #   `__lt`/`__lte`/`__between`/`__in` on `integer` / `duration`
      #   fields; `__gt`/`__gte`/`__lt`/`__lte`/`__between`/`__in` on
      #   `boolean` fields) that are built against `jsonb_as_numeric` /
      #   `jsonb_as_boolean` rather than the text-extract
      #   `content->>'field'` — see `Util::FilterClauses.typed_clauses`,
      # - a hash of money field filters routed to `Util::FilterClauses.money_clauses`,
      # - a hash of container filters (`__eq`/`__contains`/`__overlaps` on
      #   `array` fields) routed to `Util::FilterClauses.container_clauses`
      #   (JSONB `@>` / `&&` containment over `content->'field'`),
      # - a hash of plain scalar filters (text-based: `eq`/`ne`/`match` on
      #   text-typed and `boolean` fields, and comparison ops on text-typed
      #   fields) for `FilterSet`.
      #
      # Filters whose field is a period/dateperiod but whose operator
      # is not range-aware (e.g. `gte`) are dropped — schema validation
      # already rejected this case at doctype authoring time, but we
      # degrade gracefully here rather than 500-ing the request.
      # Filters on any other unknown field are silently dropped (existing
      # contract: a non-matching filter is a no-op rather than a 500).
      private def self.partition_filters(
        filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
      ) : Buckets
        known_fields = definition.fields.keys.to_set
        buckets = Buckets.new

        filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          if field == "search"
            # The raw key rides along: `add_search_filter` accepts only the
            # bare `search` key and rejects every suffixed form.
            buckets.search_filter = {key: key, value: value}
          elsif SYSTEM_TIMESTAMP_FIELDS.includes?(field)
            buckets.system_filters[key] = value
          elsif known_fields.includes?(field)
            route_known_field_filter(key, field, op_suffix, value, definition, buckets)
          end
        end

        buckets
      end

      # Routes a known-field filter key into the matching bucket. Maintains
      # the field-type priority: range, money, container, typed
      # (integer/duration/boolean), then scalar fallback. Extracted from
      # `partition_filters` to keep that method under ameba's
      # cyclomatic-complexity limit.
      private def self.route_known_field_filter(
        key : String,
        field : String,
        op_suffix : String,
        value : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        buckets : Buckets,
      ) : Nil
        range_kind = Util::FilterClauses.range_field_type(definition, field)
        if range_kind
          # Range operators route to the range builder; a non-range operator
          # on a range field is dropped (validation should have caught it at
          # authoring time).
          route_range_filter(key, op_suffix, value, range_kind, buckets.range_filters)
        elsif route_object_filter(key, field, op_suffix, value, definition, buckets.money_filters, buckets.container_filters, buckets.reference_filters)
          nil
        elsif route_typed_comparison(key, field, op_suffix, value, definition, buckets.typed_filters, buckets.scalar_filters)
          nil
        else
          buckets.scalar_filters[key] = value
        end
      end

      # Routes a `period`/`dateperiod` field filter into the range bucket.
      # A filter with a non-range operator is dropped here. Validation
      # rejects this case at authoring time; the drop is a safe fallback.
      private def self.route_range_filter(
        key : String,
        op_suffix : String,
        value : JSON::Any,
        range_kind : String,
        range_filters : Hash(String, JSON::Any),
      ) : Nil
        return unless {"eq", "contains", "overlaps", "within"}.includes?(op_suffix)
        range_filters[key] = value
      end

      # Routes money, container (array), and reference fields to their
      # type-aware builders. Returns true when the key was routed.
      private def self.route_object_filter(
        key : String,
        field : String,
        op_suffix : String,
        value : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        money_filters : Hash(String, JSON::Any),
        container_filters : Hash(String, JSON::Any),
        reference_filters : Hash(String, JSON::Any),
      ) : Bool
        if Util::FilterClauses.money_field?(definition, field) &&
           {"eq", "gt", "gte", "lt", "lte", "between", "currency"}.includes?(op_suffix)
          # Money field — routed to its own builder that handles the
          # `<CCY> <amount>` filter grammar and the `__currency` operator.
          money_filters[key] = value
          return true
        end
        if Util::FilterClauses.container_field?(definition, field) &&
           {"eq", "contains", "overlaps"}.includes?(op_suffix)
          # Array field — routed to `container_clauses` (JSONB `@>` /
          # `&&` containment over `content->'field'`). `FilterSet` would
          # otherwise compare the JSON-stringified array against the filter
          # value via `content->>'field' = 'foo'`, which never matches.
          container_filters[key] = value
          return true
        end
        if Util::FilterClauses.reference_field?(definition, field) &&
           {"eq", "ne"}.includes?(op_suffix)
          # Reference field with a scalar match — the stored form is
          # qualified (`app.App.<id>`) while clients naturally hold the
          # bare row id (meta.id) and address single-document routes with
          # either form (canonical_doc_id). The clause matches both so the
          # two surfaces agree.
          reference_filters[key] = value
          return true
        end
        false
      end

      # Routes comparison operators on typed fields (`integer`/`duration`/
      # `boolean`) to the type-aware builder; everything else keeps the
      # scalar (text-extract) path. Returns true when the key was routed.
      #
      # `eq` / `ne` route through the numeric helper only for `integer` /
      # `duration` fields that declare an `equality` / `comparison`
      # capability. That declaration is what makes `Index::Planner` create
      # the `btree_numeric` index on `jsonb_as_numeric(content->'field')`,
      # so equality can use it and both operators compare numerically. A
      # unique `integer` / `duration` field without those capabilities has
      # only the text `unique_btree`, which the text equality matches — it
      # stays on the scalar path. `boolean` also keeps the scalar text
      # path: its index is a plain btree on `content->>'field'`.
      private def self.route_typed_comparison(
        key : String,
        field : String,
        op_suffix : String,
        value : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        typed_filters : Hash(String, JSON::Any),
        scalar_filters : Hash(String, JSON::Any),
      ) : Bool
        field_def = definition.fields[field]?
        return false if field_def.nil?

        helper = Util::FilterClauses.typed_field_type(definition, field)
        return false if helper.nil?

        comparison = {"gt", "gte", "lt", "lte", "between", "in"}.includes?(op_suffix)
        caps = field_def.filters
        btree_numeric = helper == "jsonb_as_numeric" &&
                        !caps.nil? &&
                        caps.any? { |c| c.equality? || c.comparison? }
        equality = btree_numeric && {"eq", "ne"}.includes?(op_suffix)
        return false unless comparison || equality

        # Type-aware LHS (`jsonb_as_numeric` / `jsonb_as_boolean`) so
        # query-string string values do not collapse to text ordering.
        typed_filters[key] = value
        true
      end

      # Builds SQL where-clause fragments for filters targeting system columns on
      # the `projections` table (`id`, `created_at`, `updated_at`, `deleted_at`). These are
      # not doctype fields and so cannot go through `FilterSet` (whose LHS is
      # always `content->>'field'`). The LHS here is the projection column
      # itself; for the timestamp columns the bound value is cast to
      # `::timestamp` because the columns are tz-naive UTC (see AGENTS.md →
      # Time / Timezone) — casting to `::timestamptz` would cross tz-aware
      # and tz-naive semantics and pull the session TimeZone into the result.
      #
      # Supported operators:
      # - `id`: `eq`, `ne`, `match`, `gt`, `gte`, `lt`, `lte`, `between`
      #   (lexicographic ULID comparison — ULIDs sort by their embedded
      #   timestamp, so this is also a useful chronological ordering).
      # - `created_at`/`updated_at`: same operators, with `between` accepting
      #   a two-element `[start, end]` ISO-8601 array. `match` is rejected
      #   (no useful `ILIKE` semantics on a `timestamp` column).
      #
      # Invalid operator/value combinations degrade to `FALSE` so a bad
      # filter never 500s the request (same contract as `FilterSet`).
      private def self.build_system_clauses(
        system_filters : Hash(String, JSON::Any),
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        system_filters.each do |key, value|
          field, op = Util::FilterSet.parse_filter_key(key)
          n = base_offset + params.size + 1
          clause, vals = build_system_clause(field, op, value, n)
          clauses << clause
          params.concat(vals)
        end

        {clauses, params}
      end

      # Builds a single system-column WHERE clause fragment.
      private def self.build_system_clause(
        field : String,
        op : String,
        value : JSON::Any,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        if field == "id"
          return build_id_clause(op, value, n)
        end

        # `created_at` / `updated_at` / `deleted_at` — tz-naive UTC `timestamp`
        # columns. `match` is rejected (no useful text-pattern semantics on a
        # timestamp).
        return {"FALSE", [] of ::DB::Any} if op == "match"

        if op == "between"
          return build_timestamp_between_clause(field, value, n)
        end

        build_timestamp_comparison_clause(field, op, value, n)
      end

      # SQL operator for each supported single-value comparison against a
      # tz-naive UTC `timestamp` system column.
      TIMESTAMP_SQL_OPS = {
        "eq"  => "=",
        "ne"  => "IS DISTINCT FROM",
        "gt"  => ">",
        "gte" => ">=",
        "lt"  => "<",
        "lte" => "<=",
      }

      # Builds a single-value comparison clause against a timestamp system
      # column. The bound value is cast to `::timestamp`; the columns are
      # tz-naive UTC. Degrades to `FALSE` when the operator is unsupported
      # or the value is not a parseable timestamp string, so a bad filter
      # never 500s the request (same contract as `FilterSet`).
      private def self.build_timestamp_comparison_clause(
        field : String,
        op : String,
        value : JSON::Any,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        sql_op = TIMESTAMP_SQL_OPS[op]?
        return {"FALSE", [] of ::DB::Any} unless sql_op

        raw = value.raw
        return {"FALSE", [] of ::DB::Any} unless raw.is_a?(String)
        normalized = Util::TimeHelper.to_utc_rfc3339(raw)
        return {"FALSE", [] of ::DB::Any} unless normalized

        {"#{field} #{sql_op} $#{n}::timestamp", [normalized] of ::DB::Any}
      end

      # Builds a clause for the short document `id` column on `projections`.
      # ULIDs sort lexicographically by their embedded timestamp, so the
      # ordering operators are also chronologically meaningful.
      private def self.build_id_clause(op : String, value : JSON::Any, n : Int32) : {String, Array(::DB::Any)}
        if op == "between"
          arr = value.as_a?
          return {"FALSE", [] of ::DB::Any} if arr.nil? || arr.size != 2
          lo = arr[0].raw.to_s
          hi = arr[1].raw.to_s
          return {"id BETWEEN $#{n} AND $#{n + 1}", [lo, hi] of ::DB::Any}
        end

        if op == "in"
          arr = value.as_a?
          if arr.nil? || arr.empty? || arr.size > Util::FilterSet::MAX_IN_VALUES
            return {"FALSE", [] of ::DB::Any}
          end
          placeholders = arr.map_with_index { |_, i| "$#{n + i}" }
          vals = [] of ::DB::Any
          arr.each { |el| vals << el.raw.to_s }
          return {"id = ANY(ARRAY[#{placeholders.join(", ")}])", vals}
        end

        val = case raw = value.raw
              when String, Int64, Float64, Bool, Nil then raw
              else                                        raw.to_s
              end
        clause = id_comparison_clause(op, n)
        return {"FALSE", [] of ::DB::Any} if clause.nil?
        # `match` follows the escaped-substring contract — the bound value
        # must be LIKE-escaped before binding.
        bound = op == "match" ? Util::LikeEscape.escape(val.to_s) : val
        {clause, [bound] of ::DB::Any}
      end

      # Returns the SQL fragment for a single-value comparison against the
      # `id` column, or `nil` if the operator is not supported.
      #
      # `match` follows the general text-pattern contract: the caller passes
      # a plain substring; it is escaped and wrapped as `%…% ESCAPE '\'` so
      # `%` / `_` in the input never act as ILIKE wildcards.
      private def self.id_comparison_clause(op : String, n : Int32) : String?
        case op
        when "eq"    then "id = $#{n}"
        when "ne"    then "id IS DISTINCT FROM $#{n}"
        when "match" then "id ILIKE '%' || $#{n} || '%' ESCAPE '\\'"
        when "gt"    then "id > $#{n}"
        when "gte"   then "id >= $#{n}"
        when "lt"    then "id < $#{n}"
        when "lte"   then "id <= $#{n}"
        else              nil
        end
      end

      # Builds a `BETWEEN` clause for a tz-naive UTC timestamp column. Both
      # array elements are normalized to UTC RFC-3339 before binding.
      private def self.build_timestamp_between_clause(
        field : String,
        value : JSON::Any,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        arr = value.as_a?
        return {"FALSE", [] of ::DB::Any} if arr.nil? || arr.size != 2
        lo_raw = arr[0].raw
        hi_raw = arr[1].raw
        return {"FALSE", [] of ::DB::Any} unless lo_raw.is_a?(String) && hi_raw.is_a?(String)
        lo = Util::TimeHelper.to_utc_rfc3339(lo_raw)
        hi = Util::TimeHelper.to_utc_rfc3339(hi_raw)
        return {"FALSE", [] of ::DB::Any} unless lo && hi
        {"#{field} BETWEEN $#{n}::timestamp AND $#{n + 1}::timestamp", [lo, hi] of ::DB::Any}
      end

      # Adds a search filter clause using substring (ILIKE) matching against
      # the `search` column.
      #
      # `search` is an operator-keyword of the filter grammar, not a column:
      # the bare key `search` is the only valid production. A suffixed form
      # (`search__match`, `search__eq`, `search__starts_with`, ...) is not a
      # production — it emits `FALSE`, the same no-silent-widening rule as
      # `created_at__match`: a bad filter matches nothing, it does not
      # silently become a contains match.
      #
      # The column is plain `text`; the corpus folded at write time
      # (`Document::Search`) and the term folded here make the match
      # case- and accent-insensitive without a citext column.
      #
      # The term folds through `Util::DiacriticFold` before escaping — the
      # corpus folded at write time (`Document::Search`), the term folds
      # here, so a term without diacritics matches an accented corpus. Fold
      # never creates a LIKE metacharacter; the folded term is then wrapped
      # in `%...%` and `\`, `%`, `_` are escaped so user input is matched
      # literally (contains semantics) rather than as a LIKE pattern. The
      # pattern is a bind parameter concatenated into the literal
      # (`'%' || $n || '%'`), which the trigram planner constant-folds into a
      # usable GIN search key. Terms shorter than three characters degrade to
      # a full GIN scan (correct results, slower) — this matches PostgreSQL's
      # trigram minimum-pattern behavior.
      private def self.add_search_filter(
        where_clauses : Array(String),
        all_params : Array(::DB::Any),
        search_filter : NamedTuple(key: String, value: JSON::Any)?,
        offset : Int32,
      ) : Nil
        return if search_filter.nil?

        # Only the bare key is a production of the grammar — check the raw
        # key, since a suffixed form and the operator form are distinguishable
        # only through it (`search__eq` parses to op `eq` exactly like a bare
        # key would).
        unless search_filter[:key] == "search"
          where_clauses << "FALSE"
          return
        end

        search_val = search_filter[:value].raw
        return if search_val.nil?

        term = Util::LikeEscape.escape(Util::DiacriticFold.fold(search_val.to_s))

        n = offset + all_params.size + 1
        where_clauses << "search ILIKE '%' || $#{n} || '%' ESCAPE '\\'"
        all_params << term
      end
    end
  end
end
