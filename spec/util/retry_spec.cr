# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "spec"
require "../../src/util/retry"

# A custom error type used to test custom exception filtering.
class RetrySpecCustomError < RuntimeError; end

describe Facet::Util::Retry do
  # ── Happy path ──────────────────────────────────────────────────────

  describe ".with_retry" do
    it "returns the block value on success" do
      result = Facet::Util::Retry.with_retry { 42 }
      result.should eq(42)
    end

    it "passes through the block value after one failure then success" do
      attempt = 0
      result = Facet::Util::Retry.with_retry(max_attempts: 3, base_delay: 0.001) do
        attempt += 1
        raise "fail" if attempt == 1
        "ok"
      end
      result.should eq("ok")
    end

    # ── Retry behavior ───────────────────────────────────────────────

    it "retries on Exception (default) until success" do
      attempt = 0
      Facet::Util::Retry.with_retry(max_attempts: 3, base_delay: 0.001) do
        attempt += 1
        raise "transient" if attempt < 3
        attempt
      end.should eq(3)
    end

    it "raises after max_attempts exceeded" do
      expect_raises(Exception, "boom") do
        Facet::Util::Retry.with_retry(max_attempts: 2, base_delay: 0.001) do
          raise "boom"
        end
      end
    end

    # ── Custom exception type ────────────────────────────────────────

    it "only rescues the specified exception type" do
      expect_raises(RetrySpecCustomError) do
        Facet::Util::Retry.with_retry(max_attempts: 3, base_delay: 0.001, exception: RetrySpecCustomError) do
          raise RetrySpecCustomError.new("custom")
        end
      end
    end

    it "does not rescue exceptions not matching the specified type" do
      expect_raises(ArgumentError) do
        Facet::Util::Retry.with_retry(max_attempts: 3, base_delay: 0.001, exception: RuntimeError) do
          raise ArgumentError.new("wrong type")
        end
      end
    end

    it "retries on RuntimeError when specified as the exception type" do
      attempt = 0
      Facet::Util::Retry.with_retry(max_attempts: 3, base_delay: 0.001, exception: RuntimeError) do
        attempt += 1
        raise RuntimeError.new("transient") if attempt < 3
        attempt
      end.should eq(3)
    end

    # ── Default arguments ────────────────────────────────────────────

    it "uses default max_attempts (5)" do
      attempt = 0
      expect_raises(Exception, "always fail") do
        Facet::Util::Retry.with_retry(base_delay: 0.001) do
          attempt += 1
          raise "always fail"
        end
      end
      attempt.should eq(5)
    end

    it "uses default exception type (Exception)" do
      expect_raises(Exception, "default exception") do
        Facet::Util::Retry.with_retry(max_attempts: 2, base_delay: 0.001) do
          raise "default exception"
        end
      end
    end

    # ── Sad path: non-matching exception ─────────────────────────────

    it "does not retry for exceptions outside the rescued type" do
      expect_raises(ArgumentError) do
        Facet::Util::Retry.with_retry(max_attempts: 2, base_delay: 0.001, exception: RuntimeError) do
          raise ArgumentError.new("not a RuntimeError")
        end
      end
    end

    # ── Edge: single attempt ─────────────────────────────────────────

    it "works with max_attempts = 1 (no retry)" do
      expect_raises(Exception, "no retry") do
        Facet::Util::Retry.with_retry(max_attempts: 1, base_delay: 0.001) do
          raise "no retry"
        end
      end
    end
  end
end
