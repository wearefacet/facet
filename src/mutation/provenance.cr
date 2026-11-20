# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../rbac/auth_context"

module Facet
  module Mutation
    # Audit metadata for mutations: **provenance** (who/what surface wrote it)
    # and **cause** (what directly triggered it).
    #
    # Both are stored on typed columns of the `mutations` table (promoted
    # from the former JSONB `meta` column):
    #
    # - `channel` (+ `app` / `api_key` / `acting_role`) — how the request
    #   authenticated. Exactly one channel per mutation:
    #   `session | oauth_app | app_api_key | api_key | mcp | internal`.
    # - `cause_*` — the direct trigger, one hop per row. The full chain is a
    #   walk on `cause_parent`; all mutations of one causal cluster share
    #   `cause_trace` (the root mutation's ULID):
    #
    #   `kind=action, name="hire", event="hired",
    #    source="crm.Employee:01J…", parent=NULL, trace="01J…"`
    #
    # A Lua `document.*` write driven by that action stamps the same
    # kind/name/event plus `cause_parent` = the action's (pre-generated)
    # mutation id, so audit consumers can reconstruct the full trigger
    # chain without parsing any string convention.
    enum Channel
      Session
      OauthApp
      AppApiKey
      ApiKey
      Mcp
      Internal

      # Snake_case label stored in `mutations.channel`.
      def json_value : String
        case self
        in Session   then "session"
        in OauthApp  then "oauth_app"
        in AppApiKey then "app_api_key"
        in ApiKey    then "api_key"
        in Mcp       then "mcp"
        in Internal  then "internal"
        end
      end
    end

    # Who/what surface wrote a mutation. Built once per service call via
    # `Provenance.from(auth_context)` and threaded through to
    # `Mutation::Client` as a single argument — replacing the former loose
    # `app` / `acting_role` / `api_key` keyword params.
    struct Provenance
      getter channel : Channel
      # The `app.App` projection id (`OauthApp` / `AppApiKey` channels).
      getter app : String?
      # The `api_keys.id` row ULID (`ApiKey` / `AppApiKey` channels). Never
      # the secret.
      getter api_key : String?
      # The qualified id of the role that authorized the write
      # (`iam.Roles.admin`) — the request's elected role, stamped on every
      # authenticated channel (`session`, `oauth_app`, `app_api_key`,
      # `api_key`, `mcp`). `nil` for `internal` and preview writes, and for
      # synthetic marker roles that no role document backs.
      getter acting_role : String?

      def initialize(@channel : Channel, @app : String? = nil, @api_key : String? = nil, @acting_role : String? = nil)
      end

      # System-tier default: seeds, migrations, hooks, replication.
      def self.internal : Provenance
        new(Channel::Internal)
      end

      # Derives the provenance from the request's auth context. The channel
      # mirrors the context's construction factory:
      #
      # - `Principal::System`               → `internal`
      # - `app_id` + `api_key_id`           → `app_api_key` (app-owned key)
      # - `app_id`                          → `oauth_app` (app token)
      # - context `acting_role`             → `mcp`
      # - `api_key_id`                      → `api_key`
      # - otherwise                         → `session` (browser cookie)
      #
      # Every authenticated channel stamps `acting_role` with the request's
      # elected role (qualified projection id) — the role that authorized
      # the write, one shape on every surface. On MCP the role is pinned at
      # authorize time (the URL slug); on the other surfaces it is the
      # principal's active role. A preview principal carries no provenance
      # tag — it maps to `session` and stamps no role (the preview
      # capability consults no role).
      def self.from(auth_context : RBAC::AuthContext) : Provenance
        return new(Channel::Internal) if auth_context.system?

        app = auth_context.app_id
        api_key = auth_context.api_key_id
        elected = elected_role(auth_context)

        if app
          # The context's `acting_role` stays MCP-only, so on an app
          # surface the elected role always comes from the principal.
          return new(
            api_key ? Channel::AppApiKey : Channel::OauthApp,
            app: app, api_key: api_key, acting_role: elected,
          )
        end
        # The context field doubles as the MCP channel signal — only
        # `AuthContext.mcp` sets it.
        return new(Channel::Mcp, acting_role: auth_context.acting_role) if auth_context.acting_role
        return new(Channel::ApiKey, api_key: api_key, acting_role: elected) if api_key

        new(Channel::Session, acting_role: elected)
      end

      # The request's elected role as a qualified projection id
      # (`iam.Roles.admin`). Synthetic marker roles (the `denied`
      # fail-closed fallback, the domain-editor grant) have no role
      # document behind them and stamp `nil`.
      private def self.elected_role(auth_context : RBAC::AuthContext) : String?
        principal = auth_context.principal
        return nil unless principal.is_a?(RBAC::Principal::Real)
        principal.active_role.stored_role_id
      end
    end

    enum CauseKind
      Request          # top-level API call (REST, MCP tool write)
      Action           # Lua named action
      HookEvent        # domain event hook fire
      HookSchedule     # schedule hook fire
      Replication      # replica-field propagation
      Cascade          # owned-child tombstone
      Rollback         # audit rollback snapshot
      Migration        # schema-version migration snapshot
      PeriodicSnapshot # periodic_snapshot trigger snapshot
      WebhookTest      # webhook test fire
      Assistant        # assistant tool write (LLM-driven)
      Compaction       # retention-compaction boundary snapshot
      Seed             # boot-time seed reconcile of a system doctype

      def json_value : String
        case self
        in Request          then "request"
        in Action           then "action"
        in HookEvent        then "hook_event"
        in HookSchedule     then "hook_schedule"
        in Replication      then "replication"
        in Cascade          then "cascade"
        in Rollback         then "rollback"
        in Migration        then "migration"
        in PeriodicSnapshot then "periodic_snapshot"
        in WebhookTest      then "webhook_test"
        in Assistant        then "assistant"
        in Compaction       then "compaction"
        in Seed             then "seed"
        end
      end

      # Parses a stored `cause_kind` (the `json_value` form — the member
      # name snake_cased) back to the member. Returns nil on an unknown
      # value, so callers reading the typed `mutations` columns can
      # degrade fail-closed instead of raising. The `mutations.cause_kind`
      # CHECK constraint keeps every stored value inside the map.
      def self.from_json_value(value : String) : self?
        parse(value.split('_').map(&.capitalize).join)
      rescue ArgumentError
        nil
      end
    end

    # The direct trigger of a mutation — one hop. The full chain is a walk
    # on `parent`; `trace` groups the whole causal cluster.
    struct Cause
      getter kind : CauseKind
      # Action name, hook id, or replication binding descriptor.
      getter name : String?
      # Resolved event name ("hired", "updated", "delete-unset", …).
      getter event : String?
      # The document the cause ran on, as `domain.Doctype:id`.
      getter source : String?
      # Mutation ULID of the direct trigger. Nil for root mutations.
      getter parent : String?
      # Mutation ULID of the root of the causal cluster. Nil means "this
      # mutation's own id" — `Mutation::Client` resolves it at insert time.
      getter trace : String?

      def initialize(@kind : CauseKind, @name : String? = nil, @event : String? = nil, @source : String? = nil, @parent : String? = nil, @trace : String? = nil)
      end

      # Root-cause builder: the mutation is its own trace.
      def self.root(kind : CauseKind, name : String? = nil, event : String? = nil, source : String? = nil) : Cause
        new(kind: kind, name: name, event: event, source: source)
      end

      # Returns a copy with `trace` resolved to a concrete id. Used by
      # `Mutation::Client` when the own-id default applies.
      def resolve(id : String) : Cause
        return self if trace
        Cause.new(kind: kind, name: name, event: event, source: source, parent: parent, trace: id)
      end

      # Builds the cause template for mutations written by Lua
      # `document.*` helpers under this cause: same kind/name/event/source,
      # `parent` bound to the driving mutation id, trace inherited (or the
      # driving id when this cause is itself the root).
      def child_of(driving_mutation_id : String) : Cause
        Cause.new(
          kind: kind, name: name, event: event, source: source,
          parent: driving_mutation_id, trace: trace || driving_mutation_id,
        )
      end

      # Serializes the `cause` object for event headers. `trace` must be
      # resolved (non-nil) — call `resolve` first.
      def to_json_any : JSON::Any
        raise ArgumentError.new("Cause#to_json_any: trace must be resolved (call resolve first)") unless trace

        JSON.parse(JSON.build do |json|
          json.object do
            json.field "kind", kind.json_value
            json.field "name", name if name
            json.field "event", event if event
            json.field "source", source if source
            json.field "parent", parent if parent
            json.field "trace", trace
          end
        end)
      end
    end
  end
end
