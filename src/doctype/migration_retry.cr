# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "../database"
require "../error"
require "../mutation/client"
require "../document/migrate"
require "../document/snapshot_persist"
require "./doctype_definition"
require "./definition_store"

module Facet
  module Doctype
    # Operator recovery for documents blocked by a `meta.migration_error`
    # marker (B-301).
    #
    # A failed lazy migration writes the marker and then blocks every retry
    # (`Document::Migrate.migration_blocked?`). No REST or CLI surface could
    # clear it, so a document whose definition was later fixed stayed stale
    # forever. This service clears the marker per document and re-runs the
    # lazy migration in the same pass:
    #
    # 1. Scan the doctype's live rows for `meta->'migration_error'`.
    # 2. Per row: open one transaction, lock the row `FOR UPDATE`, and
    #    re-check the marker (a concurrent write may have cleared it).
    # 3. Rebuild the projection's meta without the marker and call
    #    `Document::Migrate.call` on it. Success persists the migrated
    #    document with a clean meta. Failure writes nothing — the original
    #    marker survives, so the command is safe to re-run after the
    #    definition is fixed.
    #
    # A row already at the current schema version still carries a stale
    # marker (the migration fast path never rewrites meta). For those the
    # service persists a content-preserving snapshot with the marker
    # dropped.
    #
    # The marker stays invisible through REST reads and lists (B-342), so
    # the CLI door is the recovery surface — see `MigrationRetryCLI`.
    module MigrationRetry
      Actioner = "system:migration-retry"
      Cause    = Mutation::Cause.root(Mutation::CauseKind::Migration, name: "migration_retry")

      SCAN_BATCH = 500

      class Stats
        property scanned : Int32 = 0
        property migrated : Int32 = 0
        property failed : Int32 = 0
        property skipped : Int32 = 0
        property failed_ids : Array(String) = [] of String
      end

      record Result,
        stats : Stats

      # Re-runs lazy migration for every live document of
      # *qualified_doctype* that carries a `meta.migration_error` marker.
      #
      # Sequential by design: marked rows are the rare failure tail, not a
      # full corpus, so the producer/worker machinery of `Reproject` buys
      # nothing here. Rows the scan reports but that lose the marker (or the
      # row itself) before the lock are counted as skipped.
      #
      # Returns `Result` on success or `ServiceError` if the doctype cannot
      # be resolved or `qualified_doctype` is malformed.
      def self.call(
        db : DB::Connection,
        qualified_doctype : String,
        *,
        limit : Int32? = nil,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "doctype.migration_retry" do |span|
          span["qualified_doctype"] = qualified_doctype

          dot = qualified_doctype.index('.')
          return Facet::ServiceError.new(400, "Invalid qualified doctype '#{qualified_doctype}' (expected 'domain.Doctype')") unless dot && dot > 0
          domain = qualified_doctype[0...dot]
          doc_type = qualified_doctype[(dot + 1)..]

          defn = DefinitionStore.fetch(db, qualified_doctype)
          return Facet::ServiceError.new(404, "Doctype #{qualified_doctype} not found") unless defn

          stats = Stats.new
          last_id = ""

          loop do
            ids = scan_batch(db, domain, doc_type, last_id, limit && (limit - stats.scanned))
            break if ids.empty?

            ids.each do |id|
              last_id = id
              stats.scanned += 1
              outcome = process_one(db, defn, domain, doc_type, id)
              if outcome == :migrated
                stats.migrated += 1
              elsif outcome == :failed
                stats.failed += 1
                stats.failed_ids << id
              else
                stats.skipped += 1
              end
            end

            break if ids.size < SCAN_BATCH
          end

          span["scanned"] = stats.scanned.to_s
          span["migrated"] = stats.migrated.to_s
          span["failed"] = stats.failed.to_s
          Result.new(stats: stats)
        end
      end

      # One keyset page of marked row ids, oldest ULID first. `remaining`
      # trims the page when a `--limit` caps the run.
      private def self.scan_batch(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        last_id : String,
        remaining : Int32?,
      ) : Array(String)
        sql = <<-SQL
          SELECT id FROM projections
          WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL
            AND meta->'migration_error' IS NOT NULL
            AND id > $3
          ORDER BY id
          LIMIT $4
        SQL
        batch = [SCAN_BATCH, remaining || SCAN_BATCH].min
        db.query_all(sql, domain, doc_type, last_id, batch, as: String)
      end

      # Clears the marker on one locked row and re-runs the migration.
      #
      # Returns `:migrated` when the row ends without the marker, `:failed`
      # when `Document::Migrate` still rejects it (nothing is written, the
      # stored marker survives), and `:skipped` when the row is gone or was
      # already unmarked under the lock.
      private def self.process_one(
        db : DB::Connection,
        defn : DoctypeDefinition,
        domain : String,
        doc_type : String,
        id : String,
      ) : Symbol
        Database.with_transaction(db, ignore_if_set: true) do |txn|
          locked = txn.query_one?(
            "SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL FOR UPDATE",
            domain, doc_type, id,
            as: String,
          )
          next :skipped if locked.nil?

          cur = Mutation::Client.fetch_projection(txn, domain, doc_type, id)
          next :skipped unless Document::Migrate.migration_blocked?(cur)

          cleared_meta = strip_marker(cur.meta)
          cleared = cur.with_meta(cleared_meta)

          unless Document::Migrate.migration_needed?(cleared, defn)
            # Already at the current version — only the stale marker remains.
            persist_markerless_snapshot(txn, defn, cleared)
            next :migrated
          end

          result = Document::Migrate.call(txn, defn, cleared)
          case result
          in Document::Migrate::Result then :migrated
          in Facet::ServiceError       then :failed
          end
        end
      end

      # Persists a content-preserving snapshot whose meta lacks the marker.
      # Same shape as `Document::Migrate.write_migration_error_marker`, with
      # the key removed instead of added.
      private def self.persist_markerless_snapshot(
        txn : DB::Connection,
        defn : DoctypeDefinition,
        projection : Mutation::Client::Projection,
      ) : Nil
        Document.persist_snapshot_mutation(
          txn, projection.domain, projection.doc_type, projection.id,
          content: projection.content, meta: strip_marker(projection.meta),
          actioner_id: Actioner,
          cause: Cause,
          definition: defn,
          version: projection.version,
          created_at: projection.created_at.to_rfc3339,
        )
      end

      # Returns a copy of *meta* without the `migration_error` key.
      private def self.strip_marker(meta : JSON::Any) : JSON::Any
        h = meta.as_h?
        return meta if h.nil?

        new_h = h.dup
        new_h.delete("migration_error")
        JSON::Any.new(new_h)
      end

      Log = ::Log.for("facet.doctype.migration_retry")
    end
  end
end
