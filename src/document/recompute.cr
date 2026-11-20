# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"
require "pg"
require "json"
require "../mutation/client"
require "../doctype/definition_store"
require "./compute"
require "./update"

module Facet
  module Document
    # Parent recompute on child mutation (B-110 part 2).
    #
    # A computed field whose `compute_when` names a **child relationship**
    # re-runs when the children change. The value lives on the parent; the
    # trigger lives on the child. The document services call
    # `after_child_mutation` right after a child mutation persisted — inside
    # the same transaction — and this module walks the composition tree
    # upward: it re-runs the parent's relationship-named computed fields
    # against the parent content (children staged into `ctx.children`) and
    # writes the result with a partial-patch `Document::Update.call` under
    # the system auth context, so the change lands in the audit log. Then it
    # continues upward — the parent may itself be a composition child whose
    # grandparent computes over it — until no parent remains, no
    # relationship matches, the parent content does not change, or the
    # composition-depth cap is reached.
    #
    # **Cause and loop guard.** Each recompute write carries a cause of kind
    # `replication` named `recompute` (see `doc/backend/mutation.md`) whose
    # `parent` is the driving child mutation's id and whose `trace` inherits
    # the driving cluster. The services' trigger skips the walk when the
    # driving mutation's cause is itself a recompute write — the same
    # pattern as the hooks' `reentrant` flag: a parent update hook that
    # writes a child produces a recompute-descended child write whose walk
    # is skipped, so hook → child → recompute → hook cannot loop. The walk
    # itself continues upward explicitly (not through the guarded trigger),
    # which is what makes the grandparent cascade work while the guard
    # holds.
    #
    # **Limits.** Sidecar mutations do not trigger: a sidecar attaches
    # through a reference column, not through `meta.parent_id`, so the walk
    # resolves no parent. The walk runs inside the caller's transaction when
    # one is open (every HTTP, compound-create, and agent-tool path holds
    # one); a direct service caller without an ambient transaction gets a
    # separate commit for the recompute write.
    module Recompute
      Log = ::Log.for("facet.document.recompute")

      # `cause_name` of a recompute write. The loop guard matches on this
      # name so genuine `replication` writes (replica-field propagation,
      # named `"<source>.<field>"`) still trigger the walk.
      CAUSE_NAME = "recompute"

      # The actioner stamped on recompute writes — system work, attributed
      # like the compaction snapshot's `system:compaction`.
      SYSTEM_ACTIONER = "system:recompute"

      # Depth cap of the upward composition walk. Composition chains are
      # shallow; the cap also stops a corrupt parent cycle (same bound as
      # `Search::MAX_COMPOSITION_DEPTH`).
      MAX_COMPOSITION_DEPTH = 8

      # Runs the recompute walk for a child mutation that just persisted.
      # Call inside the child mutation's transaction, after the child's
      # mutation insert. Returns a `ServiceError` when the parent's compute
      # or the recompute write fails — the caller surfaces it so the whole
      # operation (child mutation included) rolls back instead of persisting
      # a stale aggregate.
      #
      # `driving_mutation_id` is the child mutation's ULID; `cause` is its
      # resolved cause. A recompute-caused driving mutation skips the walk
      # (the loop guard).
      def self.after_child_mutation(
        db : DB::Connection,
        domain : String,
        child_doc_type : String,
        child_doc_id : String,
        driving_mutation_id : String,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actioner_id : String,
      ) : Facet::ServiceError?
        return nil if recompute_write?(cause)
        walk(db, domain, child_doc_type, child_doc_id, driving_mutation_id, cause, provenance, actioner_id, 0)
      end

      # True when the cause names a recompute write. `child_of` templates
      # preserve kind and name, so every write descended from a recompute
      # write (parent update hooks writing children through the Lua
      # `document.*` helpers) carries it too.
      def self.recompute_write?(cause : Mutation::Cause?) : Bool
        return false unless cause
        cause.kind == Mutation::CauseKind::Replication && cause.name == CAUSE_NAME
      end

      # ── Private ──────────────────────────────────────────────────────

      # One level of the walk: recompute the mutated document's parent, then
      # continue from the parent. `driving_cause` is the resolved cause of
      # the mutation that drove this level.
      private def self.walk(
        db : DB::Connection,
        domain : String,
        child_doc_type : String,
        child_doc_id : String,
        driving_mutation_id : String,
        driving_cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actioner_id : String,
        depth : Int32,
      ) : Facet::ServiceError?
        current_doc_type = child_doc_type
        current_doc_id = child_doc_id
        current_mut_id = driving_mutation_id
        current_cause = driving_cause

        while depth < MAX_COMPOSITION_DEPTH
          scope = resolve_parent(db, domain, current_doc_type, current_doc_id)
          return nil if scope.nil?

          rel_set = matching_relationships(scope.definition, current_doc_type)
          return nil if rel_set.empty?

          step = recompute_parent(db, domain, scope, rel_set, current_mut_id, current_cause, provenance, actioner_id)
          return step.error if step.error
          # The parent content did not change — nothing above it can change
          # either, so the chain stops here.
          step_mut = step.mutation_id
          return nil if step_mut.nil?

          current_doc_type = scope.doctype
          current_doc_id = scope.id
          current_mut_id = step_mut
          current_cause = step.cause
          depth += 1
        end
        nil
      end

      # Everything one walk level needs about the mutated document's parent.
      private record ParentScope,
        doctype : String,
        id : String,
        projection : Mutation::Client::Projection,
        definition : Doctype::DoctypeDefinition

      # One completed or refused recompute write. `mutation_id` nil means
      # the parent content did not change (no write); `error` non-nil means
      # the compute or the write failed and the caller must roll back.
      private record RecomputeStep,
        mutation_id : String?,
        cause : Mutation::Cause?,
        error : Facet::ServiceError?

      # Resolves the parent scope of the mutated document: the parent
      # projection (live), its definition, and the linkage. Returns nil when
      # any step cannot resolve — the walk degrades to a no-op.
      private def self.resolve_parent(
        db : DB::Connection,
        domain : String,
        child_doc_type : String,
        child_doc_id : String,
      ) : ParentScope?
        child_proj = fetch_projection(db, domain, child_doc_type, child_doc_id)
        return nil if child_proj.nil?

        parent_doctype = parent_doctype_of(db, domain, child_doc_type)
        return nil if parent_doctype.nil?

        parent_id = child_proj.meta.as_h?.try(&.["parent_id"]?).try(&.as_s?)
        return nil if parent_id.nil? || parent_id.empty?

        parent_proj = fetch_projection(db, domain, parent_doctype, parent_id)
        return nil if parent_proj.nil? || parent_proj.deleted_at

        parent_defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{parent_doctype}")
        return nil unless parent_defn.is_a?(Doctype::DoctypeDefinition)

        ParentScope.new(parent_doctype, parent_id, parent_proj, parent_defn)
      end

      # The parent's child relationships that point at the mutated child's
      # doctype — the relationships whose change this mutation is.
      private def self.matching_relationships(
        parent_defn : Doctype::DoctypeDefinition,
        child_doc_type : String,
      ) : Set(String)
        names = Set(String).new
        parent_defn.children.each do |rel_name, child|
          names << rel_name if child.doctype == child_doc_type
        end
        names
      end

      # Re-runs the parent's relationship-named computed fields against the
      # parent content (children staged into ctx.children) and writes the
      # changed values with a partial-patch update carrying the recompute
      # cause. Returns the step outcome for the driver.
      private def self.recompute_parent(
        db : DB::Connection,
        domain : String,
        scope : ParentScope,
        rel_set : Set(String),
        driving_mutation_id : String,
        driving_cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        actioner_id : String,
      ) : RecomputeStep
        parent_defn = scope.definition

        # Only fields whose `compute_when` names one of those relationships
        # run in this pass. No match — no recompute.
        to_run = parent_defn.computed_field_names.select do |field_name|
          compute_when = parent_defn.fields[field_name].compute_when
          !compute_when.nil? && compute_when.any? { |trigger| rel_set.includes?(trigger) }
        end
        return RecomputeStep.new(nil, nil, nil) if to_run.empty?

        script = parent_defn.script
        return RecomputeStep.new(nil, nil, nil) if script.nil?

        # The fields the compute pass will run (the selection rule `call`
        # applies) — their changed values land in the patch.
        ran = Compute.candidate_fields(parent_defn, rel_set)
        children_ctx = Compute.stage_children(db, domain, parent_defn, scope.id, rel_set)

        computed, errors = Compute.call(
          script,
          parent_defn,
          scope.projection.content,
          changed_fields: rel_set,
          actioner_id: actioner_id,
          db: db,
          domain: domain,
          children: children_ctx,
          doc_id: scope.id,
        )
        unless errors.empty?
          return RecomputeStep.new(nil, nil, Facet::ServiceError.new(422, "Computed fields failed", details: errors))
        end

        patch = changed_computed_fields(field_names: ran, before: scope.projection.content, after: computed)
        return RecomputeStep.new(nil, nil, nil) if patch.empty?

        cause = Mutation::Cause.new(
          kind: Mutation::CauseKind::Replication,
          name: CAUSE_NAME,
          event: "updated",
          source: "#{domain}.#{scope.doctype}:#{scope.id}",
          parent: driving_mutation_id,
          trace: driving_cause.try(&.trace) || driving_mutation_id,
        )

        result = Update.call(
          db, domain, scope.doctype, scope.id,
          JSON::Any.new(patch).to_json,
          RBAC::AuthContext.system,
          cause: cause,
          provenance: provenance || Mutation::Provenance.internal,
          reentrant: true,
          allow_computed_writes: true,
          actioner_id: SYSTEM_ACTIONER,
        )
        case result
        in Update::Result
          RecomputeStep.new(result.mutation_id, cause.resolve(result.mutation_id), nil)
        in Facet::ServiceError
          RecomputeStep.new(nil, nil, result)
        end
      end

      # The parent's doctype: the child definition's `member_of`. Composition
      # is mutual, so a child carrying `meta.parent_id` always names its
      # parent doctype here; a one-sided edge fails composition validation
      # before it can reach the walk.
      private def self.parent_doctype_of(db : DB::Connection, domain : String, child_doc_type : String) : String?
        child_defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{child_doc_type}")
        return nil unless child_defn.is_a?(Doctype::DoctypeDefinition)
        child_defn.member_of
      end

      # The computed fields whose value differs between the pre-compute and
      # post-compute content. A cleared field (nil) patches as JSON null —
      # the merge-patch form that removes the key.
      private def self.changed_computed_fields(
        field_names : Array(String),
        before : JSON::Any,
        after : JSON::Any,
      ) : Hash(String, JSON::Any)
        before_h = before.as_h? || {} of String => JSON::Any
        after_h = after.as_h? || {} of String => JSON::Any

        patch = {} of String => JSON::Any
        field_names.each do |field_name|
          old_value = before_h[field_name]?
          new_value = after_h[field_name]?
          next if old_value == new_value
          patch[field_name] = new_value || JSON::Any.new(nil)
        end
        patch
      end

      # Fetches a projection row, returning nil (not found / tombstone
      # query error) instead of raising — the walk degrades to a no-op when
      # a row is unreachable.
      private def self.fetch_projection(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Mutation::Client::Projection?
        Mutation::Client.fetch_projection(db, domain, doc_type, doc_id)
      rescue DB::NoResultsError | PG::Error
        nil
      end
    end
  end
end
