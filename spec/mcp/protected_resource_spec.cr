# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../spec_helper"
require "../../src/config"
require "../../src/mcp"
require "../../src/mcp/protected_resource"

# RFC 9728 Protected Resource Metadata for the MCP surface.
#
# Acceptance (`doc/backend/mcp.md`):
# - Document shape: `resource`, `authorization_servers`,
#   `bearer_methods_supported`, `scopes_supported`.
# - Per-role resource: a `resource` query parameter naming a per-role
#   identifier is echoed back verbatim.
# - A non-MCP `resource` value falls back to the bare prefix.
describe "MCP::ProtectedResource" do
  it "advertises the required RFC 9728 fields" do
    doc = Facet::MCP::ProtectedResource.metadata(nil)
    h = doc.as_h

    h["resource"].as_s.should eq("#{Facet::MCP.base_url}#{Facet::MCP::PATH_PREFIX}")
    servers = h["authorization_servers"].as_a.map(&.as_s)
    servers.should contain(Facet::MCP.base_url)
    h["bearer_methods_supported"].as_a.map(&.as_s).should eq(["header"])
    h["scopes_supported"].as_a.should be_a(Array(JSON::Any))
  end

  it "echoes a per-role resource identifier verbatim" do
    per_role = Facet::MCP.resource_identifier("editor")
    doc = Facet::MCP::ProtectedResource.metadata(per_role)
    doc.as_h["resource"].as_s.should eq(per_role)
  end

  it "falls back to the bare prefix for a foreign resource value" do
    doc = Facet::MCP::ProtectedResource.metadata("https://evil.example.com/Api/_mcp/admin")
    doc.as_h["resource"].as_s.should eq("#{Facet::MCP.base_url}#{Facet::MCP::PATH_PREFIX}")
  end

  it "extracts the role slug from a per-role identifier" do
    Facet::MCP::ProtectedResource.role_slug_from_resource(
      Facet::MCP.resource_identifier("finance-controller")
    ).should eq("finance-controller")
  end

  it "returns nil for identifiers outside the MCP prefix" do
    Facet::MCP::ProtectedResource.role_slug_from_resource("https://other.example.com/x").should be_nil
    Facet::MCP::ProtectedResource.role_slug_from_resource(
      "#{Facet::MCP.base_url}#{Facet::MCP::PATH_PREFIX}/"
    ).should be_nil
  end

  it "builds an absolute URI from the configured host with scheme assumed https" do
    # The identifier is absolute and path-pinned; never derived at dispatch.
    id = Facet::MCP.resource_identifier("viewer")
    id.should contain("://")
    id.should contain("/Api/_mcp/viewer")
  end
end
