# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/jobs"

module Facet
  module Jobs
    # Minimal fake handler used only to exercise the `Handler` contract.
    class SpecHandler < Handler
      @result : Result

      # The default keeps the class no-arg constructible — the worker
      # instantiates handlers through the dispatch table, which requires
      # every subclass to support `new` with no arguments.
      def initialize(@result : Result = Result.new(status: Kind::Succeeded))
      end

      def execute(job : Job) : Result
        @result
      end
    end

    describe Handler do
      it "subclasses return a Result for each Kind" do
        job = Job.new(id: "01JTESTJOB", kind: "test", payload: JSON.parse(%({"n": 1})),
          attempts: 1, max_attempts: 5, backoff: nil)

        succeeded = SpecHandler.new(Handler::Result.new(status: Handler::Kind::Succeeded, http_status: 200))
        result = succeeded.execute(job)
        result.status.should eq(Handler::Kind::Succeeded)
        result.error.should be_nil
        result.http_status.should eq(200)

        failed = SpecHandler.new(Handler::Result.new(status: Handler::Kind::Failed, error: "boom", http_status: 500))
        result = failed.execute(job)
        result.status.should eq(Handler::Kind::Failed)
        result.error.should eq("boom")
        result.http_status.should eq(500)
      end

      it "exposes kind defaults as class methods" do
        Handler.default_max_attempts.should eq(5)
        Handler.default_backoff.should eq([10, 60, 300, 1800, 7200])
        SpecHandler.default_max_attempts.should eq(5)
        SpecHandler.default_backoff.should eq([10, 60, 300, 1800, 7200])
      end

      # The remaining contract points are enforced elsewhere:
      # - `Handler` is abstract, so `Handler.new` is rejected at compile
      #   time; a runtime spec cannot exercise it.
      # - An uncaught exception in `execute` becomes
      #   `Result.new(status: Failed, error: ...)` inside the worker
      #   — the worker owns that conversion, not the handler.
    end
  end
end
