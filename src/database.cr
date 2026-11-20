# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "opentelemetry"
require "./fiber_state"
require "./database/cluster_config"
require "./metrics"
require "./error"
require "./event/publisher"

module Facet
  # Centralised database connection management.
  #
  # Provides the connection pools (`init` / `close`) and three access
  # patterns: `with_connection` for a pinned pooled connection,
  # `with_db` as its read-path alias, and `with_transaction` for atomic
  # operations on top of a pinned connection.
  #
  # ## Modes and the route table
  #
  # Every entry point names its mode explicitly: `with_db(:read_only)` for
  # read-shaped paths, `with_db(:read_write)` (the default) for writes.
  # A `Mode` is an enum — no symbol overloads, a typo fails to compile.
  #
  # `init` builds the route table from the optional `database.cluster`
  # config: one entry per physical database, each holding the resources
  # (domain ids, `$tags`, or `*`) it serves. Resolution is a function of
  # the resource alone: the resource picks the entry, the mode picks the
  # pool inside it — the `replica:` pool when defined, else an enforced
  # pool at the primary URL (`SET default_transaction_read_only = on`).
  # An absent `cluster:` section gives one unnamed database from
  # `DATABASE_URL`, no separate ro pool, no enforcement — the back-compat
  # shape. Entries that share a URL keep separate pools.
  #
  # ## Fiber-local connection pinning
  #
  # `with_connection` checks out a connection from the resolved pool and
  # pins it to the current fiber — one slot per mode (`Fiber#db_ro` /
  # `Fiber#db_rw`). The reuse contract:
  #
  # | State on the fiber | Requested | Result |
  # | --- | --- | --- |
  # | no pins | `ro` | check out from the resolved route pool, pin ro |
  # | no pins | `rw` | check out from the resolved route pool, pin rw |
  # | `ro` pinned | `ro` | reuse the ro pin |
  # | `ro` pinned | `rw` | check out from the rw route pool, pin rw |
  # | `rw` pinned | `ro` | reuse the rw pin — no checkout |
  # | `rw` pinned | `rw` | reuse the rw pin |
  #
  # On block exit a frame releases only a pin it checked out itself; the
  # other slot stays pinned for the outer frame. The resource label is
  # consulted only at checkout — a reused pin ignores the inner resource
  # label, so a request never hops hosts mid-scope.
  #
  # This is what makes transactions actually atomic: `BEGIN`, the `INSERT`,
  # and the `SELECT` that follows all run on the same backend connection,
  # so the read sees the uncommitted write.
  #
  # Background fibers (e.g. the DDL fibers spawned by `Index::Manager.sync`)
  # start with empty slots and check out their own connections, so they
  # never interfere with the request fiber's pins.
  #
  # ## Transaction nesting
  #
  # `with_transaction` uses PG savepoints when called inside an existing
  # transaction block on the same connection (per-connection depth in
  # `Fiber#txn_depths` — two pins can hold two connections on one fiber,
  # and the explicit `with_transaction(db)` form can receive a raw,
  # unpinned connection). Nested calls roll back to the savepoint rather
  # than aborting the outer transaction.
  #
  # ## Session hooks
  #
  # Session settings go through connection hooks, never through URL
  # `options` (crystal-pg 0.30 silently drops that parameter). Hook order
  # on every pool: UTC pin → statement timeout → per-pool extras
  # (read-only enforcement on ro pools) → the shared list registered via
  # `setup_connection`.
  #
  # ## Singleton lifecycle
  #
  # Call `Database.init` once at startup to open the pools; call
  # `Database.close` on shutdown to close every pool.
  module Database
    enum Mode
      ReadOnly
      ReadWrite
    end

    # ── Route table and pools ────────────────────────────────────────────

    # One pool of the route table: the pooled connections plus the
    # per-pool hooks (UTC pin, statement timeout, read-only enforcement).
    # `setup_connection` re-composes these with the shared hook list on
    # every registration.
    private record PoolSlot,
      pool : DB::Database,
      database : String,
      role : String,
      hooks : Array(Proc(DB::Connection, Nil))

    # One configured database entry: the pools that serve it and the
    # resources it holds. `read_only` is the ro pool (the `replica:` pool
    # when defined, else an enforced pool at the primary URL); `nil` only
    # in the back-compat single-pool shape, where ro requests share the
    # primary pool.
    private record Entry,
      name : String,
      primary : PoolSlot,
      read_only : PoolSlot?,
      resources : Array(String)

    @@entries : Array(Entry) = [] of Entry
    @@pool_slots : Array(PoolSlot) = [] of PoolSlot

    # Per-connection hooks, run in registration order on every pooled
    # connection of every pool — existing and future. crystal-db's
    # `DB::Database#setup_connection` holds a single proc, so registering
    # through it directly would silently drop earlier hooks. Keeping the
    # list here lets independently registered hooks (the statement timeout
    # from `init`, session tuning from callers) compose instead of
    # overwrite each other. Cleared by `init` so a re-initialized set of
    # pools starts with only the hooks its caller installs.
    @@connection_hooks = [] of Proc(DB::Connection, Nil)

    # Statement timeout (ms) installed by the last `init` call. `nil` means
    # no timeout was requested — the PG default stays in force.
    @@statement_timeout_ms : Int32? = nil

    # Returns the statement timeout (ms) carried by the pools, or `nil`
    # when `init` ran without one.
    def self.statement_timeout_ms : Int32?
      @@statement_timeout_ms
    end

    # Opens the connection pools from the given cluster config, or — when
    # `cluster` is nil — the back-compat single pool from `DATABASE_URL`.
    # Closes any existing pools first. Safe to call multiple times (e.g.
    # after a test worker provisions a new database).
    #
    # Every pool pins the PostgreSQL session `TimeZone` to UTC through a
    # connection hook (`SET TimeZone = 'UTC'`) — session settings never
    # travel through the URL `options` parameter, which crystal-pg drops
    # silently. The codebase stores UTC in every tz-naive `timestamp`
    # column; without an explicit session TimeZone this would rely on the
    # server/role default, which is fragile.
    #
    # When `statement_timeout_ms` is given, every pooled connection of
    # every pool runs `SET statement_timeout = N`. CLI entry points call
    # `init` without a timeout so long migration DDL and reproject workers
    # cannot be cancelled.
    def self.init(cluster : ClusterConfig? = nil, statement_timeout_ms : Int32? = nil) : Nil
      if cluster
        init_cluster(cluster, statement_timeout_ms)
      else
        init(url_from_env, statement_timeout_ms)
      end
    end

    # Opens the back-compat single pool at *url* (no separate ro pool, no
    # read-only enforcement). CLI entry points and the absent-`cluster:`
    # path.
    def self.init(url : String, statement_timeout_ms : Int32? = nil) : Nil
      close
      @@statement_timeout_ms = statement_timeout_ms
      @@connection_hooks.clear

      hooks = base_hooks(statement_timeout_ms)
      slot = PoolSlot.new(DB.open(url), "main", "rw", hooks)
      @@pool_slots = [slot]
      @@entries = [Entry.new("main", slot, nil, ["*"])]
      sync_connection_hooks
    end

    # Builds the route table and the pool map from the cluster config: one
    # primary pool per entry, one ro pool per entry (the `replica:` pool
    # when defined, else an enforced pool at the primary URL). Entries that
    # share a URL keep separate pools.
    private def self.init_cluster(cluster : ClusterConfig, statement_timeout_ms : Int32?) : Nil
      close
      @@statement_timeout_ms = statement_timeout_ms
      @@connection_hooks.clear

      slots = [] of PoolSlot
      entries = [] of Entry
      enforcement = Proc(DB::Connection, Nil).new do |conn|
        conn.exec("SET default_transaction_read_only = on")
      end

      cluster.databases.each do |db|
        hooks = base_hooks(statement_timeout_ms)
        primary = PoolSlot.new(
          open_pool(db.url, db.initial_pool_size, db.max_pool_size, db.checkout_timeout_s),
          db.name, "rw", hooks,
        )
        slots << primary

        ro_hooks = hooks + [enforcement]
        ro_slot = if replica = db.replica
                    PoolSlot.new(
                      open_pool(replica.url, replica.initial_pool_size, replica.max_pool_size, replica.checkout_timeout_s),
                      db.name, "ro", ro_hooks,
                    )
                  else
                    PoolSlot.new(
                      open_pool(db.url, db.initial_pool_size, db.max_pool_size, db.checkout_timeout_s),
                      db.name, "ro", ro_hooks,
                    )
                  end
        slots << ro_slot

        entries << Entry.new(db.name, primary, ro_slot, db.resources)
      end

      @@pool_slots = slots
      @@entries = entries
      sync_connection_hooks
    end

    # Hooks shared by every pool: the UTC pin first, then the statement
    # timeout when configured.
    private def self.base_hooks(statement_timeout_ms : Int32?) : Array(Proc(DB::Connection, Nil))
      hooks = [
        Proc(DB::Connection, Nil).new do |conn|
          conn.exec("SET TimeZone = 'UTC'")
        end,
      ] of Proc(DB::Connection, Nil)
      if timeout = statement_timeout_ms
        hooks << Proc(DB::Connection, Nil).new do |conn|
          conn.exec("SET statement_timeout = #{timeout}")
        end
      end
      hooks
    end

    # Opens a pool at *url*, appending crystal-db's pool-sizing query
    # parameters when configured (crystal-db reads them from the URL).
    private def self.open_pool(
      url : String,
      initial_pool_size : Int32?,
      max_pool_size : Int32?,
      checkout_timeout_s : Float64?,
    ) : DB::Database
      if initial_pool_size.nil? && max_pool_size.nil? && checkout_timeout_s.nil?
        return DB.open(url)
      end
      uri = URI.parse(url)
      params = URI::Params.parse(uri.query || "")
      params["initial_pool_size"] = initial_pool_size.to_s if initial_pool_size
      params["max_pool_size"] = max_pool_size.to_s if max_pool_size
      params["checkout_timeout"] = checkout_timeout_s.to_s if checkout_timeout_s
      uri.query = params.to_s
      DB.open(uri.to_s)
    end

    # Registers a block to run on every pooled connection of every pool —
    # both the existing ones (iterated immediately) and any future
    # lazily-created ones. Hooks compose: each registration is kept and
    # run in order on every connection, after the per-pool hooks
    # `init` installed. Thin wrapper around `DB::Database#setup_connection`
    # so callers don't need direct access to the pools.
    def self.setup_connection(&proc : DB::Connection -> Nil) : Nil
      @@connection_hooks << proc
      sync_connection_hooks
    end

    # Re-registers the combined hook list on every pool. Each pool stores
    # a single proc, so one combined proc runs the pool's own hooks and
    # then the shared list, in order.
    private def self.sync_connection_hooks : Nil
      @@pool_slots.each do |slot|
        slot.pool.setup_connection do |conn|
          slot.hooks.each(&.call(conn))
          @@connection_hooks.each(&.call(conn))
        end
      end
    end

    # Closes every pool. Safe to call when not initialized.
    def self.close : Nil
      slots = @@pool_slots
      @@pool_slots = [] of PoolSlot
      @@entries = [] of Entry
      slots.each(&.pool.close)
    end

    # Yields every pool with its route labels (database entry name and
    # pool role: "rw" or "ro"). Healthcheck and diagnostics probe pools
    # through this.
    def self.each_pool(& : (String, String, DB::Database) -> Nil) : Nil
      @@pool_slots.each do |slot|
        yield slot.database, slot.role, slot.pool
      end
    end

    # Returns the database URL from the environment.
    def self.url_from_env : String
      ENV.fetch("DATABASE_URL") { abort("DATABASE_URL is required") }
    end

    # ── Route resolution ─────────────────────────────────────────────────

    # Resolves the resource to its database entry: the entry that lists it,
    # else the entry carrying `*` (validation guarantees exactly one).
    # The mode never changes the database — it selects the pool inside the
    # resolved entry.
    private def self.resolve(resource : String) : Entry
      raise "Database not initialized — call Database.init first" if @@entries.empty?
      @@entries.find(&.resources.includes?(resource)) ||
        @@entries.find(&.resources.includes?("*")) ||
        raise "No database entry routes resource '#{resource}'"
    end

    # Groups the given resources by their routed database entry, one array
    # per distinct entry, in the order the entries first appear while
    # walking the input. A single-pool configuration (one entry carrying
    # `*`) yields one group holding every resource.
    #
    # There is no cross-database SQL, so a caller that must read several
    # resources at once (the app-wide search fan-out) runs one statement
    # per group and merges the results itself. The first resource of each
    # group is a valid `with_db` resource label for the whole group.
    def self.group_by_database(resources : Array(String)) : Array(Array(String))
      groups = [] of Array(String)
      group_of_entry = {} of String => Int32
      seen = Set(String).new

      resources.each do |resource|
        next unless seen.add?(resource)
        entry = resolve(resource)
        index = group_of_entry[entry.name]?
        unless index
          index = groups.size
          group_of_entry[entry.name] = index
          groups << [] of String
        end
        groups[index] << resource
      end

      groups
    end

    # ── Access patterns ─────────────────────────────────────────────────

    # Yields a single pooled connection pinned to the current fiber.
    #
    # If the fiber already holds a pin that satisfies the request (see the
    # reuse table in the module doc), it is reused as-is — no checkout. The
    # resource label is consulted only at checkout: a reused pin ignores
    # the inner resource. Otherwise a fresh connection is checked out from
    # the resolved route pool, pinned to the fiber, and released back to
    # the pool when the block ends.
    #
    # Use this for read paths that don't need a transaction but still
    # benefit from connection stability (e.g. multiple reads in a row
    # seeing a consistent snapshot).
    def self.with_connection(mode : Mode = Mode::ReadWrite, resource : String = "*", & : DB::Connection -> T) : T forall T
      with_pinned(mode, resource) { |conn, _pin| yield conn }
    end

    # Convenience alias for read paths. Yields a pinned connection.
    def self.with_db(mode : Mode = Mode::ReadWrite, resource : String = "*", & : DB::Connection -> T) : T forall T
      with_connection(mode, resource) { |db| yield db }
    end

    # Begins a transaction on a pinned connection, yields the connection
    # inside the transaction, and commits on success. Rolls back and
    # re-raises on exception.
    #
    # A block that returns an error value — any value whose type includes
    # `Facet::ErrorResult` — has produced nothing worth keeping. The
    # wrapper rolls the transaction back and returns the error unchanged
    # to the caller. On the top-level rollback it also discards the
    # fiber's pending event queue, so the buffered events of a failed
    # transaction never ride a later flush.
    #
    # The connection is pinned via `with_connection`, so every statement
    # inside the block runs on the same backend — including any nested
    # `with_transaction` or `with_db` calls.
    #
    # Supports nesting via PG savepoints: a nested `with_transaction`
    # creates a savepoint instead of a new top-level transaction.
    # Rolling back an inner savepoint does not abort the outer txn.
    def self.with_transaction(mode : Mode = Mode::ReadWrite, resource : String = "*", & : DB::Connection -> T) : T forall T
      with_pinned(mode, resource) do |db, pin|
        Facet::Telemetry.trace("db.transaction") do |span|
          span["db.pool"] = "#{pin.database}/#{pin.role}"
          enter_transaction(db)
          begin
            value = yield db
            if value.is_a?(Facet::ErrorResult)
              Event::Publisher.discard if rollback_transaction(db)
              value
            else
              leave_transaction(db)
              value
            end
          rescue e
            Event::Publisher.discard if rollback_transaction(db)
            raise e
          end
        end
      end
    end

    # Variation of `with_transaction` that reuses an existing pinned
    # connection. The caller must already hold a connection (typically
    # from an outer `with_connection` or `with_transaction`), or passes a
    # raw connection it owns (the seeds). Nesting is handled via
    # savepoints.
    #
    # When `ignore_if_set: true` is passed and the given connection is
    # already inside a transaction, this method yields without opening a
    # new savepoint — useful for service methods that must be atomic when
    # called standalone but should join the caller's transaction when one
    # is already active. When no transaction is active, the wrapper always
    # opens one regardless of `ignore_if_set` — the flag is an opt-out for
    # outer-transaction callers, not a way to skip transactionality
    # entirely.
    #
    # `isolation` appends an isolation clause to the outermost BEGIN
    # (e.g. `"ISOLATION LEVEL REPEATABLE READ, READ ONLY"`). It is honoured
    # only when this call opens the transaction (depth 0); a nested entry
    # creates a savepoint on the caller's transaction and cannot change its
    # isolation.
    #
    # Like the mode overload, a block that returns an error value (any
    # value whose type includes `Facet::ErrorResult`) rolls the transaction
    # back and comes back to the caller unchanged. A savepoint rollback
    # leaves the event-queue decision to the outermost frame.
    def self.with_transaction(db : DB::Connection, *, ignore_if_set : Bool = false, isolation : String? = nil, & : DB::Connection -> T) : T forall T
      if ignore_if_set && txn_depth(db) > 0
        yield db
      else
        Facet::Telemetry.trace("db.transaction") do |span|
          if pin = pin_for(db)
            span["db.pool"] = "#{pin.database}/#{pin.role}"
          else
            span["db.pool"] = "external"
          end
          enter_transaction(db, isolation)
          begin
            value = yield db
            if value.is_a?(Facet::ErrorResult)
              Event::Publisher.discard if rollback_transaction(db)
              value
            else
              leave_transaction(db)
              value
            end
          rescue e
            Event::Publisher.discard if rollback_transaction(db)
            raise e
          end
        end
      end
    end

    # Core pin logic. Resolves the route, reuses a satisfying pin, or
    # checks out a new one; yields the connection and its pin (the pin
    # labels the `db.transaction` span); releases on exit only what this
    # frame checked out.
    private def self.with_pinned(mode : Mode, resource : String, & : (DB::Connection, Pin) -> T) : T forall T
      fiber = Fiber.current
      if pin = fiber.db_rw
        return yield pin.connection, pin
      end
      if mode.read_only? && (pin = fiber.db_ro)
        return yield pin.connection, pin
      end

      entry = resolve(resource)
      slot = if mode.read_only? && (ro = entry.read_only)
               ro
             else
               entry.primary
             end

      Metrics.inc("facet_db_checkout_total", {"database" => slot.database, "role" => slot.role})
      conn = slot.pool.checkout
      conn.auto_release = false
      pin = Pin.new(conn, slot.database, slot.role)
      set_pin(fiber, mode, pin)
      begin
        yield conn, pin
      ensure
        clear_pin(fiber, mode, conn)
        Fiber.current.txn_depths.try(&.delete(conn))
        conn.release
      end
    end

    private def self.set_pin(fiber : Fiber, mode : Mode, pin : Pin) : Nil
      if mode.read_only?
        fiber.db_ro = pin
      else
        fiber.db_rw = pin
      end
    end

    # A frame releases only a pin it checked out itself: the slot is
    # cleared only when it still holds the connection this frame checked
    # out. A reused pin (checked out by an outer frame) is never released
    # here.
    private def self.clear_pin(fiber : Fiber, mode : Mode, conn : DB::Connection) : Nil
      if mode.read_only?
        fiber.db_ro = nil if fiber.db_ro.try(&.connection.same?(conn))
      else
        fiber.db_rw = nil if fiber.db_rw.try(&.connection.same?(conn))
      end
    end

    # The pin holding *conn* on this fiber, when it is a pinned pooled
    # connection. Raw connections (e.g. the seeds') have no pin.
    private def self.pin_for(conn : DB::Connection) : Pin?
      fiber = Fiber.current
      fiber.db_rw.try { |p| return p if p.connection.same?(conn) }
      fiber.db_ro.try { |p| return p if p.connection.same?(conn) }
      nil
    end

    # ── Private transaction helpers ─────────────────────────────────────

    # Fiber-local, per-connection depth counter for transaction nesting.
    private def self.txn_depth(db : DB::Connection) : Int32
      Fiber.current.txn_depths.try(&.[db]?) || 0
    end

    private def self.set_txn_depth(db : DB::Connection, depth : Int32) : Nil
      depths = Fiber.current.txn_depths
      if depths
        depths[db] = depth
      else
        Fiber.current.txn_depths = {db => depth} of DB::Connection => Int32
      end
    end

    # Enters a transaction: either BEGIN (optionally with an isolation
    # clause — see `with_transaction`) or SAVEPOINT.
    private def self.enter_transaction(db : DB::Connection, isolation : String? = nil) : Nil
      depth = txn_depth(db)
      if depth == 0
        db.exec(isolation ? "BEGIN #{isolation}" : "BEGIN")
      else
        db.exec("SAVEPOINT facet_txn_#{depth}")
      end
      set_txn_depth(db, depth + 1)
    end

    # Leaves a transaction: either COMMIT or RELEASE SAVEPOINT.
    private def self.leave_transaction(db : DB::Connection) : Nil
      depth = txn_depth(db)
      if depth <= 0
        raise "Transaction depth underflow — mismatched BEGIN/COMMIT"
      end
      set_txn_depth(db, depth - 1)
      if depth == 1
        db.exec("COMMIT")
      else
        db.exec("RELEASE SAVEPOINT facet_txn_#{depth - 1}")
      end
    end

    # Rolls back a transaction: either ROLLBACK or ROLLBACK TO SAVEPOINT.
    # Returns true when this call executed the top-level ROLLBACK — this
    # frame owned the whole transaction. Callers use it to release
    # fiber-local state (the pending event queue) only on the outermost
    # rollback; a savepoint rollback leaves that decision to the
    # outermost frame.
    private def self.rollback_transaction(db : DB::Connection) : Bool
      depth = txn_depth(db)
      if depth <= 0
        raise "Transaction depth underflow during rollback"
      end
      set_txn_depth(db, depth - 1)
      if depth == 1
        db.exec("ROLLBACK")
        true
      else
        db.exec("ROLLBACK TO SAVEPOINT facet_txn_#{depth - 1}")
        false
      end
    end
  end
end
