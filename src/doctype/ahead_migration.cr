# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "opentelemetry"
require "pg"
require "../database"
require "../error"
require "../mutation/client"
require "../document/migrate"
require "./doctype_definition"
require "./definition_store"

module Facet
  module Doctype
    # Eager (ahead) migration for a doctype's live documents.
    #
    # ## Why this exists
    #
    # Documents migrate lazily on read/write. After a definition bump, an
    # untouched corpus keeps the old `meta.schema_version` until each row is
    # next touched. This service pushes every live document to the current
    # definition version in one run, so the operator does not wait for lazy
    # migration to drip through reads and writes.
    #
    # ## Contract
    #
    # 1. A count pass reports how many live rows sit below the current
    #    definition version.
    # 2. The run pages through those rows in batches of `BATCH_SIZE` ids,
    #    past a keyset cursor on `id`, until a page returns no rows. The
    #    cursor is what makes "tried once per run" hold: a row whose
    #    migration fails keeps its old version, so a fresh re-scan would
    #    return it forever — the cursor never revisits a visited row.
    # 3. Each row runs in its own transaction: lock `FOR UPDATE`, re-check
    #    the version (a concurrent write may have migrated it — counted as
    #    superseded), strip a `meta.migration_error` marker in memory so a
    #    blocked row can retry, then `Document::Migrate.call`. One bad row
    #    never rolls back its batch neighbours.
    # 4. A failing row writes nothing (this run never writes the marker —
    #    only the lazy read/list paths do). It is counted once and the run
    #    continues. Because the row keeps its old version, the next run —
    #    typically after the Lua script was fixed — picks it up again.
    #    A row that carried a marker keeps it on failure; on success the
    #    migrated document persists with clean meta and the marker is gone.
    #
    # The audit footprint is one `mutations` row per migrated document —
    # the same price the lazy path pays per document, paid up front.
    module AheadMigration
      BATCH_SIZE = 10

      class Stats
        property migrated : Int32 = 0
        property superseded : Int32 = 0
        property failed : Int32 = 0
        property skipped : Int32 = 0
        property batches : Int32 = 0
        property failed_ids : Array(String) = [] of String
      end

      record Result,
        stats : Stats,
        total : Int32

      # Migrates every live document of *qualified_doctype* whose
      # `meta.schema_version` sits below the definition's current version.
      #
      # Returns `Result` on success or `ServiceError` if `qualified_doctype`
      # is malformed or the doctype cannot be resolved. Sequential by design:
      # per-document transactions are short, and batches of ten keep the run
      # well inside one pooled connection.
      def self.call(
        db : DB::Connection,
        qualified_doctype : String,
        *,
        batch_size : Int32 = BATCH_SIZE,
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "doctype.ahead_migration" do |span|
          span["qualified_doctype"] = qualified_doctype
          span["batch_size"] = batch_size.to_s

          dot = qualified_doctype.index('.')
          return Facet::ServiceError.new(400, "Invalid qualified doctype '#{qualified_doctype}' (expected 'domain.Doctype')") unless dot && dot > 0
          domain = qualified_doctype[0...dot]
          doc_type = qualified_doctype[(dot + 1)..]

          defn = DefinitionStore.fetch(db, qualified_doctype)
          return Facet::ServiceError.new(404, "Doctype #{qualified_doctype} not found") unless defn

          total = count_ahead(db, domain, doc_type, defn.schema_version)
          span["total"] = total.to_s

          stats = Stats.new
          cursor = ""

          loop do
            ids = scan_batch(db, domain, doc_type, cursor, defn.schema_version, batch_size)
            break if ids.empty?

            stats.batches += 1
            ids.each do |id|
              outcome = process_one(db, defn, domain, doc_type, id)
              case outcome
              when :migrated   then stats.migrated += 1
              when :superseded then stats.superseded += 1
              when :failed
                stats.failed += 1
                stats.failed_ids << id
              else stats.skipped += 1
              end
            end

            cursor = ids.last
          end

          span["migrated"] = stats.migrated.to_s
          span["failed"] = stats.failed.to_s
          Result.new(stats: stats, total: total)
        end
      end

      # ── Scan ────────────────────────────────────────────────────────────

      # One keyset page of row ids below *current_version*, oldest ULID
      # first. The regex guard keeps a non-numeric `schema_version` from
      # killing the cast: such rows read as version 1, the same default
      # `Document::Migrate.extract_schema_version` applies.
      private def self.scan_batch(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        last_id : String,
        current_version : Int32,
        batch_size : Int32,
      ) : Array(String)
        db.query_all(<<-SQL, domain, doc_type, last_id, current_version, batch_size, as: String)
          SELECT id FROM projections
          WHERE domain = $1 AND doc_type = $2
            AND deleted_at IS NULL
            AND id > $3
            AND COALESCE(
              CASE WHEN meta->>'schema_version' ~ '^[0-9]+$'
                   THEN (meta->>'schema_version')::int END, 1) < $4
          ORDER BY id
          LIMIT $5
        SQL
      end

      # Counts live rows below *current_version* — progress reporting and
      # the confirm-dialog number. The scan cursor never relies on it.
      private def self.count_ahead(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        current_version : Int32,
      ) : Int32
        db.query_one(<<-SQL, domain, doc_type, current_version, as: Int64).to_i32
          SELECT count(*) FROM projections
          WHERE domain = $1 AND doc_type = $2
            AND deleted_at IS NULL
            AND COALESCE(
              CASE WHEN meta->>'schema_version' ~ '^[0-9]+$'
                   THEN (meta->>'schema_version')::int END, 1) < $3
        SQL
      end

      # ── Per-document processing ─────────────────────────────────────────

      # Locks the row, re-checks it under the lock, and runs the migration.
      #
      # Returns `:migrated` when the row reaches the current version,
      # `:superseded` when a concurrent write already brought it there,
      # `:skipped` when the row is gone, and `:failed` when
      # `Document::Migrate` still rejects it (nothing is written).
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

          # Optimistic re-check under the lock: a concurrent write that
          # landed between the scan and the lock may have migrated the row.
          unless Document::Migrate.migration_needed?(cur, defn)
            next :superseded
          end

          # Strip a `migration_error` marker in memory so a blocked row can
          # retry. On success the migrated document persists with clean
          # meta; on failure nothing is written and the stored marker
          # survives untouched.
          cleared = Document::Migrate.migration_blocked?(cur) ? cur.with_meta(strip_marker(cur.meta)) : cur

          result = Document::Migrate.call(txn, defn, cleared)
          case result
          in Document::Migrate::Result then :migrated
          in Facet::ServiceError       then :failed
          end
        end
      end

      # Returns a copy of *meta* without the `migration_error` key.
      private def self.strip_marker(meta : JSON::Any) : JSON::Any
        h = meta.as_h?
        return meta if h.nil?

        new_h = h.dup
        new_h.delete("migration_error")
        JSON::Any.new(new_h)
      end

      Log = ::Log.for("facet.doctype.ahead_migration")
    end
  end
end
