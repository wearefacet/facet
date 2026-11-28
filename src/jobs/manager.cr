# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "mutex"
require "../config"
require "../database"
require "../metrics"
require "../util/script_helpers"
require "./handler"
require "./job"
require "./queries"
require "./worker"

module Facet
  module Jobs
    # Coordinator for the background-jobs subsystem.
    #
    # Owns the `Worker` that polls `background_jobs`. `main.cr` constructs
    # one `Jobs::Manager`, installs it as the process-wide singleton, and
    # calls `start` after the HTTP server boots; `stop` runs in `at_exit`.
    #
    # ## Enabled / enqueue-only mode
    #
    # With `jobs.enabled: false` the worker never starts: the manager
    # stays in enqueue-only mode. `enqueue` still inserts rows, so callers
    # can stage work that a later-enabled worker (or another process with
    # the worker on) claims.
    #
    # ## Singleton
    #
    # `self.instance` / `self.instance=` / `self.reset!` mirror
    # `Hooks::Manager`. The accessor returns `nil` when no manager is
    # installed (e.g. in test contexts that don't boot the jobs
    # subsystem) — callers use `try` to skip safely.
    # ## Handler registration
    #
    # `register_handler(kind, klass)` fills the dispatch table one entry at
    # a time. It must run **before** `start`: the worker snapshots the map
    # at start, so an entry registered afterwards would never be seen by
    # the running loop — registration after start raises.
    class Manager
      Log = ::Log.for("facet.jobs.manager")

      # Process-wide singleton accessor (mirrors `Hooks::Manager`).
      # Installed by `main.cr` after construction.
      @@instance : Manager?

      def self.instance : Manager?
        @@instance
      end

      def self.instance=(mgr : Manager?) : Nil
        @@instance = mgr
      end

      # Clears the singleton. Specs call this so one example never leaks
      # its manager into the next.
      def self.reset! : Nil
        @@instance = nil
      end

      getter config : Config::JobsConfig
      getter worker : Worker?

      @handlers : Hash(String, Handler.class)
      @worker : Worker?
      @mutex : Mutex
      # The tightest `max_concurrent` any enqueue named. It lowers the cap
      # of the next `start` (the worker snapshots its cap at start), so a
      # heavy kind cannot fill the worker with default-capped fibers. Once
      # a worker runs, the cap applies at its next restart — the running
      # worker keeps the cap it started with.
      @concurrency_override : Int32?

      # Stores configuration and the handler map. No I/O. The map fills
      # the flat `kind` → `Handler` table of the worker constructed at
      # `start`.
      def initialize(config : Config::JobsConfig = Config.instance.jobs, handlers : Hash(String, Handler.class) = {} of String => Handler.class)
        @config = config
        @handlers = handlers
        @worker = nil
        @concurrency_override = nil
        @mutex = Mutex.new
      end

      # Registers one `kind` → `Handler.class` entry into the dispatch
      # table. Must be called before `start` — the worker snapshots the map
      # at start, so a later registration would silently never dispatch.
      def register_handler(kind : String, handler : Handler.class) : Nil
        @mutex.synchronize do
          if @worker
            raise "Cannot register handler '#{kind}' — Jobs::Manager already started"
          end
          @handlers[kind] = handler
        end
      end

      # Returns the registered handler class for `kind`, or nil. Read-only
      # view for tests and diagnostics.
      def handler_for(kind : String) : Handler.class | Nil
        @mutex.synchronize { @handlers[kind]? }
      end

      # Starts the poll-loop worker when `jobs.enabled` is true. Idempotent:
      # a no-op when the worker is already running, and a no-op (enqueue-only
      # mode) when disabled.
      def start : Nil
        @mutex.synchronize do
          return if @worker || !@config.enabled

          # `@concurrency_override` is the tightest cap any enqueue named
          # (an import caps the whole worker at its own `max_concurrent`),
          # so the aggregate footprint stays bounded by the heaviest work
          # the worker can run, not only by the global `jobs.max_concurrent`.
          worker = Worker.new(
            poll_interval_s: @config.poll_interval_s,
            lease_ttl_s: @config.lease_ttl_s,
            batch: @config.batch,
            max_concurrent: @concurrency_override || @config.max_concurrent,
            sweep_interval_s: @config.sweep_interval_s,
            retention_days: @config.retention_days,
            handlers: @handlers,
          )
          worker.start
          @worker = worker
          Log.info { "Jobs manager started (poll_interval_s: #{@config.poll_interval_s})" }
        end
      end

      # Signals the worker loop to exit. Idempotent, and safe when the
      # manager is disabled (no worker to stop).
      def stop : Nil
        worker = @mutex.synchronize do
          w = @worker
          @worker = nil
          w
        end
        worker.try(&.stop)
      end

      # Enqueues one `pending` row and returns the new row id. Delegates to
      # the running worker; in enqueue-only mode it inserts the row directly
      # so the work is staged even though no worker will claim it here.
      # `lease_ttl_s` overrides the row's lease length at claim time; nil
      # keeps the worker default. `max_concurrent` is the kind's own
      # concurrency cap: the next worker start honours the tightest cap
      # among its enqueues, so a heavy kind (an import) can hold the
      # worker to fewer fibers than `jobs.max_concurrent`.
      def enqueue(kind : String, payload : JSON::Any, *, max_attempts : Int32? = nil, backoff : Array(Int32)? = nil, run_after : Time? = nil, lease_ttl_s : Int32? = nil, max_concurrent : Int32? = nil) : String
        worker = @mutex.synchronize do
          if cap = max_concurrent
            previous = @concurrency_override
            @concurrency_override = previous ? (previous < cap ? previous : cap) : cap
          end
          @worker
        end
        Database.with_db(:read_write) do |db|
          if worker
            worker.enqueue(db, kind, payload, max_attempts: max_attempts, backoff: backoff, run_after: run_after, lease_ttl_s: lease_ttl_s)
          else
            id = Util::ScriptHelpers.ulid
            Queries.insert(db, id, kind, payload, max_attempts: max_attempts, backoff: backoff, run_after: run_after, lease_ttl_s: lease_ttl_s)
            # Enqueue-only mode inserts directly — count it here so both
            # branches report exactly once (the running-worker branch
            # counts inside `Worker#enqueue`).
            Metrics.inc("facet_jobs_enqueued_total", {"kind" => kind})
            id
          end
        end
      end
    end
  end
end
