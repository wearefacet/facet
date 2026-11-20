# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../error"
require "../rbac"
require "./access"
require "./store"

module Facet
  module Artifact
    # "Where is this artifact used?" — the read side of `artifact_references`.
    #
    # Answers the inverse of the re-attach flow: which live documents embed
    # the artifact, either as a `file` field value or as an inline
    # `urn:facet:artifact:<id>` link in a longtext. Both placements write a
    # reference row (see `Document::ArtifactRefs`, `doc/backend/artifact.md`
    # → Dangling sweep). This is the question `Document::Backrefs` cannot
    # ask: an artifact is transversal — it has no domain/doctype/doc_id
    # triple — and `projections.links` intentionally never carries artifact
    # URNs.
    #
    # Contract:
    #
    # 1. The artifact gate runs first (`Artifact::Access.can_read?`). An
    #    unknown, tombstoned, ownerless, or denied artifact is one
    #    non-disclosing `NotFound` (404). This is deliberately stricter than
    #    the REST metadata route, which answers 403 for a denial: the
    #    listing follows the `Document::Backrefs` target-gate shape, where a
    #    denied target is indistinguishable from a missing one.
    # 2. Every returned row passed its own record's visibility. Referrers
    #    are grouped by `(domain, doc_type)` and each group is filtered by
    #    that doctype's list scope clauses (`RBAC::ReadEnforcer`), so a
    #    referrer can never leak past the caller's list visibility. An empty
    #    result is indistinguishable from "no references".
    # 3. No total over all references is reported — it would leak the
    #    cardinality of unreadable ones. Callers count the returned rows.
    # 4. Tombstoned referrers are excluded (`deleted_at IS NULL`). Reference
    #    rows are dropped on delete, so a survivor is a transient race and
    #    yields nothing.
    #
    # Pure read: no mutation, no events. Serves the MCP `list_artifact_refs`
    # tool. The operator surface (`GET /Api/Artifacts/:id/references` via
    # `Artifact::Admin.references`) stays the unfiltered, `read *.*`-gated
    # view.
    module Refs
      # One referencing document with its placement detail.
      record Item,
        id : String,
        domain : String,
        doc_type : String,
        display_name : String?,
        field : String,
        last_reference_at : Time

      record Result,
        items : Array(Item),
        capped : Bool

      # Returns the live, readable documents that reference the artifact,
      # stopped at `limit` with `capped` set when the result set reaches it.
      # A failed artifact gate returns the `Facet::ServiceError` to surface.
      #
      # Ordering: pairs are visited in `(domain, doc_type)` order; rows
      # within a pair by `last_reference_at` descending. The result is
      # group-ordered, not globally interleaved — the same shape as
      # `Document::Backrefs`.
      def self.call(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        artifact_id : String,
        limit : Int32 = 100,
      ) : Result | Facet::ServiceError
        # Artifact gate first — unknown, tombstoned, ownerless, and denied
        # collapse into one non-disclosing NotFound.
        artifact = Store.find_artifact(db, artifact_id)
        return error(404, "Artifact not found") unless artifact
        return error(404, "Artifact not found (deleted)") if artifact.deleted_at
        return error(404, "Artifact not found") unless Access.can_read?(db, auth_context, artifact_id)

        items = [] of Item
        return Result.new(items: items, capped: false) if limit <= 0

        reference_pairs(db, artifact_id).each do |(domain, doc_type)|
          break if items.size >= limit
          items.concat(readable_refs_of_pair(db, auth_context, artifact_id, domain, doc_type, limit - items.size))
        end

        Result.new(items: items, capped: items.size >= limit)
      end

      # ── Internals ───────────────────────────────────────────────────────

      private def self.error(status : Int32, message : String) : Facet::ServiceError
        Facet::ServiceError.new(status, message)
      end

      # Distinct `(domain, doc_type)` pairs among the artifact's referrers.
      # `artifact_references` carries no `doc_type` — resolve it from the
      # referrer's projection, newest row first (the same join
      # `Artifact::Admin.references` uses).
      private def self.reference_pairs(db : DB::Connection, artifact_id : String) : Array({String, String})
        db.query_all(
          <<-SQL,
            SELECT DISTINCT r.domain, p.doc_type
            FROM artifact_references r
            JOIN LATERAL (
              SELECT doc_type
              FROM projections
              WHERE domain = r.domain AND id = r.resource_id
              ORDER BY updated_at DESC
              LIMIT 1
            ) p ON true
            WHERE r.artifact_id = $1 AND p.doc_type IS NOT NULL
            ORDER BY 1, 2
          SQL
          artifact_id,
          as: {String, String},
        )
      end

      # Readable reference rows for one `(domain, doc_type)` pair.
      #
      # The scope clauses run against the bare `projections` table: their
      # column vocabulary (`id`, `meta->>'…'`, `content->>'…'`) must resolve
      # unqualified, so the lateral that decorates the reference metadata
      # exposes only `artifact_references` columns that cannot collide.
      private def self.readable_refs_of_pair(
        db : DB::Connection,
        auth_context : RBAC::AuthContext,
        artifact_id : String,
        domain : String,
        doc_type : String,
        limit : Int32,
      ) : Array(Item)
        return [] of Item if limit <= 0

        # Pure permission arithmetic — skip the query entirely for a
        # doctype the caller holds no read grant on at all.
        return [] of Item if RBAC::ReadEnforcer.read_denied?(domain, doc_type, auth_context)

        scope_clauses, scope_params = RBAC::ReadEnforcer.list_where_clauses(
          db, domain, doc_type, auth_context, start_idx: 4)
        where = String.build do |sql|
          sql << "p.domain = $2 AND p.doc_type = $3 AND p.deleted_at IS NULL"
          sql << " AND p.id IN (SELECT resource_id FROM artifact_references"
          sql << " WHERE artifact_id = $1 AND domain = $2)"
          scope_clauses.each { |clause| sql << " AND " << clause }
        end
        params = [artifact_id, domain, doc_type] of ::DB::Any
        params.concat(scope_params)

        rows = db.query_all(
          <<-SQL,
            SELECT p.id, p.display_name, ref.resource_field, ref.last_reference_at
            FROM projections p
            JOIN LATERAL (
              SELECT resource_field, last_reference_at
              FROM artifact_references
              WHERE artifact_id = $1 AND domain = $2 AND resource_id = p.id
            ) ref ON true
            WHERE #{where}
            ORDER BY ref.last_reference_at DESC, p.id ASC
            LIMIT #{limit}
          SQL


          args: params,
          as: {String, String?, String, Time},
        )
        rows.map do |(id, display_name, field, last_reference_at)|
          Item.new(
            id: id, domain: domain, doc_type: doc_type,
            display_name: display_name, field: field,
            last_reference_at: last_reference_at,
          )
        end
      end
    end
  end
end
