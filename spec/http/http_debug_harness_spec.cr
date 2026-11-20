# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/http/server"
require "../support/http_helper"
require "../support/io_helper"

HTTPTest.init

# Probe route for the debug harness examples. Registered through the normal
# Kemal DSL so the request crosses the full harness chain (JsonErrorHandler
# included); the raise happens inside a route, so `JsonErrorHandler` renders
# the 500 and the recorder never sees it — the captured `facet.http` error
# line carries the trace into `spec_debug.log`.
post "/Api/__spec_debug/boom" do
  raise TypeCastError.new("Cast to String failed")
end

describe "spec HTTP debug harness" do
  it "splices the exception recorder after Kemal's ExceptionHandler" do
    current = HTTPTest.handler.not_nil!
    spliced = false
    while current.is_a?(HTTP::Handler)
      if current.is_a?(Kemal::ExceptionHandler)
        spliced = current.next.is_a?(SpecHttpDebug::Recorder)
        break
      end
      current = current.next
    end
    spliced.should be_true
  end

  it "merges the captured error-log trace into a route-rendered 500" do
    resp = call_api(HTTP::Request.new("POST", "/Api/__spec_debug/boom"))
    resp.status_code.should eq(500)

    body = JSON.parse(resp.body)
    # The wire error stays generic — the exception text lives in the
    # captured log trace (`spec_debug`, a spec-harness-only enrichment)
    # and the server log, never in the `error` field a client parses.
    body["error"].as_s.should eq("Internal server error")

    debug = body["spec_debug"]
    debug["request"].as_s.should eq("POST /Api/__spec_debug/boom")

    log_text = debug["log"].as_a.join("\n")
    # The captured trace carries the exception's own class and message — the
    # part `SpecHttpDebug` exists to surface on a failing 5xx body. No frame
    # assertion is made here: `make test` builds with `--no-debug`, where
    # Crystal drops file/line info and inlined frames, so the stack has a
    # different length and shape than under `crystal spec`. Pinning a frame
    # would encode the build flags rather than the behaviour under test.
    log_text.should contain("→ 500 TypeCastError: Cast to String failed")
  end

  it "merges a recorder-captured exception into the 500 body" do
    raw = HTTP::Client::Response.new(
      500,
      body: %({"error":"TypeCastError"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    )
    enriched = SpecHttpDebug.enrich(
      raw,
      "POST /Api/core/DocType",
      TypeCastError.new("Cast to String failed"),
      ["facet.http: POST /Api/core/DocType → 500 TypeCastError"],
    )

    body = JSON.parse(enriched.body)
    body["error"].as_s.should eq("TypeCastError")
    body["spec_debug"]["exception"].as_s.should eq("TypeCastError")
    body["spec_debug"]["message"].as_s.should eq("Cast to String failed")
    body["spec_debug"]["log"].as_a.size.should eq(1)
  end

  it "does not echo the enriched body on STDERR by default" do
    raw = HTTP::Client::Response.new(
      500,
      body: %({"error":"TypeCastError"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    )
    # The suite triggers deliberate 5xxes; an unconditional echo would flood
    # the CI log. While the echo target is hooked, ANY echo lands in the
    # buffer — so an empty buffer proves the echo is off.
    buffer = IO::Memory.new
    previous_io = SpecHttpDebug.echo_io
    SpecHttpDebug.echo_io = buffer
    begin
      SpecHttpDebug.enrich(raw, "POST /Api/core/DocType", TypeCastError.new("boom"), [] of String)
    ensure
      SpecHttpDebug.echo_io = previous_io
    end
    buffer.rewind
    buffer.gets_to_end.should be_empty
  end

  it "echoes the enriched body when SPEC_DEBUG_STDERR=1" do
    raw = HTTP::Client::Response.new(
      500,
      body: %({"error":"TypeCastError"}),
      headers: HTTP::Headers{"Content-Type" => "application/json"},
    )
    buffer = IO::Memory.new
    previous_env = ENV["SPEC_DEBUG_STDERR"]?
    previous_io = SpecHttpDebug.echo_io
    ENV["SPEC_DEBUG_STDERR"] = "1"
    SpecHttpDebug.echo_io = buffer
    begin
      SpecHttpDebug.enrich(raw, "POST /Api/core/DocType", TypeCastError.new("boom"), [] of String)
    ensure
      if previous_env
        ENV["SPEC_DEBUG_STDERR"] = previous_env
      else
        ENV.delete("SPEC_DEBUG_STDERR")
      end
      SpecHttpDebug.echo_io = previous_io
    end
    buffer.rewind
    buffer.gets_to_end.should contain("spec-debug POST /Api/core/DocType → 500")
  end
end
