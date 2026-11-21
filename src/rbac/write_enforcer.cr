# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "../error"
require "../validation_error"
require "./scope_context"
require "./enforcer_support"
require "./field_visibility"

module Facet
  module RBAC
    # Enforces RBAC on write operations (create, update, delete, action).
    #
    # Permission scopes reference named scopes declared on the target
    # doctype. At enforcement time, the alias is expanded against the
    # doctype definition into a `field -> ScopeValue` `where` map, then
    # compiled to SQL and evaluated against the target row by the shared
    # single-row gate (`EnforcerSupport.row_authorized?`) — the same
    # compiler the list path uses.
    #
    # - Create: the row does not exist yet, so name-scope predicates cannot
    #   apply. `create` permissions only assert "this role may create rows of
    #   this doctype". Parent-pre-image filtering on the previous scope
    #   grammar has been dropped — its use cases are covered by the HTTP
    #   layer's `parent_authorized?` gate (parent read scope) and by named
    #   scopes that reference `$parent_id` (for child doctypes).
    # - Update/Delete/Action: check the target document satisfies the
    #   named scope's `where` predicates. Each action is matched against its
    #   own permission `action` value (`update`, `delete`, or the named
    #   action) — they are NOT collapsed under a single `update` permission.
    module WriteEnforcer
      # Refuses caller-submitted writes into invisible fields (B-70/B-72).
      # `submitted` is the caller-controlled body — the full document on
      # create, the patch on update, each child body on create-with-
      # children. Every key present is a write; an explicit `null` is a
      # write. Returns a `403` naming the offending content paths, or
      # `nil` when nothing invisible is touched. System and Preview keep
      # their bypasses.
      def self.authorize_field_writes(
        definition : Doctype::DoctypeDefinition,
        submitted : JSON::Any,
        auth_context : AuthContext,
      ) : Facet::ServiceError?
        violations = FieldVisibility.write_violations(auth_context, definition, submitted)
        field_write_denial(violations)
      end

      # Refuses a content transition (before → after) that lands inside
      # invisible fields — the named-action final-diff guard and the
      # rollback current-versus-replayed guard. Returns a `403` naming the
      # offending content paths, or `nil` when the transition only touches
      # visible fields.
      def self.authorize_field_changes(
        definition : Doctype::DoctypeDefinition,
        before : JSON::Any,
        after : JSON::Any,
        auth_context : AuthContext,
      ) : Facet::ServiceError?
        violations = FieldVisibility.changed_violations(auth_context, definition, before, after)
        field_write_denial(violations)
      end

      # Builds the structured 403 for field-write / field-change violations.
      private def self.field_write_denial(violations : Array(Array(String))) : Facet::ServiceError?
        return nil if violations.empty?

        details = violations.sort.map do |path|
          ValidationError.new(
            "field '#{path.join(".")}' is not visible to the active role",
            code: "forbidden",
          )
        end
        Facet::ServiceError.new(403, "Write refused: invisible field", details: details)
      end

      # Enforces RBAC for a create operation.
      #
      # Named scopes apply to *existing* rows; a row being created cannot
      # satisfy a content predicate. A `create` permission grants create
      # access — the `where` clause (if any) is enforced by Lua `create(ctx)`
      # lifecycle hooks, not by RBAC.
      #
      # `authorize_path` overrides the doctype path the gate checks. Nested
      # child routes pass the composition path from the aggregate root
      # (`["WorkOrder", "WorkLog"]`) — the flat route keeps the bare path
      # (`["WorkLog"]`). One resource, two rules: the route shape decides
      # which path the permission must match.
      def self.authorize_create(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        return true if auth_context.system?
        return PreviewEnforcer.authorizes?(db, "create", domain, doc_type, nil, auth_context) if auth_context.preview?

        gate = EnforcerSupport.dispatch_action("create", domain, doc_type, auth_context, authorize_path)

        # `Scoped` means the matching `create` permissions carry named scope
        # aliases. Named scopes apply to existing rows, not new ones — RBAC
        # authorises the create action itself; row-content rules belong to
        # Lua `create(ctx)` hooks. Treat any scoped match as allowed.
        !gate.denied?
      end

      # True when the caller holds no permission for the action on the
      # doctype at all (role denial or layer-1 app-grant ceiling) — the
      # class-level denial the update / delete / action gates answer with
      # 403, the same answer the read side gives for a class-level read
      # denial. A caller that holds a scoped grant but fails the row check
      # does NOT match: their denial surfaces as 404, so an inaccessible
      # document is indistinguishable from a missing one. Pure permission
      # arithmetic — no database access, no row scope. Preview principals
      # gate through `PreviewEnforcer` and keep their own denial mapping,
      # so they answer `false` here.
      def self.action_denied?(
        action : String,
        domain : String,
        doc_type : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        return false if auth_context.system? || auth_context.preview?

        EnforcerSupport.dispatch_action(action, domain, doc_type, auth_context, authorize_path).denied?
      end

      # Enforces RBAC for an update operation.
      #
      # The target document must exist and satisfy the named scope's `where`
      # predicates.
      def self.authorize_update(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        authorize_existing(db, "update", domain, doc_type, doc_id, auth_context, authorize_path)
      end

      # Enforces RBAC for a delete operation.
      #
      # Like update, the target document must exist and satisfy the named
      # scope's `where` predicates — but matched against a `delete` permission,
      # not `update`. Each action checks its own action name.
      def self.authorize_delete(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        authorize_existing(db, "delete", domain, doc_type, doc_id, auth_context, authorize_path)
      end

      # Enforces RBAC for a named action operation.
      #
      # The action name must match a permission's `action` value.
      # Scope evaluation follows the same rules as update.
      def self.authorize_action(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        action_name : String,
        auth_context : AuthContext,
      ) : Bool
        authorize_existing(db, action_name, domain, doc_type, doc_id, auth_context)
      end

      # Authorizes a sidecar create attached to a host document.
      #
      # Two-gate contract (host gate runs first in the handler):
      #
      # 1. **Host read gate** — `ReadEnforcer.parent_authorized?` on the
      #    host record, run by the handler before this call.
      # 2. **Nested grant** — a `create` permission on the host-scoped
      #    path (`create hr.Employee.Comment`). The path is prefix-matched,
      #    so a host `create` grant implies the nested grant. Flat grants
      #    on the sidecar doctype (`create core.Comment`) do NOT
      #    participate — they serve the flat endpoint only.
      #
      # The flat sidecar identity lives in a different domain than the host
      # (`core.Comment` vs `hr.Employee`); the enforcer is the only place
      # that can translate between them.
      def self.authorize_sidecar_create(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        sidecar_domain : String,
        sidecar_doctype : String,
        auth_context : AuthContext,
      ) : Bool
        EnforcerSupport.sidecar_action_authorized?(db, "create", host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_context)
      end

      # Authorizes a sidecar update attached to a host document.
      #
      # Mirror of `authorize_sidecar_create` for the per-document nested
      # route: the host read gate runs first in the handler, then this check
      # resolves the `update` action against the host-scoped nested path
      # (`update hr.Employee.Comment`), prefix-matched. Flat grants on the
      # sidecar doctype do NOT participate — they serve the flat endpoint
      # only.
      def self.authorize_sidecar_update(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        sidecar_domain : String,
        sidecar_doctype : String,
        auth_context : AuthContext,
      ) : Bool
        EnforcerSupport.sidecar_action_authorized?(db, "update", host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_context)
      end

      # Authorizes a sidecar delete attached to a host document.
      #
      # Mirror of `authorize_sidecar_create` for the per-document nested
      # route, against the `delete` action. Each write action checks its own
      # action name — a nested `update` grant does not carry `delete`.
      def self.authorize_sidecar_delete(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        sidecar_domain : String,
        sidecar_doctype : String,
        auth_context : AuthContext,
      ) : Bool
        EnforcerSupport.sidecar_action_authorized?(db, "delete", host_domain, host_doctype, sidecar_domain, sidecar_doctype, auth_context)
      end

      # ── Private ────────────────────────────────────────────────────────

      # Authorizes an operation on an existing document through the shared
      # single-row gate: the row must exist, be live, and satisfy the
      # matched permissions' scope clauses — compiled by
      # `RBAC::ScopePredicateSql`, the same engine the list path uses.
      # `authorize_path` overrides the doctype path the gate checks — see
      # `authorize_create` for the nested-route contract.
      private def self.authorize_existing(
        db : DB::Connection,
        action : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : AuthContext,
        authorize_path : Array(String)? = nil,
      ) : Bool
        return true if auth_context.system?
        return PreviewEnforcer.authorizes?(db, action, domain, doc_type, doc_id, auth_context) if auth_context.preview?

        EnforcerSupport.row_authorized?(db, action, domain, doc_type, doc_id, auth_context, authorize_path)
      end
    end
  end
end
