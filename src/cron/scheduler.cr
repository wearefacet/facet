# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "mutex"
require "../metrics"
require "../util/fiber_supervisor"
require "./parser"

# Fiber-based cron scheduler.
#
# Runs a single loop fiber that sleeps until the next task is due (or is
# woken early by a registry change). When a task is due, it is executed in
# its own fiber so a slow or failing task never blocks the scheduler or
# sibling tasks.
#
# ## Lifecycle
#
# 1. `Scheduler#start` spawns the loop fiber.
# 2. `#register` adds a task (id + cron expression + block); the loop is
#    woken so the new task's `next_run` is taken into account without
#    waiting for the current sleep to elapse.
# 3. `#unregister` removes a task by id and wakes the loop.
# 4. `#stop` wakes the loop and lets it exit; in-flight task fibers are
#    not cancelled (they run to completion).
#
# A failing task fiber logs an error and the scheduler keeps running — a
# task exception never crashes the loop or sibling tasks. This mirrors the
# `Event::Manager.dispatch_message` fault-isolation pattern.
#
# ## Once-per-cluster tick lease
#
# With an `acquire_lease` proc wired, every dispatch first leases the
# task's scheduled tick in Redis and skips the fire on a loss: the first
# instance to dispatch a tick runs it, every other instance of the cluster
# skips. The key carries the task id and the tick, so a lease can never
# alias a different fire moment; the TTL covers only the dispatch jitter
# between instances, not the task duration. Without a proc (the default)
# the scheduler fires unconditionally — the single-instance shape, and the
# shape specs drive. See `Cron::Lease` for the Redis-backed acquirer and
# `doc/backend/cron.md`.
class Facet::Cron::Scheduler
  Log = Facet::Cron::Log.for("scheduler")

  # A registered cron task.
  #
  # `next_run` is the next instant at which the task must fire. At dispatch
  # time the scheduler advances it synchronously via `Parser#next` (computed
  # from the fire time, not the scheduled instant, so a delayed firing does
  # not cause a catch-up storm) — before the block runs.
  record Task,
    id : String,
    parser : Facet::Cron::Parser,
    next_run : Time,
    block : Proc(Nil)

  getter tasks : Array(Task)

  @clock : Proc(Time)
  @acquire_lease : Proc(String, Int32, String, Bool)?
  @service_id : String
  @wake : Channel(Nil)?
  @run_fiber : Fiber?
  @mutex = Mutex.new
  @stopped = true
  @in_flight = Set(String).new

  # `clock` defaults to `Time.utc` and exists so tests can inject a
  # deterministic time source instead of sleeping wall-clock minutes.
  #
  # `acquire_lease` wires the once-per-cluster tick lease (see the header
  # comment). `nil` — the default — disables leasing. Production passes
  # the Redis-backed acquirer from `Cron::Lease.redis_acquirer`; tests
  # inject in-memory procs. The acquirer runs on the loop fiber, so a
  # wired client never sees concurrent calls.
  def initialize(
    @clock : Proc(Time) = -> { Time.utc },
    @acquire_lease : Proc(String, Int32, String, Bool)? = nil,
    @service_id : String = "facet-cron",
  )
    @tasks = [] of Task
  end

  # Returns `true` while the loop fiber is running.
  def running? : Bool
    @mutex.synchronize { !@stopped }
  end

  # Ids of the tasks whose block fiber is currently running. The loop never
  # awaits in-flight task fibers (see `#stop`), so this set is the only
  # observability for how many dispatches are still unwinding — shutdown
  # reporting reads it, and it pins the dispatch contract in specs: the
  # id leaves the set inside the same `ensure` scope that any bookkeeping
  # would run in, so an absent id means the fiber has fully unwound.
  def in_flight : Array(String)
    @mutex.synchronize { @in_flight.to_a }
  end

  # Spawns the loop fiber. Idempotent: a no-op if already running. The loop
  # runs under `Util::FiberSupervisor`: a raise that escapes the loop body
  # (a bug in the bookkeeping, not in a task — task fibers rescue their own
  # errors) restarts the loop after a backoff instead of killing the
  # scheduler silently.
  def start : Nil
    @mutex.synchronize do
      return unless @stopped
      @stopped = false
      @wake = Channel(Nil).new
    end
    @run_fiber = Util::FiberSupervisor.supervise("Cron Scheduler") { run_loop }
  end

  # Signals the loop to exit. The loop fiber observes the closed `@wake`
  # channel on its next `select` turn and returns. Idempotent.
  #
  # In-flight task fibers are not awaited or cancelled.
  def stop : Nil
    wake = @mutex.synchronize do
      return if @stopped
      @stopped = true
      @wake
    end
    wake.try(&.close)
  end

  # Registers a task identified by `id`. If a task with the same id already
  # exists, it is replaced. Wakes the loop so the new `next_run` is taken
  # into account immediately.
  #
  # Returns the `next_run` instant that was computed for the task.
  def register(id : String, expression : String, &block : ->) : Time
    parser = Facet::Cron::Parser.new(expression)
    next_run = parser.next(@clock.call)
    task = Task.new(id: id, parser: parser, next_run: next_run, block: block)

    @mutex.synchronize do
      @tasks.reject!(&.id.==(id))
      insert_sorted(task)
    end
    wake

    next_run
  end

  # Removes the task identified by `id`, if present. Wakes the loop so a
  # shorter sleep is not held unnecessarily. Returns `true` if a task was
  # removed.
  def unregister(id : String) : Bool
    removed = false
    @mutex.synchronize do
      before = @tasks.size
      @tasks.reject!(&.id.==(id))
      removed = @tasks.size < before
    end
    wake if removed
    removed
  end

  # ── Internals ──────────────────────────────────────────────────────

  private def run_loop : Nil
    loop do
      sleep_span = compute_sleep_span
      select_sleep(sleep_span)

      # `stop` closes `@wake` — a closed receive returns `nil`; exit.
      return if @mutex.synchronize { @stopped }

      now = @clock.call
      fire_due(now)
    end
  end

  # Computes the duration until the next task is due. Zero (fire
  # immediately) when a task is already overdue or the registry is empty
  # (an empty registry short-circuits to a small idle poll — there is no
  # next task to wait for, but we must not sleep forever or `stop` cannot
  # break us out).
  private def compute_sleep_span : Time::Span
    head = @mutex.synchronize { @tasks.first? }
    return IDLE_POLL_INTERVAL unless head

    span = head.next_run - @clock.call
    span < ZERO_SPAN ? ZERO_SPAN : span
  end

  # Blocks for at most `span`, or until `@wake` is signalled/closed.
  # Returns `true` if woken by a signal/close, `false` if the timeout
  # elapsed. A closed channel is observed as a non-blocking `receive?`
  # returning `nil`.
  private def select_sleep(span : Time::Span) : Bool
    wake = @mutex.synchronize { @wake }
    return true if wake.nil? # not started / stopped

    select
    when timeout(span)
      false
    when wake.receive?
      true
    end
  end

  # Fires every task whose `next_run` is at or before `now`. Each fires in
  # its own fiber. `next_run` is advanced synchronously before the fiber
  # spawns, so the loop can never observe a stale due task and re-dispatch
  # a still-running one.
  private def fire_due(now : Time) : Nil
    due = @mutex.synchronize do
      fired = @tasks.select(&.next_run.<=(now))
      fired.each do |task|
        @tasks.reject!(&.id.==(task.id))
        insert_sorted(Task.new(id: task.id, parser: task.parser, next_run: task.parser.next(now), block: task.block))
      end
      fired
    end
    return if due.empty?

    due.each do |task|
      spawn_fire(task)
    end
  end

  # Fires one due task in its own fiber. With a lease acquirer wired, the
  # task's tick is leased first: a loss means another instance already
  # fires this tick — skip. `task` is the pre-advance record, so
  # `task.next_run` is the scheduled tick this dispatch belongs to.
  private def spawn_fire(task : Task) : Nil
    if acquirer = @acquire_lease
      unless acquirer.call(lease_key_for(task), LEASE_TTL_S, @service_id)
        Log.debug { "Cron task '#{task.id}': tick #{task.next_run.to_unix} already leased — skipping" }
        Metrics.inc("facet_cron_task_lease_skips_total", {"task" => task.id})
        return
      end
    end

    @mutex.synchronize { @in_flight.add(task.id) }
    spawn do
      begin
        task.block.call
      rescue e : Exception
        Log.error { "Cron task #{task.id} raised: #{e.message}" }
        Metrics.inc("facet_cron_task_failures_total", {"task" => task.id})
      ensure
        @mutex.synchronize { @in_flight.delete(task.id) }
      end
    end
  end

  private def lease_key_for(task : Task) : String
    "#{LEASE_KEY_PREFIX}#{task.id}:#{task.next_run.to_unix}"
  end

  private def insert_sorted(task : Task) : Nil
    idx = @tasks.bsearch_index { |t| t.next_run > task.next_run } || @tasks.size
    @tasks.insert(idx, task)
  end

  private def wake : Nil
    wake = @mutex.synchronize { @wake }
    wake.try { |c| c.send(nil) rescue nil }
  end

  IDLE_POLL_INTERVAL = 1.second
  ZERO_SPAN          = Time::Span.zero

  # Once-per-cluster tick lease. The key carries the task id and the
  # scheduled tick (unix seconds) — a lease can never alias a different
  # fire moment. The TTL covers only the dispatch jitter between
  # instances, not the task duration: the key auto-expires, and the next
  # tick leases its own key.
  LEASE_KEY_PREFIX = "cron:lease:"
  LEASE_TTL_S      = 120
end
