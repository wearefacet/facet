# AI — Assistants, agent tools, MCP

Pinned to `c2f1427e`. The AI layer: three assistant surfaces, one shared tool
catalogue, and the MCP server.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| AI-01 | Workspace assistant | Chat over the caller's data under the caller's own RBAC: SSE streaming, tool-call traces, cancel (Redis pub/sub fan-out), turn replay, per-account usage; UI tools `navigate` and `show_documents`. | REST `/api/assistant/conversations*`, `/api/assistant/cancel/:turn_token`; UI chat | `doc/backend/workspace-assistant.md`, `doc/backend/agent-conversations.md`, `src/assistant/workspace/` |
| AI-02 | Domain-builder assistant | Conversational domain authoring scoped to a draft domain: read tools, draft-scoped write tools, UI tools; system-tier identity for tool mutations; 16 skill docs steer the model. | REST domain-builder conversation route; UI `/Builder` chat | `doc/backend/domain-builder-skills.md`, `src/assistant/domain_builder/` |
| AI-03 | Per-app assistant | Assistant surface for hosted apps (embedded via `@facetapp/chat`): per-app availability gate, app-scoped caller, registry tools minus `ping`, no skills/UI tools. | REST dedicated create route; app frontends | `doc/packages/chat.md`, `src/assistant/app/` |
| AI-04 | Agent tool catalogue | Shared tools for MCP + assistants: `whoami`, `list_domains`, `list_doctypes`, `get_schema`, `list_documents`, `get_document`, `resolve_refs`, `search_documents`, `aggregate_documents`, `list_mutations`, `get_links`, `get_backrefs`, `create_document`, `update_document`, `delete_document`, `call_action`, `batch`, `create_sidecar`, `list_sidecars`, `request_artifact_upload`, `get_artifact`, `list_artifact_refs`, `ping` — every call runs through the caller's AuthContext. | agent/MCP | `doc/backend/agent-tools.md`, `src/agent_tools/` |
| AI-05 | MCP resource server | `/api/_mcp/:role_slug` — Facet as an in-process MCP server; OAuth 2.1 resource server (RFC 9728 protected-resource metadata, bearer verification); one fixed delegated role per endpoint; endpoint directory `GET /api/_mcp/endpoints` lists the caller's held-role endpoints. | MCP over HTTP; REST | `doc/backend/mcp.md`, `src/mcp/` |
| AI-06 | Skill corpus | `read_skill` tool over a markdown corpus filtered per surface (agent skills, 16 domain-builder skills, workspace skills); front-matter allow-list. | agent/MCP/assistant | `doc/backend/agent-tools.md`, `src/agent_tools/skills/` |
| AI-07 | Usage ledger & limits | Per-account token usage ledger (`GET /api/assistant/usage`), token-budget seam, history limits; aged usage rows pruned by cron. | REST; UI usage view | `doc/backend/assistant.md`, `doc/backend/agent-conversations.md`, `src/assistant/usage.cr`, `limits.cr` |
| AI-08 | Assistant configuration | LLM endpoint/model/temperature/prompt config via SystemSettings; operator custom instructions; `assistant.auto_execute_tools` toggle; availability access gate. | SystemSettings UI; config | `doc/backend/assistant.md`, `src/assistant/config.cr`, `custom_prompt.cr` |
| AI-09 | Stale-turn sweep | Cron marks abandoned `running` turns as `error` so conversations never stick. | automatic cron | `doc/backend/assistant.md`, `src/cron/assistant_turn_sweep.cr` |
# APP — Registered apps, OAuth, hosting, SDKs

Pinned to `c2f1427e`. The app platform: register an app, authorize it, host its
frontend, ship it with the CLI, build against the SDKs.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| APP-01 | App registry (`app.App`) | Register an app: slug, public/confidential client type, redirect URIs, allowed origins, headless flag; hooks enforce slug immutability and redirect validation; `facet-cli` seeded by default. | REST documents on `app.App`; UI `/Configure/apps` (+ new-app wizard) | `doc/backend/app-system.md`, `data/seeds/app.App/` |
| APP-02 | OAuth 2.1 authorization server | `/app/oauth/*`: authorize (PKCE S256), single-use 60 s codes in Redis, token exchange, refresh, discovery (`/.well-known/oauth-authorization-server`), client-info; per-IP rate limiting on the token endpoint. | REST `/app/oauth/authorize|token|refresh|register|client-info` | `doc/backend/oauth.md`, `src/oauth/` |
| APP-03 | DPoP proof binding | Public clients bind tokens to a proof key (RFC 9449); proof verified before code consume; `jti` replay cache; `htu` pinning. | REST headers on token + API calls | `doc/backend/oauth.md`, `src/oauth/dpop.cr` |
| APP-04 | Dynamic client registration | RFC 7591 registration endpoint for MCP clients (and other automated consumers). | REST `POST /app/oauth/register` | `doc/backend/mcp.md`, `src/oauth/register.cr` |
| APP-05 | Consent screen | Browser consent page for the delegated-authorization flow: shows the app, requested scopes, presented redirect URI, and the role election (`role` form key). | UI `/oauth/consent` | `doc/backend/oauth.md`, `frontend/src/routes/oauth/consent/` |
| APP-06 | App hosting | Deploy uploaded builds (`app.Deployment`), activate/rollback releases; per-request host dispatch serves the active build behind Facet auth with static asset caching; Caddy on-demand TLS approval endpoint (`GET /edge/host-ask`) issues certificates only for hosts an active app claims; no external CDN/pipeline. | REST `POST /api/app/:id/deploy`; dev-CLI `deploy`/`releases`/`rollback`; served app URLs | `doc/backend/app-system.md`, `src/app/hosting.cr`, `deploy.cr`, `host_ask.cr` |
| APP-07 | App API keys + service accounts | Backend apps get a service account and one active `fct_` key (issue/rotate/revoke); reach = app grant ∩ pinned role, re-resolved per request. | REST `GET/POST/DELETE /api/app/:id/api-key`; UI app credentials page | `doc/backend/app-system.md`, `src/app/api_keys.cr`, `service_accounts.cr` |
| APP-08 | CORS for registered origins | Registered `allowed_origins` get CORS + preflight handling on the OAuth and API surfaces. | automatic for browser apps | `doc/backend/oauth.md`, `src/oauth/cors.cr` |
| APP-09 | Developer CLI (`@facetapp/cli`) | App-developer CLI: `login` / `whoami` / `logout` (OAuth PKCE + DPoP), `init` scaffold, `deploy`, `releases`, `rollback <revision>`. | dev-CLI | `doc/packages/cli.md`, `packages/cli/` |
| APP-10 | TypeScript SDK (`@facetapp/sdk`) | HTTP handles, query builder, ETag cache, OAuth helper, WebSocket realtime, artifact helpers for Facet frontends. | npm package | `doc/packages/sdk.md`, `packages/sdk/` |
| APP-11 | Chat embed (`@facetapp/chat`) | Embeddable assistant chat for hosted apps (Svelte 5 custom elements + `FacetAssistant` facade + HTTP/SSE driver), backed by the per-app assistant surface. | npm package in app frontends | `doc/packages/chat.md`, `packages/chat/` |
# AUD — Mutation log, audit, rollback

Pinned to `c2f1427e`. The append-only event log: every change traceable, any
document restorable.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| AUD-01 | Append-only mutation log | Every create/update/delete/action writes a `mutations` row (diff, actor, channel, cause) in the same transaction as the projection write. | automatic on every write | `doc/backend/mutation.md`, `src/mutation/` |
| AUD-02 | Audit reading | Per-document history (`GET …/:id/history`, incl. nested child history) and the global `GET /api/Audit` log with filters. | REST; UI `/…/[id]/history`, `/Configure/audit` | `doc/backend/audit.md`, `src/audit/list.cr` |
| AUD-03 | Audit redaction | Mutation arguments are redacted by row shape for readers without the field tag; the response names the redacted paths (`redacted: [["secret"]]`). | automatic on audit reads | `doc/backend/audit.md`, `Audit::Redact` |
| AUD-04 | Rollback | Replay-based rollback of a document (or a child) to a prior mutation; snapshot rollback; rollback to a `delete` restores the document. | REST `POST /api/Audit/:mutation_id/rollback`, `…/:id/rollback`, child rollback; UI history page | `doc/backend/audit.md`, `src/audit/rollback.cr` |
| AUD-05 | Write-time coalescing | Same-actor, same-channel updates inside a configurable window fold into one mutation row (fresh ULID, idx gap as the documented clue). | automatic; `mutations.coalesce_window_minutes` | `doc/backend/mutation.md`, `src/document/coalesce.cr` |
| AUD-06 | Retention compaction | Cron folds pre-retention history into one synthetic snapshot row per document; per-doctype retention overrides; rollback depth equals the window. | automatic cron; config + SystemSettings | `doc/backend/mutation.md`, `src/cron/mutation_compaction.cr` |
| AUD-07 | Tombstone retention | Deleted rows keep `content`/`links`/`search` until a retention window passes, then a cron prunes the payload (`display_name` kept for audit labelling). | automatic cron; `tombstone.content_retention_days` | `doc/backend/mutation.md`, `src/cron/tombstone_content_prune.cr` |
| AUD-08 | Provenance & cause metadata | Each mutation carries actor, channel and cause chain (`system`, `replication`, `hooks`, app attribution); audit rows attribute API-key writes to the service account. | visible in audit views | `doc/backend/mutation.md`, `src/mutation/provenance.cr` |
# AUT — Events, hooks, webhooks, jobs, notifications, mail

Pinned to `c2f1427e`. Everything that reacts: the event bus and its consumers.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| AUT-01 | Event bus (Redis Streams) | Mutation events published post-commit, partitioned streams, consumer groups; delivery is at-most-once by design; loss counters exposed on `/Healthcheck` (`event_loss`), lag gauge from `Cron::EventLagCheck`. | internal; observable via `/Healthcheck` | `doc/backend/event.md`, `src/event/` |
| AUT-02 | Domain event hooks | Lua hooks bound to source events on `core.Domain.content.hooks`; sandboxed execution with cause chain; hooks added at runtime picked up by the subscriber-sync fiber; cron-scheduled hooks under a Redis lease. | doctype/domain authoring; automatic firing | `doc/backend/hooks.md`, `src/hooks/` |
| AUT-03 | Outbound webhooks | `core.Webhook` registrations deliver signed (HMAC) event payloads to HTTPS targets: SSRF target guard at authoring/dispatch/test, inline `/test` with signed-body preview, per-webhook call log + replay, `$mine` ownership scope, reconcile cron repairs missed enqueues from the mutations log. | REST `POST /api/core/Webhook/:id/test`, `…/calls[/:call_id/replay]`; UI `/Settings/webhooks` | `doc/backend/webhook.md`, `src/webhook/` |
| AUT-04 | Background jobs | PostgreSQL-backed `background_jobs` queue: registered handlers, claim/lease, retry, retention sweep; powers import/export, domain export/import, webhook delivery. | enqueued by REST/CLI; job status routes | `doc/backend/jobs.md`, `src/jobs/` |
| AUT-05 | Cron scheduler + maintenance | In-process cron (own parser) with per-task fibers and Redis leases: mutation compaction, tombstone/secret/artifact prunes, sidecar + webhook reconcile, assistant sweep, lag check. | config `cron` entries; automatic | `doc/backend/cron.md`, `src/cron/` |
| AUT-06 | In-app notifications | Per-account notification store with bell/badge, paginated list, mark-read (one/all), one-shot action buttons wired to named document actions, `@mention` producer, download-key for export jobs; `notifications.in_app` preference gates delivery. | REST `/api/notifications*`; UI bell + panel | `doc/backend/notifications.md`, `src/notifications/` |
| AUT-07 | Outbound email | Carbon mailer with pluggable adapters (SMTP/test): invite email and password-reset email with ECR templates; sender/SMTP config via SystemSettings. | automatic on invite/reset | `src/emails/`, `doc/backend/system-settings.md` |
| AUT-08 | Lua scripting engine | Shared sandbox for all script surfaces (hooks, actions, lifecycle scripts, migrations, computed fields): `document.*`, `notification.*`, `util.*` (json, ulid, webhook URL safety), `date.*`, `math.*`; errors surface as catchable Lua errors and 422 guard text. | authoring surfaces; automatic execution | `doc/backend/lua-engine.md`, `src/lua/` |
# DOC — Document data plane

Pinned to `c2f1427e`. Reading and writing the organization's data: CRUD,
querying, search, realtime, bulk transfer.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| DOC-01 | Document CRUD | Create, read, update (`PATCH`), soft-delete (`DELETE`), restore a tombstoned document. JSONB projections in PostgreSQL. | REST `GET/POST/PATCH/DELETE /api/:domain/:doctype[/:id]`, `POST …/:id/restore`; UI list/show/edit | `doc/backend/document.md`, `doc/backend/util-projections.md`, `src/document/routes.cr` |
| DOC-02 | List + filter grammar | Lists with filters (`field__op` suffix grammar), sort, paging (`page`/`items`), named `?scope=`, `QUERY` transport with JSON body; unknown filter key → 422 with the filterable list. | REST `GET/QUERY /api/:domain/:doctype`; UI filter bar | `doc/backend/http-layer.md`, `doc/backend/filter-set.md`, `src/document/filter_compiler.cr` |
| DOC-03 | Aggregates | `count` / `sum` / `avg` / `min` / `max` over a filtered set (`?aggregate=&field=` on the list and child-list routes); money sums return a per-currency bag with exact decimals; `count` capped at 1000, field aggregates uncapped; RBAC-scoped and non-disclosing. | REST `GET/QUERY /api/:domain/:doctype?aggregate=…`; child lists forward it | `doc/backend/http-layer.md`, `src/document/list/aggregate.cr` |
| DOC-04 | ETag caching | Per-document ETag (projection `state` ULID) and per-collection ETags (`updated_at` scopes); `If-None-Match` → 304. | REST headers | `doc/backend/http-layer.md`, `src/http/caching.cr` |
| DOC-05 | Links and backrefs | Every write computes the reference `links` array; inverse links queryable per document. | REST `GET …/:id/backrefs`; UI backlinks panel | `doc/backend/links.md`, `src/document/backrefs.cr` |
| DOC-06 | Cross-doctype search | Trigram search over the rendered `search` corpus, per domain (`/api/:domain/search`) or global (`/api/search`); RBAC-scoped; accent folding. | REST `GET/QUERY /api/search`; UI command palette | `doc/backend/search.md`, `src/search/` |
| DOC-07 | Atomic parent+children create | One request creates a parent and its children in a single transaction; failure rolls the whole set back. | REST `POST /api/:domain/:doctype` with nested children | `doc/backend/document.md`, `src/document/create_with_children.cr` |
| DOC-08 | Document copy (internal primitive) | Recursive copy of a document with its children — used by portable export, artifact owner flows and secret adoption; not a user-facing duplicate action. | internal | `doc/backend/document.md`, `src/document/copy.cr` |
| DOC-09 | Write-only and secret fields | `write_only` fields stripped before persistence; `secret` fields stored out-of-band in the secret store, revealed only via staging flow. | REST writes; UI forms mask | `doc/backend/secrets.md`, `src/document/strip_write_only.cr` |
| DOC-10 | Reference validation | Reference field values checked for target existence (per element for collections); URN (RFC 8141) reference type; qualified `domain.Doctype.id` form. | REST writes | `doc/backend/document.md`, `src/document/reference_check.cr` |
| DOC-11 | Import / export (documents) | CSV or JSON import (one transaction, capped staging, unique checks) and export (keyset, one snapshot) as background jobs with status + download; export honours a saved CollectionView (`export_view`). | REST `POST /api/:domain/:doctype/import|export|export_view` + `GET …/import_export/:job_id[/download]`; UI import/export dialogs | `doc/backend/import-export.md`, `src/import_export/` |
| DOC-12 | Realtime updates | WebSocket bridge: RBAC-scoped subscriptions to document/collection paths; live document refresh in the UI (e.g. `must_change_pw` flip without reload). | WS `/ws`; UI live updates | `doc/backend/websocket.md`, `src/websocket/` |
| DOC-13 | Field defaults & normalization | Field defaults applied to new documents; per-type value normalization (datetime → UTC RFC-3339, color, money, diacritic folding). | REST create; UI forms | `doc/backend/document.md`, `src/document/apply_defaults.cr`, `normalize.cr` |
# DOM — Domains, doctypes, schema authoring

Pinned to `c2f1427e`. The schema layer: how an organization's data model is
defined, evolved, checked and moved between instances.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| DOM-01 | Domains (`core.Domain`) | Top-level grouping of doctypes; each domain isolates its data by access rules, not app code. Create, list, drop (with audit record). | REST `POST/GET /api/core/Domain`, `POST /api/core/Domain/:id/drop`; UI `/Configure/domains` | `doc/backend/draft-domains.md`, `src/domain/` |
| DOM-02 | Draft → publish lifecycle | Domain changes are authored as drafts and published atomically when ready; publish version gate; preview session; fail-closed draft teardown. | REST `POST /api/core/Domain/draft`, `/:id/draft`, `/:id/publish`, `/:id/preview-session`; UI `/Builder` | `doc/backend/draft-domains.md`, `doc/ops/build-a-domain.md`, `src/domain/publish*.cr` |
| DOM-03 | Doctypes (`core.DocType`) | Typed document schemas (fields, refs, actions, scopes) stored as definitions; create/update with schema version bump; an idempotent re-save (no diff) answers 200 with the unchanged projection. | REST `POST/GET /api/core/DocType`, `PUT /api/core/DocType/:id`; UI `/Builder`, `/Configure/domains/…/doctypes` | `doc/backend/doctype-system.md`, `src/doctype/` |
| DOM-04 | Field type system | 22 field types: `any`, `array`, `boolean`, `color`, `data` (computed), `date`, `dateperiod`, `datetime`, `dictionary`, `duration`, `enum`, `file`, `integer`, `long_text`, `money`, `object`, `period`, `phone`, `reference`, `secret`, `string`, `url`. Per-type validation, normalization, filter operators. | REST (all document writes/reads); UI forms | `doc/backend/doctype-system.md`, `doc/backend/util-color.md`, `src/doctype/field_types/` |
| DOM-05 | Composition (parent/children) | Child relationships in the definition; atomic parent+children create (`CreateWithChildren`); nested child routes addressed by relationship name; recursive document copy. | REST `POST /api/:domain/:doctype` with children, `…/:id/<child>`; UI form | `doc/backend/document.md`, `src/document/create_with_children.cr`, `copy.cr` |
| DOM-06 | Sidecars | Records attached to a host document (`core.Comment`, `core.Attachment`): own doctype, reference column, nested routes under the host, orphan sweep. | REST `…/:id/<sidecar>` routes; UI sidecar rail | `doc/backend/sidecar.md`, `src/document/sidecar_handler.cr` |
| DOM-07 | Named actions (Lua) | Scripted actions declared on a doctype with typed args (required, default, min/max, `collection:`), executed via `POST …/:action_name`; authoring-time script-vs-declaration validation. | REST `POST /api/:domain/:doctype/:id/:action`; UI action buttons | `doc/backend/document.md`, `src/doctype/action_definition.cr`, `script_validator.cr` |
| DOM-08 | Lifecycle scripts | `create` / `update` / `delete` Lua hooks per doctype; sandboxed; guard refusals surface as 422 with the guard text. | REST (rides every write); seeded examples (`app.App`) | `doc/backend/lua-engine.md`, `src/document/script_context/` |
| DOM-09 | Computed fields | `data`-typed fields computed by Lua at mutation time; not directly writable, not aggregatable. | REST writes; UI show/form | `doc/backend/document.md`, `src/document/compute.cr` |
| DOM-10 | Sequential identifiers | Template-generated ids (e.g. `SO-0001`) per doctype; `genonly` mode refuses caller-supplied ids. | REST create; UI | `doc/backend/util-sequence.md`, `src/document/sequence_id.cr` |
| DOM-11 | Unique constraints | `unique: true` on a field enforced against live rows and same-batch import rows; violation names file + field. | REST writes, import | `doc/backend/document.md`, `src/document/unique_constraint.cr` |
| DOM-12 | Named scopes | Reusable server-side predicates over a doctype's own fields; usable as row scope and list `?scope=`. | REST list `?scope=`; RBAC role grants | `doc/backend/rbac.md`, `src/doctype/named_scope.cr` |
| DOM-13 | Domain editors (`core.DomainEditor`) | Scoped domain-admin membership: non-admin users can author one domain without platform admin. | REST; UI `/Builder`, `/Configure/domains/…/editors` | `doc/backend/domain-editors.md`, `src/domain/editors.cr` |
| DOM-14 | Domain grants (`core.DomainGrant`) | Cross-domain read-consent contract under the producer domain; activate/deactivate; gates cross-domain refs/replication (G2/G4). | REST `POST /api/core/DomainGrant/:id/activate|deactivate`; UI grants tabs | `doc/backend/domain-grants.md`, `src/grants/` |
| DOM-15 | Portable domain bundles | Export a domain (definitions, optionally documents) to dir/tar.gz/zip and import into another instance; transactional import with gates; async jobs + download. | CLI `facet domain:export|import`; REST `POST /api/core/Domain/export|import` + job status; UI import/export | `doc/backend/portable-domains.md`, `src/domain/portable/` |
| DOM-16 | Definition diagnostics | `/check` on one doctype or a whole draft domain: aggregated structural problems; dev-mode full report route. | REST `GET /api/core/DocType/:id/check`, `/api/core/Domain/:id/check`, `/api/dev/check-report`; UI `/Builder/…/check` | `doc/backend/doctype-system.md`, `src/doctype/check.cr`, `src/domain/check.cr` |
| DOM-17 | Lazy document migration | When a doctype definition changes, existing documents migrate on read/write through per-version Lua migration scripts. | automatic on read/write; script authoring in definition | `doc/backend/schema-migration.md`, `src/document/migrate.cr` |
| DOM-18 | Re-projection CLI | Recompute `search` / `links` / `display_name` projection columns for every live document of a doctype. | CLI `facet doctype:reproject` | `doc/backend/cli.md`, `src/doctype/reproject_cli.cr` |
| DOM-19 | Dev domain watcher | Injects folder-authored domain definitions at runtime in dev mode (edit files, no re-seed). | dev-only; `GET /api/dev/check-report` | `doc/backend/dev-domain-watcher.md`, `src/dev/` |
| DOM-20 | Domain schematic | Boxes-and-arrows visualisation of a domain's doctypes and reference edges, drag-to-move. | UI `/Configure/domains/…` + Builder | `doc/frontend/schematic.md`, `frontend/src/lib/components/schematic/` |
| DOM-21 | CollectionView (`core.CollectionView`) | Saved list presentation per doctype: `table` / `kanban` / `calendar` surfaces, columns, default views auto-created per doctype. | REST (CollectionView docs); UI list pages | `doc/backend/collection-view.md`, `src/doctype/collection_view/` |
| DOM-22 | DocumentView templates (DVT) | Declarative template tree for show/form pages (layout + field widgets + conditionals); authoring-time validator. | `doc/backend/doctype-system.md` (ViewTemplateValidator), `doc/frontend/workflow.md` (Document View Template), UI show pages, Builder | `doc/backend/doctype-system.md`, `src/doctype/view_template_validator.cr` |
| DOM-23 | Jinja2 templating for derived columns | Doctype-level Jinja2 templates render `display_name` and the `search` corpus at mutation time. | automatic on write; defined in doctype | `doc/backend/templating.md`, `src/templating/` |
| DOM-24 | Core seeding | Idempotent seed of core doctypes + currency registry at boot/CLI; embedded seed corpus (`data/seeds/`). | CLI `facet seed:core`, `seed:dev` | `doc/backend/cli.md`, `src/doctype/seed.cr`, `data/seeds/` |
| DOM-25 | Cross-domain field replication | `replicate` config on a consumer field pulls a source field's value through a local reference field: initial value pulled synchronously at write time (`SyncPull`), later source changes propagated by the event handler. Exactly one hop (a replica may not re-replicate); cross-domain edges gated by a domain grant (DOM-14); `Replication::Validator` refuses invalid shapes at doctype authoring, broken bindings fail closed at runtime. | REST (doctype definitions); automatic on source mutation | `doc/backend/replication.md`, `src/replication/` |
# FE — Workspace SPA surfaces

Pinned to `c2f1427e`. The SvelteKit single-page app an organization's people
actually use.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| FE-01 | Auth screens | Login (password + SSO provider list), MFA challenge and enrollment, forced password change, password reset. | UI `/login`, `/reset-password` | `doc/frontend/workflow.md`, `frontend/src/lib/components/features/auth/` |
| FE-02 | Dashboard | Landing page: domain cards with doctype counts and quick links, pinned doctypes/views, empty-state onboarding, new-domain / new-doctype dialogs. | UI `/` | `doc/frontend/workflow.md`, `frontend/src/lib/components/features/dashboard/` |
| FE-03 | List surfaces | Document lists in three layouts (table, kanban, calendar) driven by CollectionViews; filter bar with the filter grammar; saved views. | UI `/[domain]/[doctype]` | `doc/frontend/filter-bar.md`, `kanban.md`, `calendar.md` |
| FE-04 | Document show page | Template-driven show page (DVT renderer), sidecar rail (comments, attachments), backlinks panel, artifact images, action buttons. | UI `/[domain]/[doctype]/[id]` | `doc/frontend/sidecar-panel.md`, `backlinks.md`, `doc/frontend/workflow.md` → Document View Template |
| FE-05 | Document form | New/edit forms with per-type widgets (datetime, period, color, money, file…), validation feedback, nested children editing. | UI `/…/new`, `/…/edit` | `doc/frontend/datetime-picker.md`, `period-picker.md`, `markdown-editor.md` |
| FE-06 | History & rollback | Per-document mutation history view with rollback action. | UI `/…/[id]/history` | `doc/frontend/audit.md` |
| FE-07 | Command palette | Top-bar search / Cmd+K: cross-doctype search results and navigation. | UI (global) | `doc/frontend/command-palette.md` |
| FE-08 | Keyboard shortcuts | Global shortcut map (palette, navigation, list actions). | UI (global) | `doc/frontend/shortcuts.md` |
| FE-09 | Notifications UI | Bell with unread badge, panel with list/mark-read/actions, click routes to the source document, download offers for export jobs; preference-gated. | UI (top bar) | `doc/frontend/notifications.md` |
| FE-10 | Builder | Draft-domain authoring workspace: overview, doctype list/editor, grants, editors, check page, live preview of the draft, plus the domain-builder assistant chat. | UI `/Builder/…` | `doc/frontend/configure-editors.md` |
| FE-11 | Configure — Access | Role list/editor (permissions, tags, scopes, members, grants), assignment matrix, account admin (invite, credential actions, temporary password panel). | UI `/Configure/access/*` | `doc/frontend/access-accounts.md`, `access-assignments.md` |
| FE-12 | Configure — Apps | App registry UI: new-app wizard (setup → credentials → permissions → review), per-app overview, deploy page, grants, settings. | UI `/Configure/apps/*` | `doc/frontend/app-configure.md` |
| FE-13 | Configure — Domains | Live-domain pages: overview, doctypes, editors, grants; entry to Builder drafts. | UI `/Configure/domains/*` | `doc/frontend/configure-editors.md` |
| FE-14 | Configure — Platform | Admin pages: system settings form, artifacts explorer, managed indexes table, OIDC provider management. | UI `/Configure/platform/*` | `doc/frontend/platform.md`, `frontend/src/lib/components/features/platform/` |
| FE-15 | Configure — Currencies | Edit the `core.Currency` registry rows (feeds the money registry). | UI `/Configure/currencies` | `doc/backend/util-money.md` |
| FE-16 | Configure — Audit | Global audit log browser. | UI `/Configure/audit` | `doc/frontend/audit.md` |
| FE-17 | Settings | Personal settings: profile/preferences (language, timezone, welcome flag), API keys, personal webhooks, MCP endpoint directory. | UI `/Settings`, `/Settings/api-keys`, `/Settings/webhooks` | `doc/frontend/settings.md` |
| FE-18 | Import/export UI | Dialogs to import CSV/JSON and export lists (incl. current view), with job progress and download. | UI list pages | `doc/backend/import-export.md`, `features/importExport/` |
| FE-19 | Welcome tour | First-run guided tour modal for admins, flag-gated (`core.show_welcome`), dismissal persists. | UI (first login) | `doc/frontend/settings.md` → Welcome tour |
| FE-20 | Internationalization | Inlang/Paraglide message pipeline; `en` today, language preference plumbed. | UI (global) | `frontend/project.inlang/`, `doc/frontend/settings.md` |
| FE-21 | OAuth consent page | Browser consent UI for delegated app authorization (app info, scopes, role election). | UI `/oauth/consent` | `doc/backend/oauth.md` |
| FE-22 | Assistant chat UI | Workspace chat panel: streaming answers, tool-trace chips, cancel, replay, `show_documents` / `navigate` rendering. | UI (global chat) | `doc/frontend/chat.md`, `features/chat/` |
# IAM — Identity and authentication

Pinned to `c2f1427e`. Who the caller is: accounts, login, sessions, MFA, SSO,
keys, lockouts.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| IAM-01 | Password login + sessions | Email/password login issues a session cookie (Redis-backed session, ~15 min JWT); logout tears the session down. | REST `POST /api/iam/login|logout`; UI `/login` | `doc/backend/iam.md`, `src/iam/login.cr` |
| IAM-02 | Refresh rotation + reuse detection | Refresh tokens rotate on use; replay of a rotated token kills the session family. | REST `POST /api/iam/refresh` | `doc/backend/iam.md`, `src/iam/refresh.cr` |
| IAM-03 | MFA (TOTP + backup codes) | Enroll-at-login TOTP setup/verify; challenge step on login; 10 single-use `xxxx-xxxx` backup codes minted at enrollment (digest-only storage); admin disable. Enforcement mode is a system setting. | REST `POST /api/iam/mfa/totp/setup|verify`, `/challenge`, `/mfa/disable`; UI challenge/enroll screens | `doc/backend/iam.md`, `src/iam/mfa.cr`, `totp.cr`, `backup_codes.cr` |
| IAM-04 | Forced password change | Accounts with `must_change_pw` (invite, admin reset) must change the password through a one-shot change token before use. | REST `POST /api/iam/change-password`; UI forced-change screen | `doc/backend/iam.md`, `src/iam/pwd_change_token.cr` |
| IAM-05 | Self-service password reset | Request a reset link by email (default TTL 24 h), confirm with the token; one-shot tokens. | REST `POST /api/iam/password-reset/request|confirm`; UI `/reset-password` | `doc/backend/iam.md`, `src/iam/password_reset.cr` |
| IAM-06 | Invites & temporary passwords | Admin invites an account by email (invite email) or generates a temporary password; both force a change on first login. | REST `POST /api/iam/accounts/:id/invite|temporary-password`; UI `/Configure/access/accounts` | `doc/backend/iam.md`, `src/iam/invite.cr` |
| IAM-07 | Account lifecycle | Statuses `pending` / `active` / `suspended` / `deleted`; suspend blocks login; delete/restore via document actions; credential-state probe for the admin UI. | REST document writes on `iam.Account` + `GET /api/iam/accounts/credential-states`; UI account pages | `doc/backend/iam.md`, `doc/frontend/access-accounts.md` |
| IAM-08 | Inbound OIDC SSO | Multiple external OIDC providers (`iam.OIDCProvider`): discovery + JWKS cache, one-shot flow state, id_token verify (RS256/ES256), identity linking, JIT provisioning; auth mode `hybrid` / `oidc_only`. | REST `GET /auth/oidc/:provider(+/callback)`, `GET /api/iam/oidc/providers`; UI SSO buttons on `/login` | `doc/backend/oidc.md`, `src/iam/oidc/` |
| IAM-09 | Static API keys | `fct_` bearer keys for machine access, issued per account, listed and revoked; attributed audit rows (`channel: api_key`). | REST `GET/POST /api/iam/keys`, `DELETE /api/iam/keys/:key_id`; UI `/Settings/api-keys` | `doc/backend/iam.md`, `src/iam/api_key.cr` |
| IAM-10 | Login throttle & lockout | Per-account attempt counters and lockout flag in Redis; failed attempts bounded, message shows remaining tries. | automatic on login/challenge | `doc/backend/iam.md`, `src/iam/login_throttle.cr` |
| IAM-11 | Session management | Caller lists their active sessions (and app sessions) and revokes one or all. | REST `GET /api/iam/sessions|apps`, `DELETE /api/iam/sessions/:id|/api/iam/apps/:app_id/sessions`; UI `/Settings` | `doc/backend/iam.md`, `src/iam/redis_session.cr` |
| IAM-12 | Bootstrap CLI | First-admin bootstrap with generated one-time password (`seed:admin`), dev admin (`seed:dev`), auth-mode pin (`auth:mode`), account/role inspection (`accounts:list`, `roles:list`, `roles:add`). | CLI `facet seed:admin|seed:dev|auth:mode|accounts:list|roles:list|roles:add` | `doc/backend/cli.md`, `src/iam/*_cli.cr` |
| IAM-13 | Login event log | Every login/logout/challenge outcome recorded as `iam.LoginEvent` rows (audit trail of access). | automatic; readable as documents | `doc/backend/iam.md`, `src/iam/helpers.cr` |
| IAM-14 | Caller identity endpoint | `GET /api/iam/me` returns the caller's account, elected role, and the permission manifest the frontend uses to gate navigation and buttons. | REST; UI boot | `doc/backend/iam.md`, `src/iam/routes.cr` |
# PLT — Platform, operations, observability

Pinned to `c2f1427e`. The operator layer: configuration, storage, background
infrastructure, diagnostics.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| PLT-01 | YAML config | Single source of truth per environment (`config.{env}.yml`), per-section loaders; secrets via env only. | file; `src/config.cr` | `doc/backend/config.md` |
| PLT-02 | System settings (`core.SystemSettings`) | Runtime platform configuration as a singleton document: registry of spec entries (mail, assistant, IAM auth mode/MFA, localization, retention, artifact TTLs…), write-time semantic gate, invalidate-only cache, admin UI form. | REST `GET /api/SystemSettings`; UI `/Configure/platform/settings` | `doc/backend/system-settings.md`, `src/system_settings/` |
| PLT-03 | Secret store | Out-of-band secret storage: hashed / sealed / token payloads, stage-handle flow (`POST /api/secrets/stage`), master key + bcrypt knobs, cron prune of expired rows. | REST staging route; `secret` field type | `doc/backend/secrets.md`, `src/secrets/` |
| PLT-04 | Artifact store | File uploads for `file` fields (multipart or signed one-time upload grants), filesystem or S3 backends, MIME sniffing + accept lists, signed capability URLs (mint, permanent publish via the `publish_artifact` action, verify, revoke), provenance-based read check, operator listing, prune/reconcile/revoke CLIs, purge audit (`iam.ArtifactEvent`). | REST `/api/core/artifacts*`, `/a/:gid` serving, `/api/Artifacts*`; UI artifacts explorer | `doc/backend/artifact.md`, `src/artifact/` |
| PLT-05 | Managed indexes | Index planner derives desired PG indexes per doctype field set; background DDL with advisory-lock gate; status listing and retry CLI. | REST `GET /api/Indexes`; CLI `facet index:retry`; UI `/Configure/platform/indexes` | `doc/backend/index-management.md`, `src/index/` |
| PLT-06 | Health probes | `/Healthcheck` readiness (all DB pools, Redis PING, consumer health, `event_loss`, `event_lag`) and `/Healthcheck/live` liveness. | REST (public) | `doc/backend/http-layer.md`, `src/http/healthcheck.cr` |
| PLT-07 | Metrics | In-process registry + Prometheus text endpoint; request counters per route. | REST `GET /metrics` | `doc/backend/metrics.md`, `src/metrics.cr` |
| PLT-08 | OpenTelemetry tracing | OTLP exporter, HTTP server middleware, DB query instrumentation. | config; exported traces | `doc/backend/telemetry.md`, `src/telemetry/` |
| PLT-09 | Structured logging | Config-driven JSON or text logs. | config | `doc/backend/logging.md`, `src/logging.cr` |
| PLT-10 | Database topology | Central pools with a route table, read/write pinning (fiber-local), transaction helpers, cluster grammar in config. | config | `doc/backend/config.md`, `src/database/` |
| PLT-11 | Migrations | SQL migrations with `-- UP` / `-- DOWN`, tracked runner, revert CLI (validated plan, `--yes` gate), `db_reset` for dev/test. | CLI `facet migrate|migrate:down|db_reset` | `doc/backend/migrations.md`, `src/migrate.cr` |
| PLT-12 | OpenAPI (v1) | Committed `doc/api/openapi.json` + generator over document CRUD / audit / IAM subset; CI drift job regenerates and diffs. | REST spec; CI | `doc/backend/openapi.md`, `src/http/openapi.cr` |
| PLT-13 | HTTP admission gates | Body-shape gate (JSON object or 422), `QUERY` method gate, CSRF / `X-Requested-With` gate on state-changing calls, param validation, token gate ordering. | all REST routes | `doc/backend/http-layer.md`, `src/http/gates.cr` |
| PLT-14 | Currency registry + money math | `core.Currency` rows hydrate an in-process registry; money values are exact decimals; sums are per-currency bags. | automatic; `money` field/aggregate | `doc/backend/util-money.md`, `src/currency/` |
| PLT-15 | Graceful shutdown | Signal traps, request drain, ordered teardown of fibers/managers. | process signal | `doc/backend/shutdown.md`, `src/shutdown.cr` |
| PLT-16 | Container images | Multi-stage backend image, frontend preview image, Caddy TLS edge; documented container deployment. | Docker | `doc/ops/container-images.md`, `doc/ops/first-deployment.md`, `docker/`, `caddy/` |
| PLT-17 | Account settings store | Per-account, per-application preference rows (`account_settings` table): keyed by app scope (`core` default), values validated against a key registry, self-service only (the caller touches only their own rows — no RBAC enforcer by design). Not event-sourced: a preference change is not an auditable business event (the deliberate contrast with PLT-02). `GET /api/iam/me` embeds the `core` scope. | REST `GET /api/settings[/:app[/:key]]`, `PUT`/`DELETE /api/settings/:app/:key`; UI `/Settings` | `doc/backend/settings.md`, `src/settings/` |
# RBC — Authorization and governance

Pinned to `c2f1427e`. Who may do what: roles, grants, field/row granularity,
enforcement. This is the substrate-side governance the product promises a
vibe-coded app cannot escape.

| ID | Feature | What it does | Surface / entry point | Docs / source |
|---|---|---|---|---|
| RBC-01 | Roles (`iam.Roles`) | Role documents carry permission lines (`domain.Doctype.action` or wildcards with `except` carve-outs) and a level 0–100; authoring-time validator refuses out-of-authority lines. | REST documents on `iam.Roles`; UI `/Configure/access/roles` | `doc/backend/rbac.md`, `src/rbac/` |
| RBC-02 | Role assignment & election | Accounts hold one or more roles; the caller elects a role at login (and at OAuth consent); role usable checks gate every request. | REST login/consent `role_id`; UI `/Configure/access/assignments`, role members tab | `doc/backend/rbac.md`, `src/rbac/active_role.cr` |
| RBC-03 | Read enforcement | Every read (single, list, aggregate, search, backrefs, audit) passes the ReadEnforcer; out-of-grant reads answer non-disclosing (empty set / 404), never a leaky error. | automatic, all read routes | `doc/backend/rbac.md`, `src/rbac/read_enforcer.cr` |
| RBC-04 | Field visibility (tags) | Fields carry tags; roles grant or except tags; masked fields are hidden in reads, write responses, audit history, and refused on write (B-69/70/71/72 guard set). | automatic; role editor tag pickers | `doc/backend/rbac.md`, `src/rbac/` + `Audit::Redact` |
| RBC-05 | Row scopes | Permission lines attach where-clauses; `$self` / `$mine` aliases resolve to the caller; doctype named scopes reusable as row scopes; context sets bundle them per domain. | role authoring; list reads scoped automatically | `doc/backend/rbac.md`, `src/rbac/scope_*.cr` |
| RBC-06 | Write enforcement | Create/update/delete/action authorized per doctype+action, including field-write authorization (writes into invisible fields refused, explicit nulls included) and child-create guards. | automatic, all write routes | `doc/backend/rbac.md`, `src/rbac/write_enforcer.cr` |
| RBC-07 | Role authority guard | Caller-controlled writes to `iam.Account`/`iam.Roles` pass a transition guard: no self-escalation above caller level, no god-role mint, target protection for admin rows, level required on every role. | automatic on those doctypes | `doc/backend/rbac.md`, `src/rbac/` (`RoleAuthority`) |
| RBC-08 | App grants | Each `app.App` carries a grant set; effective reach = grant ∩ pinned service role (key channel) or ∩ elected role (delegated user); grant ceiling enforced on every app request. | REST app config; UI `/Configure/apps/…/grants` | `doc/backend/app-system.md`, `src/rbac/app_scope.cr`, `grant_resolver.cr` |
| RBC-09 | Metadata gate | A caller is served `core.DocType` / `core.Domain` rows only for doctypes it holds a grant on (non-disclosing otherwise); fixes the "scoped role can't render its own pages" class. | REST `GET /api/core/DocType|Domain` | `doc/backend/rbac.md`, `src/rbac/metadata_gate.cr` |
| RBC-10 | Auth contexts (all channels) | One authorization context model over: session JWT (browser), app OAuth tokens (PKCE + DPoP, delegated user), app API keys (service account), MCP bearer, Lua system-tier. Principals and channel attribution are uniform. | all surfaces | `doc/backend/rbac.md`, `src/rbac/auth_context.cr`, `src/http/auth_handler.cr` |
| RBC-11 | Permission manifest | `GET /api/iam/me` emits the caller's action manifest (exact keys, wildcard scopes, per-action `*.*.except.<action>` keys) that the SPA uses for sidebar, dashboard and button gating. | REST; UI nav/buttons | `doc/frontend/workflow.md`, `frontend/src/lib/components/features/admin/rbacModel.ts` |
# Facet feature inventory

Catalog of every feature the Facet application provides, as the base map for the
pre-release QA review. One file per functional area. Each feature has a stable
ID (`AREA-NN`) that QA reports, scenarios and journal entries can cite.

**Pinned to:** `envelope` @ `c2f1427e` (`features/road-to-beta`, 2026-11-03).
Re-derive this folder when the platform moves; record the commit at the top of
each area file if it changes.

## How this was derived

Source-led sweep of the platform (not a persona run — the cold-start rule does
not apply to this inventory):

- `envelope/doc/project-structure.md` — architecture map and per-concern docs.
- HTTP route enumeration — every `get|post|patch|put|delete` handler in `src/` (120 routes, incl. the `/ws` socket).
- Backend CLI registry — `src/cli/commands.cr` (18 commands).
- Agent tool registry — `src/agent_tools/` (23 tools + `read_skill`).
- Frontend route tree — `frontend/src/routes/` (54 pages).
- Developer packages — `packages/cli`, `packages/sdk`, `packages/chat`.

## Areas

| File | Area | Prefix | Features |
|---|---|---|---|
| [domains-doctypes.md](domains-doctypes.md) | Domains, doctypes, schema authoring | `DOM` | 25 |
| [documents.md](documents.md) | Document data plane | `DOC` | 13 |
| [iam.md](iam.md) | Identity and authentication | `IAM` | 14 |
| [rbac.md](rbac.md) | Authorization and governance | `RBC` | 11 |
| [audit.md](audit.md) | Mutation log, audit, rollback | `AUD` | 8 |
| [apps.md](apps.md) | Registered apps, OAuth, hosting, SDKs | `APP` | 11 |
| [automation.md](automation.md) | Events, hooks, webhooks, jobs, notifications, mail | `AUT` | 8 |
| [ai.md](ai.md) | Assistants, agent tools, MCP | `AI` | 9 |
| [frontend.md](frontend.md) | Workspace SPA surfaces | `FE` | 22 |
| [platform.md](platform.md) | Ops, config, artifacts, observability | `PLT` | 17 |

Total: **138 features**.

## How to use in QA

- Every feature row lists its surface (REST / UI / CLI / MCP / agent) and its
  doc or source pointer. A scenario picks features by ID; a finding cites the
  ID it broke.
- This is an inventory of what **exists**, not what **works**. Known defects
  live in [`../findings/INDEX.md`](../findings/INDEX.md); verdicts on Q1/Q2 in
  [`../answers/`](../answers/).
- Coverage rule of thumb: every feature needs at least one constructive probe
  and, for governance-bearing ones, one adversarial probe (see
  [`../goal/questions.md`](../goal/questions.md)).

## Conventions

- ASD-STE100-style plain wording, consistent with `envelope/AGENTS.md`.
- "Surface" column: `REST` = HTTP API, `UI` = workspace SPA, `CLI` = backend
  `facet` binary, `dev-CLI` = `@facetapp/cli`, `MCP` / `agent` = tool surfaces.
- Paths are relative to `envelope/` unless written absolute.
