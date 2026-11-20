# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../util/identifier"
require "../util/filter_clauses"
require "../doctype/doctype_definition"
require "./scope_value"
require "./scope_context"
require "./scope_predicate"

module Facet
  module RBAC
    # Resolves context sets at request time with per-request memoization.
    #
    # Context sets are domain-owned and defined in the `core.Domain` definition.
    # Resolution reads raw projections (trusted bypass) and follows the
    # dependency DAG in topological order.
    #
    # The memo cache is partitioned by domain:
    #   { "crm" => { "my_teams" => [...], "my_projects" => [...] },
    #     "hr"  => { ... } }
    #
    # This is a trusted-bypass component — it reads raw projections,
    # never calling into RBAC-enforced read paths.
    module ContextResolver
      # A type alias for the memo cache: domain → set_name → resolved values.
      Memo = Hash(String, Hash(String, Array(String)))

      # An empty memo for starting fresh.
      EMPTY_MEMO = {} of String => Hash(String, Array(String))

      # Resolves a single context set for a given actioner and domain.
      #
      # Results are memoized per domain so all scopes in a request
      # see a consistent snapshot.
      def self.resolve(
        db : DB::Connection,
        domain_name : String,
        set_name : String,
        scope_context : ScopeContext,
        context_sets : Hash(String, ContextSet),
        memo : Hash(String, Hash(String, Array(String))) = {} of String => Hash(String, Array(String)),
      ) : Array(String)
        # Check memo first
        domain_memo = memo[domain_name]?
        if domain_memo && domain_memo.has_key?(set_name)
          return domain_memo[set_name]
        end

        defn = context_sets[set_name]?
        if defn.nil?
          raise Error.new("Context set '#{set_name}' not defined in domain '#{domain_name}'")
        end

        # Resolve dependencies first (topological order). `context_results`
        # maps each dependency's set name to its resolved value array — the
        # same shape the enforcers load via `EnforcerSupport.load_scope_inputs`
        # and hand to `ScopePredicateSql`.
        context_results = {} of String => Array(String)
        resolve_dependencies(db, domain_name, defn.dependencies, scope_context, context_sets, memo, context_results)

        # Build the SQL query with parameterised $N placeholders.
        #
        # The `select_field` may be a literal content field name, or the
        # reserved token `$parent_id`, which reads the system-managed
        # parent linkage stored at `meta->>'parent_id'`. This lets a
        # context set scope by the parent of a child doctype (e.g. resolve
        # the teams a user belongs to via TeamMember child rows of Team).
        select_field = defn.select_field
        from_doctype = defn.from
        select_expr = ScopePredicateSql.field_expr(select_field, "Context set select field")

        where_parts = ["domain = $1", "doc_type = $2", "deleted_at IS NULL"]
        where_values = [domain_name, from_doctype] of ::DB::Any
        idx = 3

        predicates = ScopePredicateParser.parse_where(defn.where)
        # Validate the where fields with the context-set label before the
        # shared compiler runs (its default label names the named-scope
        # surface). Same SQL-injection guard, same error contract.
        predicates.each do |predicate|
          ScopePredicateSql.field_expr(predicate.field, "Context set where field")
        end

        # The target doctype definition is only needed by the type-aware
        # clause builders (comparison / range / currency operators); fetch
        # it lazily so equality-only context sets skip the lookup.
        from_definition = fetch_from_definition(db, domain_name, from_doctype, predicates)

        # Compile every predicate through the shared scope → SQL compiler,
        # so context-set resolution and the named-scope list path agree on
        # operator semantics (including the fail-closed empty-set rule).
        clause_sql, clause_params, _idx = ScopePredicateSql.build_clauses(
          predicates, scope_context, context_results, idx, from_definition,
        )
        where_parts << clause_sql if clause_sql
        where_values.concat(clause_params)

        where_sql = where_parts.join(" AND ")

        sql = <<-SQL
          SELECT DISTINCT #{select_expr}
          FROM projections
          WHERE #{where_sql}
        SQL

        values = where_values

        results = [] of String
        db.query(sql, args: values) do |rs|
          rs.each do
            results << rs.read(String)
          end
        end

        # Memoize
        domain_memo = memo[domain_name] ||= {} of String => Array(String)
        domain_memo[set_name] = results

        results
      end

      # All-in-one convenience: fetches domain content, extracts context sets,
      # and resolves all of them for a given actioner.
      #
      # This is the single method that ReadEnforcer and WriteEnforcer should
      # call instead of repeating the three-step dance.
      def self.resolve_for_domain(
        db : DB::Connection,
        domain : String,
        scope_context : ScopeContext,
      ) : Hash(String, Array(String))
        domain_content = fetch_domain_content(db, domain)
        context_sets = extract_context_sets(domain_content)
        resolve_all(db, domain, context_sets, scope_context)
      end

      # Resolves all context sets defined in a domain's `context_sets` config
      # for a given actioner. Returns a fully populated domain memo.
      def self.resolve_all(
        db : DB::Connection,
        domain_name : String,
        context_sets : Hash(String, ContextSet),
        scope_context : ScopeContext,
      ) : Hash(String, Array(String))
        memo = {} of String => Hash(String, Array(String))
        context_sets.each_key do |name|
          resolve(db, domain_name, name, scope_context, context_sets, memo)
        end
        memo.fetch(domain_name, {} of String => Array(String))
      end

      # Extracts context set definitions from a domain's content JSON.
      # Returns a map of set_name → ContextSet, or empty hash if none defined.
      def self.extract_context_sets(domain_content : JSON::Any?) : Hash(String, ContextSet)
        return {} of String => ContextSet if domain_content.nil?

        content_hash = domain_content.as_h?
        return {} of String => ContextSet if content_hash.nil?

        context_sets_raw = content_hash["context_sets"]?
        return {} of String => ContextSet if context_sets_raw.nil?

        sets_h = context_sets_raw.as_h?
        return {} of String => ContextSet if sets_h.nil?

        sets_h.each_with_object({} of String => ContextSet) do |(name, raw), acc|
          h = raw.as_h
          from = h["from"]?.try(&.as_s) || raise ArgumentError.new("Context set '#{name}' missing 'from'")
          select_field = h["select"]?.try(&.as_s) || raise ArgumentError.new("Context set '#{name}' missing 'select'")
          where_raw = h["where"]?.try(&.as_h) || {} of String => JSON::Any
          where_map = where_raw.each_with_object({} of String => String) do |(k, v), wh|
            wh[k] = v.as_s
          end
          acc[name] = ContextSet.new(name: name, from: from, where: where_map, select_field: select_field)
        end
      end

      # Fetches a domain's content from projections (trusted bypass).
      def self.fetch_domain_content(
        db : DB::Connection,
        domain_name : String,
      ) : JSON::Any?
        row = db.query_one?(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
            AND deleted_at IS NULL
          SQL
          domain_name
        ) do |rs|
          rs.read(JSON::Any)
        end
        row
      end

      # ── Private ────────────────────────────────────────────────

      # Fetches the `from` doctype definition when any predicate needs the
      # type-aware clause builders (comparison / range / currency
      # operators). Returns `nil` for equality-only predicate lists, so
      # those context sets skip the lookup.
      private def self.fetch_from_definition(
        db : DB::Connection,
        domain_name : String,
        from_doctype : String,
        predicates : Array(ScopePredicate),
      ) : Doctype::DoctypeDefinition?
        needs_definition = predicates.any? do |predicate|
          op = predicate.operator
          op.gt? || op.gte? || op.lt? || op.lte? || op.between? ||
            op.range? || op.currency?
        end
        return nil unless needs_definition
        Doctype::DefinitionStore.fetch(db, "#{domain_name}.#{from_doctype}")
      end

      # Resolves all dependencies of a context set, populating
      # `context_results` with each dependency's resolved values.
      private def self.resolve_dependencies(
        db : DB::Connection,
        domain_name : String,
        dependencies : Array(String),
        scope_context : ScopeContext,
        context_sets : Hash(String, ContextSet),
        memo : Hash(String, Hash(String, Array(String))),
        context_results : Hash(String, Array(String)),
      ) : Nil
        dependencies.each do |dep_name|
          dep_defn = context_sets[dep_name]?
          if dep_defn.nil?
            raise Error.new("Context set dependency '#{dep_name}' not defined in domain '#{domain_name}'")
          end

          context_results[dep_name] = resolve(db, domain_name, dep_name, scope_context, context_sets, memo)
        end
      end
    end
  end
end
