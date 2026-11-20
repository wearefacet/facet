# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./identifier"
require "./like_escape"
require "./sql_ops"
require "./bind_scalar"

module Facet
  module Util
    # Composable SQL filter-set builder for document queries.
    #
    # Takes a hash of filter keys (with `__op` suffixes) and produces
    # WHERE clause fragments that can be AND‑combined with other sets.
    # This enables composition of user-supplied filters with system-level
    # filters (e.g. RBAC scope restrictions).
    #
    # Schema-agnostic by contract: the cast for comparison operators
    # (`__gt`, `__gte`, `__lt`, `__lte`, `__between`) is selected from the
    # *bound value's* runtime JSON type, not from any doctype definition.
    # Callers that have the doctype definition in scope (notably
    # `Document::List`) MUST intercept comparison ops on `integer` / `money`
    # / `boolean` fields and route them through type-aware `jsonb_as_*`
    # helpers instead — otherwise query-string filters (always parsed as
    # `JSON::Any(String)`) collapse to lexicographic text comparison.
    # See `Document::List#build_typed_clauses`.
    #
    # Text-based operators (`__eq`, `__ne`, `__match`, `__starts_with`) and
    # comparison ops on
    # text-typed fields (`string`, `date`, `datetime`, …) are correct here
    # as text comparison.
    #
    # ```
    # set = Facet::Util::FilterSet.new({"name__eq" => JSON::Any.new("Alice")})
    # set.to_sql # => "content->>'name' = $1"
    # ```
    class FilterSet
      # The maximum number of entries one `__in` filter may carry. A longer
      # array degrades to `FALSE` here (backstop for the REST path); the
      # agent surfaces raise `InvalidParams` instead so the caller learns
      # the bound.
      MAX_IN_VALUES = 100

      # The individual SQL clause fragments (one per filter key).
      getter clauses : Array(String)
      # The accumulated parameter values for the clause fragments.
      getter values : Array(::DB::Any)

      # Build a set from a raw filter hash (as parsed from HTTP).
      #
      # *offset* — the starting `$N` number (default 0 means `$1`, `$2`, …).
      def initialize(filters : Hash(String, JSON::Any), offset : Int32 = 0)
        @clauses = [] of String
        @values = [] of ::DB::Any
        filters.each do |key, value|
          clause, vals = self.class.build_clause(key, value, @values.size + offset)
          @clauses << clause
          @values.concat(vals)
        end
      end

      # Internal constructor that accepts pre-built clauses and values (used by `+`).
      protected def initialize(@clauses : Array(String), @values : Array(::DB::Any))
      end

      # Returns `true` when no filters were provided.
      def empty? : Bool
        @clauses.empty?
      end

      # Returns the combined SQL fragment.
      # Returns an empty string when no filters are present.
      def to_sql : String
        @clauses.join(" AND ")
      end

      # Combines two FilterSets with AND, merging their clauses and values.
      def +(other : FilterSet) : FilterSet
        FilterSet.new(@clauses + other.clauses, @values + other.values)
      end

      # ── Clause building ─────────────────────────────────────────────────

      # Builds a single SQL WHERE clause fragment from a filter key and value.
      #
      # The key can include an operator suffix (e.g. `age__gte`).
      # Returns a `{String, Array(::DB::Any)}` tuple — the SQL fragment with
      # `$N` placeholder(s) and the raw value(s) to bind. Most operators emit a
      # single value; `between` emits two (`$N` and `$(N+1)`).
      #
      # For ordering-sensitive operators (`gt`, `gte`, `lt`, `lte`, `between`),
      # the SQL cast is chosen based on the *actual JSON value type* — not a
      # blanket `::text` — so that `100 >= 9` evaluates correctly as a numeric
      # comparison rather than alphabetically (`"100" >= "9"` → false).
      def self.build_clause(key : String, value : JSON::Any, idx : Int32) : {String, Array(::DB::Any)}
        field, op = parse_filter_key(key)
        n = idx + 1

        # Guard against SQL injection via the field name. Filter keys are
        # user-supplied via the HTTP query layer; `Document::List` already
        # restricts them to known doctype fields, but FilterSet must not trust
        # its caller — fail closed on any non-identifier field name.
        Identifier.validate!(field, "FilterSet field")

        if op == "between"
          return build_between_clause(field, value, n)
        end

        if op == "in"
          return build_in_clause(field, value, n)
        end

        val = Util.bind_scalar(value.raw)

        clause = case op
                 when "eq", "ne"
                   # Equality and inequality work correctly as text across
                   # all types — no cast needed.
                   lhs = "content->>'#{field}'"
                   case op
                   when "eq" then "#{lhs} = $#{n}"
                   when "ne" then "#{lhs} IS DISTINCT FROM $#{n}"
                   else           "#{lhs} = $#{n}" # unreachable
                   end
                 when "match", "starts_with"
                   # Text-pattern operators. The user value is escaped and
                   # wrapped so % and _ in the input never act as ILIKE
                   # wildcards. `match` = contains substring (%term%);
                   # `starts_with` = prefix (term%). The bound parameter is
                   # the escaped value; the SQL concatenates the literal %
                   # wrappers around it (trigram planners constant-fold the
                   # concatenation into a usable GIN search key).
                   lhs = "content->>'#{field}'"
                   case op
                   when "match"       then "#{lhs} ILIKE '%' || $#{n} || '%' ESCAPE '\\'"
                   when "starts_with" then "#{lhs} ILIKE $#{n} || '%' ESCAPE '\\'"
                   else                    "#{lhs} = $#{n}" # unreachable
                   end
                 else
                   # Comparison operators — use a type-appropriate cast based on
                   # the filter value's actual type, not a blanket `::text`.
                   # Unknown operator suffix — never widen it to `=` (see
                   # `Util::SQLOPS` for the no-match policy): a bad filter
                   # matches nothing, it does not silently become equality.
                   sql_op = Util::SQLOPS.lookup(op)
                   return {"FALSE", [] of ::DB::Any} if sql_op.nil?

                   extract, cast = sql_extract_and_cast(field, value.raw)
                   "#{extract} #{sql_op} $#{n}#{cast}"
                 end

        # For match/starts_with the bound param is the escaped value;
        # for everything else it stays the raw `val`.
        bound = op.in?("match", "starts_with") ? LikeEscape.escape(val.to_s) : val
        {clause, [bound] of ::DB::Any}
      end

      # Builds an `ANY` membership clause from a JSON array value —
      # `content->>'field' = ANY(ARRAY[$n, $n+1, …])`. One placeholder per
      # entry keeps every value a bind parameter. Malformed values
      # (non-array, empty, over `MAX_IN_VALUES`) degrade to an always-false
      # clause rather than raising — a bad filter is a no-match, not a 500.
      # The agent surfaces reject over-long arrays with `InvalidParams`
      # before the service runs.
      private def self.build_in_clause(field : String, value : JSON::Any, n : Int32) : {String, Array(::DB::Any)}
        arr = value.as_a?
        return {"FALSE", [] of ::DB::Any} if arr.nil? || arr.empty? || arr.size > MAX_IN_VALUES

        placeholders = arr.map_with_index { |_, i| "$#{n + i}" }
        clause = "content->>'#{field}' = ANY(ARRAY[#{placeholders.join(", ")}])"
        vals = [] of ::DB::Any
        arr.each { |el| vals << Util.bind_scalar(el.raw) }
        {clause, vals}
      end

      # Builds a `between` clause (inclusive range) from a two-element array
      # value `[start, end]`. Both bounds share the same type-appropriate cast
      # so that numeric, datetime, and text comparisons are consistent.
      #
      # Malformed values (wrong length, non-array) degrade to an always-false
      # clause rather than raising — a bad filter should not 500 the request.
      private def self.build_between_clause(field : String, value : JSON::Any, n : Int32) : {String, Array(::DB::Any)}
        arr = value.as_a?
        if arr.nil? || arr.size != 2
          return {"FALSE", [] of ::DB::Any}
        end

        lo_raw = arr[0].raw
        hi_raw = arr[1].raw
        extract, cast = sql_extract_and_cast(field, lo_raw)
        lo = Util.bind_scalar(lo_raw)
        hi = Util.bind_scalar(hi_raw)

        clause = "#{extract} BETWEEN $#{n}#{cast} AND $#{n + 1}#{cast}"
        {clause, [lo, hi] of ::DB::Any}
      end

      # Returns the SQL extract expression and optional `::type` cast suffix
      # appropriate for the given raw value type.
      #
      # All expressions use `content->>'field'` (text extraction) as the base,
      # matching the B-tree index expression from `Index::Naming.access_expression`.
      # The cast is applied on top so PostgreSQL can still use the index
      # (the `text::type` casts are immutable).
      #
      # - `Int64`   → `(content->>'field')::bigint`
      # - `Float64` → `(content->>'field')::numeric`
      # - `Bool`    → `(content->>'field')::boolean`
      # - Default   → `content->>'field'` (text, no cast needed)
      private def self.sql_extract_and_cast(field : String, raw : (Array(JSON::Any) | Bool | Float64 | Hash(String, JSON::Any) | Int64 | String?)) : {String, String}
        case raw
        when Int64
          {"(content->>'#{field}')::bigint", "::bigint"}
        when Float64
          {"(content->>'#{field}')::numeric", "::numeric"}
        when Bool
          {"(content->>'#{field}')::boolean", "::boolean"}
        else
          # String, Nil, etc. — text comparison is correct
          {"content->>'#{field}'", ""}
        end
      end

      # Parses a filter key like `"salary__gt"` into `{"salary", "gt"}`.
      def self.parse_filter_key(key : String) : {String, String}
        if key.includes?("__")
          parts = key.split("__", 2)
          {parts[0], parts[1]}
        else
          {key, "eq"}
        end
      end
    end
  end
end
