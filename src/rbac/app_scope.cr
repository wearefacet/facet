# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./grant"
require "./permission"
require "./active_role"
require "../mutation/client"

module Facet
  module RBAC
    # The parsed grant set of a single `app.App` projection.
    #
    # Built from the projection's `content` JSON: the `grants` array is
    # parsed into `Grant` objects; nothing else on the projection (redirect
    # URIs, status, etc.) is consulted by the grant resolver.
    #
    # `AppScope` is a pure value — it carries no DB handle and no request
    # state. The grant resolver is genuinely pure: given an `AppScope` and
    # an `ActiveRole`, both functions return synchronously with no I/O.
    struct AppScope
      getter app_id : String # the projection id (ULID)
      getter grants : Array(Grant)

      # Builds an `AppScope` from a `Mutation::Client::Projection` of an
      # `app.App` row. Used by the service layer when it
      # loads the app alongside the role.
      def self.from_projection(projection : Mutation::Client::Projection) : self
        from_content(projection.id, projection.content)
      end

      # Builds an `AppScope` from raw content JSON. Used by specs that
      # construct an app scope from a JSON literal without touching the DB,
      # and by callers that already hold the projection content separately
      # from the id.
      def self.from_content(app_id : String, content : JSON::Any) : self
        h = content.as_h? || raise ArgumentError.new(
          "AppScope content must be a JSON object (got: #{content.raw.inspect})"
        )

        grants_raw = h["grants"]?
        grants = parse_grants(grants_raw)

        new(app_id: app_id, grants: grants)
      end

      def initialize(@app_id : String, @grants : Array(Grant))
      end

      # Parses the `grants` field from raw JSON, tolerating the empty
      # array and the Lua-round-trip empty-Hash form (see
      # doc/backend/app-system.md → Quirks).
      private def self.parse_grants(raw : JSON::Any?) : Array(Grant)
        return [] of Grant if raw.nil?

        case raw.raw
        when Array
          raw.as_a.map { |g| Grant.from_json(g) }
        when Hash
          if raw.as_h.empty?
            [] of Grant
          else
            raise ArgumentError.new(
              "AppScope 'grants' is a non-empty object; expected an array"
            )
          end
        else
          raise ArgumentError.new(
            "AppScope 'grants' must be an array (got: #{raw.raw.inspect})"
          )
        end
      end
    end

    # The output of `GrantResolver.resolve`: the intersection of an app's
    # grants with the active role's permissions.
    #
    # An `EffectiveScope` is the **policy** the enforcer
    # consults to decide whether a `(domain, path, action)` operation may
    # proceed under an app token. Each entry pairs a concrete doctype path
    # (wildcard grants expand to per-doctype entries — see below) with the
    # concrete action names the role actually permits and the underlying
    # role `Permission`(s) that matched.
    #
    # Why the role's `Permission`s are carried verbatim: resource scope
    # (named scopes, context sets) is **not** intersected with the grant.
    # A role whose permission carries `scope: ["$mine"]` passes that
    # scope alias unchanged into the app token. The enforcer runs
    # the existing scope predicates (`ScopeExpander`, `ScopePredicateSql`)
    # exactly as today — the grant narrows the set of `(domain, path,`
    # action)` the token may attempt at all, never widening or relaxing a
    # row-level filter.
    #
    # Wildcard grant expansion: a grant with `target: "crm.*"` produces one
    # `Entry` per concrete doctype path the role actually holds a matching
    # permission on. The original wildcard target is recorded in `target`
    # for traceability; `domain` and `path` carry the concrete (de-wildcarded)
    # coordinates the enforcer will check against. If the role has no
    # permission on any `crm.*` doctype, the wildcard grant produces no
    # entries — the actions it declared become unreachable through this
    # token (and if any of them were `required`, `role_usable?` already
    # returned `false` and the token would not have been issued).
    struct EffectiveScope
      record Entry,
        target : String,                # original grant target string
        domain : String,                # concrete (de-wildcarded) domain
        path : Array(String),           # concrete (de-wildcarded) doctype path
        actions : Set(String),          # action names the role permits (post write-expansion)
        permissions : Array(Permission) # matching role permissions, scope aliases preserved

      getter entries : Array(Entry)

      def initialize(@entries : Array(Entry))
      end

      # An empty effective scope carries no permitted operations. The
      # enforcer denies everything under such a token.
      def empty? : Bool
        @entries.empty?
      end

      # Builds the effective scope from the role's own permission map, with
      # no app-grant intersection. Used by the MCP authorize branch: MCP is
      # not an app (decision D5), so the role's permission map is
      # authoritative and each held role contributes one entry per distinct
      # (domain, path) it holds permissions on.
      def self.from_active_role(role : ActiveRole) : EffectiveScope
        entries = role.permissions.group_by do |perm|
          {perm.domain, perm.path}
        end.map do |(domain, path), perms|
          actions = perms.map(&.action).to_set
          Entry.new(
            target: "#{domain}.#{path.join(".")}",
            domain: domain,
            path: path,
            actions: actions,
            permissions: perms,
          )
        end
        EffectiveScope.new(entries)
      end
    end
  end
end
