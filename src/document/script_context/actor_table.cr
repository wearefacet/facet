# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./base"

module Facet
  module Document
    module ScriptContext
      # The `ctx.actor` surface of `ScriptContext::Base`.
      #
      # The methods here read the auth context and the RBAC state that
      # `Base` captures. They build the read-only `ctx.actor` table that
      # `setup_ctx` attaches.
      abstract class Base
        # Builds the `ctx.actor` table from `@auth_context`.
        #
        # Returns nil when no auth context is set (migration contexts, unit
        # tests), so Lua scripts simply see `ctx.actor == nil` and can skip
        # enforcement. For a system principal, a minimal table with
        # `system = true` and `id` is returned. For a preview principal, the
        # table is minimal too: `system = false` and `id`, nothing else. No
        # preview marker goes into the table, so a script cannot branch on
        # preview mode. For a real principal, the full surface is populated:
        # `id`, `role_id`, `visible_tags`, `scope`, `scopes`, and
        # `context_sets` (the latter only when a DB connection and domain
        # are available, since context-set resolution is a DB read).
        private def build_actor_table : Hash(String, Lua::Engine::Value)?
          auth = @auth_context
          return nil if auth.nil?

          actor = Hash(String, Lua::Engine::Value).new
          actor["system"] = auth.system?
          actor["id"] = auth.account_id

          if auth.system?
            return actor
          end

          # A preview principal loads no role, and resource-scope resolution
          # is not applicable to draft data (see `RBAC::Principal::Preview`).
          if auth.preview?
            return actor
          end

          principal = auth.principal.as(RBAC::Principal::Real)
          role = principal.active_role
          actor["role_id"] = role.role_id
          actor["visible_tags"] = role.visible_tags.to_a.map(&.as(Lua::Engine::Value))

          # The `app.App` projection id when the caller is app-scoped (a
          # service account acting for an app, through an app-owned key or
          # an OAuth app token). Lets a script branch on "this caller is an
          # app, not a human" — e.g. the app.App update hook's self-grant
          # guard. Absent for session callers.
          if app_id = auth.app_id
            actor["app_id"] = app_id
          end

          # Collect the action's scope aliases (bare names, no `$`), using
          # this hook's own action name ("create", "update", "delete", or a
          # named action). The caller has already cleared the corresponding
          # WriteEnforcer check, so a match is guaranteed here for real
          # principals.
          if (action = @rbac_action) && (domain = @domain) && (doc_type = @doc_type)
            scopes = scope_aliases_for(auth, domain, doc_type, action)
            unless scopes.empty?
              actor["scopes"] = scopes.map(&.as(Lua::Engine::Value))
              actor["scope"] = scopes.first
            end
          end

          # Resolve context sets for the caller in this domain. These are the
          # materialized dynamic value sets (e.g. the teams the caller belongs
          # to) that a named scope's `where` may reference. Useful at create
          # time to constrain an incoming field against the caller's values.
          if (db = @db) && (domain = @domain)
            context_sets = resolve_context_sets_safe(db, domain, auth.account_id)
            actor["context_sets"] = context_sets unless context_sets.empty?
          end

          actor
        end

        # Returns the bare scope alias names from the matching permissions
        # for `action` on this doctype (e.g. `["mine", "global"]`). Each
        # permission may carry one or more aliases (combined with OR at
        # enforcement time); they are flattened here so a script sees the
        # union across all matching permissions' aliases. Empty for an
        # unrestricted (`$all` / absent scope) permission.
        #
        # The lookup path is the one the enforcer authorized with
        # (`@rbac_doctype_path` — the composition path on nested child
        # routes), not the bare doctype: a nested-route permission on the
        # full path (or the parent) never matches a bare-path lookup, which
        # would leave `ctx.actor.scope` nil for exactly the hooks that run
        # behind a scoped nested-route grant.
        private def scope_aliases_for(
          auth : RBAC::AuthContext,
          domain : String,
          doc_type : String,
          action : String,
        ) : Array(String)
          path = @rbac_doctype_path || [doc_type]
          case result = auth.can?(action, domain, path)
          when RBAC::CanResult::Scoped
            result.permissions.flat_map(&.scope_aliases)
          else
            [] of String
          end
        end

        # Wraps `ContextResolver.resolve_for_domain` so a resolution failure
        # (e.g. domain has no context sets, or a query error) does not abort
        # the create hook — the script simply sees an absent `context_sets`.
        private def resolve_context_sets_safe(
          db : DB::Connection,
          domain : String,
          account_id : String,
        ) : Hash(String, Lua::Engine::Value)
          scope_context = RBAC::ScopeContext.load(db, account_id)
          resolved = RBAC::ContextResolver.resolve_for_domain(db, domain, scope_context)
          lua_hash = Hash(String, Lua::Engine::Value).new
          resolved.each do |set_name, values|
            lua_hash[set_name] = values.map(&.as(Lua::Engine::Value))
          end
          lua_hash
        rescue
          # Fail soft: a context-set resolution error must not break the
          # create hook. The script can still enforce via scope/actor_id.
          {} of String => Lua::Engine::Value
        end
      end
    end
  end
end
