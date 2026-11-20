# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./filter_set"
require "./sql_ops"
require "./bind_scalar"
require "./money"
require "./money_filter_value"
require "../doctype/doctype_definition"

module Facet
  module Util
    # Type-aware SQL clause builders for document filters.
    #
    # Extracted from `Document::List` so the RBAC scope surfaces
    # (`RBAC::ScopePredicateSql` for named scopes, `RBAC::ContextResolver`
    # for context sets) can reuse the same type-aware compilation for
    # comparison / range / currency operators in scope `where` clauses.
    #
    # Each public builder takes a filter hash keyed by the standard
    # `field__op` filter-key grammar, the doctype definition, and a starting
    # placeholder offset; it returns `{Array(String), Array(::DB::Any)}` —
    # the SQL fragments and their bound parameters, with `$N` placeholders
    # numbered from `base_offset + 1`.
    #
    # Malformed filter values degrade to an always-false (`FALSE`) clause
    # rather than raising — a bad filter is a no-match, not a 500. Two
    # exceptions raise so the service layer can answer 422:
    # `MoneyFilterError` on malformed money values, and `FilterGrammarError`
    # (from `FilterCompiler.validate_filters!`) on a filter key the grammar
    # does not serve at all.
    module FilterClauses
      # Raised by `money_clauses` when a money filter value is malformed
      # (non-decimal amount) or references an unregistered currency ticker.
      # `Document::List.call` rescues it and returns a 422 `ServiceError`.
      class MoneyFilterError < Exception
      end

      # Raised by `FilterCompiler.compile` when a filter key names an unknown
      # field, a known field with an operator its family does not serve, or
      # an array-valued operator given a value of the wrong shape (B-41).
      # `Document::List.call` rescues it and returns a 422 `ServiceError`
      # (same channel as `MoneyFilterError`) — a typo in a filter key must
      # surface, never silently degrade the query to an unfiltered result,
      # and a malformed array value must surface, never read as "nothing
      # matches". `filter_key` names the offending key; `reason` is the
      # validation error code (`unknown_filter_field`,
      # `unsupported_filter_operator`, or `malformed_filter_value`).
      class FilterGrammarError < Exception
        getter filter_key : String
        getter reason : String

        def initialize(@filter_key : String, @reason : String, message : String)
          super(message)
        end
      end

      # Returns the PostgreSQL range constructor name ("tstzrange" or
      # "daterange") if the named field is a `period` or `dateperiod` field
      # on the doctype definition; `nil` otherwise.
      def self.range_field_type(
        definition : Doctype::DoctypeDefinition,
        field_name : String,
      ) : String?
        field_def = definition.fields[field_name]?
        return nil if field_def.nil?
        type = field_def.type
        return nil if type.nil?
        case type.type_name
        when "period"     then "tstzrange"
        when "dateperiod" then "daterange"
        else
          nil
        end
      end

      # Returns the cast helper name to use for a typed field's comparison
      # operators, or `nil` if the field's type is not numeric/boolean.
      # `integer` and `duration` share `jsonb_as_numeric` (numeric subsumes
      # bigint); `boolean` uses `jsonb_as_boolean`. `money` is NOT listed
      # here — it has its own builder (`money_clauses`) that uses
      # `facet_money_value_as_numeric(content->'field')`.
      def self.typed_field_type(
        definition : Doctype::DoctypeDefinition,
        field_name : String,
      ) : String?
        field_def = definition.fields[field_name]?
        return nil if field_def.nil?
        type = field_def.type
        return nil if type.nil?
        case type.type_name
        when "integer", "duration" then "jsonb_as_numeric"
        when "boolean"             then "jsonb_as_boolean"
        else                            nil
        end
      end

      # Returns true if the named field is a `money` field on the doctype
      # definition.
      def self.money_field?(
        definition : Doctype::DoctypeDefinition,
        field_name : String,
      ) : Bool
        field_def = definition.fields[field_name]?
        return false if field_def.nil?
        type = field_def.type
        return false if type.nil?
        type.type_name == "money"
      end

      # Returns true if the named field is an `array` container field on the
      # doctype definition. `dictionary` fields are deliberately excluded —
      # `membership` is not supported on dictionaries in this iteration.
      def self.container_field?(
        definition : Doctype::DoctypeDefinition,
        field_name : String,
      ) : Bool
        field_def = definition.fields[field_name]?
        return false if field_def.nil?
        type = field_def.type
        return false if type.nil?
        type.type_name == "array"
      end

      # True when the named field is a single-value `reference` field. Such
      # fields store the fully-qualified target id (`app.App.<ulid>`), but
      # clients hold and pass the bare row id just as naturally — see
      # `reference_clauses`.
      def self.reference_field?(
        definition : Doctype::DoctypeDefinition,
        field_name : String,
      ) : Bool
        field_def = definition.fields[field_name]?
        return false if field_def.nil?
        field_def.reference?
      end

      # Builds SQL where-clause fragments for scalar filters on `reference`
      # fields (`__eq` / `__ne`).
      #
      # A reference field stores the qualified target id
      # (`{domain}.{Doctype}.{id}`) while clients naturally hold the bare
      # `projections.id` (that is what `meta.id` returns and what
      # `canonical_doc_id` accepts on single-document routes). Matching the
      # stored text directly would force every client to re-qualify, so the
      # clause accepts both forms: a `__eq` matches `(bare) OR (qualified)`,
      # a `__ne` is the negation of the same pair. Collection references
      # (`collection: true`) stay on the container path.
      def self.reference_clauses(
        reference_filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        reference_filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          field_def = definition.fields[field]?
          next if field_def.nil?

          given = value.as_s?
          next if given.nil? || given.empty?

          # A polymorphic reference (no declared doctype — e.g. the sidecar
          # `target`) has no qualification prefix to derive, so it keeps the
          # plain exact match on the caller's value.
          target = field_def.qualified_doctype
          if target.nil?
            binds = [given]
          else
            # A caller-supplied qualified form normalizes down to the bare
            # id; the clause re-qualifies with the field's own target
            # doctype. Both forms then match the stored qualified value.
            prefix = "#{target}."
            bare = given.starts_with?(prefix) ? given[prefix.size..] : given
            binds = [bare, "#{target}.#{bare}"]
          end

          lhs = "content->>'#{field}'"
          placeholders = binds.map do |bind|
            i = base_offset + params.size + 1
            params << bind
            "$#{i}"
          end
          if op_suffix == "eq"
            comparisons = placeholders.map { |p| "#{lhs} = #{p}" }
            clauses << "(#{comparisons.join(" OR ")})"
          else
            comparisons = placeholders.map { |p| "#{lhs} IS DISTINCT FROM #{p}" }
            clauses << "(#{comparisons.join(" AND ")})"
          end
        end

        {clauses, params}
      end

      # Builds SQL where-clause fragments for filters on `money` fields.
      #
      # The money row stores `{"value":"123.42","currency":"USD"}`. The LHS
      # for value comparisons routes the object through the IMMUTABLE
      # `facet_money_value_as_numeric(content->'field')` cast (reads the
      # `value` member, decodes as `numeric`), matching the `btree_money`
      # leading column so the index is usable. The LHS for `__currency` is
      # `content#>>'{field,currency}'` (text extract, matched by
      # `btree_money_currency`).
      #
      # Filter value grammar (per the money revamp):
      # - `<CCY> <amount>`  → numeric compare AND currency equality.
      # - `<amount>` (no CCY prefix) → numeric compare against any currency.
      # - `price__currency=<CCY>` → text equality on the stored ticker.
      #
      # `MoneyFilterValue.parse` raises `ArgumentError` on malformed amounts
      # or unknown currency tickers; this builder rewraps those as
      # `MoneyFilterError` so `Document::List.call` returns a 422 rather
      # than a 500. A `__between` whose bounds mix currencies is also
      # rejected with 422 (ambiguous as a filter).
      def self.money_clauses(
        money_filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        money_filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          next unless money_field?(definition, field)

          n = base_offset + params.size + 1

          clause, vals = case op_suffix
                         when "currency"
                           money_currency_clause(field, value, n)
                         when "eq", "gt", "gte", "lt", "lte"
                           money_value_clause(field, op_suffix, value, n)
                         when "between"
                           money_between_clause(field, value, base_offset + params.size)
                         else
                           next
                         end
          next if clause.nil?
          clauses << clause
          params.concat(vals)
        end

        {clauses, params}
      end

      # Builds SQL where-clause fragments for filters on `array` container
      # fields. The LHS is `content->'field'` (JSONB-direct, not the
      # `content->>'field'` text-extract), matched by the `gin_jsonb` index.
      #
      # Operator semantics:
      # - `tags__contains: "foo"`         → `content->'tags' @> $n::jsonb` with bound `'["foo"]'`.
      # - `tags__eq: "foo"`                → alias of `tags__contains` (single-element).
      # - `tags__overlaps: ["a","b"]`     → `content->'tags' && $n::jsonb` with bound `'["a","b"]'`.
      # - `tags__contains: ["a","b"]`     → multi-element contains: `content->'tags' @> $n::jsonb` ("tags contains all of these").
      #
      # The bound value is always a JSON-encoded array string, parameterised
      # so the field name (validated as an identifier upstream by `FilterSet`
      # / known-fields routing) is the only interpolated token. Malformed
      # filter values (non-string / non-array) degrade to `FALSE` rather
      # than raising — same contract as `range_clauses` / `money_clauses`.
      def self.container_clauses(
        container_filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        container_filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          next unless container_field?(definition, field)

          json_arr = container_bound_array(value)
          if json_arr.nil?
            clauses << "FALSE"
            next
          end

          n = base_offset + params.size + 1
          case op_suffix
          when "eq", "contains"
            # `__eq` is a single-element alias of `__contains`: the stored
            # array must contain the given element (or all of the given
            # elements for the multi-element form).
            clauses << "content->'#{field}' @> $#{n}::jsonb"
            params << json_arr
          when "overlaps"
            # `&&` — the stored array shares at least one element with the
            # bound array.
            clauses << "content->'#{field}' && $#{n}::jsonb"
            params << json_arr
          else
            # Operator not handled here — drop (the routing layer already
            # restricted the suffix set, but stay defensive).
            next
          end
        end

        {clauses, params}
      end

      # Builds SQL where-clause fragments for comparison operators
      # (`__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`, `__between`,
      # `__in`) on `integer` / `duration` (`jsonb_as_numeric`) and
      # `boolean` (`jsonb_as_boolean`) fields.
      #
      # Unlike the schema-agnostic `FilterSet` (which extracts via
      # `content->>'field'` and selects its cast from the *bound value's*
      # runtime type — collapsing query-string string values to text
      # comparison), this builder reads the JSONB value directly
      # (`content->'field'`) and routes it through the IMMUTABLE helpers
      # selected from the doctype field declaration. The bound value is
      # coerced to the matching SQL type on the parameter side, so passing
      # a string (`"100"`) or a number (`20_i64`) yields the same numeric
      # comparison.
      #
      # Malformed `__between` values (non-array or wrong arity) degrade to
      # `FALSE` rather than raising — same contract as `FilterSet` and the
      # range filter builder: a bad filter is a no-match, not a 500.
      def self.typed_clauses(
        typed_filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        typed_filters.each do |key, value|
          field, op_suffix = Util::FilterSet.parse_filter_key(key)
          helper = typed_field_type(definition, field)
          next if helper.nil?

          cast_suffix = helper == "jsonb_as_numeric" ? "::numeric" : "::boolean"
          lhs = "#{helper}(content->'#{field}')"

          if op_suffix == "in"
            arr = value.as_a?
            if arr.nil? || arr.empty? || arr.size > Util::FilterSet::MAX_IN_VALUES
              clauses << "FALSE"
              next
            end
            n = base_offset + params.size + 1
            placeholders = arr.map_with_index { |_, i| "$#{n + i}#{cast_suffix}" }
            clauses << "#{lhs} = ANY(ARRAY[#{placeholders.join(", ")}])"
            arr.each { |el| params << Util.bind_scalar(el.raw) }
          elsif op_suffix == "between"
            arr = value.as_a?
            if arr.nil? || arr.size != 2
              clauses << "FALSE"
              next
            end
            n = base_offset + params.size + 1
            lo = Util.bind_scalar(arr[0].raw)
            hi = Util.bind_scalar(arr[1].raw)
            clauses << "#{lhs} BETWEEN $#{n}#{cast_suffix} AND $#{n + 1}#{cast_suffix}"
            params.concat([lo, hi] of ::DB::Any)
          elsif op_suffix == "ne"
            # `ne` is not in `Util::SQLOPS` (the scalar path handles it with
            # `IS DISTINCT FROM`). Keep the same numeric semantics on the
            # typed LHS.
            n = base_offset + params.size + 1
            clauses << "#{lhs} IS DISTINCT FROM $#{n}#{cast_suffix}"
            params << Util.bind_scalar(value.raw)
          else
            # Explicit no-match policy: an unknown comparison suffix is a
            # skip, never a silent widening (see `Util::SQLOPS`).
            sql_op = Util::SQLOPS.lookup(op_suffix)
            next unless sql_op
            n = base_offset + params.size + 1
            clauses << "#{lhs} #{sql_op} $#{n}#{cast_suffix}"
            params << Util.bind_scalar(value.raw)
          end
        end

        {clauses, params}
      end

      # Builds SQL where-clause fragments for range filters on `period` /
      # `dateperiod` fields. Each filter key has one of the suffixes
      # `__eq`, `__contains`, `__overlaps`, `__within`; the LHS is a
      # PostgreSQL range expression over the stored `{start, end}` object;
      # the RHS is a parameterised literal cast to the same range type.
      #
      # The operator determines the PG operator:
      # - `eq`       → `=`
      # - `contains` → `@>`
      # - `overlaps` → `&&`
      # - `within`   → `<@`
      #
      # Parameter ordering: this method receives the current `base_offset`
      # (number of params already accumulated), and emits `$N` placeholders
      # starting at `base_offset + 1`.
      #
      # The RHS value can be:
      # - a single ISO string (point): wrapped as `tstzrange(v, v, '[]')` /
      #   `daterange(v, v, '[]')` for contains/within (point containment).
      # - a two-element array `[start, end]` (interval): wrapped as the
      #   same range type with the field's bound convention.
      #
      # `overlaps` and `within` always take an interval; a single-point
      # value under those operators degrades to always-false.
      def self.range_clauses(
        range_filters : Hash(String, JSON::Any),
        definition : Doctype::DoctypeDefinition,
        base_offset : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any

        range_filters.each do |key, value|
          n = base_offset + params.size + 1
          clause, vals = single_range_clause(key, value, definition, n)
          if clause.nil?
            next
          elsif vals.empty? && clause == "FALSE"
            clauses << "FALSE"
          else
            clauses << clause
            params.concat(vals)
          end
        end

        {clauses, params}
      end

      # ── Private ────────────────────────────────────────────────────────

      # Builds the `__currency` clause (text equality on the stored ticker).
      # Raises `MoneyFilterError` on an unregistered ticker.
      private def self.money_currency_clause(field : String, value : JSON::Any, n : Int32) : {String, Array(::DB::Any)}
        ticker = value.as_s? || value.raw.to_s
        unless Util::Currency.registered?(ticker)
          raise MoneyFilterError.new("unknown currency '#{ticker}' in price filter")
        end
        {"content#>>'{#{field},currency}' = $#{n}", [ticker] of ::DB::Any}
      end

      # Builds a numeric-compare value clause (`eq`/`gt`/`gte`/`lt`/`lte`).
      # Optionally adds a `currency = $ccy` predicate when the value carries a
      # `<CCY> ` prefix.
      private def self.money_value_clause(
        field : String,
        op_suffix : String,
        value : JSON::Any,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        # Money ops are pre-gated by the compiler layer (field-type
        # routing, scope authoring); an unknown suffix here is a programming
        # error, so the strict entry point raises (see `Util::SQLOPS`).
        sql_op = Util::SQLOPS.for(op_suffix)
        parsed = parse_money_filter_value(value)
        clause = "facet_money_value_as_numeric(content->'#{field}') #{sql_op} $#{n}::numeric"
        vals = [parsed.amount.to_s] of ::DB::Any
        if ccy = parsed.currency
          clause += " AND content#>>'{#{field},currency}' = $#{n + 1}"
          vals << ccy
        end
        {clause, vals}
      end

      # Builds a `__between` clause. Returns `{nil, []}` to signal
      # "degrade to FALSE" on malformed (non-2-element) bounds; raises
      # `MoneyFilterError` on mixed-currency bounds. When the bounds share a
      # currency prefix, an `AND currency = $ccy` predicate is appended.
      private def self.money_between_clause(
        field : String,
        value : JSON::Any,
        offset : Int32,
      ) : {String?, Array(::DB::Any)}
        arr = value.as_a?
        if arr.nil? || arr.size != 2
          # Malformed bounds degrade to FALSE (mirrors FilterSet).
          return {"FALSE", [] of ::DB::Any}
        end
        lo = parse_money_filter_value(arr[0])
        hi = parse_money_filter_value(arr[1])
        if lo.currency != hi.currency
          raise MoneyFilterError.new("money __between bounds must share the same currency")
        end
        n_lo = offset + 1
        clause = "facet_money_value_as_numeric(content->'#{field}') BETWEEN $#{n_lo}::numeric AND $#{n_lo + 1}::numeric"
        vals = [lo.amount.to_s, hi.amount.to_s] of ::DB::Any
        if ccy = lo.currency
          clause += " AND content#>>'{#{field},currency}' = $#{n_lo + 2}"
          vals << ccy
        end
        {clause, vals}
      end

      # Parses a single money filter value, wrapping `MoneyFilterValue.parse`
      # errors into `MoneyFilterError` so the caller re-raises a typed
      # exception the service layer turns into a 422.
      private def self.parse_money_filter_value(value : JSON::Any) : Util::MoneyFilterValue
        case raw = value.raw
        when String, Int64, Float64
          Util::MoneyFilterValue.parse(raw)
        else
          # Objects / arrays / booleans are not valid money filter values.
          raise MoneyFilterError.new("money filter value must be a string or number (got '#{raw.inspect}')")
        end
      rescue ex : ArgumentError
        raise MoneyFilterError.new(ex.message.to_s)
      end

      # `{nil, []}` if the operator is not a range operator; `{"FALSE", []}`
      # if the value shape doesn't match the operator's expectation.
      private def self.single_range_clause(
        key : String,
        value : JSON::Any,
        definition : Doctype::DoctypeDefinition,
        n : Int32,
      ) : {String?, Array(::DB::Any)}
        field, op_suffix = Util::FilterSet.parse_filter_key(key)
        range_kind = range_field_type(definition, field)
        return {nil, [] of ::DB::Any} if range_kind.nil?

        cast_type, range_ctor, bounds, ctor_fn =
          if range_kind == "tstzrange"
            {"timestamptz", "tstzrange", "'[)'", "facet_tstzrange"}
          else
            {"date", "daterange", "'[]'", "facet_daterange"}
          end

        # LHS range expression over the stored `{start, end}` object.
        # Uses the IMMUTABLE helper (`facet_tstzrange` / `facet_daterange`)
        # to match the GiST index expression byte-for-byte — PostgreSQL's
        # planner matches on the parsed expression tree, so using the raw
        # `tstzrange(...)` constructor here would NOT use the index. The
        # wrapper takes text arguments and casts internally.
        lhs = "#{ctor_fn}(content#>>'{#{field},start}', content#>>'{#{field},end}')"

        case op_suffix
        when "contains"
          rhs, vals = contains_rhs(value, range_ctor, cast_type, bounds, n)
          {"#{lhs} @> #{rhs}", vals}
        when "eq", "overlaps", "within"
          sql_op = {"eq" => "=", "overlaps" => "&&", "within" => "<@"}[op_suffix]
          rhs, vals = interval_rhs(value, range_ctor, cast_type, bounds, n)
          if rhs.nil?
            {"FALSE", [] of ::DB::Any}
          else
            {"#{lhs} #{sql_op} #{rhs}", vals}
          end
        else
          {nil, [] of ::DB::Any}
        end
      end

      # Builds the RHS range expression for `contains`: either a point
      # (single ISO string value cast to the inner type) or an interval
      # (two-element array wrapped in the same range constructor).
      private def self.contains_rhs(
        value : JSON::Any,
        range_ctor : String,
        cast_type : String,
        bounds : String,
        n : Int32,
      ) : {String, Array(::DB::Any)}
        if arr = value.as_a?
          if arr.size == 2
            # interval contains point/interval — use the range constructor.
            lo = arr[0].raw.to_s
            hi = arr[1].raw.to_s
            clause = "#{range_ctor}($#{n}::#{cast_type}, $#{n + 1}::#{cast_type}, #{bounds})"
            return {clause, [lo, hi] of ::DB::Any}
          end
          return {"FALSE", [] of ::DB::Any}
        end

        # Single point — cast the scalar directly to the inner type.
        # PostgreSQL supports `range @> element` natively.
        v = value.raw.to_s
        {"$#{n}::#{cast_type}", [v] of ::DB::Any}
      end

      # Builds the RHS interval range for `eq`, `overlaps`, and `within`.
      # The value must be a two-element `[start, end]` array; any other
      # shape degrades to always-false (returns nil — caller emits FALSE).
      private def self.interval_rhs(
        value : JSON::Any,
        range_ctor : String,
        cast_type : String,
        bounds : String,
        n : Int32,
      ) : {String?, Array(::DB::Any)}
        arr = value.as_a?
        return {nil, [] of ::DB::Any} if arr.nil? || arr.size != 2

        lo = arr[0].raw.to_s
        hi = arr[1].raw.to_s
        {"#{range_ctor}($#{n}::#{cast_type}, $#{n + 1}::#{cast_type}, #{bounds})", [lo, hi] of ::DB::Any}
      end

      # Coerces a raw filter value to a JSON-encoded array string for
      # binding as `::jsonb`. Accepts:
      # - a single scalar (string / number / bool) → `[value]`.
      # - an array of scalars                         → the array verbatim.
      # Returns `nil` to signal "degrade to FALSE" for shapes that have no
      # meaningful containment semantics (objects / `nil` / nested arrays).
      private def self.container_bound_array(value : JSON::Any) : String?
        case raw = value.raw
        when String, Int64, Float64, Bool
          encode_json_array([value])
        when Array(JSON::Any)
          # Reject nested arrays and objects — `@>` / `&&` over a
          # heterogeneous array would silently match on JSONB structure
          # rather than element membership, which is not what array-string
          # `membership` promises. Degrade to FALSE instead.
          return nil unless raw.all? { |item| scalar_json_any?(item) }
          encode_json_array(raw)
        else
          nil
        end
      end

      # Encodes an array of `JSON::Any` scalars as a JSON array string for
      # binding as `::jsonb`. Uses `JSON::Any#to_json` on each element so
      # the per-value serializer handles the concrete type (string / int /
      # float / bool / nil) — `JSON::Builder#scalar` does not accept the
      # `Int` union so we route through the typed `JSON::Any` path.
      private def self.encode_json_array(values : Array(JSON::Any)) : String
        JSON.build do |json|
          json.array do
            values.each(&.to_json(json))
          end
        end
      end

      # Returns true when a `JSON::Any` holds a bindable scalar (string,
      # number, bool, or `nil`). Used by `container_bound_array` to
      # reject nested containers before binding them as a `gin_jsonb`
      # containment operand.
      private def self.scalar_json_any?(value : JSON::Any) : Bool
        case value.raw
        when String, Int64, Float64, Bool, Nil
          true
        else
          false
        end
      end
    end
  end
end
