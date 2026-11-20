# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./app_scope"

module Facet
  module RBAC
    # The authorization context for a single request.
    #
    # Bundles the caller's `Principal` (identity + role) and provides a
    # pure (I/O-free) `can?` query interface. Context set resolution is
    # not its job — that stays in the enforcers, which hold the DB
    # connection and memoize results per request.
    #
    # An optional `app_grant` attaches the resolved `EffectiveScope` of an
    # `app.App` registration. When present, every document operation is
    # pre-checked against the grant (Layer-1 enforcement): `(domain, path,
    # action)` must fall within the grant's ceiling **before** the role's
    # own `can?` is consulted. Resource scope (named scopes, context sets)
    # continues to apply unchanged on top of the role permission's scope
    # aliases — the grant narrows reach, it never widens a row-level filter.
    #
    # Construction:
    #   AuthContext.system                           # full bypass
    #   AuthContext.authenticated("user_123", role)  # real principal
    #   AuthContext.app_scoped("user_123", role, grant) # app-bound principal
    #
    # Usage:
    #   case result = auth_context.can?("read", "crm", ["Project"])
    #   in CanResult::Denied  then deny
    #   in CanResult::All     then allow
    #   in CanResult::Scoped  then evaluate_scopes(result.permissions, ...)
    #   end
    struct AuthContext
      getter principal : Principal
      getter app_grant : EffectiveScope?
      # The `app.App` projection id when this context was built from an app
      # token. `nil` for ordinary browser-session requests and for
      # the system bypass. Carried separately from `app_grant` because the
      # app id is authentication data (which app the JWT named), while the
      # `EffectiveScope` is the resolved policy ceiling. Threaded into
      # `mutations.meta.app`, app-attributed `iam.LoginEvent`s, and the
      # current OpenTelemetry span.
      getter app_id : String?
      # The role elected at authorize time on the MCP surface (the token's
      # `role` claim, which equals the mounted URL slug). `nil` on every
      # non-MCP surface. The URL pins one role for the lifetime of an MCP
      # session; stamping it into `mutations.meta.acting_role` makes that
      # one-role-per-session invariant auditable. Mutually exclusive with
      # `app_grant` / `app_id` — MCP is not an app and carries no grant.
      getter acting_role : String?
      # The `api_keys.id` row ULID when this context was built from a static
      # API key (`Authorization: Bearer fct_…`). `nil` for every other
      # authentication channel. Never the secret itself. Threaded into
      # `mutations.meta.api_key` so an audit view can answer "which key wrote
      # this mutation". Combines with `app_id` / `app_grant` only for an
      # app-owned key (the `app_api_key` channel); never with `acting_role` —
      # a request authenticates through exactly one channel.
      getter api_key_id : String?

      def initialize(@principal : Principal, @app_grant : EffectiveScope? = nil, @app_id : String? = nil, @acting_role : String? = nil, @api_key_id : String? = nil)
        validate_provenance!
      end

      # Provenance guards, fail-closed at construction:
      #
      # - The system bypass is never app-scoped, MCP-attributed, or
      #   API-key-attributed — internal callers (migrations, replication,
      #   projection triggers) always run unrestricted.
      # - A preview principal carries none of those provenance tags — the
      #   preview capability is independent of all three identities.
      # - `app_id` and `app_grant` are an app-scoped pair: always both or
      #   neither (the grant's provenance is the app token).
      # - MCP provenance never combines with an app grant: the MCP surface
      #   is not an app, carries no `EffectiveScope`, and its role comes
      #   from the URL-pinned token, not from a grant intersection.
      # - `api_key_id` combines with the app pair only for an app-owned
      #   key; a self-service key never combines with any other tag.
      private def validate_provenance! : Nil
        validate_principal_provenance!
        validate_app_pair!
        validate_channel_exclusivity!
      end

      # The system bypass and preview principals carry no provenance tag —
      # internal callers run unrestricted, and the preview capability is
      # independent of all three identities.
      private def validate_principal_provenance! : Nil
        return unless @principal.is_a?(Principal::System) || @principal.is_a?(Principal::Preview)
        return unless carries_provenance?

        raise ArgumentError.new(
          "AuthContext: a #{@principal.is_a?(Principal::System) ? "system" : "preview"} principal cannot carry an app grant, app id, acting role, or api key id"
        )
      end

      # `app_id` and `app_grant` are an app-scoped pair: always both or
      # neither (the grant's provenance is the app token).
      private def validate_app_pair! : Nil
        return if @app_id.nil? == @app_grant.nil?

        raise ArgumentError.new(
          "AuthContext: app_id and app_grant must both be present or both be nil"
        )
      end

      # Provenance tags are mutually exclusive by auth channel — a request
      # authenticates through exactly one surface. Two channel shapes exist:
      # - MCP provenance never combines with an app grant or an api key id.
      # - `api_key_id` combines with the app pair ONLY for an app-owned key
      #   (`channel: app_api_key` — the key rides on the app's grant
      #   ceiling). A self-service key never combines with anything else.
      private def validate_channel_exclusivity! : Nil
        app_scoped = !@app_grant.nil? || !@app_id.nil?
        if !@acting_role.nil? && (app_scoped || !@api_key_id.nil?)
          raise ArgumentError.new(
            "AuthContext: acting_role and app_grant/app_id/api_key_id are mutually exclusive"
          )
        end
      end

      private def carries_provenance? : Bool
        !@app_grant.nil? || !@app_id.nil? || !@acting_role.nil? || !@api_key_id.nil?
      end

      # ── Factories ──────────────────────────────────────────────────────

      # Full bypass principal. Used for internal operations (migrations,
      # projection trigger path, replication apply) and specs.
      #
      # The optional `account_id` lets a system-tier caller (e.g. the AI
      # assistant) be attributed in the mutation/audit log while still
      # bypassing every enforcer. Existing no-arg callers are unaffected.
      def self.system(account_id : String = "system") : self
        new(Principal::System.new(account_id))
      end

      # Fails when *account_id* is one of the reserved principal names.
      # The two names must stay exclusive in the audit log: "system" marks
      # the bypass principal and "anonymous" the unauthenticated caller
      # (both the denied fallback and the anonymous-role principal built by
      # `AuthHandler`). *hint* carries the factory-specific advice. Shared
      # by every factory that builds a real principal.
      private def self.assert_real_name!(account_id : String, hint : String) : Nil
        return unless account_id == "system" || account_id == "anonymous"
        raise ArgumentError.new(
          "Account ID '#{account_id}' is reserved. #{hint}"
        )
      end

      # A real authenticated principal with a loaded role.
      #
      # Raises `ArgumentError` if `account_id` is `"system"` or `"anonymous"`
      # to prevent audit-log collisions with the reserved principal names.
      def self.authenticated(account_id : String, active_role : ActiveRole) : self
        assert_real_name!(
          account_id,
          "Use AuthContext.system for bypass, or AuthContext.authenticated with a real account ID.",
        )
        new(Principal::Real.new(account_id, active_role))
      end

      # Denied principal — a `Real` principal with an empty role.
      # Every `can?` call returns `Denied`. Used as the safe fallback
      # when `AuthHandler` is enabled but the fiber-local context is nil
      # (misconfiguration, missing middleware, etc.).
      def self.denied : self
        empty_role = ActiveRole.new(
          role_id: "denied",
          visible_tags: ActiveRole::DEFAULT_VISIBLE_TAGS,
          permissions: [] of Permission,
          synthetic: true,
        )
        # No app grant — a denied principal has no app binding.
        new(Principal::Real.new("anonymous", empty_role), nil)
      end

      # An unauthenticated caller dispatched under the seeded
      # `iam.Roles.anonymous` role. `HTTP::AuthHandler` builds this context
      # when a protected route receives no credential and the role
      # projection exists; every `can?` check then follows the permissions
      # that role carries (read on `core.Currency` by default — fail-closed
      # beyond the seed).
      #
      # The principal stays a `Principal::Real` carrying the reserved
      # `"anonymous"` identity, so the existing guards keyed on
      # `account_id == "anonymous"` (assistant access, usage ledger,
      # account routes) keep working, and the enforcers treat the caller
      # exactly like any other role-limited principal — named scopes,
      # list WHERE clauses, and field masking all apply unchanged.
      #
      # Scope semantics of the reserved identity: `$self` resolves to the
      # literal `"anonymous"` (it matches no account row, so
      # `$self`-scoped grants are inert), and `$organizational_unit`
      # resolves to `"/"` (the root-safe fallback for a missing account).
      #
      # When the role projection is missing or deleted, the handler answers
      # 401 instead of building this context — fail closed.
      def self.anonymous(active_role : ActiveRole) : self
        new(Principal::Real.new("anonymous", active_role), nil)
      end

      # An app-scoped principal: an authenticated caller whose reach is
      # additionally ceiling-limited by an `app.App` grant. The
      # `EffectiveScope` is the resolved intersection of the app's grants
      # with the supplied role's permissions (see `GrantResolver.resolve`).
      # At least the role's required actions must be covered
      # (`GrantResolver.role_usable?`); the caller decides whether to
      # gate issuance on usability, but constructing an `AuthContext` with
      # a usable-role-only grant is the safe default.
      #
      # `app_id` is the `app.App` projection id the token named. It threads
      # into mutation audit (`mutations.meta.app`), app-attributed
      # `iam.LoginEvent`s, and OpenTelemetry span attributes. It must be
      # present whenever `app_grant` is present.
      #
      # Raises `ArgumentError` if `account_id` is a reserved name.
      def self.app_scoped(
        account_id : String,
        active_role : ActiveRole,
        app_grant : EffectiveScope,
        app_id : String,
        api_key_id : String? = nil,
      ) : self
        assert_real_name!(
          account_id,
          "Use AuthContext.system for bypass, or AuthContext.authenticated / app_scoped with a real account ID.",
        )
        new(Principal::Real.new(account_id, active_role), app_grant, app_id, nil, api_key_id)
      end

      # An MCP principal: an authenticated caller dispatching through the
      # `/Api/_mcp/:role_slug` resource server. The URL pins one role for
      # the lifetime of the session; `acting_role` records that role so the
      # resulting mutations are auditable as one-role-per-session (see
      # `doc/backend/mcp.md`). Authorization is the regular role-only RBAC
      # enforcement — no app grant applies.
      #
      # Raises `ArgumentError` if `account_id` is a reserved name or
      # `acting_role` is empty.
      def self.mcp(account_id : String, active_role : ActiveRole, acting_role : String) : self
        assert_real_name!(
          account_id,
          "Use AuthContext.mcp with a real account ID.",
        )
        if acting_role.empty?
          raise ArgumentError.new("AuthContext.mcp: acting_role must not be empty")
        end
        new(Principal::Real.new(account_id, active_role), nil, nil, acting_role)
      end

      # An API-key principal: an authenticated caller dispatching with a
      # static bearer key (`Authorization: Bearer fct_…`). The context is
      # identical to a browser-session principal — same RBAC enforcement —
      # plus the `api_key_id` provenance tag (`api_keys.id` row ULID, never
      # the secret) so mutations written through the key are attributable in
      # `mutations.meta.api_key`.
      #
      # Raises `ArgumentError` if `account_id` is a reserved name.
      def self.api_key(account_id : String, active_role : ActiveRole, api_key_id : String) : self
        assert_real_name!(
          account_id,
          "Use AuthContext.api_key with a real account ID.",
        )
        if api_key_id.empty?
          raise ArgumentError.new("AuthContext.api_key: api_key_id must not be empty")
        end
        new(Principal::Real.new(account_id, active_role), nil, nil, nil, api_key_id)
      end

      # A preview-scoped principal: a caller who proved at preview-session
      # issuance time (against their real identity, via the standard
      # `read`/`create core.DocType` permission) that they may edit the
      # draft's doctype definitions. The capability is scoped to the named
      # draft domain — every operation outside it is denied at the enforcer
      # (see `Principal::Preview`).
      #
      # No `ActiveRole` is loaded: the role-based permission check already
      # ran on the caller's real identity at issuance. The preview principal
      # does not consult permissions; it gates purely on domain identity.
      #
      # Raises `ArgumentError` if `account_id` is a reserved name. A preview
      # principal is never `system` — it must be attributable to a real account.
      def self.preview(account_id : String, preview_domain : String) : self
        assert_real_name!(
          account_id,
          "A preview principal must be attributed to a real account.",
        )
        if preview_domain.empty?
          raise ArgumentError.new("AuthContext.preview: preview_domain must not be empty")
        end
        new(Principal::Preview.new(account_id, preview_domain))
      end

      # ── Delegation ─────────────────────────────────────────────────────

      # The identity string that goes into mutation/audit logs.
      def account_id : String
        @principal.account_id
      end

      # True if this is the system bypass principal.
      def system? : Bool
        @principal.is_a?(Principal::System)
      end

      # True if this is a preview-mode capability principal. The enforcers
      # consult `preview_domain` (exposed below) to scope every operation.
      def preview? : Bool
        @principal.is_a?(Principal::Preview)
      end

      # The draft domain a preview principal is bound to. Returns `nil` for
      # every other principal variant; the enforcers use the non-nil path to
      # branch into the preview authorization flow.
      def preview_domain : String?
        p = @principal
        p.is_a?(Principal::Preview) ? p.preview_domain : nil
      end

      # ── Authorization query (pure, no I/O) ─────────────────────────────

      # Layer-1 app-grant pre-check. Pure: no DB, no doctype store.
      #
      # Returns `true` when the operation may proceed to the role-level
      # `can?` check; returns `false` to deny. The contract:
      #
      # - **No app grant attached** (`app_grant.nil?`) — normal request,
      #   pre-check passes. Cost is a single nil test. The role's own
      #   `can?` continues to gate the operation exactly as before.
      # - **Present but empty `EffectiveScope`** — fail-closed denial.
      #   A usable role never produces an empty scope, so this guards
      #   against a present-but-unresolvable grant reaching the service.
      # - **Present and non-empty** — the grant must contain at least one
      #   entry whose concrete `(domain, path)` is a prefix of the target
      #   path and whose `actions` set includes `action`. The prefix match
      #   mirrors `Grant#covers?` so a grant resolving to `crm.Contact`
      #   permits operations on the descendant doctype `crm.Contact.Comment`.
      #   A wildcard entry path — the collapse of a `domain.*` grant with a
      #   `*.*` role permission (see `GrantResolver.entry_coordinates`) —
      #   covers every doctype in the domain, mirroring `Grant#covers?`'s
      #   own wildcard rule.
      #
      # Resource scope is **not** consulted here. The role's scope aliases
      # survive on the matching `EffectiveScope::Entry#permissions` verbatim
      # and continue to apply unchanged via the existing `ScopeExpander` /
      # `ContextResolver` machinery. The grant narrows which `(domain, path,
      # action)` may be attempted at all; it never widens or relaxes a
      # row-level filter.
      def app_grant_permits?(action : String, domain : String, doctype_path : Array(String)) : Bool
        grant = @app_grant
        return true if grant.nil?
        return false if grant.empty?

        grant.entries.any? do |entry|
          next false unless entry.domain == domain
          unless entry.path == [Permission::WILDCARD_DOCTYPE]
            next false unless entry.path.size <= doctype_path.size
            next false unless entry.path.zip(doctype_path).all? { |a, b| a == b }
          end
          entry.actions.includes?(action)
        end
      end

      # Checks whether this principal may perform `action` on the given
      # domain and doctype path.
      #
      # Returns a `CanResult` variant:
      # - `Denied` — no matching permission.
      # - `All` — wildcard or empty scope; full access.
      # - `Scoped(permissions)` — matching permissions with scope constraints.
      #
      # This method is pure: it never hits the database. Context set
      # resolution is the enforcer's responsibility.
      def can?(action : String, domain : String, doctype_path : Array(String)) : CanResult
        if @principal.is_a?(Principal::System)
          CanResult::All.new
        elsif @principal.is_a?(Principal::Preview)
          # A preview principal does not consult the role/permission system.
          # Authorization is purely domain-scoped and lives in the enforcers'
          # `preview_authorizes?` branch; reaching here indicates a caller
          # bypassed the enforcer and is attempting a raw permission lookup,
          # which the preview capability model does not support.
          raise ArgumentError.new(
            "AuthContext#can? is not applicable to a preview principal — " \
            "use the enforcers, which branch on AuthContext#preview?"
          )
        else
          p = @principal.as(Principal::Real)
          matching = p.active_role.matching_permissions(action, domain, doctype_path)
          if matching.empty?
            CanResult::Denied.new
          elsif matching.any?(&.unrestricted?)
            CanResult::All.new
          else
            CanResult::Scoped.new(matching)
          end
        end
      end

      # Convenience overload: `can?("read", "crm.Project")` is equivalent to
      # `can?("read", "crm", ["Project"])`.
      #
      # Raises `ArgumentError` if the path does not contain at least a domain
      # and one doctype segment (e.g. bare `"crm"` is rejected).
      def can?(action : String, on_path : String) : CanResult
        parts = on_path.split('.')
        if parts.size < 2
          raise ArgumentError.new(
            "Permission path '#{on_path}' must include at least domain and doctype " \
            "(e.g. 'crm.Project')"
          )
        end
        domain = parts[0]
        path = parts[1..]
        can?(action, domain, path)
      end
    end
  end
end
