# 03 — Page map

Every English page of the current site, its new path, and what happens to it.
Paths are relative to `site-docs/src/content/docs/`. French pages under
`fr/` follow their English page (same relative path).

**Actions**

| Action | Meaning |
|---|---|
| `move` | `git mv` to the new path; update links and front-matter (`type`, `sidebar.order`). Light edit only: title, lead, Related. |
| `rewrite` | Move, then rewrite to the v2 voice and layer. Same topic, same facts. |
| `split` | One old page becomes two or more pages (usually L1 + L3). Each new path is listed. |
| `merge` | Two or more old pages become one. The page names its partners. |
| `new` | No old page. Listed in §7. |
| `retire` | The page goes away; its content is merged elsewhere (named) and its URL redirects. |

Owner = the WP that writes the page. WP 11 performs **all** moves (`git mv`)
first, so content WPs only edit files that already sit at their new path.
For `split` and `merge`, WP 11 moves the *first* listed target; the owner WP
creates the others.

Titles are proposals that follow `01-voice-and-vibe.md` §6. `ord` is
`sidebar.order` inside the group.

---

## 1. `start/` → Discover, Build, Reference

| Old | New | Proposed title | Type | Action | Owner | Notes |
|---|---|---|---|---|---|---|
| `start/index.md` | `discover/index.md` | Start here | overview | rewrite | 13 | Path picker for evaluators (ord 0). |
| `start/what-is-facet.md` | `discover/why-facet.md` | Why Facet | explanation | rewrite | 13 | Problem first (scattered tools, lost control of access, fragile bridges, price hikes), then the idea: apps disposable, data durable. ord 1. |
| `start/architecture.md` | `discover/how-it-works/index.md` | The big picture | explanation | rewrite | 13 | L1: one diagram, the request path in plain words. Engine detail (channels, enforcers, event bus) moves to `admin/under-the-hood/` pages (preservation checklist). |
| `start/is-facet-right-for-you.md` | `discover/is-it-right-for-you.md` | Is Facet right for you? | explanation | rewrite | 13 | Keep the honest limits. ord 4. |
| `start/security-governance.md` | `discover/security.md` | Security and governance | explanation | rewrite | 13 | For Marc. Each claim links to the admin page that proves it. ord 5. |
| `start/glossary.md` | `reference/glossary.md` | Glossary | reference | rewrite | 19 | Every glossary term of `01-voice-and-vibe.md` §5.1 and every engine word of §5.2, each with a plain definition and a link. |
| `start/install.md` | `build/dev-environment.md` | Set up a dev environment | how-to | rewrite | 14 | For developers working in files mode and on apps. |

## 2. `tutorials/` → `build/first-hour/`

| Old | New | Proposed title | Type | Action | Owner | Notes |
|---|---|---|---|---|---|---|
| `tutorials/index.md` | `build/first-hour/index.md` | Your first hour | overview | rewrite | 14 | ord 0. The plan, the time, what you need. |
| `tutorials/t1-run-facet.md` | `build/first-hour/run-facet.md` | Run Facet | tutorial | rewrite | 14 | ord 1. |
| `tutorials/t2-first-domain.md` | `build/first-hour/first-domain.md` | Model your first domain | tutorial | rewrite | 14 | ord 2. Uses the assistant in a draft, then Check and Publish. Brightwater *Equipment* domain. Absorbs the planned T3 ("Build it with the assistant"). |
| `tutorials/t4-team-access.md` | `build/first-hour/team-access.md` | Give your team access | tutorial | rewrite | 14 | ord 5 (after first-domain-in-files 3 and first-app 4; connect-an-agent is 6). Brightwater *Warehouse* role, purchase price hidden with a field tag. |

## 3. `concepts/` → Discover (L1), Build/Admin depth (L3)

| Old | New | Proposed title | Type | Action | Owner | Notes |
|---|---|---|---|---|---|---|
| `concepts/index.md` | — | — | — | retire | 11 | Redirect to `/discover/how-it-works/`. |
| `concepts/domains-and-isolation.md` | `discover/how-it-works/domains.md` + `build/deeper/domain-isolation.md` | Domains: where your data lives / How domains stay isolated | explanation | split | 13 (L1), 16 (L3) | |
| `concepts/documents-doctypes-projections.md` | `build/deeper/documents-and-projections.md` + `discover/how-it-works/documents.md` | How a document is stored / Documents: records with a memory | explanation | split | 16 (L3), 13 (L1) | L1 also absorbs the plain part of the mutation log (every change recorded, undo). |
| `concepts/mutation-log.md` | `admin/under-the-hood/change-log.md` | The change log, in detail | explanation | rewrite | 18 | L1 part goes to `discover/how-it-works/documents.md` (13). |
| `concepts/draft-publish.md` | `build/model/in-app/how-drafts-work.md` | How drafts work | explanation | rewrite | 16 | |
| `concepts/auth-contexts.md` | `admin/under-the-hood/one-role-at-a-time.md` | Why you act as one role at a time | explanation | rewrite | 18 | L1 part goes to `discover/how-it-works/roles.md` (13). |
| `concepts/authorization-enforcement.md` | `admin/under-the-hood/how-access-is-enforced.md` | How access is enforced | explanation | rewrite | 18 | |
| `concepts/roles-levels-authority.md` | `admin/people/who-can-change-roles.md` | Who can change roles | explanation | rewrite | 18 | |
| `concepts/apps-grants-roles.md` | `build/apps/connect/what-an-app-can-do.md` | What an app is allowed to do | explanation | rewrite | 17 | L1 part goes to `discover/how-it-works/apps.md` (13). |
| `concepts/events-delivery.md` | `admin/under-the-hood/events-and-delivery.md` | Events and delivery guarantees | explanation | rewrite | 18 | |
| `concepts/schema-evolution.md` | `build/deeper/schema-evolution.md` | How old documents follow a new schema | explanation | rewrite | 16 | |
| `concepts/cross-domain-replication.md` | `build/deeper/cross-domain-replication.md` | How copied fields stay in sync | explanation | rewrite | 16 | |
| `concepts/ai-under-callers-rights.md` | `discover/how-it-works/assistant.md` + `admin/under-the-hood/ai-and-permissions.md` | The assistant: AI with your rights / AI and permissions, in detail | explanation | split | 13 (L1), 18 (L3) | |

## 4. `workspace/` → `use/`

| Old | New | Proposed title | Type | Action | Owner | Notes |
|---|---|---|---|---|---|---|
| `workspace/index.md` | `use/index.md` | Use Facet | overview | rewrite | 20 | Tab index. |
| `workspace/sign-in-mfa.md` | `use/first-day/sign-in.md` | Sign in and secure your account | how-to | rewrite | 15 | ord 2. |
| `workspace/dashboard.md` | `use/first-day/dashboard.md` | The dashboard | how-to | rewrite | 15 | ord 3. |
| `workspace/viewing-editing-document.md` | `use/documents/view-and-edit.md` | Open and edit a document | how-to | rewrite | 15 | |
| `workspace/comments-attachments.md` | `use/documents/comments-attachments.md` | Comments and attachments | how-to | rewrite | 15 | |
| `workspace/history-undo.md` | `use/documents/history-undo.md` | History and undo | how-to | rewrite | 15 | |
| `workspace/import-export.md` | `use/documents/import-export.md` | Import and export data | how-to | rewrite | 15 | |
| `workspace/lists-filters-views.md` | `use/finding/lists-and-views.md` | Lists, boards and calendars | how-to | rewrite | 15 | |
| `workspace/search-command-palette.md` | `use/finding/search.md` | Search and the command palette | how-to | rewrite | 15 | |
| `workspace/keyboard-shortcuts.md` | `use/finding/keyboard-shortcuts.md` | Keyboard shortcuts | reference | move | 15 | |
| `workspace/notifications.md` | `use/notifications.md` | Notifications | how-to | rewrite | 15 | |
| `workspace/assistant.md` | `use/assistant.md` | Ask the assistant | how-to | rewrite | 15 | |
| `workspace/settings-sessions-api-keys.md` | `use/account.md` | Your settings and API keys | how-to | rewrite | 15 | |

## 5. `build/` → `build/model/` and `build/deeper/`

| Old | New | Proposed title | Type | Action | Owner | Batch | Notes |
|---|---|---|---|---|---|---|---|
| `build/index.md` | `build/index.md` | Build | overview | rewrite | 20 | — | Tab index (path picker). The old content becomes `build/model/index.md` material. |
| `build/domains-drafts-editors.md` | `build/model/in-app/drafts-and-publishing.md` | Drafts, editors and publishing | how-to | rewrite | 16 | A | |
| `build/domain-builder-assistant.md` | `build/model/in-app/build-with-assistant.md` | Build with the assistant | how-to | rewrite | 16 | A | |
| `build/checking-before-publish.md` | `build/model/in-app/check-before-publish.md` | Check before you publish | how-to | rewrite | 16 | A | Verify whether diagnostics also run under the watcher; if so, say it and link from the files pages. |
| `build/dev-domain-watcher.md` | `build/model/in-files/domain-watcher.md` | The domain watcher | how-to | rewrite | 16 | A | |
| `build/bundles.md` | `build/model/bundles.md` | Move domains with bundles | how-to | rewrite | 16 | A | |
| `build/evolving-schema.md` | `build/model/change-a-live-domain.md` | Change a live domain safely | how-to | rewrite | 16 | A | |
| `build/designing-doctypes.md` | `build/model/data/design-doctypes.md` | Design a doctype | how-to | rewrite | 16 | B | |
| `build/field-types.md` | `build/model/data/field-types.md` | Choose field types | how-to | rewrite | 16 | B | The reference twin stays at `reference/field-types.md`. |
| `build/identifiers-unique-constraints.md` | `build/model/data/identifiers-uniqueness.md` | Reference numbers and uniqueness | how-to | rewrite | 16 | B | |
| `build/computed-fields.md` | `build/model/data/computed-fields.md` | Computed fields | how-to | rewrite | 16 | B | |
| `build/secret-write-only-fields.md` | `build/model/data/secret-fields.md` | Secret and write-only fields | how-to | rewrite | 16 | B | |
| `build/files-artifacts.md` | `build/model/data/files.md` | Files in fields | how-to | rewrite | 16 | B | |
| `build/references-links-backlinks.md` | `build/model/relations/references-links.md` | Link documents together | how-to | rewrite | 16 | B | |
| `build/parent-child-composition.md` | `build/model/relations/parent-child.md` | Parent and child documents | how-to | rewrite | 16 | B | |
| `build/sharing-across-domains.md` | `build/model/relations/across-domains.md` | Share data across domains | how-to | rewrite | 16 | B | |
| `build/sidecars.md` | `build/model/relations/comments-attachments.md` | Add comments and attachments | how-to | rewrite | 16 | B | Users see "comments and attachments"; the term **sidecar** appears once, in the lead. |
| `build/display-names-search-text.md` | `build/model/views/names-and-search.md` | Display names and search text | how-to | rewrite | 16 | C | |
| `build/view-templates.md` | `build/model/views/document-pages.md` | Design document pages | how-to | rewrite | 16 | C | |
| `build/collection-views.md` | `build/model/views/lists-boards-calendars.md` | Lists, boards and calendars | how-to | rewrite | 16 | C | |
| `build/schematic-view.md` | `build/model/views/schematic.md` | See your domain as a diagram | how-to | rewrite | 16 | C | |
| `build/named-actions.md` | `build/model/behaviour/named-actions.md` | Add actions to a doctype | how-to | rewrite | 16 | C | |
| `build/lifecycle-scripts-guards.md` | `build/model/behaviour/scripts-and-guards.md` | Scripts and guards | how-to | rewrite | 16 | C | |
| `build/event-hooks.md` | `build/model/automation/event-hooks.md` | React to events and schedules | how-to | rewrite | 16 | C | |
| `build/webhooks.md` | `build/model/automation/webhooks.md` | Send webhooks | how-to | rewrite | 16 | C | |
| `build/notifications-mentions.md` | `build/model/automation/notifications.md` | Notifications and mentions | how-to | rewrite | 16 | C | |
| `build/named-scopes.md` | `build/model/access/named-scopes.md` | Write row rules for roles | how-to | rewrite | 16 | C | Author half; admin half is `admin/people/row-scopes.md`. |

## 6. `apps/` → `build/apps/`

| Old | New | Proposed title | Type | Action | Owner | Batch | Notes |
|---|---|---|---|---|---|---|---|
| `apps/index.md` | `build/apps/index.md` | Build apps | overview | rewrite | 17 | A | Group path picker: browser app / backend service / AI agent. |
| `apps/how-apps-work.md` | `build/apps/how-apps-work.md` | How apps work on Facet | explanation | rewrite | 17 | A | |
| `apps/quickstart-dev-cli.md` | `build/apps/quickstart.md` | Quickstart | how-to | rewrite | 17 | A | |
| `apps/registering-app.md` | `build/apps/connect/register.md` | Register an app | how-to | rewrite | 17 | A | |
| `apps/oauth-login.md` | `build/apps/connect/user-login.md` | Sign users in | how-to | rewrite | 17 | A | OAuth 2.1 + PKCE named in the lead. |
| `apps/dpop.md` | `build/apps/connect/dpop.md` | Bind tokens to your app (DPoP) | how-to | rewrite | 17 | A | |
| `apps/cors-origins.md` | `build/apps/connect/cors.md` | Allowed origins and CORS | how-to | rewrite | 17 | A | |
| `apps/service-accounts.md` | `build/apps/connect/backend-apps.md` | Backend apps and service accounts | how-to | rewrite | 17 | A | |
| `apps/permission-manifest.md` | `build/apps/connect/permission-manifest.md` | Show only what the user can do | how-to | rewrite | 17 | A | |
| `apps/rest-api.md` | `build/apps/data/rest-api.md` | Use the REST API | how-to | rewrite | 17 | B | |
| `apps/typescript-sdk.md` | `build/apps/data/sdk.md` | The TypeScript SDK | how-to | rewrite | 17 | B | |
| `apps/search.md` | `build/apps/data/search.md` | Search from an app | how-to | rewrite | 17 | B | |
| `apps/websockets.md` | `build/apps/data/realtime.md` | Live updates | how-to | rewrite | 17 | B | |
| `apps/files.md` | `build/apps/data/files.md` | Upload and serve files | how-to | rewrite | 17 | B | |
| `apps/bulk-import-export.md` | `build/apps/data/bulk-import-export.md` | Bulk import and export | how-to | rewrite | 17 | B | |
| `apps/hosting-deploy.md` | `build/apps/host/deploy.md` | Deploy your app on Facet | how-to | rewrite | 17 | B | |
| `apps/chat-embed.md` | `build/apps/host/embed-assistant.md` | Embed the assistant in your app | how-to | rewrite | 17 | B | |
| `apps/ai-coding-agents.md` | `build/apps/agents/coding-agents.md` | Build apps with a coding agent | how-to | rewrite | 17 | B | The domain-file part moves to `build/model/in-files/with-a-coding-agent.md` (16). |
| `apps/mcp-agents.md` | `build/apps/agents/mcp.md` | Connect agents over MCP | how-to | rewrite | 17 | B | |
| `apps/agent-tools.md` | `build/apps/agents/agent-tools.md` | What agents can do | how-to | rewrite | 17 | B | The generated table stays in `reference/agent-tools.md`. |

## 7. `govern/` and `operate/` → `admin/`

| Old | New | Proposed title | Type | Action | Owner | Batch | Notes |
|---|---|---|---|---|---|---|---|
| `govern/index.md` | `admin/index.md` | Administer | overview | merge | 20 | — | Merges with `operate/index.md`. Tab index. |
| `operate/index.md` | `admin/index.md` | — | — | merge | 20 | — | See above; redirect `/operate/` → `/admin/`. |
| `govern/accounts-lifecycle.md` | `admin/people/accounts.md` | Manage accounts | how-to | rewrite | 18 | A | |
| `govern/roles-permission-lines.md` | `admin/people/roles-and-permissions.md` | Roles and permissions | how-to | rewrite | 18 | A | |
| `govern/assigning-roles-election.md` | `admin/people/assign-roles.md` | Assign roles | how-to | rewrite | 18 | A | |
| `govern/row-scopes.md` | `admin/people/row-scopes.md` | Show each role only its rows | how-to | rewrite | 18 | A | |
| `govern/field-visibility-tags.md` | `admin/people/hidden-fields.md` | Hide a field from some roles | how-to | rewrite | 18 | A | |
| `govern/enforcing-mfa.md` | `admin/people/mfa.md` | Require MFA | how-to | rewrite | 18 | A | |
| `govern/sso-oidc.md` | `admin/people/sso.md` | Single sign-on (OIDC) | how-to | rewrite | 18 | A | |
| `govern/sessions-tokens-lockouts.md` | `admin/people/sessions-lockouts.md` | Sessions and lockouts | how-to | rewrite | 18 | A | |
| `govern/app-grants.md` | `admin/apps-access/app-grants.md` | Control what apps can reach | how-to | rewrite | 18 | A | |
| `govern/api-keys.md` | `admin/apps-access/api-keys.md` | API keys | how-to | rewrite | 18 | A | |
| `govern/auditing-activity.md` | `admin/history/audit.md` | See who did what | how-to | rewrite | 18 | A | |
| `govern/rolling-back.md` | `admin/history/roll-back.md` | Roll back a change | how-to | rewrite | 18 | A | |
| `govern/retention.md` | `admin/history/retention.md` | Retention: what is kept | how-to | merge | 18 | A | Merges with `operate/retention-tuning.md`: policy first (admin), then tuning (operator) as a second half. |
| `operate/retention-tuning.md` | `admin/history/retention.md` | — | — | merge | 18 | A | See above. |
| `govern/governing-assistant.md` | `admin/assistant/govern.md` | Govern the assistant | how-to | rewrite | 18 | B | |
| `operate/assistant-config.md` | `admin/assistant/connect-a-model.md` | Connect a language model | how-to | rewrite | 18 | B | |
| `operate/system-requirements.md` | `admin/install/requirements.md` | System requirements | reference | rewrite | 18 | B | |
| `operate/containers-tls.md` | `admin/install/containers.md` | Run with containers | how-to | rewrite | 18 | B | |
| `operate/production.md` | `admin/install/production.md` | Go to production | how-to | rewrite | 18 | B | A checklist page that links the others. |
| `operate/bootstrap-cli.md` | `admin/install/bootstrap.md` | First start and bootstrap | how-to | rewrite | 18 | B | |
| `operate/configuration-files.md` | `admin/configure/configuration-files.md` | Configuration files | how-to | rewrite | 18 | B | |
| `operate/system-settings.md` | `admin/configure/system-settings.md` | System settings | how-to | rewrite | 18 | B | |
| `operate/email.md` | `admin/configure/email.md` | Email | how-to | rewrite | 18 | B | |
| `operate/file-storage.md` | `admin/configure/file-storage.md` | File storage | how-to | rewrite | 18 | B | |
| `operate/currencies.md` | `admin/configure/currencies.md` | Currencies | how-to | rewrite | 18 | B | |
| `operate/localization.md` | `admin/configure/languages.md` | Languages | how-to | rewrite | 18 | B | |
| `operate/health-metrics-logs.md` | `admin/keep-running/monitoring.md` | Health, metrics and logs | how-to | rewrite | 18 | B | |
| `operate/jobs-cron.md` | `admin/keep-running/jobs-cron.md` | Background jobs and cron | how-to | rewrite | 18 | B | |
| `operate/migrations.md` | `admin/keep-running/migrations.md` | Database migrations | how-to | rewrite | 18 | B | |
| `operate/upgrades-shutdown.md` | `admin/keep-running/upgrades.md` | Upgrade Facet | how-to | rewrite | 18 | B | |
| `operate/indexes.md` | `admin/keep-running/indexes.md` | Indexes | how-to | rewrite | 18 | B | |

## 8. `compare/`, `reference/`, `changelog/`, landing

| Old | New | Proposed title | Type | Action | Owner | Notes |
|---|---|---|---|---|---|---|
| `index.mdx` | `index.mdx` | Welcome to Facet | — | rewrite | 20 | Doors to the five tabs + **Your first hour**. |
| `compare/index.md` | `discover/compare/index.md` | Compare | overview | move | 13 | |
| `compare/vs-ai-built-apps.md` | `discover/compare/vs-ai-built-apps.md` | Facet vs "just let AI build it" | explanation | move | 13 | Voice pass only. |
| `compare/vs-airtable-notion.md` | `discover/compare/vs-airtable-notion.md` | Facet vs Airtable and Notion | explanation | move | 13 | Voice pass only. |
| `compare/vs-odoo-erp.md` | `discover/compare/vs-odoo-erp.md` | Facet vs Odoo and ERP suites | explanation | move | 13 | Voice pass only. |
| `compare/vs-retool-lowcode.md` | `discover/compare/vs-retool-lowcode.md` | Facet vs Retool and low-code | explanation | move | 13 | Voice pass only. |
| `compare/vs-supabase-firebase.md` | `discover/compare/vs-supabase-firebase.md` | Facet vs Supabase and Firebase | explanation | move | 13 | Voice pass only. |
| `changelog/index.md` | `reference/changelog.md` | Releases | reference | move | 19 | |
| `reference/index.md` | `reference/index.md` | Reference | overview | rewrite | 20 | Tab index. |
| `reference/rest-api.mdx` | same | REST API | reference | keep | 19 | Generated embed; lead only. |
| `reference/error-responses.md` | same | Error responses | reference | rewrite | 19 | Hand-written. |
| `reference/jinja2-context.md` | same | Jinja2 template context | reference | rewrite | 19 | Hand-written. |
| `reference/permission-syntax.md` | same | Permission line syntax | reference | rewrite | 19 | Hand-written. |
| `reference/account-settings-keys.md` | same | — | reference | keep | 19 | Generated: generator only. |
| `reference/agent-tools.md` | same | — | reference | keep | 19 | Generated. |
| `reference/cli-facet.md` | same | — | reference | keep | 19 | Generated. |
| `reference/cli-npm.md` | same | — | reference | keep | 19 | Generated. |
| `reference/config-keys.md` | same | — | reference | keep | 19 | Generated. |
| `reference/doctype-schema.md` | same | — | reference | keep | 19 | Generated. |
| `reference/dvt-schema.md` | same | — | reference | keep | 19 | Generated. |
| `reference/feature-index.md` | same | — | reference | keep | 19 | Generated from front-matter; regenerate after the moves (WP 11) and at the end (WP 21). |
| `reference/field-types.md` | same | — | reference | keep | 19 | Generated. |
| `reference/filter-operators.md` | same | — | reference | keep | 19 | Generated. |
| `reference/health-metrics-names.md` | same | — | reference | keep | 19 | Generated. |
| `reference/lua-api.md` | same | — | reference | keep | 19 | Generated. |
| `reference/system-settings-keys.md` | same | — | reference | keep | 19 | Generated. |
| `reference/webhook-payloads.md` | same | — | reference | keep | 19 | Generated. |

## 9. New pages

| New path | Title | Type | Owner | Features (minimum) | What it holds |
|---|---|---|---|---|---|
| `discover/how-it-works/roles.md` | Roles: who sees and does what | explanation | 13 | RBC-01, RBC-02, RBC-04, RBC-05 (L1) | Roles, one role at a time, rows and fields, enforced on every request. Absorbs the L1 part of auth contexts and enforcement. |
| `discover/how-it-works/apps.md` | Apps: built fast, replaced freely | explanation | 13 | APP-01, APP-06, RBC-08 (L1) | An app lives outside the data, signs in through Facet, gets at most what the user and the app may do; Facet hosts it. |
| `discover/a-day-at-brightwater.md` | A day at Brightwater | explanation | 13 | — | An illustrative tour of the running example: who uses what, in which tab of the docs each part is explained. Clearly labelled as a fictional example. |
| `discover/licensing-and-services.md` | Licensing and services | explanation | 13 | — | BSL 1.1 + Additional Use Grant in plain words, the conversion to Apache 2.0, what you may and may not do; how to get help. Decisions D6, D10. Source: `LICENSE`, `LICENSING.md`, `TRADEMARKS.md`. |
| `use/first-day/index.md` | A tour of the workspace | tutorial | 15 | FE-19, FE-02, FE-07 | The welcome tour, the sidebar, where things are. Screenshots. |
| `use/finding/index.md`, `use/documents/index.md` | (group overviews) | overview | 15 | — | Short path pickers, only if the group has 4+ pages. |
| `build/first-hour/first-domain-in-files.md` | The same domain in files | tutorial | 14 | DOM-19, DOM-15 | Build the *Equipment* domain from files under the watcher; export it as a bundle. |
| `build/first-hour/first-app.md` | Ship your first app | tutorial | 14 | APP-01, APP-02, APP-06, APP-09, APP-10 | Register, scaffold with `@facetapp/cli`, build with a coding agent, deploy, sign in. Absorbs the planned T5. |
| `build/first-hour/connect-an-agent.md` | Connect an AI agent | tutorial | 14 | AI-05, APP-04 | An MCP client on one role, asking questions about Brightwater data. Absorbs the planned T6. |
| `build/model/index.md` | Choose how you build | overview | 16 A | DOM-02, DOM-19 | The two build modes as a decision (`02-information-architecture.md` §2.3). |
| `build/model/in-files/domain-files.md` | The domain file layout | reference | 16 A | DOM-19, DOM-15 | Folder layout the watcher reads; how it relates to the bundle layout. Source: `doc/backend/portable-domains.md`, `doc/backend/dev-domain-watcher.md`, code. |
| `build/model/in-files/with-a-coding-agent.md` | Build domains with a coding agent | how-to | 16 A | DOM-19, AI-06 | Agent writes files, watcher applies, diagnostics feed back. Absorbs the domain part of `apps/ai-coding-agents.md`. |
| `build/model/dev-to-production.md` | From dev to production | how-to | 16 A | DOM-15, DOM-02, DOM-19 | The round trip; what moves and what does not; editing the same domain in both places. |
| `build/deeper/index.md` | How it works (deeper) | overview | 16 A | — | Path picker for the L3 build pages. |
| `admin/install/index.md`, `admin/people/index.md`, … | (group overviews) | overview | 18 | — | Only for groups with 5+ pages. |
| `admin/keep-running/backup-restore.md` | Back up and restore | how-to | 18 B | — | **Blocked on D7.** Do not write until decided. |
| `admin/under-the-hood/index.md` | Under the hood | overview | 18 B | — | Path picker for the L3 admin pages. |
| `reference/limits.md` | Limits | reference | 19 | — | **Only if D9 = A.** Every hard limit with its source (aggregate caps, import caps, upload size, rate limits, history limits). |

## 10. Redirects

WP 11 generates one Astro redirect per old URL from §1–§8 (for split pages,
to the first listed target; for retired pages, to the named replacement).
Old French URLs (`/fr/<old>/`) redirect the same way. WP 21 checks that every
old URL in the current `dist/sitemap-0.xml` answers.
