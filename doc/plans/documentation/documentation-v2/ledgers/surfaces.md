# Surface ledger (WP 10)

Every user-visible surface, mapped to a feature ID and to the page that
explains it today (old path), and to the v2 page that explains it now.
The **New page** column is filled from `site-docs/scripts/page-map.mjs`
(WP 21 fix round, 2026-11-27); every target path exists under
`site-docs/src/content/docs`. WP 21 checks that no row is empty.

**How this was built.** The scriptable kinds (routes, CLI commands, cron
tasks, field types, agent tools, settings keys, metric names, frontend routes,
UI label groups) were extracted by
[`scripts/extract_surfaces.mjs`](scripts/extract_surfaces.mjs) at commit
`8fb69df`; the raw output is [`surfaces-raw.md`](surfaces-raw.md) (2524 rows).
This file maps the extracted surfaces to inventory IDs. Granularity: HTTP
routes, CLI commands, cron tasks, field types and frontend routes are mapped
per family (one row per route family / command / task); the UI-label kind is
mapped per label group, not per label — the group owner WP splits it when it
writes the pages. Lua bindings and Jinja2 context live on generated/hand
written reference pages; the ledger points at them instead of duplicating the
lists.

Rule from `04-coverage-and-verification.md` §2: a surface with no feature ID
means the inventory is missing a feature. All rows below carry an ID after the
WP 10 refresh (inventory grew 138 → 158 IDs).

---

## 1. Workspace and Builder routes

Source of truth: `frontend/src/routes/**/+page.svelte` (extracted in
`surfaces-raw.md` §11, 56 routes). Grouped rows below; per-route detail in the
raw file.

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `/` (dashboard) | FE-02 | workspace/dashboard.md | use/first-day/dashboard.md |
| `/Login`, `/ResetPassword` | FE-01 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `/[domain]/[doctype]` (list) | FE-03 | workspace/lists-filters-views.md | use/finding/lists-and-views.md |
| `/[domain]/[doctype]/new`, `…/[id]/edit` | FE-05 | workspace/viewing-editing-document.md | use/documents/view-and-edit.md |
| `/[domain]/[doctype]/[id]` (show) | FE-04 | workspace/viewing-editing-document.md | use/documents/view-and-edit.md |
| `/[domain]/[doctype]/[id]/history` | FE-06 | workspace/history-undo.md | use/documents/history-undo.md |
| `/Builder/**` (draft authoring, check, preview) | FE-10 | build/domains-drafts-editors.md | build/model/in-app/drafts-and-publishing.md |
| `/Configure/access/**` (roles, assignments, accounts) | FE-11 | govern/roles-permission-lines.md, govern/assigning-roles-election.md, govern/accounts-lifecycle.md | admin/people/roles-and-permissions.md, admin/people/assign-roles.md, admin/people/accounts.md |
| `/Configure/apps/**` (wizard, overview, deploy, grants, settings) | FE-12 | apps/registering-app.md, apps/hosting-deploy.md | build/apps/connect/register.md, build/apps/host/deploy.md |
| `/Configure/domains/**` (live domains) | FE-13 | build/index.md | build/index.md |
| `/Configure/platform/**` (settings, artifacts, indexes, OIDC, maintenance) | FE-14 | operate/system-settings.md, operate/indexes.md (maintenance: DOM-26, no old page) | admin/configure/system-settings.md, admin/keep-running/indexes.md (maintenance: build/deeper/schema-evolution.md) |
| `/Configure/currencies` | FE-15 | operate/currencies.md | admin/configure/currencies.md |
| `/Configure/audit` | FE-16 | govern/auditing-activity.md | admin/history/audit.md |
| `/Settings`, `/Settings/api-keys`, `/Settings/webhooks` | FE-17 | workspace/settings-sessions-api-keys.md, build/webhooks.md | use/account.md, build/model/automation/webhooks.md |
| `/OAuthConsent` | FE-21, APP-05 | apps/oauth-login.md | build/apps/connect/user-login.md |

## 2. Visible UI actions

Source of truth: `frontend/messages/en.json` (extracted per group in
`surfaces-raw.md` §12). Group-level mapping; the owning WP splits to labels.

| Group (examples) | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `auth_*`, `login_*` (sign in, MFA, reset) | FE-01 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `dashboard_*`, `domain_*`, `doctype_*` (cards, new-domain/new-doctype dialogs) | FE-02 | workspace/dashboard.md | use/first-day/dashboard.md |
| `list_view_*`, `filter_*`, `kanban_*`, `calendar_*`, `list_view_starter_*` | FE-03, DOM-21, DOM-29, DOM-32 | workspace/lists-filters-views.md, build/collection-views.md | use/finding/lists-and-views.md, build/model/views/lists-boards-calendars.md |
| `grid_*` (cell editors, paste, undo) | FE-23 (dormant) | — (not user-reachable; excluded from docs) | — |
| `doc_*`, `doc_peek_*`, `form_*` (show/form, peek drawer) | FE-04, FE-05, FE-24 | workspace/viewing-editing-document.md | use/documents/view-and-edit.md |
| `history_*`, `audit_restore_*` | FE-06, AUD-04 | workspace/history-undo.md, govern/rolling-back.md | use/documents/history-undo.md, admin/history/roll-back.md |
| `palette_*`, `search_*` | FE-07, DOC-06 | workspace/search-command-palette.md | use/finding/search.md |
| `shortcuts_*` | FE-08 | workspace/keyboard-shortcuts.md | use/finding/keyboard-shortcuts.md |
| `nav_*` (bell, notifications) | FE-09, AUT-06 | workspace/notifications.md | use/notifications.md |
| `builder_*` (draft editor, check, publish) | FE-10, DOM-02, DOM-16 | build/domains-drafts-editors.md, build/checking-before-publish.md | build/model/in-app/drafts-and-publishing.md, build/model/in-app/check-before-publish.md |
| `rbac_*`, `access_*` (roles, assignments, accounts) | FE-11, RBC-01..07 | govern/roles-permission-lines.md and the People pages | admin/people/roles-and-permissions.md and the People pages |
| `app_*` (wizard, deploy, credentials) | FE-12, APP-01..09 | apps/registering-app.md and the Apps pages | build/apps/connect/register.md and the Apps pages |
| `settings_*`, `sessions_*` (profile, API keys, sessions) | FE-17, IAM-09, IAM-11 | workspace/settings-sessions-api-keys.md | use/account.md |
| `impex_*` (import/export dialogs) | FE-18, DOC-11 | workspace/import-export.md | use/documents/import-export.md |
| `welcome_*` (tour) | FE-19 | workspace/dashboard.md | use/first-day/dashboard.md |
| `chat_*`, `assistant_*` | FE-22, AI-01 | workspace/assistant.md | use/assistant.md |
| `webhook_*` | AUT-03 | build/webhooks.md | build/model/automation/webhooks.md |
| `trash`/deleted toggle + restore | FE-25, AUD-04 | workspace/lists-filters-views.md (restore: govern/rolling-back.md) | use/finding/lists-and-views.md (restore: admin/history/roll-back.md) |

## 3. HTTP route groups

Source of truth: route registration in `src/` and `doc/api/openapi.json`
(extracted in `surfaces-raw.md` §1; note routes are PascalCase `/Api/…`).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `POST /Api/iam/login`, `/challenge` | IAM-01, IAM-10 | workspace/sign-in-mfa.md, govern/sessions-tokens-lockouts.md | use/first-day/sign-in.md, admin/people/sessions-lockouts.md |
| `POST /Api/iam/refresh`, `/logout` | IAM-02 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `/Api/iam/mfa/*` | IAM-03 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `POST /Api/iam/change-password` | IAM-04 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `/Api/iam/password-reset/*` | IAM-05 | workspace/sign-in-mfa.md | use/first-day/sign-in.md |
| `/Api/iam/accounts/:id/invite`, `…/temporary-password`, `…/credential-states` | IAM-06, IAM-07 | govern/accounts-lifecycle.md | admin/people/accounts.md |
| `/auth/oidc/:provider(+/callback)`, `GET /Api/iam/oidc/providers` | IAM-08 | govern/sso-oidc.md | admin/people/sso.md |
| `/Api/iam/keys*` | IAM-09 | govern/api-keys.md | admin/apps-access/api-keys.md |
| `/Api/iam/sessions*`, `/Api/iam/apps/:app_id/sessions` | IAM-11 | govern/sessions-tokens-lockouts.md | admin/people/sessions-lockouts.md |
| `GET /Api/iam/me` | IAM-14, RBC-11 | apps/permission-manifest.md | build/apps/connect/permission-manifest.md |
| `GET /Api/iam/apps` | APP-12 | workspace/dashboard.md | use/first-day/dashboard.md |
| `/Api/assistant/conversations*`, `…/cancel/:turn_token` | AI-01 | workspace/assistant.md | use/assistant.md |
| `GET /Api/assistant/usage` | AI-07 | govern/governing-assistant.md | admin/assistant/govern.md |
| domain-builder conversation route | AI-02 | build/domain-builder-assistant.md | build/model/in-app/build-with-assistant.md |
| `POST /Api/assistant/app/conversations` | AI-03 | apps/chat-embed.md | build/apps/host/embed-assistant.md |
| `/Api/_mcp/*` (POST `:role_slug`, GET `endpoints`) | AI-05 | apps/mcp-agents.md | build/apps/agents/mcp.md |
| `/OAuth/authorize|token|refresh|register|client-info`, `/.well-known/oauth-authorization-server` | APP-02, APP-04 | apps/oauth-login.md, apps/mcp-agents.md | build/apps/connect/user-login.md, build/apps/agents/mcp.md |
| `/OAuthConsent` route (UI) + consent hand-off | APP-05 | apps/oauth-login.md | build/apps/connect/user-login.md |
| `POST /Api/app/:id/deploy`, `GET /Edge/HostAsk` | APP-06 | apps/hosting-deploy.md | build/apps/host/deploy.md |
| `/Api/app/:id/api-key*` | APP-07 | apps/service-accounts.md | build/apps/connect/backend-apps.md |
| app registry documents (`/Api/app/App` CRUD + grants) | APP-01, RBC-08 | apps/registering-app.md, govern/app-grants.md | build/apps/connect/register.md, admin/apps-access/app-grants.md |
| `/Api/core/Domain` CRUD, `/draft`, `/:id/draft`, `/:id/drop` | DOM-01, DOM-31 | build/domains-drafts-editors.md | build/model/in-app/drafts-and-publishing.md |
| `/Api/core/Domain/:id/publish`, `/:id/preview-session` | DOM-02 | build/domains-drafts-editors.md | build/model/in-app/drafts-and-publishing.md |
| `/Api/core/Domain/:id/check` | DOM-16 | build/checking-before-publish.md | build/model/in-app/check-before-publish.md |
| `/Api/core/Domain/:id/export`, `/Api/core/Domain/import*` | DOM-15 | build/bundles.md | build/model/bundles.md |
| `/Api/core/DomainGrant*` (activate/deactivate) | DOM-14 | build/sharing-across-domains.md | build/model/relations/across-domains.md |
| `/Api/core/DocType` CRUD | DOM-03 | build/designing-doctypes.md | build/model/data/design-doctypes.md |
| `GET /Api/core/DocType/:id/check` | DOM-16 | build/checking-before-publish.md | build/model/in-app/check-before-publish.md |
| `/Api/core/DocType/:id/reproject`, `/migrate_ahead`, `/maintenance_status`, `/maintenance_jobs` | DOM-26, DOM-27, DOM-18 | build/evolving-schema.md | build/model/change-a-live-domain.md |
| `/Api/core/Webhook*` (test, calls, replay) | AUT-03 | build/webhooks.md | build/model/automation/webhooks.md |
| `/Api/core/artifacts*`, `/A/:gid`, `/A/upload/:uid`, `/Api/Artifacts*` | PLT-04 | build/files-artifacts.md, apps/files.md | build/model/data/files.md, build/apps/data/files.md |
| `/Api/:domain/:doctype` CRUD + `restore` | DOC-01 | apps/rest-api.md, workspace/viewing-editing-document.md | build/apps/data/rest-api.md, use/documents/view-and-edit.md |
| `/Api/:domain/:doctype` list grammar (filters, scope, aggregate) | DOC-02, DOC-03, DOM-12 | apps/rest-api.md, workspace/lists-filters-views.md | build/apps/data/rest-api.md, use/finding/lists-and-views.md |
| `GET /Api/:domain/:doctype/:id/backrefs` | DOC-05 | build/references-links-backlinks.md | build/model/relations/references-links.md |
| `/Api/:domain/:doctype/:id/history`, `/rollback`, child `history`/`rollback` | AUD-02, AUD-04, AUD-09 | govern/auditing-activity.md, govern/rolling-back.md | admin/history/audit.md, admin/history/roll-back.md |
| `/Api/:domain/:doctype/import*`, `/export*` | DOC-11 | workspace/import-export.md, apps/bulk-import-export.md | use/documents/import-export.md, build/apps/data/bulk-import-export.md |
| `/Api/:domain/:doctype/:id/:rel` (child lists) | DOC-14, DOM-05 | build/parent-child-composition.md | build/model/relations/parent-child.md |
| `…/:id/:action` (named actions), `…/:id/:sidecar` (sidecars) | DOM-07, DOM-06 | build/named-actions.md, build/sidecars.md | build/model/behaviour/named-actions.md, build/model/relations/comments-attachments.md |
| `/Api/:domain/:doctype/:id/:child/:child_id/*` history | AUD-02 | govern/auditing-activity.md | admin/history/audit.md |
| `GET|QUERY /Api/search`, `/Api/:domain/search` | DOC-06 | workspace/search-command-palette.md, apps/search.md | use/finding/search.md, build/apps/data/search.md |
| `/Api/Audit*` | AUD-02, AUD-03 | govern/auditing-activity.md | admin/history/audit.md |
| `/Api/Audit/:mutation_id/rollback` (incl. cluster scope) | AUD-04, AUD-09 | govern/rolling-back.md | admin/history/roll-back.md |
| `/Api/notifications*` | AUT-06 | workspace/notifications.md | use/notifications.md |
| `/Api/SystemSettings`, `…/assistant/test`, `…/mail/test` | PLT-02, AI-08 | operate/system-settings.md, operate/assistant-config.md | admin/configure/system-settings.md, admin/assistant/connect-a-model.md |
| `/Api/secrets/stage` | PLT-03, DOC-09 | build/secret-write-only-fields.md | build/model/data/secret-fields.md |
| `/Api/settings*` | PLT-17 | workspace/settings-sessions-api-keys.md | use/account.md |
| `/Api/Indexes` | PLT-05 | operate/indexes.md | admin/keep-running/indexes.md |
| `/Api/dev/check-report` | DOM-19, DOM-16 | build/dev-domain-watcher.md | build/model/in-files/domain-watcher.md |
| `/Ws` | DOC-12, DOC-15 | apps/websockets.md | build/apps/data/realtime.md |
| `/Healthcheck`, `/Healthcheck/live` | PLT-06 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `/metrics` | PLT-07 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `POST /Api/iam/keys` etc. (see §1 of raw list) | IAM-09 | govern/api-keys.md | admin/apps-access/api-keys.md |

## 4. `facet` CLI commands

Source of truth: `src/cli/commands.cr` (21 commands, extracted in
`surfaces-raw.md` §2).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `facet server` | PLT-01 | operate/containers-tls.md | admin/install/containers.md |
| `facet migrate`, `migrate:down`, `db_reset` | PLT-11 | operate/migrations.md | admin/keep-running/migrations.md |
| `facet seed:core`, `seed:dev` | DOM-24, IAM-12 | operate/bootstrap-cli.md | admin/install/bootstrap.md |
| `facet seed:admin` | IAM-12 | operate/bootstrap-cli.md | admin/install/bootstrap.md |
| `facet accounts:list`, `accounts:create`, `roles:list`, `roles:add`, `auth:mode` | IAM-12 | operate/bootstrap-cli.md | admin/install/bootstrap.md |
| `facet index:retry` | PLT-05 | operate/indexes.md | admin/keep-running/indexes.md |
| `facet artifacts:prune|reconcile|revoke` | PLT-04 | operate/file-storage.md | admin/configure/file-storage.md |
| `facet domain:export`, `domain:import` | DOM-15 | build/bundles.md | build/model/bundles.md |
| `facet doctype:reproject` | DOM-18 | build/display-names-search-text.md | build/model/views/names-and-search.md |
| `facet doctype:migrate-retry` | DOM-28 | build/evolving-schema.md | build/model/change-a-live-domain.md |
| `facet cron:list` | AUT-10 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |

## 5. `@facetapp/cli` commands

Source of truth: `packages/cli/src/commands/` (extracted in
`surfaces-raw.md` §3).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `login`, `whoami`, `logout` | APP-09, APP-02 | apps/quickstart-dev-cli.md | build/apps/quickstart.md |
| `init` (scaffold) | APP-09 | apps/quickstart-dev-cli.md | build/apps/quickstart.md |
| `deploy`, `releases`, `rollback` | APP-09, APP-06 | apps/hosting-deploy.md | build/apps/host/deploy.md |

## 6. Config file keys

Source of truth: `src/config.cr`; full list generated at
`reference/config-keys.md`. Each section maps to one how-to page:

| Section | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `database.*` (incl. cluster grammar) | PLT-10 | operate/system-requirements.md | admin/install/requirements.md |
| `event.*` | AUT-01 | concepts/events-delivery.md | admin/under-the-hood/events-and-delivery.md |
| `cron.*`, per-task entries | AUT-05 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |
| `jobs.*` | AUT-04 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |
| `mutations.*` (retention, coalesce, overrides) | AUD-05, AUD-06 | govern/retention.md | admin/history/retention.md |
| `tombstone.*` | AUD-07 | govern/retention.md | admin/history/retention.md |
| `webhook.*` | AUT-03 | build/webhooks.md | build/model/automation/webhooks.md |
| `dev.domain_watch.*` | DOM-19 | build/dev-domain-watcher.md | build/model/in-files/domain-watcher.md |
| `assistant.*` | AI-08 | operate/assistant-config.md | admin/assistant/connect-a-model.md |
| `mail.*` | AUT-07 | operate/email.md | admin/configure/email.md |
| `artifacts.*`, `storage.*` | PLT-04 | operate/file-storage.md | admin/configure/file-storage.md |
| `logs.*` | PLT-09 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `telemetry.*` | PLT-08 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `secrets.*` | PLT-03 | operate/configuration-files.md | admin/configure/configuration-files.md |
| `iam.*` (session/token TTLs, auth mode) | IAM-01..11 | govern/sessions-tokens-lockouts.md | admin/people/sessions-lockouts.md |
| `localization.*` | PLT-02, FE-20 | operate/localization.md | admin/configure/languages.md |
| `http.*` (gates, limits) | PLT-13 | concepts/authorization-enforcement.md | admin/under-the-hood/how-access-is-enforced.md |

## 7. System settings keys

Source of truth: `src/system_settings/spec.cr` (31 keys, extracted in
`surfaces-raw.md` §7); full list generated at
`reference/system-settings-keys.md`. Sections: `mail.*`, `assistant.*`
(incl. `assistant.api_key` sealed slot), `iam.*` (auth mode, MFA, change
password), `localization.*`, `mutations.retention_days`,
`tombstone.content_retention_days`, `artifact.*`.

| Group | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `iam.auth.*`, `iam.mfa.*`, `iam.change_password_expiration`, `iam.oidc.provision_roles` | IAM-03, IAM-04, IAM-08, RBC-01 | govern/enforcing-mfa.md, govern/sso-oidc.md | admin/people/mfa.md, admin/people/sso.md |
| `mail.*` | AUT-07 | operate/email.md | admin/configure/email.md |
| `assistant.*` | AI-08 | operate/assistant-config.md | admin/assistant/connect-a-model.md |
| `localization.*` | PLT-02, FE-20 | operate/localization.md | admin/configure/languages.md |
| `mutations.retention_days`, `tombstone.content_retention_days` | AUD-06, AUD-07 | govern/retention.md | admin/history/retention.md |
| `artifact.*` | PLT-04 | operate/file-storage.md | admin/configure/file-storage.md |

## 8. Account settings keys

Source of truth: `src/settings/keys.cr` (extracted in `surfaces-raw.md` §8);
full list generated at `reference/account-settings-keys.md`.

| Group | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `core.language`, `core.timezone` (default `auto`), `core.show_welcome` | PLT-17, FE-19, FE-20 | workspace/settings-sessions-api-keys.md | use/account.md |
| `notifications.in_app` | AUT-06 | workspace/notifications.md | use/notifications.md |
| `core.pinned_collection_views` | DOM-30 | workspace/lists-filters-views.md | use/finding/lists-and-views.md |

## 9. Lua API functions

Full list generated at `reference/lua-api.md` from `src/lua/`. Families:
`document.*`, `notification.*`, `util.*` (json, ulid, webhook URL safety,
`facet_hosts`, `valid_redirect_uri`), `date.*`, `math.*`.

| Family | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `document.*` (get, list, …) | DOM-08, DOC-01 | build/lifecycle-scripts-guards.md | build/model/behaviour/scripts-and-guards.md |
| `notification.send` | AUT-06, DOM-08 | build/notifications-mentions.md | build/model/automation/notifications.md |
| `util.*` | AUT-08 | build/lifecycle-scripts-guards.md | build/model/behaviour/scripts-and-guards.md |
| `date.*`, `math.*` | AUT-08 | build/lifecycle-scripts-guards.md | build/model/behaviour/scripts-and-guards.md |

## 10. Jinja2 context variables

Full list on the hand-written page `reference/jinja2-context.md`
(`display_name`/`search` rendering, 255/256-char truncation).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| Doctype `display_name` / `search` templates | DOM-23 | build/display-names-search-text.md | build/model/views/names-and-search.md |
| CollectionView `title_template` (browser-side) | DOM-21 | build/collection-views.md | build/model/views/lists-boards-calendars.md |

## 11. Agent tools

Source of truth: `src/agent_tools/` (23 tools, extracted in
`surfaces-raw.md` §6); full table generated at `reference/agent-tools.md`.

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| Read tools (`whoami`, `list_domains`, `list_doctypes`, `get_schema`, `list_documents`, `get_document`, `resolve_refs`, `search_documents`, `aggregate_documents`, `list_mutations`, `get_links`, `get_backrefs`, `ping`) | AI-04 | apps/agent-tools.md | build/apps/agents/agent-tools.md |
| Write tools (`create_document`, `update_document`, `delete_document`, `call_action`, `batch`, `create_sidecar`, `list_sidecars`) | AI-04, DOC-01 | apps/agent-tools.md | build/apps/agents/agent-tools.md |
| File tools (`request_artifact_upload`, `get_artifact`, `list_artifact_refs`) | AI-04, PLT-04 | apps/agent-tools.md | build/apps/agents/agent-tools.md |
| `read_skill` + skill corpus | AI-06 | apps/agent-tools.md | build/apps/agents/agent-tools.md |

## 12. Field types

Source of truth: `src/doctype/field_types/` (22 types, extracted in
`surfaces-raw.md` §5); full table generated at `reference/field-types.md`.

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| 22 field types (any, array, boolean, color, data, date, dateperiod, datetime, dictionary, duration, enum, file, integer, long_text, money, object, period, phone, reference, secret, string, url) | DOM-04 | build/field-types.md | build/model/data/field-types.md |
| `secret` type + stage flow | DOC-09, PLT-03 | build/secret-write-only-fields.md | build/model/data/secret-fields.md |
| `file` type + artifacts | PLT-04 | build/files-artifacts.md | build/model/data/files.md |
| `reference` type + validation | DOC-10 | build/references-links-backlinks.md | build/model/relations/references-links.md |

## 13. Cron tasks

Source of truth: `src/cron/` (extracted in `surfaces-raw.md` §4; the boot
task table with schedules is in `doc/backend/cron.md` and
`reference/config-keys.md`).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `mutation_compaction` | AUD-06 | govern/retention.md | admin/history/retention.md |
| `tombstone_content_prune` | AUD-07 | govern/retention.md | admin/history/retention.md |
| `secrets_prune` | PLT-03 | operate/file-storage.md | admin/configure/file-storage.md |
| `artifact_grant_prune` | PLT-04 | operate/file-storage.md | admin/configure/file-storage.md |
| `webhook_reconcile` | AUT-03 | build/webhooks.md | build/model/automation/webhooks.md |
| `sidecar_reconcile` | DOM-06 | build/sidecars.md | build/model/relations/comments-attachments.md |
| `assistant_turn_sweep` | AI-09 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |
| `assistant_usage_prune` | AI-07 | govern/governing-assistant.md | admin/assistant/govern.md |
| `event_lag_check` | AUT-01 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| scheduler, lease, parser, pass, tasks, list_cli | AUT-05 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |

## 14. Metrics and health names

Full list generated at `reference/health-metrics-names.md` (extracted in
`surfaces-raw.md` §10; 20+ `facet_*` counters/gauges plus `event_loss`,
`event_lag` fields on `/Healthcheck`).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| `/Healthcheck` payload (pools, Redis, consumers, `event_loss`, `event_lag`) | PLT-06, AUT-01 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `facet_http_requests_total` per route | PLT-07 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `facet_event_loss_*`, `facet_event_lag_max` | AUT-01 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |
| `facet_jobs_*` | AUT-04 | operate/jobs-cron.md | admin/keep-running/jobs-cron.md |
| `facet_cron_task_*`, `facet_consumer_*`, `facet_fiber_*`, `facet_db_*`, `facet_messages_processed_total` | PLT-06, PLT-07 | operate/health-metrics-logs.md | admin/keep-running/monitoring.md |

## 15. Error codes

Full list on the hand-written page `reference/error-responses.md`. Families
verified there against `src/` (representative: `inactive_currency`,
`named_scope`, `context_set`, `unsupported_filter_operator`,
`malformed_filter_value`, `wildcard_target`, `no_asset`, DPoP
`invalid_dpop_proof`/`invalid_claim`, WS close codes 4401/4403, uniform 401,
403-vs-404 denial classes).

| Surface | Feature ID | Page that explains it | New page |
|---|---|---|---|
| Filter/list error codes | DOC-02 | apps/rest-api.md | build/apps/data/rest-api.md |
| Denial classes (403 class denial vs 404 row denial) | RBC-03, RBC-06 | concepts/authorization-enforcement.md | admin/under-the-hood/how-access-is-enforced.md |
| DPoP/OAuth error codes | APP-02, APP-03 | apps/dpop.md | build/apps/connect/dpop.md |
| WebSocket close codes | DOC-12 | apps/websockets.md | build/apps/data/realtime.md |
| Money/scope/action error codes | PLT-14, DOM-12, DOM-07 | reference/error-responses.md | reference/error-responses.md |
