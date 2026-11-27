# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "json"
require "../../src/jobs"

# Mutable clock so specs control when sweeps and prunes fire (mirrors
# spec/cron/scheduler_spec.cr). Job due-ness is decided by PostgreSQL's
# `now()`, so the clock only steers maintenance cadence.
private class SpecClock
  property now : Time

  def initialize(@now : Time = Time.utc)
  end

  def to_proc : Proc(Time)
    -> { @now }
  end
end

# Shared scripted state for the spec doubles. Lives outside the handler
# hierarchy on purpose: Crystal class variables resolve per receiving
# class, so `@@` state on `TestHandler` would fork per subclass and the
# scripting would never reach an inherited `execute`.
module WorkerSpecState
  class_property next_result : Facet::Jobs::Handler::Result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded)
  class_property executions : Int32 = 0
  class_property events : Array(String) = [] of String
  class_property hook_calls : Int32 = 0
  class_property prune_calls : Int32 = 0
  class_property last_retention : Int32? = nil

  def self.reset : Nil
    self.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded)
    self.executions = 0
    self.events = [] of String
    self.hook_calls = 0
    self.prune_calls = 0
    self.last_retention = nil
  end
end

# Stub handler registered on kind "test". Returns the state-module result
# so each spec scripts the outcome before the worker claims a row.
private class TestHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    WorkerSpecState.executions += 1
    WorkerSpecState.next_result
  end
end

# A handler that always raises — exercises the worker's
# "uncaught exception = failure" conversion.
private class ExplodingHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    raise "handler exploded"
  end
end

# A message-less exception, the shape the driver's `DB::ConnectionLost`
# takes. The worker must still record a non-empty reason.
private class WorkerSpecMessageLessError < Exception
end

# Raises the message-less exception — the class name is the only reason.
private class SilentExplodingHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    raise WorkerSpecMessageLessError.new
  end
end

# Raises the message-less exception with a cause — the cause message is
# appended to the class-name floor.
private class CausedExplodingHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    raise WorkerSpecMessageLessError.new(cause: Exception.new("connection reset"))
  end
end

# Records the attempt-lifecycle hooks it observes, in order. Inherits
# `execute` so the scripted outcome still drives the job to completion.
private class RecordingHandler < TestHandler
  def attempt_started(db : DB::Connection, job : Facet::Jobs::Job, attempt : Int32) : Nil
    WorkerSpecState.events << "started:#{job.id}:#{attempt}"
  end

  def attempt_finished(db : DB::Connection, job_id : String, attempt : Int32, result : Facet::Jobs::Handler::Result) : Nil
    WorkerSpecState.events << "finished:#{job_id}:#{attempt}:#{result.status}"
  end

  def attempt_abandoned(db : DB::Connection, job_id : String) : Nil
    WorkerSpecState.events << "abandoned:#{job_id}"
  end
end

# Raises in every hook — the worker must log and skip, never break the
# job outcome.
private class ExplodingHooksHandler < TestHandler
  def attempt_started(db : DB::Connection, job : Facet::Jobs::Job, attempt : Int32) : Nil
    WorkerSpecState.hook_calls += 1
    raise "hook exploded"
  end

  def attempt_finished(db : DB::Connection, job_id : String, attempt : Int32, result : Facet::Jobs::Handler::Result) : Nil
    WorkerSpecState.hook_calls += 1
    raise "hook exploded"
  end

  def attempt_abandoned(db : DB::Connection, job_id : String) : Nil
    WorkerSpecState.hook_calls += 1
    raise "hook exploded"
  end
end

# Counts `prune_expired` invocations and the retention horizon it got.
# The attempt hooks keep the no-op defaults.
private class PruneCountingHandler < TestHandler
  def prune_expired(db : DB::Connection, retention_days : Int32) : Int32
    WorkerSpecState.prune_calls += 1
    WorkerSpecState.last_retention = retention_days
    0
  end
end

# Holds every execution until released, so a spec can park jobs in the
# running state and observe the concurrency gate. Counts concurrent runs.
# A closed channel releases every waiter at once, so one `close` drains a
# whole gate in an `ensure` block.
#
# One instance per example. A fiber left over from the previous example
# keeps the instance it captured at `execute` time, so it can no longer
# write into the counters of the example that follows.
class BlockingState
  getter entered : Int32 = 0
  getter peak : Int32 = 0
  getter release = Channel(Nil).new

  def initialize
  end

  def enter : Nil
    @entered += 1
    @peak = @entered if @entered > @peak
  end

  def leave : Nil
    @entered -= 1
  end

  def unblock : Nil
    release.close
  end
end

# The state the handlers of the running example block on. The worker builds
# handlers with a zero-argument `.new`, so the current example publishes its
# own instance here; a fiber from a finished example keeps the reference it
# read when it started.
module BlockingRegistry
  class_property current : BlockingState = BlockingState.new
end

private class BlockingHandler < Facet::Jobs::Handler
  def execute(job : Facet::Jobs::Job) : Facet::Jobs::Handler::Result
    state = BlockingRegistry.current
    state.enter
    begin
      state.release.receive?
    ensure
      state.leave
    end
    Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Succeeded)
  end
end

# Fake liveness for specs. Refreshes are counted; instances named in
# `dead` answer not alive, every other instance answers alive.
private class SpecLiveness
  include Facet::Jobs::Liveness

  property dead : Array(String) = [] of String
  getter refreshes : Int32 = 0

  def refresh(instance_id : String) : Nil
    @refreshes += 1
  end

  def alive?(instance_id : String) : Bool
    !@dead.includes?(instance_id)
  end
end

private def wait_until(timeout : Time::Span = 5.seconds, &cond : -> Bool) : Bool
  deadline = Time.utc + timeout
  loop do
    return true if cond.call
    return false if Time.utc >= deadline
    Fiber.yield
    sleep 10.milliseconds
  end
end

# Lets pending loop/job fibers run to a quiet point without asserting
# anything. Used to drain an in-flight tick before a stop-related assert.
private def enqueue_row(db : DB::Connection, kind : String = "test", *, max_attempts : Int32? = nil, backoff : Array(Int32)? = nil, run_after : Time? = nil) : String
  id = Facet::Util::ScriptHelpers.ulid
  payload = JSON.parse(%({"n": "#{id}"}))
  Facet::Jobs::Queries.insert(db, id, kind, payload, max_attempts: max_attempts, backoff: backoff, run_after: run_after)
  id
end

private def job_row(db : DB::Connection, id : String)
  db.query_one?(
    "SELECT status, attempts, run_after, last_error, last_http_status
     FROM background_jobs WHERE id = $1",
    id,
  ) do |rs|
    {
      status:           rs.read(String),
      attempts:         rs.read(Int32),
      run_after:        rs.read(Time?),
      last_error:       rs.read(String?),
      last_http_status: rs.read(Int32?),
    }
  end
end

private def status_of(db : DB::Connection, id : String) : String?
  job_row(db, id).try(&.[:status])
end

private def attempts_of(db : DB::Connection, id : String) : Int32?
  job_row(db, id).try(&.[:attempts])
end

private def new_worker(*, poll_interval_s : Float64 = 60.0, sweep_interval_s : Float64 = 30.0, handlers : Hash(String, Facet::Jobs::Handler.class) = {"test" => TestHandler} of String => Facet::Jobs::Handler.class, liveness : Facet::Jobs::Liveness? = nil) : Facet::Jobs::Worker
  # The fake liveness keeps every example Redis-free; the examples that
  # script a dead owner pass their own `SpecLiveness`.
  Facet::Jobs::Worker.new(
    poll_interval_s: poll_interval_s,
    sweep_interval_s: sweep_interval_s,
    handlers: handlers,
    liveness: liveness || SpecLiveness.new,
  )
end

private def stop_worker(worker : Facet::Jobs::Worker) : Nil
  worker.stop
  # `running?` flips synchronously in `stop`; the loop fiber exits on its
  # next select turn, so also wait for its death. `stop` does not cancel
  # in-flight job fibers, so wait for them too: a survivor would claim
  # rows of the next example and run them under this worker's gate.
  wait_until { !worker.running? && worker.loop_fiber.try(&.dead?) == true && worker.in_flight.zero? }
  nil
end

describe Facet::Jobs::Worker do
  before_each do
    # `background_jobs` (and any attempt-log tables) are not in the global
    # truncation list; each spec cleans up its own rows.
    with_db do |db|
      db.exec("DELETE FROM background_jobs")
      db.exec("DELETE FROM webhook_calls")
    end
    WorkerSpecState.reset
    Facet::Metrics.reset
  end

  describe "#enqueue / #start" do
    it "executes an enqueued job and writes succeeded" do
      with_db do |db|
        worker = new_worker
        id = worker.enqueue(db, "test", JSON.parse(%({"n": 1})))

        worker.start
        wait_until { status_of(db, id) == "succeeded" }.should be_true

        row = job_row(db, id).not_nil!
        row[:attempts].should eq 1
        row[:run_after].should be_nil
        stop_worker(worker)
      end
    end

    it "returns the new row id and leaves the row pending" do
      with_db do |db|
        worker = new_worker
        id = worker.enqueue(db, "test", JSON.parse(%({"n": 1})))
        row = job_row(db, id).not_nil!
        row[:status].should eq "pending"
        row[:attempts].should eq 0
      end
    end

    it "persists the handler's result payload on the terminal row" do
      with_db do |db|
        result = JSON.parse(%({"artifact_id": "01JART", "row_count": 7, "format": "json"}))
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(
          status: Facet::Jobs::Handler::Kind::Succeeded, result: result,
        )
        worker = new_worker
        id = worker.enqueue(db, "test", JSON.parse(%({"n": 1})))

        worker.start
        wait_until { status_of(db, id) == "succeeded" }.should be_true
        stop_worker(worker)

        outcome = Facet::Jobs::Queries.find_outcome(db, id).not_nil!
        outcome.result.not_nil!["artifact_id"].as_s.should eq "01JART"
        outcome.result.not_nil!["row_count"].as_i.should eq 7
      end
    end
  end

  describe "retry semantics" do
    it "requeues a failed job with run_after pushed out while attempts remain" do
      with_db do |db|
        worker = new_worker
        id = enqueue_row(db, max_attempts: 3, backoff: [3600, 7200])
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "boom")
        worker.start

        wait_until { attempts_of(db, id) == 1 }.should be_true
        row = job_row(db, id).not_nil!
        row[:status].should eq "pending"
        row[:last_error].should eq "boom"
        row[:run_after].should_not be_nil
        row[:run_after].not_nil!.should be > Time.utc + 3500.seconds

        # A later tick does not re-claim the row while run_after is in
        # the future. The tick-count advance proves one full claim pass
        # ran after the wake, so the unchanged attempts count below is
        # structural, not a timing guess.
        ticks_before = worker.tick_count
        worker.wake
        wait_until { worker.tick_count > ticks_before }.should be_true
        attempts_of(db, id).should eq 1
        stop_worker(worker)
      end
    end

    it "marks a job failed after max_attempts is reached" do
      with_db do |db|
        worker = new_worker
        # nil backoff retries immediately, so attempts 1 and 2 land in
        # quick succession.
        id = enqueue_row(db, max_attempts: 2, backoff: nil)
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "still down")
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        row = job_row(db, id).not_nil!
        row[:attempts].should eq 2
        row[:last_error].should eq "still down"
        row[:run_after].should be_nil
        stop_worker(worker)
      end
    end

    it "fails a non-retryable job on the first attempt" do
      with_db do |db|
        worker = new_worker
        id = enqueue_row(db, max_attempts: 1)
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "no retry")
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        row = job_row(db, id).not_nil!
        row[:attempts].should eq 1
        row[:last_error].should eq "no retry"
        row[:run_after].should be_nil
        stop_worker(worker)
      end
    end

    it "treats an uncaught handler exception as a failure" do
      with_db do |db|
        worker = new_worker(handlers: {"test" => ExplodingHandler} of String => Facet::Jobs::Handler.class)
        id = enqueue_row(db, max_attempts: 1)
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        row = job_row(db, id).not_nil!
        row[:attempts].should eq 1
        row[:last_error].should eq "handler exploded"
        row[:run_after].should be_nil
        # The loop survives the exception.
        worker.running?.should be_true
        stop_worker(worker)
      end
    end

    it "records the exception class name when the exception has no message" do
      with_db do |db|
        worker = new_worker(handlers: {"test" => SilentExplodingHandler} of String => Facet::Jobs::Handler.class)
        id = enqueue_row(db, max_attempts: 1)
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        job_row(db, id).not_nil![:last_error].should eq "WorkerSpecMessageLessError"
        stop_worker(worker)
      end
    end

    it "appends the cause message when the exception has one" do
      with_db do |db|
        worker = new_worker(handlers: {"test" => CausedExplodingHandler} of String => Facet::Jobs::Handler.class)
        id = enqueue_row(db, max_attempts: 1)
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        job_row(db, id).not_nil![:last_error].should eq "WorkerSpecMessageLessError: connection reset"
        stop_worker(worker)
      end
    end

    it "fails a job whose kind has no registered handler" do
      with_db do |db|
        worker = new_worker
        id = enqueue_row(db, "mystery")
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        job_row(db, id).not_nil![:last_error].should eq "no handler for kind mystery"
        stop_worker(worker)
      end
    end
  end

  describe "claim gating" do
    it "does not claim a job whose run_after is in the future" do
      with_db do |db|
        worker = new_worker
        future_id = enqueue_row(db, run_after: Time.utc + 1.hour)
        due_id = enqueue_row(db)
        worker.start

        # The due row succeeding proves ticks ran.
        wait_until { status_of(db, due_id) == "succeeded" }.should be_true
        row = job_row(db, future_id).not_nil!
        row[:status].should eq "pending"
        row[:attempts].should eq 0
        stop_worker(worker)
      end
    end
  end

  describe "lifecycle" do
    it "does not pick up jobs enqueued after stop" do
      worker = new_worker
      worker.start
      # `stop_worker` waits for the loop fiber to die, so the loop can no
      # longer observe anything this example enqueues.
      stop_worker(worker)

      with_db do |db|
        id = enqueue_row(db)
        worker.wake # no-op: the loop has exited
        wait_until(0.5.seconds) { (attempts_of(db, id) || 0) > 0 }.should be_false
        job_row(db, id).not_nil![:status].should eq "pending"
      end
    end

    it "resumes after a stop/start cycle" do
      with_db do |db|
        worker = new_worker
        worker.start
        stop_worker(worker)

        worker.start
        worker.running?.should be_true
        id = enqueue_row(db)
        # The loop may already be in its 60 s poll sleep, so wake it — the
        # same contract `Manager#enqueue` uses in production.
        worker.wake
        wait_until { status_of(db, id) == "succeeded" }.should be_true
        stop_worker(worker)
      end
    end
  end

  describe "attempt hooks" do
    it "invokes started and finished per attempt, in order" do
      with_db do |db|
        # nil backoff retries immediately, so both attempts land in quick
        # succession.
        id = enqueue_row(db, max_attempts: 2, backoff: nil)
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "boom")
        worker = new_worker(handlers: {"test" => RecordingHandler} of String => Facet::Jobs::Handler.class)
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        wait_until { WorkerSpecState.events.size == 4 }.should be_true
        WorkerSpecState.events.should eq([
          "started:#{id}:1",
          "finished:#{id}:1:Failed",
          "started:#{id}:2",
          "finished:#{id}:2:Failed",
        ])
        stop_worker(worker)
      end
    end

    it "a raising hook never breaks the job outcome" do
      with_db do |db|
        id = enqueue_row(db, max_attempts: 1)
        worker = new_worker(handlers: {"test" => ExplodingHooksHandler} of String => Facet::Jobs::Handler.class)
        worker.start

        wait_until { status_of(db, id) == "succeeded" }.should be_true
        WorkerSpecState.hook_calls.should be >= 2
        job_row(db, id).not_nil![:attempts].should eq(1)
        stop_worker(worker)
      end
    end

    it "fires the abandoned hook from the lease sweep, before the re-claim" do
      with_db do |db|
        id = enqueue_row(db)
        claimed = Facet::Jobs::Queries.claim(db, "manual-claimer", 60, 10)
        claimed.size.should eq(1)

        db.exec("UPDATE background_jobs SET locked_until = now() - interval '1 second' WHERE id = $1", id)

        worker = new_worker(handlers: {"test" => RecordingHandler} of String => Facet::Jobs::Handler.class)
        worker.start # the first tick always runs one sweep

        wait_until { status_of(db, id) == "succeeded" }.should be_true
        events = WorkerSpecState.events
        abandoned_at = events.index!("abandoned:#{id}")
        started_second_at = events.index!(&.starts_with?("started:#{id}:2"))
        abandoned_at.should be < started_second_at
        stop_worker(worker)
      end
    end
  end

  describe "concurrency gate" do
    it "runs at most max_concurrent jobs at once" do
      with_db do |db|
        state = BlockingState.new
        BlockingRegistry.current = state
        4.times { enqueue_row(db) }
        worker = Facet::Jobs::Worker.new(
          poll_interval_s: 0.01,
          max_concurrent: 2,
          handlers: {"test" => BlockingHandler} of String => Facet::Jobs::Handler.class,
          liveness: SpecLiveness.new,
        )
        begin
          worker.start

          # The gate's contract is the ceiling: however many jobs are due,
          # never more than `max_concurrent` run at once. The spec asserts
          # that ceiling and that the worker does claim, not a fixed count
          # of entrants — another worker from a different spec may hold a
          # row of this table, and the claim is global by design (there is
          # no kind filter).
          wait_until { state.peak >= 1 }.should be_true
          sleep 100.milliseconds
          state.peak.should be <= 2
          db.query_one("SELECT COUNT(*) FROM background_jobs WHERE status = 'running'", as: Int64).should be <= 2

          # Releasing lets the held passes claim the rest, two at a time.
          state.unblock
          wait_until { db.query_one("SELECT COUNT(*) FROM background_jobs WHERE status = 'succeeded'", as: Int64) == 4 }.should be_true
          state.peak.should be <= 2
        ensure
          state.unblock
          stop_worker(worker)
        end
      end
    end

    it "stop releases a claim pass parked on a full gate" do
      with_db do |db|
        state = BlockingState.new
        BlockingRegistry.current = state
        3.times { enqueue_row(db) }
        worker = Facet::Jobs::Worker.new(
          poll_interval_s: 0.01,
          max_concurrent: 1,
          handlers: {"test" => BlockingHandler} of String => Facet::Jobs::Handler.class,
          liveness: SpecLiveness.new,
        )
        begin
          worker.start
          wait_until { state.entered >= 1 }.should be_true

          # The loop is parked in `await_slots`; `stop` must wake it so the
          # loop fiber exits instead of holding the fiber until the job ends.
          worker.stop
          wait_until { worker.loop_fiber.try(&.dead?) == true }.should be_true
        ensure
          # Release the parked job fiber, then wait for it so it cannot
          # claim rows of the next example.
          state.unblock
          stop_worker(worker)
        end
      end
    end
  end

  describe "attempt-log prune" do
    it "delegates the prune pass to handlers with the queue's retention horizon" do
      worker = new_worker(handlers: {"test" => PruneCountingHandler} of String => Facet::Jobs::Handler.class)
      worker.start

      # The first tick always runs one prune pass.
      wait_until { WorkerSpecState.prune_calls > 0 }.should be_true
      WorkerSpecState.last_retention.should eq(30)
      stop_worker(worker)
    end
  end

  describe "lease sweep" do
    it "requeues a row with an expired lease and re-executes it" do
      with_db do |db|
        worker = new_worker
        id = enqueue_row(db)
        claimed = Facet::Jobs::Queries.claim(db, "manual-claimer", 60, 10)
        claimed.size.should eq 1

        db.exec("UPDATE background_jobs SET locked_until = now() - interval '1 second' WHERE id = $1", id)
        job_row(db, id).not_nil![:status].should eq "running"

        worker.start # the first tick always runs one sweep

        wait_until { status_of(db, id) == "succeeded" }.should be_true
        # Two claims: the manual one and the worker's. The sweep itself
        # does not increment `attempts`.
        attempts_of(db, id).should eq 2
        stop_worker(worker)
      end
    end
  end

  describe "owner liveness sweep" do
    it "refreshes the instance liveness key on each sweep tick" do
      with_db do
        liveness = SpecLiveness.new
        worker = new_worker(liveness: liveness)
        worker.start # the first tick always runs one sweep

        wait_until { liveness.refreshes > 0 }.should be_true
        stop_worker(worker)
      end
    end

    it "requeues a row owned by a dead instance while its lease is valid" do
      with_db do |db|
        id = enqueue_row(db)
        claimed = Facet::Jobs::Queries.claim(db, "dead-instance:worker-1", 3600, 10)
        claimed.size.should eq 1

        liveness = SpecLiveness.new
        liveness.dead = ["dead-instance"]
        worker = new_worker(handlers: {"test" => RecordingHandler} of String => Facet::Jobs::Handler.class, liveness: liveness)
        worker.start # the first tick always runs one sweep

        wait_until { status_of(db, id) == "succeeded" }.should be_true
        attempts_of(db, id).should eq 2
        events = WorkerSpecState.events
        abandoned_at = events.index!("abandoned:#{id}")
        started_second_at = events.index!(&.starts_with?("started:#{id}:2"))
        abandoned_at.should be < started_second_at
        stop_worker(worker)
      end
    end

    it "does not requeue a live owner's row while its lease is valid" do
      with_db do |db|
        id = enqueue_row(db)
        claimed = Facet::Jobs::Queries.claim(db, "live-instance:worker-1", 3600, 10)
        claimed.size.should eq 1

        worker = new_worker
        worker.start

        # One full tick ran; the sweep touched nothing.
        wait_until { worker.tick_count > 0 }.should be_true
        job_row(db, id).not_nil![:status].should eq "running"
        attempts_of(db, id).should eq 1
        stop_worker(worker)
      end
    end

    it "marks a dead-owner row failed when the retry cap is reached" do
      with_db do |db|
        id = enqueue_row(db, max_attempts: 1)
        claimed = Facet::Jobs::Queries.claim(db, "dead-instance:worker-1", 3600, 10)
        claimed.size.should eq 1

        liveness = SpecLiveness.new
        liveness.dead = ["dead-instance"]
        worker = new_worker(handlers: {"test" => RecordingHandler} of String => Facet::Jobs::Handler.class, liveness: liveness)
        worker.start

        wait_until { status_of(db, id) == "failed" }.should be_true
        row = job_row(db, id).not_nil!
        row[:attempts].should eq 1
        row[:run_after].should be_nil
        row[:last_error].should eq Facet::Jobs::Queries::ABANDONED_ERROR
        WorkerSpecState.events.should contain("abandoned:#{id}")
        stop_worker(worker)
      end
    end
  end

  describe "metrics counters" do
    it "counts enqueue, claim, and success per kind" do
      with_db do |db|
        worker = new_worker
        id = worker.enqueue(db, "test", JSON.parse(%({"n": 1})))
        Facet::Metrics.value("facet_jobs_enqueued_total", {"kind" => "test"}).should eq(1.0)

        worker.start
        wait_until { status_of(db, id) == "succeeded" }.should be_true
        stop_worker(worker)

        Facet::Metrics.value("facet_jobs_claimed_total", {"kind" => "test"}).should eq(1.0)
        Facet::Metrics.value("facet_jobs_succeeded_total", {"kind" => "test"}).should eq(1.0)
        Facet::Metrics.value("facet_jobs_failed_total", {"kind" => "test"}).should eq(0.0)
        Facet::Metrics.value("facet_jobs_abandoned_total", {"kind" => "test"}).should eq(0.0)
      end
    end

    it "counts a failed attempt per kind" do
      with_db do |db|
        WorkerSpecState.next_result = Facet::Jobs::Handler::Result.new(status: Facet::Jobs::Handler::Kind::Failed, error: "boom")
        worker = new_worker
        id = worker.enqueue(db, "test", JSON.parse(%({"n": 1})), max_attempts: 1)

        worker.start
        wait_until { status_of(db, id) == "failed" }.should be_true
        stop_worker(worker)

        Facet::Metrics.value("facet_jobs_failed_total", {"kind" => "test"}).should eq(1.0)
        Facet::Metrics.value("facet_jobs_succeeded_total", {"kind" => "test"}).should eq(0.0)
      end
    end

    it "counts a lease-swept row as abandoned" do
      with_db do |db|
        id = enqueue_row(db)
        claimed = Facet::Jobs::Queries.claim(db, "manual-claimer", 60, 10)
        claimed.size.should eq(1)
        db.exec("UPDATE background_jobs SET locked_until = now() - interval '1 second' WHERE id = $1", id)

        worker = new_worker
        worker.start # the first tick always runs one sweep

        wait_until { status_of(db, id) == "succeeded" }.should be_true
        stop_worker(worker)

        Facet::Metrics.value("facet_jobs_abandoned_total", {"kind" => "test"}).should eq(1.0)
      end
    end
  end

  describe "multi-worker claim isolation" do
    it "two workers on the same database claim disjoint rows" do
      with_db do |db|
        10.times do
          enqueue_row(db)
        end

        a = new_worker(poll_interval_s: 0.01)
        b = new_worker(poll_interval_s: 0.01)
        a.start
        b.start

        all_done = wait_until do
          with_db do |c|
            c.query_one(
              "SELECT count(*) FROM background_jobs WHERE status = 'succeeded'",
              &.read(Int64)
            ) == 10
          end
        end
        all_done.should be_true

        # No row was claimed twice (a double claim shows as attempts > 1).
        double_claimed = with_db do |c|
          c.query_all("SELECT id FROM background_jobs WHERE attempts > 1", as: String)
        end
        double_claimed.should be_empty

        stop_worker(a)
        stop_worker(b)
      end
    end
  end
end
