# WP 18 batch A ledger — people + app access

Ledger for the 11 pages in `admin/people/*` and `admin/apps-access/*`.
`verified_at` stamp: `eee55a2` (WP 12, the running-example commit; the live
instance runs the same tree). Live checks ran on the shared instance
`https://facet.localhost:3443` on 2026-11-26.

One throwaway role (`iam.Roles.wp18a_tester`) and one throwaway account
(`wp18a-probe@example.tld`) were created, exercised, and deleted during
verification. The four demo accounts and the three Brightwater roles were
never modified.

---

## 1. Preservation checklists

Old content = the moved pages as of commit `9ab44a5` (wave 1), which carry the
pre-rewrite govern/* content. Every H2/H3, table, aside, code block and
diagram of each old page is listed.

### govern/accounts-lifecycle.md → admin/people/accounts.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: account = iam.Account document, audited/reversible | §lead (compressed into the Monday story + account table intro) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (page, credential right, model links) | §Before you start | moved |
| Table: account fields (10 rows) | §The account document | moved |
| d2 diagram: status lifecycle | §The status lifecycle (same d2 source, re-fenced) | moved |
| pending-on-create rule + 2 exemptions + suspended/disabled 403 | §The status lifecycle | moved |
| §Steps 1 create (New form) | §Steps 1 | moved |
| §Steps 2 option A temporary password (format, shown once, must_change_pw, 422 refusals, clears invite) | §Steps 2 option A | moved |
| §Steps 2 option B invite link (24 h default `iam.change_password_expiration`, replaces link, service 422, accepts suspended/disabled + why-different paragraph) | §Steps 2 option B | moved |
| Caution: credentials, never forward response body | §Steps 2 caution | moved |
| §Steps 3 credential-states route + states table + label pairs | §Steps 3 | moved |
| §Steps 4 suspend/disable + sessions note + service-account no-login/reset no-op | §Steps 4 | moved |
| §Steps 5 delete + authority-guard 403 | §Steps 5 | moved |
| §Steps 6 restore route + 200/409/404/403/422 table + child-records note | §Steps 6 | moved |
| §The first administrator (`facet seed:admin`) | §The first administrator | moved |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (7 links) | §Related | moved (link titles updated to v2 titles) |
| Old link title "Roles and permission lines" → "Roles and permissions"; "Assigning roles and role election" → "Assign roles"; "Enforcing MFA" → "Require MFA"; "Machine access: API keys" → "API keys"; "Single sign-on with OIDC" → "Single sign-on (OIDC)"; "Sessions, refresh tokens and lockouts" → "Sessions and lockouts"; "Rolling back changes" → "Roll back a change" | across page | moved (retitles per page map) |

### govern/roles-permission-lines.md → admin/people/roles-and-permissions.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: role = iam.Roles doc, qualified id | §lead | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (page, model links) | §Before you start | moved |
| Table: role document fields (6 rows) | §The role document | moved |
| Table: permission line parts (4 rows) | §The permission line | moved |
| H3 `on` and prefix matching | §The permission line → `on` and prefix matching | moved |
| H3 `scope` (array required, OR, omit = all) | §The permission line → `scope` | moved |
| H3 `except` (concrete paths, prefix match, not a deny system) | §The permission line → `except` | moved |
| H3 Examples (5 full-line examples with effects) | §The permission line → Examples | moved |
| §The connectivity channels (4 channels, empty = browser-only, live re-read) | §The connectivity channels | moved |
| §Named actions table (6 rows) + caution (5 actions not for app-electable roles) | §Named actions | moved |
| §The role authority guard (4-row check table + containment sentence) | §The role authority guard | moved |
| §The seeded roles table (6 rows) + SystemSettings carve-out model | §The seeded roles | moved (Brightwater roles paragraph added) |
| §The role name is immutable (id desync reason, delete refuses while assigned) | §The role name is immutable | moved (real 422 body added) |
| §Example (regional_reader curl) | §Example | moved |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (5 links) | §Related | moved |
| Added: real rename-refusal response captured on the instance | §The role name is immutable | new (evidence for an old claim) |

### govern/assigning-roles-election.md → admin/people/assign-roles.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: roles array, one elected role | §lead (Nadia story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (page + guard) | §Before you start | moved |
| §Steps 1 assignments editor (2-mode table, deep-linkable URL) | §Steps 1 | moved |
| §Steps 2 assign (PATCH example + 4 enforcement rules + default_role tip) | §Steps 2 | moved |
| §Steps 3 remove (self-removal blocked by target protection) | §Steps 3 | moved |
| §Steps 4 check (re-read, applies at next sign-in/refresh) | §Steps 4 | moved |
| H3 One role per request (no merge, no cross-role reconciliation) | §How election works → One role per request | moved |
| H3 Election at sign-in (resolution order, 403, active_role/available_roles pair, roleless → anonymous) | §How election works → Election at sign-in | moved (real 403 body added) |
| H3 Switching during a session (refresh, two 403s, Switch Role menu, manifest rides response) | §How election works → Switching during a session | moved (the two 403 meanings clarified per code: refresh.cr:98-106) |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (5 links) | §Related | moved |

### govern/row-scopes.md → admin/people/row-scopes.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: scope = named condition, declared once | §lead (Tom story) | moved |
| Pair note (admin half; author half in build/model/access/named-scopes) | §lead note | moved (mutual top links kept) |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (grammar + declaration) | §Before you start | moved |
| H3 Where scopes live (yaml example + where-grammar table 5 rows + operator suffixes + $parent_id/$doc_id) | §Explanation → Where scopes live | moved |
| H3 What a permission line says (3 examples incl. `$all` collapse) | §Explanation → What a permission line says | moved |
| H3 How Facet applies a scope (6 bullets: lists, single reads 404, create intent, redefinition, query-time narrowing, credential-less) | §Explanation → How Facet applies a scope | moved |
| Caution: alias must exist on target doctype | §Explanation caution | moved |
| §Example (scoped editor, 6 steps) | replaced by the Brightwater `$my_clients` example with live output (5 company names) | merged: same teaching content, running-example form; the production.Project steps remain visible in the line examples and the worked example |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Worked example: own projects via teams (model bullets, d2 diagram re-fenced, role line, 3-step manager view) | §Worked example | moved |
| §Related (4 links) | §Related | moved |
| Added: live Tom list output (5 companies) | §The Brightwater setup | new (evidence) |

### govern/field-visibility-tags.md → admin/people/hidden-fields.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: tags, visible_tags, hide on reads + write refusal + audit redaction, fail closed | §lead (Lucía story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (field definitions + role content) | §Before you start | moved |
| §Steps 1 tag the field (hr.Employee yaml) | §Steps 1 (equipment.Item yaml — running example) | moved |
| §Steps 2 grant the tag (hr_partner json) | §Steps 2 (manager json) | moved |
| §Steps 3 check table (hr_partner vs team_lead) | §Steps 3 (manager/sales/warehouse with live Nadia/Tom outputs) | moved |
| H3 The visibility rule (all tags must sit in list; `["*"]`; fail closed) | §Explanation | moved |
| H3 Read masking (every nesting level; unknown keys omitted) | §Explanation | moved |
| H3 Write guards (4 bullets: 403 names path, null counts, raw-body-before-422, transition guard, trusted lifecycle) | §Explanation | moved |
| H3 Audit redaction (per-principal on read, `redacted` block, 3-row table, no marker stored) | §Explanation | moved |
| Tip: rollback checks the real transition → 403 | §Explanation tip | moved |
| H3 Tags are not secrets (secret, write_only) | §Explanation | moved |
| §Example (4-step employee walkthrough) | replaced by the live Brightwater item reads (Nadia sees value, Tom sees no key) | merged: same teaching with the running example and real output |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (4 links) | §Related | moved |

### admin/people/who-can-change-roles.md (not rewritten — outside my 11-page scope)

| Old heading / fact | Destination | Status |
|---|---|---|
| Whole page (concepts/roles-levels-authority.md per page map §3) | unchanged | open: page map assigns it to WP 18; my batch instructions excluded it. Proposed title "Who can change roles" (page map §3). Linked from index.md, accounts.md §5, roles-and-permissions.md. See §5 report, Requests outside my scope. |

### govern/enforcing-mfa.md → admin/people/mfa.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: TOTP factor, ask vs must, two tiers, recovery | §lead (Ravi story) | moved |
| H3 The factor (RFC 6238, 6 digits/30 s, backup codes) | §lead (merged into the factor paragraph) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (settings page, carve-out, member's side) | §Before you start | moved |
| H3 The two enforcement levels (preferred/always table + no-exit paragraph + caution) | §The two enforcement levels | moved |
| H3 The two configuration tiers (table, runtime wins, read row directly) | §The two configuration tiers | moved |
| §Steps 1 runtime policy (Security chapter, sparse PATCH, 422 write gate, Lua refuses create/delete) | §Steps 1 | moved (screenshot placeholder added) |
| §Steps 2 effective values (values/pinned maps) | §Steps 2 | moved |
| §Steps 3 enroll (5 numbered steps, verify call, backup_codes + mfa_enabled) | §Steps 3 | moved (live response shape added) |
| §Steps 4 backup codes (10 × 8 hex, xxxx-xxxx, SHA-256, once, method backup_code) | §Steps 4 | moved |
| §Steps 5 recover (mfa_disable route, permission, clears secret/replay/codes, Reset MFA button, federated hide) | §Steps 5 | moved |
| §Rate limits (3-row table, success resets) | §Rate limits | moved |
| §Troubleshooting (5 entries) | §Troubleshooting | moved |
| §Related (4 links) | §Related | moved |
| Added: config.dev.yml iam.mfa section + otpauth URI from the instance | §The two configuration tiers | new (evidence) |
| Added: live MFA enrollment on a throwaway account (setup → verify → disable all observed) | §Steps 3/5 evidence in claim ledger | new |

### govern/sso-oidc.md → admin/people/sso.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: OIDC providers as documents, audited | §lead (Brightwater story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (rights, provider details, redirect address) | §Before you start | moved |
| §Steps 1 provider document (10-row field table + API create example + 422 + secret stage call) | §Steps 1 | moved (screenshot placeholder added) |
| §Steps 2 check sign-in page (Continue with buttons, public read, no secret leaves) | §Steps 2 | moved (live `{"auth_mode":"hybrid","providers":[]}` output added) |
| §Steps 3 decide who gets an account (linking w/ provider+subject join key, JIT, service accounts never federate, suspended denies, no local MFA on path) | §Steps 3 | moved |
| §Steps 4 audit trail (oidc_provisioned/oidc_login/oidc_denied, generic browser error) | §Steps 4 | moved |
| §Steps 5 require SSO (hybrid/oidc_only table, write gate refuses oidc_only with no provider) | §Steps 5 | moved (config `iam.auth.mode` fallback added) |
| Caution: break-glass | §Steps 5 caution | moved |
| §Steps 6 recover (`facet auth:mode hybrid`, applies at once) | §Steps 6 | moved |
| §Troubleshooting (5 entries) | §Troubleshooting | moved |
| §Related (5 links) | §Related | moved |

### govern/sessions-tokens-lockouts.md → admin/people/sessions-lockouts.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: two credentials, short JWT + refresh in Redis | §lead (stolen-laptop story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| H3 Where sessions live (session:{id} hash contents, sets per account/app, Redis loss = re-login) | §Explanation | moved |
| H3 The access token (ES256 pinned, 900 s, claims table, JWT_SIGNING_KEY + generated-key warning + openssl command) | §Explanation | moved |
| H3 The refresh token and rotation (pair, 3-step rotation, 10 s grace, reuse → delete + refresh_reuse, 14-day TTL restarts) | §Explanation | moved |
| H3 Delivery modes (cookie/body, mismatch 422 before state change) | §Explanation | moved |
| H3 Session management (4-route table + token-until-TTL note + self-service link) | §Explanation | moved (live list shape added) |
| H3 The login throttle (5 counters + 1 flag, 300 s rules, flag own timer, only lockout writes event, facet.iam.login warn) | §Explanation | moved (live remaining_attempts + 429 bodies added) |
| §Steps clear a lockout (4-family DEL, per-address scan, password-only 3-family, shared-address caution) | §Steps | moved |
| §Steps verify the result | §Steps | moved |
| §Example (bulk revoke, {"ok":true,"revoked":3}, session_revoked events) | §Example | moved (live `revoked: 0` observed) |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (5 links) | §Related | moved |
| Added: config.dev.yml iam.jwt section (900/1209600/10) | §Explanation | new (evidence) |

### govern/app-grants.md → admin/apps-access/app-grants.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: grant bounds attempts, role bounds reach, both per request | §lead (Jo/Check-out story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (update on app.App, model link) | §Before you start | moved |
| §Steps 1 create (wizard, presets, setup step) | §Steps 1 | moved (screenshot placeholder added) |
| §Steps 2 set grants (4-level table, named-action toggles, child inheritance explicit on save, wildcard-refused note) | §Steps 2 | moved |
| §Steps 3 pin service role (missing-action warning, api channel) | §Steps 3 | moved |
| §Steps 4 publish and issue credentials | §Steps 4 | moved |
| §Steps 5 change or revoke (re-read per request) | §Steps 5 | moved |
| H3 Two bounds, not one (grant ceiling, role ∩, row scopes unchanged) | §Explanation | moved |
| H3 The grant pre-check (fails closed on empty set) | §Explanation | moved |
| H3 Effective scope re-resolved per request | §Explanation | moved |
| H3 What the app cannot reach (concrete paths, core.DocType needs grant) | §Explanation | moved |
| H3 Tokens, keys, and consent (typ app, PKCE+DPoP, consent always, app_api_key + draft/disabled 401) | §Explanation | moved |
| H3 Attribution (app id on mutations + login events, pre-check denials logged) | §Explanation | moved |
| §Example (crm.Contact/crm.Deal grants + required semantics) | §Steps 2 (real Check-out grants) + §The grant actions | moved |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (4 links) | §Related | moved |
| Added: the real Brightwater Check-out app grant JSON from the instance | §Steps 2 | new (evidence) |

### govern/api-keys.md → admin/apps-access/api-keys.md

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: static bearer, one account + one role pinned, re-checked every request | §lead (nightly-report story) | moved |
| §When to use this (3 bullets) | §When to use this | moved |
| §Before you start (role assigned + api channel; service account) | §Before you start | moved |
| §Steps 1 create (curl, field table, shown-once answer, fct_ + 26 chars, SHA-256 + prefix, 422s) | §Steps 1 | moved (live key + live 422 body added) |
| §Steps 2 call the API | §Steps 2 | moved |
| §Steps 3 list keys (field list, never the secret) | §Steps 3 | moved (live list row added) |
| §Steps 4 revoke (soft idempotent, bare 404) | §Steps 4 | moved (live `{"ok":true}` + 401-after-revoke added) |
| H3 What Facet checks on every request (6-row table, uniform 401, last_used_at ≤ 1/min) | §Explanation | moved |
| H3 Attribution (api_key column, api_key_created/api_key_revoked events) | §Explanation | moved |
| H3 App-owned keys (app_id, live+active gate, grant ∩ role) | §Explanation | moved |
| §Troubleshooting (4 entries) | §Troubleshooting | moved |
| §Related (6 links) | §Related | moved |

### govern/index.md → admin/people/index.md

| Old heading / fact | Destination | Status |
|---|---|---|
| 5-word stub ("This page is being written.") + stub front-matter (pagefind/pager false) | replaced by the group overview | replaced: stub, nothing to preserve |

---

## 2. Claim ledger

Sources: `src/…` line references, `doc/backend/…` files, live commands on
`https://facet.localhost:3443` (2026-11-26, curl with session cookies or
Bearer key; output pasted in the pages), and config files. All numbers,
defaults, limits and security statements are listed.

### admin/people/accounts.md

| Claim | Source |
|---|---|
| Account id is the lowercased email; status on create is `pending`; `organizational_unit` defaults to `/` | live `POST /Api/iam/Account` → `meta.id = "wp18a-probe@example.tld"`, `"status":"pending"`, `"organizational_unit":"/"`; src/doctype hooks (create hook) |
| Status values pending/active/suspended/disabled; suspended/disabled login → `403` | live suspended login → `{"error":"Account is suspended"}`; doc/backend/iam.md |
| Temporary password: 16 chars, 4 dashed groups, shown once, sets must_change_pw, clears pending invite; refuses service + suspended/disabled with 422 | live `POST …/temporary-password` → `{"temporary_password":"9YS5-6WH7-YNCE-H4Z7"}`; doc/backend/iam.md (format + gates) |
| Invite link TTL default 24 h = `iam.change_password_expiration` 86400 | config.dev.yml:157, docker/config.production.example.yml:85; live |
| credential-states route: batch read, states array (has_password, must_change_pw, mfa_enabled, invite_pending, federated), needs provision_credentials | live → `{"states":[{"id":"wp18a-probe@example.tld","has_password":true,"must_change_pw":true,"mfa_enabled":false,"invite_pending":false,"federated":false}]}`; doc/backend/iam.md |
| Login with temp password → `{"must_change_password":true,"change_token":…}`; change-password requires change_token AND old_password AND new_password; success flips status to active, clears must_change_pw | live sequence (login → change → re-read → re-login); src/iam/routes.cr:798-861 (old_password always required, 5-attempt throttle) |
| Delete = tombstone, history stays; restore answers 200/409/404/403/422 | live delete → 204, restore → 200 (account returned live), restore again → `{"error":"Document is not deleted"}` (409); doc/backend/iam.md; AGENTS.md rollback rules |
| Authority guard: cannot delete account above your level → 403 | doc/backend/rbac.md; doc/backend/iam.md |
| `facet seed:admin` prints one-time password once, refuses duplicate email | doc/backend/iam.md; surfaces.md row 146 |
| Service account: no password login, silent no-op resets, created active | doc/backend/iam.md |

### admin/people/roles-and-permissions.md

| Claim | Source |
|---|---|
| Role id = `iam.Roles.<name>`; name immutable on update | live rename PATCH → 422 `{"error":"Script validation failed","details":[{"message":"'name' is immutable after creation — the role id is iam.Roles.wp18a_renamed; recreate the role under the new name","code":"script"}]}`; doc/backend/rbac.md |
| String scope on write → 422 `permissions.0.scope must be an array` | live POST role → exact body captured; doc/backend/rbac.md |
| Level required 0–100; visible_tags default `["default"]`, `["*"]` sees all; connectivity vocabulary mcp/webhook/api/assistant; empty = browser-only | live roles list (all 9 roles with levels/channels/tags); doc/backend/rbac.md |
| Seeded roles table (admin 100 all channels/tags; editor 30; viewer 20; comment_author 20; attachment_owner 20; anonymous 0) | live `GET /Api/iam/Roles?items=20` → levels 100/30/20/20/20/0, channels per role; doc/backend/rbac.md |
| editor/viewer carve out core.SystemSettings with except | doc/backend/rbac.md; live role docs |
| Brightwater roles: manager 60 `["default","finance"]`; sales 40; warehouse 40 | live roles list; site-docs/examples/brightwater/load.sh |
| Guard: assignment ≤ caller level, default_role member, target protection, role authoring containment (level, lines implied, tags union, channels + assistant budget) | doc/backend/rbac.md (RBC-07) |
| `*.*` wildcard; parent path covers children; `except` prefix-matches; domain-only path covers domain | doc/backend/rbac.md |
| Named actions: provision_credentials, mfa_disable, publish_artifact, revoke, download, purge | doc/backend/rbac.md; doc/backend/iam.md |
| Delete refuses while any account holds the role | doc/backend/iam.md; live: role delete succeeded only after the account was deleted |

### admin/people/assign-roles.md

| Claim | Source |
|---|---|
| Assignment = PATCH on the account roles array; hook dedups, keeps first-occurrence order; default_role must be a member | live PATCH added viewer, response kept order; doc/backend/rbac.md |
| Sign-in election resolution: explicit role → default_role → first assigned | doc/backend/iam.md; live login (no role field) elected default wp18a_tester |
| Login with unheld role → 403 `Role 'iam.Roles.manager' is not assigned to this account` | live login body captured |
| Refresh role switch works without re-login; response carries active_role + available_roles + permission manifest | live refresh → active_role viewer, available_roles array |
| Refresh 403s: `Role not assigned` (not in assigned array — including unknown names), `Role not found or disabled` (assigned but document gone) | live: unheld manager and unknown nosuch both → `Role not assigned`; src/iam/refresh.cr:93-106 (servable check first, then document lookup) |
| Roleless account runs under iam.Roles.anonymous; available_roles [] | doc/backend/iam.md (B-120); src/iam/refresh.cr:196 |
| Cannot remove yourself from a role above your level | doc/backend/rbac.md (target protection) |

### admin/people/row-scopes.md

| Claim | Source |
|---|---|
| Tom's scoped list returns exactly 5 companies (names pasted) | live login as tom + `GET /Api/clients/Company?items=25` → 5 rows, names listed; site-docs/examples/brightwater/README.md |
| `my_clients` scope: `where: {account_manager: "$self"}` on clients.Company | site-docs/examples/brightwater/clients.facet-domain definition; 05-running-example.md |
| `$self` matches reference and bare id forms; `$my_teams` context set, empty matches nothing incl. `ne`; `$null` eq only; `$organizational_unit`; operator suffixes per field capabilities; `$parent_id`/`$doc_id` eq/ne only | doc/backend/rbac.md; doc/plans/.../05-running-example.md |
| Lists → SQL WHERE fragment, never 403; single reads/updates/deletes/actions → scope fail = 404 (non-disclosing); create ignores scope (intent channel to hook, warning on iam); redefinition applies next request; `scope=` query param narrows only, unknown → 422; credential-less → anonymous, `$self` inert, org unit `/` | doc/backend/rbac.md; doc/backend/http-layer.md |
| Alias must exist on target doctype, validated at role save | doc/backend/rbac.md; live: role save with `$all` (declared implicitly) OK — validation refusals documented in rbac.md |
| `$all` explicit unrestricted; omitted scope = same; in array collapses line | doc/backend/rbac.md |

### admin/people/hidden-fields.md

| Claim | Source |
|---|---|
| purchase_price tagged `finance`; manager lists `["default","finance"]`; sales/warehouse don't | live roles list; equipment bundle definition |
| Nadia reads item WITH purchase_price (`{"value":"4800.00","currency":"EUR"}`); Tom reads same item WITHOUT the key | live: tom vs nadia `GET /Api/equipment/Item?items=1` — key sets differ exactly as claimed |
| Visible when every tag in visible_tags; `["*"]` sees all; fail closed | doc/backend/rbac.md |
| Read masking at every nesting level; unknown content keys omitted | doc/backend/rbac.md |
| Write into invisible field → 403 naming path; explicit null counts; raw body before format validation; transition guard; trusted lifecycle populates | doc/backend/rbac.md |
| Audit redaction per principal on read; `redacted` block path-segment arrays; 3-row shape table; no marker stored; rollback checks real transition | doc/backend/audit.md; doc/backend/rbac.md |
| secret / write_only field kinds hide from everyone | doc/backend/doctype field types |

### admin/people/mfa.md

| Claim | Source |
|---|---|
| Factor TOTP RFC 6238, 6 digits/30 s; `window: 1`; issuer "Facet" | config.dev.yml:145-149; live otpauth URI `otpauth://totp/Facet:wp18a-probe%40example.tld?secret=…` |
| Enforcement levels preferred (dismissible prompt) / always (hold, no exit, no session before first code) | doc/backend/iam.md; live `me` → `"mfa_enforcement":"preferred"` |
| Two tiers: runtime SystemSettings wins, file fallback; decisions read the row directly (no cache) | doc/backend/iam.md; live `GET /Api/SystemSettings` |
| Write gate: type ∈ {none,totp}, enforcement ∈ {preferred,always}, else 422; Lua refuses create/delete of settings doc | doc/backend/iam.md; doc/backend/system-settings.md |
| Enrollment: setup returns secret + otpauth_uri; verify {code} → `{ok, mfa_enabled:true, backup_codes[10]}`; codes 8 hex `xxxx-xxxx`, shown once, SHA-256 stored, single use, method backup_code | live: setup → secret+uri; verify (computed TOTP) → `{"ok":true,"mfa_enabled":true,"backup_codes":["384f-0d34", …]}`; doc/backend/iam.md |
| Recovery: `POST /Api/iam/mfa/disable` {account_id}, needs mfa_disable, clears secret/replay counter/codes, sets mfa_enabled false; Reset MFA button, hidden for federated | live admin disable → `{"ok":true}`, account mfa_enabled false after; doc/backend/iam.md |
| Rate limits: enrollment verify 5/5min → 429; challenge 5 wrong → challenge deleted + lockout flag; enroll-at-login 5 wrong → token dies + lockout; success resets | doc/backend/iam.md (login throttle section) |
| Setup route requires a JSON body (POST with no body → error); optional `account` key sets the otpauth label | live: `-d '{}'` required; src/iam/routes.cr:703-721; logged as discrepancy #29 |

### admin/people/sso.md

| Claim | Source |
|---|---|
| Providers are documents (iam.OIDCProvider); create/update rights; editor carved out | doc/backend/oidc.md; doc/backend/rbac.md |
| Redirect address `https://<host>/auth/oidc/<name>/callback`; name immutable, lowercase/digits/hyphens; label defaults to name | doc/backend/oidc.md |
| issuer must be absolute https (http only loopback); secret staged out-of-band via secret store; scopes default openid/email/profile | doc/backend/oidc.md |
| Public provider read returns auth_mode + display names only; on the instance: `{"auth_mode":"hybrid","providers":[]}` | live unauthenticated GET captured; doc/backend/oidc.md |
| Linking join key = provider name + provider-side subject (not email); JIT conditions (unknown identity, verified email, allowlisted domain, auto_provision on → default_role required); federated_identities array; service accounts never federate; suspended/disabled deny | doc/backend/oidc.md |
| No local MFA check on the OIDC path (provider is factor of record) | doc/backend/oidc.md |
| Events oidc_provisioned / oidc_login / oidc_denied; browser sees one generic error | doc/backend/oidc.md |
| Modes hybrid (default) / oidc_only (password route 403 + password_login_denied event, reset + bootstrap 422, login page hides form); write gate refuses oidc_only with no enabled provider (422) | doc/backend/oidc.md; doc/backend/iam.md |
| File fallback `iam.auth.mode: hybrid` | config.dev.yml:154-155; docker/config.production.example.yml:82-83 |
| Recovery `facet auth:mode hybrid` writes the settings doc through the normal path, applies without restart | doc/backend/iam.md; surfaces.md row 147 |

### admin/people/sessions-lockouts.md

| Claim | Claim source |
|---|---|
| Session hash in Redis `session:{id}`; contents (refresh ids, account, role, timestamps, UA, address, delivery mode); sets per account + per app; Redis loss = re-login only | doc/backend/iam.md |
| Access token JWT ES256 pinned (header never selects); TTL 900 s `iam.jwt.access_token_ttl`; claims sub/sid/role/jti/typ; JWT_SIGNING_KEY env, P-256 PEM, unset → temp key + warning | config.dev.yml:141-144; doc/backend/iam.md; live cookie auth_token header `{"alg":"ES256","kid":"facet-1"}` |
| Refresh token pair `session_id.refresh_id`; rotation with 10 s grace `iam.jwt.refresh_grace_window`; reuse → session deleted + refresh_reuse event; 14-day TTL `iam.jwt.refresh_token_ttl` restarts on refresh | config.dev.yml (1209600); doc/backend/iam.md; src/iam/refresh.cr:70-83 |
| Delivery modes cookie/body; mismatched refresh → 422 before any state change | doc/backend/iam.md; src/iam/refresh.cr:61-68 |
| Session routes: GET list, DELETE one (idempotent `{ok, revoked:false}` on unknown), DELETE all-but-current, DELETE per-app | live: list shape captured (session_id, created_at, last_used, user_agent, ip, app, role); unknown-id delete → `{"ok":true,"revoked":false}`; bulk → `{"ok":true,"revoked":0}`; doc/backend/iam.md |
| Throttle: 10 wrong passwords/account → flag + 429; 20 per address → 429 no flag; MFA challenge 5 → delete + flag; MFA verify 5 → 429 no flag; counters 300 s from first increment, not extended; success resets password + post-sign-in MFA counters | doc/backend/iam.md; live: 10 attempts counted down `remaining_attempts` 9→0, 11th (correct password) → `{"error":"Too many attempts. Try again later."}`; flag lifted ~5 min later (next login passed the throttle and hit the status check) |
| Lockout flag own key `login_lockout:<account_id>`, own 300 s timer, set by password limit + MFA challenge; every sign-in 429 before password check while present | doc/backend/iam.md; live sequence |
| Only lockout writes a login-event row; failed attempts → backend log `facet.iam.login` warn with remaining attempts | doc/backend/iam.md |
| Clear runbook: 4-family DEL / per-address scan / password-only 3-family; shared-office caution | doc/backend/iam.md |
| Status check order: throttle runs before the password check, the suspended check after it | live: during lockout even correct password → 429; after expiry → `403 Account is suspended` |

### admin/apps-access/app-grants.md

| Claim | Source |
|---|---|
| App = app.App registration document; update rights admin/editor | doc/backend/app-system.md |
| Wizard steps (Setup → Permissions → Credentials → Review); presets web/backend; levels None/Read/Write/Full; write = create+update; named-action toggles; child inheritance explicit on save; wildcard target refused | frontend app wizard (Configure → Apps); doc/backend/app-system.md |
| Real grants JSON (rentals.Booking read, rentals.BookingLine read, equipment.Item read+write, all required:true; status active; client_type public) | live `GET /Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M` |
| Service role pinning; missing-required-action warning (non-blocking, real check per request); api channel required for key issuance | doc/backend/app-system.md; doc/backend/iam.md |
| Grant ∩ role per request; token never carries the grant; empty grant set fails closed; row scopes on the role unchanged inside granted paths | doc/backend/app-system.md; doc/backend/rbac.md |
| App token typ "app", OAuth code flow + PKCE + DPoP, consent always shown, one elected role | doc/backend/app-system.md; doc/backend/oauth.md |
| App-owned key (app_api_key channel): app must be live+active else uniform 401 | doc/backend/app-system.md; doc/backend/iam.md |
| Attribution: app id on mutations + login events; pre-check denials in login-event log | doc/backend/app-system.md; live LoginEvent rows (`layer1_denied`, `consent_granted` with app-scoped accounts) |

### admin/apps-access/api-keys.md

| Claim | Source |
|---|---|
| Key format `fct_` + 26 chars (30 total); shown once; stored as SHA-256 + display prefix; response {id, key, display_prefix, expires_at} | live create → `fct_6VBSG6…` (len 30), `display_prefix: fct_6VBSG6`; doc/backend/iam.md |
| Create requires the pinned role assigned to the caller + `api` channel; else 422 — live body: `{"error":"The role's connectivity excludes the 'api' channel — enable it on the role first"}` | live: removed channel → 422 exact body; doc/backend/iam.md |
| Key calls run with pinned account + role; re-checked every request | live key GET clients.Company → 200 with role-scoped data |
| List fields (id, name, display_prefix, role_id, created_at, expires_at, last_used_at, revoked_at); never the secret | live list row captured |
| Revoke soft + idempotent (repeat 200); unknown/not-yours → bare 404; use after revoke → 401 `{"error":"Authentication required"}` | live revoke → `{"ok":true}`; reuse → 401; doc/backend/iam.md |
| Verification chain (6 checks: revoked, expiry, account live+active, role assigned, role present, api channel) → uniform bare 401 | doc/backend/iam.md (api key verification pipeline) |
| `last_used_at` updates ≤ 1/min | doc/backend/iam.md; live list showed a fresh last_used_at |
| Attribution: api_key column on mutations; events api_key_created / api_key_revoked | doc/backend/iam.md; live LoginEvent `api_key_created` row observed |
| App-owned keys add the live+active app gate; reach = grant ∩ pinned role | doc/backend/app-system.md; doc/backend/iam.md |
| `expires_at` optional future ISO-8601, normalized to UTC | doc/backend/iam.md; DatetimeType normalize (AGENTS.md) |

### admin/people/index.md

| Claim | Source |
|---|---|
| The people story order (accounts → roles → assign → rows → fields → who can change roles → MFA → SSO → sessions) | doc/plans/.../18-wp-administer.md (page rules) |
| Brightwater through-line (Tom 5 companies, Lucía no price, Nadia finance tag, Ravi admin) | 05-running-example.md; live checks above |

---

## 3. Verification notes

Live sequence executed (throwaway pair only):

1. Created role `wp18a_tester` (level 10, api channel, read+update on
   clients.Company) → id `iam.Roles.wp18a_tester`.
2. String-scope write → 422 (body captured). Rename PATCH → 422 (body
   captured).
3. Created account `wp18a-probe@example.tld` → pending, id = email.
4. Temp password → `9YS5-6WH7-YNCE-H4Z7`; credential-states → must_change_pw
   true.
5. Login with temp pw → change_token; change-password (token + old + new) →
   `{"ok":true}`; status active; re-login OK.
6. PATCH roles + viewer; refresh switch → viewer; unheld + unknown role
   refresh → `Role not assigned`; login with unheld role → 403 body captured.
7. Sessions list/revoke shapes captured; bulk revoke → revoked 0; unknown id →
   revoked false.
8. MFA: setup (needs a body) → secret + otpauth; computed TOTP verify →
   mfa_enabled + 10 backup codes; admin mfa/disable → ok.
9. API key as probe: create (fct_…, len 30) → use 200 → list → revoke → 401.
   Channel removal → 422 (captured). Channel restored.
10. Lockout: 10 wrong passwords (remaining_attempts 9→0) → 429 with correct
    password → lifted after ~5 min → `403 Account is suspended` (status check
    after throttle).
11. Suspend → delete (204) → restore (200, returned suspended) → restore
    again → 409 `Document is not deleted`.
12. Reactivate → delete (204) → role delete (204). Cleanup complete.
13. Read-only: roles list, SystemSettings, public oidc providers, Check-out
    app document, LoginEvent samples, Tom/Nadia logins (5 companies; price
    masking pair).

---

## 4. Open questions

1. **who-can-change-roles.md is still pre-rewrite content.** The page map
   (§3, from `concepts/roles-levels-authority.md`) assigns it to WP 18 with no
   batch. My batch instructions listed only the 11 pages above, so I did not
   rewrite it. It is linked from index.md, accounts.md and
   roles-and-permissions.md, and its old title ("Roles, levels and the
   authority guard") does not match the page-map title ("Who can change
   roles"). Someone must rewrite it to close the people story.
2. **`iam.change_password_expiration` governs more than invites.** The file
   comment says "Time-to-live for password reset tokens". The old accounts
   page applies it to invite links. Both read the same key (iam.md), but the
   page keeps the invite wording of the old page; if reset tokens use a
   different window, the key comment is wrong. Needs a code check by the
   configure/* owner (batch B owns the settings pages).
3. **MFA enrollment via API needs a body** — logged as discrepancy #29. The
   `use/first-day/sign-in` page (another owner) should not teach a bodiless
   POST.
4. **Screenshot placeholders are not yet captured** — 7 ids listed in §5; the
   shot pipeline (WP 14) owns capture.
5. **`doc/backend/iam.md` says key verification checks "role projection
   present"**; the phrasing "projection" is engine language. The page
   translates to "the role document is gone" — confirm the underlying check
   reads the live document, not a cached projection (claimed from
   doc/backend/iam.md; not re-verified in src).

---

## 5. WP 18 batch A — report

- Pages written: 11 (new 1 — people/index.md was a stub; rewritten 10)
- Feature IDs now covered by this batch: IAM-01, IAM-02, IAM-03, IAM-06,
  IAM-07, IAM-08, IAM-09, IAM-10, IAM-11, RBC-01, RBC-02, RBC-04, RBC-05,
  RBC-07, RBC-08, DOM-12, AUD-03, FE-11, FE-12 (grants half), FE-14
- Gates: **not run** — builds are barred for this batch (shared checkout).
  Required before merge: `npm run diagrams` (new d2 fences in accounts.md §
  status lifecycle and row-scopes.md worked example), then
  `npm run build` + `node scripts/check-coverage.mjs`.
- Discrepancies logged: #29 (mfa/totp/setup requires a request body)
- Not verified (and why):
  - OIDC sign-in flow end to end — a real identity provider is out of scope
    per batch rules; verified from doc/backend/oidc.md, the config keys, and
    the public provider endpoint.
  - Per-address lockout counter (20 from one address) — would need source
    address spoofing; table kept from doc/backend/iam.md as moved content.
  - MFA challenge/enroll-at-login rate-limit rows — need an enrolled account
    at sign-in; covered by doc/backend/iam.md, preserved unchanged.
  - `facet seed:admin`, `facet auth:mode hybrid` — server-host CLI commands;
    not run on the shared instance (restart-adjacent), sourced from
    doc/backend/iam.md and the surfaces ledger.
  - Storybook/Vitest or Playwright checks — not part of this batch's gates.
- Requests outside my scope:
  - Rewrite `admin/people/who-can-change-roles.md` (page map §3, WP 18, no
    batch) and align its title to the page-map proposal "Who can change
    roles".
  - ledgers/surfaces.md page-column updates (shared file, not edited) —
    suggested new-page values for the rows this batch covers:

| Surface row (surfaces.md) | Feature | New page(s) |
|---|---|---|
| `/Configure/access/**` (41) | FE-11 | admin/people/roles-and-permissions.md, admin/people/assign-roles.md, admin/people/accounts.md |
| `/Configure/apps/**` (42) — grants editor half | FE-12 | admin/apps-access/app-grants.md (wizard/register half stays with apps/*) |
| `/Configure/platform/**` (44) — Security + OIDC chapters | FE-14 | admin/people/mfa.md, admin/people/sso.md (system-settings page itself = batch B) |
| `auth_*`, `login_*` (57) / `/Login` (35) — admin side of MFA policy | FE-01 | admin/people/mfa.md (member side stays with use pages) |
| `rbac_*`, `access_*` (67) | FE-11, RBC-01..07 | admin/people/* group |
| `app_*` (68) — grants/credentials half | FE-12, APP-01..09 | admin/apps-access/app-grants.md, admin/apps-access/api-keys.md |
| `POST /Api/iam/login`, `/challenge` (83) | IAM-01, IAM-10 | admin/people/sessions-lockouts.md |
| `/Api/iam/accounts/:id/invite`, `…/temporary-password`, `…/credential-states` (88) | IAM-06, IAM-07 | admin/people/accounts.md |
| `/auth/oidc/:provider(+/callback)`, `GET /Api/iam/oidc/providers` (89) | IAM-08 | admin/people/sso.md |
| `/Api/iam/keys*` (90, 134) | IAM-09 | admin/apps-access/api-keys.md |
| `/Api/iam/sessions*`, `/Api/iam/apps/:app_id/sessions` (91) | IAM-11 | admin/people/sessions-lockouts.md |
| App registry documents CRUD + grants (103) — grants half | APP-01, RBC-08 | admin/apps-access/app-grants.md |
| `iam.*` config keys (187) — mfa/auth/jwt sections | IAM-01..11 | admin/people/mfa.md, admin/people/sso.md, admin/people/sessions-lockouts.md |
| `/Settings/sessions` self-service (69) — session semantics | FE-17, IAM-09, IAM-11 | admin/people/sessions-lockouts.md (route reference; the /Settings UI page belongs to the use group) |

- Proposals: none beyond the who-can-change-roles rewrite above. The people
  story order in index.md includes it between hidden-fields and MFA, per the
  WP-18 page rules.
