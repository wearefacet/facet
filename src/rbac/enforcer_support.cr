# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./scope_context"

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
    end
  end
end
