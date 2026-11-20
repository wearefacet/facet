# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "http"
require "kemal"

require "./http_debug"

# ── Shared HTTP test helpers ─────────────────────────────────────────────────

module HTTPTest
  @@initialized : Bool = false
  @@chain_handler : HTTP::Handler? = nil

  # Full initialization: register routes, build the handler chain via Kemal,
  # and chain the next pointers exactly once. Safe to call from every spec
  # file — subsequent calls are no-ops.
  def self.init
    return if @@initialized
    @@initialized = true

    Facet::HTTP::Server.routes
    Kemal.config.setup
    install_recorder
    chain_handlers

    # Disable AuthHandler in test mode — tests use AuthContext.system
    Facet::HTTP::AuthHandler.enabled = false
  end

  # Inserts the spec exception recorder into Kemal's handler array, right
  # after Kemal's `ExceptionHandler`.
  #
  # It must live in the array itself, not in a private chain copy: any
  # `HTTP::Server` built from `Kemal.config.handlers` — the shutdown spec's
  # real `Kemal.run` included — re-derives the `next` pointers from that
  # array (`HTTP::Server.build_middleware`), which would silently drop a
  # recorder that exists only in a private copy. See `SpecHttpDebug`.
  private def self.install_recorder : Nil
    handlers = Kemal.config.handlers
    return if handlers.any?(SpecHttpDebug::Recorder)
    if idx = handlers.index { |h| h.is_a?(Kemal::ExceptionHandler) }
      handlers.insert(idx + 1, SpecHttpDebug::Recorder.new)
    end
  end

  def self.chain_handlers : Nil
    return if @@chain_handler

    all = Kemal.config.handlers
    first = all.first
    cur = first

    if all.size > 1
      all[1..].each do |h|
        cur.next = h
        cur = h
      end
    end
    cur.next = nil
    @@chain_handler = first
  end

  def self.handler
    @@chain_handler
  end
end

def chain_handlers : Nil
  HTTPTest.chain_handlers
end

# Call a request through the full Kemal middleware/route stack.
# If Kemal's ExceptionHandler renders HTML, converts it to JSON.
#
# Leaves the fiber-local `auth_context` untouched — callers that pre-pin
# an `AuthContext` on `Fiber.current` (the preview-session spec builds a
# real cookie token via the AuthHandler, then runs as system) keep it. Use
# `call_api_as` to override the principal explicitly.
#
# First-party-client default: a request with no `X-Requested-With` key
# gets one, mirroring what the browser client sends on every mutating
# call (see `apiFetch`). CSRF negative-path specs use `call_api_raw` to
# send the request exactly as built.
def call_api(request : HTTP::Request) : HTTP::Client::Response
  apply_default_csrf_header(request)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  run_handler(io, context)
end

# Call a request through the full Kemal middleware/route stack with a
# specific auth context pinned on the fiber.
#
# - `auth_context = nil` — clears the fiber-local state so the request runs
#   through `Helpers.auth_context`'s fallback (system in test mode).
# - A real `AuthContext` — pins it on the fiber for this call (exercises the
#   non-system code paths — the standalone artifact upload route, RBAC gates
#   — without the JWT round-trip).
#
# To preserve whatever the caller pre-set on the fiber, use `call_api`
# instead. Adds the default `X-Requested-With` header like `call_api` —
# use `call_api_raw_as` for the raw request shape.
def call_api_as(request : HTTP::Request, auth_context : Facet::RBAC::AuthContext?) : HTTP::Client::Response
  apply_default_csrf_header(request)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  Fiber.current.auth_context = auth_context
  run_handler(io, context)
end

# `call_api` without the default `X-Requested-With` header — the escape
# hatch for CSRF negative-path specs, which must control the header's
# presence (or its emptiness) themselves.
def call_api_raw(request : HTTP::Request) : HTTP::Client::Response
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  run_handler(io, context)
end

# `call_api_as` without the default `X-Requested-With` header — the raw
# escape hatch for CSRF negative-path specs that also pin the principal.
def call_api_raw_as(request : HTTP::Request, auth_context : Facet::RBAC::AuthContext?) : HTTP::Client::Response
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  context = HTTP::Server::Context.new(request, response)
  Fiber.current.auth_context = auth_context
  run_handler(io, context)
end

# Adds the browser-client default CSRF header when the request carries no
# `X-Requested-With` key at all. A value the caller set — including an
# empty one — is never overwritten.
private def apply_default_csrf_header(request : HTTP::Request) : Nil
  return if request.headers.has_key?("X-Requested-With")
  request.headers["X-Requested-With"] = "XMLHttpRequest"
end

# Drives the configured Kemal handler chain on a freshly built context and
# normalises the response into a `HTTP::Client::Response` — error-path JSON
# hardening is shared by `call_api` and `call_api_as`.
private def run_handler(io : IO::Memory, context : HTTP::Server::Context) : HTTP::Client::Response
  response = context.response
  request_line = "#{context.request.method} #{context.request.path}"
  log_mark = SpecLogCapture.mark
  Fiber.current.spec_http_exception = nil

  begin
    HTTPTest.handler.not_nil!.call(context)
  rescue ex
    # Exception escaped the handler chain (unlikely since Kemal::ExceptionHandler
    # catches most things, but we catch what we can).
    io.clear
    response_for_error = HTTP::Server::Response.new(io)
    response_for_error.status_code = 500
    response_for_error.content_type = "application/json"
    response_for_error.print({
      error:     ex.message,
      exception: ex.class.name,
      backtrace: ex.backtrace?.try(&.first(10)),
    }.to_json)

    response_for_error.close rescue nil
    io.rewind
    return HTTP::Client::Response.from_io(io, decompress: false)
  end

  response.close rescue nil
  io.rewind
  raw = HTTP::Client::Response.from_io(io, decompress: false)

  # If the response body looks like HTML (Kemal ExceptionHandler rendered it),
  # convert to a JSON error.
  if raw.status_code >= 400 && !raw.body.starts_with?('{') && !raw.body.starts_with?('[') && !raw.body.starts_with?('"')
    clean_body = raw.body.gsub(/<[^>]*>/, " ").squeeze(' ').strip[0..200]
    json_body = {error: clean_body}.to_json
    raw = HTTP::Client::Response.new(
      raw.status_code,
      body: json_body,
      headers: HTTP::Headers{"Content-Type" => "application/json"}
    )
  end

  # Test diagnostics: merge the recorder-captured exception and the
  # ERROR-level log lines emitted during the request into every 5xx body,
  # and echo them on STDERR — a failing spec then shows *why* the call
  # failed, not just that it returned 500. See SpecHttpDebug / SpecLogCapture.
  if raw.status_code >= 500
    raw = SpecHttpDebug.enrich(
      raw, request_line,
      Fiber.current.spec_http_exception,
      SpecLogCapture.since(log_mark),
    )
  end

  raw
end

# Asserts an HTTP response status code and prints the response body
# (including error message / details / backtrace) on failure.
def assert_http_status(response : HTTP::Client::Response, expected_status : Int32) : Nil
  if response.status_code != expected_status
    STDERR.puts "─" * 70
    STDERR.puts "HTTP Status mismatch: expected #{expected_status}, got #{response.status_code}"
    STDERR.puts "Response body: #{response.body}"
    STDERR.puts "─" * 70
  end
  response.status_code.should eq(expected_status)
end
