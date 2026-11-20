# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "../metrics"

module Facet
  module HTTP
    # Kemal handler that counts every handled request.
    #
    # Registered **first** in the middleware stack (see
    # `Facet::HTTP::Server.routes`), so it wraps every other handler —
    # including the OpenTelemetry middleware, app-host dispatch, and the
    # error handlers — and reads the final status code after the rest of
    # the chain has run.
    #
    # Labels stay bounded: `method` is the HTTP verb, `route` is the first
    # path segment (one of a fixed set, `other` otherwise — request
    # scanners cannot mint new label values), and `status_class` is
    # `1xx` … `5xx`.
    class MetricsHandler < Kemal::Handler
      # The first path segments this server answers on. Anything else —
      # including `/` and unmatched paths — collapses into `other`.
      private ROUTE_SEGMENTS = ["/Api", "/OAuth", "/A", "/auth", "/Ws", "/.well-known", "/Healthcheck", "/metrics"]

      def call(env)
        call_next(env)
      ensure
        record(env)
      end

      private def record(env) : Nil
        Metrics.inc(
          "facet_http_requests_total",
          {
            "method"       => env.request.method,
            "route"        => route_label(env.request.path),
            "status_class" => status_class(env.response.status_code),
          },
        )
      end

      private def route_label(path : String) : String
        ROUTE_SEGMENTS.each do |segment|
          return segment if path == segment || path.starts_with?(segment + '/')
        end
        "other"
      end

      private def status_class(status_code : Int32) : String
        group = status_code // 100
        (1..5).includes?(group) ? "#{group}xx" : "other"
      end
    end
  end
end
