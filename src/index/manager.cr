# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "digest/sha256"
require "pg"
require "json"
require "opentelemetry"
require "../doctype"
require "../database"
require "../util/pg_error"

module Facet
  module Index
    # Manages PostgreSQL partial indexes on the `projections` table based on
    # doctype field definitions.
    #
    # ## Lifecycle
    #
    # 1. `sync` is called after a doctype is created or updated.
    # 2. `Index::Planner` computes the desired set of indexes from the field
    #    definitions; `sync` diffs against the `doctype_indexes` table and
    #    inserts/removes rows.
    # 3. Actual DDL (`CREATE INDEX CONCURRENTLY` / `DROP INDEX CONCURRENTLY`)
    #    runs in a background fiber so the HTTP response is not blocked.
    #    Every DDL unit runs under the DDL gate (`with_ddl_gate`), which
    #    serialises managed index DDL across fibers and processes. Two
    #    concurrent CONCURRENTLY statements on one table deadlock against
    #    each other, so they must not overlap.
    #
    # Failed index creations leave the row in `error` status with the error
    # message stored — the doctype mutation is never rolled back. PG deadlock
    # (SQLSTATE 40P01) is retried with backoff while the DDL unit holds the
    # gate; anything else fails the row immediately.
    class Manager
      Log = ::Log.for("facet.index")

      # Session-level advisory-lock key for the DDL gate (see
      # `with_ddl_gate`). Derived from a fixed string so every process
      # (running server, index:retry CLI) computes the same key. PG
      # advisory keys are signed bigint; 15 hex digits (2^60) fit with
      # room to spare and stay positive.
      DDL_LOCK_KEY = Digest::SHA256.hexdigest("facet:index:ddl:gate")[0, 15].to_i64(16)

      # Attempts per DDL statement in the runtime path before the tracking
      # row settles into `error` status. The `index:retry` CLI passes a
      # larger budget explicitly.
      MAX_DDL_ATTEMPTS = 3

      # Backoff bounds for the DDL gate poll loop (see `with_ddl_gate`).
      # The first retry waits `GATE_POLL_MIN`; each failed attempt doubles
      # the wait up to `GATE_POLL_MAX` (2^5 × 25 ms). The poll never
      # blocks in the database, so these bounds only trade CPU for
      # latency while the gate is busy.
      GATE_POLL_MIN = 25.milliseconds
      GATE_POLL_MAX = 800.milliseconds

      # How often a still-busy gate logs a warning, so a wedged holder is
      # visible in the log instead of silently stalling the queue.
      GATE_WARN_EVERY = 30.seconds

      # Refused `pg_try_advisory_lock` attempts since boot — the waiter-side
      # view of a busy gate. A moving counter proves a waiter polled and was
      # turned away (B-46 diagnostics: while polling, no ungranted advisory
      # lock may exist anywhere). Reads are cheap; nothing resets it.
      @@gate_refusals = Atomic(Int32).new(0)

      def self.gate_refusals : Int32
        @@gate_refusals.get
      end

      # Out-standing background DDL fibers (CREATE INDEX CONCURRENTLY /
      # DROP INDEX CONCURRENTLY). Each async `run_batch` call increments
      # this counter; the spawned fiber decrements it in `ensure` when it
      # has finished processing its batch. `Migrate.db_reset` (and tests
      # that need to assert against index state) uses
      # `wait_for_pending_fibers` to drain the queue before closing the
      # singleton pool — otherwise in-flight DDL would hit
      # `DB::ConnectionLost` mid-statement.
      @@pending_fibers = 0
      @@fibers_mutex = Mutex.new

      # When `true`, `sync` runs `CREATE INDEX` / `DROP INDEX` (no
      # `CONCURRENTLY`) inline on a fresh singleton-pool connection
      # instead of spawning a background fiber. The non-concurrent form
      # is significantly faster (single table scan, no waiting for
      # in-flight transactions, no two-phase commit), does not take the
      # SHARE lock that contends with the per-test `TRUNCATE`, and is
      # allowed inside a transaction block.
      #
      # This is the mode the spec suite opts into (see
      # `spec/spec_helper.cr`'s `Spec.before_suite`). It mirrors the
      # pattern used by `Event::Publisher.manager = InProcessManager.new`:
      # swap the production non-blocking infrastructure for an inline
      # equivalent so tests are not penalised for semantics they do not
      # need. The production path (`false`, the default) keeps
      # `CONCURRENTLY` + background fibers so HTTP responses are not
      # blocked by DDL.
      #
      # `Index::Manager.synchronous?` is read by `sync` to choose
      # between the two paths. It MUST be set before any `sync` call
      # (e.g. before `setup_template_database` in `before_suite`); changing
      # it after some `sync` calls have already returned mid-flight fibers
      # is unsupported.
      @@synchronous = false

      # ── Public API ──────────────────────────────────────────────────────

      # Returns the number of background DDL fibers still running. Mainly
      # useful for CLI entry points (`db_reset`) and tests that need to wait
      # for index creation to settle before asserting on `doctype_indexes`
      # state or closing the singleton pool.
      def self.pending_fibers : Int32
        @@fibers_mutex.synchronize { @@pending_fibers }
      end

      # Blocks the calling fiber until every background DDL fiber spawned by
      # `sync` has finished (success or failure), or `timeout` elapses —
      # whichever comes first. Returns `true` if the queue drained, `false`
      # on timeout.
      #
      # This is a cooperative wait — `Fiber.yield` lets the event loop run
      # the spawned fibers and progress their `db.exec` calls. It must be
      # called from the main fiber (or any fiber that is not itself one of
      # the DDL fibers, or it would self-deadlock).
      def self.wait_for_pending_fibers(timeout : Time::Span = 30.seconds) : Bool
        deadline = Time.utc + timeout
        loop do
          return true if pending_fibers.zero?
          return false if Time.utc >= deadline
          Fiber.yield
          sleep 10.milliseconds
        end
      end

      # Set or clear the synchronous mode. See `@@synchronous`.
      def self.synchronous=(value : Bool)
        @@synchronous = value
      end

      # Returns whether `sync` runs DDL inline (true) or in background fibers
      # via `CONCURRENTLY` (false).
      def self.synchronous? : Bool
        @@synchronous
      end

      # Runs `&block` while holding the DDL gate when `concurrent` (the
      # production path); runs the block inline when not — the synchronous
      # test mode involves no `CONCURRENTLY` and no cross-fiber DDL.
      #
      # The gate is a session-level PostgreSQL advisory lock taken on the
      # connection that runs the DDL (each background DDL fiber checks out
      # its own connection, so one session equals one unit of DDL work).
      # It serialises each DDL unit — statement, status update, failure
      # cleanup — across every fiber in this process and across processes
      # (the running server and a concurrent `index:retry` CLI wait for
      # each other). Two `CREATE`/`DROP INDEX CONCURRENTLY` statements on
      # the same table deadlock against each other: their wait-for-lock
      # and wait-for-snapshot phases interlock, and PostgreSQL aborts one
      # with 40P01. Managed DDL must therefore never overlap; ordinary
      # DML on `projections` never conflicts with the gate, so nothing
      # else is blocked — DDL turns from parallel to sequential, which is
      # the point.
      #
      # The lock is acquired by **polling** `pg_try_advisory_lock`, never
      # by blocking on `pg_advisory_lock`. A session blocked on the plain
      # advisory lock sits inside an open (implicit) transaction, and the
      # gate-holder's `CREATE INDEX CONCURRENTLY` snapshot-wait collects
      # concurrent transactions — including that waiter's — and waits for
      # its virtual xid, while the waiter waits for the gate: a deadlock
      # cycle PostgreSQL resolves by killing the queued fiber (observed
      # as B-46: publish returned 200 while the row stayed `pending`
      # forever). A `pg_try_advisory_lock` poll grants or returns false
      # immediately, so a waiter never holds a waiting transaction and
      # cannot be a counterparty in any such cycle. Serialisation is
      # unaffected: only the granted holder runs its DDL unit.
      def self.with_ddl_gate(db : DB::Connection, *, concurrent : Bool = true, & : -> T) : T forall T
        return yield unless concurrent

        acquire_ddl_gate(db)
        begin
          yield
        ensure
          begin
            db.exec("SELECT pg_advisory_unlock($1)", DDL_LOCK_KEY)
          rescue e : DB::Error
            # A dead connection releases its session locks by itself, and
            # the pool discards it. Never mask the protected work's
            # result with an unlock failure.
            Log.warn(exception: e) do
              "Index DDL gate unlock failed: #{e.class}: #{e.message}"
            end
          end
        end
      end

      # Polls `pg_try_advisory_lock` until the gate is granted. The try
      # form never waits inside PostgreSQL: a failed attempt returns
      # false immediately and the implicit transaction of the statement
      # completes at once, so the polling session never holds a waiting
      # transaction — the property that makes the gate deadlock-free
      # (see `with_ddl_gate`). Backoff doubles per failed attempt up to
      # `GATE_POLL_MAX`; a gate busy longer than `GATE_WARN_EVERY` logs a
      # warning so a wedged holder is visible. Runs forever otherwise —
      # a dead holder releases its session locks automatically.
      private def self.acquire_ddl_gate(db : DB::Connection) : Nil
        started = Time.instant
        next_warn = started + GATE_WARN_EVERY
        attempt = 0

        loop do
          granted = db.query_one(
            "SELECT pg_try_advisory_lock($1)",
            DDL_LOCK_KEY,
            as: Bool,
          )
          return if granted

          attempt += 1
          @@gate_refusals.add(1)
          now = Time.instant
          if now >= next_warn
            Log.warn do
              "Index DDL gate busy for #{(now - started).total_seconds.round(1)}s " \
              "(#{attempt} polls) — still waiting"
            end
            next_warn += GATE_WARN_EVERY
          end
          backoff = GATE_POLL_MIN * (2 ** Math.min(attempt - 1, 5))
          backoff = GATE_POLL_MAX if backoff > GATE_POLL_MAX
          sleep backoff
        end
      end

      # Computes the desired indexes for a doctype definition, diffs against
      # the current state in the `doctype_indexes` table, and spawns fibers
      # to execute the actual DDL.
      #
      # This method is safe to call multiple times — it's idempotent:
      # duplicate `DesiredIndex` entries are prevented by the UNIQUE constraint.
      #
      # DDL execution depends on `synchronous?`:
      # * `false` (default — production): the batch runs `CREATE INDEX
      #   CONCURRENTLY` / `DROP INDEX CONCURRENTLY` in a background fiber
      #   (`run_batch` with `async: true`) so the HTTP response is not
      #   blocked.
      # * `true` (test mode): the batch runs plain `CREATE INDEX` /
      #   `DROP INDEX` on a fresh singleton-pool connection on the caller's
      #   stack (`async: false`). See `@@synchronous`.
      def self.sync(db : DB::Connection, definition : Doctype::DoctypeDefinition) : Nil
        Facet::Telemetry.trace "index.sync" do |span|
          span["domain"] = definition.domain
          span["doc_type"] = definition.doctype
          desired = Planner.compute_desired(definition)
          current = fetch_current(db, definition.domain, definition.doctype)

          to_remove = current - desired
          to_add = desired - current

          span["to_add"] = to_add.size.to_s
          span["to_remove"] = to_remove.size.to_s
          span["synchronous"] = synchronous?.to_s

          unless to_remove.empty?
            run_batch(BatchKind::Remove, definition.domain, definition.doctype, to_remove,
              concurrent: !synchronous?, async: !synchronous?, remaining: desired)
          end

          unless to_add.empty?
            insert_pending(db, to_add)
            run_batch(BatchKind::Create, definition.domain, definition.doctype, to_add,
              concurrent: !synchronous?, async: !synchronous?)
          end
        end
      end

      # ── Current state queries ──────────────────────────────────────────

      # Fetches all non-dropped index records for a given domain/doctype.
      private def self.fetch_current(
        db : DB::Connection,
        domain : String,
        doc_type : String,
      ) : Set(DesiredIndex)
        result = Set(DesiredIndex).new

        rows = db.query_all(
          <<-SQL,
            SELECT field_name, index_type
            FROM doctype_indexes
            WHERE domain = $1 AND doc_type = $2 AND status IN ('pending', 'active', 'error')
          SQL
          domain, doc_type,
          as: {String, String}
        )

        rows.each do |field_name, index_type|
          result << DesiredIndex.new(domain, doc_type, field_name, index_type)
        end

        result
      end

      # Inserts pending rows for new desired indexes.
      # Uses ON CONFLICT DO NOTHING to handle race conditions.
      private def self.insert_pending(
        db : DB::Connection,
        to_add : Set(DesiredIndex),
      ) : Nil
        to_add.each do |idx|
          index_name = Naming.index_name(idx.domain, idx.doc_type, idx.field_name, idx.index_type)
          db.exec(
            <<-SQL,
              INSERT INTO doctype_indexes (domain, doc_type, field_name, index_type, index_name, status)
              VALUES ($1, $2, $3, $4, $5, 'pending')
              ON CONFLICT (domain, doc_type, field_name, index_type) DO NOTHING
            SQL
            idx.domain, idx.doc_type, idx.field_name, idx.index_type, index_name
          )
        end
      end

      # ── DDL execution (background fibers) ──────────────────────────────
      # ── DDL execution (batch executors) ──────────────────────

      # Selects create vs. drop for `run_batch`.
      enum BatchKind
        Create
        Remove
      end

      # Runs the per-index DDL batch for one doctype — the shared body of
      # the spawn/inline, create/remove executor quartet.
      #
      # `concurrent` selects the `CONCURRENTLY` DDL form; `async` wraps the
      # batch in `track_fiber`, so a background fiber owns the whole
      # per-doctype loop and the HTTP response is not blocked by DDL. The
      # inline form (`async: false`) runs on the caller's stack — the spec
      # suite's synchronous mode opts into it to avoid both the SHARE-lock
      # contention against `TRUNCATE` and the background-fiber lifecycle
      # overhead.
      #
      # Each index runs under the DDL gate (see `with_ddl_gate`): managed
      # index DDL on `projections` is serialised, because two `CREATE INDEX
      # CONCURRENTLY` statements on one table deadlock against each other —
      # not only against the per-test `TRUNCATE` of the spec suite. When a
      # draft or publish copies a whole domain, one fiber per doctype used
      # to race; only the gate ordering makes the multi-doctype template
      # creation safe. Deadlock from an outside party is retried with
      # backoff inside `exec_ddl_with_deadlock_retry` before the row
      # settles into `error` status, where the `facet index:retry` command
      # picks it up.
      private def self.run_batch(
        kind : BatchKind,
        domain : String,
        doc_type : String,
        indexes : Set(DesiredIndex),
        *,
        concurrent : Bool,
        async : Bool,
        remaining : Set(DesiredIndex) = Set(DesiredIndex).new,
      ) : Nil
        if async
          track_fiber { run_batch_once(kind, domain, doc_type, indexes, concurrent, async, remaining) }
        else
          run_batch_once(kind, domain, doc_type, indexes, concurrent, async, remaining)
        end
      end

      # The batch body: one pooled connection, one per-index loop, and a
      # logging rescue. The rescue covers the cases where the fiber could
      # not even acquire a connection, or the per-index loop raised
      # before / between iterations (pool closed, "Database not
      # initialized", a poisoned connection). None of the pending rows for
      # this doctype will have been touched — they remain in `pending`
      # status for a later `index:retry` run. The inline variant has the
      # same semantics: the doctype create itself (the HTTP /
      # `with_transaction` that preceded this call) is NOT rolled back —
      # failures surface as an `error` row that `index:retry` re-attempts.
      private def self.run_batch_once(
        kind : BatchKind,
        domain : String,
        doc_type : String,
        indexes : Set(DesiredIndex),
        concurrent : Bool,
        async : Bool,
        remaining : Set(DesiredIndex) = Set(DesiredIndex).new,
      ) : Nil
        begin
          Database.with_db(:read_write) do |db|
            indexes.each do |idx|
              case kind
              in BatchKind::Create
                create_one_index(db, idx, concurrent: concurrent)
              in BatchKind::Remove
                drop_one_index(db, idx, concurrent: concurrent, remaining: remaining)
              end
            end
          end
        rescue ex
          mode = async ? "fiber" : "inline"
          verb = kind.create? ? "creation" : "removal"
          Log.error(exception: ex) do
            "Index #{verb} #{mode} failed for #{domain}.#{doc_type} " \
            "before completing (#{indexes.size} pending): #{ex.class}: #{ex.message || "(no message)"}"
          end
        end
      end

      # Runs one `CREATE INDEX` (concurrent or not, per the `concurrent`
      # flag) against `db`, then updates `doctype_indexes` to `active` or
      # `error` accordingly. Best-effort `DROP INDEX` cleanup runs on
      # failure so PG does not keep an INVALID index around.
      #
      # Shared by the async create batch (`concurrent: true`) and the
      # inline create batch (`concurrent: false`) through `run_batch`.
      private def self.create_one_index(
        db : DB::Connection,
        idx : DesiredIndex,
        *,
        concurrent : Bool,
      ) : Nil
        index_name = Naming.index_name(idx.domain, idx.doc_type, idx.field_name, idx.index_type)
        sql = Naming.create_index_sql(idx.domain, idx.doc_type, idx.field_name, idx.index_type, concurrent: concurrent)
        drop_sql = Naming.drop_index_sql(idx.domain, idx.doc_type, idx.field_name, idx.index_type, concurrent: concurrent)

        begin
          with_ddl_gate(db, concurrent: concurrent) do
            begin
              exec_ddl_with_deadlock_retry(db, sql, drop_sql)
              create_field_statistics(db, idx)
              db.exec(
                "UPDATE doctype_indexes SET status = 'active', updated_at = now() WHERE index_name = $1",
                index_name
              )
            rescue ex
              # Best-effort cleanup of any partial / invalid index that
              # PostgreSQL may have left behind from the failed CREATE.
              # Bare `rescue` is intentional: we must not mask the
              # original CREATE failure with a DROP failure.
              begin
                exec_ddl_with_deadlock_retry(db, drop_sql)
              rescue e
                Log.warn(exception: e) do
                  "Best-effort DROP INDEX cleanup failed for #{idx.domain}.#{idx.doc_type}.#{idx.field_name} (#{idx.index_type}): #{e.class}: #{e.message}"
                end
              end

              record_create_failure(db, idx, index_name, sql, ex)
            end
          end
        rescue ex
          # The gate acquisition itself failed (a dead connection is the
          # realistic case). The row must not stay `pending` behind a
          # successful caller — mark it failed like any other create
          # error. When the connection is dead the marking UPDATE raises
          # too; the batch rescue logs it and `index:retry` recovers the
          # stale row later.
          record_create_failure(db, idx, index_name, sql, ex, stage: "gate acquisition")
        end
      end

      # Persists a failed create attempt: logs a class-qualified message
      # and marks the tracking row `error`. `stage` distinguishes the DDL
      # statement itself from the DDL-gate acquisition around it. Raises
      # through when the connection is dead — the batch rescue logs that,
      # and `index:retry` recovers the row from `pending` later.
      private def self.record_create_failure(
        db : DB::Connection,
        idx : DesiredIndex,
        index_name : String,
        sql : String,
        ex : Exception,
        *,
        stage : String = "ddl",
      ) : Nil
        error_message = "#{ex.class}: #{ex.message || "(no message)"}"

        Log.error(exception: ex) do
          "Index creation failed for #{idx.domain}.#{idx.doc_type}.#{idx.field_name} " \
          "(#{idx.index_type}, index_name=#{index_name}, stage=#{stage}): #{error_message} | SQL: #{sql}"
        end

        db.exec(
          "UPDATE doctype_indexes SET status = 'error', error_message = $1, updated_at = now() WHERE index_name = $2",
          error_message,
          index_name
        )
      end

      # Creates the field's extended statistics object, if the index type
      # has one (see `Naming.create_statistics_sql`). Best effort: the
      # index is the contract, and the statistics object only steers the
      # planner towards it, so a failure logs and leaves the index active.
      #
      # The object is created under the same DDL gate and with the same
      # concurrency as the index. `CREATE STATISTICS` has no
      # `CONCURRENTLY` form, so it takes the same `SHARE UPDATE EXCLUSIVE`
      # lock a plain `CREATE INDEX` does — writes keep flowing. A newly
      # created object has no collected data until the next `ANALYZE` on
      # `projections` (autovacuum reaches the table, or an operator runs
      # `ANALYZE projections` after a bulk load).
      private def self.create_field_statistics(
        db : DB::Connection,
        idx : DesiredIndex,
      ) : Nil
        sql = Naming.create_statistics_sql(idx.domain, idx.doc_type, idx.field_name, idx.index_type)
        return if sql.nil?

        exec_ddl_with_deadlock_retry(db, sql)
      rescue ex
        Log.warn(exception: ex) do
          "Statistics creation failed for #{idx.domain}.#{idx.doc_type}.#{idx.field_name} " \
          "(#{idx.index_type}): #{ex.class}: #{ex.message || "(no message)"}"
        end
      end

      # Drops the field's statistics object. The object is shared by every
      # btree variant of a field, so it goes only when no remaining
      # desired index for that field needs it. Best effort, like the
      # create path.
      private def self.drop_field_statistics(
        db : DB::Connection,
        idx : DesiredIndex,
        remaining : Set(DesiredIndex),
      ) : Nil
        still_needed = remaining.any? do |other|
          other.field_name == idx.field_name &&
            !Naming.create_statistics_sql(other.domain, other.doc_type, other.field_name, other.index_type).nil?
        end
        return if still_needed
        return if Naming.create_statistics_sql(idx.domain, idx.doc_type, idx.field_name, idx.index_type).nil?

        exec_ddl_with_deadlock_retry(db, Naming.drop_statistics_sql(idx.domain, idx.doc_type, idx.field_name))
      rescue ex
        Log.warn(exception: ex) do
          "Statistics removal failed for #{idx.domain}.#{idx.doc_type}.#{idx.field_name} " \
          "(#{idx.index_type}): #{ex.class}: #{ex.message || "(no message)"}"
        end
      end

      # Runs one DDL statement with a bounded retry on PG deadlock
      # (SQLSTATE 40P01). `CREATE INDEX CONCURRENTLY` cannot run inside a
      # transaction block (it manages its own internal transactions), so
      # we simply re-issue the statement after an exponential backoff.
      #
      # When *drop_sql* is given, it runs between attempts: a failed
      # CREATE CONCURRENTLY already committed its phase-one catalog row,
      # so a half-built index with the target name exists, and the next
      # `CREATE INDEX CONCURRENTLY IF NOT EXISTS` would match that
      # leftover by name and silently keep an INVALID index while the
      # tracking row turns `active`.
      #
      # The caller serialises against sibling DDL — the runtime path and
      # the `index:retry` CLI wrap this in `with_ddl_gate`. Used by
      # `create_one_index` / `drop_one_index` and by `index:retry`, which
      # passes a larger attempt budget.
      def self.exec_ddl_with_deadlock_retry(
        db : DB::Connection,
        sql : String,
        drop_sql : String? = nil,
        max_attempts : Int = MAX_DDL_ATTEMPTS,
      ) : Nil
        attempts = 0
        loop do
          db.exec(sql)
          return
        rescue ex : PQ::PQError
          # SQLSTATE lives in the field tagged `:code`. 40P01 = deadlock_detected.
          raise ex unless deadlock_detected?(ex)
          attempts += 1
          db.exec(drop_sql) if drop_sql
          raise ex if attempts >= max_attempts
          sleep 25.milliseconds * (2 ** (attempts - 1))
        end
      end

      # True when the PG error is a detected deadlock (SQLSTATE 40P01).
      private def self.deadlock_detected?(ex : PQ::PQError) : Bool
        Util::PgError.sqlstate(ex) == "40P01"
      end

      # Runs one `DROP INDEX` (concurrent or not, per the `concurrent` flag)
      # against `db`, then updates `doctype_indexes` to `dropped`. On
      # failure the row is still marked `dropped` (a leftover PG index may
      # need manual cleanup) with an `error_message` for visibility. The
      # field's statistics object goes with the last btree variant of the
      # field (see `drop_field_statistics`).
      #
      # Shared by the async remove batch (`concurrent: true`) and the
      # inline remove batch (`concurrent: false`) through `run_batch`.
      private def self.drop_one_index(
        db : DB::Connection,
        idx : DesiredIndex,
        *,
        concurrent : Bool,
        remaining : Set(DesiredIndex) = Set(DesiredIndex).new,
      ) : Nil
        index_name = Naming.index_name(idx.domain, idx.doc_type, idx.field_name, idx.index_type)
        sql = Naming.drop_index_sql(idx.domain, idx.doc_type, idx.field_name, idx.index_type, concurrent: concurrent)

        begin
          with_ddl_gate(db, concurrent: concurrent) do
            begin
              exec_ddl_with_deadlock_retry(db, sql)
              drop_field_statistics(db, idx, remaining)
              db.exec(
                "UPDATE doctype_indexes SET status = 'dropped', updated_at = now() WHERE index_name = $1",
                index_name
              )
            rescue ex
              record_drop_failure(db, idx, index_name, sql, ex)
            end
          end
        rescue ex
          # Gate acquisition failed — same contract as a failed DROP: the
          # row is still marked `dropped` so future syncs are not blocked,
          # with the message stored for the operator.
          record_drop_failure(db, idx, index_name, sql, ex, stage: "gate acquisition")
        end
      end

      # Persists a failed removal attempt. The row is always marked
      # `dropped` (a leftover PG index may need manual cleanup) so future
      # syncs are not blocked; the class-qualified message is stored for
      # the operator. Raises through when the connection is dead.
      private def self.record_drop_failure(
        db : DB::Connection,
        idx : DesiredIndex,
        index_name : String,
        sql : String,
        ex : Exception,
        *,
        stage : String = "ddl",
      ) : Nil
        error_message = "#{ex.class}: #{ex.message || "(no message)"}"

        Log.error(exception: ex) do
          "Index removal failed for #{idx.domain}.#{idx.doc_type}.#{idx.field_name} " \
          "(#{idx.index_type}, index_name=#{index_name}, stage=#{stage}): #{error_message} | SQL: #{sql}"
        end

        db.exec(
          "UPDATE doctype_indexes SET status = 'dropped', error_message = $1, updated_at = now() WHERE index_name = $2",
          error_message,
          index_name
        )
      end

      # Wraps `spawn` so the global pending-fiber counter is decremented
      # when the spawned fiber finishes (success or failure). Increments
      # *before* `spawn` is called so a `wait_for_pending_fibers` call
      # issued immediately after an async `run_batch` sees the fiber as
      # pending even before the scheduler has run it.
      private def self.track_fiber(&block : -> Nil) : Nil
        @@fibers_mutex.synchronize { @@pending_fibers += 1 }
        spawn do
          begin
            block.call
          ensure
            @@fibers_mutex.synchronize { @@pending_fibers -= 1 }
          end
        end
      end
    end
  end
end
