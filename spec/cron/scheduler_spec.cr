# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/cron"

# Helper: a mutable clock used by the scheduler specs so determinism does not
# depend on wall-clock minute boundaries.
private class FakeClock
  property now : Time

  def initialize(@now : Time)
  end

  def to_proc : Proc(Time)
    -> { @now }
  end
end

# Wait helper：cooperatively yields until `cond` returns true or the timeout
# elapses. Mirrors `Index::Manager.wait_for_pending_fibers` semantics.
private def wait_until(timeout : Time::Span = 5.seconds, &cond : -> Bool) : Bool
  deadline = Time.utc + timeout
  loop do
    return true if cond.call
    return false if Time.utc >= deadline
    Fiber.yield
    sleep 10.milliseconds
  end
end

describe Facet::Cron::Scheduler do
  it "computes next_run and registers a task" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    next_run = scheduler.register("test", "30 5 * * *") { }
    next_run.should eq Time.utc(2024, 1, 1, 5, 30, 0)
    scheduler.tasks.size.should eq 1
    scheduler.tasks.first.id.should eq "test"
  end

  it "keeps tasks sorted by next_run" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    scheduler.register("later", "30 5 * * *") { }
    scheduler.register("earlier", "15 5 * * *") { }

    scheduler.tasks.map(&.id).should eq ["earlier", "later"]
  end

  it "replaces a task registered with an existing id" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    fired = [] of String
    scheduler.register("t1", "0 6 * * *") { fired << "first" }
    scheduler.register("t1", "0 7 * * *") { fired << "second" }

    scheduler.tasks.size.should eq 1
    scheduler.tasks.first.next_run.should eq Time.utc(2024, 1, 1, 7, 0, 0)
  end

  it "unregisters a task by id" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)
    scheduler.register("t1", "0 6 * * *") { }

    scheduler.unregister("t1").should be_true
    scheduler.tasks.should be_empty
    scheduler.unregister("t1").should be_false
  end

  it "fires a due task in its own fiber" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    fired = Channel(Nil).new
    next_run = scheduler.register("t1", "30 5 * * *") do
      fired.send(nil)
    end

    # Advance the clock past the fire time, then start. The loop's first
    # `compute_sleep_span` sees `next_run <= now` and fires immediately.
    clock.now = next_run + 1.second
    scheduler.start

    fired.receive.should be_nil
    scheduler.stop
  end

  it "isolates task failures: a raising task does not crash the loop" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    fired = Channel(Nil).new
    next_run = scheduler.register("failing", "30 5 * * *") do
      raise "boom"
    end
    scheduler.register("survivor", "30 5 * * *") do
      fired.send(nil)
    end

    clock.now = next_run + 1.second
    scheduler.start

    fired.receive.should be_nil
    scheduler.running?.should be_true
    scheduler.stop
  end

  it "counts a failed task fire per task id" do
    Facet::Metrics.reset
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    fired = Channel(Nil).new
    next_run = scheduler.register("failing", "30 5 * * *") do
      raise "boom"
    end
    scheduler.register("survivor", "30 5 * * *") do
      fired.send(nil)
    end

    clock.now = next_run + 1.second
    scheduler.start

    fired.receive.should be_nil
    scheduler.stop

    # The failing task's own fiber increments the counter in its rescue —
    # relative order with the survivor's fiber is not guaranteed, so wait
    # for it instead of racing.
    wait_until { Facet::Metrics.value("facet_cron_task_failures_total", {"task" => "failing"}) >= 1.0 }.should be_true
  end

  it "advances next_run after firing and does not refire immediately" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)
    fire_count = 0

    next_run = scheduler.register("t1", "30 5 * * *") do
      fire_count += 1
    end

    # Bring the clock just past next_run so the task fires once.
    fire_time = next_run + 1.second
    clock.now = fire_time
    scheduler.start

    wait_until { fire_count >= 1 }.should be_true
    fire_count.should eq 1

    # At dispatch the loop advances `next_run` to `parser.next(fire_time)` —
    # the next day 05:30, strictly after `fire_time`. The `FakeClock` stays
    # frozen, so `compute_sleep_span` is always positive and a refire needs
    # a clock advance — no wall-clock wait is needed.
    rescheduled = wait_until do
      task_next_run = scheduler.tasks.first?.try(&.next_run)
      !task_next_run.nil? && task_next_run > fire_time
    end
    rescheduled.should be_true
    fire_count.should eq 1

    scheduler.stop
  end

  it "does not re-dispatch a slow task while it is still running" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    started = Channel(Nil).new
    release = Channel(Nil).new
    fire_count = Atomic(Int32).new(0)

    next_run = scheduler.register("slow", "30 5 * * *") do
      fire_count.add(1)
      started.send(nil)
      release.receive
    end

    clock.now = next_run + 1.second
    scheduler.start

    started.receive.should be_nil

    # The block is provably still running (blocked on `release`). The loop
    # advanced `next_run` synchronously at dispatch, so the frozen clock can
    # never make the task due again; the old stale-`next_run` race left
    # `next_run` at the fire time and re-dispatched the task concurrently.
    scheduler.tasks.first.next_run.should be > next_run
    fire_count.get.should eq 1

    release.send(nil)
    scheduler.stop
  end

  it "keeps a task unregistered while its block is still running" do
    clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
    scheduler = Facet::Cron::Scheduler.new(clock.to_proc)

    started = Channel(Nil).new
    release = Channel(Nil).new
    next_run = scheduler.register("t1", "30 5 * * *") do
      started.send(nil)
      release.receive
    end

    clock.now = next_run + 1.second
    scheduler.start

    started.receive.should be_nil
    scheduler.unregister("t1").should be_true
    scheduler.tasks.should be_empty

    # Let the in-flight block unwind. The old dispatch-time `ensure`
    # reschedule re-inserted the task right here — after `unregister`
    # removed it. `in_flight` clears in the same ensure scope, so once the
    # id is gone, any bookkeeping has already run.
    release.send(nil)
    wait_until { !scheduler.in_flight.includes?("t1") }.should be_true
    scheduler.tasks.should be_empty

    scheduler.stop
  end

  it "start is idempotent and stop is idempotent" do
    scheduler = Facet::Cron::Scheduler.new

    scheduler.start
    scheduler.running?.should be_true
    scheduler.start # no-op
    scheduler.running?.should be_true

    scheduler.stop
    scheduler.running?.should be_false
    scheduler.stop # no-op
    scheduler.running?.should be_false
  end

  describe "once-per-cluster tick lease" do
    it "fires the task when the lease is won" do
      clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      scheduler = Facet::Cron::Scheduler.new(
        clock.to_proc,
        acquire_lease: ->(_key : String, _ttl : Int32, _owner : String) { true },
      )

      fired = Channel(Nil).new
      next_run = scheduler.register("t1", "30 5 * * *") { fired.send(nil) }

      clock.now = next_run + 1.second
      scheduler.start

      fired.receive.should be_nil
      scheduler.stop
    end

    it "skips the fire and counts a skip when the lease is lost" do
      Facet::Metrics.reset
      clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      scheduler = Facet::Cron::Scheduler.new(
        clock.to_proc,
        acquire_lease: ->(_key : String, _ttl : Int32, _owner : String) { false },
      )

      fire_count = Atomic(Int32).new(0)
      next_run = scheduler.register("t1", "30 5 * * *") { fire_count.add(1) }

      clock.now = next_run + 1.second
      scheduler.start

      # The single due tick dispatches once: the lease stays lost, the block
      # never runs, and `fire_due` advances `next_run` past the frozen clock
      # — no further dispatch can occur. A re-dispatch bug would keep the
      # skip counter climbing past 1.
      wait_until do
        Facet::Metrics.value("facet_cron_task_lease_skips_total", {"task" => "t1"}) >= 1.0
      end.should be_true
      fire_count.get.should eq 0
      Facet::Metrics.value("facet_cron_task_lease_skips_total", {"task" => "t1"}).should eq 1.0

      scheduler.stop
    end

    it "leases with a per-task, per-tick key, the fixed TTL, and the service id" do
      clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      keys = Array(String).new
      ttls = Array(Int32).new
      owners = Array(String).new
      acquirer = ->(key : String, ttl : Int32, owner : String) : Bool do
        keys << key
        ttls << ttl
        owners << owner
        true
      end
      scheduler = Facet::Cron::Scheduler.new(
        clock.to_proc,
        acquire_lease: acquirer,
        service_id: "spec-instance",
      )

      fired = Channel(Nil).new
      next_run = scheduler.register("t1", "30 5 * * *") { fired.send(nil) }

      clock.now = next_run + 1.second
      scheduler.start

      fired.receive.should be_nil
      scheduler.stop

      keys.should eq ["cron:lease:t1:#{next_run.to_unix}"]
      ttls.should eq [Facet::Cron::Scheduler::LEASE_TTL_S]
      owners.should eq ["spec-instance"]
    end

    it "fires a tick exactly once across two schedulers sharing the lease store" do
      # Atomic SET NX stand-in: first caller wins the key, everyone else
      # loses. The mutex mirrors the single-threaded atomicity of Redis.
      leased = Set(String).new
      mutex = Mutex.new
      acquirer = ->(key : String, _ttl : Int32, _owner : String) : Bool do
        mutex.synchronize do
          next false if leased.includes?(key)
          leased.add(key)
          true
        end
      end

      clock_a = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      clock_b = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      count = Atomic(Int32).new(0)
      a = Facet::Cron::Scheduler.new(clock_a.to_proc, acquire_lease: acquirer)
      b = Facet::Cron::Scheduler.new(clock_b.to_proc, acquire_lease: acquirer)

      next_run = a.register("t1", "30 5 * * *") { count.add(1) }
      b.register("t1", "30 5 * * *") { count.add(1) }

      clock_a.now = next_run + 1.second
      clock_b.now = next_run + 1.second
      a.start
      b.start

      wait_until { count.get >= 1 }.should be_true
      # Both loops advanced `next_run` past their frozen clocks at dispatch:
      # the winner fired, the loser skipped. No second dispatch of the tick
      # is possible without a clock advance.
      count.get.should eq 1

      a.stop
      b.stop
    end

    it "leases each tick separately — the next tick fires again" do
      clock = FakeClock.new(Time.utc(2024, 1, 1, 0, 0, 0))
      leased = Set(String).new
      mutex = Mutex.new
      acquirer = ->(key : String, _ttl : Int32, _owner : String) : Bool do
        mutex.synchronize do
          next false if leased.includes?(key)
          leased.add(key)
          true
        end
      end
      scheduler = Facet::Cron::Scheduler.new(clock.to_proc, acquire_lease: acquirer)

      fire_count = Atomic(Int32).new(0)
      # A six-field every-second expression: the loop's wall-clock sleep
      # between ticks is at most one second, so a frozen FakeClock advance
      # between ticks is observed without a long wait.
      next_run = scheduler.register("t1", "* * * * * *") { fire_count.add(1) }

      # First tick fires...
      clock.now = next_run + 0.5.seconds
      scheduler.start
      wait_until { fire_count.get >= 1 }.should be_true

      # ...and the loop re-armed to the next second — its own lease key.
      clock.now = next_run + 1.5.seconds
      wait_until { fire_count.get >= 2 }.should be_true

      # The clock stays frozen before the third tick boundary, so no third
      # fire can occur without a clock advance.
      fire_count.get.should eq 2
      leased.size.should eq 2

      scheduler.stop
    end
  end
end
