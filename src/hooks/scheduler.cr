# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "redis"
require "../cron/parser"
require "../database"
require "../event/publisher"
require "../iam/redis"
require "../metrics"
require "../util/fiber_supervisor"
require "./registry"
require "./executor"
require "./definition"

module Facet
  module Hooks
    # Cluster-wide once-per-fire dispatcher for `:schedule` hooks.
    #
    # One instance per `Hooks::Manager`. Owns a single poll-loop fiber that,
    # every `scheduler_poll_interval_s` (default 5s), reads
    # `Registry#schedule_hooks` and attempts to fire each due hook exactly
    # once across the cluster.
    #
    # ## Once-only guarantee
    #
    # Per tick, for each schedule hook:
    #
    # 1. Compute the fire bucket — `Cron::Parser#last(now)`, the most recent
    #    cron instant at or before `now`. A `*/5 * * * *` cron at `t=312s`
    #    yields the `t=300s` bucket.
    # 2. Lease key = `hooks:lease:{owning_domain}:{hook_id}:{fire_at.to_unix}`.
    #    The unix-second bucket is baked into the key so the same lease can
    #    never be reused for a different fire moment — no clock-drift
    #    double-fires across instances.
    # 3. Acquire via `SET key service_id NX EX lease_ttl_s` (the redis shard
    #    returns `"OK"` on success, `nil` if the key already exists).
    # 4. On win: open a DB connection, build an `Executor`, call
    #    `run_schedule(scheduled_at: fire_at)`. Lua/DB failures are logged
    #    and the lease stays held (the bucket is not retried by another
    #    instance on the same tick — skip-and-continue, plan decision 4).
    # 5. The lease TTL (default 600s) outlives any Lua run (hard-capped at
    #    `lua.time_limit_s`), so a slow script can never cause a duplicate
    #    fire; the key auto-expires, no explicit release is needed.
    #
    # The "advance" is implicit: each tick recomputes the bucket from the
    # clock — no `next_fire` state lives in Redis.
    #
    # ## Misfire grace
    #
    # None in v1. A genuine instance outage longer than the lease TTL loses
    # the missed bucket (the next tick computes the next-naturally-due
    # bucket). This matches the plan's "honest failure over silent catch-up
    # batches" stance. Firing `last(now)` on the first tick after startup is
    # benign for common minute/hour crons (at most one stale bucket fires);
    # daily crons may fire at most one stale bucket on startup.
    #
    # ## Reentrancy
    #
    # Hook-executed mutations run with `reentrant: true` (decision 5), set by
    # `Hooks::Executor` at registration time. The scheduler calls
    # `Event::Publisher.flush` after each fire so reentrant write events land
    # on the stream immediately (mirrors `Hooks::Handler`).
    class Scheduler
      Log = ::Log.for("facet.hooks.scheduler")

      getter registry : Registry
      getter poll_interval : Time::Span
      getter lease_ttl_s : Int32

      @redis : ::Redis::Client?
      @acquire_lease : Proc(String, Int32, String, Bool)
      @service_id : String
      @clock : Proc(Time)
      @stop_channel : Channel(Nil)?
      @run_fiber : Fiber?
      @mutex = Mutex.new
      @stopped = true

      # Yields control of construction to the caller; `clock` is injectable
      # so specs can advance time past a cron boundary without sleeping
      # wall-clock minutes. `service_id` is the instance identifier written
      # into the lease value (visible in Redis for diagnostics).
      #
      # `acquire_lease` is the cluster-wide once-per-fire primitive. The
      # default implementation is a Redis `SET NX EX`; specs may inject a
      # pure-in-memory implementation to drive the bucket/dispatch logic
      # without a live Redis.
      def initialize(
        @registry : Registry,
        redis_url : String,
        @service_id : String,
        poll_interval_s : Float64 = 5.0,
        @lease_ttl_s : Int32 = 600,
        @clock : Proc(Time) = -> { Time.utc },
        acquire_lease : Proc(String, Int32, String, Bool)? = nil,
      )
        @poll_interval = poll_interval_s.seconds
        if lease_proc = acquire_lease
          # Caller injected a lease acquirer (e.g. an in-memory impl in tests).
          # No Redis connection needed in this path.
          @acquire_lease = lease_proc
          @redis = nil
        else
          @redis = Facet::Redis.client(redis_url)
          @acquire_lease = default_acquire_lease
        end
      end

      # Returns `true` while the poll fiber is running.
      def running? : Bool
        @mutex.synchronize { !@stopped }
      end

      # Spawns the poll fiber. Idempotent — a no-op if already running. The
      # loop runs under `Util::FiberSupervisor`: a raise that escapes the
      # loop body restarts the scheduler after a backoff instead of killing
      # it silently.
      def start : Nil
        @mutex.synchronize do
          return unless @stopped
          @stopped = false
          @stop_channel = Channel(Nil).new
        end
        @run_fiber = Util::FiberSupervisor.supervise("Hooks Scheduler") { run_loop }
      end

      # Signals the poll fiber to exit. Idempotent. In-flight hook fire
      # fibers are not awaited or cancelled (they run to completion — the
      # Lua sandbox's `time_limit_s` bounds any runaway).
      def stop : Nil
        channel = @mutex.synchronize do
          return if @stopped
          @stopped = true
          @stop_channel
        end
        channel.try(&.close)
      end

      # ── Internals ──────────────────────────────────────────────────────

      private def run_loop : Nil
        Log.info { "Hooks scheduler started (poll=#{poll_interval.total_seconds}s, lease_ttl=#{lease_ttl_s}s)" }
        loop do
          select_sleep(poll_interval)
          return if @mutex.synchronize { @stopped }

          begin
            tick(@clock.call)
          rescue ex : Exception
            # A transient DB or Redis error in the tick path is logged and
            # retried on the next poll — the scheduler never crashes.
            Log.error { "Hooks scheduler tick failed: #{ex.message}" }
            Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => "Hooks Scheduler"})
          end
        end
      ensure
        Log.info { "Hooks scheduler stopped" }
      end

      # One scheduler tick — public so specs can drive a deterministic tick
      # without sleeping. Reads the schedule-hook list, attempts to fire each
      # due hook, flushes events so reentrant writes land immediately.
      def tick(now : Time) : Nil
        hooks = @registry.schedule_hooks
        return if hooks.empty?

        hooks.each do |hook|
          fire_one(hook, now)
        end

        Facet::Event::Publisher.flush
      end

      # Attempts to fire one hook for the bucket covering `now`. Acquires the
      # lease first; on a win, opens a DB connection and runs the script.
      # Failures in the Lua / DB layer are logged and the lease stays held
      # (the bucket will not be retried on this tick).
      private def fire_one(hook : Definition::Hook, now : Time) : Nil
        owning_domain = hook.owning_domain
        if owning_domain.nil?
          Log.warn { "Schedule hook '#{hook.id}' has no owning domain — skipping" }
          return
        end

        schedule = hook.schedule
        if schedule.nil?
          Log.warn { "Schedule hook '#{hook.id}' has no cron expression — skipping" }
          return
        end

        parser = Facet::Cron::Parser.new(schedule)
        fire_at = parser.last(now)
        # `last` should always return a time at or before `now`; guard
        # against a future-pinned shard quirk by skipping in that case.
        return if fire_at > now

        lease_key = lease_key_for(owning_domain, hook.id, fire_at)
        won = try_acquire_lease(lease_key)
        unless won
          Log.debug { "Schedule hook '#{owning_domain}.#{hook.id}': bucket #{fire_at.to_unix} already leased — skipping" }
          return
        end

        Log.info { "Schedule hook '#{owning_domain}.#{hook.id}': firing bucket #{fire_at.to_unix} (#{fire_at.to_rfc3339})" }
        run_hook(hook, owning_domain, fire_at, now)
      end

      # Opens a DB connection, builds the executor, runs `on_schedule`. Any
      # failure (Lua error, DB error, etc.) is logged and swallowed — the
      # lease was already acquired, so the bucket is not retried this tick.
      private def run_hook(
        hook : Definition::Hook,
        owning_domain : String,
        fire_at : Time,
        now : Time,
      ) : Nil
        # A schedule fire has no source mutation, so the fire itself mints
        # the trace: every write the hook's Lua performs shares this trace
        # (one causal cluster per fire) with `parent` nil — each write is a
        # chain root.
        fire_trace = Util::ScriptHelpers.ulid
        cause = Mutation::Cause.new(
          kind: Mutation::CauseKind::HookSchedule,
          name: hook.id,
          trace: fire_trace,
        )

        Facet::Database.with_db(:read_write) do |db|
          Executor.new(db, owning_domain, hook, cause: cause) do |executor|
            errors = executor.run_schedule(scheduled_at: fire_at, now: now)
            unless errors.empty?
              Log.warn do
                "Schedule hook '#{hook.id}' on '#{owning_domain}' reported " \
                "#{errors.size} validation error(s): #{errors.map(&.message).join("; ")}"
              end
            end
          end
        end
      rescue ex : Executor::Error
        Log.error { "Schedule hook '#{hook.id}' on '#{owning_domain}' raised Lua error: #{ex.message}" }
      rescue ex : Exception
        Log.error { "Schedule hook '#{hook.id}' on '#{owning_domain}' failed: #{ex.message}" }
      end

      # `SET key service_id NX EX lease_ttl_s`. Returns `true` when this
      # instance won the lease. The redis shard returns `"OK"` on success and
      # `nil` when the key already exists (`NX` miss).
      private def default_acquire_lease : Proc(String, Int32, String, Bool)
        ->(key : String, ttl_s : Int32, owner : String) : Bool do
          begin
            redis = @redis
            return false if redis.nil?
            result = redis.set(key, owner, ex: ttl_s, nx: true)
            result == "OK"
          rescue ex : Exception
            # A transient Redis failure: do not fire. The next tick retries —
            # if Redis is back up, either this instance or another wins the
            # lease. Safer than firing without the once-only guarantee.
            Log.warn { "Lease acquire failed for '#{key}' (skipping fire): #{ex.message}" }
            false
          end
        end
      end

      private def try_acquire_lease(lease_key : String) : Bool
        @acquire_lease.call(lease_key, @lease_ttl_s, @service_id)
      end

      private def lease_key_for(owning_domain : String, hook_id : String, fire_at : Time) : String
        "hooks:lease:#{owning_domain}:#{hook_id}:#{fire_at.to_unix}"
      end

      # Blocks for at most `span`, or until the stop channel is closed.
      private def select_sleep(span : Time::Span) : Nil
        stop = @mutex.synchronize { @stop_channel }
        return if stop.nil? # not started / stopped

        select
        when timeout(span)
        when stop.receive?
        end
      end
    end
  end
end
