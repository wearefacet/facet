# QA bugs — F-series naive sweeps

One file per finding. Each file records the finding as filed and its verification against the envelope commit under test (source review, read-only). F-IDs are provisional per sweep; triage to B-IDs is not done. The source scenario evidence lives in the external QA repo (`scenarios/feature-coverage/F0x-*/evidence/naive-<date>/`).

Files exist for findings verified CONFIRMED or PARTIAL. Findings marked INFIRMED or UNVERIFIABLE get no file — the sweep section below records their disposition.

## Sweep 2026-11-21 — naive F01–F10 against the release `02b67c90` (verified against HEAD `2953fb7`)

Naive full F-series pass run against the first public release (`02b67c90`, tag `v0.2.0`). The
report was consolidated in one file; verification here is source review, read-only, at HEAD
`2953fb7` (four commits after the release: `d0efac9`, `e963d10`, `fe26a4a`, `2953fb7`). The
release-to-HEAD delta changed no verified path except the document-update and RBAC scope
internals, which touch F04-01 and F10-09 only by strengthening the same code.

The report carried 59 findings (F01→F10). 22 were verified actionable and got a file: 15
CONFIRMED, 5 PARTIAL, 2 confirmed-but-by-design with a documentation gap. The rest split as
below — 16 INFIRMED, 12 brief drift or by-design with no in-repo action, 4 UNVERIFIABLE, 3
duplicates of a finding above, and 2 not a defect.

Headline: **F04-01** (an editor forks and publishes a foreign live domain — the documented 403
can never fire for the seeded role) and **F07-01** (the seeded `editor` can open a working
outbound webhook — containment C7 FAIL). The F10 authoring-door cluster (F10-01, F10-02, F10-03,
F10-04) is the other load-bearing group: a view config, a view template, and a doctype round-trip
all accept input the renderer cannot use. Two findings the previous sweep fixed did **not**
reproduce as filed and are recorded as PARTIAL or INFIRMED (F05-01, F09-02).

### Filed — resolved 2026-11-22 (files removed)

All 21 finding files were fixed and removed. The two by-design rows (F02-01) stay in **Not
filed**. One row records what each fix changed.

| ID | Sev | Finding | Fix |
|---|---|---|---|
| F04-01 | 🟠 | A domain editor forks **and publishes** a live domain she does not edit | `Domain::Editors.authorize_draft_from?` requires source membership whenever a `source_domain` is present; the `All` create verdict no longer bypasses it. |
| F07-01 | 🟠 | The seeded `editor` carries the `webhook` channel, so a non-admin opens a working egress channel (C7 FAIL) | The seeded `editor` role carries `connectivity: [api, assistant]`; only `admin` holds `webhook` and `mcp`. |
| F10-01 | 🟡 | CollectionView `config` is unvalidated; an unusable config renders an empty board | New `Document::CollectionViewGate` validates `config` against the parent doctype at both write doors (`422` with field paths). |
| F10-02 | 🟡 | `PATCH` on a `core.DocumentView` merges `template` instead of replacing it | `Document::Update` replaces `template` (`core.DocumentView`) and `config` (`core.CollectionView`) on write; both gates validate the submitted value. |
| F10-03 | 🟡 | The template gate does not resolve `relation.source.rel`, relation column keys, or display-node bindings | `ViewTemplateValidator` resolves these against the doctype definition and emits `:warning`; `/check` reports them. |
| F10-04 | 🟡 | The doctype GET→PUT round-trip drops an array-of-reference target | `FieldDefinition#to_json` emits the full nested `items` / `properties` / `values`; the refusal names the flat authoring PATCH. |
| F03-01 | 🟡 | The nested-route 404 mixes children, sidecars and actions under "child" | The miss message splits "unknown relation" (children + sidecars) from "unknown action"; the action route's location is documented (the declarative slice stays hand-maintained). |
| F03-02 | 🟡 | The inline-children counter stays at the persisted-row count while drafts are staged | The relation header counts visible drafts when editable. |
| F03-03 | ⚪ | A no-op `PUT core.DocType` answers `422` with a text-only match and no machine code | An idempotent re-save answers `200` with the unchanged projection (`Result#unchanged`); the seed reconcile treats it as a no-op. |
| F06-01 | 🟡 | The audit pager prints the from-offset count as "N total mutations" | The footer labels the remainder ("N more from here"); the API contract is unchanged. |
| F07-03 | 🟡 | `GET /Api/Audit` admits `field=` / `select=` and ignores them | The audit route admits only the keys it reads; other grammar keys answer `422`. |
| F07-05 | ⚪ | A lowercase probe path answers `303 → /Login` and `200` HTML | Both edge Caddyfiles answer `404` for `/healthcheck` and `/metrics` on every method, before the SPA fallback. |
| F08-01 | 🟡 | The usage meter cannot tell an estimate from a bill | `GET /Api/assistant/usage` returns `estimated_total`; the meter shows a hint; the two doc paragraphs are reconciled to the code. |
| F08-03 | ⚪ | `/Api/_mcp/endpoints` lists roles with no `mcp` channel | The listing filters on the `mcp` channel through the shared consent helper. |
| F09-01 | 🟡 | A Redis outage reaches the login box as an opaque `500` | Connection-level errors map to `503 {"error": "Service unavailable", "dependency": …}`; documented in `http-layer.md`. |
| F09-03 | 🟡 | A domain with a set secret cannot be moved between instances | `facet domain:export --omit-secrets` strips the secret markers so the bundle imports with the fields unset. |
| F09-05 | ⚪ | The REST refusal for `artifact.storage` names a field that does not exist | The `artifact.storage` node answers the write-gate message (config-file remedy) instead of `unknown_field`. |
| F10-06 | ⚪ | A hand-authored column without `label` prints the raw field key | One render-time rule: `label ?? field.title ?? humanize(key)`. |
| F10-07 | ⚪ | A `file` cell shows the artifact id in the table and a filename on the show page | `file` cells resolve the cached filename (shared cache) and fall back to the id with the id as a tooltip. |
| F10-08 | ⚪ | Money formats three ways on one document; `-0.00` prints | The header chip uses `formatMoneyAmount` + `composeMoneyText`; a value that rounds to zero drops its sign. |
| F10-09 | ⚪ | Nested child reads need no child grant, and the docs do not say so | Documented in `rbac.md` and `http-layer.md`: the nested route reads children through the parent; the flat child route stays refused. |
| F10-10 | ⚪ | `Doctype::Check` does not name a view that groups on an unservable field | `check.cr` reads the doctype's `core.CollectionView` rows through `CollectionViewGate.validate` and reports a `:warning`. |

### Not filed — no verification file

| ID | Verdict | Disposition |
|---|---|---|
| F01-01 | By design | The guard is per-email and `iam.md` names `accounts:create` as the second-admin path. Residual: the CLI does not say it created an *additional* admin. |
| F02-01 (filed) | By design | `filters` stays opt-in and `doctype-system.md` states that no authoring door applies a default. The Builder's defaults live in `frontend/src/lib/doctype/capabilities.ts`. The asymmetry is documented; the residual is discoverability (see F10-10). |
| F02-02 | INFIRMED | The skip is by design (the cross-doctype endpoint needs a `search` template; the list `search` filter keeps the `display_name` fallback corpus). The check notice is accurate per surface — the two clauses describe two different routes, not one contradiction. |
| F02-03 | By design | An earlier-step close is session-only by documented design (`doc/frontend/settings.md`); only the last step and the checkbox persist. |
| F04-02 | By design | The qualified id `iam.Roles.<slug>` is documented (`iam.md`). The 404 names the wrong id form but the doc does not. |
| F04-03 | By design | `import-export.md` states the header follows the caller's selection and the cells are masked. The `422` contract covers unknown and duplicate keys only. |
| F04-04 | By design | `active: false` covers both "never accepted" and "paused" by documented design (D6). No doc requires a dropped-consumer marker. |
| F04-05 | CONFIRMED (doc gap) | Correct by design (the `activate` action is doctype-global, held by the admin). The gap is that no doc says "only an administrator can accept a grant" and the `403` names no holder. |
| F05-01 | INFIRMED | `iam.mfa.enforcement` IS rendered (`SystemSettingsForm.svelte`), hidden only while `iam.mfa.type === 'none'`. The residual observation holds: the default is `preferred`, so flipping TOTP alone does not enforce. |
| F05-02 | CONFIRMED (doc gap) | The Accounts subtitle promises credential management; the peek is read-only and the actions live on the document page. The copy should change. |
| F05-03 | Brief drift | A revoked key stays listed with a `REVOKED` badge, and no `challenge` LoginEvent exists — both match the docs. |
| F06-02 | CONFIRMED (label) | The history chip says "Document version {idx}" while `meta.version` is the snapshot counter. Two meanings of "version" on one document. |
| F06-03 | Brief drift | Redaction is a read-side transform; a write into an invisible field is refused `403` first. The docs match the code. |
| F06-04 | PARTIAL | The slug-vs-ULID split holds, and a ULID app addressed by slug answers `404`. The seeded `facet-cli` is `public`, so it answers `422 "App is not a backend app"`, not `404`. |
| F07-02 | INFIRMED | The suspected replay path does not exist: a new group is created at `$`; an existing group resumes its cursor, and a `no_ack: true` + `>` reader leaves the cursor at the tail. The doc wording for the existing-group case is thin, not wrong. |
| F07-04 | CONFIRMED (feature gap) | A hook's `document.*` error carries only the top-level message; `details` are dropped. No doc promises them to hook authors. |
| F07-06 | Brief drift | The vocabulary is the documented closed set of bare verbs. |
| F07-07 | PARTIAL | The `confidential (secret)` copy contradicts the "nothing here is confidential" panel, but the two do not appear on one page. |
| F07-08 | CONFIRMED (UI) | Two `window.confirm` calls sit beside dialog-based destructive actions in the same surface. |
| F07-09 | By design | `app.Deployment` declares no actions; rollback is `PATCH app.App {active_deployment}`, documented in `app-system.md`. The 404 does not point there. |
| F08-02 | By design (open decision) | The terminal refusal rides `cancelled`, and `agent-conversations.md` now documents it in three places. A distinguishing status stays an open product decision (same as the earlier sweep's F08-01). |
| F08-04 | CONFIRMED (copy) | The authorize refusal says `App is not active (status=draft)` and does not name the field to set. |
| F08-05 | By design | `@facetapp/chat` is source-only and disclosed in `doc/packages/chat.md`. A bundler is required by contract. |
| F09-02 | INFIRMED | An emptied numeric input submits no key (`state.text === ''` is skipped in `buildPatch`). Only the explicit keep-forever toggle writes `0`. |
| F09-04 | CONFIRMED (prose) | `openapi.md` said 26 paths / 36 operations; the spec carries 27 paths / 30 standard operations + 7 `x-query` twins. The prose now states the real counts and names `doc/api/openapi.json` as the source of truth. |
| F09-06 | Duplicate | Same mechanism as F07-05, on `/metrics` — fixed with it. |
| F10-05 | INFIRMED | The calendar's own picker text names `filters: [comparison]`; the `[equality]` hint belongs to the kanban group-by and to the filter compiler, and is correct there. |
| F10-11 | Brief drift | `doc/frontend/kanban.md` states the surface is read-only in this version ("no drag and drop"). |

### Retracted or not a defect

| ID | Reason |
|---|---|
| F03-04 | Brief drift — MIME comes from magic bytes by design, and the signed URL is `/A/:gid`. |
| F07-05 residual (`/metrics`) | Kept inside F07-05; the edge does not route `/metrics`, which `metrics_route.cr` documents. |

## Sweep 2026-11-20 — naive F01–F10 (verified against `1b7bf906`)

Ninth naive full F-series pass (report dated 2026-11-19/20). The sweep ran on another machine; the detailed repro evidence and the consolidated report live with that session. Verification here is source review, read-only, against the sweep commit `1b7bf906` and HEAD `abe21a28`. Two commits landed between the sweep and verification (`8234d6e9` site-docs only; `abe21a28` OIDC role provision + system settings) and none changed a verified path — the one relevant delta is JIT role provisioning (roles now resolve from the instance baseline instead of the provider's `default_role`), which touches no verdict. Thirteen parallel source-review agents produced the verdicts; the load-bearing claims were spot-checked directly.

52 findings were verifiable from the in-repo copy of the report (7 🟠 with repro, 45 ⚪). 31 got a file (23 CONFIRMED, 8 PARTIAL) — triaged 2026-11-20: 26 fixed and their files removed, 5 kept with open product/design decisions (files retained for review). 21 got none: 2 INFIRMED, 4 UNVERIFIABLE, 1 duplicate, 14 verified as documented design or brief drift with nothing actionable in this repo. The sweep itself retracted 7 of its observations before verification (method honesty; see below). The report's brief-drift register collects the brief fixes for the QA repo; the in-repo facts behind it were verified where checkable. Containment: every adversarial pass in the report came back SAFE — nothing to file from the containment ledger.

Headline: the one boot-class bug is **F09-01** (an unresolvable OTLP endpoint crashes boot — only `Socket::ConnectError` is rescued). The authoring/UX door gaps: F02-01 (a bare reference target is accepted at definition, then the field refuses every value), F10-01 (DocumentView REST doors store malformed relation columns the docs say are refused — the validator gates only the assistant door), F10-02 (kanban group-by and calendar discriminator pickers offer capability-less fields), F04-01 (the role UI cannot edit `visible_tags`), F01-02 (the fresh-account timezone picker degenerates to one option). The prior run's F09-02 blocker did not reproduce — INFIRMED (the in-place repair is spec-pinned and documented).

### Filed — triaged 2026-11-20 (26 fixed, files removed; 5 open, files kept)

| ID | Sev | Finding | Verdict | Disposition |
|---|---|---|---|---|
| F01-02 | 🟠 | Timezone picker shows one option on a fresh account (B-347, new shape) | CONFIRMED | Fixed 2026-11-20 (file removed) — `allTimezones()` guarantees a `UTC` entry (injected when the runtime omits it) and the Settings page renders it as a featured plain "UTC" option, so the bound server default always matches an option; the label-sync guard fires and both residuals close. Pinned by `timezones.spec.ts`. |
| F02-01 | 🟠 | Unqualified reference target accepted at definition; field then refuses every value (B-275 family) | CONFIRMED | Fixed 2026-11-20 (file removed) — `ReferenceType#validate_definition` refuses a bare target at authoring (422 naming the qualified `domain.Doctype` form) across create/update/import/publish; `DraftTargetCheck` comments reconciled, `/check` keeps flagging pre-gate definitions, `doctype-system.md` updated. Specs: `spec/doctype/reference_target_gate_spec.cr`. |
| F04-01 | 🟠 | `visible_tags` not editable in the role UI (B-87/B-350 family) | CONFIRMED | Fixed 2026-11-20 (file removed) — the role Details tab hosts an editable tag list included in the PATCH; the caller ∪ previous union rule is mirrored client-side (`roleTags.ts`) and surfaced as clean validation errors; `spec/rbac/role_authority_spec.cr` pins the `tag_errors` detail + wildcard bypass. |
| F09-01 | 🟠 | OTel endpoint with an unresolvable host crashes boot (telemetry.md promises NullExporter downgrade) | CONFIRMED | Fixed 2026-11-20 (file removed) — the probe rescues `Socket::Addrinfo::Error | Socket::ConnectError` (unresolvable sink → NullExporter + one WARN, boot survives); DNS-failure regression spec added; `telemetry.md` now states that a firewalled sink does drop telemetry. |
| F10-01 | 🟠 | DocumentView save doors accept malformed relation columns the docs say are refused — SILENT SUCCESS | CONFIRMED | Fixed 2026-11-20 (file removed) — `Document::ViewTemplateGate` wired into `Document::Create`/`Update` (nested create, compound `$children`, flat + nested PATCH; publish reconcile inherits): `:error` issues answer 422 naming the problems, duplicate keys stay warning-only. Door specs in `spec/integration/document_view_spec.cr`; `document-view.md`/`workflow.md` claims corrected. |
| F10-02 | 🟠 | Kanban/calendar view editors offer fields that cannot serve the required filter | CONFIRMED | Fixed 2026-11-20 (file removed) — the pickers gate on the derived operators (group-by needs `eq`; discriminator needs `gte`+`lte`, with `period`/`dateperiod` eligible via native range; end-field needs `gte`) and `validateDraft` refuses a saved picker that lost its operator. Residual: a period discriminator without `end_field` still fetches unbounded (native-range design). |
| F01-01 | ⚪ | `facet seed:admin` misuse exits 0 | PARTIAL | Fixed 2026-11-20 (file removed) — `SeedCLI` parses flags (`--help` prints usage; unknown flags exit 1), enforces one positional, validates the email against the live `iam.Account` field definition, and lowercases it; contract documented in `cli.md`. Specs: `spec/iam/seed_cli_spec.cr`. |
| F01-02b | ⚪ | UTC zone renders a degenerate label with empty city | PARTIAL | Fixed 2026-11-20 (file removed) — same change set as F01-02: a plain featured "UTC" option exists on every runtime and `UTC` never passes through the `(GMT{offset}) {city}` template. |
| F01-04 | ⚪ | Fallback form labels fields with raw keys while show page renders titles (covers F04-05) | PARTIAL | Fixed 2026-11-20 (file removed) — both fallback surfaces now label with `field.title ?? humanize(field.key)`. |
| F02-02 | ⚪ | Sidebar doctype count badge stale after import | CONFIRMED | Fixed 2026-11-20 (file removed) — `navCounts` gained `invalidateCount`/`clearDomainCounts` with a mid-flight token guard; the row import invalidates the imported doctype's count and the bundle import clears the domain's; NavPanel re-fetches on the version counter. Residual: live WS create/delete events do not invalidate counts. |
| F02-03 | ⚪ | Template edits apply only to new writes; existing rows need `doctype:reproject`; no UI hint | PARTIAL | Fixed 2026-11-20 (file removed) — the DoctypeEditor template section carries the stale-rows hint with a pointer to the maintenance reproject surface (message keys en+fr); a story asserts it. |
| F03-04 | ⚪ | `core.DocType` list not filterable by name/domain | CONFIRMED (by design) | Fixed 2026-11-20 (file removed) — product call taken: `filters: [equality]` added to the seed's `doctype` and `domain` fields; the equality clause builder already serves plain string fields, no code change. Seed validity, projection staging, and filter-compiler specs pass; full suite green. |
| F04-02 | ⚪ | Role grants editor silently discards unsaved edits on tab switch | CONFIRMED | Fixed 2026-11-20 (file removed) — a shared unsaved-edits gate (`unsavedEdits.ts`) confirms tab/route departure and arms `beforeunload` when the editor (or Details page) is dirty; the Members tab registers none (it PATCHes immediately). |
| F04-03 | ⚪ | Role election is API-only; no UI switcher for multi-role accounts | PARTIAL | Open (product call) — file kept. The sidebar Switch Role submenu exists and is documented; a login-time role picker is an optional UX enhancement awaiting a product decision. |
| F05-01 | ⚪ | Issuer `http://keycloak:8080` refused; working issuer is the `keycloak.localhost` carve-out | CONFIRMED (by design) | Fixed 2026-11-20 (file removed) — the issuer error text and the seed field description name the full loopback set `(localhost, *.localhost, 127.0.0.1, ::1)`; a spec pins the refusal text. Behavior unchanged. |
| F05-05 | ⚪ | Consumed reset token still renders the full form; refusal only after submitting | CONFIRMED | Open (product call) — file kept. `PasswordReset.confirm` consumes the token atomically before validating, so a load-time check needs a new non-consuming validate endpoint; one-shot semantics must be preserved. Decision needed. |
| F05-06 | ⚪ | "1 attempts remaining" grammar | CONFIRMED | Fixed 2026-11-20 (file removed) — the backend challenge/enroll strings pluralize ("1 attempt remaining."); the frontend message is an inlang `attempts` matcher (en + fr). |
| F05-07 | ⚪ | Reload during enroll-at-login loses enroll context | CONFIRMED | Fixed 2026-11-20 (file removed) — the `always`-branch enroll context (token, secret, otpauth URI) persists in `sessionStorage` with a 300 s TTL mirror, restores on mount, clears on success/dismiss/expiry; pure logic in `loginFlow.ts` (+10 tests). The `preferred` branch stays as is (product call). |
| F05-08 | ⚪ | Stale tab title on no-role screen | CONFIRMED | Fixed 2026-11-20 (file removed) — `NoRoleScreen` sets a `<svelte:head><title>` through a new paraglide key (en + fr). |
| F06-01 | ⚪ | GET→PATCH round-trip on a domain fails 422 on `draft` | CONFIRMED (by design) | Fixed 2026-11-20 (file removed) — spec-only: `spec/document/update_spec.cr` pins the presence-based draft guard (an unchanged stored value still 422s; the create side mirrors). The gate itself is unchanged by design. |
| F06-03 | ⚪ | Role names reject hyphens while app slugs allow them | CONFIRMED | Fixed 2026-11-20 (file removed) — `rbac.md` documents the role-name grammar (`^[a-z][a-z0-9_]*$`, immutable) and the identifier-vs-URL-facing split. No code change. |
| F07-02 | ⚪ | Healthcheck is `/Healthcheck` (capital H) | CONFIRMED | Fixed 2026-11-20 (file removed) — the two `doc/plans/` spellings now read `/Healthcheck`. |
| F07-03 | ⚪ | `app.App.host` has no Configure UI editor — REST-only | CONFIRMED | Fixed 2026-11-20 (file removed) — product call taken: the app Settings tab hosts a Serving section that edits `host` (client-side shape check through `validateHostname`, the mirror of the backend hook rule; the hook stays the authority; `no_asset` disables it; empty saves `host: null`, the JSON Merge Patch clear). DNS/TLS stay the deployment stack's responsibility. `app-system.md` and `app-configure.md` describe the editor; four stories pin the behaviour. |
| F08-01 | ⚪ | Terminal-refusal turn lands `status=cancelled` — indistinguishable from user cancel | CONFIRMED | Open (product call) — file kept. The status table (`turn.cr`, incl. the missing `capped` row) and `agent-conversations.md` now document the refusal case (rides `cancelled`; the tool trace differentiates). A distinguishing status/meta flag + UI copy remain a product decision. |
| F08-02 | ⚪ | Assistant audit mutations carry `cause_kind:"assistant"` but `cause_name:null` | CONFIRMED (by design) | Open (design) — file kept. `mutation.md` now names both unnamed-cause surfaces (workspace + app assistant). Per-tool attribution stays an open design question. |
| F08-05 | ⚪ | `workspace/conversations/:id` GET falls through to the doc route (404 "Unknown doctype: assistant.workspace") | CONFIRMED | Fixed 2026-11-20 (file removed) — `GET /Api/assistant/workspace/conversations/:id` now answers an opaque 404 "Not found" instead of falling through to the doc route (no blanket `assistant` reservation); a spec pins the body. |
| F08-06 | ⚪ | App key with empty grant∩role → bare 401, reason only in WARN log | CONFIRMED (by design) | Fixed 2026-11-20 (file removed) — the OAuth app-token empty-scope path logs the same WARN + `auth.refused = "empty_scope"` span tag as the app-key path (the 401 body stays opaque, spec-pinned); operator guidance in `iam.md`. Residual: the `role_usable?` branch still logs nothing. |
| F09-03 | ⚪ | No `facet cron:list` / cron API; successful runs log nothing | PARTIAL | Fixed 2026-11-20 (file removed) — the logging half was docs-only: `cron.md` documents the completion-line contract (the `log_zero` split, reconcile-on-work tasks, the two-layer failure logging). The feature half: the boot cron table moved to `Cron::Tasks.boot_entries` (`src/cron/tasks.cr`, id + config schedule key + expression + callback; `run_server` registers from it) and `facet cron:list` (`Cron::ListCLI`, `src/cron/list_cli.cr`) prints it with the next fire time computed from now (UTC); an unparseable expression marks its row and exits 1 — the server refuses to boot on the same error. Config only, no DB/Redis, chainable. Specs: `spec/cron/tasks_spec.cr`, `spec/cron/list_cli_spec.cr`. |
| F09-06 | ⚪ | Check-report can list doctypes outside the queried domain | PARTIAL | Open (no change) — file kept. By design: entries are same-domain by construction; issue text may legally name foreign doctypes. Recorded for the user's review. |
| F10-05 | ⚪ | Tag-masked field renders its label + "—" on DVT/kanban; fallback form hides it entirely | CONFIRMED | Fixed 2026-11-20 (file removed) — DvtField applies `fieldVisible` in the display path (a masked row renders nothing — the fallback-form affordance); kanban card bodies fix transitively. Stories pin the masked and held cases; `document-view.md` documents the rule. |
| F10-06 | ⚪ | Color input silently discards invalid hex; date segments clamp without message | PARTIAL | Fixed 2026-11-20 (file removed) — ColorInput announces invalid hex on blur (inline `role="alert"` error, aria wiring, danger tokens; clears on refocus/valid entry/pick). The date-segment clamp stays documented design (no change). |

### Not filed — no verification file

| ID | Verdict | Disposition |
|---|---|---|
| F09-02 | INFIRMED | The stored `migrations` map is merged AFTER the same-version guards (`src/doctype/update.cr:279-282`) — a migrations-free PUT repairs the script in place, pinned by specs (`doctype_update_spec.cr:368`, `migration_retry_spec.cr:74`) and documented (B-301 carry, `doctype-system.md:676-679`). The fix predates the sweep (`4eafe60f`, an ancestor of `1b7bf906`). The observed 422 fits a PUT body that echoed the stored `migrations` map (the guard works as documented; the endpoint is PUT, not PATCH). Residual: the 422 message could hint that omitting the key is safe. |
| F08-03 | INFIRMED | The app toolset is exactly the registry minus `ping` (23 entries → 22) — what the docs say; no doc states a count. |
| F01-03 | UNVERIFIABLE | No static auto-close path in the tour; an early-step close is session-only by documented design and matches the symptom (gone now, back on reload); the click-through scrim makes accidental dismissal plausible. |
| F04-04 | UNVERIFIABLE | One-off browser network blip; no abort/timeout logic exists in the fetch layer that could produce it on a 200. |
| F05-04 | UNVERIFIABLE (external) | The port mapping lives in the external QA override; this repo publishes no Keycloak ports and its recipe states the container port. |
| F09-05 | UNVERIFIABLE (environment) | Docker runtime behavior; nothing in the repo depends on `docker cp` from volumes. |
| F04-05 | Duplicate | Same mechanism as F01-04; verified there. |
| F03-01 | Brief drift | The Lua surface is `util.json_encode` / `util.json_decode` (plus `math.clamp`); docs and site-docs match the code. |
| F03-02 | Not a defect | All compute failures are documented 422s naming the script line; a learnability observation. Cosmetic residual: telemetry records `status: 500` for `compute_runtime` while HTTP answers 422. |
| F03-03 | By design | Stored MIME comes from magic bytes, never the client header (`doc/backend/artifact.md:186-187`); consistent bytes; no doc promises refusal. |
| F05-02 | By design | An empty email-domain allowlist means link-based login only, documented; the reason rides the `oidc_denied` audit event, the browser gets one generic error (anti-enumeration). HEAD delta (`abe21a28`) changed JIT role sourcing, not the allowlist gate. |
| F05-03 | By design | The documented list contract includes `revoked_at`; the UI and its stories pin the Revoked badge — audit history by design. |
| F06-02 | By design | App-key refusals answer one uniform 401 (anti-enumeration, documented in code); the specific reason rides the WARN line + span tag. |
| F07-01 | By design + brief drift | The event vocabulary is the documented closed set (`Event::WEBHOOK_EVENT_NAMES`; the 422 enumerates it, B-152). |
| F07-04 | Brief drift | All four grammar facts verified: `iam.Roles` shape (structured `permissions` objects, `visible_tags`), `items=` pagination (`limit=` answers 422 Unknown parameter, B-279), hooks declare `source: {domain, doc_type}` (no `source_doctype` key; the qualified form is a webhook-field/storage detail), hooks are a top-level `core.Domain` array. Harness note verified: `e2e/docker/backend-entrypoint.sh:24` runs `db_reset` on every container start — the F07 brief should carry the F06-style override warning. |
| F08-04 | Brief drift | No conversation `title` field exists anywhere (table, model, routes, drivers); unknown create keys are tolerated silently; the documented create contract is `{context?, enabled_tools?, language?}`. A strict-keys 422 would be a design decision. |
| F08-07 | By design | `@facetapp/chat` ships an ESM build with `svelte` external + peer dependency — a bundler is required by contract; no doc claims a drop-in `<script>` embed; npm publication explicitly pending. |
| F09-04 | By design | The `route` label is the first path segment from a fixed allow-list, collapsing to `other` — a documented cardinality decision (`metrics.md:53-59`). |
| F10-03 | Brief drift | The kanban is documented read-only ("no drag and drop") with move groundwork; cards are not draggable at all — the brief's step 8 describes a feature that does not exist. |
| F10-04 | Brief drift | No `conditional` node type; conditional rendering exists as the documented `if` node; the unknown-type warning is intended behavior. |
| F10-07 | Brief drift / feature request | "Pin current view" feeds dashboard cards only; no default-view concept exists anywhere (`is_default`/`default_view`: zero matches in `src/`); no doc promises one. |

### Retracted by the sweep

Seven observations were retracted by the sweep itself before verification (payload/harness mistakes, honestly reported): F10 compound-create "422 field ''" (payload lacked `$content`), F10 mixed-subtitle empty label (a stale patch), F10 stale PATCH response body (0/10), F01 ref-drop, F02 dup-import/meta.more, F03 backlinks, F05 stuck-loading. No files.

## Sweep 2026-11-19 — naive F01–F10 (verified against `a8520dee`)

Eighth naive full F-series pass. The sweep ran on another machine; the detailed repro evidence and the consolidated report live with that session. Verification here is source review, read-only, against `a8520dee` and HEAD `08f3d3e7` — three commits landed between the sweep and verification (`09e6167b`, `dac2219f`, `08f3d3e7`) and fixed two findings. 27 findings were verifiable from the in-repo copy of the report: 18 got a file (10 CONFIRMED, 8 PARTIAL), 9 were INFIRMED. 13 findings carried no repro detail in the in-repo copy and were not verified. F-IDs are provisional; triage to B-IDs is not done.

Headline: **B-271 is closed** (F04 replication containment 4/4 — replicate-from-tagged-plaintext refused at authoring). Two blockers were filed: F08-A (assistant conversation permanently unusable from turn 4 — fixed in `09e6167b` during verification, one residual open) and F10-A (table crash on a collection reference that repeats a target — still live).

### Filed — resolved 2026-11-19 (files removed)

| ID | Sev | Finding | Verdict | Disposition |
|---|---|---|---|---|
| F02-A | 🟠 | Date widgets silently drop typed input (re-observation of F02-01) | PARTIAL | Fixed — the datetime-granularity `commit()` no longer emits `''` on a partial edit: the last committed value holds, a complete date with an untouched time commits midnight (the calendar day-pick precedent), and only the explicit `Clear` emits `''`. Three stories pin it; `datetime-picker.md` states the shipped rule. Date-only and `PeriodPicker` unchanged. |
| F07-A | 🟠 | Global audit list skips the app-grant ceiling | CONFIRMED | Fixed — the global branch of `Audit::List.authorize` denies app-scoped callers with `403` before the role check — a grant names one concrete domain, so no grant can cover the cross-domain view, and the rows' `arguments` would leak. Document history keeps the `ReadEnforcer` ceiling. `app-system.md` corrected; `audit.md` and `rbac.md` state the rule. Spec: `spec/audit/list_app_grant_spec.cr`. |
| F07-F | ⚪ | SDK realtime refusal surfaces only as an unobserved promise rejection | PARTIAL | Fixed — `RealtimeHandle.onRefusal(handler)` fires once per refusal (in-band error frame or terminal close) with the same error the `subscribe()` promise rejects; promise behavior unchanged, `socket.onerror` stays unwired. README quick-start wires it; the type is re-exported from the SDK index. 6 tests in `packages/sdk/test/realtime.test.ts`. |
| F08-A | 🔴 | Workspace conversation permanently unusable from turn 4 (`Index out of bounds`) | CONFIRMED | Fixed — main fix in `09e6167b`; the residual closed in this run: the persisted slice anchors on the turn's own messages (last user message for the clean paths, clamped pre-ask boundary for the provider-drop and checkpoint paths), so a finite `max_history` trim can no longer mis-align it. A spec pins finite `max_history` with a mid-turn trim and resume; `agent-conversations.md` and `assistant.md` describe the anchors. Residual (upstream, agent-cr): the trim can orphan a trailing tool message, and its error-path rollback pops from the tail. |
| F08-C | 🟡 | Failed turns write no `assistant_usage` row; no usage surface for an unlimited budget | PARTIAL | Closed — (a) was fixed in `09e6167b` (capped turns bill the estimate). (b) stays by design: an unlimited account renders no meter; a used-count display is a product decision, declined in this run. No change. |
| F09-A | 🟠 | Thrown Lua error in a migration function 500s the read path and writes no `migration_error` marker | CONFIRMED | Fixed — `Document::Migrate.call` rescues `ScriptContext::Error` (thrown Lua runtime errors and script-load failures) into a `422` `ServiceError`, so the read and list marker branches write `migration_error` and serve stale data — `migrate-retry` and the maintenance counter see the row. `schema-migration.md` matches the behavior. Specs pin the marker, the stale read, and the 422 at the `Migrate.call` boundary. |
| F09-B | 🟠 | Seeded `editor` authors live schema through `POST /Api/core/Domain/import` | PARTIAL | Docs — `portable-domains.md` §Access control now states that a fresh import creates a live domain in one step under the same `create core.Domain` gate as the draft door, and that the importer does not become a domain editor. No code change — the behavior is documented design. The hardening options in the file stay open for a design decision. |
| F10-A | 🔴 | Table listing crashes on a collection reference that repeats a target; Retry re-crashes | CONFIRMED | Fixed — both halves: `referenceTokens` dedupes (a repeated token renders one capsule — no render can throw), and `ReferenceType#validate_collection` rejects a repeated target at the write doors with `422 duplicate_reference_target`. Story pins the dedupe (a revert was shown to reproduce the crash); specs pin the rejection. Residual: a Lua action's collection-reference arg bypasses the field-type gate. |
| F10-B | 🟠 | Form submits field keys the definition does not declare → whole save 422 | PARTIAL | No change — fixed in `09e6167b` (persisted-baseline diff); the residual changed-unknown-key pass-through is deliberate, and the authoring gate now rejects the template-binding trigger. |
| F10-C | 🟠 | Header chips render the raw reference token (B-132) | CONFIRMED | Fixed — the chip loop dispatches per type: enum labels unchanged; references render one hydrated badge per token through the header's label path; other objects route through the `toDisplayText` pipeline (money renders, secret drops) — never `String(v)`. The each key moved to index (hydrated labels can collide). Stories pin reference, collection, and money chips; `document-view.md` reconciled. |
| F10-D | 🟠 | Money chip renders `[object Object]` | CONFIRMED | Fixed — same dispatch as F10-C: a money chip renders `EUR 12.50`-style through the established pipeline; `[object Object]` is unreachable. Story pins it. |
| F10-E | 🟠 | Computed field: authoring gate and runtime disagree → every write 422 `compute_runtime` (B-274 family) | PARTIAL | Fixed — `validate_script` rejects a doctype that declares computed fields with no script (422, mirroring the `actions`/`migrations` gates), and `Doctype::Check` emits a `:compute` warning for live definitions published before the gate. The silently-inert delete-on-every-write is unreachable. Specs in the validation, check, and authoring suites; `doctype-system.md` lists the rules. |
| F10-F | 🟠 | No hydrated `array`-over-reference pattern outside the table | CONFIRMED | Fixed — `DvtValue` passes a default capsule-per-token `referenceCell` to `FieldValue` whenever it holds a driver, and `DvtField` threads the driver — DVT rows, the peek drawer, and kanban card bodies hydrate arrays; the relation table's typed cells thread it too. `document-view.md`'s plain-text carve-out is removed; stories pin the hydrated arrays and the driver-less degradation. The fallback form input stays unchanged by design. |
| F10-G | 🟡 | No-op Save rewrites `longtext` (`- a` → `* a\n`) | PARTIAL | Fixed — the editor compares every serialization against the seeded baseline's parsed document (`isSameMarkdownDocument`, a `marked`-lexer fingerprint): a pure re-serialization (space + backspace, a slash-menu insert elsewhere) never fires `onchange`, and a full undo realigns the values bag to the exact stored string — `- a` survives a type+undo save. 17 unit cases plus a story pin it. |
| F10-H | 🟡 | Every relation node double-fetches | INFIRMED | One HTTP request per target: the relation-table hydration effect re-runs, but the show cache's in-flight dedup joins the waves and `tableSeq` discards the stale one. A code smell only. |
| F10-I | 🟡 | `field.label` not interpolated | INFIRMED | No doc promises it: the DVT grammar is `$field`-only (`template-resolve.ts:253`); `{{ }}` belongs to display_name/search/calendar engines, none of which document a `.label` accessor. At most a doc note (⚪). |
| F10-J | 🟡 | Zero/small-value collapse | CONFIRMED | Fixed — the duration branch gates on `Number.isFinite(n)` only — `0` renders `0s`, negatives clamp inside `Duration`; the blank dash is reserved for non-numeric values. Stories pin zero and negative. |
| F10-K | 🟡 | Identity leaks into breadcrumb | CONFIRMED | Fixed — the id crumb resolves `display_name ?? id` through a layout-owned label cache (one cached `show()` per document navigation) and falls back to the raw id when unknown; the crumb `title` always carries the raw id for copyability. `navCrumbs.spec.ts` pins the resolved label, the fallback, and the `new`-route exclusion. Residual: an in-place rename leaves the crumb stale until the next navigation. |
| F10-L | 🟡 | Client disconnect logged as a server error | PARTIAL | Fixed — all three disconnect guards (`guarded_write`, `Session#run`'s IO arm, the stream route's close guard) also rescue `OpenSSL::SSL::Error` as a DEBUG transport fact — no ERROR line, no spurious 500 entry. A spec injects a real TLS error through `guarded_write`; the two backstop arms are widened without a spec (unreachable through the public API). |
| F10-M | ⚪ | Duplicate relation columns not caught by `/check` | CONFIRMED | Fixed — `check_relation_columns` tracks seen keys and emits a `:warning` naming the duplicate ("the renderer collapses duplicates to the first occurrence"). Spec pins it; `doctype-system.md` lists the rule. Collection-view columns keep their interactive-only guard (no stored-config validator exists). |

### Not filed — no verification file

| ID | Verdict | Disposition |
|---|---|---|
| F02-B | INFIRMED (as a defect) | By design — the filters opt-in rule is documented (`doctype-system.md` → Filter capabilities; "A field without a `filters` capability is not filterable"); same finding as 2026-11-18 F02-03. HEAD added the capability vocabulary (`src/doctype/filter_capability.cr`, editor checkboxes). |
| F05-B | INFIRMED | Mechanism misidentified: Kemal's radix matcher treats the trailing slash as the exact route, so `DELETE /Api/iam/sessions/` dispatches to the documented bulk endpoint (B-140) — the caller's own sessions minus the serving one, CSRF-checked. The per-session handler refuses an empty id with 422; no blanket WHERE exists. Residual: app-wide trailing-slash URL hygiene (⚪). |
| F06-A | INFIRMED | Dismissal persists server-side per account (`core.show_welcome`, `settings.svelte.ts` → `saveShowWelcome`) at both commits. Early exit (Esc/×/scrim) is session-only by documented design (`doc/frontend/settings.md` → Welcome tour). `dac2219f` refined the interaction only. |
| F06-D | INFIRMED (as a defect) | `coalesce_window_minutes` is documented file-config (`doc/backend/mutation.md`); by design. |
| F08-D | INFIRMED | The prefix split is the documented architecture: per-kind create routes bake in context and tool sets; stream/turns/cancel/usage are shared surfaces (`doc/packages/chat.md`, `src/assistant/app/routes.cr:24-27`). |
| F09-C | INFIRMED | The zip is fully built and stored before any response exists; the stream carries an exact `Content-Length`, so truncation is client-detectable; build failures answer 404/422/500. Residual: no checksum/ETag header for corrupted-in-storage bytes (⚪). |
| F09-E | INFIRMED (premise) | The requirement is documented at both commits: `doc/backend/openapi.md:40-44` ("The gate"). |
| F10-N/O, F03-A, F05-A, F05-C/D/E, F06-B/C, F07-B/C, F08-B, F08-E/F, F09-D, F09-G | UNVERIFIABLE | No repro detail in the in-repo copy of the report; the detailed findings live with the sweep session on another machine. |

## Sweep 2026-11-18 — naive F01–F10 (verified against `c782d339`)

Ten cold-start persona scenarios, browser-first, no consultation of the findings register. 46 findings were filed; 39 verified against the source and got a file (27 CONFIRMED, 12 PARTIAL). 7 got no file (5 INFIRMED, 2 UNVERIFIABLE). Six parallel source-review agents plus direct review produced the verdicts.

### Filed — resolved 2026-11-19 (files removed)

| ID | Sev | Finding | Verdict | Disposition |
|---|---|---|---|---|
| F01-01 | 🟡 | Builder crashes renaming a field key onto an existing key | CONFIRMED | Fixed — `DoctypeFieldEditor` blocks the duplicate-key write (mirrors the enum guard). Stories pin it. |
| F01-02 | ⚪ | No-op Save shows "Save failed — No changes detected"; no dirty indicator | CONFIRMED | Fixed — the editor intercepts the backend 422 and flashes the neutral saved state. Residual: the message match is textual (no machine code); a literal "No changes to save" state would need a new status + key. |
| F01-03 | ⚪ | Change-password consumes the token before the response lands; retry misleads | CONFIRMED | Fixed — a 300 s `pwd_change:used:{token}` marker answers a distinct 401 ("the change succeeded") on retry; the 5-attempt consume and the planned burn stay. |
| F02-01 | 🟠 | Date-family form widgets silently drop typed values | PARTIAL | Fixed — fill-style entry distributes digits across segments (anchored at the delivered segment, overflows into full ones); the fallback form already rendered the pickers at this commit (ticket item stale). Stories pin both. |
| F02-02 | 🟡 | Invisible welcome overlay intercepts navigation | CONFIRMED | Fixed — the scrim passes clicks through and the Bits UI body lock is opted out; a click closes the tour and reaches its target. Residual: the page can scroll behind the tour; the `!important` override pins to bits-ui 2.18.1 internals. |
| F02-03 | 🟡 | REST-authored fields carry no `filters` capability | PARTIAL | Docs — `doctype-system.md` → Filter capabilities states the opt-in rule, the empty operator set, and the 422; `http-layer.md` cross-links. The "Builder adds defaults" half was infirmed. |
| F02-04 | 🟠 | Doctypes without a `search` template never join cross-doctype search | PARTIAL | Fixed — the doctype editor fetches `/check` on the General tab and renders the `:info` notices inline (the endpoint had no frontend client at all). The skip itself stays by design. |
| F02-06 | ⚪ | PATCH response carries no ETag | CONFIRMED | Fixed — every `write_result` branch (create, compound create, action, update) and the doctype PUT emit the same `state` validator; specs pin header == `meta.mid` == the next GET. |
| F02-07 | ⚪ | "Recently viewed" keeps deleted docs | CONFIRMED | Fixed — the dashboard chips prune on 404/410 label-resolve failure, reusing `removeRecentDocument` (the palette's rule). Story pins it. |
| F03-01 | 🟡 | Fallback form renders every editable declared field | PARTIAL | By design — four filters apply and system columns never render; the remedy is a `kind: form` view. `doc/frontend/document-view.md` now states the selection rule. |
| F03-02 | ⚪ | `compute` rejected on any type but `data` | CONFIRMED | By design (B-274) — the 422 names the remedy; no change. |
| F03-03 | ⚪ | `{{ id }}` unavailable in display_name/search templates | CONFIRMED | By design, documented (`templating.md` → Binding rules); a bindable id token would be a grammar extension, not a fix. |
| F03-04 | ⚪ | Sidecars must be declared before comments/attachments exist | CONFIRMED | By design — the 404 names the segment and the tool error names the declared segments; documented contract. |
| F03-05 | ⚪ | Attachment `file` wants a bare ULID, not the artifact URN | CONFIRMED | By design — the 422 names the exact shape; the URN is the longtext link form only; no doc claims otherwise. |
| F04-01 | 🟠 | `pay`-tagged field escapes its tag through `replicate` — B-271 re-verified | CONFIRMED | Fixed (B-271) — new hard invariant: the replica field's tags must carry every source-field tag (resolved against `Grants::DEFAULT_TAG`); enforced at create, update, import, and publish; mirrored as a `/check` `:replication` warning (drift backstop). Residual: the runtime registry does not fail closed on a later producer-side tag addition. |
| F04-02 | ⚪ | Role that cannot read a referenced doctype cannot save the edit form | PARTIAL | Fixed — `buildFormPatch` now diffs against the persisted content (minimal patches): an untouched save emits an empty patch, so untouched references and Lua-guarded immutable fields (`iam.Roles.name`, `app.App.slug`) no longer ride along. The read-the-reference-need stays for genuinely edited references. |
| F04-03 | 🟡 | `PUT /Api/core/DocType` accepts a `replicate` with a missing source field | CONFIRMED | By design (B-164) + docs — `replication.md` states the write doors run only the hard invariants and `/check` carries the advisory. |
| F04-04 | ⚪ | `credential-states` silently ignores a comma-joined `id` | CONFIRMED | Fixed — values split on comma per the query list grammar; empties still refused. Spec covers mixed forms. |
| F04-07 | ⚪ | Unreadable reference renders raw id + warning | CONFIRMED | By design — the Capsule contract is pinned by stories and the message already names access and deletion. |
| F05-01 | ⚪ | Typo'd auth route answers 405/403 instead of 404 | PARTIAL | By design — 405 is the spec-tested B-175 contract, 403 is the fail-closed posture; a typo'd path answers 404. |
| F05-02 | ⚪ | `identifier.template` rejection has no grammar hint | PARTIAL | Fixed — the unknown-variable message names `{year}/{month}/{day}` and the no-`#` message names the counter rule + doc pointer. |
| F06-01 | ⚪ | Documented `arguments._reason` for Lua writes is never written | CONFIRMED | Docs — `lua-engine.md` now names the typed `cause_source`/`cause_name`/`cause_parent` columns. |
| F07-01 | 🟠 | Hooks receive `ctx.event.content` with only `{id}` | CONFIRMED | Fixed — the handler loads the live body at delivery (one read per fire), then applies the granted-tags projection; id-only frame stays for missing/tombstoned sources and opt-in events pass through verbatim. `hooks.md` updated. |
| F07-02 | ⚪ | `/Edge/HostAsk` accepts non-exact host values | CONFIRMED | Fixed — the normalizer strips one trailing dot (matches the webhook check); the approve-on-normalized contract stays as documented. |
| F07-03 | ⚪ | Wrong error code named for a private JWK member | PARTIAL | Docs — `oauth.md` names `private_key_in_jwk` (source + pinned spec) and notes RFC 9449's general `invalid_dpop_proof`. |
| F07-04 | ⚪ | SDK README shows `facet.can(...)` as synchronous | CONFIRMED | Docs — the README awaits `can` and `scopes`. |
| F07-05 | ⚪ | CORS preflight allow-lists no write verbs | PARTIAL | Fixed — `PATCH, PUT, DELETE` added to the allow-list (POST was already there). Spec pins all seven verbs. |
| F07-06 | ⚪ | Out-of-grant list: 200/empty on `core.DocType`, 403 elsewhere | PARTIAL | By design (B-86), documented; the filed "200/empty" premise was wrong — the answer is grant-filtered, not empty. |
| F08-01 | 🟡 | Prompt injection drives assistant tool choice; only RBAC stops it | CONFIRMED | Held — architectural. Containment (RefusalGuard, TerminalRefusalStop, max_tool_iterations) exists; the tool-choice layer has no injection resistance. Needs a design decision. |
| F09-01 | 🟠 | Two write routes answer 500 for a non-object JSON body | CONFIRMED | Fixed — object-shape gates on the doctype PUT and all three rollback routes (422, sibling message); a non-string `scope` also answers the 422 now. |
| F09-02 | ⚪ | CLI prints an unrelated stale-index line on export/import/seed | CONFIRMED | Fixed — the teardown's retry pass runs quiet; the explicit `indexes retry` command keeps its output; the wrong comments are corrected. |
| F10-01 | 🟠 | Array-of-reference renders raw JSON tokens on every surface | CONFIRMED | Fixed (table surface) — `cellKind` classifies the spelling through the reference kind and `FieldValue` flattens `items.doctype`, so table cells hydrate capsules. Residual: DVT rows / peek / kanban card bodies lack a driver, so they render the `', '`-joined token fallback, not capsules (`DvtValue` would need a `referenceCell` snippet); the fallback form input is unchanged. |
| F10-02 | 🟠 | Filed: definition read path drops `items.doctype` | PARTIAL | Held — the read path is clean at this commit and the authoring-door loss is unreproduced; the byte-level round-trip gate is a feature decision. |
| F10-03 | 🟡 | Int64 beyond 2^53 renders wrong in the table | CONFIRMED | Fixed — `parseLosslessJson` quotes unsafe integer literals in the DataSource response path (no dependency); 19 vitest cases. Bigints arrive as exact strings (string-semantic sorting). |
| F10-04 | 🟡 | Kanban card enum chip ignores the declared label | CONFIRMED | Fixed — `DvtHeader` (status + categorical chips) and `FieldValue`'s enum branch resolve the declared label first. |
| F10-05 | ⚪ | Enum labels equal to the humanized key dropped from the definition | PARTIAL | By design — the serialization fixed point is documented and lossless; the visible defect is F10-06, fixed. |
| F10-06 | ⚪ | Kanban lane headers show the raw enum key | CONFIRMED | Fixed — `lanesFromEnum` humanizes the fallback key; `doc/frontend/kanban.md` updated. |
| F10-07 | ⚪ | Relation-table boolean toggle aria-name "Toggle undefined" | CONFIRMED | Fixed — `col.label ?? col.key` on the aria and the `<th>`. |
| F10-09 | ⚪ | Malformed relation `source` renders "Forbidden" | CONFIRMED | Fixed — `DvtRelation` validates the source shape and renders a local config-error message (`doc_relation_source_invalid`, en + fr) instead of firing the request. |

### Not filed — no verification file

| ID | Verdict | Disposition |
|---|---|---|
| F01-04 | INFIRMED | No doc says schematic positions are ephemeral; `doc/frontend/schematic.md:111` states they persist on `core.SchematicLayout`, and the code implements it. Sweep artifact or stale external brief. |
| F02-05 | INFIRMED | The mechanism is inverted: rows are not focusable and a click never arms the selection — Enter works only after keyboard navigation (`j`/`k`/arrows), never after a mouse click. The real gap (help label promises a shortcut mouse users cannot reach) is recorded here for triage. |
| F02-08 | UNVERIFIABLE | The "brief" lives in the external QA repo; the in-repo operator tables match the source. |
| F04-05 | INFIRMED | Role election re-reads roles per request (`src/iam/refresh.cr:88-92`); `/Api/iam/me` returns fresh `available_roles`. No re-login needed. |
| F04-06 | INFIRMED | The generic `POST /Api/:domain/:doctype` route serves `iam.Roles` create; the payload clears the gates for an authorized caller. |
| F06-02 | INFIRMED | `GET /Api/SystemSettings` returns `{values, pinned}` as documented (`src/system_settings/routes.cr:67-69`). |
| F10-08 | UNVERIFIABLE | The sidecar attachment upload chain is fully wired in source; "zero requests" needs a browser repro. The sweep itself flagged manual confirmation before triage. |

## Sweep 2026-11-17 — naive F-series (verified against `2c2086e8`)

Each file recorded the finding as filed and its verification against envelope commit `2c2086e8` (subagent source review, 2026-11-18, read-only). F-IDs are provisional; triage to B-IDs is not done. The source scenario evidence lives in the external QA repo (`scenarios/feature-coverage/F0x-*/evidence/naive-2026-11-17/`).

Verdict meaning:

- **CONFIRMED** — code and docs match the claim.
- **PARTIAL** — the core holds; named parts are corrected or infirmed.
- **INFIRMED** — the claim does not hold at this commit.
- **UNVERIFIABLE** — the target file lives outside this repo.

## Summary

40 findings were filed in the 2026-11-17 sweep; 27 were resolved in this repo on 2026-11-18 and 13 belonged to the external QA repo (their files were removed the same day). This folder held no open findings from that sweep.

The 2026-11-18 sweep filed 39 findings. All 39 were resolved on 2026-11-19: 27 fixed in code or docs, 9 closed as by-design (documented above in the sweep table), 3 held for a design decision (F04-02 reference re-submission on save, F08-01 assistant tool-choice injection resistance, F10-02 definition round-trip gate). Their files were removed after the resolution run; the dispositions live in the sweep table. Validation: full backend suite (7409 examples) green, frontend vitest server (1852) and storybook (1298) green, `bin/ameba` and `pnpm check` clean.

The 2026-11-19 sweep filed 18 findings. At HEAD `08f3d3e7`: 14 open (1 blocker — F10-A), 3 fixed in `09e6167b` during verification (F08-A, F08-C part a, F10-B), 1 no-change-by-design (F09-B). All 18 were resolved on 2026-11-19 in one sub-agent run: 14 fixed in code (F02-A, F07-A, F07-F, F08-A residual, F09-A, F10-A, F10-C, F10-D, F10-E, F10-F, F10-G, F10-J, F10-K, F10-L, F10-M), 1 docs-only (F09-B), 2 no-change (F08-C part b, F10-B residual — documented design). The verification files were removed after the resolution run; the dispositions live in the sweep table. Validation: targeted specs per fix (the full backend suite was not run, by instruction), `bin/ameba` 1051 inspected / 0 failures, `make check` clean, `pnpm check` 0 errors, and the touched vitest `server` specs and story files green.

The 2026-11-20 sweep (commit `1b7bf906`) filed 31 findings, open in this folder pending triage: 23 CONFIRMED, 8 PARTIAL. 21 findings were not filed (2 INFIRMED — including the F09-02 headline, 4 UNVERIFIABLE, 1 duplicate, 14 documented design or brief drift), and the sweep retracted 7 of its own observations before verification. No resolution run has happened for this sweep yet.

## External — handed to the QA repo (files removed)

| ID | Class | Disposition |
|---|---|---|
| F04-02 | brief-drift | Secret "reveal affordance" — platform matches its docs; the brief step is stale. |
| F05-01 | harness | `stack/oidc.override.yml` silent mount — fixed during the run; UNVERIFIABLE here. |
| F05-02 | harness | Keycloak realm redirect wildcard — fixed during the run; UNVERIFIABLE here. |
| F05-03 | brief-drift | User-issued key channel is `api_key`, not `app_api_key`; the brief is wrong. |
| F05-04 | brief-drift | The seed has no `user` role; the brief's premise is wrong (422 is correct). |
| F06-01 | harness + brief | The e2e entrypoint reseeds on every start; the brief must boot the config variant before arranging. |
| F06-03 | brief-drift | Hook cause is `hook_event`, no `system` channel; the brief vocabulary is wrong. |
| F07-03 | brief-drift | Hosted apps serve anonymous requests with 200 by design; the brief expects a login redirect. |
| F07-04 | brief-drift | Real paths are `/Edge/HostAsk` and `/OAuth/*`; the brief names lowercase twins. |
| F07-06 | brief-drift | CLI login is PKCE-only, not "PKCE + DPoP". |
| F08-04 | brief-drift | `/Api/_mcp/*`, `/Api/assistant/usage`, stream field `content`, `PATCH /Api/app/App/:id`; the brief paths are stale. |
| F09-01 | brief-drift | `/Api/…` case, `POST /Api/core/Domain/:id/export`, definitions-only bundle import; the brief paths are stale. |
| F09 stack note | harness | The persist-entrypoint override skips the baseline boot; a persist boot needs `facet migrate` (or one stock boot first) on a fresh volume. |

## Resolved in this repo 2026-11-18 (files removed)

The first 16 rows date from the morning review. The F05-06 / F08-02 / F07-05 / F09-04 rows were implemented the same day (targeted specs and compile/validate gates only — the full suite was not run, by instruction).

### Fixed in code or docs

| ID | Fix |
|---|---|
| F08-01 | The coalescing fold scopes `harness.bypass_projection_triggers` to the fold and restores the previous value, so a same-transaction `delete`/`create` still fires its projection trigger. Regression specs in `spec/document/coalesce_spec.cr`. |
| F04-01 | Field visibility runs before the pair-consistency check: a role-invisible `field` answers 403, never a 422 that names it. Spec in `spec/document/list_spec.cr`. |
| F07-08 | The response stays the generic 401; the server log now carries the DPoP error code and cause for every refusal branch in `verify_dpop_for_payload?`. |
| F07-01 | CLI `createApp` posts `{name, slug}`; real payload test in `packages/cli/test/api.test.ts`. |
| F07-02 | CLI version `0.0.3`; README pin updated. |
| F07-07 | `RBAC::Validator` refuses a role line with `action: "write"` and names `create/update`. |
| F06-02 | `ApiKeys.issue` refuses (422, with the remedy) when the app's grants do not intersect the service role. |
| F02-01 | The empty-allowed-list 422 names the fix (`filters:` capability); the Builder skill corpus teaches `filters:` instead of the discarded `operators:`. Residual: `filters` stays opt-in, and `Doctype::Check` does not validate a view's `group_by` against field capabilities. |
| F02-02 | The Views tab empty-state note follows the `canWrite` gate. |
| F02-04 | `DoctypeViewsTab` calls `onsaved`, so the Views badge follows a save without a reload. |
| F04-03 | The dashboard quick links carry the gate their destination applies. |
| F01-03 | The welcome tour final step has a Done button that runs the same close intent as Esc. |
| F03-02 | `doc/backend/http-layer.md` states that `mid` is not a document handle. |
| F09-03 | `doc/backend/schema-migration.md` states the silent-no-op failure mode. Residual: no authoring-time warning for a function that never touches `ctx.root`. |
| F01-02 | Side note only: the stale `count` example in `doc/backend/http-layer.md` is corrected. |
| F08-03 | `doc/backend/agent-tools.md` states the `list_domains` stance. Behaviour is unchanged. |
| F05-06 | The last-admin MFA recovery runbook is in `doc/backend/iam.md`: `facet accounts:create <new-email> --role admin`, self-enroll, then `POST /Api/iam/mfa/disable` on the locked account. A live session lets the locked admin self-disable. |
| F08-02 | `Assistant::Stream::TerminalRefusalStop` (mounted per turn in `Session#build_agent`) cancels the response when the model repeats a call the refusal guard already answered with a terminal envelope; the model still gets one provider call to comply, and the turn ends on the standard cancelled path. Specs in `spec/assistant/stream/terminal_refusal_stop_spec.cr` and `spec/assistant/refusal_guard_spec.cr`; behaviour documented in `doc/backend/assistant.md`. |
| F07-05 | Both edges (`caddy/Caddyfile`, `docker/Caddyfile.prod`) answer a mutation verb under a lowercase namespace twin with a 404 JSON that names the case rule. Browser GETs and OPTIONS keep falling through, so domain pages and CORS preflights are unchanged; the lowercase-as-domain-id contract stands. Noted in `doc/frontend/workflow.md`. |
| F09-04 | The three e2e Dockerfiles carry the release OCI label set (`VERSION`/`REVISION` build args, throwaway defaults `dev`/`unknown`); `e2e/compose.yml` passes the args. The release Dockerfile comment now describes the shared-label state. |

### Closed — infirmed or by design

| ID | Reason |
|---|---|
| F01-01 | INFIRMED — the timezone picker lists every IANA zone; no code path yields a single option. |
| F03-03 | INFIRMED — `lua-engine.md` already grants the JSON helpers to every script context. |
| F05-05 | INFIRMED — the lockout TTL does not slide; the fixed window, keys, and runbook are documented (`iam.md:378-421`). The residual is the cycling pattern, an artifact of repeated probes. |
| F08-05 | INFIRMED — the turn knobs are file-config and never appear in the settings view. |
| F09-02 | Done — the read-gate sentence already exists (`portable-domains.md:122-129`), and both risk claims were infirmed: the HTTP export is definition-only. |
| F02-03 | By design — authorization precedes existence, and the 403 carries no path hint; non-disclosure as designed. |
| F03-01 | Done — the 405 carries a JSON body and the `Allow` header, pinned by `spec/http/method_not_allowed_body_spec.cr` (B-175). The route-pointer idea stays declined. |
