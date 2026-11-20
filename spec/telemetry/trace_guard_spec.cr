# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"

# Guard spec for `Facet::Telemetry.trace` (B-354).
#
# The shard ends each span and exports the trace in an `ensure` with no
# rescue. With OTLP export on, a span end can raise from the exporter queue
# and that raise used to escape into the traced operation — a 500 for the
# request, a restart loop for background fibers. These specs prove that a
# telemetry failure never escapes `Facet::Telemetry.trace` and that a failure
# raised by the traced block itself still reaches the caller unchanged.

# Exporter that always raises — mirrors the B-354 failure, where the trace
# send onto the batch exporter queue raises
# `RuntimeError: Can't unlock Sync::MU that isn't held`.
private class GuardRaisingExporter
  include OpenTelemetry::Exporter

  def trace(traces : Array(OpenTelemetry::Exporter::Trace)) : Nil
    raise RuntimeError.new("Can't unlock Sync::MU that isn't held")
  end
end

private class GuardProbeError < Exception
end

private SPEC_GUARD_ORIGINAL_EXPORTER = OpenTelemetry::CONFIG.exporter

# Warn-level sink for the telemetry source. The suite-wide capture backend
# only records ERROR, and the guard logs at warn.
private class GuardLogSink < ::Log::Backend
  getter lines = [] of String

  def initialize
    super(::Log::DispatchMode::Sync)
  end

  def write(entry : ::Log::Entry) : Nil
    @lines << entry.message
  end
end

# Installs the failing exporter for the example and restores the original.
private def with_raising_exporter(&)
  OpenTelemetry.configure(&.exporter=(GuardRaisingExporter.new))
  yield
ensure
  OpenTelemetry.configure(&.exporter=(SPEC_GUARD_ORIGINAL_EXPORTER))
end

# Binds the sink to the telemetry source for the example and unbinds after.
private def with_telemetry_log_capture(sink : GuardLogSink, &)
  ::Log.builder.bind("facet.telemetry", :warn, sink)
  yield
ensure
  ::Log.builder.unbind("facet.telemetry", :warn, sink)
end

# Runs `Facet::Telemetry.init` with the given OTLP endpoint in the
# environment. Restores the previous value and exporter afterwards, and
# returns the log sink so the example can assert on the WARN lines.
private def with_otlp_endpoint(url : String) : GuardLogSink
  previous = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]?
  ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = url
  sink = GuardLogSink.new
  begin
    with_telemetry_log_capture(sink) do
      Facet::Telemetry.init
    end
  ensure
    if previous
      ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = previous
    else
      ENV.delete("OTEL_EXPORTER_OTLP_ENDPOINT")
    end
    OpenTelemetry.configure(&.exporter=(SPEC_GUARD_ORIGINAL_EXPORTER))
  end
  sink
end

describe "Telemetry.init endpoint probe (NS-20)" do
  it "downgrades an unreachable endpoint to NullExporter with one warning" do
    # Port 1 on loopback refuses a connection — the probe fails fast.
    previous = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]?
    ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:1/v1/traces"
    sink = GuardLogSink.new
    begin
      with_telemetry_log_capture(sink) do
        Facet::Telemetry.init
      end
    ensure
      if previous
        ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = previous
      else
        ENV.delete("OTEL_EXPORTER_OTLP_ENDPOINT")
      end
      OpenTelemetry.configure(&.exporter=(SPEC_GUARD_ORIGINAL_EXPORTER))
    end

    OpenTelemetry::CONFIG.exporter.should be_a(OpenTelemetry::NullExporter)
    sink.lines.count(&.includes?("is unreachable")).should eq(1)
  end
end

describe "Telemetry.init endpoint probe (F09-01)" do
  it "downgrades an unresolvable endpoint host to NullExporter with one warning" do
    # `.invalid` never resolves (RFC 6761), so the probe fails at name
    # resolution — `Socket::Addrinfo::Error`, a sibling of the refused-port
    # `Socket::ConnectError`. The downgrade must catch both, not crash the
    # boot. Port 1 keeps the case decisive under a wildcard-resolving
    # resolver: a bogus answer still ends in a refused or filtered connect,
    # which lands in the same downgrade.
    sink = with_otlp_endpoint("http://facet-unresolvable.invalid:1/v1/traces")

    OpenTelemetry::CONFIG.exporter.should be_a(OpenTelemetry::NullExporter)
    sink.lines.count(&.includes?("is unreachable")).should eq(1)
  end
end

describe "Telemetry.trace guard" do
  it "returns the block value on the healthy path" do
    value = Facet::Telemetry.trace("spec.guard.healthy") do |span|
      span["probe"] = "healthy"
      42
    end

    value.should eq(42)
  end

  it "keeps the block value and does not raise when the exporter fails" do
    sink = GuardLogSink.new
    value = with_raising_exporter do
      with_telemetry_log_capture(sink) do
        Facet::Telemetry.trace("spec.guard.exporter") do |span|
          span["probe"] = "exporter"
          "kept"
        end
      end
    end

    value.should eq("kept")
    sink.lines.count(&.includes?("Telemetry span end or export failed")).should eq(1)
  end

  it "keeps a nil block value when the exporter fails" do
    value = with_raising_exporter do
      Facet::Telemetry.trace("spec.guard.nil") { nil }
    end

    value.should be_nil
  end

  it "lets the block exception escape when the exporter also fails" do
    with_raising_exporter do
      ex = expect_raises(GuardProbeError, "block failed") do
        Facet::Telemetry.trace("spec.guard.double_fault") do |_span|
          raise GuardProbeError.new("block failed")
        end
      end

      # The exporter's RuntimeError must not replace the operation's failure.
      ex.message.should eq("block failed")
    end
  end

  it "does not raise when the exporter fails and the block value type is a union" do
    value = with_raising_exporter do
      Facet::Telemetry.trace("spec.guard.union") do |_span|
        rand(2).zero? ? "left" : "right"
      end
    end

    {"left", "right"}.should contain(value)
  end
end

describe "Telemetry middleware guard" do
  it "completes the request when the exporter fails at span end" do
    sink = GuardLogSink.new
    io = IO::Memory.new
    context = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/guarded-path"),
      HTTP::Server::Response.new(io),
    )
    middleware = Facet::Telemetry::Middleware.new(Facet::Telemetry::ROOT_SPAN_NAME)
    middleware.next = ->(ctx : HTTP::Server::Context) {
      ctx.response.status_code = 201
      ctx.response.print("created")
      nil
    }

    with_raising_exporter do
      with_telemetry_log_capture(sink) do
        middleware.call(context)
      end
    end

    context.response.close
    context.response.status_code.should eq(201)
    io.to_s.should contain("created")
    sink.lines.count(&.includes?("Telemetry span end or export failed")).should eq(1)
  end

  it "lets a route exception reach the error handlers when the exporter also fails" do
    io = IO::Memory.new
    context = HTTP::Server::Context.new(
      HTTP::Request.new("GET", "/failing-path"),
      HTTP::Server::Response.new(io),
    )
    middleware = Facet::Telemetry::Middleware.new(Facet::Telemetry::ROOT_SPAN_NAME)
    middleware.next = ->(_ctx : HTTP::Server::Context) {
      raise GuardProbeError.new("route failed")
    }
    sink = GuardLogSink.new

    with_raising_exporter do
      with_telemetry_log_capture(sink) do
        expect_raises(GuardProbeError, "route failed") do
          middleware.call(context)
        end
      end
    end

    # The exporter failure was swallowed with one log line; the route
    # exception escaped for the error handlers.
    sink.lines.count(&.includes?("Telemetry span end or export failed")).should eq(1)
  end
end
