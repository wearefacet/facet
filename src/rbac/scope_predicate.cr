# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../util/filter_set"
require "../util/like_escape"
require "../util/identifier"
require "../util/filter_clauses"
require "../doctype/operator"
require "./scope_value"
require "./scope_context"

module Facet
  module RBAC
    # A parsed predicate entry from a scope/context-set `where` clause.
    #
    # Field side: `field` is the bare field name; `operator` is the
    # `Doctype::Operator` derived from a `__op` suffix on the key (defaults
    # to `Eq` when no suffix is present). Value side: a `ScopeValue`, which
    # may be a literal, `$self`, `$null`, `$organizational_unit`, or a
    # `$<context_set>` reference.
    #
    # The reserved field token `$parent_id` round-trips through the parser:
    # it contains no `__` separator, so `Util::FilterSet.parse_filter_key`
    # returns `{"$parent_id", "eq"}`.
    struct ScopePredicate
      getter field : String
      getter operator : Doctype::Operator
      getter value : ScopeValue

      def initialize(@field : String, @operator : Doctype::Operator, @value : ScopeValue)
      end
    end

    # Parses a `where` map (field → raw string value) into predicates.
    # Shared by ScopeExpander (content match), ContextResolver (SQL
    # resolution), and the authoring-time validator.
    module ScopePredicateParser
      PARENT_ID_FIELD = "$parent_id"

      # Reserved field token reading the row's own id (`projections.id`).
      # Needed because a document's identity sometimes lives on the row and
      # not in content — a `core.Domain` row's domain name IS its id. Valid
      # only with `eq`/`ne` (the id is a string), enforced at authoring time.
      DOC_ID_FIELD = "$doc_id"

      def self.parse_where(where : Hash(String, String)) : Array(ScopePredicate)
        where.map do |raw_key, raw_value|
          bare_field, op_name = Util::FilterSet.parse_filter_key(raw_key)
          operator = Doctype::Operator.parse(op_name)
          value = ScopeValue.parse(raw_value)
          ScopePredicate.new(bare_field, operator, value)
        end
      end
    end

    # Compiles parsed `ScopePredicate`s into SQL WHERE fragments against the
    # `projections` table. This is the single owner of scope → SQL
    # compilation: it serves `ReadEnforcer` (named-scope list path) and
    # `ContextResolver` (context-set resolution), and exposes the scalar and
    # LHS helpers that `ScopeMatcher` reuses for the in-process match path.
    # All authorization surfaces therefore implement the same operator
    # semantics.
    #
    # LHS: a normal field reads `content->>'field'`; the reserved
    # `$parent_id` token reads the system-managed parent linkage at
    # `meta->>'parent_id'`; the reserved `$doc_id` token reads the row's own
    # `projections.id` column. The field name is validated with
    # `Util::Identifier.validate!` before interpolation (fail closed).
    #
    # Comparison / range / currency operators delegate to the shared
    # `Util::FilterClauses` builders, which need the target doctype
    # definition to pick the type-aware LHS/cast. `definition` is optional:
    # when absent (or when the field is unknown on the definition), those
    # operators degrade to an unsatisfiable clause rather than guessing a
    # text comparison.
    #
    # Dispatch for the type-aware builders is field-driven, in this order:
    # a range operator (`contains`/`overlaps`/`within`) routes to
    # `range_clauses`; then a `money` FIELD routes to `money_clauses` (which
    # covers the `currency` operator and numeric comparisons on the money
    # value member); then a typed field (integer/duration/boolean) routes to
    # `typed_clauses`; anything else falls back to a text ordering
    # comparison for gt/gte/lt/lte, `FALSE` for every other operator.
    # Field-driven routing (not operator-driven) is what makes `price__gt`
    # on a money field compare the numeric `value` member — routing by
    # `operator.currency?` alone would misroute gt/lte on money fields to a
    # text comparison over the raw JSONB object.
    #
    # Fail-closed contract for `$<context_set>`: `Eq` against an empty or
    # missing set emits `1=0`; `Ne` and the pattern operators emit `FALSE`.
    # A missing set (undefined name, unresolved dependency) is treated as
    # an empty set. For `Ne` this is deliberate: "not in an empty set" is
    # vacuously true for every row, and emitting that would widen access
    # when a dependency fails to resolve.
    module ScopePredicateSql
      # Builds the AND-combined SQL fragment for a predicate list.
      #
      # Returns `{clause, params, next_idx}` where `clause` is `nil` for an
      # empty predicate list (matches every row) and `next_idx` is the
      # placeholder index after the last bound parameter.
      def self.build_clauses(
        predicates : Array(ScopePredicate),
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        start_idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        return {nil, [] of ::DB::Any, start_idx} if predicates.empty?

        fragments = [] of String
        params = [] of ::DB::Any
        idx = start_idx

        predicates.each do |predicate|
          clause, clause_params, idx = build_clause(
            predicate, scope_context, context_results, idx, definition,
          )
          if clause
            fragments << clause
            params.concat(clause_params)
          end
        end

        {fragments.join(" AND "), params, idx}
      end

      # Builds the SQL fragment for a single predicate. Returns `nil` to
      # signal "no clause" (degenerate shapes degrade to `FALSE` instead of
      # widening the result set — never fail open).
      private def self.build_clause(
        predicate : ScopePredicate,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        lhs = field_expr(predicate.field)
        sv = predicate.value

        case predicate.operator
        when .eq?
          eq_clause(lhs, sv, scope_context, context_results, idx, definition)
        when .ne?
          ne_clause(lhs, sv, scope_context, context_results, idx, definition)
        when .match?, .starts_with?
          pattern_clause(lhs, predicate.operator, sv, scope_context, context_results, idx)
        else
          # Comparison / range / currency operators — type-aware builders.
          comparison_clause(predicate, lhs, idx, definition)
        end
      end

      # ── Per-operator emitters ─────────────────────────────────────────

      private def self.eq_clause(
        lhs : String,
        sv : ScopeValue,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        case sv.type
        when ScopeValueType::Literal, ScopeValueType::OrganizationalUnit
          {"#{lhs} = $#{idx}", [resolve_scalar(sv, scope_context)] of ::DB::Any, idx + 1}
        when ScopeValueType::Self
          self_eq_clause(lhs, scope_context, idx)
        when ScopeValueType::Null
          {"#{lhs} IS NULL", [] of ::DB::Any, idx}
        when ScopeValueType::ContextSet
          context_set_eq(lhs, sv, context_results, idx)
        else
          {"FALSE", [] of ::DB::Any, idx}
        end
      end

      private def self.ne_clause(
        lhs : String,
        sv : ScopeValue,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        case sv.type
        when ScopeValueType::Literal, ScopeValueType::OrganizationalUnit
          # `IS DISTINCT FROM` also matches rows where the field is absent
          # (SQL NULL) — "not equal" includes "not set".
          {"#{lhs} IS DISTINCT FROM $#{idx}", [resolve_scalar(sv, scope_context)] of ::DB::Any, idx + 1}
        when ScopeValueType::Self
          self_ne_clause(lhs, scope_context, idx)
        when ScopeValueType::Null
          # Negation of the Eq-Null path: the field must be present and
          # non-null.
          {"#{lhs} IS NOT NULL", [] of ::DB::Any, idx}
        when ScopeValueType::ContextSet
          name = sv.context_set_name
          values = context_results[name]? || [] of String
          if values.empty?
            # Not in an empty set is vacuously true for every row — but a
            # missing or unresolved set must not widen access. Fail closed:
            # no rows.
            {"FALSE", [] of ::DB::Any, idx}
          else
            clause = "NOT (#{lhs} = ANY(string_to_array($#{idx}, ',')))"
            {clause, [values.join(",")] of ::DB::Any, idx + 1}
          end
        else
          {"FALSE", [] of ::DB::Any, idx}
        end
      end

      private def self.pattern_clause(
        lhs : String,
        operator : Doctype::Operator,
        sv : ScopeValue,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        idx : Int32,
      ) : {String?, Array(::DB::Any), Int32}
        wrapper = operator.match? ? "'%' || $#{idx} || '%'" : "$#{idx} || '%'"

        case sv.type
        when ScopeValueType::Literal, ScopeValueType::OrganizationalUnit
          # The resolved scalar is LIKE-escaped: `%` / `_` in the value are
          # matched literally, never as wildcards (same contract as
          # `Util::FilterSet`).
          bound = Util::LikeEscape.escape(resolve_scalar(sv, scope_context))
          {"#{lhs} ILIKE #{wrapper} ESCAPE '\\'", [bound] of ::DB::Any, idx + 1}
        when ScopeValueType::Self
          self_pattern_clause(lhs, operator, scope_context, idx)
        when ScopeValueType::ContextSet
          # Membership over resolved dependency values, matched as a pattern:
          # EXISTS over the unnested value list keeps a single bound
          # parameter for the comma-joined string.
          name = sv.context_set_name
          values = context_results[name]? || [] of String
          if values.empty?
            {"FALSE", [] of ::DB::Any, idx}
          else
            clause = "EXISTS (SELECT 1 FROM unnest(string_to_array($#{idx}, ',')) AS v WHERE #{lhs} ILIKE #{wrapper} ESCAPE '\\')"
            {clause, [values.join(",")] of ::DB::Any, idx + 1}
          end
        when ScopeValueType::Null
          # `$null` is only valid with Eq — reject at runtime too.
          {"FALSE", [] of ::DB::Any, idx}
        else
          {"FALSE", [] of ::DB::Any, idx}
        end
      end

      private def self.comparison_clause(
        predicate : ScopePredicate,
        lhs : String,
        idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        sv = predicate.value
        # Literal RHS only — the authoring-time validator restricts
        # `$<context_set>` to Eq/Ne/Match/StartsWith, and comparison
        # semantics on `$null` / `$self` / `$organizational_unit` are not
        # defined. Fail closed.
        return {"FALSE", [] of ::DB::Any, idx} unless sv.type == ScopeValueType::Literal

        # `$parent_id` and `$doc_id` resolve to system columns/links, which
        # the FilterClauses builders cannot target (their LHS is derived
        # from the doctype definition). The validator restricts both tokens
        # to Eq/Ne; anything reaching here is a fail-closed degradation.
        return {"FALSE", [] of ::DB::Any, idx} if predicate.field == ScopePredicateParser::PARENT_ID_FIELD
        return {"FALSE", [] of ::DB::Any, idx} if predicate.field == ScopePredicateParser::DOC_ID_FIELD

        defn = definition
        return {"FALSE", [] of ::DB::Any, idx} if defn.nil?

        key = "#{predicate.field}#{predicate.operator.suffix}"
        filters = {key => JSON::Any.new(sv.raw)}

        clauses, params = dispatch_filter_clauses(predicate, sv, lhs, idx, defn, filters)

        if clauses.empty?
          {"FALSE", [] of ::DB::Any, idx}
        else
          {clauses.join(" AND "), params, idx + params.size}
        end
      end

      # Routes a comparison predicate to the matching `FilterClauses` builder
      # (range → money → typed → text fallback), in that priority order.
      private def self.dispatch_filter_clauses(
        predicate : ScopePredicate,
        sv : ScopeValue,
        lhs : String,
        idx : Int32,
        defn : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
      ) : {Array(String), Array(::DB::Any)}
        if predicate.operator.range?
          Util::FilterClauses.range_clauses(filters, defn, idx - 1)
        elsif Util::FilterClauses.money_field?(defn, predicate.field)
          Util::FilterClauses.money_clauses(filters, defn, idx - 1)
        elsif Util::FilterClauses.typed_field_type(defn, predicate.field)
          Util::FilterClauses.typed_clauses(filters, defn, idx - 1)
        else
          text_comparison_clauses(predicate, sv, lhs, idx)
        end
      end

      # Text fallback for ordering operators on non-money, non-typed fields
      # (string / datetime / …). Correct for RFC-3339 datetimes stored
      # tz-naive UTC, and the stored contract for string ordering.
      # `Between` has no single-string representation, and a `currency`
      # operator on a non-money field has no comparable LHS — fail closed.
      private def self.text_comparison_clauses(
        predicate : ScopePredicate,
        sv : ScopeValue,
        lhs : String,
        idx : Int32,
      ) : {Array(String), Array(::DB::Any)}
        if predicate.operator.gt? || predicate.operator.gte? ||
           predicate.operator.lt? || predicate.operator.lte?
          {["#{lhs} #{comparison_sql_op(predicate.operator)} $#{idx}"] of String, [sv.raw] of ::DB::Any}
        else
          {[] of String, [] of ::DB::Any}
        end
      end

      # ── Helpers ───────────────────────────────────────────────────────

      # Maps an ordering operator to its SQL comparison form. Only
      # gt/gte/lt/lte reach this helper — the comparison fallback excludes
      # every other operator before calling it.
      private def self.comparison_sql_op(operator : Doctype::Operator) : String
        case operator
        when .gt?  then ">"
        when .gte? then ">="
        when .lt?  then "<"
        else            "<="
        end
      end

      # Resolves a Literal / OrganizationalUnit value to its bound string
      # form. Public because `ScopeMatcher` resolves the same RHS forms for
      # the in-process match path. `$self` is deliberately not resolved
      # here: a single scalar cannot represent it, because its predicate
      # clauses accept both stored principal forms (see `self_forms`).
      def self.resolve_scalar(sv : ScopeValue, scope_context : ScopeContext) : String
        case sv.type
        when ScopeValueType::OrganizationalUnit
          scope_context.organizational_unit
        else
          sv.raw
        end
      end

      # ── `$self` dual-form clauses ─────────────────────────────────────

      # The stored forms a `$self` predicate accepts (see
      # `RBAC.principal_forms`): the bare account id (a plain string field
      # holding `ctx.actor.id`) and the qualified `iam.Account.<id>`
      # reference form. Equality ORs across the pair, negation ANDs its
      # `IS DISTINCT FROM`s, and pattern operators OR their ILIKE
      # fragments.
      private def self.self_forms(scope_context : ScopeContext) : Array(String)
        RBAC.principal_forms(scope_context.account_id)
      end

      # `$self` equality: OR across both stored principal forms, so the
      # predicate matches a reference-typed owner field (qualified form)
      # and a plain string owner field (bare id) alike.
      private def self.self_eq_clause(lhs : String, scope_context : ScopeContext, idx : Int32) : {String, Array(::DB::Any), Int32}
        forms = self_forms(scope_context)
        if forms.size == 1
          {"#{lhs} = $#{idx}", [forms[0]] of ::DB::Any, idx + 1}
        else
          {"(#{lhs} = $#{idx} OR #{lhs} = $#{idx + 1})", [forms[0], forms[1]] of ::DB::Any, idx + 2}
        end
      end

      # `$self` negation: the field must differ from both stored forms.
      # `IS DISTINCT FROM` keeps absent-field (SQL NULL) rows matching —
      # "not equal" includes "not set".
      private def self.self_ne_clause(lhs : String, scope_context : ScopeContext, idx : Int32) : {String, Array(::DB::Any), Int32}
        forms = self_forms(scope_context)
        if forms.size == 1
          {"#{lhs} IS DISTINCT FROM $#{idx}", [forms[0]] of ::DB::Any, idx + 1}
        else
          {"(#{lhs} IS DISTINCT FROM $#{idx} AND #{lhs} IS DISTINCT FROM $#{idx + 1})", [forms[0], forms[1]] of ::DB::Any, idx + 2}
        end
      end

      # `$self` pattern operators: one LIKE-escaped bound parameter per
      # accepted form, OR-combined (the wrapper is match's `%v%` or
      # starts_with's `v%`).
      private def self.self_pattern_clause(
        lhs : String,
        operator : Doctype::Operator,
        scope_context : ScopeContext,
        idx : Int32,
      ) : {String, Array(::DB::Any), Int32}
        fragments = [] of String
        params = [] of ::DB::Any
        next_idx = idx
        self_forms(scope_context).each do |form|
          wrapper = operator.match? ? "'%' || $#{next_idx} || '%'" : "$#{next_idx} || '%'"
          fragments << "#{lhs} ILIKE #{wrapper} ESCAPE '\\'"
          params << Util::LikeEscape.escape(form)
          next_idx += 1
        end
        # Parenthesised: the fragments are OR-combined, and `build_clauses`
        # AND-joins predicate clauses without parens — unparenthesised, a
        # second predicate would bind to only the last ILIKE (`A OR B AND C`).
        {"(" + fragments.join(" OR ") + ")", params, next_idx}
      end

      private def self.context_set_eq(
        lhs : String,
        sv : ScopeValue,
        context_results : Hash(String, Array(String)),
        idx : Int32,
      ) : {String?, Array(::DB::Any), Int32}
        name = sv.context_set_name
        values = context_results[name]? || [] of String
        if values.empty?
          {"1=0", [] of ::DB::Any, idx}
        else
          {"#{lhs} = ANY(string_to_array($#{idx}, ','))", [values.join(",")] of ::DB::Any, idx + 1}
        end
      end

      # Builds the left-hand SQL expression for a predicate field.
      # `$parent_id` reads from `meta`, `$doc_id` reads the row id column;
      # any other value reads from `content`.
      #
      # The field name is validated against a SQL-safe identifier regex
      # before interpolation (defence in depth — fields are already
      # validated at authoring time, but fail closed here too). `label`
      # names the call surface in the validation error: named-scope
      # predicates, a context set's `where` field, or its `select` field.
      def self.field_expr(field : String, label : String = "Scope predicate field") : String
        if field == ScopePredicateParser::DOC_ID_FIELD
          "id"
        elsif field == ScopePredicateParser::PARENT_ID_FIELD
          "meta->>'parent_id'"
        else
          Util::Identifier.validate!(field, label, allow_parent_token: true)
          "content->>'#{field}'"
        end
      end
    end
  end
end
