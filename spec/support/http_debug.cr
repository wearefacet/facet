# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "log"

# Test diagnostics for 5xx responses (used by `spec/support/http_helper.cr`).
#
# A 500 body is intentionally sparse — `JsonErrorHandler` renders the message,
# and the Kemal `error 500` block renders only the exception class — so a
# failing spec used to show `create failed (500): {"error":"TypeCastError"}`
# with nothing to act on. Two capture layers close that gap:
#
# 1. `Recorder` sits in the harness chain right after Kemal's
#    `ExceptionHandler`. Every exception that reaches Kemal's renderer (i.e.
#    one that escaped `JsonErrorHandler` — raised by the OpenTelemetry
#    middleware or the handlers between them) is stashed on the fiber before
#    being rendered; `SpecHttpDebug.enrich` then merges class, message,
#    backtrace and cause chain into the response body.
#
# 2. `SpecLogCapture` (spec/support/log_capture.cr) records the ERROR-level
#    log lines emitted during the request window. Exceptions handled by
#    `JsonErrorHandler` never reach the recorder (it renders them itself), but
#    its `facet.http` error line carries the class, message and backtrace.
#
# `run_handler` calls `SpecHttpDebug.enrich` for every 5xx: the response body
# gains a `spec_debug` key, so a failing spec's assertion message (the
# assertion helpers print the body) carries the root cause. The suite stays
# quiet on the many deliberate 5xxes — set `SPEC_DEBUG_STDERR=1` to echo each
# enriched body on STDERR behind a `spec-debug` marker (a debugging session
# that wants to grep the job log for 5xx causes without touching spec code).
class Fiber
  # Exception captured by `SpecHttpDebug::Recorder` for the request this
  # fiber is currently driving through the harness chain.
  property spec_http_exception : ::Exception?
end

module SpecHttpDebug
  # Stashes the exception on the fiber and re-raises. Rendering is left
  # untouched — Kemal's `ExceptionHandler` still produces its own response.
  class Recorder
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      call_next(context)
    rescue ex
      Fiber.current.spec_http_exception = ex
      raise ex
    end
  end

  # Where the `spec-debug` echo is written. `nil` — the echo goes to STDERR
  # when enabled. Test hook: specs point this at a memory buffer to assert
  # on the echo without touching the real stderr stream.
  @@echo_io : IO? = nil

  def self.echo_io : IO?
    @@echo_io
  end

  def self.echo_io=(io : IO?) : Nil
    @@echo_io = io
  end

  # Merges the captured exception and the captured log lines into a 5xx
  # response body. The response is returned untouched when the body is not a
  # JSON object. STDERR echo is opt-in via `SPEC_DEBUG_STDERR=1` — the suite
  # triggers deliberate 5xxes, so an unconditional echo would flood CI logs;
  # the enriched body already reaches the failure message through the
  # assertion helpers.
  def self.enrich(raw : HTTP::Client::Response, request_line : String, ex : ::Exception?, log_lines : Array(String)) : HTTP::Client::Response
    return raw if ex.nil? && log_lines.empty?

    merged = merge_body(raw.body, request_line, ex, log_lines)
    raw = with_body(raw, merged) if merged

    if echo_stderr?
      io = @@echo_io || STDERR
      io.puts "───── spec-debug #{request_line} → #{raw.status_code} ─────"
      if merged
        io.puts merged[0, 6000]
        io.puts "… truncated (#{merged.size} bytes total)" if merged.size > 6000
      else
        io.puts "response body: #{raw.body[0, 1000]}"
      end
    end

    raw
  end

  # The echo is off by default; `SPEC_DEBUG_STDERR=1` turns it on for a
  # debugging session.
  private def self.echo_stderr? : Bool
    ENV["SPEC_DEBUG_STDERR"]? == "1"
  end

  # Builds the enriched body: the original JSON object plus one `spec_debug`
  # key. Returns nil when the original body is not a JSON object.
  private def self.merge_body(body : String, request_line : String, ex : ::Exception?, log_lines : Array(String)) : String?
    base = JSON.parse(body).as_h?
    return nil unless base

    JSON.build do |json|
      json.object do
        base.each do |key, value|
          json.field(key) { value.to_json(json) }
        end
        json.field("spec_debug") do
          json.object do
            json.field("request", request_line)
            if e = ex
              json.field("exception", e.class.name)
              json.field("message", e.message) if e.message
              backtrace_field(json, e.backtrace?, 25)
              causes = causes_of(e)
              unless causes.empty?
                json.field("cause") do
                  json.array do
                    causes.each do |cause|
                      json.object do
                        json.field("class", cause.class.name)
                        json.field("message", cause.message) if cause.message
                        backtrace_field(json, cause.backtrace?, 15)
                      end
                    end
                  end
                end
              end
            end
            unless log_lines.empty?
              json.field("log") do
                json.array { log_lines.each { |line| json.scalar(line) } }
              end
            end
          end
        end
      end
    end
  end

  private def self.backtrace_field(json : JSON::Builder, frames : Array(String)?, limit : Int32) : Nil
    json.field("backtrace") do
      json.array do
        (frames || Array(String).new).first(limit).each { |frame| json.scalar(frame) }
      end
    end
  end

  private def self.causes_of(ex : ::Exception) : Array(::Exception)
    causes = [] of ::Exception
    current = ex.cause
    while current
      causes << current
      current = current.cause
    end
    causes
  end

  private def self.with_body(raw : HTTP::Client::Response, body : String) : HTTP::Client::Response
    HTTP::Client::Response.new(raw.status_code, body: body, headers: raw.headers)
  end
end
