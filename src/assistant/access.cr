# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "db"
require "json"

require "../database"
require "../iam/helpers"
require "../rbac/auth_context"

module Facet
  module Assistant
    # Availability gate for the workspace assistant.
    #
    # Access rides the one active role: RBAC runs exactly one active role
    # per request and roles never merge (see `doc/backend/rbac.md`), so the
    # assistant gate reads `connectivity` off that role alone — the channel
    # must be listed for the assistant to open. The former
    # ANY-over-held-roles aggregation is retired. The token budget stays
    # the one account-wide aggregation: `effective_budget` takes the
    # maximum budget over the enabling roles the account holds, any unset
    # budget meaning unlimited. The asymmetry is deliberate: access asks
    # "may this active role open the assistant", budget asks "how much may
    # this account spend".
    module Access
      # True when the role projection's content lists `assistant` in its
      # `connectivity` array. A missing or malformed field reads as off —
      # the field's closed vocabulary is enforced at authoring time by the
      # `iam.Roles` hook. Shared by the HTTP gates and the `/Api/iam/me`
      # payload (which reuses the role content it already loads for the
      # permission manifest).
      def self.role_enabled?(content : JSON::Any) : Bool
        channels = content["connectivity"]?.try(&.as_a?) || return false
        channels.any? do |channel|
          channel.as_s?.try(&.==("assistant")) == true
        end
      end

      # Availability of one named role — the primitive both the
      # auth-context gate and the `/Api/iam/me` payload build on. A missing
      # projection (tombstoned role, dangling reference) fails closed.
      def self.allowed_for_role?(db : DB::Connection, role_id : String) : Bool
        content = IAM::Helpers.find_role_content(db, role_id)
        return false if content.nil?

        role_enabled?(content)
      end

      # Same gate for an `AuthContext`: the system bypass is internal and
      # unrestricted; every principal without a loaded active role (the
      # denied anonymous principal, the preview capability) fails closed;
      # a real principal reads its active role's channel list.
      #
      # `ActiveRole.role_id` carries the bare role name (the convention
      # `ImportExport::CallerContext.role_reference` also builds on), while
      # the role projection lives at the qualified `iam.Roles.<name>` id —
      # the gate qualifies it the same way. Role names match
      # `^[a-z][a-z0-9_]*$` (no dots), so the prefix is unambiguous.
      def self.allowed?(db : DB::Connection, auth_context : RBAC::AuthContext) : Bool
        return true if auth_context.system?

        principal = auth_context.principal
        return false unless principal.is_a?(RBAC::Principal::Real)

        account_id = principal.account_id
        return false if account_id.empty? || account_id == "anonymous"
        allowed_for_role?(db, "iam.Roles.#{principal.active_role.role_id}")
      end

      # The token budget in force for the account, or `nil` when unlimited.
      #
      # Unlimited (`nil`) when any enabling role has no
      # `assistant_token_budget`; otherwise the **maximum** budget among
      # the enabling roles. Both directions permissive — adding a role
      # never silently removes a budget, and adding a budget never
      # silently lowers an existing one. A non-enabling role's budget
      # never contributes, and a role id the projection is missing
      # (tombstoned role, dangling reference) contributes nothing. A
      # malformed budget value reads as unset (fail-open — unreachable
      # through the mutation path since the field gained `min: 0`).
      def self.effective_budget(db : DB::Connection, account_id : String) : Int64?
        any_unset = false
        max_budget : Int64? = nil

        held_role_ids(db, account_id).each do |role_id|
          content = IAM::Helpers.find_role_content(db, role_id)
          next if content.nil?

          next unless role_enabled?(content)

          budget = content["assistant_token_budget"]?.try(&.as_i64?)
          if budget.nil?
            any_unset = true
          elsif max_budget.nil? || budget > max_budget
            max_budget = budget
          end
        end

        any_unset ? nil : max_budget
      end

      # ── Private helpers ──────────────────────────────────────────────────

      # The role references the account holds: the `roles` array plus
      # `default_role` when set. Deduplicated, order irrelevant.
      private def self.held_role_ids(db : DB::Connection, account_id : String) : Array(String)
        row = db.query_one?(
          <<-SQL,
            SELECT content->'roles', content->>'default_role'
            FROM projections
            WHERE domain = 'iam' AND doc_type = 'Account'
              AND id = $1 AND deleted_at IS NULL
          SQL
          account_id,
        ) do |rs|
          roles_raw = rs.read(JSON::Any?)
          default_role = rs.read(String?)
          roles = roles_raw.try(&.as_a?.try(&.map(&.as_s))) || [] of String
          {roles, default_role}
        end

        return [] of String unless row

        roles, default_role = row
        if default_role && !default_role.empty? && !roles.includes?(default_role)
          roles << default_role
        end
        roles
      end
    end
  end
end
