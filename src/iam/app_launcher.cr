# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../database"
require "./helpers"
require "../rbac/active_role"
require "../rbac/app_scope"
require "../rbac/grant_resolver"

module Facet
  module IAM
    # The dashboard launcher: lists the `app.App` registrations an account
    # sees on the dashboard, and flags each one as usable or not.
    #
    # The launcher applies two filters:
    #
    # 1. The app is **enabled** — `status == "active"`. A `draft` app is not
    #    yet launchable. A `disabled` app blocks sign-in and API access.
    #    Only `active` apps are listed.
    # 2. The app is **visible by design** — `no_launcher` is false. A
    #    headless registration (the CLI tool) is reached through its client,
    #    not through the dashboard.
    #
    # Client type does not filter. A `confidential` app has a backend
    # component — it can additionally authenticate as itself through an
    # app-owned API key — but it signs in through the consent screen like a
    # `public` app, so it gets a card too.
    #
    # Each listed app carries `usable` — the result of
    # `GrantResolver.role_usable?` for the active role. A role that does not
    # cover every `required` grant action gets `usable: false`. The dashboard
    # shows that card in a disabled state with a notice, so the account can
    # ask for access. This mirrors the OAuth authorize gate
    # (`OAuth::Authorize.load_app` + `GrantResolver.role_usable?`). The
    # `compatible_roles` field on `app.App` is metadata only and is **not**
    # consulted here — see `doc/backend/app-system.md` → Fields.
    #
    # The launcher returns only the public, non-secret fields a dashboard
    # card needs (`id`, `slug`, `display_name`, `description`, `usable`).
    # `client_id`, `redirect_uris`, `allowed_origins`, and `grants` are
    # intentionally absent from the response.
    module AppLauncher
      # A launcher app summary — the public projection of an `app.App` row,
      # with `usable` reporting whether the active role can open the app.
      record AppSummary,
        id : String,
        slug : String,
        display_name : String,
        description : String?,
        usable : Bool

      # Returns every active frontend app, in projection `id` order
      # (ULID-sortable, so roughly creation order). `usable` on each entry
      # reports whether the given role can open the app.
      #
      # Returns an empty array when the role has no projection row (the role
      # was deleted between session creation and this call) — without a role
      # no app is usable, so the launcher lists nothing.
      def self.launcher_apps(db : DB::Connection, role_name : String) : Array(AppSummary)
        role_content = IAM::Helpers.find_role_content(db, role_name)
        return [] of AppSummary unless role_content

        active_role = RBAC::ActiveRole.from_projection_content(role_content)

        rows = db.query_all(<<-SQL, as: {String, JSON::Any})
          SELECT id, content
          FROM projections
          WHERE domain = 'app' AND doc_type = 'App'
            AND content->>'status' = 'active'
            AND deleted_at IS NULL
          ORDER BY id
        SQL

        rows.compact_map do |row|
          id, content = row

          # Headless registrations (`no_launcher`) are hidden — a CLI tool
          # registration is reached through its client, not through the
          # dashboard. Client type does not filter: a `confidential` app
          # signs in through the consent screen like a `public` app.
          next if content.as_h["no_launcher"]?.try(&.as_bool?) == true

          app_scope = RBAC::AppScope.from_content(id, content)
          usable = RBAC::GrantResolver.role_usable?(app_scope, active_role)

          h = content.as_h
          AppSummary.new(
            id: id,
            slug: h["slug"]?.try(&.as_s?) || "",
            display_name: h["name"]?.try(&.as_s?) || "",
            description: h["description"]?.try(&.as_s?),
            usable: usable,
          )
        end
      end
    end
  end
end
