# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "opentelemetry"
require "../config"
require "../util/client_ip"

module Facet
  module Telemetry
    # First-party replacement for the shard's `OpenTelemetry::Middleware`.
    #
    # Same span, same attributes — but the `http.client_ip` attribute is
    # collected nil-safely and through the trusted-proxy resolver
    # (`Util::ClientIp.resolve`): the correctly spelled `X-Forwarded-For`
    # header counts only when the socket peer is a configured trusted
    # proxy; otherwise the attribute is the socket host. The upstream
    # middleware reads
    # `request.remote_address.as(Socket::IPAddress).address`, which raises on
    # every request that has no socket behind it (in-process test harness,
    # HTTP/1.0 clients) and on Unix-socket deployments, turning an
    # observability failure into a 500. Attribute collection is also guarded:
    # telemetry must never fail the request it observes.
    class Middleware
      include ::HTTP::Handler

      Log = ::Log.for("facet.telemetry")

      def initialize(@name : String); end

      def call(context : ::HTTP::Server::Context)
        Facet::Telemetry.trace(@name) do |span|
          span.kind = :server
          begin
            collect_request_attributes(span, context.request)
          rescue ex
            # Pre-dispatch only — the route has not run yet, so continuing is
            # safe. Route exceptions raised by `call_next` below must keep
            # propagating (the error handlers rely on them).
            Log.warn(exception: ex) { "Telemetry attribute collection failed — continuing without request attributes" }
          end

          begin
            call_next(context)
          ensure
            begin
              stamp_response_attributes(span, context)
            rescue ex
              # Must not mask a route exception that is mid-flight here.
              Log.warn { "Telemetry status stamping failed: #{ex.class.name}: #{ex.message}" }
            end
          end
        end
      end

      # The attribute set of the upstream middleware, with `http.client_ip`
      # collected through an `is_a?` check instead of a cast — `nil` (no
      # socket) and `Socket::UNIXAddress` (Unix-socket deployment) both
      # leave the attribute unset.
      private def collect_request_attributes(span, request : ::HTTP::Request) : Nil
        span["http.server_name"] = request.headers["host"]?
        span["http.client_ip"] = client_ip(request)
        span["http.user_agent"] = request.headers["user-agent"]?
        span["http.path"] = request.path
        span["http.method"] = request.method
        span["http.target"] = request.resource
        span["http.flavor"] = request.version
        span["http.host"] = request.headers["host"]?
        request.query_params.each do |key, value|
          span["request.query_params.#{key}"] = value
        end
      end

      private def client_ip(request : ::HTTP::Request) : String?
        Facet::Util::ClientIp.resolve(request.headers, request.remote_address, Facet::Config.instance.trusted_proxies)
      end

      private def stamp_response_attributes(span, context : ::HTTP::Server::Context) : Nil
        span["http.status_code"] = context.response.status_code.to_i64
        if context.response.status_code < 400
          span.status = OpenTelemetry::Proto::Trace::V1::Status.new(code: :ok)
        end
      end
    end
  end
end
