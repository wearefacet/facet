# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"

require "../../database"
require "../../doctype/definition_store"
require "../../doctype/doctype_definition"
require "../../doctype/structure"
require "../../doctype/composition"
require "../../doctype/validation"
require "../../doctype/script_validator"
require "../../doctype/draft_target_check"
require "../../mutation/client"
require "../../mutation/json_diff"
require "../../grants/publish_tickets"
require "../../hooks/definition"
require "../../index"
require "../../rbac"
require "../../event"
require "../../error"
require "../../util/script_helpers"
require "../../document/projection_gucs"
require "../../document/display_name"
require "../../document/unique_constraint"
require "../../replication/sync_pull"
require "../../util/projections"
require "../publish_gate"
require "../copy"
require "../view_reconciler"
require "./archive"
require "./import/rewrite"
require "./import/canonical_json"
require "./import/authoring"

module Facet
  module Domain
    module Portable
      # Service that applies an `Archive::Bundle` to the database.
      #
      # Import is **definition-only** — it carries the same structural set
      # as `Export` produces (domain document, doctypes, document views,
      # general collection views) and never touches live document data.
      #
      # ## Merge rules
      #
      # Without `--merge`, the import refuses when the target domain
      # already exists (`409`). With `--merge`, every doctype in the
      # bundle is upserted under the version-gate contract that
      # `Doctype::Update` enforces:
      #
      # - Bundle doctype missing in target → create via
      #   `Domain::Copy.upsert_doctype_definition` (shared with publish).
      # - Bundled and target content identical (SHA-256 match) → no-op.
      # - Different content at `schema_version == current + 1` with a
      #   matching migration chain → update via JsonDiff.
      # - Anything else → reject with a named, actionable error.
      #
      # `core.DocumentView` rows are reconciled to match the bundle
      # (definition-owned): bundle-only kinds create, target-only kinds
      # delete, common kinds update. `core.CollectionView` rows are
      # **not** deleted on merge — they are live-authored (mirrors the
      # publish action: "CollectionView rows are never touched by
      # publish"). Bundle-only general views are created; general views
      # matched by `name` are updated in place.
      #
      # ## Atomicity
      #
      # The whole import runs inside **one** outer transaction. Any
      # rejection rolls every prior mutation back, so a partial import
      # is impossible: the database is either untouched or fully converged
      # to the bundle.
      module Import
        Log = ::Log.for("facet.domain.portable.import")

        # Result of a successful import. Counts let the CLI print a summary
        # without re-querying the database. `grant_tickets` carries the
        # tickets filed or merged for outbound cross-domain edges (B-10).
        record Result,
          domain : String,
          created : Bool,
          doctypes_created : Int32,
          doctypes_updated : Int32,
          doctypes_unchanged : Int32,
          document_views_created : Int32,
          document_views_updated : Int32,
          document_views_deleted : Int32,
          collection_views_created : Int32,
          collection_views_updated : Int32,
          documents_created : Int32,
          grant_tickets : Array(Grants::PublishTickets::Ticket) = [] of Grants::PublishTickets::Ticket

        # Actioner id stamped on every mutation produced by the import.
        # The `system:import` prefix makes import-authored mutations
        # distinguishable from `system:publish` and `system:migration`
        # in the audit log.
        ACTIONER_ID = "system:import"

        # Applies `bundle` to the database.
        #
        # - `merge`: when `false` (default), the target domain must not
        #   exist; the import creates it from scratch. When `true`, an
        #   existing target is upserted under the version gate and a
        #   missing target is created fresh — `--merge` never fails on
        #   the target's existence.
        # - `into`: optional rename of the bundle's source domain to a
        #   different target name. Useful for cloning a domain into a
        #   fresh slot under a different name (still subject to the
        #   `merge` flag).
        def self.call(
          db : DB::Connection,
          bundle : Archive::Bundle,
          *,
          merge : Bool = false,
          into : String? = nil,
        ) : Result | Facet::ServiceError
          target_domain = into || bundle.source_domain

          # 0. Validate the bundle's domain document before touching the
          #    DB — a draft bundle is rejected outright (defense-in-depth;
          #    `Export` also refuses draft exports, but a hand-crafted
          #    bundle could bypass that).
          if bundle_domain_draft?(bundle)
            return Facet::ServiceError.new(
              422,
              "Bundle's core.Domain has draft=true — scratch data is not portable.",
            )
          end

          target_exists = Util::Projections.exists?(db, "core", "Domain", target_domain)

          if target_exists && !merge
            return Facet::ServiceError.new(
              409,
              "Domain '#{target_domain}' already exists; pass --merge to overwrite.",
            )
          end

          # A fresh import makes the bundle the whole initial state, so the
          # composition graph must close inside the bundle: every `children`
          # entry reciprocated by a `member_of` on its target and vice
          # versa. A one-sided edge would import a half-owned relationship
          # (no cascade, no copy) — reject the bundle instead. Merge is a
          # partial sync (the other half of an edge may already live on the
          # target), so the graph cannot be closed bundle-only there; live
          # diagnostics (`Doctype::Check`) cover it.
          if !target_exists
            bundled_definitions = bundle.doctypes.map do |entry|
              begin
                parse_definition(entry[:entry].content, entry[:doctype], DefinitionSource::Bundle)
              rescue ex : ImportError
                return ex.to_service_error
              end
            end
            composition_problems = Doctype::Composition.validate(bundled_definitions)
            unless composition_problems.empty?
              return Facet::ServiceError.new(
                422,
                "Bundle has an inconsistent composition graph: #{composition_problems.first.message}",
              )
            end
          end

          stats = Stats.new

          begin
            Database.with_transaction(db, ignore_if_set: true) do |txn|
              if target_exists
                apply_merge(txn, bundle, target_domain, stats)
              else
                apply_fresh(txn, bundle, target_domain, stats)
              end
            end
          rescue ex : ImportError
            return ex.to_service_error
          end

          # Post-commit display_name backfill. Only runs when documents
          # were created: a definition-only import has no document rows
          # whose `display_name` could have drifted. A doctype whose `display_name` template contains a `$<field>`
          # reference token may have stored the type label fallback when
          # the referenced doctype was seeded later (alphabetical
          # ordering on the source side never matters here because the
          # source already had every row resolved, but a bundle exported
          # mid-seed on a fresh instance could carry stale values).
          if stats.documents_created > 0
            backfill_display_names(db, bundle.doctypes.map(&.[:doctype]), bundle.source_domain, target_domain)
          end

          # Post-commit side effects: index sync runs in background
          # fibers (mirror `Domain::Copy.upsert_doctype_definition`).
          # Events are flushed by the CLI.
          Result.new(
            domain: target_domain,
            created: !target_exists,
            doctypes_created: stats.doctypes_created,
            doctypes_updated: stats.doctypes_updated,
            doctypes_unchanged: stats.doctypes_unchanged,
            document_views_created: stats.document_views_created,
            document_views_updated: stats.document_views_updated,
            document_views_deleted: stats.document_views_deleted,
            collection_views_created: stats.collection_views_created,
            collection_views_updated: stats.collection_views_updated,
            documents_created: stats.documents_created,
            grant_tickets: stats.grant_tickets,
          )
        end

        # Applies the bundle's documents onto `target_domain` inside the
        # caller's transaction. Shared by `Import.call` and
        # `Domain::Publish` — the two flows that carry rows from one domain
        # into another. The caller owns the transaction, so a refused row
        # rolls back everything the caller wrote.
        #
        # `bundle.source_domain` is the identity the rows were read under;
        # ids, reference tokens, and `meta.parent_id` are rewritten from it
        # to `target_domain`. `actioner_id` is stamped on every mutation, so
        # a publish-imported row is distinguishable from a CLI import.
        #
        # Returns the number of rows created. Raises `ImportError` on a
        # refused row (authoring gate, secret gate, unique collision).
        def self.import_documents(
          db : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
          actioner_id : String = ACTIONER_ID,
        ) : Int32
          created = 0
          bundle.documents.each do |source_qualified, docs|
            next if docs.empty?
            target_qualified = target_qualified_name(source_qualified, bundle.source_domain, target_domain)

            docs.each do |doc|
              target_id = rewrite_document_id(doc.id, bundle.source_domain, target_domain)
              next if document_exists?(db, target_qualified, target_id)

              rewritten_content = rewrite_any_strings(doc.entry.content, bundle.source_domain, target_domain)
              rewritten_meta = rewrite_any_strings(doc.entry.meta, bundle.source_domain, target_domain)
              # The bundle-relative file the row came from — named in the
              # unique-constraint error so the operator can fix the bundle.
              source_file = "documents/#{source_qualified}/#{doc.id}.yml"
              create_document(
                db, target_qualified, target_id, rewritten_content, rewritten_meta,
                source_file, actioner_id,
              )
              created += 1
            end
          end
          created
        end

        # Post-commit `display_name` backfill for the documents of
        # `source_qualified_doctypes` now living under `target_domain`.
        # `Import.call` and `Domain::Publish` both call it after commit, so
        # a reference-token template resolves against rows that landed
        # later in the same batch.
        def self.backfill_display_names(
          db : DB::Connection,
          source_qualified_doctypes : Array(String),
          source_domain : String,
          target_domain : String,
        ) : Nil
          source_qualified_doctypes.each do |source_qualified|
            refresh_reference_display_names(db, source_qualified, source_domain, target_domain)
          end
        end

        # ── Stats accumulator ────────────────────────────────────────────

        # Mutable counters shared with the persistence helpers. Lives only
        # for the duration of a single import call.
        private class Stats
          property doctypes_created : Int32 = 0
          property doctypes_updated : Int32 = 0
          property doctypes_unchanged : Int32 = 0
          property document_views_created : Int32 = 0
          property document_views_updated : Int32 = 0
          property document_views_deleted : Int32 = 0
          property collection_views_created : Int32 = 0
          property collection_views_updated : Int32 = 0
          property documents_created : Int32 = 0
          property grant_tickets : Array(Grants::PublishTickets::Ticket) = [] of Grants::PublishTickets::Ticket
        end

        # ── Fresh-import branch ─────────────────────────────────────────

        # Creates the target domain and every bundled doctype from
        # scratch. No version gate — the bundle is the initial state.
        private def self.apply_fresh(
          txn : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
          stats : Stats,
        ) : Nil
          # 1. Create the core.Domain document. The bundled content is
          #    rewritten so `id` (the implicit projection id) and any
          #    `draft` flag match the target identity; everything else
          #    (description, color, grants, context_sets) is copied
          #    verbatim.
          create_domain(txn, bundle, target_domain)

          # 2. Create every doctype and its owned views.
          definitions = apply_doctypes(txn, bundle, target_domain, stats, fresh: true)

          # 2.5 File the grant tickets for outbound cross-domain edges
          #    (replicate fields + foreign-source hooks) — the same scan
          #    the publish flow runs (B-10). The import is a system actor,
          #    so tickets file inactive.
          grant_tickets = file_grant_tickets(txn, target_domain, definitions)
          stats.grant_tickets = grant_tickets

          # 3. Create every bundled document. Doctypes are now registered,
          #    so `DefinitionStore.fetch` resolves for every one of them.
          #    Runs in its own pass so a composition child can rely on the
          #    parent doctype being present even when the bundle orders
          #    them differently. The parent_id linkage is stored on
          #    `meta.parent_id`, not enforced by an FK, so children may be
          #    written before their parent row without raising.
          reconcile_documents(txn, bundle, target_domain, stats)
        end

        # ── Merge branch ─────────────────────────────────────────────────

        # Applies the bundle on top of an existing target domain. Every
        # doctype goes through the version gate.
        private def self.apply_merge(
          txn : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
          stats : Stats,
        ) : Nil
          # Reconcile doctypes: bundled, plus target-only ones become
          # orphan detection (we do NOT delete target-only doctypes —
          # they may carry live data the bundle does not know about; the
          # operator must delete them explicitly).
          definitions = apply_doctypes(txn, bundle, target_domain, stats, fresh: false)

          # File the grant tickets for the merged definitions' outbound
          # cross-domain edges (B-10). The scan is idempotent: an edge the
          # target already carries widens nothing and touches no grant.
          grant_tickets = file_grant_tickets(txn, target_domain, definitions)
          stats.grant_tickets = grant_tickets

          # Documents are idempotently created — re-running an import
          # on top of an existing target is a no-op for created rows.
          # Document updates on merge are explicitly out of scope; the
          # operator should `db_reset` and re-import to refresh data.
          reconcile_documents(txn, bundle, target_domain, stats)
        end

        # Shared per-doctype loop behind both import branches. `fresh`
        # selects the persistence path (blind create vs gated upsert) and
        # is passed through to the view reconciliation. Both branches run
        # inside the caller's transaction, so the fresh-vs-merge
        # atomicity contract is unchanged. Returns the landed definitions
        # (rewritten to the target identity) — the grant-ticket scan's
        # input.
        private def self.apply_doctypes(
          txn : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
          stats : Stats,
          *,
          fresh : Bool,
        ) : Array(Doctype::DoctypeDefinition)
          landed = [] of Doctype::DoctypeDefinition

          bundle.doctypes.each do |entry|
            source_qualified = entry[:doctype]
            target_qualified = target_qualified_name(source_qualified, bundle.source_domain, target_domain)

            # `$force` is read from the raw bundled content root (mirrors
            # `Doctype::Update#parse_body`) and stripped before anything is
            # persisted — the flag is per-operation, never stored.
            force = entry[:entry].content["$force"]?.try(&.as_bool) || false
            rewritten = PublishGate.domained_content(strip_force(entry[:entry].content), target_domain)

            # Stamp the derived per-field `operators` surface before the
            # create/merge dispatch — both branches must see the same
            # canonical content, or the merge path's identity check would
            # fight the stamp (every re-import would "update" each doctype).
            # See `Domain::Copy.with_derived_operators` for why the member
            # must exist on raw-persisted definitions.
            rewritten = Copy.with_derived_operators(rewritten)

            definition = parse_definition(rewritten, target_qualified, DefinitionSource::Bundle)

            if fresh
              # Authoring gate before the first persist (B-302) — the same
              # battery `Doctype::Create` runs on the REST door.
              validate_authoring_gate!(txn, definition, target_qualified)
              create_doctype(txn, target_qualified, rewritten, target_domain)
              stats.doctypes_created += 1
            else
              upsert_doctype_merge(txn, target_qualified, rewritten, target_domain, stats, force: force)
            end
            landed << definition

            reconcile_document_views(txn, target_qualified, target_domain,
              bundle.document_views[source_qualified]?, stats, fresh: fresh)
            reconcile_collection_views(txn, target_qualified, target_domain,
              bundle.collection_views[source_qualified]?, stats, fresh: fresh)
          end

          # Hard replication invariants — the same gate `Doctype::Create`
          # and `Doctype::Update` run before persist (B-164). Runs after
          # the whole loop, not per doctype: a bundle may order the
          # consumer before its producer, and a per-doctype check would
          # silently skip a source that has not landed yet. `$force` does
          # not relax the gate — the authoring door runs the invariants
          # regardless. The raise rolls back the caller's transaction, so
          # the import stays all-or-nothing.
          landed.each do |definition|
            rep_errors = Replication::Validator.validate_invariants(definition, txn)
            next if rep_errors.empty?
            raise ImportError.new(422, "#{definition.qualified_name}: #{rep_errors.first}")
          end

          landed
        end

        # Files the grant tickets for the landed definitions' outbound
        # cross-domain edges — the same `PublishTickets` scan the publish
        # flow runs (B-10). Without it an imported replicate edge is
        # inert: the producer never hears about the consumer. The import
        # is a system actor, so tickets file inactive — the producer's
        # acceptance stays an explicit act, exactly like a publish without
        # the acceptance right. Tickets file only into live producer
        # domains; a draft producer keeps surfacing as a `/check` warning.
        private def self.file_grant_tickets(
          txn : DB::Connection,
          target_domain : String,
          definitions : Array(Doctype::DoctypeDefinition),
        ) : Array(Grants::PublishTickets::Ticket)
          hooks = fetch_target_hooks(txn, target_domain)
          Grants::PublishTickets.file(txn, target_domain, definitions, hooks, false, ACTIONER_ID)
        end

        # Parses the target domain document's `hooks` array — the second
        # edge source for the ticket scan (event hooks whose source domain
        # is foreign). A malformed hook is skipped with a warning, the same
        # leniency the publish flow applies.
        private def self.fetch_target_hooks(txn : DB::Connection, target_domain : String) : Array(Hooks::Definition::Hook)
          content = txn.query_one?("SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'Domain' AND id = $1 AND deleted_at IS NULL", target_domain) { |rs| rs.read(JSON::Any) }
          return [] of Hooks::Definition::Hook if content.nil?

          hooks, errors = Hooks::Definition.parse(content)
          errors.each { |e| Log.warn { "Import ticket scan skips malformed hook: #{e.message}" } }
          hooks
        end

        # Upserts a single doctype during a `--merge` import. Enforces
        # the same version gate `Doctype::Update` enforces, then writes
        # via `Mutation::Client.update` (existing) or
        # `Mutation::Client.create` (missing). `force` is the bundled
        # `$force` flag — it relaxes the same-version destructive-edit
        # rejections, exactly as an editor-driven `$force` update does.
        private def self.upsert_doctype_merge(
          txn : DB::Connection,
          qualified : String,
          new_content : JSON::Any,
          target_domain : String,
          stats : Stats,
          *,
          force : Bool = false,
        ) : Nil
          existing = fetch_existing_doctype(txn, qualified)

          if existing.nil?
            # Authoring gate before the first persist (B-302) — the merge
            # path skips `validate_version_gate!` when the row is missing,
            # so the create door must not skip it either.
            validate_authoring_gate!(txn, parse_definition(new_content, qualified, DefinitionSource::Bundle), qualified)
            create_doctype(txn, qualified, new_content, target_domain)
            stats.doctypes_created += 1
            return
          end

          current_content = existing
          if content_identical?(current_content, new_content)
            stats.doctypes_unchanged += 1
            return
          end

          # Validate version gate before writing. Raises a service error
          # surfaced as a `ServiceError` via the caller's `case ... in`
          # dispatch.
          validate_version_gate!(txn, current_content, new_content, qualified, target_domain, force: force)

          diff = Mutation::JsonDiff.diff(current_content, new_content)
          if diff.empty?
            stats.doctypes_unchanged += 1
            return
          end

          # Stage the projection GUCs from the NEW content before the raw
          # update — the trigger recomputes the row's derived columns from
          # them, and the raw mutation path stages nothing on its own
          # (B-78: an unstaged GUC keeps the old corpus or stores NULL).
          stage_projection_gucs(txn, "core.DocType", new_content)

          mut_id = Mutation::Client.update(
            txn, "core", "DocType", qualified,
            diff_json: diff.to_json,
            actioner_id: ACTIONER_ID,
          )

          fire_doctype_side_effects(txn, qualified, new_content, event: "updated", mutation_id: mut_id)
          stats.doctypes_updated += 1
        end

        # ── Document-view reconciliation ─────────────────────────────────

        # Reconciles `core.DocumentView` rows for the doctype `qualified`
        # against the bundle through the shared `ViewReconciler`.
        #
        # A bundle that carries no views for the doctype states nothing
        # about its views: the live set stays untouched. A bundle may
        # re-declare a doctype without owning its views — for example the
        # `iam` fixture bundle re-declares the seed doctypes, whose views
        # the core seed owns. This mirrors the CollectionView
        # reconciliation below.
        #
        # When the bundle carries at least one view, it is the source of
        # truth for the set:
        #
        # - Bundle `kind` exists in target → update in place (JsonDiff).
        # - Bundle-only `kind` → create.
        # - Target-only `kind` → soft-delete (same as the publish action).
        #
        # In `fresh` mode the live set is empty and nothing is deleted —
        # every bundled view is created.
        private def self.reconcile_document_views(
          txn : DB::Connection,
          qualified : String,
          target_domain : String,
          bundled_views : Array({kind: String, entry: Archive::Entry})?,
          stats : Stats,
          *,
          fresh : Bool,
        ) : Nil
          bundled = bundled_views || [] of {kind: String, entry: Archive::Entry}
          return if bundled.empty?

          live = fresh ? [] of ViewReconciler::Live : fetch_live_document_views(txn, qualified)

          desired = bundled.map do |bv|
            ViewReconciler::Desired.new(
              bv[:kind],
              rewrite_document_view(bv[:entry].content, target_domain, bv[:kind], qualified),
              remap_parent_id(bv[:entry].meta, qualified),
            )
          end

          created, updated, deleted = ViewReconciler.converge(
            live, desired,
            ViewReconciler::Ops.new(
              equal: ->(live_content : JSON::Any, want_content : JSON::Any) { content_identical?(live_content, want_content) },
              create: ->(_kind : String, content : JSON::Any, meta : JSON::Any) {
                create_view_child(txn, "DocumentView", content, meta)
              },
              update: ->(id : String, current_content : JSON::Any, new_content : JSON::Any) {
                upsert_view_child(txn, "DocumentView", id, current_content, new_content)
              },
              delete: ->(id : String) {
                Mutation::Client.delete(txn, "core", "DocumentView", id, actioner_id: ACTIONER_ID)
              },
            ),
            delete_unmatched: !fresh,
          )

          stats.document_views_created += created
          stats.document_views_updated += updated
          stats.document_views_deleted += deleted
        end

        # ── Collection-view reconciliation ────────────────────────────────

        # Reconciles general `core.CollectionView` rows. Unlike
        # DocumentView, CollectionViews are **live-authored** — the
        # bundle never deletes a target-only general view (mirrors the
        # publish action: "CollectionView rows are never touched by
        # publish — they are live-authored and out of scope for the
        # domain definition").
        #
        # Reconciliation matches by `content.name` (the human-readable tab
        # label) rather than by id — general views are slug-stable only
        # when authored consistently.
        private def self.reconcile_collection_views(
          txn : DB::Connection,
          qualified : String,
          target_domain : String,
          bundled_views : Array(Archive::CollectionView)?,
          stats : Stats,
          *,
          fresh : Bool,
        ) : Nil
          bundled = bundled_views || [] of Archive::CollectionView
          return if bundled.empty? && fresh
          return if bundled.empty?

          # Build a name → target id map for the doctype's general views.
          target_views = fetch_general_collection_views(txn, qualified)

          bundled.each do |cv|
            name = view_name(cv.entry.content)
            target_id = name.empty? ? nil : target_views[name]?

            # Rewrite parent_id linkage on the bundle content so the new
            # view attaches to the target doctype rather than the source.
            meta = remap_parent_id(cv.entry.meta, qualified)

            if target_id.nil?
              stats.collection_views_created += 1
              create_view_child(txn, "CollectionView", cv.entry.content, meta)
            else
              tid = target_id
              next unless tc = fetch_view_content(txn, "CollectionView", tid)
              if upsert_view_child(txn, "CollectionView", tid, tc, cv.entry.content)
                stats.collection_views_updated += 1
              end
            end
          end
        end

        # ── Documents ──────────────────────────────────────────────────────

        # Creates every bundled document under the target domain. Skips
        # rows that already exist (idempotent — re-running an import is
        # a no-op). When `--into` renamed the target domain, the document
        # id, every `reference`-shaped string inside the content that
        # starts with `{source}.`, and `meta.parent_id` (when it starts
        # with `{source}.`) are rewritten to the target identity.
        #
        # The `core` domain is never encountered here — `fetch_documents`
        # on the export side already excludes definition doctypes, and
        # `bundle.documents` only carries user-doctype rows.
        private def self.reconcile_documents(
          txn : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
          stats : Stats,
        ) : Nil
          stats.documents_created += import_documents(txn, bundle, target_domain)
        end

        # Writes one document via `Mutation::Client.create`. Stages the
        # search/links/display_name GUCs the projection trigger reads —
        # same as `Document::Create`. Without
        # this, the seeded row would land with `display_name = NULL` and
        # broken link/search columns.
        #
        # Replicated fields are pulled from their source documents before
        # persist (same semantics as `Document::Create`'s SyncPull hook) —
        # otherwise every bundled row would land with a null replica until
        # the next source mutation. The pull is a best-effort read within
        # the same transaction: a source document that has not landed yet
        # (e.g. a cross-bundle reference) leaves the replica null, exactly
        # like the create path on a missing source.
        private def self.create_document(
          txn : DB::Connection,
          target_qualified : String,
          doc_id : String,
          content : JSON::Any,
          meta : JSON::Any,
          source_file : String? = nil,
          actioner_id : String = ACTIONER_ID,
        ) : Nil
          domain_segment, _, doctype_segment = target_qualified.partition('.')
          # Authoring gate (B-277) — the same validators the document
          # pipeline runs on the RBAC-relevant doctypes. Runs before the
          # unique-constraint check, the same order `Document::Create`
          # uses. Raises `ImportError`, so the caller's transaction rolls
          # the whole import back.
          validate_document_authoring!(txn, target_qualified, doc_id, content, meta, source_file)
          defn = Doctype::DefinitionStore.fetch(txn, target_qualified)
          if defn
            # Secret-leaf gate (B-370) — the write door's type-layer check
            # and adoption step. A bundled row skips the document pipeline,
            # so without this a plaintext string or a forged marker in a
            # `secret` field lands verbatim in the projection, the event
            # log, and export. Raises `ImportError` on any refusal; the
            # payload is never rewritten — `mutations` is the replay
            # source.
            content = validate_secret_gate!(
              txn, defn, target_qualified, doc_id, content, source_file, actioner_id,
            )
            # Enforce the same `unique: true` constraints the REST create
            # path enforces (B-32) — the portable import writes through
            # `Mutation::Client` directly, so without this a colliding
            # bundle would land duplicate rows. Checked inside the import
            # transaction, so an earlier row of the same batch also counts.
            unique_errors = Document::UniqueConstraint.check(txn, domain_segment, doctype_segment, content, defn)
            unless unique_errors.empty?
              where = source_file ? " from #{source_file}" : ""
              raise ImportError.new(
                422,
                "Bundle document '#{target_qualified}##{doc_id}'#{where} violates a unique constraint: #{unique_errors.first.field || "unknown field"}: #{unique_errors.first.message}",
                details: unique_errors,
              )
            end
            content = Replication::SyncPull.call(txn, defn, content)
            Document::ProjectionGucs.set_all(txn, defn, content)
          else
            Document::ProjectionGucs.clear_all(txn)
          end
          Mutation::Client.create(
            txn,
            domain_segment,
            doctype_segment,
            doc_id: doc_id,
            content: content.to_json,
            meta: meta.to_json,
            actioner_id: actioner_id,
          )
        end

        # ── Helpers — persistence ────────────────────────────────────────

        # Creates the target `core.Domain` document from the bundle.
        # Rewrites the bundled content so it cannot carry the source
        # identity or a `draft` flag forward.
        private def self.create_domain(
          txn : DB::Connection,
          bundle : Archive::Bundle,
          target_domain : String,
        ) : Nil
          content = rewrite_domain(bundle.domain.content, target_domain)
          # Authoring gate (B-277) — the same checks a domain save runs
          # (`Document::Update#validate_rbac_definitions?`): context sets
          # and declared hooks. Raises `ImportError`, so the caller's
          # transaction rolls the whole import back.
          validate_domain_authoring!(target_domain, content)
          # The source bundle's `meta.parent_id` (if present) is stale —
          # core.Domain is a top-level document. Drop it.
          meta = drop_parent_id(bundle.domain.meta)
          # core.Domain has no parseable definition — stage the empty GUC
          # set, the same branch Document::Create uses for domain creates.
          Document::ProjectionGucs.clear_all(txn)
          mut_id = Mutation::Client.create(
            txn, "core", "Domain",
            doc_id: target_domain,
            content: content.to_json,
            meta: meta.to_json,
            actioner_id: ACTIONER_ID,
          )
          Event::Publisher.enqueue(
            domain: "core", doc_type: "Domain",
            doc_id: target_domain, event: "created",
            mutation_id: mut_id, actioner_id: ACTIONER_ID,
          )
        end

        # Creates a `core.DocType` row from rewritten bundle content.
        # Delegates to `Domain::Copy.upsert_doctype_definition` — its create
        # branch, since both callers guarantee the row is absent — so import
        # and publish share one persist-with-side-effects path: `registered`
        # event, index sync, cache invalidation.
        private def self.create_doctype(
          txn : DB::Connection,
          qualified : String,
          new_content : JSON::Any,
          target_domain : String,
        ) : Nil
          doctype_name = qualified.lchop("#{target_domain}.")
          Copy.upsert_doctype_definition(
            txn, new_content, doctype_name, target_domain, ACTIONER_ID,
            event: "registered",
          )
        end

        # Fires the post-persist side effects that `Domain::Copy` and
        # `Doctype::Create`/`Update` perform. Runs on the caller's
        # connection so index sync sees the just-committed row.
        private def self.fire_doctype_side_effects(
          db : DB::Connection,
          qualified : String,
          new_content : JSON::Any,
          *,
          event : String,
          mutation_id : String,
        ) : Nil
          Event::Publisher.enqueue(
            domain: "core", doc_type: "DocType",
            doc_id: qualified, event: event,
            mutation_id: mutation_id, actioner_id: ACTIONER_ID,
          )
          defn = Doctype::DoctypeDefinition.from_json(new_content.to_json)
          Index::Manager.sync(db, defn)
          Doctype::DefinitionStore.invalidate(qualified)
        end

        # Creates a `core.DocumentView` or `core.CollectionView` child
        # row with a fresh ULID and enqueues the `created` event. The
        # `doc_type` argument selects between the two child doctypes both
        # helpers share.
        private def self.create_view_child(
          txn : DB::Connection,
          doc_type : String,
          content : JSON::Any,
          meta : JSON::Any,
        ) : Nil
          new_id = Util::ScriptHelpers.ulid
          # Stage the projection GUCs from the target doctype's stored
          # definition — the raw mutation path stages nothing, and an
          # unstaged GUC stores a NULL derived column (B-78). The view
          # doctypes carry a `search` template, so an unstaged child row
          # silently matches nothing.
          stage_projection_gucs(txn, "core.#{doc_type}", content)
          Mutation::Client.create(
            txn, "core", doc_type,
            doc_id: new_id,
            content: content.to_json,
            meta: meta.to_json,
            actioner_id: ACTIONER_ID,
          )
          Event::Publisher.enqueue(
            domain: "core", doc_type: doc_type,
            doc_id: new_id, event: "created",
            mutation_id: new_id, actioner_id: ACTIONER_ID,
          )
        end

        # Updates a child row in place when the bundled content differs.
        # Returns `true` when a mutation was written, `false` when the
        # contents were identical or the diff was empty.
        private def self.upsert_view_child(
          txn : DB::Connection,
          doc_type : String,
          target_id : String,
          current_content : JSON::Any,
          new_content : JSON::Any,
        ) : Bool
          return false if content_identical?(current_content, new_content)
          diff = Mutation::JsonDiff.diff(current_content, new_content)
          return false if diff.empty?
          stage_projection_gucs(txn, "core.#{doc_type}", new_content)
          mut_id = Mutation::Client.update(
            txn, "core", doc_type, target_id,
            diff_json: diff.to_json,
            actioner_id: ACTIONER_ID,
          )
          Event::Publisher.enqueue(
            domain: "core", doc_type: doc_type,
            doc_id: target_id, event: "updated",
            mutation_id: mut_id, actioner_id: ACTIONER_ID,
          )
          true
        end

        # Stages the projection GUCs (`harness.mutation_search` / `_links` /
        # `_display_name`) for a raw `core.*` mutation written outside the
        # document pipeline. `qualified_doctype` names the doctype the row
        # is written under; its stored definition supplies the templates.
        # A missing or corrupt definition takes the no-definition branch
        # (`clear_all`), exactly like the pipeline's fallback — the trigger
        # then stores NULL derived columns instead of guessing.
        private def self.stage_projection_gucs(
          txn : DB::Connection,
          qualified_doctype : String,
          content : JSON::Any,
        ) : Nil
          defn = Doctype::DefinitionStore.fetch(txn, qualified_doctype)
          if defn
            Document::ProjectionGucs.set_all(txn, defn, content)
          else
            Document::ProjectionGucs.clear_all(txn)
          end
        end

        # Extracts the `name` field from a view content object, returning
        # an empty string when absent. Used to match CollectionViews by
        # name during reconciliation.
        private def self.view_name(content : JSON::Any) : String
          h = content.as_h?
          return "" unless h
          h["name"]?.try(&.as_s?) || ""
        end

        # ── Helpers — validation ─────────────────────────────────────────

        # Enforces the version gate before a doctype update. Returns the
        # bundled definition parsed (used downstream for the index sync).
        # Raises `ImportError` on any rejection; the caller converts to a
        # `ServiceError` via `case ... in ImportError`.
        private def self.validate_version_gate!(
          txn : DB::Connection,
          current_content : JSON::Any,
          new_content : JSON::Any,
          qualified : String,
          target_domain : String,
          *,
          force : Bool = false,
        ) : Nil
          current_def = parse_definition(current_content, "#{qualified} (stored)", DefinitionSource::Stored)
          new_def = parse_definition(new_content, qualified, DefinitionSource::Bundle)

          # Identity: doctype/domain cannot move. The qualified id stays
          # the same across import (the doc_id is the qualified name), so
          # we check the definition's own fields against the stored ones.
          unless new_def.doctype == current_def.doctype
            raise ImportError.new(
              422,
              "#{qualified}: doctype identity cannot change (#{current_def.doctype} → #{new_def.doctype})",
            )
          end
          unless new_def.domain == target_domain
            raise ImportError.new(
              422,
              "#{qualified}: domain field '#{new_def.domain}' does not match target '#{target_domain}'",
            )
          end

          current_version = current_def.schema_version
          new_version = new_def.schema_version

          # Same rules as `Doctype::Update#validate_version`, wording shared
          # via `Doctype::DefinitionGate`; the qualified id prefixes each
          # message.
          Doctype::DefinitionGate.version_violations(current_version, new_version).each do |violation|
            raise ImportError.new(422, "#{qualified}: #{violation}")
          end

          is_breaking = new_version > current_version

          check_same_version_guards(current_def, new_def, is_breaking, qualified, force: force)

          # Run the same full schema validation `Doctype::Update` runs,
          # passing the current version so the migration gap check fires
          # for breaking bumps.
          begin
            errors = Doctype::Validation.validate(new_def, current_version)
          rescue ex : ArgumentError
            raise ImportError.new(422, "#{qualified}: schema validation raised: #{ex.message}")
          end
          unless errors.empty?
            raise ImportError.new(422, "#{qualified}: schema validation failed", errors)
          end

          # Validate the script (compile + ScriptValidator). Mirrors
          # `Doctype::Update`'s implicit step. An empty script is "no
          # script" — `Doctype::Validation` skips it, so the gate must too.
          if (script = new_def.script) && !script.empty?
            script_errors = Doctype::ScriptValidator.validate(script, new_def)
            unless script_errors.empty?
              raise ImportError.new(422, "#{qualified}: script validation failed", script_errors)
            end
          end

          # Cross-doctype gates — the authoring-door checks the version
          # gate did not cover before (B-302): draft targets (B-287) and
          # named scopes against the target domain's context sets.
          validate_cross_doctype_gates!(txn, new_def, qualified)
        end

        # Authoring gate on the import door (B-302). Runs the checks a
        # `Doctype::Create` save runs before it persists — schema
        # validation, script validation, the draft-target gate, and
        # named-scope validation — so a bundled definition cannot land a
        # state the authoring API refuses to re-save. Imported domains are
        # never drafts (a draft bundle is rejected at the top of `call`),
        # so the strict validators run unconditionally, mirroring
        # `validate_version_gate!`'s stance on the merge path. Raises
        # `ImportError`; the caller's transaction rolls the import back.
        private def self.validate_authoring_gate!(
          txn : DB::Connection,
          definition : Doctype::DoctypeDefinition,
          qualified : String,
        ) : Nil
          begin
            errors = Doctype::Validation.validate(definition)
          rescue ex : ArgumentError
            raise ImportError.new(422, "#{qualified}: schema validation raised: #{ex.message}")
          end
          unless errors.empty?
            raise ImportError.new(422, "#{qualified}: schema validation failed", errors)
          end

          # Validate the script (compile + ScriptValidator). Mirrors the
          # REST door's implicit step. An empty script is "no script" —
          # `Doctype::Validation` skips it, so the gate must too.
          if (script = definition.script) && !script.empty?
            script_errors = Doctype::ScriptValidator.validate(script, definition)
            unless script_errors.empty?
              raise ImportError.new(422, "#{qualified}: script validation failed", script_errors)
            end
          end

          validate_cross_doctype_gates!(txn, definition, qualified)
        end

        # Draft-target gate (B-287) and named-scope validation — the
        # authoring-door checks that read other rows. Shared by the fresh
        # persist gate and the merge version gate. Raises `ImportError` on
        # the first failing gate.
        private def self.validate_cross_doctype_gates!(
          txn : DB::Connection,
          definition : Doctype::DoctypeDefinition,
          qualified : String,
        ) : Nil
          draft_errors = Doctype::DraftTargetCheck.validate(txn, definition)
          unless draft_errors.empty?
            raise ImportError.new(422, "#{qualified}: cross-domain reference targets a draft domain", draft_errors)
          end

          scope_errors = RBAC::Validator.validate_named_scopes_for(txn, definition)
          unless scope_errors.empty?
            raise ImportError.new(422, "#{qualified}: named scope validation failed", scope_errors)
          end
        end

        # Same-version guards — same rules as
        # `Doctype::Update#check_same_version_guards`, shared via
        # `Doctype::DefinitionGate`. `force` is the bundled `$force`
        # flag: it skips the same-version data-shape rejections exactly as
        # an editor-driven `$force` update does. It does NOT relax the
        # migrations guard here, and the version rules in
        # `validate_version_gate!` (no decrease, no jump past +1) stay
        # enforced. The guard order (migrations, removed fields, type
        # changes, data shape) matches `Doctype::Update`. Raises
        # `ImportError` on any rejection.
        private def self.check_same_version_guards(
          current_def : Doctype::DoctypeDefinition,
          new_def : Doctype::DoctypeDefinition,
          is_breaking : Bool,
          qualified : String,
          *,
          force : Bool = false,
        ) : Nil
          violations = Doctype::DefinitionGate.same_version_violations(current_def, new_def, is_breaking, force)
          return if violations.nil?

          message = Doctype::DefinitionGate.render(violations, Doctype::DefinitionGate::Style::Import).first?
          raise ImportError.new(422, "#{qualified}: #{message}") if message
        end

        # ── Helpers — DB lookups ─────────────────────────────────────────

        private def self.fetch_existing_doctype(db : DB::Connection, qualified : String) : JSON::Any?
          db.query_one?(
            "SELECT content FROM projections WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1 AND deleted_at IS NULL",
            qualified,
            as: JSON::Any,
          )
        end

        # True when a non-deleted document with `doc_id` already lives on
        # the target under the qualified doctype. Idempotency guard for the
        # document creation phase.
        private def self.document_exists?(
          db : DB::Connection,
          target_qualified : String,
          doc_id : String,
        ) : Bool
          domain_segment, _, doctype_segment = target_qualified.partition('.')
          Util::Projections.exists?(db, domain_segment, doctype_segment, doc_id)
        end

        # Returns the live DocumentView rows of a doctype as reconciler
        # input: one `{id, kind, content}` per row. A row without a kind
        # keeps `nil` — the reconciler treats it as never matching a
        # desired kind.
        private def self.fetch_live_document_views(
          db : DB::Connection,
          qualified : String,
        ) : Array(ViewReconciler::Live)
          db.query_all(
            <<-SQL,
              SELECT id, content->>'kind', content FROM projections
              WHERE domain = 'core' AND doc_type = 'DocumentView'
                AND meta->>'parent_id' = $1
                AND deleted_at IS NULL
              ORDER BY id ASC
            SQL
            qualified,
          ) do |rs|
            id = rs.read(String)
            kind = rs.read(String?)
            content = rs.read(JSON::Any)
            ViewReconciler::Live.new(id, kind, content)
          end
        end

        # Returns a `name → id` map for the **general** CollectionViews
        # of a doctype. Matches the export's general-view predicate so
        # import never touches personal views.
        private def self.fetch_general_collection_views(
          db : DB::Connection,
          qualified : String,
        ) : Hash(String, String)
          rows = db.query_all(
            <<-SQL,
              SELECT id, content->>'name' FROM projections
              WHERE domain = 'core' AND doc_type = 'CollectionView'
                AND meta->>'parent_id' = $1
                AND deleted_at IS NULL
                AND (content->>'owner_id' IS NULL
                     OR content->>'owner_id' = ''
                     OR content->>'owner_id' = 'null')
            SQL
            qualified,
          ) do |rs|
            {rs.read(String), rs.read(String?) || ""}
          end
          map = {} of String => String
          rows.each do |(id, name)|
            map[name] = id unless name.empty?
          end
          map
        end

        private def self.fetch_view_content(
          db : DB::Connection,
          doc_type : String,
          id : String,
        ) : JSON::Any?
          db.query_one?(
            "SELECT content FROM projections WHERE domain = 'core' AND doc_type = $1 AND id = $2 AND deleted_at IS NULL",
            doc_type, id,
            as: JSON::Any,
          )
        end

        # ── Helpers — parsing ────────────────────────────────────────

        # Which artifact a definition parse failure names. A bundle grammar
        # error points the operator at the bundle file; a stored-definition
        # failure points at the database row.
        private enum DefinitionSource
          Bundle
          Stored
        end

        private def self.parse_definition(
          content : JSON::Any,
          label : String,
          source : DefinitionSource,
        ) : Doctype::DoctypeDefinition
          Doctype::DoctypeDefinition.from_json(content.to_json)
        rescue ex : JSON::ParseException
          artifact = source.stored? ? "stored doctype definition is corrupt" : "bundle doctype definition is invalid"
          raise ImportError.new(422, "#{label}: #{artifact}: #{ex.message}")
        end

        private def self.bundle_domain_draft?(bundle : Archive::Bundle) : Bool
          content = bundle.domain.content
          h = content.as_h?
          return false unless h
          d = h["draft"]?
          return false unless d
          d.raw == true
        end

        # Local exception type used to abort the import with a specific
        # `ServiceError`. Raised inside the transaction so the savepoint
        # rolls back the partial writes; recaught by the caller via
        # `case ... in ImportError`.
        class ImportError < ::Exception
          getter status : Int32
          getter error_message : String
          getter details : Array(Facet::ValidationError)?

          def initialize(@status : Int32, @error_message : String, @details : Array(Facet::ValidationError)? = nil)
            super(@error_message)
          end

          def to_service_error : Facet::ServiceError
            Facet::ServiceError.new(@status, @error_message, @details)
          end
        end
      end
    end
  end
end
