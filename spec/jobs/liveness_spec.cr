# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/jobs"

module Facet
  module Jobs
    describe Liveness do
      describe ".key" do
        it "names one key per instance under the jobs namespace" do
          Liveness.key("01JEXAMPLE").should eq("FACET:JOBS:SERVICE_LIVENESS:01JEXAMPLE")
        end
      end

      describe "Redis implementation" do
        # A closed loopback port keeps both examples deterministic: the
        # suite never requires a live Redis, and a real endpoint would
        # turn the fail-open assertions into environment-dependent ones.
        checker = Liveness::Redis.new("redis://localhost:1/9")

        it "treats an instance as alive when the liveness read fails" do
          checker.alive?("01JEXAMPLE").should be_true
        end

        it "does not raise when the refresh fails" do
          checker.refresh("01JEXAMPLE").should be_nil
        end
      end
    end
  end
end
