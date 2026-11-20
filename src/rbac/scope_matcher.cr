# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../doctype/operator"
require "./scope_value"
require "./scope_context"
require "./scope_predicate"
require "../util/time_helper"

module Facet
  module RBAC
    # Shared predicate matching logic for enforcers.
    #
    # Evaluates a parsed `ScopePredicate` against a single projection's
    # field value in memory (the "in-process content match" path — the SQL
    # counterpart lives in `RBAC::ScopePredicateSql`). Both `ReadEnforcer`
    # and `WriteEnforcer` reach it through `ScopeExpander`.
    #
    # The RHS is resolved from the predicate's `ScopeValue`: a literal, the
    # actioner's account (`$self`, matched against both the bare id and the
    # fully qualified `iam.Account.<id>` reference form), the actioner's
    # organizational unit
    # (`$organizational_unit`, from the per-request `ScopeContext`), a
    # resolved context set (`$<name>`, membership), or `$null`.
    #
    # Per-operator behaviour mirrors the SQL surface (see
    # `RBAC::ScopePredicateSql`):
    #
    # | Operator | In-process behaviour |
    # |---|---|
    # | `Eq` | equality (`$self` matches both principal forms; `$organizational_unit`, context-set membership, `$null`) |
    # | `Ne` | negation of the `Eq` path |
    # | `Match` | case-insensitive substring (`%` / `_` are literal, never wildcards) |
    # | `StartsWith` | case-insensitive prefix |
    # | `Gt`/`Gte`/`Lt`/`Lte` | numeric, then datetime, then lexicographic comparison |
    # | `Contains` | array membership, or period `{start,end}` containment |
    # | `Currency` | money-object currency-member equality |
    #
    # `Between`, `Overlaps`, and `Within` have no single-string RHS
    # representation in the `where` grammar (the authoring-time validator
    # allows them on the field-type axis but the value grammar cannot
    # express two bounds); they degrade to `false` at runtime — defence in
    # depth behind the authoring gate.
    module ScopeMatcher
      # Checks whether a single parsed predicate matches an actual field
      # value. `actual` is the projection's JSON value for the predicate's
      # field; absence (missing key) is handled by the caller (`ScopeExpander`
      # short-circuits `$null` against absence before delegating, and treats
      # any other operator on an absent field as no-match).
      def self.match?(
        predicate : ScopePredicate,
        actual : JSON::Any,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
      ) : Bool
        op = predicate.operator
        sv = predicate.value

        # `$null` is only meaningful with Eq/Ne (authoring gate); if it
        # reaches here with any other operator, degrade to `false`.
        return null_matches?(op, actual) if sv.type == ScopeValueType::Null

        return eq_matches?(sv, actual, scope_context, context_results) if op.eq?
        return !eq_matches?(sv, actual, scope_context, context_results) if op.ne?
        return text_op?(sv, actual, scope_context, context_results) { |a, r| a.includes?(r) } if op.match?
        return text_op?(sv, actual, scope_context, context_results) { |a, r| a.starts_with?(r) } if op.starts_with?
        return comparison_matches?(op, sv, actual) if comparison_op?(op)
        return contains_matches?(sv, actual) if op.contains?
        return currency_matches?(sv, actual) if op.currency?

        # Between / Overlaps / Within — see the module doc comment.
        false
      end

      private def self.comparison_op?(op : Doctype::Operator) : Bool
        op.gt? || op.gte? || op.lt? || op.lte?
      end

      # ── Private ────────────────────────────────────────────────────────

      private def self.eq_matches?(
        sv : ScopeValue,
        actual : JSON::Any,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
      ) : Bool
        case sv.type
        when ScopeValueType::Literal
          actual.raw == sv.raw
        when ScopeValueType::Self
          # `$self` refers to the actioner's account. Both stored principal
          # forms match: the qualified reference form (`iam.Account.<id>`,
          # what a reference field targeting `iam.Account` stores) and the
          # bare id (what a plain string field holds — e.g. a create hook
          # writing `ctx.actor.id`).
          RBAC.principal_forms(scope_context.account_id).any? { |form| actual.raw == form }
        when ScopeValueType::OrganizationalUnit
          actual.raw == scope_context.organizational_unit
        when ScopeValueType::ContextSet
          name = sv.context_set_name
          values = context_results[name]? || [] of String
          values.includes?(actual.raw.to_s)
        else
          false
        end
      end

      # Case-insensitive text operators (Match / StartsWith). The resolved
      # RHS is a literal substring / prefix, never an ILIKE pattern.
      # Context-set values OR the predicate across the resolved set (the
      # in-process analog of the SQL `EXISTS (unnest(...))` form).
      private def self.text_op?(
        sv : ScopeValue,
        actual : JSON::Any,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        &
      ) : Bool
        actual_s = actual.raw.to_s.downcase
        case sv.type
        when ScopeValueType::Literal, ScopeValueType::OrganizationalUnit
          rhs = ScopePredicateSql.resolve_scalar(sv, scope_context).downcase
          yield actual_s, rhs
        when ScopeValueType::Self
          # Pattern operators OR across both accepted principal forms, so a
          # `match`/`starts_with` predicate on `$self` hits the bare id and
          # the qualified reference form alike.
          RBAC.principal_forms(scope_context.account_id).any? { |form| yield actual_s, form.downcase }
        when ScopeValueType::ContextSet
          name = sv.context_set_name
          values = context_results[name]? || [] of String
          values.any? { |v| yield actual_s, v.downcase }
        else
          false
        end
      end

      # Numeric → datetime → lexicographic comparison, in that order. The
      # type is selected from the RHS literal (the authoring gate ties the
      # operator to the field's declared type; this runtime parse is the
      # best-effort mirror). An unparseable actual degrades to `false`.
      private def self.comparison_matches?(
        op : Doctype::Operator,
        sv : ScopeValue,
        actual : JSON::Any,
      ) : Bool
        return false unless sv.type == ScopeValueType::Literal

        rhs = sv.raw
        actual_s = actual.raw.to_s

        if (a_num = as_numeric(actual_s)) && (b_num = as_numeric(rhs))
          return ordered?(op, a_num, b_num)
        end
        if (a_time = as_datetime(actual_s)) && (b_time = as_datetime(rhs))
          return ordered?(op, a_time, b_time)
        end
        # String fields legitimately use comparison operators (the
        # `comparison` capability is valid on string-like fields) —
        # lexicographic ordering, mirroring the SQL text comparison.
        ordered?(op, actual_s, rhs)
      end

      private def self.ordered?(op : Doctype::Operator, a : Float64, b : Float64) : Bool
        compare(op, a, b)
      end

      private def self.ordered?(op : Doctype::Operator, a : Time, b : Time) : Bool
        compare(op, a, b)
      end

      private def self.ordered?(op : Doctype::Operator, a : String, b : String) : Bool
        compare(op, a, b)
      end

      private def self.compare(op : Doctype::Operator, a, b) : Bool
        case op
        when .gt?  then a > b
        when .gte? then a >= b
        when .lt?  then a < b
        when .lte? then a <= b
        else            false
        end
      end

      private def self.contains_matches?(sv : ScopeValue, actual : JSON::Any) : Bool
        return false unless sv.type == ScopeValueType::Literal

        case raw = actual.raw
        when Array(JSON::Any)
          # Array membership: the stored array contains the literal.
          raw.any? { |item| item.raw.to_s == sv.raw }
        when Hash(String, JSON::Any)
          # Period/dateperiod containment: the stored `{start, end}` object
          # contains the literal point (`[start, end)` bound convention).
          start_s = raw["start"]?.try(&.raw.to_s)
          end_s = raw["end"]?.try(&.raw.to_s)
          return false if start_s.nil? || end_s.nil?
          point = sv.raw
          if (s = as_datetime(start_s)) && (e = as_datetime(end_s)) && (p = as_datetime(point))
            s <= p < e
          else
            start_s <= point && point < end_s
          end
        else
          false
        end
      end

      # Money-field currency equality: the actual must be a
      # `{"value", "currency"}` object whose `currency` member equals the
      # RHS literal.
      private def self.currency_matches?(sv : ScopeValue, actual : JSON::Any) : Bool
        return false unless sv.type == ScopeValueType::Literal
        h = actual.as_h?
        return false if h.nil?
        h["currency"]?.try(&.raw) == sv.raw
      end

      # `$null` against a present, non-null value is a no-match; `Ne` against
      # `$null` means "present and non-null".
      private def self.null_matches?(op : Doctype::Operator, actual : JSON::Any) : Bool
        case op
        when .eq? then actual.raw.nil?
        when .ne? then !actual.raw.nil?
        else           false
        end
      end

      private def self.as_numeric(s : String) : Float64?
        s.to_f?
      end

      private def self.as_datetime(s : String) : Time?
        Time.parse_iso8601(s).to_utc
      rescue Time::Format::Error
        nil
      end
    end
  end
end
