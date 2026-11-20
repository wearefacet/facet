# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "db"
require "../config"
require "../database"
require "../mutation/json_diff"
require "../mutation/client"
require "../doctype/doctype_definition"
require "../event"
require "../artifact/owners"
require "./projection_gucs"
require "./artifact_refs"

module Facet
  module Document
    # Write-time coalescing for document updates, and the persist step the
    # update pipeline calls.
    module Coalesce
      # The transaction-local GUC that skips the projection triggers.
      BYPASS_GUC = "harness.bypass_projection_triggers"

      # Persists an `update` mutation: stages the projection GUCs, inserts the
      # mutation, fetches the fresh projection, enqueues the `updated` event,
      # and returns the new `Result`.
      #
      # With write-time coalescing enabled (`mutations.coalesce_window_minutes`
      # > 0), a new update folds into the document's previous update row when
      # both writes are plain root requests and the last row is an `update`
      # by the same actor through the same channel, inside the window, whose
      # causal cluster has exactly one member: the two diffs compose into one
      # `X→Z` row (a fresh ULID — `projections.state` is the ETag token), the
      # previous row is deleted (its idx stays vacant — the gap clue), and the
      # projection is advanced manually under the bypass GUC. A write that
      # carries a cause — an action's own update, a nested `document.*` write,
      # an assistant tool call, a replication recompute — never folds, and
      # never folds into: the fold would erase or mislabel the cause in the
      # audit log. See `doc/backend/mutation.md` → Write-time coalescing.
      #
      # The GUCs are transaction-local, so the GUC set + mutation insert +
      # projection fetch must run inside one transaction.
      def self.call(
        span,
        db : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        auth_context : RBAC::AuthContext,
        cause : Mutation::Cause?,
        provenance : Mutation::Provenance?,
        mutation_id : String,
        reentrant : Bool,
        merged : JSON::Any,
        diff : Mutation::JsonDiff::Result,
        current : JSON::Any,
      ) : Update::Result
        prov = provenance || Mutation::Provenance.from(auth_context)
        mut_id, updated_proj = Database.with_transaction(db, ignore_if_set: true) do |txn|
          # The row lock serializes the coalesce decision per document (and
          # the MAX(idx)+1 probe with it): a second writer on the same
          # document probes only after this transaction commits.
          lock_projection(txn, domain, doc_type, doc_id)

          target = coalesce_target(txn, domain, doc_type, doc_id, actioner_id, prov, cause)
          this_mut_id = if target
                          insert_coalesced_update(txn, defn, domain, doc_type, doc_id, actioner_id, prov, cause, mutation_id, merged, diff, current, target)
                        else
                          # Stage search, links, and display_name GUCs for the trigger.
                          # `merged` is the post-diff content the trigger will land on.
                          Document::ProjectionGucs.set_all(txn, defn, merged)

                          Mutation::Client.update(
                            txn, domain, doc_type, doc_id,
                            diff_json: diff.to_json,
                            actioner_id: actioner_id,
                            provenance: prov,
                            cause: cause,
                            mutation_id: mutation_id,
                          )
                        end

          this_proj = Mutation::Client.fetch_projection(txn, domain, doc_type, doc_id)

          # Reconcile `artifact_references` against the post-mutation content,
          # in the same transaction so a rollback undoes both. Using `merged`
          # (not the diffed projection) mirrors the create path: the walker
          # sees the full document.
          ArtifactRefs.set_guc(txn, merged, defn, domain, doc_id)

          # Re-attach: a JSON update that puts an existing artifact id into a
          # `file` field appends an owner row *only if* the actor can already
          # read the artifact. Knowing an id never confers ownership. The
          # multipart path already records owner rows via `Multipart.upload_files`;
          # this covers the JSON-only path.
          Artifact::Owners.append_readable_for_document(
            txn, auth_context, merged, defn, domain, doc_type, doc_id, actioner_id,
          )

          {this_mut_id, this_proj}
        end
        span["mutation_id"] = mut_id

        Event::Publisher.enqueue(
          domain: domain, doc_type: doc_type, doc_id: doc_id,
          event: "updated", mutation_id: mut_id, actioner_id: actioner_id,
          cause: (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(mut_id).to_json_any,
          reentrant: reentrant,
        )

        # Aggregate push: an update on a child (meta.parent_id rides the
        # projection row) also emits one `child_changed` frame keyed to
        # the parent.
        if parent_id = updated_proj.meta["parent_id"]?.try(&.as_s?)
          Event::Publisher.enqueue_child_changed(
            db, domain, doc_type, doc_id,
            parent_doc_id: parent_id, action: "updated",
            mutation_id: mut_id, actioner_id: actioner_id,
            cause: cause, reentrant: reentrant,
          )
        end

        Update::Result.new(projection: updated_proj, mutation_id: mut_id)
      end

      # The document's last mutation row, when it can absorb the new update:
      # a root-request `update` by the same actor through the same channel,
      # inside the coalesce window, whose causal cluster has exactly one
      # member (itself — hook and action descendants share the root's trace,
      # so a row with descendants never merges). Adjacency holds by
      # construction: the probe reads the last row only, and the row lock
      # above serializes it.
      private record CoalesceTarget,
        id : String,
        diff : Mutation::JsonDiff::Result,
        meta_diff : Mutation::JsonDiff::Result

      private def self.lock_projection(db : DB::Connection, domain : String, doc_type : String, doc_id : String) : Nil
        db.query_one?(
          "SELECT state FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 FOR UPDATE",
          domain, doc_type, doc_id,
          as: String
        )
      end

      private def self.coalesce_target(
        txn : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        prov : Mutation::Provenance,
        cause : Mutation::Cause?,
      ) : CoalesceTarget?
        return nil unless coalescible_cause?(cause)
        window = Facet::Config.instance.mutations.coalesce_window_minutes
        return nil unless window.positive?

        # No cause filter in the WHERE: the probe must read THE last row,
        # not the last row that matches — folding across a snapshot or a
        # delete would break adjacency. The cause rule runs on the probed
        # row in `coalescible_row?` instead.
        row = txn.query_one?(
          <<-SQL,
            SELECT id, action, actioner_id, channel, app, api_key, acting_role, cause_trace,
                   cause_kind, cause_parent,
                   (emitted_at >= now() - make_interval(mins => $4)) AS within_window,
                   COALESCE(arguments->'diff', '{"set": [], "unset": []}'::jsonb) AS diff,
                   COALESCE(arguments->'meta_diff', '{"set": [], "unset": []}'::jsonb) AS meta_diff
            FROM mutations
            WHERE domain = $1 AND doc_type = $2 AND doc_id = $3
            ORDER BY idx DESC
            LIMIT 1
          SQL
          domain, doc_type, doc_id, window
        ) do |rs|
          {
            id:            rs.read(String),
            action:        rs.read(String),
            actioner_id:   rs.read(String),
            channel:       rs.read(String),
            app:           rs.read(String?),
            api_key:       rs.read(String?),
            acting_role:   rs.read(String?),
            cause_trace:   rs.read(String),
            cause_kind:    rs.read(String),
            cause_parent:  rs.read(String?),
            within_window: rs.read(Bool),
            diff:          rs.read(JSON::Any),
            meta_diff:     rs.read(JSON::Any),
          }
        end
        return nil if row.nil?
        return nil unless coalescible_row?(row, actioner_id, prov)

        # Single-member cluster check: no other row may share the trace.
        descendant = txn.query_one?(
          "SELECT 1 FROM mutations WHERE cause_trace = $1 AND id <> $2 LIMIT 1",
          row[:cause_trace], row[:id],
          as: Int32
        )
        return nil unless descendant.nil?

        CoalesceTarget.new(
          id: row[:id],
          diff: Mutation::JsonDiff::Result.from_json(row[:diff]),
          meta_diff: Mutation::JsonDiff::Result.from_json(row[:meta_diff]),
        )
      end

      # A fold merges two plain root-request writes only. A driven write —
      # the action's own update, a nested `document.*` write, an assistant
      # tool call, a replication recompute — carries a cause and must land
      # as its own row, and a row carrying one must never absorb a later
      # write: folding would erase or mislabel the cause in the audit log
      # (and orphan the event already emitted for the folded id). The
      # cluster check cannot do this job alone: an action with no nested
      # writes is a single-member `update` cluster, exactly the shape of a
      # plain interactive save.
      private def self.coalescible_cause?(cause : Mutation::Cause?) : Bool
        return true if cause.nil?
        cause.kind == Mutation::CauseKind::Request && cause.parent.nil?
      end

      # The fold conditions on the probed row (the incoming write's cause
      # ran in Crystal, the window check in SQL against PG's clock). The
      # `cause_kind` / `cause_parent` check keeps driven rows out of the
      # fold target slot: an action's own update is a single-member `update`
      # cluster — exactly the shape the cluster check accepts — but folding
      # it away would erase the action from the log.
      private def self.coalescible_row?(
        row,
        actioner_id : String,
        prov : Mutation::Provenance,
      ) : Bool
        row[:action] == "update" &&
          row[:cause_kind] == "request" &&
          row[:cause_parent].nil? &&
          row[:actioner_id] == actioner_id &&
          row[:channel] == prov.channel.json_value &&
          row[:app] == prov.app &&
          row[:api_key] == prov.api_key &&
          row[:acting_role] == prov.acting_role &&
          row[:within_window]
      end

      # Folds the new update into the previous row: composes the two diffs
      # into one `X→Z` row, inserts it under the bypass GUC (a natural
      # MAX(idx)+1 — the old idx stays vacant as the gap clue), deletes the
      # previous row, and advances the projection manually (the trigger was
      # skipped, and the stored diff is `X→Z` while the projection sits at
      # `Y`, so the trigger could not apply it anyway).
      private def self.insert_coalesced_update(
        txn : DB::Connection,
        defn : Doctype::DoctypeDefinition,
        domain : String,
        doc_type : String,
        doc_id : String,
        actioner_id : String,
        prov : Mutation::Provenance,
        cause : Mutation::Cause?,
        mutation_id : String,
        merged : JSON::Any,
        diff : Mutation::JsonDiff::Result,
        current : JSON::Any,
        target : CoalesceTarget,
      ) : String
        # `current` is the middle content (Y) — the projection content
        # before this write, exactly what the previous diff produced.
        composed = Mutation::JsonDiff.compose(target.diff, diff, current)
        # The second write's meta diff is empty on the current write path,
        # so the composed meta diff keeps the previous row's entries.
        composed_meta = Mutation::JsonDiff.compose(
          target.meta_diff,
          Mutation::JsonDiff::Result.new,
          current,
        )

        # Insert first: the merged row takes a fresh idx, so the previous
        # idx stays vacant. The bypass GUC skips both AFTER triggers —
        # the projection is advanced manually below. The bypass lives for
        # this fold only: the save/restore keeps it out of every later
        # operation in the same transaction (a batch `delete` after a fold
        # must still fire its tombstone trigger).
        with_projection_triggers_bypassed(txn) do
          this_mut_id = Mutation::Client.update(
            txn, domain, doc_type, doc_id,
            diff_json: composed.to_json,
            meta_diff_json: composed_meta.to_json,
            actioner_id: actioner_id,
            provenance: prov,
            cause: cause,
            mutation_id: mutation_id,
          )

          # Stage the projection GUCs — the manual advance consumes the same
          # GUCs the trigger would have read.
          Document::ProjectionGucs.set_all(txn, defn, merged)

          # Delete the folded row second.
          txn.exec("DELETE FROM mutations WHERE id = $1", target.id)

          # Advance the projection manually, mirroring `projection_from_update`:
          # `content` is the new content (in memory); `meta` advances with the
          # SECOND write's meta diff (the projection sits at Y — the composed
          # `X→Z` diff belongs to the stored row only). `now()` is
          # transaction-stable, so `updated_at` matches the merged row's
          # `emitted_at`.
          txn.exec(
            <<-SQL,
              UPDATE projections SET
                  content      = $4::jsonb,
                  meta         = jsonb_apply_diff(meta, $5::jsonb),
                  links        = COALESCE(NULLIF(current_setting('harness.mutation_links', true), '')::jsonb, '[]'::jsonb),
                  state        = $6,
                  search       = NULLIF(current_setting('harness.mutation_search', true), ''),
                  display_name = NULLIF(current_setting('harness.mutation_display_name', true), ''),
                  updated_at   = now()
              WHERE domain = $1 AND doc_type = $2 AND id = $3
            SQL
            domain, doc_type, doc_id, merged.to_json, "{}", this_mut_id,
          )

          this_mut_id
        end
      end

      # Runs the block with `harness.bypass_projection_triggers` set, then
      # restores the GUC to the value it held before. The GUC is
      # transaction-local, so a fold that never reset it suppressed the
      # projection triggers of every later operation in the same
      # transaction — a batch `delete` after a fold recorded its mutation
      # but never wrote the tombstone. An outer bypass (a caller that set
      # the GUC itself, e.g. `Mutation::Client.compaction_snapshot`) stays
      # in force: the restore puts back its value, never a cleared one.
      private def self.with_projection_triggers_bypassed(txn : DB::Connection, &)
        previous = txn.query_one(
          "SELECT current_setting($1, true)", BYPASS_GUC, as: String?
        )
        txn.exec("SELECT set_config($1, $2, true)", BYPASS_GUC, "on")
        begin
          yield
        ensure
          txn.exec("SELECT set_config($1, $2, true)", BYPASS_GUC, previous || "")
        end
      end
    end
  end
end
