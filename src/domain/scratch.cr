# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "../util/projections"
require "../index"

module Facet
  module Domain
    # Fail-closed teardown of a draft domain.
    #
    # Soft-deletes a draft domain's doctype definitions, its `core.Domain`
    # document, its view rows, and all of its `projections` rows by setting
    # `deleted_at`. Used by `Domain::Publish` to dispose of the draft after
    # structure has been copied into the target.
    #
    # ## Mechanism and policy
    #
    # `Scratch` owns the **mechanism** — two disposal scopes:
    #
    # - `dispose_definitions!` — the definition surface only: `core.DocType`
    #   rows, the `core.Domain` row, the domain's view rows
    #   (`core.DocumentView` and **general** `core.CollectionView`, keyed by
    #   `meta.parent_id`), its `core.DomainEditor` rows (keyed by content
    #   domain), and its `doctype_indexes` rows. Data rows,
    #   personal (owner-bound) collection views, and artifact provenance
    #   are left untouched.
    # - `dispose!` — everything above, plus the domain's data rows
    #   (`projections WHERE domain = …`), its personal collection views,
    #   and its artifact provenance.
    #
    # The **policy** lives with the caller: `drop` is the publish path's
    # entry point and stays fail-closed (draft-only); the dev domain
    # watcher (`Facet::Dev::DomainWatcher`) owns the dev-mode policy and
    # is the only other caller.
    #
    # ## Fail-closed
    #
    # Refuses to run unless the named domain has `draft = true` on its
    # `core.Domain` projection row. This is the safety net behind the
    # state-machine guard: the publish path can only ever reach a draft
    # (the draft flag is set at create time and rejected in any document
    # update diff), and this drop is the only operation that soft-deletes
    # draft data wholesale. Soft-deleting a non-draft domain would be
    # catastrophic, so the guard is enforced here rather than relied on at
    # call sites.
    #
    # ## What is disposed
    #
    # The `mutations` table (append-only event log) is **never touched** —
    # the draft's history stays in the log for audit purposes. Only
    # `projections` (a materialised view) and `doctype_indexes` (index
    # tracking) are modified.
    #
    # Projections are soft-deleted (tombstoned via `deleted_at`), matching
    # the normal `Document::Delete` behaviour: all consumers already filter
    # `deleted_at IS NULL`, so the draft's documents disappear from every
    # query surface without breaking the append-only contract.
    #
    # - `doctype_indexes` rows for the domain (hard-deleted — orphan-free
    #   cleanup of index tracking rows).
    # - View rows under `domain = 'core'` — `core.DocumentView` and
    #   **general** `core.CollectionView` rows whose parent doctype belongs
    #   to the domain (the parent link is `meta.parent_id =
    #   '{domain}.{Doctype}'`, so the leading segment picks the domain).
    #   Views are definition surface and must die with the draft; a rebuild
    #   creates fresh rows, so stale live rows would pile up as duplicate
    #   views per kind. Personal collection views are user data — the
    #   definitions scope keeps them, the full scope tombstones them.
    # - `projections` rows where `domain = $1` — the draft's own documents.
    # - `projections` rows under `domain = 'core'` keyed by
    #   `content->>'domain' = $1` — the draft's `core.DocType` definition
    #   rows (stored under core, keyed by their content domain field).
    # - `projections` row for the draft's own `core.Domain` document.
    module Scratch
      class Error < ::Exception
      end

      # Soft-deletes everything owned by the draft `domain`. Raises
      # `Scratch::Error` if `domain` is not a draft, so a misuse cannot
      # silently destroy live data.
      def self.drop(db : DB::Connection, domain : String) : Nil
        # Treats a missing row, a missing field, or any non-`true` value
        # as "not a draft" — fail-closed.
        unless Util::Projections.draft_domain?(db, domain)
          raise Error.new(
            "Domain '#{domain}' is not a draft — refusing to drop. " \
            "Scratch.drop is only callable on draft domains."
          )
        end

        dispose!(db, domain)
      end

      # Full-scope disposal: the definition surface (see
      # `dispose_definitions!`) plus the domain's data rows, its personal
      # (owner-bound) collection views, and its artifact provenance.
      #
      # No guard lives here — the caller owns the policy. `drop` enforces
      # the draft-only rule for publish; the dev domain watcher enforces
      # the dev-mode rule for managed domains.
      def self.dispose!(db : DB::Connection, domain : String) : Nil
        dispose_definitions!(db, domain)

        # Personal (owner-bound) CollectionView rows are user data — kept
        # by the definitions scope, disposed only in the full scope. The
        # general views were already tombstoned by `dispose_definitions!`;
        # the `deleted_at IS NULL` guard leaves them alone.
        db.exec(
          <<-SQL,
            UPDATE projections SET deleted_at = now()
            WHERE domain = 'core' AND doc_type = 'CollectionView'
              AND deleted_at IS NULL
              AND split_part(meta->>'parent_id', '.', 1) = $1
          SQL
          domain,
        )

        # Soft-delete the domain's own document data: any projection under
        # the domain string itself (e.g. documents of the domain's own
        # doctypes). The mutation log is left intact — the history stays
        # in the append-only log for audit.
        db.exec(
          "UPDATE projections SET deleted_at = now() WHERE domain = $1 AND deleted_at IS NULL",
          domain,
        )

        # Clean artifact provenance for the domain. `artifact_owners` rows
        # are domain-scoped; deleting them cascades to `artifact_grants`
        # (FK `owner_id → artifact_owners` ON DELETE CASCADE).
        # `artifact_references` rows are domain-scoped too. The `artifacts`
        # rows themselves are left untouched — they fall out on the next
        # prune, whose eligibility is join-derived (see
        # `doc/backend/artifact.md` → Prune).
        db.exec("DELETE FROM artifact_owners WHERE domain = $1", domain)
        db.exec("DELETE FROM artifact_references WHERE domain = $1", domain)
      end

      # Definitions-only disposal: the definition surface of `domain`,
      # with no data touched. Data rows, personal (owner-bound) collection
      # views, and artifact provenance survive.
      def self.dispose_definitions!(db : DB::Connection, domain : String) : Nil
        # 1. Drop the domain's physical indexes and field statistics
        #    objects, then hard-delete the tracking rows. The managed
        #    indexes are partial indexes on the shared `projections` table
        #    (scoped by `domain = '<d>'`), so deleting the tracking rows
        #    alone would leave the real indexes behind — every later write
        #    and query plan would keep paying for a domain that no longer
        #    exists. The drop is non-concurrent: `dispose!` runs inside the
        #    caller's transaction, and `DROP INDEX CONCURRENTLY` cannot run
        #    in a transaction block. Failures are logged, not raised — a
        #    leftover index is a performance problem, never a correctness
        #    one, and must not abort the disposal.
        Index::Manager.dispose_domain_indexes(db, domain, concurrent: false)
        db.exec(
          "DELETE FROM doctype_indexes WHERE domain = $1",
          domain,
        )

        # 2. Soft-delete the domain's view rows: `core.DocumentView` and
        #    **general** `core.CollectionView` (owner_id absent) whose
        #    parent doctype belongs to the domain. The parent link is
        #    `meta.parent_id = '{domain}.{Doctype}'`, so the leading
        #    segment of `parent_id` picks the domain. The owner_id
        #    predicate mirrors the `$null` named-scope
        #    (`where: { owner_id: '$null' }`) and tolerates JSON null and
        #    a text-empty string (same shape as the export predicate).
        #    Personal collection views are user data and survive this
        #    scope.
        db.exec(
          <<-SQL,
            UPDATE projections SET deleted_at = now()
            WHERE domain = 'core'
              AND doc_type IN ('DocumentView', 'CollectionView')
              AND deleted_at IS NULL
              AND split_part(meta->>'parent_id', '.', 1) = $1
              AND (
                doc_type = 'DocumentView'
                OR content->>'owner_id' IS NULL
                OR content->>'owner_id' = ''
                OR content->>'owner_id' = 'null'
              )
          SQL
          domain,
        )

        # 3. Soft-delete the domain's `core.DocType` definition rows (they
        #    live under domain = 'core', keyed by their content domain
        #    field).
        db.exec(
          <<-SQL,
            UPDATE projections SET deleted_at = now()
            WHERE domain = 'core' AND doc_type = 'DocType'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
          SQL
          domain,
        )

        # 4. Soft-delete the `core.Domain` document itself.
        db.exec(
          <<-SQL,
            UPDATE projections SET deleted_at = now()
            WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1
              AND deleted_at IS NULL
          SQL
          domain,
        )

        # 5. Soft-delete the domain-editor rows pointing at the domain, so
        #    no grant ever references a dead slug. Covers publish-drop, draft
        #    discard, and `Domain::Drop` of a live domain — all three
        #    funnel through `dispose!` → `dispose_definitions!`. The rows
        #    live under domain 'core' keyed by their content domain field,
        #    like the DocType definitions above — the data-row sweep does
        #    not reach them.
        db.exec(
          <<-SQL,
            UPDATE projections SET deleted_at = now()
            WHERE domain = 'core' AND doc_type = 'DomainEditor'
              AND content->>'domain' = $1
              AND deleted_at IS NULL
          SQL
          domain,
        )
      end
    end
  end
end
