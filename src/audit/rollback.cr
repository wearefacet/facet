# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../mutation/client"
require "../mutation/json_diff"
require "../mutation/retention"
require "../document/snapshot_persist"
require "../event"
require "../rbac"
require "../error"
require "./restore"
require "./replay"
require "opentelemetry"

module Facet
  module Audit
    # Service for rolling back documents to earlier states.
    #
    # Two scopes:
    #
    # - `document` — replay one document's mutations up to the target and
    #   persist the result as a `snapshot`. A `delete` target resolves to the
    #   mutation before it (a restore).
    # - `cluster` — undo a whole causal cluster (`cause_trace`): every document
    #   the cluster touched is restored to its pre-cluster state; documents
    #   born inside the cluster (or already tombstoned before it) are
    #   re-tombstoned. RBAC gates on the cluster's root document, with a
    #   fallback to update rights on every affected document.
    #
    # The rollback algorithm per document:
    # 1. Fetch the target mutation by ULID to get (domain, doc_type, doc_id, idx)
    # 2. Find the most recent `snapshot` mutation with idx <= target.idx
    # 3. If a snapshot is found, start from its content; otherwise start from `{}`
    # 4. Replay all mutations from snapshot.idx+1 (or 1) up to target.idx
    # 5. Persist the result as a new `snapshot` mutation
    #
    # The snapshot persists the replayed meta too. It carries the projection
    # meta as of the target state, so a restored child keeps `parent_id`.
    #
    # A restore also brings back the composition children that the undone
    # delete cascade-tombstoned. A restore is a rollback whose target
    # document is tombstoned: the target itself is a delete, or the
    # document's latest mutation is a delete. Each child replays to its own
    # pre-delete state through the same persist path. Each child passes the
    # same RBAC gates as the parent before any write. One denied child
    # aborts the whole restore with `403`. The result lists every restored
    # child.
    #
    # The rollback is recorded with actioner_id "system:rollback" so it is
    # traceable in the audit log.
    module Rollback
      enum Scope
        Document
        Cluster
      end

      record Result,
        projection : Mutation::Client::Projection,
        mutation_id : String,
        # Composition children restored together with a restore. Empty for
        # every other rollback.
        cascade_restored : Array(CascadeRestored) = [] of CascadeRestored

      # One composition child the restore brought back.
      record CascadeRestored,
        domain : String,
        doc_type : String,
        doc_id : String,
        mut_id : String

      # One queued child restore: a `cascade` delete tombstoned the child,
      # and the replay target is the mutation before that delete.
      record CascadeChild,
        domain : String,
        doc_type : String,
        doc_id : String,
        target_mut_id : String,
        target_idx : Int32

      # One document's undo inside a cluster rollback.
      record DocumentUndo,
        domain : String,
        doc_type : String,
        doc_id : String,
        mutation_id : String,
        # `restored` — replayed to the pre-cluster state and snapshotted;
        # `deleted` — the document was born inside the cluster (or was already
        # tombstoned before it), so the undo re-tombstones it.
        outcome : String

      record ClusterResult,
        documents : Array(DocumentUndo),
        # Every undo mutation shares one cause trace — the undo itself is one
        # auditable causal cluster.
        trace : String

      # Hard cap on cluster size. Beyond this the undo is refused — an
      # unbounded cluster (a runaway hook) must not silently rewrite ten
      # thousand documents in one call.
      CLUSTER_MUTATION_CAP = 1000

      # Rolls back a document (or a whole causal cluster) to the state at the
      # given mutation.
      #
      # Requires an `auth_context` for RBAC authorization.
      # Denied → 403.
      #
      # Returns `Result` (document scope), `ClusterResult` (cluster scope), or
      # `Error` on failure.
      def self.call(
        db : DB::Connection,
        mutation_id : String,
        auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
        reentrant : Bool = false,
        scope : Scope = Scope::Document,
        retention_scope : NamedTuple(domain: String, doc_type: String)? = nil,
      ) : Result | ClusterResult | Facet::ServiceError
        Facet::Telemetry.trace "audit.rollback" do |span|
          span["mutation_id"] = mutation_id
          span["scope"] = scope.to_s.underscore

          # Preserve the "system:rollback" marker for system-bypass rollbacks
          # so they remain distinguishable from periodic snapshots in the audit log.
          actioner_id = auth_context.system? ? "system:rollback" : auth_context.account_id

          # 1. Fetch the target mutation
          target = fetch_mutation(db, mutation_id, retention_scope)
          if target.is_a?(Facet::ServiceError)
            return Telemetry.record_error(span, target)
          end
          t = target.as(NamedTuple(domain: String, doc_type: String, doc_id: String, idx: Int32, action: String, cause_trace: String))

          case scope
          in .document?
            result = rollback_document(db, t, mutation_id, actioner_id, auth_context, reentrant)
            if result.is_a?(Result)
              span["doc_id"] = result.projection.id
              span["new_mutation_id"] = result.mutation_id
              result
            else
              Telemetry.record_error(span, result)
            end
          in .cluster?
            result = rollback_cluster(db, t, actioner_id, auth_context, reentrant)
            if result.is_a?(ClusterResult)
              span["documents"] = result.documents.size.to_s
              span["new_mutation_id"] = result.trace
              result
            else
              Telemetry.record_error(span, result)
            end
          end
        end
      end

      # ── Document scope ────────────────────────────────────────────

      # Replays one document's history up to the target mutation and persists
      # the result as a snapshot. A `delete` target resolves to the mutation
      # before the delete first.
      private def self.rollback_document(
        db : DB::Connection,
        t : NamedTuple(domain: String, doc_type: String, doc_id: String, idx: Int32, action: String, cause_trace: String),
        mutation_id : String,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        reentrant : Bool,
      ) : Result | Facet::ServiceError
        t_domain = t[:domain]
        t_doc_type = t[:doc_type]
        t_doc_id = t[:doc_id]
        t_idx = t[:idx]
        t_action = t[:action]

        # 0. Authorize the rollback as an update on the target document
        unless RBAC::WriteEnforcer.authorize_update(db, t_domain, t_doc_type, t_doc_id, auth_context)
          return Facet::ServiceError.new(403, "rollback refused: your role cannot write the target document")
        end

        # Rollback to a delete restores the document: the target state is the
        # content recorded by the mutation immediately before the delete
        # (same resolution shape as `Audit::Restore`, scoped to the clicked
        # mutation rather than the document's most recent delete). The
        # snapshot clears `deleted_at`, so the document is live again.
        # Degenerate history (a delete with no preceding mutation) keeps 422.
        target_mutation_id = mutation_id
        undone_delete_id : String? = nil
        if t_action == "delete"
          undone_delete_id = mutation_id
          prior = resolve_pre_delete_target(db, t_domain, t_doc_type, t_doc_id, t_idx, mutation_id)
          if prior.is_a?(Facet::ServiceError)
            return prior
          end
          t_idx = prior[:idx]
          target_mutation_id = prior[:id]
        end

        # 0.5. Role-authority boundary: replay the target state and run the
        # IAM transition check (target protection plus the final-roles /
        # role-power rules) on the actual current-versus-replayed
        # transition, before anything persists. A rollback that would
        # resurrect stronger IAM state answers 403 here.
        rollback_error = authorize_rollback_transition(
          db, t_domain, t_doc_type, t_doc_id, t_idx, auth_context,
        )
        return rollback_error if rollback_error

        # 0.6. Cascade restore. A restore also brings back the composition
        # children the undone delete cascade-tombstoned. The restore
        # endpoint passes the pre-delete mutation, so there the undone
        # delete is the document's latest row. Every child runs the same
        # gates as a single-document rollback BEFORE any write. One denial
        # aborts the whole restore: no writes, no events, `403`.
        cascade_children = [] of CascadeChild
        undone_delete = undone_delete_id || latest_delete_id(db, t_domain, t_doc_type, t_doc_id)
        if undone_delete
          collected = collect_cascade_restores(db, undone_delete, auth_context)
          return collected if collected.is_a?(Facet::ServiceError)
          cascade_children = collected
        end

        # 1. All-or-nothing: the parent snapshot and every child restore
        # share one transaction. The restore route already wraps this call
        # in one; a standalone call opens one here. The shape mirrors the
        # cluster undo.
        parent, restored = Database.with_transaction(db, ignore_if_set: true) do |txn|
          result = rollback_document_to(
            txn, t_domain, t_doc_type, t_doc_id, t_idx, target_mutation_id,
            actioner_id, auth_context, reentrant, nil,
          )
          children = cascade_children.map do |child|
            child_result = rollback_document_to(
              txn, child.domain, child.doc_type, child.doc_id,
              child.target_idx, child.target_mut_id,
              actioner_id, auth_context, reentrant, nil,
            )
            CascadeRestored.new(
              domain: child.domain, doc_type: child.doc_type,
              doc_id: child.doc_id, mut_id: child_result.mutation_id,
            )
          end
          {result, children}
        end

        Result.new(
          projection: parent.projection,
          mutation_id: parent.mutation_id,
          cascade_restored: restored,
        )
      end

      # Replays one document's history up to `target_idx` and persists a
      # snapshot. `trace` is the undo's causal cluster id — `nil` mints a fresh
      # one (a single-document rollback starts its own cluster). The snapshot
      # row's own id is minted per call, so two documents restored by the same
      # cluster undo never share a mutation id.
      private def self.rollback_document_to(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        target_idx : Int32,
        target_mutation_id : String,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        reentrant : Bool,
        trace : String?,
      ) : Result
        # 2-4. Replay the document history up to the target (from the last
        # snapshot at or below it), then persist the result as a snapshot
        # mutation. The cause is kind `rollback` with `parent` bound to the
        # target mutation id, so audit consumers can trace the snapshot
        # back to the exact mutation it rolled back to (mirrors the
        # published event name). The snapshot ULID is minted here so the
        # cause trace resolves to it before the event is enqueued. With an
        # explicit `trace` (cluster scope) the row id is minted separately
        # — only the trace is shared.
        state = Replay.state_at(db, domain, doc_type, doc_id, target_idx)
        row_id = Mutation::Client.new_id
        snapshot_id = trace || row_id
        cause = Mutation::Cause.new(
          kind: Mutation::CauseKind::Rollback,
          event: "rolled_back",
          parent: target_mutation_id,
          trace: snapshot_id,
        )
        persist_snapshot(db, domain, doc_type, doc_id, state.content, actioner_id, cause, reentrant, provenance: Mutation::Provenance.from(auth_context), mutation_id: row_id, meta: state.meta)
      end

      # Role-authority and field-visibility boundary for one rollback
      # transition: replays the target state, reads the document's current
      # content (a tombstone keeps its payload until pruned), then runs —
      # in order — the IAM transition check and the invisible-field check
      # on the actual current-versus-replayed transition. The selected
      # mutation's own diff is irrelevant: the guard compares the real
      # states. Non-IAM targets still get the field check; System and
      # Preview keep their bypasses.
      private def self.authorize_rollback_transition(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        target_idx : Int32,
        auth_context : RBAC::AuthContext,
      ) : Facet::ServiceError?
        state = Replay.state_at(db, domain, doc_type, doc_id, target_idx)
        current = current_projection_content(db, domain, doc_type, doc_id)
        error = RBAC::RoleAuthority.authorize_transition(db, "update", domain, doc_type, current, state.content, auth_context)
        return error if error

        definition = Doctype::DefinitionStore.fetch(db, "#{domain}.#{doc_type}")
        return nil if definition.nil?

        RBAC::WriteEnforcer.authorize_field_changes(definition, current, state.content, auth_context)
      end

      # Cluster preflight: authorizes every document's undo — the delete
      # branch against the current content, the restore branch against the
      # replayed pre-cluster state — before any write happens.
      private def self.authorize_cluster_transition(
        db : DB::Connection,
        groups : Hash(Tuple(String, String, String), NamedTuple(id: String, idx: Int32)),
        auth_context : RBAC::AuthContext,
      ) : Facet::ServiceError?
        groups.each do |doc, first|
          domain = doc[0]
          doc_type = doc[1]
          doc_id = doc[2]
          if first[:idx] == 1 || pre_cluster_state_is_tombstone?(db, domain, doc_type, doc_id, first[:idx])
            # The undo re-tombstones: authorize the delete against the
            # document's current content.
            current = current_projection_content(db, domain, doc_type, doc_id)
            error = RBAC::RoleAuthority.authorize_transition(db, "delete", domain, doc_type, current, nil, auth_context)
          else
            error = authorize_rollback_transition(db, domain, doc_type, doc_id, first[:idx] - 1, auth_context)
          end
          return error if error
        end
        nil
      end

      # The document's current content, or an empty object when the
      # projection row is gone (a pruned or never-persisted document).
      # Tombstones keep their content, so a restore sees the real
      # current-versus-replayed diff.
      private def self.current_projection_content(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : JSON::Any
        proj = Mutation::Client.fetch_projection(db, domain, doc_type, doc_id)
        proj ? proj.content : JSON.parse("{}")
      rescue PG::Error | DB::NoResultsError
        JSON.parse("{}")
      end

      # ── Cluster scope ──────────────────────────────────────────────

      # Undoes a whole causal cluster: every document the cluster touched is
      # restored to its pre-cluster state, in one transaction.
      #
      # Per document (the cluster's first mutation on it is `m0`):
      # - `m0.idx > 1` and the mutation before it is not a delete → replay to
      #   that mutation and snapshot (restore).
      # - `m0.idx == 1` (the document was born inside the cluster) or the
      #   mutation before it is a delete (the document was already tombstoned
      #   before the cluster) → the undo is a soft delete (re-tombstone). No
      #   delete hooks re-run — the cluster's writes are undone, not
      #   re-executed.
      #
      # RBAC gates on the cluster's root document (the trace root's document —
      # where the action was born), with a fallback to update rights on every
      # affected document (a cron/hook-born cluster's origin document may be
      # unrelated to the undo, or a system document the actor cannot edit).
      # One denial → 403; the undo is all-or-nothing in one transaction.
      private def self.rollback_cluster(
        db : DB::Connection,
        t : NamedTuple(domain: String, doc_type: String, doc_id: String, idx: Int32, action: String, cause_trace: String),
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        reentrant : Bool,
      ) : ClusterResult | Facet::ServiceError
        trace = t[:cause_trace]

        # 1. Group the cluster's mutations by document.
        groups = cluster_groups(db, trace)
        if groups.nil?
          return Facet::ServiceError.new(422, "Cluster #{trace} has more than #{CLUSTER_MUTATION_CAP} mutations; refusing to undo it in one call")
        end
        if groups.empty?
          return Facet::ServiceError.new(404, "No mutations found for cluster #{trace}")
        end

        # 2. RBAC: update on the root document, or on every affected document.
        root = fetch_mutation(db, trace, nil)
        root_ok = !root.is_a?(Facet::ServiceError) &&
                  RBAC::WriteEnforcer.authorize_update(db, root[:domain], root[:doc_type], root[:doc_id], auth_context)
        all_ok = !root_ok && groups.keys.all? do |doc|
          RBAC::WriteEnforcer.authorize_update(db, doc[0], doc[1], doc[2], auth_context)
        end
        unless root_ok || all_ok
          return Facet::ServiceError.new(403, "rollback refused: your role cannot write every document in the cluster")
        end

        # 2a. Role-authority preflight: every resulting restore and delete
        # in the cluster runs the IAM transition check BEFORE any document
        # is written. One denial aborts the complete cluster.
        if auth_error = authorize_cluster_transition(db, groups, auth_context)
          return auth_error
        end

        undo_trace = Mutation::Client.new_id
        undos = [] of DocumentUndo

        # 3. All-or-nothing: the whole undo in one transaction.
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          groups.each do |doc, first|
            domain = doc[0]
            doc_type = doc[1]
            doc_id = doc[2]
            if first[:idx] == 1 || pre_cluster_state_is_tombstone?(txn, domain, doc_type, doc_id, first[:idx])
              mut_id = Mutation::Client.delete(
                txn, domain, doc_type, doc_id,
                actioner_id: actioner_id,
                provenance: Mutation::Provenance.from(auth_context),
                cause: Mutation::Cause.new(
                  kind: Mutation::CauseKind::Rollback,
                  event: "rolled_back",
                  parent: first[:id],
                  trace: undo_trace,
                ),
                mutation_id: Mutation::Client.new_id,
              )
              undos << DocumentUndo.new(
                domain: domain, doc_type: doc_type, doc_id: doc_id,
                mutation_id: mut_id, outcome: "deleted",
              )
            else
              result = rollback_document_to(
                txn, domain, doc_type, doc_id, first[:idx] - 1,
                prior_mutation_id(txn, domain, doc_type, doc_id, first[:idx]),
                actioner_id, auth_context, reentrant, undo_trace,
              )
              undos << DocumentUndo.new(
                domain: domain, doc_type: doc_type, doc_id: doc_id,
                mutation_id: result.mutation_id, outcome: "restored",
              )
            end
          end
        end

        # 4. Events after commit — one per document.
        undos.each do |undo|
          Event::Publisher.enqueue(
            domain: undo.domain, doc_type: undo.doc_type, doc_id: undo.doc_id,
            event: undo.outcome == "restored" ? "rolled_back" : "deleted",
            mutation_id: undo.mutation_id,
            actioner_id: actioner_id,
            cause: Mutation::Cause.new(
              kind: Mutation::CauseKind::Rollback,
              event: "rolled_back",
              trace: undo_trace,
            ).to_json_any,
            reentrant: reentrant,
          )
        end

        ClusterResult.new(documents: undos, trace: undo_trace)
      end

      # Groups a cluster's mutations by document. Returns the earliest
      # mutation per document as `{(domain, doc_type, doc_id) => {id, idx}}`,
      # or `nil` when the cluster exceeds the mutation cap.
      private def self.cluster_groups(
        db : DB::Connection,
        trace : String,
      ) : Hash(Tuple(String, String, String), NamedTuple(id: String, idx: Int32))?
        earliest = Hash(Tuple(String, String, String), NamedTuple(id: String, idx: Int32)).new
        count = 0
        rs = db.query(
          "SELECT domain, doc_type, doc_id, idx, id FROM mutations WHERE cause_trace = $1 ORDER BY idx ASC",
          trace
        )
        rs.each do
          count += 1
          return nil if count > CLUSTER_MUTATION_CAP
          domain = rs.read(String)
          doc_type = rs.read(String)
          doc_id = rs.read(String)
          idx = rs.read(Int32)
          id = rs.read(String)
          key = {domain, doc_type, doc_id}
          current = earliest[key]?
          earliest[key] = {id: id, idx: idx} if current.nil? || idx < current[:idx]
        end
        rs.close
        earliest
      end

      # True when the document was already tombstoned before the cluster's
      # first mutation on it — the pre-cluster state is a tombstone, so the
      # undo must re-tombstone rather than resurrect stale content.
      private def self.pre_cluster_state_is_tombstone?(db : DB::Connection, domain : String, doc_type : String, doc_id : String, first_idx : Int32) : Bool
        action = db.query_one?("SELECT action FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx = $4",
          domain, doc_type, doc_id, first_idx - 1, as: String)
        action == "delete"
      end

      # The id of the mutation immediately before `first_idx` — the replay
      # target for a restore. Only called when `first_idx > 1` and the prior
      # action is not a delete.
      private def self.prior_mutation_id(db : DB::Connection, domain : String, doc_type : String, doc_id : String, first_idx : Int32) : String
        db.query_one(
          "SELECT id FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx = $4",
          domain, doc_type, doc_id, first_idx - 1, as: String
        )
      end

      # ── Private helpers ──────────────────────────────────────────

      # Fetches the target mutation row. A miss answers `404` with the
      # retention window in force: a compacted-away target, a coalesced
      # fold, and a never-existed id read the same status (the answer must
      # not confirm that an id once existed), but the message gives the
      # caller the context to self-serve — see `doc/backend/audit.md` →
      # Mutation-id shape.
      private def self.fetch_mutation(
        db : DB::Connection,
        mutation_id : String,
        retention_scope : NamedTuple(domain: String, doc_type: String)?,
      ) : NamedTuple(domain: String, doc_type: String, doc_id: String, idx: Int32, action: String, cause_trace: String) | Facet::ServiceError
        db.query_one(
          "SELECT domain, doc_type, doc_id, idx, action, cause_trace FROM mutations WHERE id = $1",
          mutation_id
        ) do |rs|
          {
            domain:      rs.read(String),
            doc_type:    rs.read(String),
            doc_id:      rs.read(String),
            idx:         rs.read(Int32),
            action:      rs.read(String),
            cause_trace: rs.read(String),
          }
        end
      rescue PG::Error | DB::NoResultsError
        Facet::ServiceError.new(404, not_found_message(db, mutation_id, retention_scope))
      end

      # The 404 body for an unknown mutation id. Names the retention window
      # in force for the target doctype when the caller's route knows one
      # (document/child rollback, restore). The global audit rollback does
      # not know the target doctype, so it names the base window — the
      # number may differ from the target doctype's override. The clause
      # drops entirely when compaction is disabled (`0` = keep forever —
      # age cannot be the reason). Keeps the `Mutation <id> not found`
      # prefix.
      private def self.not_found_message(
        db : DB::Connection,
        mutation_id : String,
        retention_scope : NamedTuple(domain: String, doc_type: String)?,
      ) : String
        prefix = "Mutation #{mutation_id} not found"
        days = if scope = retention_scope
                 Mutation::Retention.effective_days(db, scope[:domain], scope[:doc_type])
               else
                 Mutation::Retention.base_days(db)
               end
        return "#{prefix}. It may be unknown or folded by coalescing." if days.zero?

        unit = days == 1 ? "day" : "days"
        if scope = retention_scope
          "#{prefix}. It may be unknown, older than the retention window (#{days} #{unit} for #{scope[:domain]}.#{scope[:doc_type]}), or folded by coalescing."
        else
          "#{prefix}. It may be unknown, older than the base retention window (#{days} #{unit}), or folded by coalescing."
        end
      end

      # Resolves the replay target for a delete mutation: the mutation
      # immediately preceding it on the same document (same query shape as
      # `Audit::Restore`). Returns the pre-delete mutation's (id, idx), or a
      # `422` when no mutation precedes the delete (degenerate history —
      # there is no state to restore).
      private def self.resolve_pre_delete_target(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        delete_idx : Int32,
        delete_id : String,
      ) : NamedTuple(id: String, idx: Int32) | Facet::ServiceError
        if row = Restore.preceding_mutation(db, domain, doc_type, doc_id, delete_idx)
          row
        else
          Facet::ServiceError.new(
            422,
            "Cannot rollback to delete mutation #{delete_id}; no mutation precedes it, so there is no state to restore"
          )
        end
      end

      # The id of the document's most recent delete mutation, or `nil` when
      # the latest mutation is not a delete. The restore endpoint passes the
      # pre-delete mutation, so this identifies the delete that a restore
      # undoes.
      private def self.latest_delete_id(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : String?
        latest = db.query_one?(
          "SELECT id, action FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx DESC LIMIT 1",
          domain, doc_type, doc_id,
        ) do |rs|
          {id: rs.read(String), action: rs.read(String)}
        end
        return nil if latest.nil?
        latest[:action] == "delete" ? latest[:id] : nil
      end

      # Collects the cascade set of one undone delete and preflights every
      # restorable child. The set is the `cascade`-kind delete rows causally
      # linked to the delete: `Document::Delete` stamps each cascade
      # tombstone's `cause_parent` with the family root's trace id, so one
      # level already finds the whole subtree today. The walk still advances
      # through the found rows, so a per-level parent stamping would keep
      # working. A child restores only when that cascade delete is still its
      # most recent mutation — a child re-created or re-deleted later keeps
      # its newer history. Each queued child passes the single-document
      # rollback gates. One denial aborts the whole restore with `403`
      # before any write.
      private def self.collect_cascade_restores(
        db : DB::Connection,
        delete_id : String,
        auth_context : RBAC::AuthContext,
      ) : Array(CascadeChild) | Facet::ServiceError
        children = [] of CascadeChild
        visited = Set(String).new
        visited << delete_id
        frontier = [delete_id]

        until frontier.empty?
          rows = db.query_all(
            <<-SQL,
              SELECT id, domain, doc_type, doc_id, idx
              FROM mutations
              WHERE cause_kind = 'cascade' AND cause_parent = ANY($1)
              ORDER BY idx ASC
            SQL
            frontier,
            as: {String, String, String, String, Int32},
          )
          frontier = [] of String

          rows.each do |(row_id, domain, doc_type, doc_id, idx)|
            next if visited.includes?(row_id)
            visited << row_id
            frontier << row_id

            # A newer mutation on the child (a later create, update, or a
            # delete of its own) keeps the child out of this restore.
            later = db.query_one?("SELECT 1 FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx > $4 LIMIT 1",
              domain, doc_type, doc_id, idx, as: Int32)
            next unless later.nil?

            target = Restore.preceding_mutation(db, domain, doc_type, doc_id, idx)
            next if target.nil? # degenerate row — no state to restore

            child = CascadeChild.new(
              domain: domain, doc_type: doc_type, doc_id: doc_id,
              target_mut_id: target[:id], target_idx: target[:idx],
            )
            error = authorize_cascade_child(db, child, auth_context)
            return error if error
            children << child
          end
        end

        children
      end

      # One child's preflight — the same gates a single-document rollback
      # runs, in the same order.
      private def self.authorize_cascade_child(
        db : DB::Connection,
        child : CascadeChild,
        auth_context : RBAC::AuthContext,
      ) : Facet::ServiceError?
        authorized = RBAC::WriteEnforcer.authorize_update(db, child.domain, child.doc_type, child.doc_id, auth_context)
        return Facet::ServiceError.new(403, "rollback refused: your role cannot write a cascade child document") unless authorized

        authorize_rollback_transition(db, child.domain, child.doc_type, child.doc_id, child.target_idx, auth_context)
      end

      # Persists the rolled-back state as a snapshot mutation.
      private def self.persist_snapshot(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        content : JSON::Any,
        actioner_id : String,
        cause : Mutation::Cause,
        reentrant : Bool,
        provenance : Mutation::Provenance = Mutation::Provenance.internal,
        mutation_id : String? = nil,
        meta : JSON::Any = JSON.parse("{}"),
      ) : Result
        # The replayed meta is the projection meta as of the target state. It
        # carries the composition linkage (`parent_id`) and every other meta
        # key the history wrote — the same payload `Cron::MutationCompaction`
        # stores on its boundary snapshot. `schema_version` falls back to the
        # current projection's value, then to 1, so a history without the
        # key still tracks the doctype version. The audit trail (which
        # mutation was rolled back to and the `rollback` cause) lives on the
        # `mutations` row's provenance columns, never on the projection meta.
        current_projection = begin
          Mutation::Client.fetch_projection(db, domain, doc_type, doc_id)
        rescue PG::Error
          nil
        end

        meta_hash = meta.as_h?.try(&.dup) || {} of String => JSON::Any
        unless meta_hash.has_key?("schema_version")
          fallback = current_projection.try(&.meta.as_h?).try(&.["schema_version"]?)
          meta_hash["schema_version"] = fallback || JSON::Any.new(1_i64)
        end
        persisted_meta = JSON::Any.new(meta_hash)

        version = current_projection ? current_projection.version : 1
        created_at = current_projection ? current_projection.created_at.to_rfc3339 : Time.utc.to_rfc3339

        # The shared persist primitive stages the projection GUCs and writes
        # the snapshot. The definition is not known here — the doctype may
        # have been dropped since the mutations were recorded — so the
        # primitive resolves it (or clears the GUCs) inside the transaction.
        #
        # Both GUCs are transaction-local, so the full persist sequence runs
        # in one transaction.
        mut_id, updated_proj = Database.with_transaction(db, ignore_if_set: true) do |txn|
          this_mut_id = Document.persist_snapshot_mutation(
            txn, domain, doc_type, doc_id,
            content: content, meta: persisted_meta,
            actioner_id: actioner_id,
            cause: cause,
            definition: nil,
            version: version,
            created_at: created_at,
            provenance: provenance,
            mutation_id: mutation_id,
            reconcile_artifact_refs: true,
          )

          this_proj = Mutation::Client.fetch_projection(txn, domain, doc_type, doc_id)
          {this_mut_id, this_proj}
        end

        Event::Publisher.enqueue(
          domain: domain, doc_type: doc_type, doc_id: doc_id,
          event: "rolled_back", mutation_id: mut_id,
          actioner_id: actioner_id, cause: cause.to_json_any, reentrant: reentrant,
        )

        Result.new(projection: updated_proj, mutation_id: mut_id)
      end
    end
  end
end
