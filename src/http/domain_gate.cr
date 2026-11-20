# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "../config"

module Facet
  module HTTP
    # Kemal handler that rejects requests to excluded domains with 404.
    #
    # Runs before route matching (Kemal middleware), so it extracts the
    # domain from the request path manually. Routes always follow the
    # pattern `/Api/:domain/...` — the domain is the third path segment.
    #
    # Paths without a domain segment (e.g. `/Api/Audit`, `/Api/Indexes`,
    # `/Api/iam/...`) are passed through.
    class DomainGate < Kemal::Handler
      # System namespaces own these first path segments.
      # A path with one of these segments carries no domain.
      # `search` hosts the app-wide search endpoint (`/Api/search`); the
      # domain-scoped form (`/Api/:domain/search`) keeps normal gating —
      # its domain is the first segment, never `search`.
      # `openapi.json` is the machine-readable API surface (`GET
      # /Api/openapi.json`) — not a domain. Without the entry the gate reads
      # the first path segment as a domain and 404s the route on deployments
      # with a domains include-list.
      RESERVED_SEGMENTS = %w[Audit Indexes Artifacts SystemSettings iam assistant search openapi.json]

      # These second path segments belong to the `core` artifact namespace.
      # The `core` domain itself stays gated.
      RESERVED_CORE_SEGMENTS = %w[artifacts Artifacts]

      def call(env)
        path = env.request.path

        # Extract the domain from /Api/:domain/... paths
        if domain = extract_domain(path)
          unless Facet::Config.instance.domain_enabled?(domain)
            env.response.status_code = 404
            env.response.content_type = "application/json"
            Helpers.no_store(env)
            env.response.print({error: "Not found"}.to_json)
            return
          end
        end

        call_next(env)
      end

      # Returns the domain segment from `/Api/<domain>/...`, or nil
      # for paths that don't carry a domain.
      #
      # Reserved namespaces match whole path segments, not prefixes.
      # The match is case-sensitive. A user domain named `AuditFoo`
      # parses as a domain. It stays gated.
      private def extract_domain(path : String) : String?
        return nil unless path.starts_with?("/Api/")

        segments = path.split('/').reject(&.empty?)
        return nil if segments.size < 2

        first = segments[1]
        return nil if RESERVED_SEGMENTS.includes?(first)
        if first == "core" && (second = segments[2]?)
          return nil if RESERVED_CORE_SEGMENTS.includes?(second)
        end

        first
      end
    end
  end
end
