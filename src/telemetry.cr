# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "opentelemetry"
require "opentelemetry/integrations/redis"
require "./error"
require "./telemetry/middleware"
require "./telemetry/span_patch"
require "./telemetry/db_integration"

# Telemetry module — configures OpenTelemetry for the facet application.
#
# ## Configuration
#
# Telemetry is configured via environment variables (standard OTLP):
#
#   OTEL_SERVICE_NAME         Service name (default: "facet")
#   OTEL_EXPORTER_OTLP_ENDPOINT  OTLP HTTP exporter endpoint (optional — uses
#                                NullExporter when unset)
#   OTEL_RESOURCE_ATTRIBUTES  Comma-separated key=value resource attributes
#
# When no endpoint is configured, the NullExporter is used — spans are
# created but discarded. This allows the application to run without
# telemetry infrastructure in dev/test.
#
# ## Instrumentation integrations
#
# - DB (crystal-db): wraps every SQL query/exec as a span
# - Redis: wraps every Redis command as a span
# - HTTP middleware: creates a root span per HTTP request
module Facet
  module Telemetry
    Log = ::Log.for("facet.telemetry")

    # The name of the root span created by the HTTP middleware.
    ROOT_SPAN_NAME = "http.server.request"

    # One log line per swallowed telemetry failure.
    SPAN_GUARD_MESSAGE = "Telemetry span end or export failed — continuing without the trace"

    # Traced operation guard. Routes every span through `OpenTelemetry.trace`
    # so a telemetry failure can never fail the operation the span observes.
    #
    # The shard ends the span and exports the trace in an `ensure` with no
    # rescue. With OTLP export on, a span end can raise from the exporter
    # queue (B-354), and that raise would fail the traced operation.
    #
    # - A failure raised by the traced block itself keeps its current
    #   behaviour: it propagates to the caller, so error handlers, error
    #   results and Lua error conversion keep working. The shard still sets
    #   the error status on the span.
    # - Any other failure — span end, serialization, export — is logged once
    #   and dropped. The block result is kept even when the export fails
    #   after the block has finished.
    def self.trace(name : String, & : ::OpenTelemetry::API::Span -> T) : T forall T
      captured = [] of T
      block_ex : Exception? = nil

      begin
        OpenTelemetry.trace(name) do |span|
          captured << (yield span)
          captured.first
        rescue ex
          block_ex = ex
          raise ex
        end
      rescue ex
        if block_ex
          # Double fault: the exporter also raised while the block exception
          # unwound. The operation's own failure must reach the caller.
          Log.warn(exception: ex) { SPAN_GUARD_MESSAGE } unless ex.same?(block_ex)
          raise block_ex
        end
        unless captured.empty?
          Log.warn(exception: ex) { SPAN_GUARD_MESSAGE }
          return captured.first
        end
        raise ex
      end

      captured.first
    end

    # Configures OpenTelemetry with environment-driven settings.
    # Falls back to NullExporter when `OTEL_EXPORTER_OTLP_ENDPOINT` is unset,
    # and also when it is set but the endpoint is unreachable — a refused
    # connection, an unresolvable host, or a connect timeout.
    #
    # The probe is a boot-time fail-fast: an unreachable sink used to leave
    # the exporter queue live, and a queue failure can raise into the
    # event-consumer fibers (B-354). A deployment that loses telemetry is
    # acceptable; a deployment that loses its event pipeline is not, so an
    # unreachable endpoint downgrades to NullExporter with one WARN.
    def self.init : Nil
      OpenTelemetry.configure do |c|
        c.service_name = "facet"

        if endpoint = ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]?
          uri = URI.parse(endpoint)
          if endpoint_reachable?(uri)
            c.exporter = OpenTelemetry::BatchExporter.new(
              OpenTelemetry::HTTPExporter.new(endpoint: uri)
            )
          else
            Log.warn do
              "OTEL_EXPORTER_OTLP_ENDPOINT #{endpoint} is unreachable — " \
              "telemetry export is disabled (NullExporter). The event pipeline is unaffected."
            end
          end
        end
        # When endpoint is nil, NullExporter is used (default) — no telemetry
        # data is sent anywhere. This is the safe default for dev/test.
      end
    end

    # Opens and closes a TCP connection to the endpoint's host and port.
    # Every connect failure disables export. A refused port and a
    # firewalled sink that drops packets (the connect times out) raise
    # `Socket::ConnectError`; a host that does not resolve raises
    # `Socket::Addrinfo::Error` before any connect — so a firewalled sink
    # loses telemetry too, and only a sink that accepts the TCP handshake
    # keeps the exporter.
    private def self.endpoint_reachable?(uri : URI) : Bool
      host = uri.host
      return true if host.nil? || host.empty?
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      socket = TCPSocket.new(host, port, connect_timeout: 2.seconds)
      socket.close
      true
    rescue Socket::Addrinfo::Error | Socket::ConnectError
      false
    end

    # Returns the HTTP middleware for use with Kemal's handler stack.
    def self.middleware : Facet::Telemetry::Middleware
      Facet::Telemetry::Middleware.new(ROOT_SPAN_NAME)
    end

    # Shortcut for creating an error-status protobuf object.
    #
    # Replaces the verbose `OpenTelemetry::Proto::Trace::V1::Status.new(code: :error, message: msg)`
    # pattern used throughout the codebase.
    def self.error_status(message : String) : OpenTelemetry::Proto::Trace::V1::Status
      OpenTelemetry::Proto::Trace::V1::Status.new(code: :error, message: message)
    end

    # Records a service error on an OpenTelemetry span and returns the same
    # error so call sites can write:
    #
    # ```
    # result = Error.new(404, "not found")
    # return Telemetry.record_error(span, result)
    # ```
    #
    # Always sets `error`, `error.status`, and the span status together.
    # Use this instead of the three-line `span["error"] = ...` pattern to
    # avoid forgetting one of the attribute writes.
    def self.record_error(span, error : T) : T forall T
      span["error"] = error.message
      span["error.status"] = error.status.to_s
      span.status = error_status(error.message)
      error
    end

    # Convenience for sites that do not produce a `ServiceError` value,
    # such as `Document::Compute` (which returns a tuple).
    def self.record_error(span, message : String, status : Int32 = 500) : Nil
      span["error"] = message
      span["error.status"] = status.to_s
      span.status = error_status(message)
    end
  end
end
