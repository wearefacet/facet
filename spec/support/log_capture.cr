# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"

# ERROR-level log capture for the spec suite (test-only).
#
# `spec_helper.cr` binds this backend on the global `Log.builder` before each
# example (`*` at ERROR) and unbinds it after. `run_handler` (see
# `spec/support/http_helper.cr`) snapshots the buffer before driving the
# Kemal chain and attaches everything captured during the request to the 5xx
# response body under `spec_debug.log` — an exception handled deep inside the
# app (e.g. `JsonErrorHandler` rendering a 500) then shows its class, message
# and backtrace in the spec failure message.
#
# The backend only records; output still reaches STDOUT through the INFO
# binding the `shrine` shard installs at require time. Entries are bounded;
# `mark` / `since` use absolute sequence numbers, so a window stays stable
# even when old entries are evicted.
module SpecLogCapture
  MAX_ENTRIES = 400

  @@mutex = Mutex.new
  @@entries = Array(Tuple(UInt64, String)).new
  @@seq : UInt64 = 0
  @@backend : ::Log::Backend?

  # The capture backend (one instance per process, reused across examples).
  def self.backend : ::Log::Backend
    @@backend ||= CaptureBackend.new
  end

  # Sequence number marking "now" — pass to `.since` after the request.
  def self.mark : UInt64
    @@mutex.synchronize { @@seq }
  end

  # Captured lines recorded strictly after *mark* was taken, oldest first.
  # Strictly-after: a line recorded before the request (e.g. by a spec that
  # drives a handler directly) carries seq == mark and must not leak into
  # this request's window.
  def self.since(mark : UInt64) : Array(String)
    @@mutex.synchronize do
      @@entries.select { |(seq, _)| seq > mark }.map(&.[1])
    end
  end

  # Called by `CaptureBackend#write`. Module-internal — the nested backend
  # cannot reach a `private def self.` across the class boundary.
  def self.record(line : String) : Nil
    @@mutex.synchronize do
      @@seq += 1
      @@entries << {@@seq, line}
      while @@entries.size > MAX_ENTRIES
        @@entries.shift
      end
    end
  end

  # Synchronous dispatch: `write` must run on the emitting fiber — async
  # dispatch could land entries after the response was already enriched.
  private class CaptureBackend < ::Log::Backend
    def initialize
      super(::Log::DispatchMode::Sync)
    end

    def write(entry : ::Log::Entry) : Nil
      SpecLogCapture.record(format(entry))
    end

    private def format(entry : ::Log::Entry) : String
      line = "#{entry.source}: #{entry.message}"
      if ex = entry.exception
        line = String.build do |str|
          str << line
          str << "\n  " << ex.class.name << ": " << (ex.message || "-")
          if frames = ex.backtrace?
            frames.first(15).each { |frame| str << "\n  from " << frame }
          end
        end
      end
      line
    end
  end
end
