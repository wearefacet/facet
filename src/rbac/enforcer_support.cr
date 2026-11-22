# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "./scope_context"
require "./permission"
require "./scope_predicate"
require "../doctype/doctype_definition"

module Facet
  module RBAC
    # Internal support code shared by ReadEnforcer and WriteEnforcer.
    #
    # Not part of the public enforcer API — call the enforcers, not this
    # module, from route and service code.
    module EnforcerSupport
      # Tagged outcome of the layered permission gate.
      enum Gate
        # No permission grants the action (or the layer-1 app-grant ceiling
        # blocks it). Fail closed.
        Denied
        # A matched permission is unrestricted — the action is allowed
        # without row-content checks.
        Allowed
        # Matched permissions carry scope aliases; the caller evaluates the
        # row content against them. `GateResult#permissions` holds them.
        Scoped
      end

      # The gate outcome plus the matched scope permissions — filled when
      # the gate is `Scoped`, empty otherwise.
      record GateResult, gate : Gate, permissions : Array(Permission) = [] of Permission do
        def denied? : Bool
          gate.denied?
        end

        def allowed? : Bool
          gate.allowed?
        end

        def scoped? : Bool
          gate.scoped?
        end
      end

      # One dispatcher for the layered permission gate shared by the read
      # and write enforcers:
      #
      # 1. System bypass — always allowed.
      # 2. Layer-1 app-grant ceiling — a present-but-unresolvable grant
      #    denies (the enforcers surface this as a non-disclosing deny).
      # 3. Permission dispatch — `can?` on the flat action path.
      #
      # `doctype_path` overrides the target path both gates check. It
      # defaults to the bare `[doc_type]` (the flat-route rule). Nested
      # child routes pass the composition path from the aggregate root
      # (`["WorkOrder", "WorkLog"]`), sidecar routes the host-scoped path —
      # the route shape picks the path the grant and the permission must
      # match.
      #
      # The preview tier stays at the call sites — only some surfaces
      # consult `PreviewEnforcer`, and each needs a different call there.
      def self.dispatch_action(
        action : String,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        doctype_path : Array(String)? = nil,
      ) : GateResult
        return GateResult.new(Gate::Allowed) if auth_context.system?
        path = doctype_path || [doc_type]
        return GateResult.new(Gate::Denied) unless auth_context.app_grant_permits?(action, domain, path)

        case result = auth_context.can?(action, domain, path)
        when CanResult::Denied
          GateResult.new(Gate::Denied)
        when CanResult::All
          GateResult.new(Gate::Allowed)
        else
          GateResult.new(Gate::Scoped, result.as(CanResult::Scoped).permissions)
        end
      end

      # Authorizes a sidecar operation attached to a host document.
      #
      # The sidecar grant is the nested grant on the host-scoped path
      # (e.g. `read hr.Employee.Comment`). Flat grants on the sidecar
      # doctype (`core.Comment`) do NOT participate here — they serve the
      # flat `/Api/core/Comment` endpoint only. The nested path is
      # prefix-matched, so a host permission implies the nested grant for
      # the same action (`read hr.Employee` ⇒ `read hr.Employee.Comment`).
      #
      # Row-level filtering (sidecar records whose `target` points at a host
      # record the caller can reach) is enforced by the handler's `target`
      # filter plus the host gate that already ran. A `false` here is a
      # class-level denial (no nested grant at all) — handlers surface it
      # as `403`, matching the sidecar write gates.
      def self.sidecar_action_authorized?(
        db : DB::Connection,
        action : String,
        host_domain : String,
        host_doctype : String,
        sidecar_domain : String,
        sidecar_doctype : String,
        auth_context : AuthContext,
      ) : Bool
        return true if auth_context.system?
        return PreviewEnforcer.authorizes?(db, action, sidecar_domain, sidecar_doctype, nil, auth_context) if auth_context.preview?

        # Nested grant on the host-scoped path (`hr.Employee.Comment`).
        nested_path = [host_doctype, sidecar_doctype]
        return false unless auth_context.app_grant_permits?(action, host_domain, nested_path)

        !auth_context.can?(action, host_domain, nested_path).is_a?(CanResult::Denied)
      end

      # Loads the per-(domain, doctype) inputs the scope evaluators need.
      # Returns `{scope_context, context_results, definition}` in that order.
      # The definition is nilable — `DefinitionStore.fetch` returns `nil`
      # for an unknown, deleted, or corrupt doctype, and the scope evaluators
      # treat `nil` as "no definition-scoped expansion".
      def self.load_scope_inputs(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
      ) : {ScopeContext, Hash(String, Array(String)), Doctype::DoctypeDefinition?}
        scope_context = ScopeContext.load(db, auth_context.account_id)
        context_results = ContextResolver.resolve_for_domain(db, domain, scope_context)
        definition = Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
        {scope_context, context_results, definition}
      end

      # Returns true if a projection row exists and is not soft-deleted.
      def self.exists_undeleted?(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : Bool
        exists = db.query_one?(
          "SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL LIMIT 1",
          domain, doc_type, doc_id,
          as: Int32
        )
        !exists.nil?
      end

      # Builds OR-ed scope clauses for a set of matching permissions.
      #
      # For each permission, expands every alias on the permission to a
      # predicate map. Aliases on the same permission are OR-ed within a
      # parenthesised group; permissions themselves are then OR-ed by the
      # caller's `clauses.join(" OR ")`.
      #
      # `start_idx` is the placeholder index for the FIRST bound parameter;
      # this lets callers compose the scope clauses with other WHERE fragments
      # (e.g. `domain = $1 AND ... AND (<scopes>)` for `parent_authorized?`).
      #
      # Returns `{clauses, params}`. Empty `clauses` means no scope predicate
      # applied (every matching permission is unrestricted OR every scope
      # failed to expand — caller disambiguates).
      def self.build_permission_scope_clauses(
        perms : Array(Permission),
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        definition : Doctype::DoctypeDefinition?,
        start_idx : Int32,
      ) : {Array(String), Array(::DB::Any)}
        clauses = [] of String
        params = [] of ::DB::Any
        idx = start_idx

        perms.each do |perm|
          # Unrestricted permission: matches everything, no clause needed.
          # Caller relies on the empty-clauses case to mean "no restriction".
          next if perm.unrestricted?

          predicates_list = ScopeExpander.expand_all(perm, definition)
          # Unknown alias: fail closed — emit an unsatisfiable clause.
          if predicates_list.nil?
            clauses << "1=0"
            next
          end

          # Build one AND-clause per alias on this permission, then OR them
          # together inside a parenthesised group so the outer join (which
          # OR-s across permissions) preserves the per-permission grouping.
          perm_clauses = [] of String
          predicates_list.each do |predicates|
            clause_sql, clause_params, next_idx =
              build_scope_sql(predicates, scope_context, context_results, idx, definition)
            if clause_sql
              perm_clauses << clause_sql
              params.concat(clause_params)
              idx = next_idx
            else
              # Empty predicate map (named scope with empty `where`) means
              # this alias matches every row — the entire OR-group therefore
              # matches every row. Emit nothing for this permission.
              perm_clauses.clear
              break
            end
          end

          next if perm_clauses.empty?
          if perm_clauses.size == 1
            clauses << perm_clauses[0]
          else
            clauses << "(#{perm_clauses.join(" OR ")})"
          end
        end

        {clauses, params}
      end

      # Builds a SQL WHERE fragment from an expanded named scope's parsed
      # predicates. Delegates to the shared `RBAC::ScopePredicateSql`
      # compiler (the same semantics `ContextResolver` uses), so the
      # single-row and list surfaces agree on operator behaviour.
      #
      # Returns `{clause, params, next_idx}` where `next_idx` is the placeholder
      # index after the last parameter this clause bound. A `nil` clause means
      # the predicate list is empty (matches every row).
      private def self.build_scope_sql(
        predicates : Array(ScopePredicate),
        scope_context : ScopeContext,
        context_results : Hash(String, Array(String)),
        start_idx : Int32,
        definition : Doctype::DoctypeDefinition?,
      ) : {String?, Array(::DB::Any), Int32}
        ScopePredicateSql.build_clauses(
          predicates, scope_context, context_results, start_idx, definition
        )
      end

      # The single-row scope gate shared by `ReadEnforcer.authorized?` and
      # `WriteEnforcer.authorize_existing`.
      #
      # One engine for both answers: the row is authorised when it exists,
      # is not soft-deleted, and satisfies the OR-ed scope clauses of the
      # caller's matched permissions — compiled by the same
      # `RBAC::ScopePredicateSql` the list path uses. The reserved tokens
      # (`$doc_id`, `$parent_id`) therefore behave identically on the
      # single-row and list surfaces.
      #
      # Gate arithmetic: `Denied` → `false`, `Allowed` (unrestricted
      # permission) → the existence check alone, `Scoped` → the existence
      # check AND the scope clauses. An empty clause list (unrestricted
      # permission, or every alias expanding to an empty `where`) also
      # leaves only the existence check. A row that does not exist answers
      # `false` — callers surface that as a non-disclosing 404.
      #
      # The preview tier stays at the call sites — each enforcer passes a
      # different call to `PreviewEnforcer`.
      def self.row_authorized?(
        db : DB::Connection,
        action : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        return true if auth_context.system?

        gate = dispatch_action(action, domain, doc_type, auth_context, authorize_path)
        return false if gate.denied?
        return true if gate.allowed?

        scope_context, context_results, definition =
          load_scope_inputs(db, domain, doc_type, auth_context)

        base_params = [domain, doc_type, doc_id] of ::DB::Any
        scope_clauses, scope_params =
          build_permission_scope_clauses(gate.permissions, scope_context, context_results, definition, start_idx: base_params.size + 1)

        where_sql = if scope_clauses.empty?
                      "domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL"
                    else
                      "domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL AND (#{scope_clauses.join(" OR ")})"
                    end

        exists = db.query_one?(
          "SELECT 1 FROM projections WHERE #{where_sql} LIMIT 1",
          args: base_params + scope_params,
          as: Int32
        )
        !exists.nil?
      end
    end
  end
end
