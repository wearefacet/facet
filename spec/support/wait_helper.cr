# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

# ── Wait helpers ────────────────────────────────────────────────────────────
#
# Polls a condition with configurable timeout and interval, replacing fixed
# `sleep` calls.  Returns as soon as the block returns truthy, so fast
# responses finish quickly without wasting wall-clock time.

# Polls `&` every `interval` seconds until it returns truthy or `timeout`
# seconds elapse.  Returns the block's return value on success, or `nil`
# on timeout.
def wait_for(timeout : Float64 = 2.0, interval : Float64 = 0.01, & : -> T) : T? forall T
  deadline = Time.instant + timeout.seconds
  loop do
    val = yield
    return val if val
    break if Time.instant >= deadline
    sleep(interval.seconds)
  end
  nil
end

# Asserts that `&` becomes truthy within `timeout` seconds.
# Fails the spec if the condition is never met.
def assert_eventually(timeout : Float64 = 2.0, interval : Float64 = 0.01, & : -> _) : Nil
  result = wait_for(timeout: timeout, interval: interval) { yield }
  result.should be_truthy
end
