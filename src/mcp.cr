# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./config"
require "./mcp/protected_resource"
require "./mcp/dispatch"
require "./mcp/routes"

module Facet
  # Model Context Protocol (MCP) resource server.
  #
  # Facet exposes one MCP endpoint per role at `/Api/_mcp/:role_slug`
  # (decision D4 — the URL pins the role for the session's lifetime) and
  # acts as an OAuth 2.1 resource server on that surface (decision D2):
  # it validates tokens minted by the existing `/OAuth/*` endpoints,
  # it does not issue them.
  #
  # MCP is independent of the app system (decision D5): no `app.App` row
  # backs it, no grant intersection applies, and the regular role-only RBAC
  # enforcement applies exactly as on REST.
  module MCP
    Log = ::Log.for("facet.mcp")

    # The reserved path prefix. `_mcp`, not `mcp`, to prevent collisions
    # with a `mcp` custom domain; the leading underscore mirrors the other
    # reserved names (`_migrations` table, `_`-prefixed draft domains).
    PATH_PREFIX = "/Api/_mcp"

    # Builds the per-role MCP resource identifier from the configured host:
    # `https://<origin>/Api/_mcp/<role_slug>`. An absolute URI compared by
    # exact string match at dispatch — never derived from the `Host` header
    # (Host-injection replay hole).
    def self.resource_identifier(role_slug : String) : String
      "#{base_url}#{PATH_PREFIX}/#{role_slug}"
    end

    # The external base URL, scheme-normalized via `Config#scheme_base_url`.
    # Kept as a thin wrapper so MCP call sites read `MCP.base_url` rather than
    # reaching into `Config` for the public origin.
    def self.base_url : String
      Facet::Config.instance.scheme_base_url
    end
  end
end
