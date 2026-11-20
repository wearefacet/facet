# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./grant"
require "./app_scope"
require "./active_role"
require "./permission"

module Facet
  module RBAC
    # Grant resolution engine: pure, I/O-free security logic that intersects
    # an application's grants with an active role's permissions.
    #
    # Two functions:
    #
    # - `role_usable?(app, role)` — strict-ALL on required actions. A role
    #   is usable with an app if and only if it covers **every** required
    #   action declared across **every** grant entry. A single missing
    #   required action rejects the role. Optional actions never reject.
    #
    # - `resolve(app, role)` — the granular intersection. For every grant
    #   entry, finds the role permissions whose `(domain, path)` the grant
    #   covers, then for each declared action emits the role permissions
    #   that actually grant it. Required and optional actions participate
    #   symmetrically in `resolve` — the required/optional distinction is
    #   a usability gate, not a resolution filter.
    #
    # Both functions are pure: no HTTP, no DB, no `Doctype::DefinitionStore`,
    # no `ScopeExpander`. Resource scope (named scopes, context sets)
    # survives untouched in the emitted `Permission`s; the enforcer runs
    # scope predicates exactly as today.
    #
    # See `doc/backend/app-system.md` for the full design.
    module GrantResolver
      # True if the role is acceptable for use with this app.
      #
      # Acceptable means: for every grant action marked `required: true`
      # on every grant entry, the role covers the de-wildcarded target
      # doctype and grants the action (after `write` expansion).
      #
      # The check is conjunctive across required actions AND across grant
      # entries: one missing required action ⇒ `false`.
      def self.role_usable?(app : AppScope, role : ActiveRole) : Bool
        missing_required_actions(app, role).empty?
      end

      # The required grant actions the role does **not** cover, one entry
      # per required action per grant target ("update on fin.Invoice").
      # Pure diagnostics over the same intersection `role_usable?` walks:
      # an empty result means the role is usable. Consumers log the gap
      # (an app-owned API key whose role misses a required action fails
      # closed with an opaque 401 — the response names nothing by design,
      # so the server-side log is the operator's only signal).
      def self.missing_required_actions(app : AppScope, role : ActiveRole) : Array(String)
        missing = [] of String
        app.grants.each do |grant|
          grant.required_actions.each do |required|
            label = "#{required.name} on #{grant.target}"
            next if missing.includes?(label)
            missing << label unless role_covers_action?(grant, required.name, role)
          end
        end
        missing
      end

      # Resolves the effective scope: the intersection of `app.grants` and
      # `role.permissions`.
      #
      # For each grant entry:
      #
      # 1. Find every role permission whose `(domain, path)` the grant
      #    covers (`Grant#covers?`). A `crm.*` grant collects role
      #    permissions on every `crm.X` doctype the role holds.
      # 2. If no role permission matches, the grant is absent from the
      #    result entirely (whether this rejected the role was already
      #    decided by `role_usable?` based on required actions).
      # 3. For each matching concrete doctype path, group the matching
      #    permissions and emit one `Entry`. The entry's `actions` set
      #    contains every declared action name (post `write` expansion)
      #    that at least one matching role permission grants. `actions`
      #    may be a strict subset of the grant's declared actions — the
      #    optional-action-with-role-missing case yields exactly that.
      # 4. An entry with zero covered actions is not emitted — the role
      #    covers the doctype but none of the granted actions, so the
      #    grant contributes nothing the token may actually do.
      def self.resolve(app : AppScope, role : ActiveRole) : EffectiveScope
        entries = [] of EffectiveScope::Entry

        app.grants.each do |grant|
          entries.concat(resolve_grant(grant, role))
        end

        EffectiveScope.new(merge_entries(entries))
      end

      # ── Internals ──────────────────────────────────────────────────────

      # Collapses entries that resolve to the same concrete `(domain, path)`
      # — a wildcard grant (`crm.*`) plus a specific grant (`crm.Contact`)
      # both contribute a Contact entry when the role holds a matching
      # permission. The actions union and the permission lists concat,
      # which is exactly the per-entry union the enforcer computes, so
      # enforcement is unchanged; the consent surface gets one row per
      # doctype instead of contradictory duplicates. First `target` wins
      # (display-only traceability).
      private def self.merge_entries(entries : Array(EffectiveScope::Entry)) : Array(EffectiveScope::Entry)
        merged = [] of EffectiveScope::Entry
        entries.each do |entry|
          index = merged.index { |m| m.domain == entry.domain && m.path == entry.path }
          if index.nil?
            merged << entry
            next
          end

          prev = merged[index]
          actions = Set(String).new
          prev.actions.each { |a| actions << a }
          entry.actions.each { |a| actions << a }
          merged[index] = EffectiveScope::Entry.new(
            target: prev.target,
            domain: prev.domain,
            path: prev.path,
            actions: actions,
            permissions: (prev.permissions + entry.permissions).uniq,
          )
        end
        merged
      end

      # Resolves a single grant into zero or more `Entry`s.
      #
      # A wildcard grant (`domain.*`) may produce multiple entries — one
      # per concrete doctype the role actually holds a permission on.
      # A concrete grant (`domain.Doctype`) produces at most one entry.
      #
      # When a matching role permission is itself wildcard (`*.*` admin),
      # the entry's concrete `(domain, path)` is taken from the grant
      # target — the grant is strictly a ceiling, so a `crm.Contact` grant
      # combined with an admin `*.*` permission collapses to a single
      # entry on `crm.Contact`, NOT a wildcard entry on `*`.
      private def self.resolve_grant(grant : Grant, role : ActiveRole) : Array(EffectiveScope::Entry)
        # 1. Role permissions this grant covers.
        matching = role.permissions.select do |perm|
          grant.covers?(perm.domain, perm.path)
        end

        return [] of EffectiveScope::Entry if matching.empty?

        # 2. Group by the *entry* coordinates, which collapse a wildcard
        # role permission onto the grant's de-wildcarded target.
        matching_by_coords = matching.group_by do |perm|
          entry_coordinates(grant, perm)
        end

        declared_action_names = grant.actions.map(&.name).to_set

        entries = [] of EffectiveScope::Entry
        matching_by_coords.each do |(domain, path), perms_for_coords|
          covered_actions = covered_actions(declared_action_names, perms_for_coords)
          next if covered_actions.empty?

          entries << EffectiveScope::Entry.new(
            target: grant.target,
            domain: domain,
            path: path,
            actions: covered_actions,
            permissions: perms_for_coords,
          )
        end
        entries
      end

      # The concrete `(domain, path)` coordinates of the entry a matching
      # permission contributes to.
      #
      # - When the permission is concrete (e.g. role perm on
      #   `crm.Contact.Comment` matched by grant `crm.Contact`), the entry
      #   takes the permission's coordinates — descendant paths survive.
      # - When the permission is wildcard (`*.*` admin or `domain.*`),
      #   the entry takes the grant's de-wildcarded target — the grant is
      #   strictly a ceiling, so a `crm.Contact` grant + admin permission
      #   emits an entry on `crm.Contact`, not on `*`.
      private def self.entry_coordinates(
        grant : Grant,
        perm : Permission,
      ) : {String, Array(String)}
        if perm.domain == Permission::WILDCARD_DOMAIN || perm.path == [Permission::WILDCARD_DOCTYPE]
          {grant.domain, grant.path}
        else
          {perm.domain, perm.path}
        end
      end

      # True if the role covers the grant's target (possibly a wildcard)
      # and grants the given action.
      #
      # A wildcard grant (`domain.*`) is satisfied when the role holds, on
      # at least one `domain.X` doctype, a permission whose action covers
      # `action`. (`*` matches any concrete action — see
      # `Permission#matches_action?`.)
      private def self.role_covers_action?(grant : Grant, action : String, role : ActiveRole) : Bool
        role.permissions.any? do |perm|
          grant.covers?(perm.domain, perm.path) &&
            perm.matches_action?(action) &&
            line_reaches_grant_target?(perm, grant)
        end
      end

      # A carve-out on the role line disqualifies it for a concrete grant
      # target: `read *.* except core.SystemSettings` does not grant read on
      # `core.SystemSettings` — not at this gate, and not at enforcement
      # (`Permission#matches_path?` refuses carved-out targets). Keeping the
      # gate except-aware is what makes the setup-time warning and the
      # launcher agree with every runtime decision. A wildcard grant target
      # (`crm.*`) keeps the lenient reading: the line qualifies when at
      # least one doctype in the domain survives the carve-out.
      private def self.line_reaches_grant_target?(perm : Permission, grant : Grant) : Bool
        return true if grant.wildcard_target?
        perm.except_paths.none? { |entry| except_covers_grant_target?(entry, grant) }
      end

      # Mirror of `Permission#matches_except?` against the grant's target:
      # an entry covers the grant when its domain equals the grant's domain
      # and its path is a prefix of the grant's path (an entry on
      # `core.DocType` also carves `core.DocType.Comment`).
      private def self.except_covers_grant_target?(entry : String, grant : Grant) : Bool
        parts = entry.split('.')
        entry_domain = parts[0]
        entry_path = parts[1..]
        entry_domain == grant.domain &&
          entry_path.size <= grant.path.size &&
          entry_path.zip(grant.path).all? { |a, b| a == b }
      end

      # The subset of `declared_actions` that the role actually grants.
      #
      # For each declared grant action name, scan the matching permissions;
      # the action is covered if any matching permission grants it (an
      # `*` action permission covers any concrete action).
      private def self.covered_actions(
        declared_actions : Set(String),
        perms : Array(Permission),
      ) : Set(String)
        covered = Set(String).new
        declared_actions.each do |action|
          if perms.any?(&.matches_action?(action))
            covered << action
          end
        end
        covered
      end
    end
  end
end
