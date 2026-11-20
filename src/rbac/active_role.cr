# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

module Facet
  module RBAC
    # The active role for a single request.
    #
    # Exactly one role is active per request; roles never merge.
    # The effective permission set is exactly this role's map, verbatim.
    struct ActiveRole
      getter role_id : String
      getter visible_tags : Set(String)
      getter permissions : Array(Permission)

      # The role's authority level (0–100), read from the role projection
      # content. `nil` when the stored role carries no usable level — every
      # role-authority check fails closed on a `nil` level (see
      # `RBAC::RoleAuthority`).
      getter level : Int32?

      # The programmatic channels the role may use (`mcp`, `webhook`, `api`,
      # `assistant`), read from the role projection content's
      # `connectivity` array. An absent or malformed field reads as empty —
      # browser-only. Powers the assistant channel flag and the
      # role-authority containment check (`RBAC::RoleAuthority`).
      getter connectivity : Set(String)

      # The assistant token budget (`nil` = unlimited), read from the role
      # projection content. Pairs with the `assistant` connectivity channel
      # in the role-authority containment check.
      getter assistant_token_budget : Int64?

      # True for synthetic marker roles: the `denied` fail-closed fallback
      # and the domain-editor grant. They are not stored `iam.Roles`
      # documents — no projection id references them — so provenance
      # stamping treats them as role-less (see `stored_role_id`).
      getter? synthetic : Bool

      # Default visible_tags when a role has none specified.
      # Fail-closed: a role with no explicit value sees only untagged fields.
      DEFAULT_VISIBLE_TAGS = Set{"default"}

      # Wildcard tag that emits all fields.
      WILDCARD_TAG = "*"

      # Creates an ActiveRole from a raw role projection content.
      def self.from_projection_content(content : JSON::Any) : self
        h = content.as_h

        role_id = h["name"]?.try(&.as_s) || raise ArgumentError.new("Role missing 'name'")
        visible_tags_raw = h["visible_tags"]?.try(&.as_a?.try(&.map(&.as_s)))
        perms_raw = h["permissions"]?.try(&.as_a) || [] of JSON::Any
        level = h["level"]?.try(&.as_i?)
        connectivity = Set.new(
          (h["connectivity"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?)
        )
        assistant_budget = h["assistant_token_budget"]?.try(&.as_i64?)

        visible_tags = if visible_tags_raw
                         Set.new(visible_tags_raw)
                       else
                         DEFAULT_VISIBLE_TAGS
                       end

        permissions = perms_raw.map { |p| Permission.from_json(p) }

        new(
          role_id: role_id, visible_tags: visible_tags, permissions: permissions,
          level: level, connectivity: connectivity,
          assistant_token_budget: assistant_budget,
        )
      end

      def initialize(
        @role_id : String,
        @visible_tags : Set(String),
        @permissions : Array(Permission),
        @level : Int32? = nil,
        @connectivity : Set(String) = Set(String).new,
        @assistant_token_budget : Int64? = nil,
        @synthetic : Bool = false,
      )
      end

      # The role's qualified projection id (`iam.Roles.admin`) — the same
      # string the JWT `role` claim, the `api_keys.role_id` row, and the
      # account `roles` array use. `role_id` carries the bare content
      # `name`; role names match `^[a-z][a-z0-9_]*$` (no dots), so the
      # prefix is unambiguous — the same qualification `Assistant::Access`,
      # `ImportExport::CallerContext`, and the upload-grant mint apply.
      # Nil for synthetic marker roles: no role document backs them, so no
      # stored reference may point at one.
      def stored_role_id : String?
        return nil if @synthetic
        "iam.Roles.#{role_id}"
      end

      # True when the role's connectivity list carries the given channel.
      def channel?(name : String) : Bool
        @connectivity.includes?(name)
      end

      # Returns true if the visible_tags contain the wildcard (admin / all-seeing).
      def wildcard_tags? : Bool
        @visible_tags.includes?(WILDCARD_TAG)
      end

      # Collects all permission lines matching the given action and path.
      # Intra-role union: multiple matching lines have their scopes OR-ed.
      def matching_permissions(action : String, domain : String, path : Array(String)) : Array(Permission)
        @permissions.select do |p|
          p.matches_action?(action) && p.matches_path?(domain, path)
        end
      end

      # Checks if this role has at least one matching permission line
      # for the given action and path (ignoring scope — use enforcers for that).
      def grants?(action : String, domain : String, path : Array(String)) : Bool
        @permissions.any? { |p| p.matches_action?(action) && p.matches_path?(domain, path) }
      end
    end
  end
end
