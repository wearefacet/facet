# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "../database"
require "../doctype/definition_store"
require "../document/delete"
require "../rbac"
require "../error"
require "../util/sidecars"

module Facet
  module Cron
    # Periodic orphan reconciliation for sidecar records.
    #
    # Backstop for the event-driven `Event::Subscriber::SidecarSweep`
    # subscriber. The sweep tombstones sidecar records immediately when a
    # host document is soft-deleted through the normal `Document::Delete`
    # path. This cron catches the orphans the sweep misses:
    #
    # - a sweep `deleted` event lost between Redis and the consumer group
    #   (a Redis stream trim, a consumer that was down at delivery time),
    # - a host projection row hard-deleted by a maintenance script
    #   (bypassing the soft-delete path so no `deleted` event was emitted),
    # - a sidecar created against a host that was already gone (a referential
    #   race: the host-read gate in `SidecarHandler` checks existence, but
    #   a host hard-delete between the gate and the sidecar create commit
    #   leaves an orphan).
    #
    # ## Algorithm
    #
    # For every sidecar doctype (every `core.DocType` projection with
    # `sidecar: true`):
    #
    # 1. Read the live sidecar records' `target` reference values.
    # 2. Parse each into `(host_domain, host_doctype, host_id)` on the
    #    first two dots only (the id segment may itself contain a dot —
    #    see the qualified reference storage contract).
    # 3. Group host ids by `(host_domain, host_doctype)`.
    # 4. For each group, batch-check host existence (batch size 1000):
    #    `SELECT id FROM projections WHERE domain = $1 AND doc_type = $2
    #    AND id = ANY($3) AND deleted_at IS NULL`.
    # 5. For each missing host id, soft-delete the sidecar record(s) whose
    #    `target` equals the orphaned qualified host id, via
    #    `Document::Delete.call` with the system auth context.
    #
    # Each batch is processed in its own transaction so a failure does not
    # roll back the work of earlier batches. The scheduler's per-task
    # fault isolation (`Cron::Scheduler#spawn_fire` rescues and reschedules)
    # means a raised exception logs and the task fires again on its next
    # cron tick; this task's own per-batch transactions ensure the rerun
    # resumes from where the failed run left off (already-tombstoned
    # sidecars are no-ops, see `Document::Delete` 410 handling).
    class SidecarReconcile
      Log = ::Log.for("facet.cron.sidecar_reconcile")

      # The maximum number of host ids checked per existence query. Caps
      # the `ANY($3)` array size so the planner stays in the btree index
      # range and the bind payload stays bounded.
      BATCH_SIZE = 1000

      # Runs one reconciliation pass over every sidecar doctype.
      def self.call : Nil
        swept = 0
        Facet::Database.with_db do |db|
          sidecar_doctypes = fetch_sidecar_doctypes(db)
          sidecar_doctypes.each do |sidecar_qualified|
            swept += reconcile_doctype(db, sidecar_qualified)
          end
        end
        if swept > 0
          Log.info { "Sidecar reconcile pass complete: #{swept} orphan(s) tombstoned" }
        end
      rescue ex : Exception
        # The scheduler logs and reschedules; re-raise so the task's own
        # span attributes reflect the failure if telemetry is wired.
        Log.error { "Sidecar reconcile pass failed: #{ex.message}" }
        raise ex
      end

      # ── Private ───────────────────────────────────────────────────────

      # Returns the qualified ids (`{domain}.{Doctype}`) of every sidecar
      # doctype: `core.DocType` projections whose definition carries
      # `sidecar: true`.
      private def self.fetch_sidecar_doctypes(db : DB::Connection) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT id FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType'
              AND deleted_at IS NULL
              AND content->>'sidecar' = 'true'
          SQL
          as: String,
        )
      rescue ex : Exception
        Log.error { "fetch_sidecar_doctypes query failed: #{ex.message}" }
        [] of String
      end

      # Reconciles one sidecar doctype. Reads live sidecar records, groups
      # their `target` references by host doctype, batch-checks host
      # existence, and tombstones orphans. Returns the count of sidecar
      # records tombstoned.
      private def self.reconcile_doctype(db : DB::Connection, sidecar_qualified : String) : Int32
        sidecar_domain, sidecar_doctype = Util::QualifiedRef.split_doctype(sidecar_qualified)
        target_column = target_column_for(db, sidecar_qualified)

        targets = fetch_sidecar_targets(db, sidecar_domain, sidecar_doctype, target_column)
        return 0 if targets.empty?

        # Group host ids by (host_domain, host_doctype) so each group's
        # existence check batches against the right `projections`
        # partition.
        groups = {} of {String, String} => Array(String)
        targets.each do |qualified_target|
          parts = Util::QualifiedRef.split_reference(qualified_target)
          next if parts.nil?
          host_domain, host_doctype, host_id = parts
          (groups[{host_domain, host_doctype}] ||= [] of String) << host_id
        end

        orphan_targets = [] of String
        groups.each do |(host_domain, host_doctype), host_ids|
          orphan_targets.concat(find_orphans(db, host_domain, host_doctype, host_ids))
        end

        return 0 if orphan_targets.empty?

        tombstone_orphans(db, sidecar_domain, sidecar_doctype, target_column, orphan_targets)
      end

      # Returns the reference column name declared on the sidecar doctype
      # (`target` by default). The sidecar definition's validation
      # guarantees exactly one reference field, and the seed's `sidecars`
      # map names the column — read it from the `SidecarRef` shape stored
      # on the host doctypes' `sidecars` map rather than from the sidecar
      # definition itself, because the sidecar definition does not record
      # its owning host.
      #
      # In practice every sidecar uses `target` (the seed and validation
      # default). Fall back to `"target"` when no host declares this
      # sidecar in a `sidecars` map yet (e.g. the sidecar was just
      # published and no host references it).
      private def self.target_column_for(db : DB::Connection, sidecar_qualified : String) : String
        row = db.query_one?(
          <<-SQL,
            SELECT content#>>'{sidecars,segment,column}'
            FROM (
              SELECT content, jsonb_object_keys(content->'sidecars') AS segment
              FROM projections
              WHERE domain = 'core' AND doc_type = 'DocType'
                AND deleted_at IS NULL
                AND jsonb_typeof(content->'sidecars') = 'object'
            ) AS hosts
            WHERE content->'sidecars'->segment->>'doctype' = $1
            LIMIT 1
          SQL
          sidecar_qualified,
          as: String?,
        )
        row || "target"
      rescue ex : Exception
        Log.warn { "target_column_for('#{sidecar_qualified}') failed: #{ex.message}; defaulting to 'target'" }
        "target"
      end

      # Reads the live `target` reference values of every non-deleted
      # sidecar record of the given sidecar doctype.
      private def self.fetch_sidecar_targets(
        db : DB::Connection,
        sidecar_domain : String,
        sidecar_doctype : String,
        target_column : String,
      ) : Array(String)
        # `target_column` is read from the doctype definition's `sidecars`
        # map (validated to `[a-z_][a-z0-9_]*` by `Doctype::Validation`),
        # so it is safe to interpolate as a SQL identifier. Quoted for
        # belt-and-braces.
        db.query_all(
          <<-SQL,
            SELECT content->>$1 AS target FROM projections
            WHERE domain = $2 AND doc_type = $3
              AND deleted_at IS NULL
              AND content->>$1 IS NOT NULL
              AND content->>$1 <> ''
          SQL
          target_column, sidecar_domain, sidecar_doctype,
          as: String,
        )
      end

      # Batch-checks host existence. `host_ids` is split into chunks of
      # `BATCH_SIZE`; each chunk issues one `id = ANY($3)` query against
      # the live host projections. Returns the qualified target references
      # (`{host_domain}.{host_doctype}.{host_id}`) of the hosts that are
      # missing or tombstoned.
      private def self.find_orphans(
        db : DB::Connection,
        host_domain : String,
        host_doctype : String,
        host_ids : Array(String),
      ) : Array(String)
        orphans = [] of String
        host_ids.each_slice(BATCH_SIZE) do |batch|
          live = db.query_all(
            <<-SQL,
              SELECT id FROM projections
              WHERE domain = $1 AND doc_type = $2
                AND id = ANY($3)
                AND deleted_at IS NULL
            SQL
            host_domain, host_doctype, batch,
            as: String,
          )
          live_set = live.to_set
          batch.each do |host_id|
            unless live_set.includes?(host_id)
              orphans << "#{host_domain}.#{host_doctype}.#{host_id}"
            end
          end
        end
        orphans
      end

      # Tombstones every sidecar record whose `target` equals one of the
      # orphaned host ids, through the shared `Sidecars.tombstone_by_target`.
      # Returns the count of sidecar records tombstoned.
      private def self.tombstone_orphans(
        db : DB::Connection,
        sidecar_domain : String,
        sidecar_doctype : String,
        target_column : String,
        orphan_targets : Array(String),
      ) : Int32
        swept = 0
        orphan_targets.each do |orphan_target|
          swept += Sidecars.tombstone_by_target(
            db, "#{sidecar_domain}.#{sidecar_doctype}", target_column, orphan_target,
            actioner_id: "system:sidecar-reconcile",
            label: "Reconcile",
          )
        end

        # Flush the enqueued `deleted` events so they land on the stream.
        # The cron task runs outside the HTTP layer, so the
        # `Publisher.flush` the HTTP layer performs after each request
        # does not cover these tombstone events.
        Facet::Event::Publisher.flush

        swept
      end
    end
  end
end
