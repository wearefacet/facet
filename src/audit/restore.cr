# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../error"

module Facet
  module Audit
    # Resolves the restore target for a deleted (tombstoned) document.
    #
    # Per AGENTS.md (Database → shared): restoring a deleted document means
    # rolling back to the mutation immediately before the delete — the replay
    # skips the delete (its no-op passthrough) and the resulting snapshot
    # restores the live content. This service is the pure-read half of that
    # workflow: it finds the mutation id to roll back to. The write half is
    # `Audit::Rollback`, which owns the RBAC gate and the audit trail entry.
    #
    # A prior restore snapshot is a valid target: delete → restore (snapshot)
    # → delete again resolves to the earlier snapshot, which replays like any
    # other snapshot. Iterative delete/restore loops stay reachable.
    module Restore
      # Returns the id of the mutation immediately preceding the target
      # document's most recent `delete` mutation, or a `ServiceError`:
      #
      # - `404` — no mutations exist for the document.
      # - `409` — the document is live (its most recent mutation is not a
      #   `delete`). Restoring is a no-op-by-rejection: the restore endpoint
      #   surfaces this as `409 Conflict` per its idempotency contract.
      # - `422` — a `delete` exists but no mutation precedes it. Unreachable
      #   through the normal mutation flow (a delete always follows a create)
      #   but guarded against a degenerate history.
      # Returns the mutation immediately before `before_idx` for the
      # document — `{id, idx}` of the closest lower mutation — or `nil`
      # when `before_idx` is the document's first mutation. Shared by the
      # restore resolution and the rollback replay-target resolution.
      def self.preceding_mutation(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
        before_idx : Int32,
      ) : NamedTuple(id: String, idx: Int32)?
        db.query_one?("SELECT id, idx FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 AND idx < $4 ORDER BY idx DESC LIMIT 1", domain, doc_type, doc_id, before_idx) do |rs|
          {id: rs.read(String), idx: rs.read(Int32)}
        end
      end

      def self.resolve_target(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : String | Facet::ServiceError
        latest = db.query_one?(
          "SELECT idx, action FROM mutations WHERE domain = $1 AND doc_type = $2 AND doc_id = $3 ORDER BY idx DESC LIMIT 1",
          domain, doc_type, doc_id
        ) do |rs|
          {idx: rs.read(Int32), action: rs.read(String)}
        end
        return Facet::ServiceError.new(404, "No mutation history for document #{domain}.#{doc_type}.#{doc_id}") if latest.nil?
        return Facet::ServiceError.new(409, "Document is not deleted") unless latest[:action] == "delete"

        # The mutation immediately before the delete, by the per-document
        # monotonic `idx`. When the delete is the create's direct successor,
        # this resolves to the `create` itself — rolling back to it replays
        # the create and skips the delete, restoring the create content.
        if row = preceding_mutation(db, domain, doc_type, doc_id, latest[:idx])
          row[:id]
        else
          Facet::ServiceError.new(422, "Delete mutation has no preceding mutation; nothing to restore")
        end
      end
    end
  end
end
