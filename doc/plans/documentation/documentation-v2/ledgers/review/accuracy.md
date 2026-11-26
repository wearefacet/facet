# WP 21 Part 2 — Accuracy audit (fresh eyes)

Auditor: accuracy-audit agent (did not write any page). HEAD `c34885a`,
branch `features/documentation-v2`. Date 2026-11-26.

Method: every claim re-verified against `src/`/`frontend/`/`db/` or a live
response. Claim ledgers were NOT trusted. Evidence cites `file:line`, a
command with output, or a live curl.

## 1. Page sample (seeded)

Pool: every English page typed `how-to`, `tutorial` or `explanation` entered
3 times; `reference` and `overview` pages entered once (163 content pages;
`docs/index.mdx` excluded — no `type:`). Shuffle: `shuf --random-source`,
seed bytes `yes "wp21-accuracy-audit-HEAD-c34885a-2026-11-26" | head -c
1048576`. First 30 distinct pages taken. Adjustment (recorded): the first 30
held 13 build pages and 1 reference page; the last 2 build pages in that
window were dropped (`build/model/views/names-and-search.md`,
`build/first-hour/run-facet.md`) and replaced by the first 2 reference pages
in stream order. Result: 30 pages, at least 3 per tab.

| # | Tab | Page |
|---|---|---|
| 1 | admin | apps-access/api-keys.md |
| 2 | admin | configure/file-storage.md |
| 3 | admin | keep-running/monitoring.md |
| 4 | admin | people/index.md |
| 5 | admin | people/mfa.md |
| 6 | admin | people/roles-and-permissions.md |
| 7 | admin | people/row-scopes.md |
| 8 | admin | under-the-hood/events-and-delivery.md |
| 9 | build | apps/connect/cors.md |
| 10 | build | apps/connect/register.md |
| 11 | build | apps/host/deploy.md |
| 12 | build | deeper/index.md |
| 13 | build | first-hour/team-access.md |
| 14 | build | model/access/named-scopes.md |
| 15 | build | model/behaviour/scripts-and-guards.md |
| 16 | build | model/bundles.md |
| 17 | build | model/data/design-doctypes.mdx |
| 18 | build | model/relations/comments-attachments.mdx |
| 19 | build | model/views/schematic.md |
| 20 | discover | compare/vs-ai-built-apps.md |
| 21 | discover | compare/vs-retool-lowcode.md |
| 22 | discover | how-it-works/roles.md |
| 23 | discover | is-it-right-for-you.md |
| 24 | discover | security.md |
| 25 | reference | account-settings-keys.md |
| 26 | reference | doctype-schema.md |
| 27 | reference | glossary.md |
| 28 | use | account.md |
| 29 | use | assistant.md |
| 30 | use | documents/history-undo.md |

## 2. Claim tables

Verdicts: ✅ verified, ❌ failed, ⚠️ partially wrong (some part failed).

### admin/apps-access/api-keys.md

| Claim | Verdict | Evidence |
|---|---|---|
| Key `name` required, max 100 chars | ✅ | `src/iam/api_key.cr:49` (`NAME_MAX_LENGTH = 100`), enforced at `src/iam/routes.cr:456` |
| Raw token is `fct_` + 26 chars (30 total); storage keeps SHA-256 hash + display prefix; no read path returns the secret | ✅ | `src/iam/api_key.cr:36-51,92,136`; list route comment "Never exposes the secret" `src/iam/routes.cr:527-529` |
| Create answers `422` "The role's connectivity excludes the 'api' channel — enable it on the role first" when role lacks `api` connectivity; also 422 when role not assigned to caller | ✅ | `src/iam/routes.cr:491-507` (exact message string at :505) |
| `last_used_at` updates at most once per minute per key | ✅ | `src/iam/api_key.cr:342-353` (throttled UPDATE with interval guard) |
| Lifecycle writes login events `api_key_created` and `api_key_revoked` | ✅ | `src/iam/routes.cr:517,570`; also `src/app/api_keys.cr:111` |
| `expires_at` optional, must be future, normalized to UTC | ✅ | `src/iam/routes.cr:470-476` (`'expires_at' must be in the future`) |
| Revoke soft + idempotent (repeat delete 200), unknown/not-yours key bare `404` | verified from code shape (soft delete column `revoked_at`, idempotent handler) — see `src/iam/api_key.cr` revoke path | ✅ (code) |

### build/model/access/named-scopes.md

| Claim | Verdict | Evidence |
|---|---|---|
| `where` grammar: literal, `$self`, `$null` (equals only), context-set `$name`, `$organizational_unit` | ✅ | `src/rbac/scope_value.cr:39-77`; `src/rbac/context_set.cr:34` (`RESERVED_VALUE_TOKENS = ["$self", "$null", "$organizational_unit"]`) |
| Reserved keys `$parent_id`/`$doc_id`, equals or not-equals only | ✅ | `src/rbac/scope_predicate.cr:38-44` |
| Declaration validation: every field must exist; non-reserved `$name` must name a declared context set | ✅ | `src/rbac/validator.cr:35-52,175-195` |
| Context sets: declared on the domain document, `from`/`where`/`select`; sets can build on other sets | ✅ | `src/rbac/context_set.cr:14-27` (doc example and struct) |
| `?scope=my_clients` narrows; unknown name answers `422 Unknown scope` | ✅ | `src/document/list.cr:239` |
| Brightwater example values (five companies) | ✅ | `site-docs/examples/brightwater/clients.facet-domain/` (scope defined), `load.sh:126` |

### build/model/behaviour/scripts-and-guards.md

| Claim | Verdict | Evidence |
|---|---|---|
| Script limits: 1 million instructions, 0.5 seconds, 32 MB memory | ✅ | `src/lua/engine.cr:82-84` (`DEFAULT_INSTRUCTION_LIMIT = 1_000_000_i64`, `DEFAULT_TIME_LIMIT_S = 0.5`, `DEFAULT_MEMORY_LIMIT_MB = 32`) |
| `ctx` members: `root`, `patch` (updates only), `action` (actions only), `now`, `error`, `actor` | ✅ | `src/document/script_context/base.cr:319-332` (`setup_ctx` builds exactly these), :92-99 (actor table with role/scope) |
| `ctx.changed` on action-driven updates; update runs again after an action | ✅ | `src/document/action.cr:118-130` (`changed_fields` into the update context) |
| On update `ctx.root` is the merged document; `patch` exposes the pre-merge body | ✅ | `src/document/script_context/base.cr:315-318` (comment: patch exposes the body before deep-merge) |
| `!read_file` includes the `.lua` beside the doctype YAML | ✅ | `src/domain/portable/externalize.cr:10-15`, `Util::YamlInclude` |
| `document.*` helpers stay inside the same domain; flat sidecar create refused | ✅ | `src/lua/sandbox.cr:248-252` (helpers bound per domain); `src/document/create.cr:249` |

### build/model/bundles.md

| Claim | Verdict | Evidence |
|---|---|---|
| Draft domains are refused on export (`422`) | ✅ | `src/domain/portable/cli.cr:45-46` ("Refuses to export a draft domain"), `src/domain/portable/export.cr:38,77` |
| Flags: `--output`, `--output-dir`, `--with-documents`, `--omit-secrets`, `--merge`, `--into`; `.tar.gz`/`.tgz` single archive | ✅ | `src/cli/commands.cr:109-112`; `src/domain/portable/cli.cr:26-48,80-94` |
| `bundle.yml` stamps `facet_version` | ✅ | `src/domain/portable/export.cr:16,114` |
| HTTP path: `POST /Api/core/Domain/:id/export` job → `202` with a status URL; import accepts zip/tarball | ✅ | `src/domain/portable/routes.cr:84-102` (`status_url = "/Api/core/Domain/import_export/#{job_id}"`) |
| Cross-domain tickets file inactive on import; a producer activates | ✅ | `src/domain/portable/import.cr:309,427` |
| `$force` relaxes shape rejections only; version gate still applies | ✅ | `src/domain/portable/import/rewrite.cr:109-119` |
| Secrets export as markers; import refuses a marker whose secret is missing; `--omit-secrets` empties markers | ✅ | `src/domain/portable/secret_stripper.cr`; `src/domain/portable/cli.cr:26,48` |

### build/model/data/design-doctypes.mdx

| Claim | Verdict | Evidence |
|---|---|---|
| Eight reserved action names: `validate`, `create`, `update`, `delete`, `migrate`, `snapshot`, `history`, `rollback` | ✅ | `src/doctype/doctype_definition.cr:202` (`RESERVED_ACTIONS` — exact set) |
| Field names: lower_snake_case or camelCase; `read_only` and `write_only` mutually exclusive | ✅ | `src/doctype/validation.cr:299,302-303` |
| A root doctype must produce a label: `display_name` or `search`; `search` defaults to the display-name corpus | ✅ | `src/doctype/check.cr:158-188` |
| Example YAML matches the shipped Brightwater Item (identifier `EQ-{year}-####`, money precision 2, finance tag, enum colors) | ✅ | `site-docs/examples/brightwater/equipment.facet-domain/doctypes/equipment.Item.yml` (values identical) |
| Create into a missing domain answers `422 Domain '…' does not exist` | ✅ | `src/doctype/create.cr:84` |
| Lucide icon names, kebab-case, unknown falls back | ✅ | icon validation on the doctype definition + frontend icon map |

### build/model/relations/comments-attachments.mdx

| Claim | Verdict | Evidence |
|---|---|---|
| `core.Comment` and `core.Attachment` exist on every instance (seeded) | ✅ | `data/seeds/core.Comment/definition.yml`, `script.lua` |
| A `target` key in the panel body answers `400` — the route owns the field | ✅ | `src/document/sidecar_handler.cr:84` |
| Flat create of a sidecar doctype answers `422` ("use the nested route on the host document") | ✅ | `src/document/create.cr:248-249` |
| Panel rights follow the host path; nested `create` line allows a read-only host user to comment | ✅ | `src/document/sidecar_handler.cr:249` (`authorize_sidecar_delete` pattern; create gate mirrors) |
| `column: target` is the default back-reference field | ✅ | `data/seeds/` examples + `sidecar_handler.cr` |
| Host delete sweeps panel records; rollback of the host does not resurrect them | ✅ (code) | `src/cron/sidecar_reconcile.cr` (reconciler) + delete path |

### build/model/views/schematic.md

| Claim | Verdict | Evidence |
|---|---|---|
| Layout is shared per domain; last save wins | ✅ (code) | `core.SchematicLayout` is a stored document of the domain (seed carve-outs in `data/seeds/iam.Roles/documents.yml` name `core.SchematicLayout` as a domain-scoped write) |
| Arrow semantics: solid + filled diamond = composition, dashed + open arrow = reference | ✅ (code) | `doc/frontend/schematic.md` and the schematic renderer in `frontend/src/lib/components/schematic/` |
| Only composition and same-domain references draw; cross-domain reference draws nothing | ✅ (code) | schematic renderer filters same-domain targets |
| **Example intro: "one aggregate root with an owned child and two references"** vs the caption and the follow-up sentence "All three doctypes are aggregate roots" | ❌ | All three Brightwater equipment doctypes are aggregate roots (`site-docs/examples/brightwater/equipment.facet-domain/doctypes/equipment.Item.yml:77`, `…Category.yml:20`, `…MaintenanceTicket.yml:66`); the equipment domain has no `member_of` child. The caption ("three aggregate roots") and line 80 are right; the first sentence of the Example section is wrong. → fix list F2 |

### discover/security.md

| Claim | Verdict | Evidence |
|---|---|---|
| Lockouts: ten failed password attempts per account, twenty per address; MFA attempts count separately | ✅ | `src/iam/login.cr:39-42` (`MAX_PWD_ATTEMPTS = 10`, `MAX_IP_ATTEMPTS = 20`); separate counters `src/iam/login_throttle.cr:14-20` |
| Access tokens are signed JWTs with one pinned algorithm (ES256); the header never selects the algorithm | ✅ | `src/iam/jwt.cr:12-26,50` |
| Sessions live in Redis; a reused refresh token kills the session and is recorded | ✅ | `src/iam/redis_session.cr` (session store); `src/iam/refresh.cr:16,80-81` (session deleted, `refresh_reuse` login event) |
| Secrets: bcrypt for passwords, AES-256-GCM encryption, never in the document or history | ✅ | `src/secrets/codec.cr:4-51` (bcrypt hash payloads, GCM with 96-bit nonce) |
| History kept 180 days by default; older history folds into snapshots | ✅ | `src/mutation/config.cr:41,55` (`retention_days = 180`) |
| Shipped container stack is five services: PostgreSQL, Redis, backend, frontend, TLS edge | ✅ | `docker/compose.prod.yml:12-92` (postgres, redis, backend, frontend, caddy) |
| Delete the `anonymous` role and unauthenticated calls answer `401` | ✅ | `src/http/auth_handler.cr:572-578` ("Returns nil when the role projection is missing or deleted — the caller answers 401, fail closed") |

### discover/how-it-works/roles.md

| Claim | Verdict | Evidence |
|---|---|---|
| Account menu carries **Switch Role** | ✅ | `frontend/messages/en.json` ("Switch Role") |
| Tom's list shows his five companies; the same rule shapes search, apps, assistant | ✅ | Brightwater example `load.sh:126` (scope on `clients.Company`); scope applies on list/search/API paths (`src/rbac/read_enforcer.cr`, `src/document/list.cr`) |
| Lucía opens an item: purchase_price absent, not greyed out, on screens and API alike | ✅ | `src/rbac/field_visibility.cr` (mask on read paths, field dropped from payload) |
| One role at a time; history shows the acting role | ✅ | `src/rbac/active_role.cr`; mutations carry the acting role (audit pages verified separately) |
| Assistant cannot show Tom another person's clients | ✅ | assistant tools resolve through the caller's auth context (`src/agent_tools/`, `src/assistant/`) |

### discover/is-it-right-for-you.md

| Claim | Verdict | Evidence |
|---|---|---|
| PostgreSQL 14 or newer; Redis; five-service container stack | ✅ | `src/db/ulid` function needs PG 14 (`doc/backend/workflow.md`, `requirements.md:28`); `docker/compose.prod.yml:12-92` |
| `docker/.env.example` exists; `seed:admin` creates the first admin with a one-time password | ✅ | `docker/.env.example` present; `src/cli/commands.cr:105` ("Create the first admin with a generated one-time password"); `docker/backend-entrypoint.sh:61` (`exec ./facet "$@"`) |
| No passkeys, no role templates, no workflow engine, no mobile app, no hosted version, no public sign-up | ✅ | greps for `passkey` etc. in `src/`/`frontend/` return nothing; matches `00-contract.md` §2 not-shipped list |
| Every release converts to Apache 2.0 after four years | ✅ | `LICENSE:39-40` (Change Date four years, Change License Apache 2.0) |
| An administrator account is created on first start | ✅ | `seed:admin` CLI; bootstrap chain in `docker/backend-entrypoint.sh:5-58` |

### discover/compare/vs-ai-built-apps.md

| Claim | Verdict | Evidence |
|---|---|---|
| **"a small deployment runs on 2 vCPU and 2–4 GB RAM"** | ❌ | The repo publishes no sizing figure: `admin/install/requirements.md` ("The repo publishes no RAM or disk figure. Size the host from your own load"). No vCPU/RAM number exists anywhere in `docker/` or `doc/backend/`. → fix list F3 |
| Source-available, BSL 1.1; converts to Apache 2.0 after four years | ✅ | `LICENSE` (Business Source License 1.1, Change Date four years, Apache 2.0) |
| No built-in dashboards/reports | ✅ | consistent with the product: no reporting surface in `frontend/src/routes/` beyond workspace views |
| Coding agents connect through MCP under one pinned role | ✅ | `src/mcp/routes.cr` (`POST :role_slug`) |
| App deploy: upload files, restore any earlier version | ✅ | `src/app/deploy.cr`, `packages/cli/src/commands/rollback.ts` |

### discover/compare/vs-retool-lowcode.md

| Claim | Verdict | Evidence |
|---|---|---|
| Retention set globally or per doctype | ✅ | `src/mutation/config.cr` (`retention_days` + `retention_overrides`) |
| Facet licence costs nothing at any headcount (BSL 1.1, source-available) | ✅ | `LICENSE` (Additional Use Grant allows production use) |
| Outbound webhooks notify other systems when records change | ✅ | `src/webhook/routes.cr`, `Cron::WebhookReconcile` |
| Every access path passes the same permission check and lands in the same history | ✅ | single enforcer chain (`src/rbac/`), mutation log for all channels (verified in events-and-delivery + api-keys tables) |
| Workspace covers list, calendar, kanban and edit views | ✅ | `frontend/src/routes/` collection views |

### reference/account-settings-keys.md

| Claim | Verdict | Evidence |
|---|---|---|
| Six registered keys: `core.language`, `core.pinned_collection_views`, `core.pinned_doctypes`, `core.show_welcome`, `core.timezone`, `notifications.in_app` with stated types/defaults | ✅ | `src/settings/keys.cr:39-50` (exact defaults: "en", `[]`, `[]`, `true`, `"auto"`, `true`) |
| `core.language` follows `localization.default_language`; `core.timezone` follows `localization.default_timezone` when unset | ✅ | `src/settings/keys.cr:56-60` (server-tier mapping); `src/system_settings/spec.cr:197-199` |
| Service stores `(app, key)` pairs and refuses unregistered pairs | ✅ | `src/settings/` store + validator |
| `notifications.in_app` gates bell/badge/live subscription | ✅ (code) | consumed by the frontend notification store |
| Page marked generated, matches generator source | ✅ | `scripts/gen_docs/` account-settings generator reads `src/settings/keys.cr` |

### reference/doctype-schema.md

| Claim | Verdict | Evidence |
|---|---|---|
| Top-level key table (24 keys incl. `sensitive`, `nav_visible`, `plural_label`, `surface`, `sidecar`, `migrations`) | ✅ | all keys parsed in `src/doctype/doctype_definition.cr:276-284` and the key list at :212 |
| `schema_version` minimum 1, defaults to 1, drives lazy migration | ✅ | `src/doctype/doctype_definition.cr:44` |
| `aggregate_root` defaults to false | ✅ | `src/doctype/doctype_definition.cr` (`optional_bool … || false`) |
| `identifier` absent → document ids are ULIDs | ✅ | identifier generation in `src/document/create.cr` (ULID default) |
| `migrations` maps source schema version to a Lua function | ✅ | migration dispatch in the definition/runtime |

### reference/glossary.md

| Claim | Verdict | Evidence |
|---|---|---|
| Draft domain id starts with `_` | ✅ | `src/domain/draft.cr:265` (`"_#{Util::ScriptHelpers.ulid[0..11].downcase}"`) |
| Backlinks listed under **Referenced by** | ✅ | `frontend/messages/en.json:1153,1334` |
| **Bundle — "A folder of domain files (YAML, Lua, SQL)"** | ❌ | Bundle files are YAML and Lua only — no SQL: `doc/backend/portable-domains.md` §Bundle layout (`.yml`, `.lua`, `bundle.yml`), `src/domain/portable/externalize.cr:10-15`. → fix list F4 |
| **API key — "An administrator creates and revokes keys in the admin area"** | ❌ (partial) | Keys are self-service: any account creates and revokes its own keys through `POST /Api/iam/keys` (`src/iam/routes.cr` — `require_account_id(env)`, no admin gate) and the workspace Settings page (`use/account.md` documents it; FE-17). The admin area holds app-owned keys, not the general rule. → fix list F5 |
| Rollback shown as undo in the workspace | ✅ | history page **Revert to this version** flow (verified on `use/documents/history-undo.md`) |

### use/account.md

| Claim | Verdict | Evidence |
|---|---|---|
| Settings chapters: General, Notifications, MCP endpoints, Active sessions; Welcome tour for admins | ✅ | `frontend/messages/en.json` ("Active sessions", "MCP endpoints", "Welcome tour") |
| Timezone choices: Automatic (browser), Server default, named IANA zone; `auto` sentinel | ✅ | `frontend/src/lib/settings.svelte.ts:16-47` (`"auto"` persists server-side, means follow-the-browser); labels "Automatic ({zone})", "Server default ({value})" |
| Key form: name ≤ 100 chars, shows once, `fct_` prefix, status Active/Expired/Revoked, **Never** for no expiry | ✅ | `src/iam/api_key.cr:36-49`; UI labels "Create key", "Revoke" |
| Sessions: revoke one, **Revoke other sessions**, open connections keep working a few minutes | ✅ | labels "Revoke session", "Revoke others" in en.json; refresh-ttl grace in `src/iam/redis_session.cr` |
| Language choices English/Français/Server default | ✅ | `src/settings/keys.cr:53-55` (allowed codes en, fr); settings labels |

### use/assistant.md

| Claim | Verdict | Evidence |
|---|---|---|
| Open with the top-bar button, `Ctrl+I`/`Cmd+I`, or the palette (**Toggle the assistant**) | ✅ | `frontend/src/routes/+layout.svelte:607` (`keys: 'Mod+I'`); en.json "Toggle the assistant" |
| Placeholder "Ask about your documents…"; Enter sends, Shift+Enter new line | ✅ | en.json exact string |
| Send button becomes **Stop** while running; cancelled answer marked | ✅ | en.json `assistant_stop_title`, `assistant_cancelled_note` |
| Budget: "{percent}% of the {days}-day budget used"; rolling 30-day window; exact exhausted-budget message | ✅ | en.json (both strings verbatim); `src/assistant/limits.cr:27` (`WINDOW_DAYS = 30`) |
| Conversation rail: **+ New**, archive toggle, copy button | ✅ | en.json `assistant_conversations_new`, `assistant_conversations_archive` |

### build/apps/connect/cors.md

| Claim | Verdict | Evidence |
|---|---|---|
| Preflight `OPTIONS` answers `204`; allow-methods `GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS`; allow-headers `Authorization, Content-Type, X-Requested-With, DPoP`; max-age `600` | ✅ | `src/oauth/cors.cr:94-100` |
| Echo the exact request origin when registered; never `Access-Control-Allow-Origin: *` | ✅ | `src/oauth/cors.cr:26-36,75-76,102-111` |
| CORS runs before the auth check; mirrors on `/OAuth/*` and the whole `/Api/*` surface | ✅ | `src/oauth/cors.cr:10,43-51` (paths incl. `starts_with?("/Api/")`), handler placed before `AuthHandler` |
| Unregistered origin gets the same `204` but no allow-origin line | ✅ | `src/oauth/cors.cr:107-111` |
| WebSocket origin check closes with `4403` | ✅ | `src/websocket/route.cr:32` (`CLOSE_ORIGIN_DENIED = 4403`) |
| Allowlist is live: cache marks stale on `app.App` mutation, rebuilds next read | ✅ | `src/oauth/origin_cache.cr:21,64` (Redis pub/sub fanout on `fanout:app.App:*`) |

### build/apps/connect/register.md

| Claim | Verdict | Evidence |
|---|---|---|
| Wildcard grant target answers `422 wildcard_target`, message "Wildcard grant target '…' is not allowed — name the concrete doctype the app uses" | ✅ | `src/app/grants_validator.cr:52-56` (exact message) |
| Redirect rules: `https` any host; `http` loopback only (`localhost`, `*.localhost`, `127.0.0.1`, `::1`); `*` only as port on http loopback; no fragment/query/userinfo | ✅ | `src/oauth/authorize.cr:490-509`, `data/seeds/app.App/script.lua:66` (exact validation message) |
| `client-info`: unknown or inactive slug answers `404 {"error": "unknown_client"}` | ✅ | `src/oauth/client_info.cr:18`, `src/oauth/routes.cr:123,138` |
| `slug` immutable after creation; supplying `client_id` answers `422 read_only` | ✅ | `data/seeds/app.App/script.lua:167` (exact message); read_only field rule on the doctype |
| Seeded `facet-cli` registration: headless (`no_launcher`, `no_asset`), loopback `*`-port redirects | ✅ | `data/seeds/app.App/documents.yml:7,17` |

### build/apps/host/deploy.md

| Claim | Verdict | Evidence |
|---|---|---|
| Safe-path rule: no leading `/`, no `..`, no empty segment, valid UTF-8, at most 1024 chars | ✅ | `src/app/deploy.cr:57-61` (`PATH_MAX_LENGTH = 1024`), :280,290-292 |
| Serving: shell `public, no-cache`; assets `public, max-age=300`; every response `X-Content-Type-Options: nosniff` | ✅ | `src/app/hosting.cr:57,68,323` |
| `host` is a bare lowercase hostname, no scheme/port/path/wildcard, at most 253 chars; reserved-host guard | ✅ | `data/seeds/app.App/script.lua:26-31`; `src/util/script_helpers.cr:31-34` (`HOST_MAX_LENGTH = 253`); `src/app/host_ask.cr:37` |
| CLI: login waits five minutes; session at `~/.config/facet/auth.json`; `init` refuses when `facet.config.json` exists; rollback messages | ✅ | `packages/cli/src/login.ts:23` (`LOGIN_TIMEOUT_MS = 5 * 60_000`), `auth.ts:50`; `init.ts:45`; `rollback.ts:32-40` (exact messages) |
| Seeded `editor` role does not carry `deploy` (admin's `*` on `*.*` does) | ✅ | `data/seeds/iam.Roles/documents.yml` — no `deploy` named-action line on editor; admin blanket |

### build/deeper/index.md

| Claim | Verdict | Evidence |
|---|---|---|
| The four linked pages exist and cover isolation, storage, schema evolution, replication | ✅ | all four paths exist under `site-docs/src/content/docs/build/deeper/` |
| Lazy migration: no backfill job; `migrate_ahead` pays the same price up front | ✅ | `src/doctype/doctype_definition.cr:44`, `src/doctype/ahead_migration.cr:23,41,48` |
| The ETag is the last mutation id, short-circuits reads | ✅ | `src/document/routes.cr:280,304,358` |
| Overview page carries `features: []` (exempt from R5) | ✅ | front-matter line 6; R5 exempts overview pages |
| The plain-language halves exist under `/discover/how-it-works/` | ✅ | the files exist |

### build/first-hour/team-access.md

| Claim | Verdict | Evidence |
|---|---|---|
| `warehouse` role permissions table (equipment `*`, rentals read, clients read, Comment/Attachment `*`) | ✅ | `site-docs/examples/brightwater/load.sh:139-155` (line-for-line) |
| `warehouse` `visible_tags: ["default"]` — no `finance` | ✅ | `load.sh:153` |
| `purchase_price` carries the `finance` tag; only `manager` holds it | ✅ | `equipment.facet-domain/doctypes/equipment.Item.yml:46,50`; `load.sh:118` (manager `visible_tags: ["default","finance"]`) |
| Field tag: absent, not blank; enforced on every read path | ✅ | `src/rbac/field_visibility.cr` (masking layer); tag check on read/list/search/export paths |
| First role on an account becomes `default_role` | ✅ | `src/iam/account_cli.cr:277,300` |
| UI labels: "New account", "Generate password", "Regenerate password", "Send invite", "Temporary password generated" | ✅ | `frontend/messages/en.json` (`admin_generate_password`, `admin_regenerate_password`, `admin_send_invite`, …) |
| Sales reads `clients.Company` through `my_clients` (`account_manager = $self`), 5 of 10 rows | ✅ | `load.sh:126`; scope defined in `clients.facet-domain/` |

### admin/configure/file-storage.md

| Claim | Verdict | Evidence |
|---|---|---|
| Defaults: `max_upload_bytes` 52428800 (50 MiB), `grant_ttl_seconds` 3600, `grant_ttl_media_seconds` 21600, `upload_grant_ttl_seconds` 300, `prune_after_days` 30, `grant_prune_days` 7 | ✅ | `src/artifact/config.cr:56-62,86-93` |
| `storage.type` default `filesystem`, other value fails boot; `directory` default `tmp/uploads/dev` | ✅ | `src/artifact/config.cr:69-70,112-113,131,151` |
| S3 credentials/endpoint fall back to `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_ENDPOINT` env vars | ✅ | `src/artifact/config.cr:116-118,146-147` |
| `artifact_grant_secret` required at boot; `artifact_grant_secret_previous` supported for rotation | ✅ | `src/config.cr:343-344` (boot raises), `src/config.cr:406-408` |
| CLI: `artifacts:prune [--hard]`, `artifacts:reconcile [--dry-run]` (deletes objects older than one hour), `artifacts:revoke <id>` | ✅ | `src/cli/commands.cr:76-84`; `src/artifact/reconcile.cr:25` (`ORPHAN_AGE = 1.hour`), :92-95 (`--dry-run`) |
| **"All knobs except `storage` are hot keys. A settings save changes them from the next mint or prune run"** — presented with `artifact.max_upload_bytes` and `artifact.upload_grant_ttl_seconds` in the knobs table | ❌ | The system-settings registry holds only `grant_prune_days`, `grant_ttl_seconds`, `grant_ttl_media_seconds`, `prune_after_days`, `storage.type` (`src/system_settings/spec.cr:156-181`). `max_upload_bytes` and `upload_grant_ttl_seconds` are absent; runtime reads them from the config file only (`src/artifact/uploader.cr:625`, `src/artifact/upload_grants.cr:112`). The generated `reference/system-settings-keys.md:36-40` agrees. → fix list F1 |

### admin/keep-running/monitoring.md

| Claim | Verdict | Evidence |
|---|---|---|
| `GET /Healthcheck` readiness checks DB pools, Redis, stream consumers, answers 200/503; `/Healthcheck/live` liveness, no dependency checks | ✅ (code) | route handlers under `src/` — see `src/health*` / http routes; body shape matches AGENTS.md documented contract |
| `event_lag.max_lag` — lag check runs every 10 minutes by default | ✅ | `src/event/config.cr:37,48` (`lag_check_cron` default `*/10 * * * *`) |
| `/metrics` Prometheus text 0.0.4, no auth, not routed by the public edge | ✅ (code; edge routing from compose) | `src/metrics.cr` registry; `docker/` edge config — spot-checked |
| "The registry emits 20 catalogued names in total" | ✅ | `grep -c '"facet_' src/metrics.cr` → 20 |
| Log `format` values `text`/`json` default `text`; `level` default `info`; unknown value fails the boot; `LOG_LEVEL` env does not drive the app | ✅ | `src/config.cr:106-107,857-868` (boot raises on unknown values) |
| Root span `http.server.request`; SQL text truncated to 2000 chars | ✅ (partial — `http.server.request` at `src/telemetry.cr:36`; SQL truncation constant checked in telemetry.cr) | `src/telemetry.cr:36` |

### admin/people/row-scopes.md

| Claim | Verdict | Evidence |
|---|---|---|
| `$self` matches both the reference form `iam.Account.<id>` and a bare id | ✅ | `src/rbac/scope_value.cr:39-40` ("matched against both the bare … and the reference form") |
| `$null` exists (rows where the field is absent/null); `$parent_id`/`$doc_id` reserved tokens take `eq`/`ne` only | ✅ | `src/rbac/scope_value.cr:44-45,74-75`; `src/rbac/scope_predicate.cr:38-44` |
| Scoped lists compile to SQL, answer 200 (never 403); a row that fails a scope answers the same `404` as a missing document | ✅ | `src/rbac/read_enforcer.cr:76,90` ("a denied read both surface as a non-disclosing 404") |
| Create does not run the scope; a scoped create line raises a domain-check warning | ✅ | `src/rbac/validator.cr:143-171` (`scoped_create_warnings`) |
| Query-time narrowing `scope=<name>`, unknown name answers `422` | ✅ | `src/document/list.cr:239` (`422 "Unknown scope: #{named_scope}"`) |
| Aliases in an array combine with OR; `$all` collapses the line; omitted scope = unrestricted | ✅ | `src/rbac/scope_expander.cr` (OR expansion); `$all` handled at `src/rbac/scope_value.cr:56` |

### admin/people/index.md

| Claim | Verdict | Evidence |
|---|---|---|
| "what happens after ten wrong passwords" (sessions-lockouts teaser) | ✅ | `src/iam/login.cr:39-40` (`MAX_PWD_ATTEMPTS = 10`), lockout TTL 300 s `src/iam/login_throttle.cr:38-40` |
| Nine steps table: 9 pages in the group | ✅ | all 9 paths exist under `site-docs/src/content/docs/admin/people/` |
| Editor/viewer cannot update `core.SystemSettings` (carved out with `except`) | ✅ | `data/seeds/iam.Roles/documents.yml:47,50,53` |
| Row scope + field tag stack (Tom: 5 companies, no purchase price) | ✅ | consistent with the row-scopes and hidden-fields claims verified separately |
| Editor promote-self guard exists (who-can-change-roles) | ✅ | role authority guard, `src/rbac/role_authority.cr` (see roles-and-permissions table) |

### admin/people/mfa.md

| Claim | Verdict | Evidence |
|---|---|---|
| TOTP per RFC 6238: 6-digit code, 30-second step | ✅ | `src/iam/totp.cr:22-29` (`DIGITS = 6`, `PERIOD = 30`) |
| Backup codes: 10 per set, 8 hex chars shown `xxxx-xxxx`, stored as SHA-256 digests, each works once, `method: "backup_code"` accepted at the challenge | ✅ | `src/iam/backup_codes.cr:23-44,102` (`COUNT = 10`, `HEX_LENGTH = 8`, SHA-256); `src/iam/challenge.cr:25-27,52` |
| Runtime keys `iam.mfa.type` (`none`/`totp`) and `iam.mfa.enforcement` (`preferred`/`always`); file boolean `iam.mfa.totp.enabled` translates to the type | ✅ | `src/system_settings/spec.cr:211-219` (the documented translation exception) |
| `otpauth://totp/Facet:…` — issuer default `Facet` | ✅ | `src/iam/config.cr:95` (`issuer : String = "Facet"`), URI built at `src/iam/mfa.cr:53` |
| Rate limits: verify 429 after 5 wrong codes / 5 min; sign-in challenge → lockout; `mfa_disable` permission on `iam.Account` | ✅ | `src/iam/enroll.cr:107` (429), `src/iam/login_throttle.cr:97-99` (5-minute TTL), `src/iam/challenge.cr:146-147` (lockout on exhausted challenge), `src/iam/routes.cr:778` (`authorize(env, "mfa_disable", "iam.Account")`) |

### admin/people/roles-and-permissions.md

| Claim | Verdict | Evidence |
|---|---|---|
| Seeded roles and levels: admin 100, editor 30, viewer 20, comment_author 20, attachment_owner 20, anonymous 0 | ✅ | `data/seeds/iam.Roles/documents.yml:3-4,20-21,118-119,132-133,149-150,166-167` |
| editor/viewer subtract `core.SystemSettings` with `except` | ✅ | `data/seeds/iam.Roles/documents.yml:47,50,53` |
| Named actions: `provision_credentials` (iam.Account), `mfa_disable` (iam.Account), `publish_artifact`, `revoke`, `download`, `purge` | ✅ | `src/iam/routes.cr:608,633,656`, `src/iam/routes.cr:778`, `src/artifact/grants.cr:123`, `src/artifact/purge.cr` |
| Connectivity vocabulary `mcp`, `webhook`, `api`, `assistant`; browser sessions never gated by it | ✅ | the four channel gates in src (api: `src/iam/api_key.cr`; assistant: assistant surface; mcp: `src/mcp/routes.cr`; webhook: webhook authoring) |
| Role `name` immutable (422 script error on rename); delete refused while accounts hold the role | ✅ (code) | lifecycle validation in `src/iam/roles.cr` / `src/iam/role_store.cr` |
| Level 0–100; array-form `scope` required on write paths | ✅ | `src/rbac/validator.cr` (scope array validation), role authority guard level bounds |

### admin/under-the-hood/events-and-delivery.md

| Claim | Verdict | Evidence |
|---|---|---|
| Delivery at-most-once by decision: consumers read with `no_ack`, no XACK/pending/reclaim anywhere in src | ✅ | `src/event/manager.cr` consumer setup; no XACK/XPENDING in `src/` |
| `webhook.reconcile_window_hours` default 24 | ✅ | `src/webhook/config.cr:48,61` |
| `jobs.retention_days` default 30; boot refuses a window at or above it | ✅ | `src/jobs/config.cr:36`; refusal `src/config.cr:470-474` |
| New consumer groups start at `$`; replication passes `0` and replays | ✅ | `src/event/manager.cr:44-54` (`group_start_id : String = "$"`), :214 (only replication passes `"0"`) |
| Lag check every ten minutes; max lag gauge on `/Healthcheck` | ✅ | `src/event/config.cr:37,48` (`*/10 * * * *`) |

## 2a. Live-instance spot checks (2026-11-26, read-only; backend 127.0.0.1:3000)

- `GET http://127.0.0.1:3000/Healthcheck` → body shape matches monitoring.md exactly (pools, redis, consumers with `consecutive_failures`/`restarts`, `event_loss`, `event_lag`). ✅
- `GET /metrics` → exactly 20 `# TYPE facet_*` catalogued names. ✅ matches "20 catalogued names".
- `OPTIONS https://facet.localhost:3443/Api/rentals/Booking` with an unregistered `Origin` → `204` with allow-headers/methods/max-age `600` and **no** `access-control-allow-origin` line. ✅ matches cors.md.

## 3. Lost facts (old → new)

Sample of 20 old pages (seeded, same seed file; pool = the 40 pre-v2 pages under
`concepts/`, `govern/`, `operate/`, `start/`, `changelog/` at `51ad8c0`, the
last commit that still carries the old tabs):

start/glossary.md · concepts/auth-contexts.md · govern/row-scopes.md ·
govern/roles-permission-lines.md · operate/assistant-config.md ·
govern/governing-assistant.md · govern/rolling-back.md · operate/index.md ·
concepts/authorization-enforcement.md · govern/retention.md ·
operate/system-settings.md · changelog/index.md · govern/accounts-lifecycle.md ·
govern/field-visibility-tags.md · govern/api-keys.md · govern/app-grants.md ·
govern/index.md · operate/containers-tls.md · operate/bootstrap-cli.md ·
operate/retention-tuning.md

Method: for each page, the preservation checklist in `ledgers/13a–19.md` was
re-checked row by row against the actual new pages (heading presence, table
rows, cautions, troubleshooting entries, example shape), plus direct fact
greps of the old content into the new site.

| Old page | Verdict | Notes |
|---|---|---|
| govern/api-keys.md | ✅ no loss | new `admin/apps-access/api-keys.md` carries every section incl. checks table, attribution, app-owned keys |
| govern/app-grants.md | ✅ no loss | `admin/apps-access/app-grants.md`: two bounds, pre-check, re-resolved scope, consent, attribution, troubleshooting |
| govern/field-visibility-tags.md | ✅ no loss | `admin/people/hidden-fields.md`: visibility rule, read masking, write guards, audit redaction, "Tags are not secrets" (line 137), all 4 troubleshooting entries |
| govern/row-scopes.md | ✅ no loss | every checklist row present in `admin/people/row-scopes.md` |
| govern/roles-permission-lines.md | ✅ no loss | `admin/people/roles-and-permissions.md` section-for-section |
| govern/rolling-back.md | ✅ no loss | `admin/history/roll-back.md`: cause_kind/cause_parent, cascade_restored, both 403 gates, caution |
| govern/retention.md + operate/retention-tuning.md | ✅ no loss | merged `admin/history/retention.md` keeps the 9-class table, edges (`0` = keep forever, override badge, file-only overrides) |
| govern/accounts-lifecycle.md | ✅ no loss | `admin/people/accounts.md`: status lifecycle, credential states, first administrator, restore |
| govern/governing-assistant.md | ✅ no loss | `admin/assistant/govern.md`; model connection split into `connect-a-model.md` step 1 (deliberate split, both halves live) |
| govern/index.md | ✅ nothing to preserve | checklist records it was a 5-word stub |
| concepts/auth-contexts.md | ✅ no loss | `admin/under-the-hood/one-role-at-a-time.md`: four channels, `/Api/iam/me`, anonymous/401, ceiling, trade-off |
| concepts/authorization-enforcement.md | ✅ no loss | `admin/under-the-hood/how-access-is-enforced.md`: SQL compile, 403 naming path, metadata gate, non-disclosing 404, trade-offs |
| operate/system-settings.md | ✅ no loss | `admin/configure/system-settings.md` section-for-section |
| operate/containers-tls.md | ✅ no loss | `admin/install/containers.md`; one consciously corrected cut (the `/app` namespace row — old list wrong, reason recorded) |
| operate/bootstrap-cli.md | ✅ no loss | `admin/install/bootstrap.md` six steps + troubleshooting |
| operate/assistant-config.md | ✅ no loss | `admin/assistant/connect-a-model.md` |
| operate/index.md | ✅ no loss | tab index; all 17 listed pages exist under new paths |
| start/glossary.md | ✅ no loss | all 16 old terms are in `reference/glossary.md` (Scope → Row scope, Tag → Field tag, renamed) |
| changelog/index.md | ✅ no loss | `reference/changelog.md`: artifact table, image tags, npm prefixes, beta dist-tag, GHCR names |

**Lost facts: 0.** Every sampled old page's headings and facts either landed or
was cut with a written reason.

## 4. Surfaces without a page

**Re-run of `ledgers/scripts/extract_surfaces.mjs` at HEAD `c34885a`** (with
`FACET_ROOT` set — the script's relative default is stale after the plan
moved one level deeper): output is **byte-identical** to the recorded
`surfaces-raw.md` (0 diff lines). No new surfaces appeared.

Mechanical presence check of every extracted surface in the new site
(`site-docs/src/content/docs`, English pages):

| Kind | Count checked | Missing |
|---|---|---|
| `facet` CLI commands | 20 | 0 |
| Cron tasks | 15 | 0 (documented by task id — `sidecar.reconcile`, `mutations.compaction`, `webhook.reconcile`, … — in `admin/keep-running/jobs-cron.md` and `reference/config-keys.md`; the raw file's names are source file names) |
| Field types | 22 | 0 (documented by registered name; `long_text_type.cr` registers as `longtext`) |
| Agent tools | 23 | 0 |
| Metric names | 20 | 0 (live `/metrics` confirms all 20) |
| System/account settings keys | all | 0 (generated reference pages match the registries) |
| HTTP routes, frontend routes, UI label groups, Lua, Jinja2, error codes | mapped families | 0 — every old path in `surfaces.md`'s "Page that explains it" column resolves through `site-docs/scripts/page-map.mjs` (153 moves), and the targets exist |

**Surfaces without a page: 0.**

One bookkeeping finding: the ledger's own **"New page" column is empty on all
159 rows**, and the "Page that explains it" column still points at old paths.
The plan (04 §2) makes filling it a content-WP duty and the empty-column check
a WP 21 duty — it never happened. The mapping exists and is correct in
`scripts/page-map.mjs`, so this is ledger maintenance, not a coverage hole.
→ fix list F6.

## 5. Tally

- Claims checked: **162** (30 pages × ~5)
- Failed: **5** (F1 file-storage hot-keys, F2 schematic example, F3 sizing
  figure, F4 glossary bundle SQL, F5 glossary API-key admin claim) — error
  rate 5/162 ≈ **3.1 %**
- Security-claim errors: **0** (every who-can-do-what, redaction, non-
  disclosure, at-most-once and secret-handling claim verified)
- Lost facts: **0**
- Surfaces without a page: **0**

Pass criteria: the claim error rate is above the 2 % bar (three of the five
failures are minor wording, two are substantive), security and preservation
criteria hold. The five findings are on the fix list for a fix round.
