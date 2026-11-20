# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/fiber_supervisor"
require "../../src/metrics"

# Polls `&` until it returns truthy or the timeout elapses. Local helper —
# this is a pure unit spec and does not load the suite's spec_helper.
private def wait_until(timeout : Time::Span = 2.seconds, & : -> T) : T? forall T
  deadline = Time.instant + timeout
  loop do
    value = yield
    return value if value
    break if Time.instant >= deadline
    sleep(1.millisecond)
  end
  nil
end

describe Facet::Util::FiberSupervisor do
  describe ".supervise" do
    it "reruns a block that raises and stops on normal return" do
      runs = Atomic(Int32).new(0)
      restarts = Atomic(Int32).new(0)
      stopped = Channel(Nil).new

      Facet::Util::FiberSupervisor.supervise(
        "spec: raising block",
        backoff: Facet::Util::FiberSupervisor::Backoff.new(initial: 1.millisecond, cap: 2.milliseconds),
        on_restart: -> { restarts.add(1); nil },
        on_stop: -> { stopped.send(nil) }
      ) do
        raise "boom" if runs.add(1) < 2
      end

      wait_until { runs.get >= 3 }.should be_truthy
      restarts.get.should eq(2)

      # The third run returned normally — on_stop marks the end of
      # supervision, so no further run can follow it.
      stopped.receive.should be_nil
      runs.get.should eq(3)
      restarts.get.should eq(2)
    end

    it "returns the supervisor fiber and counts restarts on the metric" do
      Facet::Metrics.reset
      runs = Atomic(Int32).new(0)
      stopped = Channel(Nil).new

      fiber = Facet::Util::FiberSupervisor.supervise(
        "spec: metric block",
        backoff: Facet::Util::FiberSupervisor::Backoff.new(initial: 1.millisecond, cap: 2.milliseconds),
        on_stop: -> { stopped.send(nil) }
      ) do
        raise "boom" if runs.add(1) < 2
      end

      fiber.should be_a(Fiber)
      wait_until { runs.get >= 3 }.should be_truthy
      Facet::Metrics.value("facet_fiber_restarts_total", {"fiber" => "spec: metric block"}).should eq(2.0)

      # A clean stop adds no restarts: on_stop marks the end of supervision.
      stopped.receive.should be_nil
      Facet::Metrics.value("facet_fiber_restarts_total", {"fiber" => "spec: metric block"}).should eq(2.0)
    end

    it "runs a block that returns without raising exactly once" do
      runs = Atomic(Int32).new(0)
      restarts = Atomic(Int32).new(0)
      stopped = Channel(Nil).new

      Facet::Util::FiberSupervisor.supervise(
        "spec: clean block",
        on_restart: -> { restarts.add(1); nil },
        on_stop: -> { stopped.send(nil) }
      ) do
        runs.add(1)
        nil
      end

      stopped.receive.should be_nil
      runs.get.should eq(1)
      restarts.get.should eq(0)
    end
  end

  describe "Backoff" do
    it "grows exponentially and caps" do
      backoff = Facet::Util::FiberSupervisor::Backoff.new(initial: 100.milliseconds, factor: 2.0, cap: 300.milliseconds)
      backoff.next.should eq(100.milliseconds)
      backoff.next.should eq(200.milliseconds)
      backoff.next.should eq(300.milliseconds)
      backoff.next.should eq(300.milliseconds)
    end

    it "resets to the initial delay" do
      backoff = Facet::Util::FiberSupervisor::Backoff.new(initial: 100.milliseconds, factor: 2.0, cap: 1.second)
      backoff.next
      backoff.next
      backoff.reset
      backoff.next.should eq(100.milliseconds)
    end
  end
end
