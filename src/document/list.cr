# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "big"
require "../util/filter_set"
require "../util/filter_clauses"
require "../util/diacritic_fold"
require "../util/like_escape"
require "../util/time_helper"
require "../util/money"
require "../util/money_filter_value"
require "../doctype/doctype_definition"
require "../doctype/derived_operators"
require "../rbac"
require "../mutation/client"
require "./migrate"
require "./filter_compiler"
require "./collection_version"
require "./list/aggregate"
require "../error"
require "../validation_error"
require "opentelemetry"

module Facet
  module Document
    # Service for listing documents of a given doctype.
    #
    # Supports pagination, basic equality filtering, and field-based
    # ordering. Only non-deleted projections are returned.
    #
    # Lazy-migrates stale documents in the result set: each item whose
    # `meta.schema_version` is lower than the current doctype schema_version
    # is migrated via `Document::Migrate.call` with a row lock.
    module List
      # The count window is shared with every other `meta.count` surface.
      COUNT_CAP = HTTP::Responders::COUNT_CAP

      # One list page. `total` is the number of matching rows from the page
      # offset, counted up to `COUNT_CAP`; `more` is true only when the
      # count hit that cap (so `total` is a floor, not the exact total).
      record Result,
        items : Array(Mutation::Client::Projection),
        total : Int64,
        more : Bool

      # Result of a field-aggregate request. The record lives in
      # `List::Aggregate`; this alias keeps the `List::AggregateResult`
      # call surface stable for the HTTP layer, the agent tools, and the
      # specs.
      alias AggregateResult = Aggregate::AggregateResult

      # Raised by the money clause builder when a money filter value is
      # malformed (non-decimal amount) or references an unregistered
      # currency ticker. `List.call` rescues it and returns a 422
      # `ServiceError` so typos surface to the caller instead of silently
      # degrading to a no-match (per the money revamp filter grammar).
      # The builder itself lives in `Util::FilterClauses`; the alias keeps
      # the rescue site and any spec references on `List` stable.
      alias MoneyFilterError = ::Facet::Util::FilterClauses::MoneyFilterError

      # Reserved filter key that scopes a listing to one parent's owned
      # children — the same narrowing the nested child route applies through
      # its `parent_id` path segment, exposed as a filter so a child
      # doctype's standalone table can narrow by parent (e.g. spare parts by
      # machine). Equality only — the reserved key is stripped before
      # `FilterCompiler` sees the map, so other suffixes (`parent_id__ne`,
      # …) 422 as unknown fields.
      PARENT_FILTER_KEY = "parent_id__eq"

      # Lists documents for the given domain/doctype.
      #
      # Requires an `auth_context` for RBAC authorization. Scope predicates
      # from the active role are compiled into the SQL WHERE clause as
      # compiled into the SQL WHERE clause as
      # additional restrictions. Field-level read masking is applied to
      # each returned item.
      #
      # Filters use a text-based comparison against extracted JSONB
      # values with parameterized placeholders. Filter keys are validated
      # before compilation: an unknown field, or a known field with an
      # operator its family does not serve, answers 422 (see
      # `FilterCompiler.validate_filters!`). Sort entries are validated the
      # same way: a field that is neither a system sort column nor a
      # doctype field, or a field whose type cannot sort, answers 422 (see
      # `build_order_clause`).
      #
      # When `aggregate` is set to `"count"`, the service runs only the
      # COUNT subquery (capped at 1000 — same as the normal list path)
      # and returns an empty `items` array. Reading rows, lazy migration,
      # and field-level masking are skipped because no content is ever
      # returned. RBAC scope clauses still apply — a caller cannot count
      # rows they could not list.
      # When `aggregate` is one of the field aggregates (`sum`, `avg`,
      # `min`, `max`), the service runs one `<FN>/COUNT` statement over the
      # full filtered set (no page cap — a field aggregate implies "over
      # everything matching"; runaway cost is bounded by the global
      # `statement_timeout`, not a row cap) and returns an
      # `AggregateResult`. `field` must be a top-level doctype field of
      # type `integer`, `duration`, or `money`; every other value surfaces
      # as 422 before any SQL runs, and a field whose `view` tags the
      # caller cannot see returns 403. RBAC scope clauses still apply — a
      # caller cannot aggregate rows they could not list.
      # When `include_deleted` is true, the listing returns tombstones
      # (`deleted_at IS NOT NULL`) instead of live rows — the trash listing.
      # RBAC scope clauses, read masking, pagination, and the response shape
      # are unchanged, so the trash list is the same facet as the live list
      # with the rows swapped. Tombstones carry their retained pre-delete
      # payload (cleared later by `Cron::TombstoneContentPrune`), so read
      # masking applies to whatever payload remains.
      #
      # A caller that holds no read permission on the doctype at all —
      # role denial or app-grant ceiling — answers `403` before any SQL
      # runs (`ReadEnforcer.list_denied?`), matching the write side's
      # answer for the same gate state. The structural metadata doctypes
      # keep their non-disclosing list (B-86). A caller that holds a read
      # grant gets the scope-narrowed list, empty when no row matches —
      # row-level scoping never turns into a 403.
      #
      # The reserved `parent_id__eq` filter key (see `PARENT_FILTER_KEY`)
      # narrows the listing to one parent's owned children. It is extracted
      # before field-filter compilation and folds into the same `parent_id`
      # clause the nested child route drives.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        filters : Hash(String, JSON::Any) = {} of String => JSON::Any,
        sort : Array(String) = ["id"],
        page : Int32 = 1,
        items_per_page : Int32 = 100,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        parent_id : String? = nil,
        aggregate : String? = nil,
        field : String? = nil,
        skip_authorization : Bool = false,
        include_deleted : Bool = false,
        named_scope : String? = nil,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
        skip_filter_capability_check : Bool = false,
      ) : Result | AggregateResult | Facet::ServiceError
        err = unknown_aggregate_error(aggregate)
        return err if err

        Facet::Telemetry.trace "document.list" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["page"] = page.to_s
          span["items_per_page"] = items_per_page.to_s
          span["aggregate"] = aggregate || ""
          span["include_deleted"] = include_deleted.to_s

          listed = list_definition_or_denial(db, domain, doc_type, auth_context, named_scope, skip_authorization, authorize_path, authorize_root_id)
          return listed if listed.is_a?(Facet::ServiceError)
          defn = listed

          # Field visibility runs before the pair-consistency check: a field
          # the active role cannot see answers 403, never a 422 that names it.
          err = Aggregate.field_param_error(aggregate, field, defn, auth_context, skip_authorization)
          return err if err

          extracted = extract_parent_filter(domain, defn, filters, parent_id)
          return extracted if extracted.is_a?(Facet::ServiceError)
          filters, parent_id = extracted

          compiled = compile_where(db, domain, doc_type, defn, filters, auth_context, parent_id, skip_authorization: skip_authorization, include_deleted: include_deleted, named_scope: named_scope, authorize_path: authorize_path, authorize_root_id: authorize_root_id, skip_filter_capability_check: skip_filter_capability_check)
          return compiled if compiled.is_a?(Facet::ServiceError)
          where_sql, all_params = compiled
          order_sql = build_order_clause(sort, defn)
          return order_sql if order_sql.is_a?(Facet::ServiceError)

          if aggregate == "count"
            # Count mode: cap at 1000 from offset 0 so callers always learn the
            # inclusive upper bound of what matches, irrespective of the
            # `page` / `items` they supplied. Sort/ORDER BY are still applied
            # because the cap subquery wraps the same ORDER BY … LIMIT … shape
            # used by the normal path, keeping the count semantics identical.
            total = run_count_only(db, where_sql, order_sql, all_params)
            span["total"] = total
            return Result.new(items: [] of Mutation::Client::Projection, total: total, more: total > COUNT_CAP)
          end

          if aggregate.in?(Aggregate::FIELD_AGGREGATES) && (field_param = field)
            result = field_aggregate_result(db, defn, aggregate.as(String), where_sql, all_params, field_param, auth_context, skip_authorization, domain, doc_type, authorize_path)
            return result if result.is_a?(Facet::ServiceError)

            span["field"] = field_param
            span["total"] = result.count
            return result
          end

          offset = (page - 1) * items_per_page
          items, total = run_queries(db, where_sql, order_sql, all_params, offset, items_per_page)

          # 4. Lazy-migrate stale documents before applying read mask
          migrated_items = migrate_stale_items(db, items, defn)

          masked_items = present_list_items(migrated_items, auth_context, defn)

          span["total"] = total
          # The count window reads up to `COUNT_CAP + 1` rows past the page
          # offset, so `total > COUNT_CAP` is the "counting was truncated"
          # signal.
          Result.new(items: masked_items, total: total, more: total > COUNT_CAP)
        end
      end

      # ── Private ──────────────────────────────────────────────────────

      # The 422 for an `aggregate` value outside the supported set, or nil
      # for a supported (or absent) value. Extracted so `call` stays inside
      # ameba's complexity budget.
      private def self.unknown_aggregate_error(aggregate : String?) : Facet::ServiceError?
        return nil if aggregate.nil? || Aggregate::AGGREGATES.includes?(aggregate)

        Facet::ServiceError.new(422, "Unknown aggregate: #{aggregate}")
      end

      # Fetches the doctype definition for a list request and checks the
      # `named_scope` name against it. Returns the 404 for an unknown
      # doctype, the 422 for an unknown scope, or the definition. Extracted
      # so `call` stays inside ameba's complexity budget.
      private def self.definition_for_list(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        named_scope : String?,
      ) : Doctype::DoctypeDefinition | Facet::ServiceError
        definition = fetch_definition(db, domain, doc_type)
        return Facet::ServiceError.new(404, "Unknown doctype: #{domain}.#{doc_type}") if definition.nil?

        definition = definition.as(Doctype::DoctypeDefinition)
        return Facet::ServiceError.new(422, "Unknown scope: #{named_scope}") if named_scope && !definition.scopes.has_key?(named_scope)

        definition
      end

      # The field-aggregate request body: the no-grant empty-set answer,
      # the field-tag / field-type validation, then the SQL run.
      #
      # A caller with no read permission on the doctype at all gets the
      # empty set without any field inspection — the same non-disclosing
      # contract as their list, which answers 200 with 0 rows through the
      # `1=0` scope clause. Running the field-tag / field-type validation
      # first would let a zero-grant caller enumerate field names and
      # sensitivity tags from the 403 / 422 / 200 distinctions. The check
      # needs no database access — it is pure permission arithmetic.
      private def self.field_aggregate_result(
        db : DB::Connection,
        definition : Doctype::DoctypeDefinition,
        aggregate : String,
        where_sql : String,
        all_params : Array(::DB::Any),
        field_param : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool,
        domain : String,
        doc_type : String,
        authorize_path : Array(String)?,
      ) : AggregateResult | Facet::ServiceError
        if !skip_authorization && RBAC::ReadEnforcer.read_denied?(domain, doc_type, auth_context, authorize_path)
          return Aggregate.empty_field_result(aggregate)
        end

        err = Aggregate.validate_aggregate_field(definition, aggregate, field_param, auth_context)
        return err if err

        value, count = Aggregate.run_field_aggregate(db, definition, aggregate, where_sql, all_params, field_param)
        AggregateResult.new(value: value, count: count)
      end

      # One builder for the two filter-compilation failures — both answer
      # 422; a filter-key refusal (unknown field, unserved operator) also
      # carries the structured detail so clients can branch on the code
      # (`unknown_filter_field` / `unsupported_filter_operator`).
      private def self.filter_error(message : String, field : String?, code : String?) : Facet::ServiceError
        details = if field && code
                    [ValidationError.new(field: field, code: code, message: message)]
                  end
        Facet::ServiceError.new(422, message, details: details)
      end

      # Compiles the WHERE clause, mapping the two filter-compilation
      # failures onto their 422 shape. Extracted so `call` stays inside
      # ameba's complexity budget.
      private def self.compile_where(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        defn : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
        parent_id : String?,
        *,
        skip_authorization : Bool,
        include_deleted : Bool,
        named_scope : String?,
        authorize_path : Array(String)?,
        authorize_root_id : String? = nil,
        skip_filter_capability_check : Bool = false,
      ) : {String, Array(::DB::Any)} | Facet::ServiceError
        build_where_clause(db, domain, doc_type, defn, filters, auth_context, parent_id,
          skip_authorization: skip_authorization, include_deleted: include_deleted,
          named_scope: named_scope, authorize_path: authorize_path,
          authorize_root_id: authorize_root_id,
          skip_filter_capability_check: skip_filter_capability_check)
      rescue ex : MoneyFilterError
        filter_error(ex.message.to_s, nil, nil)
      rescue ex : Util::FilterClauses::FilterGrammarError
        filter_error(ex.message.to_s, ex.filter_key, ex.reason)
      end

      # Fetches the doctype definition for the given domain/doctype.
      private def self.fetch_definition(
        db : DB::Connection,
        domain : String,
        doc_type : String,
      ) : Doctype::DoctypeDefinition?
        Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
      end

      # Resolves the list's doctype definition, then applies the
      # class-level read denial: a caller with no read permission on the
      # doctype at all answers 403 before any SQL runs, the same gate
      # state the write side denies with 403. Structural metadata keeps
      # its non-disclosing list (B-86). Returns the definition, or the
      # `Facet::ServiceError` to surface (404 unknown doctype, 422
      # unknown scope, 403 class denial).
      private def self.list_definition_or_denial(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : RBAC::AuthContext,
        named_scope : String?,
        skip_authorization : Bool,
        authorize_path : Array(String)?,
        authorize_root_id : String? = nil,
      ) : Doctype::DoctypeDefinition | Facet::ServiceError
        definition = definition_for_list(db, domain, doc_type, named_scope)
        return definition if definition.is_a?(Facet::ServiceError)

        unless skip_authorization
          if RBAC::ReadEnforcer.list_denied?(domain, doc_type, auth_context, authorize_path, authorize_root_id)
            IAM::Helpers.write_layer1_denial(db, auth_context, "read", domain, authorize_path || [doc_type])
            return Facet::ServiceError.new(403, "Forbidden")
          end
        end

        definition.as(Doctype::DoctypeDefinition)
      end

      # Builds the WHERE clause SQL and its bound parameters.
      # Composes base filters, RBAC scope restrictions, the user filter
      # grammar, and the optional parent_id filter.
      #
      # The user filter grammar (partition + clause assembly — range,
      # system columns, typed, money, container, scalars, search, datetime
      # UTC normalization) compiles through `Document::FilterCompiler`, the
      # shared compile step for the filter grammar. This method only owns
      # the row-selection predicates that are specific to the list action:
      # the domain/doc_type base, the live/tombstone switch, and the RBAC
      # scope clauses.
      private def self.build_where_clause(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        definition : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        auth_context : RBAC::AuthContext,
        parent_id : String?,
        skip_authorization : Bool = false,
        include_deleted : Bool = false,
        named_scope : String? = nil,
        authorize_path : Array(String)? = nil,
        authorize_root_id : String? = nil,
        skip_filter_capability_check : Bool = false,
      ) : {String, Array(::DB::Any)}
        # Live listing vs trash listing: the tombstone predicate is the only
        # switch. RBAC scope clauses and every other filter apply to both.
        tombstone_clause = include_deleted ? "deleted_at IS NOT NULL" : "deleted_at IS NULL"
        where_clauses = ["domain = $1", "doc_type = $2", tombstone_clause]
        all_params = [domain, doc_type] of ::DB::Any

        # Inject RBAC scope restrictions. Pass the current placeholder
        # offset so the scope clauses reference parameters that come after
        # domain/doc_type's $1, $2. The scope params are then concatenated
        # to all_params in the same order the scope clauses reference them.
        #
        # `skip_authorization` is set by callers that have ALREADY
        # enforced an equivalent (or stronger) row-level gate at a higher
        # layer — today only `SidecarHandler.list`, which enforces the
        # host read gate plus the flat-or-nested sidecar read grant before
        # delegating here, AND filters on the `target` reference so only
        # sidecar records of the reachable host are returned. Skipping the
        # inner flat scope clause lets a nested-grant holder
        # (e.g. `read hr.Employee.Comment`) reach the list path, which the
        # flat `read core.Comment` gate would otherwise collapse to `1=0`.
        unless skip_authorization
          scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
            db, domain, doc_type, auth_context, start_idx: all_params.size + 1, authorize_path: authorize_path,
            authorize_root_id: authorize_root_id
          )
          where_clauses.concat(scope_clauses)
          all_params.concat(scope_params)
        end

        # A query-time named scope (the list tools' `scope` argument): one
        # more AND clause, compiled through the single scope-to-SQL owner
        # with the caller's context — `$self` and context sets resolve for
        # the calling account, exactly as the enforcement-time expansion
        # does. RBAC clauses are untouched: a query-time scope only
        # narrows.
        if ns = named_scope
          scope_clause, scope_params = build_named_scope_clause(
            db, domain, definition, ns, auth_context, all_params.size + 1
          )
          where_clauses << scope_clause if scope_clause
          all_params.concat(scope_params)
        end

        # Compile the user filter grammar through the shared helper. The
        # compiled clauses start at the next free placeholder — after
        # domain/doc_type and (when present) the RBAC scope params.
        # `MoneyFilterError` propagates to `call`, which turns it into 422.
        #
        # When the doctype declares no `search` template, the corpus column
        # holds the folded display_name (the write-path fallback, B-115) and
        # the bare `search` filter is pulled out and re-added as a search /
        # display_name / id contains probe so the picker keeps working there.
        fallback_filters, search_fallback = extract_search_fallback(definition, filters)
        filter_clauses, filter_params = FilterCompiler.compile(definition, fallback_filters, offset: all_params.size, skip_capability_check: skip_filter_capability_check)
        where_clauses.concat(filter_clauses)
        all_params.concat(filter_params)
        add_search_fallback_clause(where_clauses, all_params, search_fallback)

        # Add parent_id filter
        add_parent_filter(where_clauses, all_params, parent_id)

        {where_clauses.join(" AND "), all_params}
      end

      # Splits the bare `search` filter out of the filter map when the
      # doctype declares no `search` template. Returns the map without the
      # key plus the filter value to re-add as the three-arm fallback
      # (nil when there is nothing to fall back to).
      #
      # With a template, the corpus filter stays as-is — the corpus column
      # is populated and the trigram probe is the right tool. A suffixed
      # `search__*` key is not touched: it is not a production of the
      # filter grammar, so it keeps its strict no-match answer.
      private def self.extract_search_fallback(
        definition : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
      ) : {Hash(String, JSON::Any), JSON::Any?}
        template = definition.search
        return {filters, nil} unless template.nil? || template.empty?

        raw = filters["search"]?
        return {filters, nil} if raw.nil?

        rest = filters.dup
        rest.delete("search")
        {rest, raw}
      end

      # Re-adds the `search` filter as a three-arm contains probe for a
      # doctype with no `search` template (B-115):
      #
      # - `search` — the folded, LIKE-escaped term. The write path stages
      #   the folded display_name as the fallback corpus for a template-less
      #   doctype, so both sides fold and the arm matches like every
      #   templated corpus probe.
      # - `display_name` — the raw (unfolded), LIKE-escaped term. Covers
      #   rows with no staged corpus (definition-less writes via
      #   `ProjectionGucs.clear_all`), and lets an accented term match an
      #   accented label — a folded probe cannot match a raw column there.
      # - `id` — the folded probe, unchanged semantics.
      #
      # The folded and raw terms bind once each and their placeholders
      # appear in two and one arms respectively — the same reuse the
      # cross-doctype `/search` statement applies to its term parameter. A
      # nil filter value adds no clause, mirroring the corpus filter.
      private def self.add_search_fallback_clause(
        where_clauses : Array(String),
        all_params : Array(::DB::Any),
        value : JSON::Any?,
      ) : Nil
        return if value.nil?

        search_val = value.raw
        return if search_val.nil?

        term = search_val.to_s
        folded = Util::LikeEscape.escape(Util::DiacriticFold.fold(term))
        raw = Util::LikeEscape.escape(term)

        n = all_params.size + 1
        where_clauses << "(search ILIKE '%' || $#{n} || '%' ESCAPE '\\' OR display_name ILIKE '%' || $#{n + 1} || '%' ESCAPE '\\' OR id ILIKE '%' || $#{n} || '%' ESCAPE '\\')"
        all_params << folded
        all_params << raw
      end

      # Compiles one named scope's `where` map into a SQL clause through
      # `ScopePredicateParser` + `ScopePredicateSql` — the single owner of
      # scope-to-SQL — bound with the calling account's context. Returns
      # `{nil, []}` for an empty predicate map (the scope matches every
      # row, so the clause narrows nothing).
      private def self.build_named_scope_clause(
        db : DB::Connection,
        domain : String,
        definition : Doctype::DoctypeDefinition,
        name : String,
        auth_context : RBAC::AuthContext,
        start_idx : Int32,
      ) : {String?, Array(::DB::Any)}
        scope_def = definition.scopes[name]
        predicates = RBAC::ScopePredicateParser.parse_where(scope_def.where)
        scope_context = RBAC::ScopeContext.load(db, auth_context.account_id)
        context_results = RBAC::ContextResolver.resolve_for_domain(db, domain, scope_context)
        clause, params, _next_idx = RBAC::ScopePredicateSql.build_clauses(
          predicates, scope_context, context_results, start_idx, definition
        )
        {clause, params}
      end

      # Splits the reserved `parent_id__eq` filter key out of the filter map.
      # Returns the map without the key plus the effective `parent_id` scope.
      #
      # The value may be the parent's bare doc id or its fully qualified
      # reference token (`{domain}.{Doctype}.{id}`) — the shape the frontend
      # reference combobox emits. The qualified form strips through the
      # anchored `domain.{member_of}.` prefix, the same convention
      # `Document::ReferenceCheck.strip_qualified_id` uses: the parent
      # doctype is known, so the strip is unambiguous even for dotted
      # opaque ids.
      #
      # 422 answers:
      # - the value is not a non-empty string;
      # - the doctype is not an owned child (`member_of` unset) — such rows
      #   never carry `parent_id`, so silently matching nothing would hide
      #   a modelling mistake;
      # - a nested route already pinned a different parent.
      private def self.extract_parent_filter(
        domain : String,
        defn : Doctype::DoctypeDefinition,
        filters : Hash(String, JSON::Any),
        nested_parent_id : String?,
      ) : Tuple(Hash(String, JSON::Any), String?) | Facet::ServiceError
        raw = filters[PARENT_FILTER_KEY]?
        return {filters, nested_parent_id} if raw.nil?

        value = raw.as_s?
        if value.nil? || value.empty?
          return Facet::ServiceError.new(422, "Filter '#{PARENT_FILTER_KEY}' must be a non-empty string")
        end

        parent_doctype = defn.member_of
        unless parent_doctype
          return Facet::ServiceError.new(422, "Filter '#{PARENT_FILTER_KEY}' needs an owned child doctype (member_of); #{domain}.#{defn.doctype} is not one")
        end

        parent_id = strip_qualified_id(value, domain, parent_doctype)
        if nested_parent_id && nested_parent_id != parent_id
          return Facet::ServiceError.new(422, "Filter '#{PARENT_FILTER_KEY}' conflicts with the nested parent scope")
        end

        rest = filters.dup
        rest.delete(PARENT_FILTER_KEY)
        {rest, parent_id}
      end

      # Strips the `{domain}.{Doctype}.` prefix from a qualified reference
      # token down to the bare id `meta.parent_id` stores. Returns the value
      # unchanged when it is already bare — the defensive fallback
      # `Document::ReferenceCheck.strip_qualified_id` uses.
      private def self.strip_qualified_id(value : String, domain : String, parent_doctype : String) : String
        prefix = "#{domain}.#{parent_doctype}."
        return value[prefix.size..] if value.starts_with?(prefix)
        value
      end

      # Adds a parent_id filter clause if provided.
      private def self.add_parent_filter(
        where_clauses : Array(String),
        all_params : Array(::DB::Any),
        parent_id : String?,
      ) : Nil
        return if parent_id.nil?

        where_clauses << "meta->>'parent_id' = $#{all_params.size + 1}"
        all_params << parent_id
      end

      # The 422 for a sort entry the doctype definition cannot serve — an
      # unknown field, or a field whose type is not sortable. Mirrors
      # `filter_error`: the structured detail lets clients branch on the
      # code (`unknown_sort_field` / `unsortable_field`).
      private def self.sort_error(code : String, field : String, message : String) : Facet::ServiceError
        details = [ValidationError.new(field: field, code: code, message: message)]
        Facet::ServiceError.new(422, message, details: details)
      end

      # Builds the ORDER BY clause, validating every entry against the
      # doctype definition. A system column (`id`, `created_at`,
      # `updated_at`, `deleted_at`) rides verbatim; a doctype field
      # dispatches to a type-appropriate SQL expression so that `integer` /
      # `money` fields sort numerically rather than lexicographically (see
      # `sort_expression_for`). Shared with the export service — the single
      # source of truth for type-aware sort expressions.
      #
      # Nothing drops silently (B-158): an entry that is neither a system
      # column nor a doctype field answers `422 unknown_sort_field`, and a
      # field whose type cannot sort answers `422 unsortable_field` — the
      # same strict contract the filter grammar holds. An empty sort list
      # answers `"id ASC"`.
      def self.build_order_clause(
        sort : Array(String),
        definition : Doctype::DoctypeDefinition,
      ) : String | Facet::ServiceError
        order_clauses = [] of String
        sort.each do |field|
          dir = field.starts_with?("-") ? "DESC" : "ASC"
          col = field.starts_with?("-") ? field[1..] : field

          case col
          when "id", "created_at", "updated_at", "deleted_at"
            order_clauses << "#{col} #{dir}"
          else
            # Whitelist against doctype fields. `col` is constrained to
            # `[a-z_][a-z0-9_]*` / camelCase by `Doctype::Validation`, so
            # interpolation into the SQL identifier position is safe.
            field_def = definition.fields[col]?
            if field_def.nil?
              return sort_error("unknown_sort_field", col, "Unknown sort field '#{col}'")
            end

            expr = sort_expression_for(field_def, col, dir)
            if expr.nil?
              type_name = field_def.type.try(&.type_name) || "unknown"
              return sort_error("unsortable_field", col, "Field '#{col}' of type '#{type_name}' is not sortable")
            end
            order_clauses << expr
          end
        end

        order_clauses.empty? ? "id ASC" : order_clauses.join(", ")
      end

      # Returns the SQL ORDER BY expression for a doctype field, or `nil`
      # if the field's type is not meaningful to sort on (period,
      # dateperiod, object, array, dictionary, any, data). The caller turns
      # the `nil` into a `422 unsortable_field` (B-158) — the expression is
      # never dropped silently.
      #
      # Numeric sorts route through IMMUTABLE cast helpers reading the
      # JSONB value directly (`content->'field'`) so the order matches the
      # index access expression and the typed filter LHS — range scans and
      # ORDER BY can share the index. `integer` / `duration` use
      # `jsonb_as_numeric`; `money` uses `facet_money_value_as_numeric`
      # which reads the object's `value` member. Malformed stored values
      # yield NULL rather than raising, and NULL sorts consistently with
      # the column default (NULLS LAST for ASC).
      def self.sort_expression_for(
        field_def : Doctype::FieldDefinition,
        col : String,
        dir : String,
      ) : String?
        type = field_def.type
        return nil if type.nil?

        case type.type_name
        when "integer", "duration"
          "jsonb_as_numeric(content->'#{col}') #{dir}"
        when "money"
          "facet_money_value_as_numeric(content->'#{col}') #{dir}"
        when "string", "longtext", "enum", "color", "date", "datetime", "reference", "boolean", "phone", "url"
          "content->>'#{col}' #{dir}"
        else
          nil
        end
      end

      # Collection ETag validators. The queries live in
      # `Document::CollectionVersion`; these delegates keep the public call
      # surface on `List` for the HTTP routes.
      def self.collection_version(db : DB::Connection, domain : String, doc_type : String) : Time?
        CollectionVersion.collection_version(db, domain, doc_type)
      end

      def self.child_collection_version(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        parent_id : String,
      ) : Time?
        CollectionVersion.child_collection_version(db, domain, doc_type, parent_id)
      end

      def self.sidecar_collection_version(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        column : String,
        value : String,
      ) : Time?
        CollectionVersion.sidecar_collection_version(db, domain, doc_type, column, value)
      end

      # Runs only the capped COUNT subquery (no projection read). Used by
      # `aggregate: count` mode. The cap (`COUNT_CAP + 1` rows) and the
      # wrapped ORDER BY … LIMIT … shape mirror `run_queries` so the count
      # semantics stay identical to a normal list request with the same
      # filters — the caller learns the inclusive upper bound capped at
      # `COUNT_CAP`.
      #
      # `offset` is forced to 0 and `limit` to `COUNT_CAP + 1` so the cap
      # reflects the full filtered result regardless of the caller's page/items.
      private def self.run_count_only(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        all_params : Array(::DB::Any),
      ) : Int64
        capped_count(db, where_sql, order_sql, all_params, COUNT_CAP + 1, 0)
      end

      # Runs COUNT and SELECT queries with the given WHERE/ORDER BY.
      private def self.run_queries(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        all_params : Array(::DB::Any),
        offset : Int32,
        items_per_page : Int32,
      ) : {Array(Mutation::Client::Projection), Int64}
        # Capped count: read `COUNT_CAP + 1` rows past the offset so the
        # caller learns the real count up to the cap, not the page size.
        # The result is offset-relative by contract: `Document::List`
        # reports the raw window count and each caller adds its own offset
        # through `HTTP::Responders.capped_count`.
        total = capped_count(db, where_sql, order_sql, all_params, COUNT_CAP + 1, offset)

        items = read_projections(db, where_sql, order_sql, all_params, items_per_page, offset)

        {items, total}
      end

      # Runs the capped COUNT subquery shared by `run_count_only` and
      # `run_queries`. The wrapped ORDER BY … LIMIT … shape keeps the
      # count semantics identical to a normal list request with the same
      # filters.
      private def self.capped_count(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        all_params : Array(::DB::Any),
        limit : Int32,
        offset : Int32,
      ) : Int64
        db.query_one(
          <<-SQL,
            SELECT COUNT(*) FROM (
              SELECT 1 FROM projections
              WHERE #{where_sql}
              ORDER BY #{order_sql}
              LIMIT #{limit} OFFSET #{offset}
            ) AS sub
          SQL


          args: all_params,
          as: Int64
        )
      end

      # Reads projection rows and builds Projection objects.
      private def self.read_projections(
        db : DB::Connection,
        where_sql : String,
        order_sql : String,
        all_params : Array(::DB::Any),
        limit : Int32,
        offset : Int32,
      ) : Array(Mutation::Client::Projection)
        items = [] of Mutation::Client::Projection
        db.query(
          <<-SQL,
            SELECT domain, doc_type, id, content, version, links, meta, state, display_name, deleted_at, updated_at, created_at
            FROM projections
            WHERE #{where_sql}
            ORDER BY #{order_sql}
            LIMIT #{limit} OFFSET #{offset}
          SQL


          args: all_params
        ) do |rs|
          rs.each do
            items << Mutation::Client::Projection.new(
              domain: rs.read(String),
              doc_type: rs.read(String),
              id: rs.read(String),
              content: rs.read(JSON::Any),
              version: rs.read(Int32),
              links: rs.read(JSON::Any),
              meta: rs.read(JSON::Any),
              state: rs.read(String),
              display_name: rs.read(String?),
              deleted_at: rs.read(Time?),
              updated_at: rs.read(Time),
              created_at: rs.read(Time),
            )
          end
        end
        items
      end

      # Lazily migrates stale documents in the result set.
      #
      # For each item whose meta.schema_version is lower than the doctype
      # definition's current version, acquires a row lock and runs the
      # migration. Returns the (possibly migrated) items in the same order.
      #
      # The stale loop escalates as ONE rw block per request (§4.6.2): the
      # row locks, the migration writes, and the follow-up re-reads all run
      # on one nested rw connection, while the outer list query stays on the
      # ro pin. A result set with no stale items never escalates — the
      # pre-pass is an in-memory comparison, so a current document checks
      # out no second connection.
      private def self.migrate_stale_items(
        db : DB::Connection,
        items : Array(Mutation::Client::Projection),
        definition : Doctype::DoctypeDefinition,
      ) : Array(Mutation::Client::Projection)
        needs_migration = items.any? do |item|
          Document::Migrate.migration_needed?(item, definition) && !Document::Migrate.migration_blocked?(item)
        end
        unless needs_migration
          return items
        end

        Database.with_db(:read_write) do |rw_db|
          items.map do |item|
            unless Document::Migrate.migration_needed?(item, definition)
              next item
            end

            # Skip if migration was previously blocked by an error
            if Document::Migrate.migration_blocked?(item)
              next item
            end

            # Row lock to prevent concurrent migration
            locked = rw_db.query_one?(
              "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE",
              item.domain, item.doc_type, item.id,
              as: String
            )
            if locked.nil?
              next item
            end

            # Re-fetch after lock (another process may have migrated it)
            cur = Mutation::Client.fetch_projection(rw_db, item.domain, item.doc_type, item.id)

            unless Document::Migrate.migration_needed?(cur, definition)
              next cur
            end

            # Double-check after re-fetch (another process may have marked it)
            if Document::Migrate.migration_blocked?(cur)
              next cur
            end

            result = Document::Migrate.call(rw_db, definition, cur)
            case result
            in Document::Migrate::Result
              result.projection
            in Facet::ServiceError
              # Mark the document so we don't retry on every list
              Document::Migrate.write_migration_error_marker(rw_db, definition, cur, result.message, result.details)
            end
          end
        end
      end

      # Applies the field-level read mask to each item.
      private def self.apply_read_mask(
        items : Array(Mutation::Client::Projection),
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : Array(Mutation::Client::Projection)
        items.map do |item|
          masked_content = RBAC::ReadEnforcer.mask_content(item.content, auth_context, definition)
          item.with_content(masked_content)
        end
      end

      # Applies the field-level read mask to each item. Extracted so `call`
      # stays inside ameba's complexity budget.
      private def self.present_list_items(
        items : Array(Mutation::Client::Projection),
        auth_context : RBAC::AuthContext,
        definition : Doctype::DoctypeDefinition,
      ) : Array(Mutation::Client::Projection)
        apply_read_mask(items, auth_context, definition)
      end
    end
  end
end
