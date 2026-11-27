# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./permission"

module Facet
  module RBAC
    # A single grant entry declared on an `app.App` document.
    #
    # A grant is a ceiling on what an application may reach through Facet.
    # It is **policy, not a permission**: confers no rights by itself. The
    # effective scope at request time is `grant ∩ role`, computed per
    # operation at the service layer (see `GrantResolver`).
    #
    # Each grant carries:
    #
    # - `target` — a doctype path. Either a qualified `domain.Doctype`
    #   (e.g. `crm.Contact`) or a domain wildcard `domain.*` (e.g. `crm.*`).
    #   Bare doctype names and the global `*.*` wildcard are rejected at
    #   parse time: grants always name a concrete domain.
    # - `actions` — one or more action declarations. Each declaration is a
    #   `(name, required)` pair. The `required` flag is per action: a role
    #   that lacks a required action is rejected; an optional action is
    #   present in the effective scope only when the role grants it.
    #
    # The grant's `actions` vocabulary uses `write` as an alias for
    # `{create, update}`. The alias is expanded once at parse time, so a
    # grant carrying `[{name: write, required: true}]` becomes a grant with
    # two required action declarations: `create` and `update`.
    #
    # Resource scope (named scopes, context sets) is **not** encoded here.
    # A role's scope predicates survive into the app token untouched and
    # continue to apply at the service layer exactly as they do today.
    struct Grant
      # A single action declaration on a grant.
      #
      # `name` is normalised: `write` is expanded upstream into two
      # separate `Action` declarations (`create`, `update`), so `name`
      # never carries the alias form after parsing.
      record Action,
        name : String,
        required : Bool

      # The wildcard token used in `target` to match every doctype in the
      # named domain. The global `*.*` form is **not** accepted as a grant
      # target — a grant always names a concrete domain.
      DOMAIN_WILDCARD_DOCTYPE = "*"

      getter target : String      # original target string, e.g. "crm.Contact" or "crm.*"
      getter domain : String      # parsed domain segment, e.g. "crm"
      getter path : Array(String) # parsed doctype path, e.g. ["Contact"] or ["*"]
      getter actions : Array(Action)

      # True when the target is the domain wildcard form (`crm.*`). The
      # authoring gate refuses this form on `app.App` grants — an app names
      # the concrete doctypes it uses. The resolver keeps the lenient
      # "at least one doctype survives" reading for content that reaches
      # it without passing the gate (import), so enforcement never crashes
      # on such a row.
      def wildcard_target? : Bool
        @path == [DOMAIN_WILDCARD_DOCTYPE]
      end

      # Parses a grant from a raw JSON object.
      #
      # Wire format:
      #
      # ```json
      # {
      #   "target": "crm.Contact",
      #   "actions": [
      #     {"name": "read",  "required": true},
      #     {"name": "write", "required": false}
      #   ]
      # }
      # ```
      #
      # The `required` flag on each action defaults to `false` when absent
      # (so an action without the flag is optional). `write` is expanded to
      # `{create, update}`: a declaration `{name: write, required: X}`
      # becomes two declarations `{name: create, required: X}` and
      # `{name: update, required: X}`.
      def self.from_json(raw : JSON::Any) : self
        h = raw.as_h? || raise ArgumentError.new(
          "Grant must be a JSON object (got: #{raw.raw.inspect})"
        )

        target = h["target"]?.try(&.as_s?) || raise ArgumentError.new(
          "Grant 'target' must be a string"
        )
        domain, path = parse_target(target)

        actions_raw = h["actions"]?.try(&.as_a?) || raise ArgumentError.new(
          "Grant 'actions' must be an array"
        )

        actions = [] of Action
        seen = Set(String).new
        actions_raw.each do |a_raw|
          a = a_raw.as_h? || raise ArgumentError.new(
            "Grant action must be a JSON object (got: #{a_raw.raw.inspect})"
          )
          name = a["name"]?.try(&.as_s?) || raise ArgumentError.new(
            "Grant action 'name' must be a string"
          )
          required = parse_required(a["required"]?)

          expand_action(name, required).each do |expanded_name|
            # A grant that declares `write` after `create` would otherwise
            # emit two `create` declarations; deduplicate so the canonical
            # form has one entry per action name. The `required` flag of
            # the first declaration wins — a later, conflicting declaration
            # is a content authoring mistake the validator will surface
            # separately, but the resolver never sees a doubled action.
            next unless seen.add?(expanded_name)
            actions << Action.new(name: expanded_name, required: required)
          end
        end

        raise ArgumentError.new("Grant 'actions' must not be empty") if actions.empty?

        new(target: target, domain: domain, path: path, actions: actions)
      end

      def initialize(
        @target : String,
        @domain : String,
        @path : Array(String),
        @actions : Array(Action),
      )
      end

      # ── Required flag helpers ──────────────────────────────────────────

      # The action declarations marked `required`.
      def required_actions : Array(Action)
        @actions.select(&.required)
      end

      # The names of the required actions, in declaration order.
      def required_action_names : Array(String)
        required_actions.map(&.name)
      end

      # True if this grant declares at least one required action.
      def has_required? : Bool
        @actions.any?(&.required)
      end

      # ── Path matching ──────────────────────────────────────────────────

      # True if this grant's reach contains the point `(other_domain,
      # other_path)` — the grant authorising semantics (`Artifact::Access`
      # asks whether a grant reaches an artifact's owner doctype).
      #
      # Wildcard rules:
      #
      # - A grant on `domain.*` covers every doctype in `domain`.
      # - A grant on `domain.Doctype` covers exactly that doctype and its
      #   descendant paths (e.g. grant `crm.Contact` covers `crm.Contact.Comment`).
      # - A grant's path may not be the global `*.*` form (rejected at parse).
      # - A point under the wildcard domain `*` (the `*.*` admin permission
      #   reading) is covered by every grant — the grant is strictly a
      #   ceiling, never an escape.
      #
      # The match is one-way: a `crm.Contact` grant does NOT cover a point
      # on `crm.Other`, and a grant on `crm.Contact.Comment` does not cover
      # a point on `crm.Contact` — a grant never reaches above its target.
      #
      # For the grant ∩ role intersection — where the argument is a
      # permission line whose path is a *reach*, not a point — use
      # `#intersects_reach?` instead: a domain-wide role line (bare
      # `crm`, empty path) has a reach that contains the grant target,
      # and the two must intersect.
      def covers?(other_domain : String, other_path : Array(String)) : Bool
        # A permission with a wildcard domain (`*.*` admin) matches every
        # grant target — regardless of this grant's domain. Only the path
        # check below applies, and any role path satisfies a `domain.*`
        # grant; for a `domain.Doctype` grant, the role's path must be
        # equal-or-descendant (or itself wildcard).
        domains_match = @domain == other_domain || other_domain == Permission::WILDCARD_DOMAIN
        return false unless domains_match

        # Domain wildcard grant: `domain.*` covers every doctype in the domain.
        return true if @path == [DOMAIN_WILDCARD_DOCTYPE]

        # A permission whose path is the wildcard `[*]` (the leaf of a
        # `*.*` admin permission) matches any concrete grant path.
        return true if other_path == [Permission::WILDCARD_DOCTYPE]

        # Otherwise the grant path must be a prefix of the point's path
        # (a grant on `crm.Contact` covers a point on `crm.Contact.Comment`).
        @path.size <= other_path.size && @path.zip(other_path).all? { |a, b| a == b }
      end

      # True if this grant's reach and a permission line's reach overlap —
      # the grant ∩ role intersection (`GrantResolver`).
      #
      # A permission line's path is a reach: the line grants its action on
      # every doctype at or below the path (`Permission#matches_path?`
      # prefix rule). The intersection is therefore reach overlap, not
      # point containment:
      #
      # - A domain-wide line (`{"on": "crm"}` — empty path) reaches every
      #   doctype in `crm`, so it intersects any `crm.X` grant target.
      # - A line above the grant target (`{"on": "crm.Contact"}` vs grant
      #   `crm.Contact.Comment`) intersects for the same reason.
      # - A line at or below the grant target intersects when the grant's
      #   reach contains the line's path (the `#covers?` rule).
      #
      # Wildcard rules mirror `#covers?`: a `domain.*` grant intersects
      # every line in the domain; a `*.*` line intersects every grant.
      # Carve-outs are NOT tested here — the resolver checks the line's
      # `except` entries against the grant target separately
      # (`GrantResolver.line_reaches_grant_target?`), because a wildcard
      # grant target keeps a lenient reading that a pure reach test
      # cannot express.
      def intersects_reach?(perm_domain : String, perm_path : Array(String)) : Bool
        domains_match = @domain == perm_domain || perm_domain == Permission::WILDCARD_DOMAIN
        return false unless domains_match

        # Domain wildcard grant: `domain.*` overlaps every reach in the domain.
        return true if @path == [DOMAIN_WILDCARD_DOCTYPE]

        # A `*.*` admin line reaches every grant target.
        return true if perm_path == [Permission::WILDCARD_DOCTYPE]

        # Prefix in either direction — the narrower reach is never empty:
        # the permission may sit at or below the grant target, or above it
        # (the bare-domain line included).
        permission_within_grant = @path.size <= perm_path.size &&
                                  @path.zip(perm_path).all? { |a, b| a == b }
        grant_within_permission = perm_path.size <= @path.size &&
                                  perm_path.zip(@path).all? { |a, b| a == b }
        permission_within_grant || grant_within_permission
      end

      # ── Parsing internals ──────────────────────────────────────────────

      private def self.parse_target(target : String) : {String, Array(String)}
        parts = target.split('.')
        if parts.size < 2
          raise ArgumentError.new(
            "Grant 'target' must include at least domain and doctype (got: '#{target}')"
          )
        end

        domain = parts[0]
        path = parts[1..]

        # Reject the global wildcard `*.*` — a grant must name a concrete
        # domain. The admin role continues to reach everything via its own
        # `*.*` permission; the grant is strictly a ceiling, never an escape.
        if domain == Permission::WILDCARD_DOMAIN
          raise ArgumentError.new(
            "Grant 'target' must name a concrete domain; the global '*.*' wildcard is not accepted (got: '#{target}')"
          )
        end

        # A `domain.*` grant is valid (covers every doctype in the domain).
        # A `domain.Foo.*` form is not — wildcard may only be the leaf segment.
        if path.size > 1 && path.any? { |seg| seg == DOMAIN_WILDCARD_DOCTYPE }
          raise ArgumentError.new(
            "Grant 'target' wildcard may only appear as the doctype segment (got: '#{target}')"
          )
        end

        {domain, path}
      end

      private def self.parse_required(raw : JSON::Any?) : Bool
        return false if raw.nil?
        case raw.raw
        when Bool
          raw.as_bool
        else
          raise ArgumentError.new(
            "Grant action 'required' must be a boolean (got: #{raw.raw.inspect})"
          )
        end
      end

      # Expands the `write` alias into `{create, update}`.
      # All other action names pass through unchanged.
      #
      # `write` is a grant-side alias only. The role permission grammar
      # refuses `write` as an action (`RBAC::Validator.validate_permissions`
      # rejects it, and the role vocabulary is
      # `create`/`update`/`delete`/`read`/`*`/named-action), so the alias
      # never appears on the role side. The grant vocabulary accepts `write`
      # purely as ergonomic shorthand that mirrors how a human author
      # thinks about "the app may edit".
      private def self.expand_action(name : String, required : Bool) : Array(String)
        return [name] unless name == "write"
        ["create", "update"]
      end
    end
  end
end
