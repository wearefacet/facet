# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "log"
require "mutex"
require "pg"
require "../database"
require "../metrics"
require "../service"
require "../util/fiber_supervisor"
require "../util/script_helpers"
require "./handler"
require "./job"
require "./liveness"
require "./queries"

# Poll-loop worker for the `background_jobs` table.
#
# One loop fiber claims due rows (`Queries.claim`), runs each claimed job
# in its own fiber, and writes the outcome. A job fiber never crashes the
# loop: an uncaught handler exception becomes a `Failed` result, and a
# write error is logged — the row is recovered later by the lease sweep.
#
# ## Lifecycle
#
# 1. `Worker#start` spawns the loop fiber.
# 2. Each tick runs maintenance (lease sweep, terminal prune), then claims
#    a batch of due rows. Requeued rows from a sweep are due immediately,
#    so the claim of the same tick picks them up.
# 3. When no row was claimed the loop sleeps `poll_interval_s`; otherwise
#    it re-polls immediately (more rows may be due).
# 4. `Worker#stop` closes the wake channel; the loop observes the close on
#    its next `select` turn and exits. Idempotent. In-flight job fibers
#    are not cancelled (they run to completion).
#
# `kind`-to-handler dispatch is a hash lookup filled at construction — a
# flat map, not a registry abstraction. A claimed row with no handler for
# its kind fails with `last_error = "no handler for kind ..."`.
#
# ## Owner tagging and instance liveness
#
# `claim` tags each row with the owner `{instance_id}:{worker_id}` — the
# boot's `Facet::Service` ULID, then the worker's own ULID. On every sweep
# tick the worker first refreshes its instance's Redis liveness key
# (`Liveness`), then the sweep recovers a `running` row whose lease
# expired or whose owner instance is dead, and caps a touched row past
# its retry cap at `failed`. The `liveness` constructor argument is
# injectable; the default reads and writes Redis (`Liveness::Redis`), and
# a Redis failure fails open — the sweep then works from leases only.
#
# The handler also owns the attempt-lifecycle hooks: started right after
# the claim, finished right after the outcome write, abandoned from the
# lease sweep. Every hook invocation is wrapped — a raising hook is
# logged and skipped, the job outcome path is untouched. The maintenance
# prune pass also calls each handler's `prune_expired` so attempt-log
# tables share the queue's retention horizon. A kind with no registered
# handler has no hooks — no handler, no lifecycle.
#
# The `@clock` injection exists so tests can drive sweeps and prunes
# deterministically instead of sleeping wall-clock time. Job due-ness is
# decided by PostgreSQL's `now()`, not by this clock.
class Facet::Jobs::Worker
  Log = Facet::Jobs::Log.for("worker")

  @clock : Proc(Time)
  @handlers : Hash(String, Handler.class)
  @liveness : Liveness
  @instance_id : String
  @locked_by : String
  @poll_interval_s : Float64
  @lease_ttl_s : Int32
  @batch : Int32
  @sweep_interval_s : Float64
  @retention_days : Int32
  @next_sweep_at : Time
  @next_prune_at : Time
  @wake : Channel(Nil)?
  @mutex = Mutex.new
  @stopped = true
  @generation = 0
  @loop_fiber : Fiber?
  @tick_count : Int64 = 0

  # Stores configuration. No I/O. The `handlers` map fills the flat
  # `kind` → `Handler` dispatch table; each handler carries its own
  # attempt hooks. `liveness` is injectable so specs run without Redis;
  # the default answers from a Redis liveness key (`Liveness::Redis`).
  def initialize(@clock : Proc(Time) = -> { Time.utc }, *, poll_interval_s : Float64 = 5.0, lease_ttl_s : Int32 = 60, batch : Int32 = 32, sweep_interval_s : Float64 = 30.0, retention_days : Int32 = 30, handlers : Hash(String, Handler.class) = {} of String => Handler.class, liveness : Liveness? = nil)
    @poll_interval_s = poll_interval_s
    @lease_ttl_s = lease_ttl_s
    @batch = batch
    @sweep_interval_s = sweep_interval_s
    @retention_days = retention_days
    @handlers = handlers
    # The owner tag identifies the boot (the instance id) and the worker
    # fiber (the per-worker ULID) — the format the sweep parses to find
    # the owner instance's liveness key. See `doc/backend/event.md` →
    # Shard locking for the instance-identity rule.
    @instance_id = Facet::Service.instance_id
    @locked_by = "#{@instance_id}:#{Util::ScriptHelpers.ulid}"
    @liveness = liveness || Liveness::Redis.new
    # Sentinel past instants: the first tick always runs one sweep and one
    # prune pass, then settles into the periodic cadence.
    @next_sweep_at = Time.unix(0)
    @next_prune_at = Time.unix(0)
  end

  # The dispatch table the loop fiber carries (snapshot taken at
  # construction). Read-only view for tests and diagnostics.
  getter handlers : Hash(String, Handler.class)

  # The loop fiber spawned by the last `start`. `nil` before start; dead
  # after `stop`. Tests wait on `dead?` instead of settling blindly.
  getter loop_fiber : Fiber?

  # One full loop pass completed. Written only by the loop fiber; tests
  # read it to prove a tick ran after a wake.
  getter tick_count : Int64

  # Returns `true` while the loop fiber is running.
  def running? : Bool
    @mutex.synchronize { !@stopped }
  end

  # Spawns the loop fiber. Idempotent: a no-op if already running. The loop
  # runs under `Util::FiberSupervisor`: a raise that escapes the loop body
  # (`tick` rescues its own errors — this covers the bookkeeping around it)
  # restarts the loop after a backoff instead of killing the worker
  # silently.
  def start : Nil
    wake = Channel(Nil).new
    @mutex.synchronize do
      return unless @stopped
      @stopped = false
      @generation += 1
      @wake = wake
    end
    @loop_fiber = Util::FiberSupervisor.supervise("Jobs Worker") { run_loop(wake) }
  end

  # Signals the loop to exit. The loop fiber observes the closed wake
  # channel on its next `select` turn and returns. Idempotent.
  #
  # In-flight job fibers are not awaited or cancelled.
  def stop : Nil
    wake = @mutex.synchronize do
      return if @stopped
      @stopped = true
      @wake
    end
    wake.try(&.close)
  end

  # Sends to the wake channel. Tests call this after enqueuing; the loop
  # also uses the channel to break its sleep. A no-op when not started.
  def wake : Nil
    wake = @mutex.synchronize { @wake }
    wake.try { |c| c.send(nil) rescue nil }
  end

  # Enqueues one `pending` row. Provided on the worker so callers have a
  # single entry point. Returns the new row id. `lease_ttl_s` overrides
  # the row's lease length at claim time; nil keeps the worker default.
  def enqueue(db : DB::Connection, kind : String, payload : JSON::Any, *, max_attempts : Int32? = nil, backoff : Array(Int32)? = nil, run_after : Time? = nil, lease_ttl_s : Int32? = nil) : String
    id = Util::ScriptHelpers.ulid
    Queries.insert(db, id, kind, payload, max_attempts: max_attempts, backoff: backoff, run_after: run_after, lease_ttl_s: lease_ttl_s)
    # Counted at the insert — `Jobs::Manager#enqueue` reaches this point
    # when its worker runs, and its enqueue-only branch counts its own
    # insert, so every staged row reports exactly once.
    Metrics.inc("facet_jobs_enqueued_total", {"kind" => kind})
    id
  end

  # ── Internals ──────────────────────────────────────────────────────

  private def run_loop(wake : Channel(Nil)) : Nil
    # The wake channel and generation are captured once, so a stale fiber
    # from a previous start/stop cycle can never receive from the channel
    # owned by the current loop.
    generation = @mutex.synchronize { @generation }

    loop do
      idle = tick
      # Counted after `tick` returns, so an advance proves one full pass
      # ran (test observability).
      @tick_count += 1
      select_sleep(idle ? @poll_interval_s.seconds : ZERO_SPAN, wake)

      # `stop` sets `@stopped`; a later `start` bumps `@generation`. A
      # stale fiber observes either and exits, so exactly one loop fiber
      # serves the worker.
      done = @mutex.synchronize { @stopped || @generation != generation }
      return if done
    end
  end

  # One maintenance + claim pass. Returns `true` when nothing was claimed
  # (the loop may then sleep a full poll interval).
  private def tick : Bool
    now = @clock.call
    run_maintenance(now)

    claims = Database.with_db(:read_write) do |db|
      jobs = Queries.claim(db, @locked_by, @lease_ttl_s, @batch)
      # One handler instance per attempt: the hooks and `execute` run on
      # the same object, so a handler may keep per-attempt state.
      jobs.each { |job| Metrics.inc("facet_jobs_claimed_total", {"kind" => job.kind}) }
      jobs.map do |job|
        handler = @handlers[job.kind]?.try(&.new)
        notify_attempt_started(db, job, handler)
        {job, handler}
      end
    end
    claims.each { |claim| spawn_process(claim) }
    claims.empty?
  rescue e : Exception
    Log.error { "Worker tick failed: #{e.message}" }
    Metrics.inc("facet_fiber_loop_errors_total", {"fiber" => "Jobs Worker"})
    true
  end

  # Runs the lease sweep and the terminal prune when due. A sweep that
  # requeues rows needs no forced wake: the claim of the same tick runs
  # after the sweep, and requeued rows are due immediately.
  private def run_maintenance(now : Time) : Nil
    if now >= @next_sweep_at
      requeued = run_sweep
      requeued.each { |row| Metrics.inc("facet_jobs_abandoned_total", {"kind" => row[:kind]}) }
      Log.info { "Sweep recovered #{requeued.size} stranded job(s)" } if requeued.size > 0
      @next_sweep_at = now + @sweep_interval_s.seconds
    end

    if now >= @next_prune_at
      pruned = Database.with_db(:read_write) do |db|
        Queries.prune_terminal(db, @retention_days) + prune_attempt_logs(db)
      end
      Log.info { "Pruned #{pruned} terminal job(s) and attempt-log row(s)" } if pruned > 0
      @next_prune_at = now + PRUNE_INTERVAL
    end
  end

  # One lease-sweep pass. Refreshes this instance's liveness key first, so
  # a peer's sweep never sees this instance as dead while it ticks. Then
  # resolves the dead owner instances and recovers their stranded rows
  # together with the rows whose lease expired. The `attempt_abandoned`
  # hook rides the sweep's transaction (when practical): a crash between
  # the requeue and the hook leaves no half-marked state, and the next
  # attempt's `attempt_started` insert replaces any lingering pending call
  # row anyway.
  private def run_sweep : Array({id: String, kind: String})
    @liveness.refresh(@instance_id)
    owners = Database.with_db(:read_write) { |db| Queries.running_owner_instances(db) }
    dead = owners.reject { |owner| @liveness.alive?(owner) }
    Log.info { "Sweep marks #{dead.size} owner instance(s) dead: #{dead.join(", ")}" } if dead.size > 0
    Database.with_db(:read_write) do |db|
      Database.with_transaction(db) do
        swept = Queries.sweep_expired_leases(db, dead)
        notify_attempt_abandoned(db, swept)
        swept
      end
    end
  end

  # Blocks for at most `span`, or until `wake` is signalled or closed. A
  # closed channel is observed as a `receive?` returning `nil`.
  private def select_sleep(span : Time::Span, wake : Channel(Nil)) : Nil
    select
    when timeout(span)
      nil
    when wake.receive?
      nil
    end
  end

  private def spawn_process(claim : {Job, Handler?}) : Nil
    job, handler = claim
    spawn { process(job, handler) }
  end

  # Runs one claimed job on its handler instance. The handler never
  # touches the row — the worker writes the outcome from the returned
  # `Result`. The no-handler path writes a terminal `Failed` row; no
  # hooks run, there is no handler to observe them.
  private def process(job : Job, handler : Handler?) : Nil
    result = if handler
               run_handler(handler, job)
             else
               Handler::Result.new(status: Handler::Kind::Failed, error: "no handler for kind #{job.kind}")
             end
    write_result(job, handler, result)
  rescue e : Exception
    # The outcome write itself failed. The row stays `running`; the lease
    # sweep requeues it when the lease expires.
    Log.error { "Worker could not record the outcome of job #{job.id}: #{e.message}" }
  end

  # Runs one handler execution. An uncaught exception becomes a `Failed`
  # result — the "uncaught handler exception = failure" contract.
  private def run_handler(handler : Handler, job : Job) : Handler::Result
    handler.execute(job)
  rescue e : Exception
    Handler::Result.new(status: Handler::Kind::Failed, error: failure_message(e))
  end

  # The failure text for an uncaught handler exception. A message-less
  # exception (e.g. `DB::ConnectionLost`) would otherwise store `nil` and
  # log an empty suffix; the class name is the floor. A cause's message is
  # appended when present, so a wrapped driver error keeps its detail.
  private def failure_message(e : Exception) : String
    message = e.message.presence || e.class.name
    if cause_message = e.cause.try(&.message.presence)
      message = "#{message}: #{cause_message}"
    end
    message
  end

  private def write_result(job : Job, handler : Handler?, result : Handler::Result) : Nil
    Database.with_db(:read_write) do |db|
      case result.status
      when Handler::Kind::Succeeded
        Metrics.inc("facet_jobs_succeeded_total", {"kind" => job.kind})
        Queries.write_succeeded(db, job.id, http_status: result.http_status, result: result.result)
      when Handler::Kind::Failed
        Metrics.inc("facet_jobs_failed_total", {"kind" => job.kind})
        # One warn line per failed attempt — the row and the caller's
        # notification carry the detail, but a silent terminal answer
        # hides the failure from anyone watching the process log.
        Log.warn { "Job #{job.id} (#{job.kind}) failed: #{result.error}" }
        Queries.write_failed(db, job.id, error: result.error, http_status: result.http_status, backoff_seconds: job.backoff, result: result.result)
      end
      notify_attempt_finished(db, job, handler, result)
    end
  end

  # ── Attempt-hook dispatch ──────────────────────────────────────

  # A raising hook must never break the job outcome: every hook is
  # logged and skipped on error.

  private def notify_attempt_started(db : DB::Connection, job : Job, handler : Handler?) : Nil
    return unless handler
    handler.attempt_started(db, job, job.attempts)
  rescue e : Exception
    Log.error { "Attempt hook failed (started, job #{job.id}): #{e.message}" }
  end

  private def notify_attempt_finished(db : DB::Connection, job : Job, handler : Handler?, result : Handler::Result) : Nil
    return unless handler
    handler.attempt_finished(db, job.id, job.attempts, result)
  rescue e : Exception
    Log.error { "Attempt hook failed (finished, job #{job.id}): #{e.message}" }
  end

  private def notify_attempt_abandoned(db : DB::Connection, swept : Array({id: String, kind: String})) : Nil
    swept.each do |row|
      handler = @handlers[row[:kind]]?.try(&.new)
      next unless handler
      begin
        handler.attempt_abandoned(db, row[:id])
      rescue e : Exception
        Log.error { "Attempt hook failed (abandoned, job #{row[:id]}): #{e.message}" }
      end
    end
  end

  # Prunes every registered handler's attempt log on the queue's
  # retention horizon. A failing prune is logged and skipped.
  private def prune_attempt_logs(db : DB::Connection) : Int32
    pruned = 0
    @handlers.each_value.uniq.each do |klass|
      begin
        pruned += klass.new.prune_expired(db, @retention_days)
      rescue e : Exception
        Log.error { "Attempt-log prune failed: #{e.message}" }
      end
    end
    pruned
  end

  PRUNE_INTERVAL = 3600.seconds
  ZERO_SPAN      = Time::Span.zero
end
