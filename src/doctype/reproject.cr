# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../database"
require "../mutation/client"
require "../doctype/definition_store"
require "../doctype/doctype_definition"
require "../document/projection_gucs"
require "../document/snapshot_persist"
require "../document/migrate"
require "../error"
require "opentelemetry"

module Facet
  module Doctype
    # Re-projects the derived columns (`search`, `links`, `display_name`)
    # for every live document of a doctype.
    #
    # ## Why this exists
    #
    # The `projections.search` / `links` / `display_name` columns are computed
    # by the PL/pgSQL mutation trigger from the doctype's `search:`,
    # `links:`, and `display_name:` definitions (staged as transaction-local
    # GUCs by `Document::ProjectionGucs.set_all`). When an operator changes
    # one of these definitions on a doctype that already has live documents,
    # the existing rows keep the *old* derived state until the next mutation
    # lands on each of them. This service back-fills the derived columns for
    # every live document in one streaming pass.
    #
    # ## How it works
    #
    # The re-projection is content-preserving: for each document, it writes
    # a `snapshot` mutation whose payload is the *current* `projections.content`
    # (read under a row lock), with the search/links/display_name GUCs re-staged
    # from the current doctype definition. The trigger (`projection_from_snapshot`,
    # migration `0004`) recomputes the three derived columns from the GUC paths
    # and lands them on the projection. `projections.content` is left unchanged.
    #
    # This mirrors `Document::Migrate` and `Audit::Rollback.persist_snapshot`,
    # which use the same primitive for the same reason.
    #
    # ## Concurrency model
    #
    # A single producer fiber streams `(id, state)` pairs from `projections`
    # via a keyset cursor on `id` (ULID — monotonic, primary key). Each pair
    # is pushed onto a bounded channel. A pool of worker fibers pulls jobs,
    # and for each one:
    #
    #   1. Opens a per-row transaction.
    #   2. `SELECT ... FOR UPDATE` locks the row (row lock, NOT a table lock).
    #   3. Verifies `projections.state == job.state` — if a mutation landed
    #      between enqueue and run, that mutation already re-projected the
    #      row, so the job is discarded as superseded.
    #   4. Skips tombstoned rows and rows marked with `meta.migration_error`
    #      (mirrors `Document::Migrate.migration_blocked?`).
    #   5. Stages the GUCs from the locked content and inserts a `snapshot`
    #      mutation. The trigger recomputes the derived columns.
    #
    # Because each job is its own short transaction, one bad row never rolls
    # back the others. Concurrent writers to *other* rows are never blocked;
    # a concurrent writer to the *same* row is held only for the snapshot
    # mutation's duration, and if it lands first, our job is skipped.
    module Reproject
      Actioner = "system:reproject"
      Cause    = Mutation::Cause.root(Mutation::CauseKind::Migration, name: "reprojected")

      # Default tuning. Exposed as constants so the CLI and specs can reason
      # about them without hard-coding duplicates.
      DEFAULT_BATCH_SIZE  = 100
      DEFAULT_WORKERS     =   5
      DEFAULT_CHANNEL_CAP =  25

      # A unit of work pulled from the channel by a worker.
      #
      # `state` is the optimistic-lock token: the `projections.state` ULID
      # captured at enqueue time. The worker re-checks it under `FOR UPDATE`
      # and skips the job if it changed (a concurrent mutation already
      # re-projected the row).
      record Job,
        domain : String,
        doc_type : String,
        id : String,
        state : String

      # Streaming results counters. Atomics so the producer and workers can
      # update them without a mutex.
      class Stats
        property processed : Atomic(Int32) = Atomic(Int32).new(0)
        property superseded : Atomic(Int32) = Atomic(Int32).new(0)
        property skipped : Atomic(Int32) = Atomic(Int32).new(0)
        property failed : Atomic(Int32) = Atomic(Int32).new(0)
        property failed_ids : Array(String) = [] of String

        def add_processed! : Nil
          processed.add(1)
        end

        def add_superseded! : Nil
          superseded.add(1)
        end

        def add_skipped! : Nil
          skipped.add(1)
        end

        def add_failed!(id : String) : Nil
          failed.add(1)
          failed_ids << id
        end
      end

      record Result,
        stats : Stats,
        total : Int32

      # Re-projects every live document of *qualified_doctype*.
      #
      # Streams rows via a keyset cursor (no full-table load), pushes
      # `(id, state)` jobs onto a bounded channel, and runs *workers*
      # consumer fibers in parallel. Each job runs in its own short
      # transaction.
      #
      # Returns `Result` on success or `ServiceError` if the doctype cannot
      # be resolved or `qualified_doctype` is malformed.
      #
      # The caller must have already called `Database.init` with a pool sized
      # for at least `workers + 1` connections (see `ReprojectCLI`).
      def self.call(
        db : DB::Connection,
        qualified_doctype : String,
        *,
        batch_size : Int32 = DEFAULT_BATCH_SIZE,
        workers : Int32 = DEFAULT_WORKERS,
        channel_cap : Int32 = DEFAULT_CHANNEL_CAP,
        limit : Int32? = nil,
        &progress : Result -> Nil
      ) : Result | Facet::ServiceError
        Facet::Telemetry.trace "doctype.reproject" do |span|
          span["qualified_doctype"] = qualified_doctype
          span["workers"] = workers.to_s
          span["batch_size"] = batch_size.to_s

          dot = qualified_doctype.index('.')
          return Facet::ServiceError.new(400, "Invalid qualified doctype '#{qualified_doctype}' (expected 'domain.Doctype')") unless dot && dot > 0
          domain = qualified_doctype[0...dot]
          doc_type = qualified_doctype[(dot + 1)..]

          # Fetch the definition once and share it with every worker.
          # `DefinitionStore.fetch` returns nil when the doctype is missing or
          # deleted, or when the stored definition is corrupt. Without a
          # definition we cannot know which field paths to stage — fail loudly
          # rather than clearing every row's search column.
          defn = Doctype::DefinitionStore.fetch(db, qualified_doctype)
          return Facet::ServiceError.new(404, "Doctype #{qualified_doctype} not found") unless defn

          total = count_live(db, domain, doc_type)
          span["total"] = total.to_s
          stats = Stats.new

          channel = Channel(Job).new(channel_cap)

          # Producer fiber: streams (id, state) from the keyset cursor onto
          # the channel. Closes the channel when the cursor is exhausted so
          # workers exit cleanly.
          #
          # The producer checks out its own pooled connection (it cannot
          # share the caller's — the fiber pin slots are fiber-local,
          # and using one PG connection from two fibers is unsafe).
          producer_done = Channel(Nil).new
          spawn(name: "reproject-producer") do
            begin
              Database.with_db(:read_write) do |producer_db|
                produce(producer_db, domain, doc_type, batch_size, limit, channel)
              end
            ensure
              channel.close
              producer_done.close
            end
          end

          # Worker fibers: each pulls jobs until the channel closes. A
          # per-worker done-channel lets the main fiber wait for completion —
          # Crystal's `Fiber` does not expose `wait` directly.
          worker_done = (1..workers).map do
            done = Channel(Nil).new
            spawn(name: "reproject-worker") do
              begin
                consume(defn, channel, stats)
              ensure
                done.close
              end
            end
            done
          end

          # Wait for the producer to drain the cursor, then for every worker
          # to finish its remaining jobs. `receive?` returns nil when a channel
          # is closed (without raising the way `receive` does).
          producer_done.receive?
          worker_done.each(&.receive?)

          result = Result.new(stats, total)
          progress.try(&.call(result))
          result
        end
      end

      # ── Producer ────────────────────────────────────────────────────────

      # Streams `(id, state)` pairs from `projections` via a keyset cursor on
      # `id` (the primary key, a ULID — naturally monotonic). Each pair is
      # pushed onto *channel*; `channel.send` blocks when bounded, giving
      # the workers natural backpressure.
      #
      # Only live (non-tombstoned) rows are emitted. Tombstones carry no
      # `search` corpus (cleared on delete by `projection_from_delete`), so
      # there is nothing to re-project.
      #
      # The `stats` block parameter is accepted for symmetry with the worker
      # side but unused here — the producer does not modify counters.
      private def self.produce(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        batch_size : Int32,
        limit : Int32?,
        channel : Channel(Job),
      ) : Nil
        cursor = ""
        emitted = 0

        loop do
          rows = db.query_all(<<-SQL, domain, doc_type, cursor, batch_size, as: {String, String})
            SELECT id, state
            FROM projections
            WHERE domain = $1 AND doc_type = $2
              AND deleted_at IS NULL
              AND id > $3
            ORDER BY id ASC
            LIMIT $4
          SQL

          break if rows.empty?

          rows.each do |(id, state)|
            channel.send(Job.new(domain: domain, doc_type: doc_type, id: id, state: state))
            emitted += 1
            return if limit && emitted >= limit
          end

          cursor = rows.last[0]

          # Short-circuit when the last page was partial — avoids one extra
          # round-trip that would return zero rows.
          break if rows.size < batch_size
        end
      end

      # ── Consumer ────────────────────────────────────────────────────────

      # Pulls jobs from *channel* until it closes, running each in its own
      # short transaction. A per-job rescue keeps one failure from aborting
      # the run.
      private def self.consume(
        defn : DoctypeDefinition,
        channel : Channel(Job),
        stats : Stats,
      ) : Nil
        while job = channel.receive?
          begin
            process_one(job, defn, stats)
          rescue ex
            # One row failed (DB error, bad UTF-8, etc.). Log and move on —
            # the run completes with the remaining rows intact. A second
            # run will retry just this one (its state is unchanged).
            Log.error(exception: ex) do
              "Reproject worker failed on #{job.domain}.#{job.doc_type}.#{job.id}: #{ex.class}: #{ex.message || "(no message)"}"
            end
            stats.add_failed!(job.id)
          end
        end
      end

      # Processes a single job: lock, verify state, stage GUCs, write a
      # content-preserving snapshot mutation. The snapshot trigger
      # (`projection_from_snapshot`) recomputes `search`/`links`/
      # `display_name` from the GUC-supplied paths.
      private def self.process_one(job : Job, defn : DoctypeDefinition, stats : Stats) : Nil
        Database.with_transaction(:read_write) do |txn|
          # 1. Lock the row and read its current state under the lock.
          #    `SELECT ... FOR UPDATE` is a row lock held until COMMIT — it
          #    does NOT block other rows or other doctypes. The lock + verify
          #    + write must run in one transaction because the GUCs are
          #    transaction-local.
          row = txn.query_one?(<<-SQL, job.domain, job.doc_type, job.id, as: {JSON::Any, JSON::Any, Int32, Time, String, Time?})
            SELECT content, meta, version, created_at, state, deleted_at
            FROM projections
            WHERE domain = $1 AND doc_type = $2 AND id = $3
            FOR UPDATE
          SQL

          # Row vanished between enqueue and run (hard delete of the
          # projection row). Nothing to do.
          unless row
            stats.add_superseded!
            next
          end

          content, meta, version, created_at, current_state, deleted_at = row

          # 2. Skip tombstones. `projection_from_delete` clears the search
          #    corpus on delete; re-projecting would resurrect the row via
          #    `projection_from_snapshot`'s `deleted_at = NULL` path.
          if deleted_at
            stats.add_superseded!
            next
          end

          # 3. Optimistic-lock check. If `state` changed between enqueue and
          #    the `FOR UPDATE`, a concurrent mutation landed — and that
          #    mutation already re-staged the GUCs from its own (current)
          #    content. Our work is redundant; skip.
          if current_state != job.state
            stats.add_superseded!
            next
          end

          # 4. Respect the `migration_error` marker. Mirror
          #    `Document::Migrate.migration_blocked?`: a row marked with a
          #    prior migration failure is left alone so the operator can
          #    investigate without an automated tool mutating it further.
          #    Content-preserving re-projection is arguably safe here, but
          #    the marker's contract is "do not auto-touch."
          if Document::Migrate.migration_blocked?(Mutation::Client::Projection.new(
               domain: job.domain, doc_type: job.doc_type, id: job.id,
               content: content, version: version, links: JSON::Any.new([] of JSON::Any),
               meta: meta, state: current_state, display_name: nil,
               deleted_at: nil, updated_at: Time.utc, created_at: created_at
             ))
            stats.add_skipped!
            next
          end

          # 5. Stage GUCs from the (now-locked) current content and insert
          #    the snapshot mutation via the shared persist primitive. The
          #    trigger recomputes the derived columns. `content` is supplied
          #    verbatim — content-preserving.
          Document.persist_snapshot_mutation(
            txn, job.domain, job.doc_type, job.id,
            content: content, meta: meta,
            actioner_id: Actioner,
            cause: Cause,
            definition: defn,
            version: version,
            created_at: created_at.to_rfc3339,
          )

          stats.add_processed!
        end
      end

      # ── Helpers ─────────────────────────────────────────────────────────

      # Counts live (non-tombstoned) projection rows for *domain*.*doc_type*.
      # Used only for progress reporting; the producer never relies on it for
      # paging (it uses a keyset cursor on `id`).
      private def self.count_live(db : DB::Connection, domain : String, doc_type : String) : Int32
        db.query_one(
          "SELECT count(*) FROM projections WHERE domain = $1 AND doc_type = $2 AND deleted_at IS NULL",
          domain, doc_type,
          as: Int64
        ).to_i32
      end

      Log = ::Log.for("facet.doctype.reproject")
    end
  end
end
