# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "../database"
require "../mutation/client"
require "../doctype"
require "../doctype/doctype_definition"
require "./script_context"
require "./recompute"
require "../iam/helpers"
require "../rbac"
require "../event"
require "../error"

module Facet
  module Document
    # Service for soft-deleting a document.
    #
    # Inserts a `delete` mutation, which causes the PL/pgSQL trigger to
    # set the `deleted_at` tombstone on the corresponding projection.
    module Delete
      record Result,
        mutation_id : String

      # Soft-deletes a document.
      #
      # Requires an `auth_context` for RBAC authorization.
      # Returns `Result` on success, `Error` on failure.
      def self.call(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        cause : Mutation::Cause? = nil,
        provenance : Mutation::Provenance? = nil,
        actioner_id : String? = nil,
        reentrant : Bool = false,
        skip_authorization : Bool = false,
        authorize_path : Array(String)? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "document.delete" do |span|
          span["domain"] = domain
          span["doc_type"] = doc_type
          span["doc_id"] = doc_id

          # Default to the auth context's account id; allow an explicit
          # override so a system-authorized mutation (e.g. a Lua `document.*`
          # call driven by a user action) can still be attributed to the
          # original caller in the audit log.
          actioner_id = actioner_id || auth_context.account_id
          prov = provenance || Mutation::Provenance.from(auth_context)

          # The mutation ULID is minted before the delete hook runs so the
          # hook's Lua `document.*` writes can stamp it as their
          # `cause.parent`. Cascade children get kind `cascade` with
          # `parent` bound to this mutation id.
          mut_id = Util::ScriptHelpers.ulid
          resolved_cause = (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(mut_id)

          # 0. Authorize the delete. `skip_authorization` is set by callers
          # that have ALREADY enforced an equivalent (or stronger) gate at a
          # higher layer — today only the nested per-document sidecar route,
          # which runs the host read gate plus the nested sidecar delete grant.
          # `authorize_path` overrides the gate path — the composition path
          # on nested child routes, the bare path on flat routes.
          if err = authorize_delete(db, domain, doc_type, doc_id, auth_context, skip_authorization, authorize_path)
            return Telemetry.record_error(span, err)
          end

          # 0.5–2a. Preflight guards: the Domain-deletion refusal, the
          # definition lookup, the projection fetch with its deleted check,
          # and the role-authority boundary. Returns the tuple to continue
          # with, or the error to surface.
          preflight = delete_preflight(db, span, domain, doc_type, doc_id, auth_context)
          return Telemetry.record_error(span, preflight) if preflight.is_a?(Facet::ServiceError)
          defn, proj = preflight

          # 3. Run the Lua delete lifecycle hook (validate before delete)
          pending = [] of Notification::Pending
          if defn.script?
            script_errors = [] of ValidationError
            delete_ctx = nil
            begin
              ScriptContext::Delete.new(defn.script.as(String), proj.content, actioner_id, db: db, domain: domain, doc_type: doc_type, doc_id: doc_id, cause: resolved_cause.child_of(mut_id), provenance: prov, auth_context: auth_context, rbac_doctype_path: authorize_path) do |ctx|
                delete_ctx = ctx
                script_errors = ctx.run
                pending = ctx.notification_queue
              end
            rescue ex : ScriptContext::Error
              # A `document.*` helper refused a nested write: surface the
              # recorded ServiceError with its native status (B-30). A
              # script bug with no recorded refusal becomes a 422 carrying
              # the Lua error message (B-131).
              return Telemetry.record_error(span, ScriptContext.refusal_or_script_error(delete_ctx, ex))
            end
            unless script_errors.empty?
              return Telemetry.record_error(span, Facet::ServiceError.new(422, "Script validation failed", details: script_errors))
            end
          end

          # 4. Insert the delete mutation.
          #
          # Wrapped in a transaction (ignoring any outer transaction) so the
          # mutation insert + cascade deletes + projection trigger fire
          # atomically. Per the contract: any mutation must be transactional.
          mut_id, child_mut_ids = Database.with_transaction(db, ignore_if_set: true) do |txn|
            this_mut_id = Mutation::Client.delete(
              txn,
              domain,
              doc_type,
              doc_id,
              actioner_id: actioner_id,
              provenance: prov,
              cause: cause,
              mutation_id: mut_id,
            )

            # Drop the document's `artifact_references` rows so a tombstoned
            # document stops holding artifact bytes alive through this
            # projection. A rollback replay repopulates on the snapshot
            # content.
            ArtifactRefs.clear_guc(txn, domain, doc_id)

            # 5. Cascade-delete child documents (composition tree).
            # Children are linked via meta->>'parent_id' and live in the same
            # domain as the parent. Each cascade entry mirrors the parent's
            # delete semantics (including `reentrant`) so children are
            # tombstoned recursively.
            this_child_mut_ids = cascade_delete_children(
              txn, domain, defn, doc_id, actioner_id, resolved_cause, prov,
              reentrant,
            )
            {this_mut_id, this_child_mut_ids}
          end
          span["cascaded_deletes"] = child_mut_ids.size.to_s

          span["mutation_id"] = mut_id

          Event::Publisher.enqueue(
            domain: domain, doc_type: doc_type, doc_id: doc_id,
            event: "deleted", mutation_id: mut_id, actioner_id: actioner_id,
            cause: resolved_cause.to_json_any, reentrant: reentrant,
          )

          # Aggregate push: a direct delete of a child also emits one
          # `child_changed` frame keyed to the parent. Cascade children are
          # suppressed — the parent's own `deleted` frame covers the
          # teardown.
          enqueue_child_changed_delete(db, domain, doc_type, doc_id, proj,
            mut_id, actioner_id, resolved_cause, reentrant)

          # Parent recompute: a deleted composition child is a mutation of
          # that child — the parent's relationship-named fields re-run and
          # see the tombstone excluded. A recompute-caused driving write
          # skips the walk (the loop guard).
          if recompute_error = Recompute.after_child_mutation(db, domain, doc_type, doc_id, mut_id, resolved_cause, prov, actioner_id)
            return Telemetry.record_error(span, recompute_error)
          end

          # Drain the delete hook's notification queue now that the
          # mutation (and its cascades) persisted. `doc_ref = nil` entries
          # resolve to the deleted document.
          Notification::Queue.drain(db, pending, domain, doc_type, doc_id)

          Result.new(mutation_id: mut_id)
        end
      end

      # ── Private helpers ──────────────────────────────────────────

      # Preflight guards for a delete (see the call site in `call`):
      # the Domain-deletion refusal, the definition lookup, the projection
      # fetch with its deleted check, and the role-authority boundary for
      # the IAM doctypes — a caller whose level sits below the account's
      # current ceiling (or the role's current level) cannot delete it.
      # The boundary is independent of route-level `skip_authorization`;
      # only the System principal bypasses it.
      private def self.delete_preflight(
        db : DB::Connection,
        span : OpenTelemetry::API::Span,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext,
      ) : {Doctype::DoctypeDefinition, Mutation::Client::Projection} | Facet::ServiceError
        if domain_delete_refusal?(domain, doc_type)
          return Facet::ServiceError.new(
            422,
            "core.Domain documents cannot be deleted directly — " \
            "use POST /Api/core/Domain/:id/drop"
          )
        end

        defn = Doctype::DefinitionStore.fetch!(db, "#{domain}.#{doc_type}")
        return defn if defn.is_a?(Facet::ServiceError)

        proj_result = Mutation::Client.fetch_projection_or_404(db, domain, doc_type, doc_id, "Document #{domain}.#{doc_type}##{doc_id} not found")
        return proj_result if proj_result.is_a?(Facet::ServiceError)
        proj = proj_result.as(Mutation::Client::Projection)

        return Facet::ServiceError.new(410, "Document #{domain}.#{doc_type}##{doc_id} was already deleted") if proj.deleted_at

        error = RBAC::RoleAuthority.authorize_transition(db, "delete", domain, doc_type, proj.content, nil, auth_context)
        return error if error

        {defn, proj}
      end

      # Enqueues the aggregate child_changed frame after a delete
      # persisted. Fires only when the deleted document carried
      # `meta.parent_id`; the helper suppresses cascade-kind causes.
      private def self.enqueue_child_changed_delete(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        proj : Mutation::Client::Projection,
        mut_id : String,
        actioner_id : String,
        resolved_cause : Mutation::Cause,
        reentrant : Bool,
      ) : Nil
        parent_id = proj.meta["parent_id"]?.try(&.as_s?)
        return unless parent_id

        Event::Publisher.enqueue_child_changed(
          db, domain, doc_type, doc_id,
          parent_doc_id: parent_id, action: "deleted",
          mutation_id: mut_id, actioner_id: actioner_id,
          cause: resolved_cause, reentrant: reentrant,
        )
      end

      # True when the delete targets a `core.Domain` document — refused in
      # `call` before any other work (see the 0.5 step there).
      private def self.domain_delete_refusal?(domain : String, doc_type : String) : Bool
        domain == "core" && doc_type == "Domain"
      end

      # Step-0 delete gate. Returns `nil` when the caller is authorized, or
      # the denial error otherwise: a class-level denial — no delete
      # permission on the doctype at all — answers `403`; a scoped caller
      # whose row check fails answers `404`, so an inaccessible document
      # is indistinguishable from a missing one. `skip_authorization`
      # bypasses the enforcer for callers that already enforced a stronger
      # gate. `authorize_path` overrides the gate path — the composition
      # path on nested child routes, the bare path on flat routes.
      private def self.authorize_delete(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        auth_context : RBAC::AuthContext,
        skip_authorization : Bool,
        authorize_path : Array(String)? = nil,
      ) : Facet::ServiceError?
        return nil if skip_authorization

        # Class-level denial first — no row state is read for a caller the
        # gate denies outright.
        if RBAC::WriteEnforcer.action_denied?("delete", domain, doc_type, auth_context, authorize_path)
          IAM::Helpers.write_layer1_denial(db, auth_context, "delete", domain, authorize_path || [doc_type])
          return Facet::ServiceError.new(403, "Forbidden")
        end

        return nil if RBAC::WriteEnforcer.authorize_delete(db, domain, doc_type, doc_id, auth_context, authorize_path)

        IAM::Helpers.write_layer1_denial(db, auth_context, "delete", domain, authorize_path || [doc_type])
        Facet::ServiceError.new(404, "Document #{doc_id} not found")
      end

      # ── Cascade ──────────────────────────────────────────────────

      # Recursively soft-deletes every live **owned** child of `parent_id`.
      #
      # Only children whose own doctype declares `member_of` equal to the
      # parent's doctype are cascaded. A `children:` entry alone is a nested
      # routing rule, not ownership — routable associates (e.g. a Deal listed
      # under a Prospect) survive parent deletion. True ownership requires the
      # child doctype to declare `member_of: <parent doctype>`, which is the
      # single source of truth for the composition link.
      #
      # Owned children are looked up by `meta->>'parent_id'` in the same
      # domain as the parent. Each is tombstoned via `Mutation::Client.delete`
      # so the same projection trigger and event semantics apply as for a
      # direct delete. A child's own children are walked before the child's
      # own delete mutation is inserted, mirroring a depth-first cascade.
      #
      # Every child tombstone is stamped with a `cascade` cause: `parent`
      # is the delete mutation of its direct parent, `trace` is inherited
      # from the root delete, so the whole composition subtree groups under
      # one causal cluster. `reentrant` mirrors the parent's flag onto every
      # cascade event so a hook-driven delete gates its whole subtree.
      private def self.cascade_delete_children(
        db : DB::Connection,
        parent_domain : String,
        parent_defn : Doctype::DoctypeDefinition,
        parent_id : String,
        actioner_id : String,
        parent_cause : Mutation::Cause,
        provenance : Mutation::Provenance,
        reentrant : Bool = false,
      ) : Array(String)
        return [] of String if parent_defn.children.empty?

        parent_doctype = parent_defn.doctype
        child_mut_ids = [] of String

        parent_defn.children.each_value do |child_def|
          child_doctype = child_def.doctype
          child_defn = Doctype::DefinitionStore.fetch(db, "#{parent_domain}.#{child_doctype}")
          next unless child_defn && child_defn.member_of == parent_doctype

          child_ids = Mutation::Client.owned_child_ids(db, parent_domain, child_doctype, parent_id)

          child_ids.each do |child_id|
            child_cause = Mutation::Cause.new(
              kind: Mutation::CauseKind::Cascade,
              source: "#{parent_domain}.#{parent_doctype}:#{parent_id}",
              parent: parent_cause.trace,
              trace: parent_cause.trace,
            )

            child_mut_ids.concat(
              cascade_delete_children(db, parent_domain, child_defn, child_id, actioner_id, child_cause, provenance, reentrant)
            )

            child_mut = Mutation::Client.delete(
              db, parent_domain, child_doctype, child_id,
              actioner_id: actioner_id, provenance: provenance, cause: child_cause,
            )
            child_mut_ids << child_mut

            Event::Publisher.enqueue(
              domain: parent_domain, doc_type: child_doctype, doc_id: child_id,
              event: "deleted", mutation_id: child_mut, actioner_id: actioner_id,
              cause: child_cause.to_json_any, reentrant: reentrant,
            )
          end
        end

        child_mut_ids
      end
    end
  end
end
