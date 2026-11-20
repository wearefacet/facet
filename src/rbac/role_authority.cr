# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./permission"
require "./active_role"
require "./auth_context"
require "./account_loader"
require "./error"
require "../error"
require "../validation_error"
require "../iam/role_store"

module Facet
  module RBAC
    # Caller-authority boundary for the IAM doctypes (`iam.Account`,
    # `iam.Roles`).
    #
    # Every caller-controlled write on those doctypes — document create,
    # update, and delete, named actions, and rollback transitions — passes
    # through one transition API. The elected active role is the caller
    # authority; held roles are never merged (the one-active-role rule).
    # The checks:
    #
    # - **Caller level** — read from the elected role's `level`. A missing
    #   or malformed level denies the write (fail closed). System keeps its
    #   repair path and Preview keeps its existing draft-domain bypass.
    # - **Account assignment** — every role in the final `roles` array must
    #   exist, be live, and have `level ≤ caller level`; `default_role`,
    #   when present, must be a member of `roles`. Same-level lateral
    #   assignment is deliberate policy: a caller may assign an existing
    #   role at or below its level even when that role holds permissions
    #   the caller does not.
    # - **Target protection** — a caller cannot update, delete, or action an
    #   account (or a role) whose *current* ceiling is above its level.
    #   This blocks the `admin.level 100 → 30` lowering attack before any
    #   assignment check runs.
    # - **Role authoring** — the resulting level must not exceed the caller
    #   level; every resulting permission line must be implied by a line
    #   from the previous role or the caller's role (`Permission#implied_by?`);
    #   new visible tags must sit inside the union of previous and caller
    #   tags; the assistant power pair (access + budget) must be implied by
    #   one baseline, never a merge of two, with one repair exception — the
    #   role holding the caller's own active role may always restore its
    #   budget to what the caller's other baselines imply (the assistant
    #   budget lock, B-372); and any unrecognized role-power field that the
    #   write adds or changes is denied until this module learns its
    #   semantics. `name` and `description` are safe metadata.
    #
    # Denials are `403` `ServiceError`s with structured field or
    # permission-line details. The guard runs after normalization and
    # structural validation and is independent of route-level
    # `skip_authorization` — only the System principal bypasses it.
    module RoleAuthority
      # Role fields with explicit power semantics (plus the safe metadata
      # pair). A Real write that adds or changes any other field is denied.
      KNOWN_ROLE_FIELDS = %w[
        name description level permissions visible_tags
        connectivity assistant_token_budget
      ]

      # Role fields any caller may set freely — no authority semantics.
      SAFE_ROLE_FIELDS = %w[name description]

      # The one entry point. `operation` is one of `create`, `update`,
      # `delete`, `action`. `previous` is the target's current content
      # (`nil` on create); `resulting` is the content the write would land
      # (`nil` on delete). Returns `nil` when the transition is allowed.
      def self.authorize_transition(
        db : DB::Connection,
        operation : String,
        domain : String,
        doc_type : String,
        previous : JSON::Any?,
        resulting : JSON::Any?,
        auth_context : AuthContext,
      ) : Facet::ServiceError?
        return nil if auth_context.system?
        return nil if auth_context.preview?
        return nil unless iam_target?(domain, doc_type)

        real = auth_context.principal
        return nil unless real.is_a?(Principal::Real)
        caller = real.active_role

        caller_level = caller.level
        return denial(["elected role carries no usable authority level"]) if caller_level.nil?

        case {domain, doc_type}
        when {"iam", "Account"}
          authorize_account(db, operation, previous, resulting, caller_level)
        when {"iam", "Roles"}
          escapes = assistant_escapes(db, auth_context, caller, previous, resulting)
          authorize_roles(db, operation, previous, resulting, caller, caller_level, escapes)
        else
          nil
        end
      end

      # ── iam.Account ─────────────────────────────────────────────────────

      private def self.authorize_account(
        db : DB::Connection,
        operation : String,
        previous : JSON::Any?,
        resulting : JSON::Any?,
        caller_level : Int32,
      ) : Facet::ServiceError?
        # Target protection: an account whose current ceiling is above the
        # caller level is read-only to that caller — update, action, and
        # delete all refuse, including cosmetic edits. This closes the
        # `admin.level 100 → 30` attack before the assignment checks run.
        if previous && operation != "create"
          ceiling = account_ceiling(db, previous)
          return ceiling if ceiling.is_a?(Facet::ServiceError)
          if (c = ceiling.as(Int32)) && c > caller_level
            return denial(["account's current role ceiling (#{c}) is above the caller level (#{caller_level})"])
          end
        end

        return nil if resulting.nil?

        # Assignment checks run against the final content: every role in
        # the final array must exist, be live, and sit at or below the
        # caller level.
        role_refs = string_array(resulting, "roles")
        details = [] of String
        role_refs.each do |ref|
          level = role_level(db, ref)
          if level.nil?
            details << "role '#{ref}' does not exist, is deleted, or carries no usable level"
          elsif level > caller_level
            details << "role '#{ref}' (level #{level}) is above the caller level (#{caller_level})"
          end
        end

        default_role = default_role_ref(resulting)
        if default_role
          unless role_refs.includes?(default_role)
            details << "default_role '#{default_role}' is not a member of the final roles array"
          end
        end

        details.empty? ? nil : denial(details)
      end

      # The highest level among an account's currently assigned roles.
      # Unresolvable role content (missing, deleted, or level-less) denies —
      # fail closed, System repairs.
      private def self.account_ceiling(db : DB::Connection, content : JSON::Any) : Int32 | Facet::ServiceError
        ceiling = 0
        string_array(content, "roles").each do |ref|
          level = role_level(db, ref)
          return denial(["assigned role '#{ref}' does not exist, is deleted, or carries no usable level"]) if level.nil?
          ceiling = level if level > ceiling
        end
        ceiling
      end

      # ── iam.Roles ───────────────────────────────────────────────────────

      private def self.authorize_roles(
        db : DB::Connection,
        operation : String,
        previous : JSON::Any?,
        resulting : JSON::Any?,
        caller : ActiveRole,
        caller_level : Int32,
        escapes : Array(ActiveRole),
      ) : Facet::ServiceError?
        # Target protection: the current role level gates update, action,
        # and delete before any power comparison — a narrowing-only PATCH of
        # a higher role is still a write to a stronger authority.
        if previous && operation != "create"
          prev_level = content_level(previous)
          return denial(["existing role carries no usable level"]) if prev_level.nil?
          return denial(["existing role level (#{prev_level}) is above the caller level (#{caller_level})"]) if prev_level > caller_level
        end

        return nil if resulting.nil?

        if operation == "delete"
          return nil
        end

        details = [] of String

        # Explicit resulting level, against the caller level.
        new_level = content_level(resulting)
        if new_level.nil?
          details << "resulting role carries no usable level"
        elsif new_level > caller_level
          details << "resulting level (#{new_level}) is above the caller level (#{caller_level})"
        end

        # Unrecognized role-power fields. `name` and `description` are safe
        # metadata; everything else outside the known set denies when the
        # write adds or changes it.
        unknown_field_errors(previous, resulting).each { |d| details << d }

        # Power containment: the resulting role must stay inside the union
        # of the previous role's power (on update/action) and the caller's
        # own power. On create there is no previous baseline.
        baselines = [caller]
        if previous && operation != "create"
          baselines << ActiveRole.from_projection_content(previous)
        end

        details.concat(permission_line_errors(resulting, baselines))
        details.concat(tag_errors(previous, resulting, caller))
        details.concat(assistant_power_errors(previous, resulting, baselines, escapes))

        details.empty? ? nil : denial(details)
      end

      # Every resulting permission line must be implied by one baseline line
      # (previous or caller). Line-level details name the offending index.
      private def self.permission_line_errors(resulting : JSON::Any, baselines : Array(ActiveRole)) : Array(String)
        lines = resulting["permissions"]?.try(&.as_a?) || [] of JSON::Any
        errors = [] of String
        lines.each_with_index do |raw, idx|
          line = begin
            Permission.from_json(raw)
          rescue ex : ArgumentError
            errors << "permissions[#{idx}] is not a valid permission line (#{ex.message})"
            next
          end
          unless baselines.any? { |b| b.permissions.any? { |p| line.implied_by?(p) } }
            errors << "permissions[#{idx}] (#{line.action} on #{line.domain}.#{line.path.join(".")}) is not implied by the previous role or the caller's role"
          end
        end
        errors
      end

      # New visible tags must be contained by the union of the previous and
      # caller tags. The wildcard tag contains everything.
      private def self.tag_errors(previous : JSON::Any?, resulting : JSON::Any?, caller : ActiveRole) : Array(String)
        union = caller.visible_tags.to_a
        union += tags_of(previous) if previous
        return [] of String if union.includes?(ActiveRole::WILDCARD_TAG)

        unmet = tags_of(resulting).reject { |t| union.includes?(t) }
        unmet.empty? ? [] of String : ["visible_tags #{unmet.map { |t| "'#{t}'" }.join(", ")} exceed the previous and caller tag union"]
      end

      # The assistant power pair is one value: the resulting pair must be
      # implied by ONE baseline (previous or caller), never assembled from
      # two. Disabled access is the narrowest state; unlimited budget is
      # broader than every numeric budget. The assistant channel rides the
      # `connectivity` list — the same containment covers a widening from
      # `[]` to a channel-carrying list.
      #
      # `escapes` holds the caller's other baselines, present only when the
      # write targets the caller's own active role (see `assistant_escapes`).
      # A budget at or below one of them restores the budget instead of
      # widening it: the role is the caller's own, and the account-wide
      # effective budget is already the maximum over every held enabling
      # role, so the restore cannot raise what the account may spend.
      private def self.assistant_power_errors(previous : JSON::Any?, resulting : JSON::Any?, baselines : Array(ActiveRole), escapes : Array(ActiveRole)) : Array(String)
        enabled = connectivity_contains?(resulting, "assistant")
        budget = resulting.try(&.["assistant_token_budget"]?).try(&.as_i64?)

        return [] of String if baselines.any? { |b| assistant_power_implied_by?(enabled, budget, b) }
        return [] of String if enabled && escapes.any? { |b| assistant_power_implied_by?(enabled, budget, b) }

        if enabled
          ["assistant access or budget exceeds every enabling baseline (previous role and caller role)"]
        else
          # Disabled access is implied by every baseline; reaching here
          # means the budget alone widened past all of them.
          ["assistant token budget exceeds every baseline (previous role and caller role)"]
        end
      end

      private def self.assistant_power_implied_by?(enabled : Bool, budget : Int64?, baseline : ActiveRole) : Bool
        return true unless enabled
        return false unless baseline.channel?("assistant")

        baseline_budget = baseline.assistant_token_budget
        return true if baseline_budget.nil?
        return false if budget.nil?
        budget <= baseline_budget
      end

      # The assistant-budget lock escape (B-372).
      #
      # The guard's baselines are the caller's elected role and the previous
      # role content. When both are the same role — the caller writes their
      # own active role — the lowered budget becomes its own baseline, and a
      # raise or clear is refused even though nothing else constrains it.
      # The lock is then one-way: rolling usage past the lowered budget
      # answers `429` on every assistant turn (`Assistant::Limits`), and no
      # role write can lift it.
      #
      # The escape returns the caller's *other* baselines (the account's
      # remaining roles, read from the account projection) and is empty in
      # every other case. The account-wide effective budget is the maximum
      # over its held enabling roles (`Assistant::Access.effective_budget`),
      # so a restore at or below one of them never raises what the account
      # may spend — it only releases the role that is its own ceiling. The
      # `iam.Roles` write permission is still required, and the caller level
      # and target-protection rules still apply.
      private def self.assistant_escapes(
        db : DB::Connection,
        auth_context : AuthContext,
        caller : ActiveRole,
        previous : JSON::Any?,
        resulting : JSON::Any?,
      ) : Array(ActiveRole)
        return [] of ActiveRole if previous.nil? || resulting.nil?
        return [] of ActiveRole unless previous["name"]?.try(&.as_s?) == caller.role_id
        return [] of ActiveRole if auth_context.can?("update", "iam", ["Roles"]).is_a?(CanResult::Denied)

        role_ids = AccountLoader.load_role_ids(db, auth_context.account_id) || return [] of ActiveRole
        role_ids.compact_map do |role_id|
          next if role_id == caller.stored_role_id
          content = IAM::RoleStore.fetch(db, role_id)
          content.try { |c| ActiveRole.from_projection_content(c) }
        end
      end

      # True when the content's `connectivity` array names the channel. A
      # missing or malformed array reads as empty.
      private def self.connectivity_contains?(content : JSON::Any?, channel : String) : Bool
        return false if content.nil?
        channels = content["connectivity"]?.try(&.as_a?) || return false
        channels.any?(&.as_s?.try(&.==(channel)))
      end

      # A Real write that adds or changes an unrecognized role field is
      # denied until `RoleAuthority` learns its power semantics. Unchanged
      # pre-existing fields pass (System wrote them, or history carries
      # them) — the rule gates this write, not the stored shape.
      private def self.unknown_field_errors(previous : JSON::Any?, resulting : JSON::Any?) : Array(String)
        result_h = resulting.as_h?
        return [] of String if result_h.nil?

        errors = [] of String
        result_h.each_key do |key|
          next if KNOWN_ROLE_FIELDS.includes?(key)
          next if SAFE_ROLE_FIELDS.includes?(key)

          if previous.nil?
            errors << "'#{key}' is not a recognized role field"
          else
            prev_h = previous.as_h?
            if prev_h.nil? || prev_h[key]? != result_h[key]
              errors << "'#{key}' is not a recognized role field and this write changes it"
            end
          end
        end
        errors
      end

      # ── Shared lookups ──────────────────────────────────────────────────

      private def self.iam_target?(domain : String, doc_type : String) : Bool
        {domain, doc_type} == {"iam", "Account"} || {domain, doc_type} == {"iam", "Roles"}
      end

      # Resolves one role reference to its level through the shared role
      # content cache (`IAM::RoleStore` — the same reader every role load
      # uses). `nil` — missing, deleted, or level-less — denies.
      private def self.role_level(db : DB::Connection, role_ref : String) : Int32?
        content = IAM::RoleStore.fetch(db, role_ref)
        return nil if content.nil?
        content_level(content)
      end

      private def self.content_level(content : JSON::Any) : Int32?
        content.as_h?.try(&.["level"]?).try(&.as_i64?).try(&.to_i32)
      end

      private def self.string_array(content : JSON::Any, key : String) : Array(String)
        content.as_h?.try(&.[key]?).try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      end

      private def self.default_role_ref(content : JSON::Any) : String?
        raw = content.as_h?.try(&.["default_role"]?)
        return nil if raw.nil? || raw.raw.nil?
        raw.as_s?
      end

      private def self.tags_of(content : JSON::Any?) : Array(String)
        return [] of String if content.nil?
        content.as_h?.try(&.["visible_tags"]?).try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      end

      private def self.denial(details : Array(String)) : Facet::ServiceError
        Facet::ServiceError.new(
          403,
          "Role authority refused this write",
          details: details.map { |d| ValidationError.new(d, code: "forbidden") },
        )
      end
    end
  end
end
