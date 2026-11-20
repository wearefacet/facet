# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./permission"
require "./scope_value"
require "./scope_context"
require "./scope_predicate"
require "./scope_matcher"
require "../doctype/doctype_definition"

module Facet
  module RBAC
    # Resolves a permission's `scope` aliases against the target doctype
    # definition at enforcement time, and evaluates the resulting predicate
    # against a projection's content.
    #
    # A permission references one or more named scopes by alias (`"$<name>"`,
    # or `"$all"`/absent for unrestricted). When multiple aliases are present
    # on a single permission, they are combined with **OR** semantics: a row
    # matches the permission if it satisfies any of the referenced named
    # scopes. This OR is in addition to the existing OR across multiple
    # matching permissions in the same role.
    #
    # `$all` and an absent `scope` both expand to no predicate (unrestricted).
    #
    # Unknown alias → `expand_all` returns `nil`. The enforcers fail closed on
    # `nil` (the alias names no scope on the doctype). This is the runtime
    # safety net: authoring-time validation should reject unknown aliases
    # before they reach here, but a definition can change between authoring
    # and request.
    module ScopeExpander
      # Expands a permission's scope aliases against the target doctype
      # definition.
      #
      # Returns one predicate list per alias (each list AND-ed across its
      # predicates; the lists OR-ed across aliases). An empty outer array
      # means the permission is unrestricted. Returns `nil` when any alias
      # names no scope on the doctype (fail closed).
      def self.expand_all(
        perm : Permission,
        definition : Doctype::DoctypeDefinition?,
      ) : Array(Array(ScopePredicate))?
        return [] of Array(ScopePredicate) if perm.unrestricted?
        return nil if definition.nil?

        result = [] of Array(ScopePredicate)
        perm.scope_aliases.each do |alias_name|
          named = definition.try(&.scopes[alias_name]?)
          return nil if named.nil?

          result << ScopePredicateParser.parse_where(named.where)
        end
        result
      end

      # Returns true if the permission's named scopes match the given content.
      #
      # Unrestricted permissions match everything. Any unknown alias fails
      # closed. Otherwise the aliases' `where` predicates are OR-ed: the
      # permission matches when at least one alias's predicates all hold
      # (each alias's predicates AND-ed across fields).
      #
      # `doc_id` is the row's own id, evaluated against the reserved
      # `$doc_id` field token. A nil id fails closed (no match) — callers
      # that hold the id (the single-doc enforcers) pass it; the SQL list
      # path compiles the token against the `projections.id` column
      # instead.
      def self.match?(
        perm : Permission,
        content : JSON::Any,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        definition : Doctype::DoctypeDefinition?,
        doc_id : String? = nil,
      ) : Bool
        return true if perm.unrestricted?

        predicates_list = expand_all(perm, definition)
        return false if predicates_list.nil?

        content_h = content.as_h?
        return false if content_h.nil?

        predicates_list.any? do |predicates|
          predicates.all? do |predicate|
            if predicate.field == ScopePredicateParser::DOC_ID_FIELD
              # The row id never comes from content — evaluate against the
              # caller-supplied id. Nil fails closed.
              next false if doc_id.nil?
              next ScopeMatcher.match?(predicate, JSON::Any.new(doc_id), scope_context, context_results)
            end

            actual = content_h[predicate.field]?
            # `$null` matches both an absent key and an explicit JSON null;
            # `Ne` against `$null` means "present and non-null". Every other
            # operator on an absent field is a no-match.
            if predicate.value.type == ScopeValueType::Null
              if predicate.operator.eq?
                actual.nil? || actual.raw.nil?
              elsif predicate.operator.ne?
                !actual.nil? && !actual.raw.nil?
              else
                false
              end
            else
              next false if actual.nil?
              ScopeMatcher.match?(predicate, actual, scope_context, context_results)
            end
          end
        end
      end

      # Returns true if any of the given permissions' named scope matches the
      # content (intra-role OR semantics, combined with the per-permission
      # OR across aliases). `doc_id` threads through to `$doc_id` predicates.
      def self.any_match?(
        perms : Array(Permission),
        content : JSON::Any,
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        definition : Doctype::DoctypeDefinition?,
        doc_id : String? = nil,
      ) : Bool
        perms.any? { |perm| match?(perm, content, scope_context, context_results, definition, doc_id) }
      end
    end
  end
end
