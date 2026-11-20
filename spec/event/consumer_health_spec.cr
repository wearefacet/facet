# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/event/consumer_health"

describe Facet::Event::ConsumerHealth do
  after_each do
    Facet::Event::ConsumerHealth.reset
  end

  describe "registration" do
    it "registers and unregisters consumers" do
      Facet::Event::ConsumerHealth.register("cg:spec:a")
      Facet::Event::ConsumerHealth.snapshot.map(&.[:name]).should eq(["cg:spec:a"])

      Facet::Event::ConsumerHealth.unregister("cg:spec:a")
      Facet::Event::ConsumerHealth.snapshot.should be_empty
    end

    it "keeps the existing state on re-registration" do
      Facet::Event::ConsumerHealth.register("cg:spec:a")
      Facet::Event::ConsumerHealth.report_restart("cg:spec:a")
      Facet::Event::ConsumerHealth.register("cg:spec:a")

      entry = Facet::Event::ConsumerHealth.snapshot.first
      entry[:restarts].should eq(1)
    end

    it "ignores unknown keys" do
      Facet::Event::ConsumerHealth.unregister("unknown")
      Facet::Event::ConsumerHealth.report_failure("unknown", RuntimeError.new("boom"))
      Facet::Event::ConsumerHealth.report_success("unknown")
      Facet::Event::ConsumerHealth.report_restart("unknown")

      Facet::Event::ConsumerHealth.snapshot.should be_empty
      Facet::Event::ConsumerHealth.degraded?.should be_false
    end
  end

  describe "reports" do
    it "tracks failures, restarts, and success recovery" do
      key = "cg:spec:b"
      Facet::Event::ConsumerHealth.register(key)

      Facet::Event::ConsumerHealth.report_failure(key, RuntimeError.new("connection refused"))
      Facet::Event::ConsumerHealth.report_failure(key, RuntimeError.new("still down"))
      Facet::Event::ConsumerHealth.report_restart(key)

      entry = Facet::Event::ConsumerHealth.snapshot.find! { |s| s[:name] == key }
      entry[:consecutive_failures].should eq(2)
      entry[:restarts].should eq(1)
      entry[:last_success_at].should be_nil
      entry[:last_error].should eq("still down")
      Facet::Event::ConsumerHealth.degraded?.should be_true

      Facet::Event::ConsumerHealth.report_success(key)
      entry = Facet::Event::ConsumerHealth.snapshot.find! { |s| s[:name] == key }
      entry[:consecutive_failures].should eq(0)
      entry[:restarts].should eq(1)
      entry[:last_success_at].should_not be_nil
      Facet::Event::ConsumerHealth.degraded?.should be_false
    end

    it "falls back to the error class when the message is nil" do
      key = "cg:spec:class"
      Facet::Event::ConsumerHealth.register(key)
      Facet::Event::ConsumerHealth.report_failure(key, Exception.new)

      entry = Facet::Event::ConsumerHealth.snapshot.find! { |s| s[:name] == key }
      entry[:last_error].should eq("Exception")
    end

    it "truncates a long error message" do
      key = "cg:spec:truncate"
      Facet::Event::ConsumerHealth.register(key)
      Facet::Event::ConsumerHealth.report_failure(key, RuntimeError.new("x" * 500))

      entry = Facet::Event::ConsumerHealth.snapshot.find! { |s| s[:name] == key }
      entry[:last_error].not_nil!.size.should eq(200)
    end
  end

  describe "degraded?" do
    it "is false with an empty registry" do
      Facet::Event::ConsumerHealth.degraded?.should be_false
    end

    it "is true while any consumer has consecutive failures" do
      Facet::Event::ConsumerHealth.register("cg:spec:c")
      Facet::Event::ConsumerHealth.register("cg:spec:d")
      Facet::Event::ConsumerHealth.report_failure("cg:spec:d", RuntimeError.new("down"))

      Facet::Event::ConsumerHealth.degraded?.should be_true
    end
  end

  describe "snapshot" do
    it "holds every recorded field" do
      key = "cg:spec:shape"
      Facet::Event::ConsumerHealth.register(key)
      Facet::Event::ConsumerHealth.report_restart(key)
      Facet::Event::ConsumerHealth.report_failure(key, RuntimeError.new("down"))

      entry = Facet::Event::ConsumerHealth.snapshot.find! { |s| s[:name] == key }
      entry[:name].should eq(key)
      entry[:consecutive_failures].should eq(1)
      entry[:restarts].should eq(1)
      entry[:last_success_at].should be_nil
      entry[:last_error].should eq("down")
    end

    it "sorts entries by name" do
      Facet::Event::ConsumerHealth.register("cg:spec:zz")
      Facet::Event::ConsumerHealth.register("cg:spec:aa")
      Facet::Event::ConsumerHealth.snapshot.map(&.[:name]).should eq(["cg:spec:aa", "cg:spec:zz"])
    end
  end
end
