# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./permission"
require "./scope_predicate"
require "../doctype/doctype_definition"

module Facet
  module RBAC
    # Resolves a permission's `scope` aliases against the target doctype
    # definition at enforcement time.
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
    #
    # The returned predicates are compiled to SQL by `RBAC::ScopePredicateSql`
    # and evaluated against the `projections` row — the same engine for the
    # list path (`ReadEnforcer.list_where_clauses`) and the single-row gate
    # (`EnforcerSupport.row_authorized?`).
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
    end
  end
end
