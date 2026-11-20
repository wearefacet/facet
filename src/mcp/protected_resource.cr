# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"
require "../iam/helpers"

module Facet
  module MCP
    # RFC 9728 Protected Resource Metadata (PRM) for the MCP surface.
    #
    # Served at `GET /.well-known/oauth-protected-resource`. The document is
    # parameterized: the `resource` query string the MCP client passes during
    # discovery selects the per-role resource identifier echoed back. Each
    # `:role_slug` is its own resource identifier, its own `aud` value, and
    # its own PRM view.
    module ProtectedResource
      # Builds the PRM document. When the request carries a `resource` query
      # parameter naming a valid per-role identifier, that identifier is
      # advertised; otherwise the bare well-known URL is used so generic
      # discovery still returns a usable document.
      def self.metadata(requested_resource : String?) : JSON::Any
        base = MCP.base_url
        resource = if requested_resource && requested_resource.starts_with?("#{base}#{MCP::PATH_PREFIX}/")
                     requested_resource
                   else
                     "#{base}#{MCP::PATH_PREFIX}"
                   end

        h = {} of String => JSON::Any
        h["resource"] = JSON::Any.new(resource)
        h["authorization_servers"] = JSON::Any.new([
          JSON::Any.new(base),
        ] of JSON::Any)
        h["bearer_methods_supported"] = JSON::Any.new([
          JSON::Any.new("header"),
        ] of JSON::Any)
        h["scopes_supported"] = JSON::Any.new([] of JSON::Any)
        h["resource_documentation"] = JSON::Any.new("#{base}#{MCP::PATH_PREFIX}")
        JSON::Any.new(h)
      end

      # Extracts the role slug from a per-role resource identifier, or nil
      # when the value does not name one. Used to validate that the client's
      # discovery `resource` matches a mountable URL shape.
      def self.role_slug_from_resource(resource : String) : String?
        prefix = "#{MCP.base_url}#{MCP::PATH_PREFIX}/"
        return nil unless resource.starts_with?(prefix)
        slug = resource[prefix.size..]
        slug.empty? ? nil : slug
      end

      # True when the account holds the role named by the resource identifier.
      # Discovery does not authenticate, so this is only consulted where a
      # db connection and account id are already at hand (authorize flow).
      def self.account_holds_resource_role?(db : DB::Connection, account_id : String, resource : String) : Bool
        slug = role_slug_from_resource(resource)
        return false unless slug
        account = IAM::Helpers.find_account_by_id(db, account_id)
        return false unless account
        account[:roles].includes?(slug)
      end
    end
  end
end
