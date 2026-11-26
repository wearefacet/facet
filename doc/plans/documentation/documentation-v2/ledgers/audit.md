# Content audit (WP 10)

One row per current English page (`site-docs/src/content/docs/`, 144 pages).
Columns per `10-wp-inventory-audit.md`: Words (body, front-matter excluded —
includes tables and code, so counts read high), Type (guess), Layer
(L1 orientation / L2 task / L3 depth), Engine words in lead (first paragraph
after front-matter; list from `01-voice-and-vibe.md` §5.2), Accuracy
spot-check (three claims per page against the code; ✅ verified, ❌ false —
see `discrepancies.md`), Notes (duplication, missing prerequisites, dead
ends). Audit ran at commit `8fb69df`, 2026-11-26. Spot-checks were done from
source (no running instance); UI-step claims were verified from code and
message files.

## Summary

**The ten worst pages for a newcomer** (deepest-first, by layer misplaced,
lead jargon, size, and staleness):

1. `start/security-governance.md` — L3 security depth in the Discover tab;
   carries the false 404-denial claim (discrepancy #1).
2. `concepts/authorization-enforcement.md` — enforcer-first L3; same false
   claim; no L1 sibling exists yet.
3. `concepts/auth-contexts.md` — engine terms in the lead ("auth context",
   "elected role"); the channel model before any plain-words page.
4. `build/named-scopes.md` — 1587 words, syntax-first how-to at L3 depth;
   pairs with `govern/row-scopes.md` across tabs.
5. `apps/rest-api.md` — 2014 words; a grammar reference posing as a how-to
   (correct, but the wrong type/layer for a task page).
6. `apps/dpop.md` — 1678 words; DPoP ×5 in the lead; crypto detail before the
   OAuth basics page does its job.
7. `apps/agent-tools.md` — 1534 words duplicating the generated
   `reference/agent-tools.md` table plus caps duplicated on `mcp-agents.md`.
8. `govern/roles-permission-lines.md` — 1520 words; permission-line syntax
   before the admin job is clear; overlaps `concepts/roles-levels-authority.md`.
9. `compare/vs-ai-built-apps.md`, `compare/vs-supabase-firebase.md` (and the
   other three compare pages) — 1900–2440 words each; stale TODO links;
   "per document" retention falsehood (#11); unsourceable sizing/pricing
   claims.
10. `concepts/mutation-log.md` + `start/architecture.md` — engine-word leads
    (mutation, projection) and hop-by-hop internals in orientation pages.

**Lead hygiene:** 26 of 144 leads carry engine words (all in `concepts/` and
`apps/`; worst: `apps/dpop.md` 5, `apps/rest-api.md` 3, `concepts/*` 1–2).
The rest of the site keeps engine vocabulary out of leads consistently.

**Duplicated topics** (name the other page; consolidation targets for the
content WPs):

- Retention policy vs tuning: `govern/retention.md` ↔ `operate/retention-tuning.md` (deliberate pair; numbers restated in both).
- Assistant budget/usage: `govern/governing-assistant.md` ↔ `operate/assistant-config.md` — and they contradict each other (discrepancy #6).
- Config hot-key chain: `operate/configuration-files.md` ↔ `operate/system-settings.md`.
- Rate-limit tables: `govern/sessions-tokens-lockouts.md` ↔ `govern/enforcing-mfa.md`.
- Restore codes table: `govern/accounts-lifecycle.md` ↔ `govern/rolling-back.md`.
- View-editor steps: `workspace/lists-filters-views.md` ↔ `build/collection-views.md`.
- Images/topology: `operate/system-requirements.md` ↔ `operate/containers-tls.md`.
- CLI rows: `operate/bootstrap-cli.md` table ↔ `operate/file-storage.md`, `operate/indexes.md`, `govern/sso-oidc.md` (`auth:mode`).
- "See it running" container block: `start/what-is-facet.md` ↔ `tutorials/t1-run-facet.md` ↔ `start/is-facet-right-for-you.md`.
- Minimal app sequence: `apps/index.md` ↔ `apps/how-apps-work.md` (intentional).
- Tool caps: `apps/agent-tools.md` ↔ `apps/mcp-agents.md` ↔ `reference/agent-tools.md`.
- Replication intro: `concepts/domains-and-isolation.md` ↔ `concepts/cross-domain-replication.md` (~30%).
- Session material: `workspace/sign-in-mfa.md` ↔ `workspace/settings-sessions-api-keys.md`.
- Pricing table compressed onto every `compare/*` page.

**Discrepancy count by area** (entries in `discrepancies.md`): start/ 2 (#1
shared with concepts/, #15) · workspace/ 1 (#2) · build/ 1 (#3) · apps/ 2
(#4, #5) · govern/ 1 (#6) · operate/ 2 (#7, #8) · reference/ 3 (#9, #10, #12)
· compare/ 1 (#11) · doc/ concern files 2 (#13, #14). Total 15 entries; 12
are current-site claims, 2 are concern-doc contradictions, 1 is a generated
page drifted from its generator.

**Verification coverage:** ~430 spot-checked claims; 17 ❌ (the discrepancies
above), the rest ✅ with `path:line` evidence. Claims the agents could not
verify within budget are listed per batch below under "Unverified" and are
not counted either way.

**Staleness is inert (pre-existing):** 137 of 144 English pages carry a
`verified_at` SHA from the private history, which this squashed repository
cannot resolve (`check-coverage.mjs`: 0 stale, 137 unresolvable, 1 without a
marker — `index.mdx`). The report cannot fire until pages are re-verified
with reachable SHAs; the v2 rewrites set fresh `verified_at` values per the
contract, which fixes this page by page. No site change in WP 10.

---

## Batch A — start/, tutorials/, concepts/, landing (25 pages)

| Page | Words | Type | Layer | Eng | Spot-check | Notes |
|---|---|---|---|---|---|---|
| index.mdx | 362 | overview | L1 | 0 | ✅ nav links exist (`start/`,`tutorials/`,`operate/`,`compare/` dirs) ✅ field+row enforcement (doc/backend/rbac.md:296) ✅ append-only log + rollback (doc/backend/mutation.md:333, http-layer.md:55) | GitHub URL unverified (external) |
| start/index.md | 89 | overview | L1 | 0 | ✅ all 6 links exist ✅ "one diagram" (diagrams/871f5719-light.svg in public/diagrams) ✅ "honest limits" (poor-fits table on is-facet-right-for-you) | — |
| start/what-is-facet.md | 703 | explanation | L1 | 0 | ✅ compose.prod.yml + `facet seed:admin` (src/iam/seed_cli.cr:11) ✅ JSONB rows (db/migrations/0001_document_store.sql) ✅ `scripts/import-fixtures` exists | "See it running" block duplicates t1 steps 1–3 and is-facet step 1 (3rd copy of same commands) |
| start/architecture.md | 737 | explanation | L1→L3 | 0 | ✅ route casing `/Api/{domain}/{doctype}`, `/Ws`, `/Healthcheck` (http-layer.md:105, src/websocket/route.cr:66, src/http/auth_handler.cr:65) ✅ anonymous seeded / invalid cred 401 (src/iam/role_store.cr:14, auth_handler.cr:46–60) ✅ retention→one snapshot row (mutation.md:333) | ❌ "platform routes start with an uppercase segment" — `/metrics` is lowercase (discrepancy #15) |
| start/is-facet-right-for-you.md | 752 | explanation | L1 | 0 | ✅ stack-up commands match repo ✅ self-hosted (doc/ops/first-deployment.md:12) ✅ one pinned role for agents (doc/backend/oauth.md:212, rbac.md:411) | docker block is a 2nd copy of t1's |
| start/security-governance.md | 842 | explanation | L3 | 0 | ✅ ES256 pinned (src/iam/token_emitter.cr:20) ✅ bcrypt + AES-256-GCM (src/iam/routes.cr:846, src/secrets/codec.cr:182) ✅ 180d compaction, rollback depth (mutation.md:333) | ❌ 404-denial claim (discrepancy #1); refresh-reuse kill (iam.md:183) and `redacted` block (audit.md:100) verified |
| start/glossary.md | 460 | reference | L1 | 0 | ✅ draft `_` prefix (draft-domains.md:26) ✅ "Referenced by" (BacklinksPanel.stories.svelte:63) ✅ signed envelope (webhook.md:5) | Every term links onward — no dead ends |
| start/install.md | 517 | how-to | L2 | 0 | ✅ `scripts/init` = `db_reset seed:dev` ✅ test PG on 5433 (Makefile:105) ✅ admin@example.tld/admin refused in prod (src/iam/seed.cr:24, src/cli/commands.cr:103) | Crystal "1.21" pin not found in repo (unverified) |
| tutorials/index.md | 101 | overview | L1 | 0 | ✅ 3 links exist ✅ t1 "15 min" matches page ✅ t2/t4 descriptions match content | — |
| tutorials/t1-run-facet.md | 1023 | tutorial | L2 | 0 | ✅ 5 containers/images (docker/compose.prod.yml:13–93) ✅ `/Healthcheck` caps + lowercase 404 (auth_handler.cr:65, docker/Caddyfile.prod:101) ✅ 19 core doctypes (data/seeds/ = 19 dirs incl. core.Currency) | Also verified: OTP shown once (seed_cli.cr:57), 8-char min (routes.cr:828), 7-step tour (WelcomeTour.svelte:25) |
| tutorials/t2-first-domain.md | 1173 | tutorial | L2 | 0 | ✅ draft id `_` prefix (draft-domains.md:26) ✅ publish copy-and-drop + ref relink (draft-domains.md:105,173) ✅ kanban group-by enum/boolean equality (frontend/src/lib/kanban/lanes.ts:24–43) | Also: starter = one card per surface (CollectionViewStarter.svelte:11) |
| tutorials/t4-team-access.md | 1380 | tutorial | L2 | 0 | ✅ `POST /Api/iam/login` + `"cookie":true` (src/iam/routes.cr:52,72) ✅ X-Requested-With CSRF (routes.cr:26) ✅ `scopes` {description,where} on definition (src/doctype/doctype_definition.cr:190,286) | "first role becomes default" ✅ (src/iam/account_cli.cr:277); role-name charset unverified |
| concepts/index.md | 196 | overview | L1 | 0 | ✅ all 12 links exist ✅ descriptions match target pages | — |
| concepts/domains-and-isolation.md | 676 | explanation | L1→L3 | 0 | ✅ `core.Domain` doc + 422 on missing domain (draft-domains.md:7) ✅ widening publish drops active grant (domain-grants.md D6) ✅ one-hop 422 (draft-domains.md:128) | overlaps cross-domain-replication ~30% |
| concepts/documents-doctypes-projections.md | 736 | explanation | L3 | 1 (projection) | ✅ display_name 255 / search 256 (templating.md:23–24) ✅ money `USD 120000` (templating.md:45) ✅ ref→stored label (templating.md:44, src/document/display_name.cr:22) | ETag short-circuit (src/http/rest_routes.cr:195), `doctype:reproject` (reproject_cli.cr:14), restore route (http-layer.md:55) verified |
| concepts/mutation-log.md | 625 | explanation | L3 | 2 (mutation, projection) | ✅ column set incl. channel CHECK + cause_* (0001_document_store.sql:191–208) ✅ 180d compaction (mutation.md:333) ✅ coalesce window, `0` disables (mutation.md:357) | Default 3 min + old-id-404 confirmed |
| concepts/draft-publish.md | 806 | explanation | L3 | 0 | ✅ copy-and-drop, draft docs soft-deleted (draft-domains.md:105,130) ✅ name regex/`_`→422, fresh 409, overwrite live+1 else 422 (:30,109,118,124) ✅ preview token (:265) | replication inert in draft (:73,81); `/check` endpoint (:263) verified |
| concepts/auth-contexts.md | 591 | explanation | L1→L3 | 2 (auth context, elected role) | ✅ `GET /Api/iam/me` (src/iam/routes.cr:186) ✅ `fct_` keys (src/iam/api_key.cr:36) ✅ anonymous seeded / invalid 401 / manifest cut to grant (auth_handler.cr:46–60, routes.cr:326) | ❌ 404-on-denial claim (discrepancy #1) |
| concepts/authorization-enforcement.md | 560 | explanation | L3 | 2 (enforcer ×2) | ✅ scopes→SQL (rbac.md:16 ScopePredicateSql) ✅ metadata gate, absent-not-403 (rbac.md:302,319) ✅ visible_tags all-present, `default` (rbac.md:296) | ❌ "denied single read = 404" + "denied parent = same 404" (discrepancy #1) |
| concepts/roles-levels-authority.md | 681 | explanation | L3 | 0 | ✅ line shape {action,on,scope,except} (rbac.md:14) ✅ level 0–100 required (rbac.md:387,407) ✅ guard table (rbac.md:388–390) | Matches code exactly, incl. same-level lateral assignment |
| concepts/apps-grants-roles.md | 581 | explanation | L3 | 1 (elected role) | ✅ wildcard target 422 (app-system.md:72,88) ✅ write→create+update, `required` rejects (app-system.md:79,80,242) ✅ consent always shown; grant re-resolved per request (oauth.md:212, app-system.md:498) | Tip's log line verified: auth_handler.cr:530–532 |
| concepts/events-delivery.md | 559 | explanation | L3 | 0 | ✅ `no_ack`, no XACK (src/event/subscriber/stream.cr:358, src/replication/handler.cr:43) ✅ `event_loss` on /Healthcheck, 503 on consecutive failures (src/event/loss.cr:18, src/event/consumer_health.cr:20) ✅ reconcile 24h default, < jobs retention (src/webhook/config.cr:48, src/config.cr:471) | replication groups start "0" (src/replication/manager.cr:101), hooks/webhooks "$" (manager.cr:54), lag */10, max_lag gauge — all ✅ |
| concepts/schema-evolution.md | 662 | explanation | L3 | 1 (lazy migration) | ✅ bump exactly +1 (schema-migration.md:127) ✅ hooks not re-run; `migration_error` marker; reads/lists skip (:89–90,208–209) ✅ `doctype:migrate-retry` (src/doctype/migration_retry_cli.cr:14) | list migrates before mask (list.cr:907) |
| concepts/cross-domain-replication.md | 706 | explanation | L3 | 0 | ✅ `replicate` = via + source field (src/replication/binding.cr:20) ✅ replica read-only, no required/unique (replication.md:67–68) ✅ `on_source_delete` default `keep` (src/doctype/field_definition.cr:108) | reentrant skip (handler.cr:28,56); revoke semantics = D8 ✅; overlaps domains-and-isolation |
| concepts/ai-under-callers-rights.md | 638 | explanation | L1→L3 | 1 (auth context) | ✅ `assistant` connectivity gate, re-checked per message (rbac.md:411, src/rbac/role_authority.cr:260) ✅ `assistant` cause_kind exists (0001_document_store.sql:203) ✅ document-tools-only catalogue (agent-tools.md tool table) | MCP writes carry `request` cause inferred, not traced end-to-end |

Batch A unverified: Crystal "1.21" pin; GitHub URLs (external); "backend
applies migrations and seeds on boot" (entrypoint not inspected); t4
role-name charset; sample outputs' exact formats; "context set = one query
per request"; cron keeps running after a failing task; MCP `request` cause
traced end-to-end; concurrent-writer 409 retry path.

## Batch B — workspace/, build/ first half (27 pages)

| Page | Words | Type | Layer | Eng | Spot-check | Notes |
|---|---|---|---|---|---|---|
| workspace/index.md | 239 | overview | L1 | 0 | 12 child links all exist ✅; order matches sidebar order 0–12 ✅; "mark them read" matches notifications page ✅ | — |
| workspace/sign-in-mfa.md | 1022 | how-to | L2 | 0 | min 8-char password ✅ src/iam/password_reset.cr:116; 10 backup codes ✅ src/iam/backup_codes.cr:23; reset link 24 h default ✅ src/iam/config.cr:62 | lockout 5 min verified (login_throttle.cr:38); session expiry duplicated in settings page (linked) |
| workspace/dashboard.md | 811 | how-to | L2 | 0 | `1000+` cap ✅ dashboard/DomainDashboard.svelte:268,281; pinned-view card caption ✅ same; "first six + Show N more" ⚠️ unverified | greeting data consistent with `/Api/iam/me` (src/iam/helpers.cr:169) |
| workspace/viewing-editing-document.md | 1138 | how-to | L2 | 0 | datetime stored UTC ✅ workflow.md → Time; delete keeps record + restore via history ✅ src/audit/rollback.cr:25,193; hidden field stays hidden ✅ src/rbac/metadata_gate.cr | `E`/`Ctrl+S` bindings and Share/Print set unverified |
| workspace/comments-attachments.md | 1017 | how-to | L2 | 0 | 50 MB default upload ✅ src/artifact/config.cr:59; nesting to 3 levels ✅ commentThreads.ts:28; deleted-comment placeholder ✅ :31–33 | 1100 px breakpoint and content-hash dedup unverified |
| workspace/history-undo.md | 914 | how-to | L2 | 0 | default window 180 days ✅ src/mutation/config.cr:41; restore of delete brings back children ✅ src/audit/rollback.cr:43–50,193; revert persists a `snapshot` entry ✅ rollback.cr:25 | `/history?mutation=` URL shape unverified |
| workspace/import-export.md | 1183 | how-to | L2 | 0 | `POST /Api/:domain/:doctype/export` + `format`/`wait` ✅ src/import_export/routes.cr:58–60; tombstoned id → skipped ✅ import.cr:277; formula guard ✅ csv_serializer.cr:38 — but code also guards `\t` ❌ (discrepancy #2) | §"Move a domain definition" duplicates build/bundles.md (cross-linked) |
| workspace/lists-filters-views.md | 1352 | how-to | L2 | 0 | count caps at 1000 ✅ src/http/list_request.cr:28, list.cr:94,179; scope personal/general immutable ✅ collection-view.md:51,145; kanban keys ✅ collection-view.md:50 | overlaps build/collection-views.md (user vs author angle) |
| workspace/search-command-palette.md | 734 | how-to | L2 | 0 | 25 overall / 5 per doctype ✅ src/search/query.cr:20,23; min term 2 chars ✅ :16; deleted never appear ✅ 0001_document_store.sql:260 + query.cr:107 | — |
| workspace/keyboard-shortcuts.md | 476 | reference | L2 | 0 | Ctrl+K palette ✅ +layout.svelte:433; Ctrl+I assistant ✅ shortcuts.test.ts:250–256; letter shortcuts outside text fields ✅ shortcuts.svelte.ts:144–145 | `j/k/C/E/Ctrl+\` rows not individually verified |
| workspace/notifications.md | 566 | how-to | L2 | 0 | in-app only ✅ src/notifications/*; actions one-shot ✅ invoke_action.cr:55,84; automations send via `notification.send` ✅ src/lua/sandbox.cr:255 | — |
| workspace/assistant.md | 866 | how-to | L2 | 0 | rolling 30-day budget window ✅ src/assistant/config.cr:68; Ctrl+I ✅; changes attributed to caller, never coalesced ✅ (driven writes) | exact budget-exhausted message string unverified |
| workspace/settings-sessions-api-keys.md | 1012 | how-to | L2 | 0 | `fct_` prefix ✅ src/iam/api_key.cr:36; name ≤ 100 chars ✅ :49; `GET /Api/iam/me` ✅ routes.cr:186 | access token "minutes" ✅ (900 s); session material overlaps sign-in page (linked) |
| build/index.md | 454 | overview | L1 | 0 | all 26 linked build pages exist ✅; four-job framing matches structure ✅; "reproject" naming real ✅ src/cli/commands.cr:115 | — |
| build/bundles.md | 672 | how-to | L2 | 0 | `facet domain:export`/`domain:import` ✅ commands.cr:109,112; `--merge`/`--into` ✅ portable-domains.md:84,93–94; `bundle.yml` + format_version 2 ✅ :19,52 | one-transaction import confirmed (portable-domains.md:234) |
| build/checking-before-publish.md | 789 | how-to | L2 | 0 | `GET /Api/core/Domain/:id/check` ✅ src/domain/routes.cr:45; categories ✅ src/doctype/check.cr:35–93; bare reference name rejects every value ✅ check.cr:293 | "overwrite publish drops draft's domain hooks" confirmed (src/domain/publish.cr:94) |
| build/collection-views.md | 883 | how-to | L2 | 0 | owner_id immutable after create ✅ collection-view.md:51,145; surface config keys ✅ :50 | "Facet never creates a view on its own" unverified (it is now true — default views dropped); view-editor steps duplicate lists-filters-views.md |
| build/computed-fields.md | 675 | how-to | L2 | 0 | 422 "Computed fields failed" ✅ update.cr:968, create.cr:674; `compute_when` validated ✅ validation.cr:112–113; `compute`/`compute_when` definition keys ✅ field_definition.cr:96,282 | `compute_<name>` prefix call unverified |
| build/designing-doctypes.md | 796 | how-to | L2 | 0 | `POST /Api/core/DocType` authoring API ✅ routes.cr:74–78; second submit → 409 ✅ create.cr:196; reserved names ✅ but set is 8, not 3 ❌ (discrepancy #3) | icon fallback not checked |
| build/dev-domain-watcher.md | 667 | how-to | L2 | 0 | `dev.domain_watch` + `poll_ms` 500 ✅ src/dev/config.cr:30,37,49–50; `GET /Api/dev/check-report` ✅ check_report.cr:16; refuses in production ✅ config.cr:35 | `documents: preserve/discard` ✅; bundle layout matches portable-domains doc |
| build/display-names-search-text.md | 847 | how-to | L2 | 0 | `facet doctype:reproject` ✅ commands.cr:115; "no search → matches only id" ✅ check.cr:171; neither key → check warning ✅ :158,171 | 255/256 cuts, `{{ id }}` rejection, fallback order unverified |
| build/domain-builder-assistant.md | 746 | how-to | L2 | 0 | writes go through the normal write path ✅ src/agent_tools/write.cr:25,144; no publish tool exists ✅ (absence check) | trace/previews are UI claims, not checked; built-in authoring guides unverified |
| build/domains-drafts-editors.md | 870 | how-to | L2 | 0 | `POST /Api/core/Domain/:id/publish` ✅ routes.cr:49; drafts `_`-prefixed ✅ draft.cr:22,95; target-name rules + 409 fresh publish ✅ publish.cr:103–104,452 | label ≤ 64 chars unverified |
| build/event-hooks.md | 719 | how-to | L2 | 0 | 5-field cron, `/` steps, no macros ✅ src/hooks/validator.cr:33–36,130,143–150; new hook starts at `$` ✅ manager.cr:61; `document.get/list` + `notification.send` ✅ sandbox.cr:40–41,255 | "writes marked automated → no loop" unverified |
| build/evolving-schema.md | 785 | how-to | L2 | 0 | `facet doctype:migrate-retry` ✅ commands.cr:118; `POST /Api/core/DocType/:id/migrate_ahead` ✅ maintenance_routes.cr:22; lazy migration + error-marker ✅ | `/Configure/platform/maintenance` page path unverified |
| build/field-types.md | 816 | explanation | L2 | 0 | datetime → UTC `Z` ✅ workflow.md → Time; money cell `<currency> <value>` ✅ csv_serializer.cr:208–234; `filters` accepted key ✅ field_definition.cr:282 | url/color normalizations unverified |
| build/files-artifacts.md | 635 | how-to | L2 | 0 | `urn:facet:artifact:<id>` ✅ artifact_refs.cr:35; 50 MB cap with 413 ✅ artifact/config.cr:35–38,59; bytes stored outside the document ✅ artifact_refs.cr:20,35 | `$content` multipart part name, MIME sniffing unverified |

Batch B unverified: exact UI strings/bindings (budget message, `E`,
`Ctrl+S`, `Ctrl+Enter`, `j/k`, `C`, `Ctrl+\`, "first six + Show N more",
`10m`/`yest` labels, `/edit` route, Share/Print set, `?` dialog);
`/history?mutation=` shape; display_name 255/256; label ≤ 64; 50 MB import
cap; 30-day export download window; `{{ id }}` rejection; fallback order;
url/color normalization; `$content` part name; MIME sniffing; 1100 px;
`[[` mention trigger; dedup; "Facet never creates a view on its own";
`compute_<name>`; hook loop prevention; `/Configure/platform/maintenance`
path; "Search all domains" chip; co-editors copied at publish.

## Batch C — build/ second half, apps/ (33 pages)

Legend: ✅ verified · ❌ contradicts code · ❓ not verified.

| Page | Words | Type | Layer | Eng | Spot-check | Notes |
|---|---|---|---|---|---|---|
| build/identifiers-unique-constraints | 608 | how-to | L2 | 0 | 3 ✅: 18-digit cap sequence.cr:36; `genonly`+ULID fallback doctype_definition.cr:217, identifier_definition.cr:12; year/month reset sequence.cr:8–25 | — |
| build/lifecycle-scripts-guards | 782 | how-to | L2 | 0 | 3 ✅: 1M instr / 0.5 s / 32 MB lua/engine.cr:82–84; `document.*` helpers lua_document_helpers.cr; sandbox helpers sandbox.cr:255 | `ctx.actor` shape not directly checked |
| build/named-actions | 620 | how-to | L2 | 0 | 1 ✅: `/Api/...` route pattern document/routes.cr:30–44; 2 ❓: args pre-check, 403/reserved names | — |
| build/named-scopes | 1587 | how-to | L3 | 0 | 3 ✅: `$organizational_unit` auth_context.cr:194; `context_sets`/`$parent_id` context_resolver.cr:42–66; `?scope=` rest_routes.cr:213, list_request.cr:58 | Paired with govern/row-scopes (cross-linked) |
| build/notifications-mentions | 626 | how-to | L2 | 0 | 2 ✅: `notification.send` sandbox.cr:255, send.cr:38; staged until insert queue.cr:12; 1 ❓: title length limit | — |
| build/parent-child-composition | 719 | how-to | L2 | 0 | 2 ✅: composition doctype files; route pattern ✅; 1 ❓: `$content`/`$children` body | — |
| build/references-links-backlinks | 576 | how-to | L2 | 0 | 3 ✅: urn format artifact_refs.cr:33; backrefs route routes.cr:57; qualified-id form openapi.cr | Reference-`filter` on write not checked |
| build/schematic-view | 580 | how-to | L2 | 0 | 1 ✅: doc/frontend/schematic.md exists; 2 ❓: arrow rules, shared layout | Weak verification — frontend out of budget |
| build/secret-write-only-fields | 802 | how-to | L2 | 0 | 3 ✅: modes hash/sealed/token secret*.cr:35; token needs ttl_seconds :155–170; `write_only` flag field_definition.cr:150,339 | stage TTL 900 ✅ secrets/config.cr:46 |
| build/sharing-across-domains | 690 | how-to | L2 | 0 | 2 ✅: `on_source_delete: keep|unset` binding.cr:24; `consumer_domain` parsing grants/validator.cr:58; 1 ❓: activate/self-grant refusal | — |
| build/sidecars | 675 | how-to | L2 | 0 | 3 ✅: `sidecars` map doctype_definition.cr:145,283; `core.Comment` gates create.cr:142, list.cr:408; sidecar_handler.cr | `target`-in-body → 400 not checked |
| build/view-templates | 795 | how-to | L2 | 0 | 2 ✅: kinds view/form/quickView/inline/card check.cr:614; missing-kind = notice :620–621; 1 ❓: input-binding errors | — |
| build/webhooks | 752 | how-to | L2 | 0 | 3 ✅: `X-Facet-Signature` + Event/Delivery/Mutation-Id dispatcher.cr:308–313; 5 attempts [10,60,300,1800,7200] config.cr:43–44; https-only + `allowed_hosts` | Repair window ✅ config.cr:471 |
| apps/index | 239 | overview | L1 | 0 | 3 ✅: `POST /Api/app/App` cli/src/api.ts:277; `/OAuth/*` src/oauth/routes.cr:116–124; `fct_` api_key.cr:36 | minimal sequence duplicated in how-apps-work (intentional) |
| apps/agent-tools | 1534 | reference | L3 | 0 | 4 ✅: caps 200/1048576/25 config.cr:219–222; error table errors.cr:20–24; reason vocab; 5-per-doctype search query.cr:20 | Duplication of caps with mcp-agents and reference/agent-tools.md |
| apps/ai-coding-agents | 822 | how-to | L2 | 0 | 1 ✅: skill corpus not in tool catalogue, MCP serves references only mcp/skills.cr:73; 2 ❓: llms twins (site build) | — |
| apps/bulk-import-export | 1233 | how-to | L2 | 0 | 5 ✅: routes import_export/routes.cr:62–70; 202 + reserved params openapi.cr:287; member_of/sidecar refusal; `actioner_id="import"` import.cr:58; formula guard csv_serializer.cr:39 | — |
| apps/chat-embed | 1270 | how-to | L2 | 2 (DPoP ×2) | 2 ✅: elements/facade/driver packages/chat/src/index.ts:5,11,12,45,66; CSRF-on-POST app/routes.cr:14–15; 1 ❓: app-conversations path | — |
| apps/cors-origins | 806 | how-to | L2 | 1 (DPoP) | 2 ✅: origin cache stale-on-mutation origin_cache.cr:11,50,107; PATCH /Api/app/App/{id} api.ts:294; 1 ❌: `?per_page=5` example (discrepancy #4) | — |
| apps/dpop | 1678 | how-to | L3 | 5 (DPoP ×5) | 4 ✅: skew +10/−30 iam/config.cr:69–70; `invalid_dpop_proof`/`invalid_claim` token.cr:294, dpop.cr:197–207; htu mismatch names both URLs; code TTL 60 s code_store.cr:32; 1 ❌: `?per_page=1` (discrepancy #4) | Lead density driven by agent box |
| apps/files | 1207 | how-to | L2 | 0 | 4 ✅: cap 52428800 = 50 MiB artifact/config.cr:59; TTLs 3600/21600 :57–58; `publish_artifact` + revoke gate grants.cr:123, admin.cr:26; urn artifact_refs.cr:35 | — |
| apps/hosting-deploy | 1276 | how-to | L2 | 0 | 3 ✅: deploy route api.ts:300; `no_asset` → 422 deploy.cr:167; `GET /Edge/HostAsk` host_ask.cr:50 | safe-path 1024 / host 253 not checked |
| apps/how-apps-work | 1058 | explanation | L1 | 1 (DPoP) | 3 ✅: api-key routes app/routes.cr:19–21; dashboard launcher iam/routes.cr:189; `422 wildcard_target` grants_validator.cr:52–56 | — |
| apps/mcp-agents | 1179 | how-to | L2 | 1 (PKCE) | 3 ✅: defaults 4/200/1048576/25 config.cr:219–222,634–637; `/Api/_mcp` prefix mcp.cr:27; PRM resource matching protected_resource.cr:24 | `MCP-Tools-Changed` header not checked |
| apps/oauth-login | 1615 | how-to | L2 | 1 (PKCE) | 5 ✅: `access_token_ttl` 900 iam/config.cr:66; code 60 s single-use code_store.cr:32, routes.cr:71; `slow_down` 429 refresh.cr:306–320; `/OAuth/client-info` routes.cr:124; qualified `iam.Roles.` consent role iam/routes.cr:491 | verifier length 43–128 not found in greps |
| apps/permission-manifest | 1340 | how-to | L3 | 0 | 2 ✅: SDK `can`/`scopeAliases` sdk index.ts:51, me.ts; SDK error classes errors.ts:17–87; 1 ❓: `/Api/iam/me` shape, fold rules | Fold/except semantics not verified in src/iam |
| apps/quickstart-dev-cli | 1174 | tutorial | L2 | 0 | 4 ✅: `auth.json` mode 600 auth.ts:50,106–107; `FACET_TOKEN` wins, never refreshed :126,134, api.ts:234; skips node_modules/.git deploy.ts:17,20; `facet-cli` slug login.ts:20; 1 ❌: error table shows lowercase `/api/app/…/deploy` (discrepancy #5) | — |
| apps/registering-app | 993 | how-to | L2 | 0 | 3 ✅: `422 wildcard_target` grants_validator.cr:56; POST + PATCH api.ts:277,294; `facet-cli` seed slug login.ts:20; 1 ❓: slug immutable / `422 read_only` | `{}`-round-trip quirk unverified |
| apps/rest-api | 2014 | how-to | L3 | 3 (ETag, DPoP ×2) | 7 ✅: grammar keys list_request.cr:58–59; unknown-param 422 :476; count cap 1000 list.cr:94,179; ETag = `projection.state` responders.cr:303; `Accept-Query` gates.cr:214; restore route openapi.cr:175; operators filter_compiler.cr:33,361,366 | — |
| apps/search | 997 | how-to | L2 | 0 | 2 ✅: constants 2/5/25/8 search/query.cr:16–27; rank-desc sort :101; 1 ❓: two route paths + QUERY 422 | — |
| apps/service-accounts | 1126 | how-to | L2 | 1 (grant ∩ pinned role) | 3 ✅: api-key routes + operator-only + rotation app/routes.cr:15–38; `svc.<slug>@apps.facet.invalid` service_accounts.cr:35,41; `fct_`/display-prefix api_key.cr:36,46; 1 ❌: `?per_page=5` (discrepancy #4) | — |
| apps/typescript-sdk | 1835 | reference | L2 | 0 | 3 ✅: `@facetapp/sdk` package.json:2; error classes errors.ts:17–87; close codes 4401/4403 realtime.ts:90–91,579; exports ✅ index.ts:13–51 | "Zero runtime dependencies" not checked |
| apps/websockets | 1204 | how-to | L2 | 0 | 4 ✅: 4401/4403 websocket/route.cr:31–32; `facet-ws-v1` :39; mailbox 64 connection.cr:76; 32 subscribers/doctype config.cr:301 | — |

Batch C unverified: schematic arrow rules/layout; view-template input-binding
severity; sidecar `target`-in-body 400; named-action args pre-check and 403
on missing permission; manifest fold rules and `/Api/iam/me` shape; slug
immutability/`read_only`/`{}` round trip; grant activate/self-refusal;
notification title limit; search route paths + strict QUERY 422;
`MCP-Tools-Changed`; WS notifications refusal to app principals; uniform 401
body; PKCE verifier length; "proof verified before code consumed"; `cnf.jkt`;
llms/twins (site build); safe-path 1024/host 253; cache headers; SDK zero
dependencies.

## Batch D — govern/, operate/ (33 pages)

| Page | Words | Type | Layer | Eng | Spot-check | Notes |
|---|---|---|---|---|---|---|
| govern/index.md | 296 | overview | L1 | 0 | ✅ all 14 child links match disk; ✅ assurance links exist; ❓ one target (listing truncated) | — |
| govern/accounts-lifecycle.md | 1487 | how-to | L2 | 0 | ✅ temporary-password/invite/credential-states routes (src/iam/routes.cr:587-593); ✅ 16-char 4-group password, temp refuses suspended/disabled 422 (invite.cr:46-89); ✅ seed:admin one-time pw, refuses existing email (seed.cr:42-55) | Restore codes table duplicated in rolling-back.md |
| govern/roles-permission-lines.md | 1520 | explanation | L2 | 0 | ✅ `visible_tags` default ["default"] (active_role.cr:41); ✅ connectivity 422 message (iam/routes.cr:513); ✅ seeded roles 100/30/20/20/20/0 + level 0–100 (iam.md:73, seeds) | Level table overlaps assigning-roles-election (cross-linked) |
| govern/assigning-roles-election.md | 929 | how-to | L2 | 1 (elected role) | ✅ login+refresh routes (routes.cr:52,58); ✅ 403 Role not assigned / not found (refresh.cr:99,105); ✅ election explicit→default_role→first (login.cr:59, iam.md:119) | — |
| govern/row-scopes.md | 1427 | explanation | L2 | 0 | ✅ `422 Unknown scope` (list.cr:239); ✅ scopes declared on doctype, referenced by alias; ✅ author half exists at /build/named-scopes/ | "never 403" claim unverified |
| govern/field-visibility-tags.md | 882 | how-to | L2 | 0 | ✅ untagged field → ["default"] (field_visibility.cr:155); ✅ write into invisible field 403 (write_enforcer.cr:75); ✅ default visible_tags (active_role.cr:41) | — |
| govern/enforcing-mfa.md | 1159 | how-to | L2 | 0 | ✅ TOTP 6 digits/30 s (totp.cr:26-29); ✅ 10 backup codes, 8 hex, xxxx-xxxx, SHA-256 only (backup_codes.cr:23-49); ✅ 5 wrong codes → 429 (mfa.cr:21-22); ✅ `iam.mfa.type` none|totp (write_gate.cr:373) | Rate-limit table duplicated in sessions-tokens-lockouts.md |
| govern/sso-oidc.md | 1117 | how-to | L2 | 0 | ✅ `oidc_only` → password 403 + event (login.cr:81-84); ✅ `auto_provision` requires default_role (identity.cr:319); ✅ providers route (routes.cr:192), default hybrid (iam/config.cr:114) | `facet auth:mode` duplicated in bootstrap-cli.md |
| govern/sessions-tokens-lockouts.md | 1287 | explanation | L3 | 0 | ✅ ES256 + JWT_SIGNING_KEY (token_emitter.cr:20); ✅ 900 s / 1209600 s / 10 s grace (iam/config.cr:66-68); ✅ 10-per-account, 20-per-IP, 300 s counters + lockout 300 s (login.cr:40-43, login_throttle.cr:38-46); ✅ sessions routes incl. app sessions (routes.cr:1028-1037) | MFA throttle rows duplicate enforcing-mfa.md |
| govern/app-grants.md | 1025 | how-to | L2 | 1 (elected role) | ✅ `assistant_token_budget` role field (access.cr:91); ✅ fail-closed 401 (auth_handler.cr:53-60); ✅ budget denial `total >= budget` (limits.cr:19-35); grant pre-check evaluator not read | — |
| govern/api-keys.md | 895 | how-to | L2 | 0 | ✅ `fct_` + 26 chars (api_key.cr:36-44); ✅ name ≤ 100 (:49); ✅ SHA-256 stored, shown once (:20); ✅ expires_at future UTC + idempotent revoke + bare 404 (iam.md:657); ✅ last_used_at throttled 1/min (:51) | — |
| govern/auditing-activity.md | 948 | how-to | L2 | 0 | ✅ GET+QUERY /Api/Audit (audit/routes.cr:56-60); ✅ include=children (list.cr:122-159); ✅ rollback route (routes.cr:65) | — |
| govern/rolling-back.md | 884 | how-to | L2 | 1 (mutation) | ✅ rollback+restore routes (audit/routes.cr:79-84); ✅ restore `409 Document is not deleted` (restore.cr:62); ✅ 404-names-window + 422 degenerate delete | Restore semantics duplicated from accounts-lifecycle |
| govern/retention.md | 952 | reference | L2 | 0 | ✅ defaults 180/3/30/1M/jobs 30/artifact 30 (mutation/config.cr:41-44, config.cr:259, event/config.cr:36, jobs/config.cr:32-36); ✅ crons `45 3 * * *`/`15 4 * * *`; ✅ boot refuses reconcile window ≥ jobs retention (config.cr:470-474) | Overlaps retention-tuning.md (cross-linked) |
| govern/governing-assistant.md | 955 | how-to | L2 | 0 | ✅ usage route (assistant/routes.cr:78); ✅ rolling 30-day budget, deny at ≥ budget (limits.cr:19-35); ❌ "keep it at 30 days or more" — code says 31+ (assistant/config.cr:68-69) (discrepancy #6) | Contradicts assistant-config.md; usage-ledger content overlaps it |
| operate/index.md | 279 | overview | L1 | 0 | ✅ section links match the 17 operate pages; ✅ coverage list matches titles | — |
| operate/system-requirements.md | 865 | reference | L1 | 0 | ✅ PG 14+ for `ulid()`; ✅ pgvector:0.8.0-pg17 (compose.prod.yml:13); ✅ backend uid 10001, frontend node (backend.Dockerfile:74); ✅ statement_timeout + cluster (config.cr:77-89,715) | Images/uid/topology duplicated in containers-tls.md |
| operate/containers-tls.md | 1093 | how-to | L2 | 0 | ✅ entrypoint render→migrate(×3)→seed:core→exec (backend-entrypoint.sh:44-54); ✅ master key fails closed < 32 bytes (secrets/config.cr:34); ✅ make docker_images/docker_smoke (Makefile:138,142); ❌ edge list "`/app`, `/a` → backend" (discrepancy #7) | duplicates system-requirements topology |
| operate/production.md | 340 | tutorial | L2 | 0 | ✅ compose.prod.yml path valid; ✅ one-off seed:admin container (commands.cr:106); ✅ HTTPS_PORT 3443, backend 3000 internal only (compose.prod.yml:87,96) | — |
| operate/bootstrap-cli.md | 926 | reference | L2 | 0 | ✅ migrate/db_reset --yes/seed:* (commands.cr:41-106); ✅ accounts:*/roles:*/auth:mode (:88-100); ✅ index:retry/artifacts:*/doctype:*/cron:list (:69-121) | Small overlaps: auth:mode (sso-oidc), seed:admin (accounts-lifecycle) |
| operate/configuration-files.md | 900 | how-to | L2 | 0 | ✅ `!env` expansion, missing raises (config.cr:374-377); ✅ `mail.allow_dev_adapter_in_production` gate (emails/config.cr:77); ✅ hot keys overridden by settings doc (config.cr:152-153, system_settings/routes.cr:17-19) | Hot-key chain duplicated in system-settings.md |
| operate/system-settings.md | 893 | how-to | L2 | 0 | ✅ GET /Api/SystemSettings + PATCH (routes.cr:17-19,45); ✅ registered paths (write_gate.cr:195-198,336-354); ✅ `iam.mfa.type` validation (:373) | Hot-key chain duplicated in configuration-files.md |
| operate/email.md | 777 | how-to | L2 | 0 | ✅ defaults dev/stdout, no-reply@facet.local, port 587 (emails/config.cr:23-60); ✅ production gate refuses dev adapter (:77-91); ✅ link TTL 86400 s (iam/config.cr:62) | — |
| operate/file-storage.md | 933 | how-to | L2 | 0 | ✅ 52428800 cap, 413 before disk write (artifact/config.cr:56, uploader.cr:23); ✅ TTLs 3600/21600/300 (config.cr:54-58); ✅ artifacts:prune/reconcile/revoke CLI (commands.cr:76-84) | Prune CLI duplicated in bootstrap-cli.md |
| operate/currencies.md | 843 | how-to | L2 | 0 | ✅ `inactive_currency` code (money_currency_check.cr:216); ✅ staleness_ttl_s 300 (config.cr:286); ✅ grouping standard default + seed:core (util/money.cr:41, commands.cr:63) | ticker regex + seed rows unverified |
| operate/localization.md | 671 | how-to | L2 | 0 | ❌ "defaults are `UTC` and `en`" — code default is `auto` (config.cr:158) (discrepancy #8); ✅ language default `en` (config.cr:546); ✅ allowed set en,fr (settings/keys.cr:54) | — |
| operate/health-metrics-logs.md | 1309 | how-to | L2 | 0 | ✅ /Healthcheck probes pools+Redis+consumers, /live no checks (healthcheck.cr:29-60); ✅ Prometheus 0.0.4 (metrics.cr:8); ✅ edge 404s /metrics (Caddyfile.prod:96-104); ✅ db.query 2000-char cap (db_integration.cr:52); lag */10; LOG_LEVEL note | — |
| operate/jobs-cron.md | 1322 | how-to | L3 | 0 | ✅ 5 retries × ladder (jobs/handler.cr:56-57); ✅ queue defaults 60/3600/32/30.0/30 (jobs/config.cr:32-36); ✅ cron table + liveness 120 s (config.cr:238,260; secrets:48; assistant:88,90; mutation:43; webhook:47; event:37) | Compaction/prune rows duplicated in retention-tuning.md |
| operate/migrations.md | 806 | how-to | L2 | 0 | ✅ embedded at compile time + _migrations (migrate.cr:13-31); ✅ entrypoint migrate→seed:core, 3 attempts (entrypoint.sh:44-54); ✅ ALTER ROLE timezone UTC in 0001 (0001_document_store.sql:42) | `migrate:down` details also in upgrades |
| operate/upgrades-shutdown.md | 914 | how-to | L2 | 0 | ✅ close frames before drain (shutdown.cr:17); ✅ 30 s drain bound (:19-20); ✅ "graceful shutdown complete" log line (main.cr:305) | — |
| operate/indexes.md | 927 | how-to | L2 | 0 | ✅ GET /Api/Indexes (index/routes.cr:31); ✅ index:retry --domain --dry-run (commands.cr:69, retry_cli.cr); ✅ stale pending > 10 min dead (retry_cli.cr:25) | index:retry duplicated in bootstrap-cli.md |
| operate/assistant-config.md | 957 | how-to | L2 | 0 | ✅ defaults Assistant / api.openai.com/v1 / gpt-4o / auto_execute true (assistant/config.cr:77-85); ✅ cancel 15 / turn 900 / prune `30 4 * * *` (:86-90); ✅ 31+ safe, 1–30 under-counts (:68-69) | Overlaps governing-assistant.md (ledger, /usage) |
| operate/retention-tuning.md | 813 | how-to | L2 | 0 | ✅ 180/30 defaults, crons, coalesce 3 (mutation/config.cr:41-44, config.cr:259-260); ✅ overrides file-only, two scalars pinnable (config.cr:265-266, write_gate.cr:195-198); ✅ negative refused (mutation/config.cr:64-66) | Overlaps govern/retention.md (deliberate, cross-linked) |

Batch D unverified: govern/index truncated link target; row-scopes "never
403"/OR-combination; app-grants uniform 401 + pre-check; MFA
challenge-delete + lockout path; role-rename 422; ticker format/seed rows;
replica `read_only` SET; OTEL no-op without endpoint; healthcheck interval
10 s.

## Batch E — compare/, changelog/, reference/ (26 pages)

| Page | Words | Type | Layer | Eng | Spot-check | Notes |
|---|---|---|---|---|---|---|
| compare/index.md | ~800 | overview | L1 | 0 | BSL 1.1 ✅ LICENSE:1; audit+field permissions+app hosting in product ✅; vendor prices ❌ external | Pricing table duplicated (compressed) on every vs-* page; sizing ($20–60/mo, 2 vCPU) has no repo source |
| compare/vs-ai-built-apps.md | ~2440 | explanation | L2 | 0 | DPoP ✅; MCP ✅; "2 vCPU, 2–4 GB RAM" ❌ not in repo | Stale `TODO(link): custom-apps and SDK pages` — apps section ships; Veracode/UpGuard figures external |
| compare/vs-airtable-notion.md | ~2095 | explanation | L2 | 0 | 50 MB upload default ✅ artifact/config.cr:59; S3-compatible ✅ :67; "retention … per document" ❌ (discrepancy #11) | Airtable/Notion caps & prices external |
| compare/vs-odoo-erp.md | ~2020 | explanation | L2 | 0 | no accounting/payroll code ✅ (absent in src/); webhooks notify ERP ✅; domain export/import ✅ commands.cr; "per document" retention ❌ (#11) | Odoo prices external; "marketplace is planned" roadmap claim |
| compare/vs-retool-lowcode.md | ~1910 | explanation | L2 | 0 | webhooks ✅; SDK ✅ packages/sdk; "per document" retention ❌ (#11) | Stale `TODO(link): REST API reference when it is published` — it exists |
| compare/vs-supabase-firebase.md | ~2430 | explanation | L2 | 0 | DPoP ✅; invites+SSO only, no public signup ✅ (no signup route; invite in openapi.json); "per document" retention ❌ (#11) | Supabase/Firebase claims external; marketplace roadmap claim |
| changelog/index.md | ~375 | explanation | L2 | 0 | sdk-v*/chat-v*/cli-v*→@facetapp/* ✅ release-npm.yml:3-11; master→nightly ✅ docker.yml:240,255; tag==package.json guard ✅ :53-56 | GHCR literal path verified only via dynamic OWNER |
| reference/index.md | ~115 | overview | L1 | 0 | `make gen-docs-*` targets ✅ Makefile:152-193; all 18 linked pages exist ✅; 13/18 generated ✅ | — |
| reference/rest-api.mdx | ~170 | reference | L3 | 0 | vendored copy ✅ public/api/openapi.json; IAM routes ✅ openapi; "serves these route groups" ❌ omits Artifacts/secrets/Indexes/SystemSettings (discrepancy #10) | Note's exclusion list drifted from spec |
| reference/error-responses.md | ~1190 | reference | L3 | 0 | `X-Document-Deleted` on 410 ✅ document/routes.cr:369; codes inactive_currency/named_scope/context_set ✅; CSRF X-Requested-With ✅ iam/routes.cr:26 | 503-on-aggregate-timeout partially verified (statement timeout exists, database.cr:78) |
| reference/permission-syntax.md | ~1260 | reference | L3 | 0 | CamelCase path regex ✅ rbac/permission.cr:321; create-scope warning ✅ validator.cr:160; admin `*.*` seed ✅ iam.Roles/documents.yml:10; "string scope fails `must be an array`" ❌ (discrepancy #12) | — |
| reference/jinja2-context.md | ~1600 | reference | L3 | 0 | 255/256 truncation ✅ display_name.cr:32, search.cr:33; Crinja filters ✅ lib/crinja; calendar title_template in browser ✅ | Crinja quirks (truthy "", shadowing) not verified |
| reference/webhook-payloads.md | ~1185 | reference | L3 | 0 | `Facet-Webhook/1.0` ✅ dispatcher.cr:91; 5 retries × ladder ✅ webhook/config.cr:43-44; example HMAC digest recomputed = `8cce667b…` ✅ | timeout 10 s ✅ webhook/config.cr:42 |
| reference/account-settings-keys.md | ~215 | reference (gen: account_settings.cr) | L3 | gen | core.language "en" ✅ keys.cr:40; notifications.in_app true ✅ :50; core.timezone "UTC" ❌ code default "auto" (discrepancy #9) | Generator drift; SERVER_DEFAULTS tier claim ✅ :63-64 |
| reference/agent-tools.md | ~885 | reference (gen: agent_tools.cr) | L3 | gen | 23 tools ✅; ping ✅ registry.cr:165; read_skill + skills dir ✅ | — |
| reference/cli-facet.md | ~485 | reference (gen: cli.cr) | L3 | gen | db_reset/seed:dev ✅ commands.cr:52,103; auth:mode hybrid|oidc_only ✅ :100; doctype:reproject/migrate-retry ✅ :115,118 | — |
| reference/cli-npm.md | ~640 | reference (gen: npm_cli.mjs) | L3 | gen | Node ≥20 ✅ packages/cli/package.json:24; commands incl rollback ✅; facet.config.json ✅ config.ts | — |
| reference/config-keys.md | ~2540 | reference (gen: config_keys.cr) | L3 | gen | snapshot_every=10 ✅ config.cr:396; host localhost:3000 ✅ :399; max_upload_bytes=52428800 ✅ artifact/config.cr:59 | — |
| reference/doctype-schema.md | ~2015 | reference (gen: doctype_schema.cr) | L3 | gen | sidecars ✅ doctype_definition.cr:469; identifier ✅ :548; unknown-key rejection ✅ :557 | — |
| reference/dvt-schema.md | ~2950 | reference (gen: dvt_schema.cr) | L3 | gen | grid⇒layout+children ✅ view_template_validator.cr:76; input-money⇒field+label ✅ :102; money→input-money map ✅ :185 | — |
| reference/feature-index.md | ~2270 | reference (gen: feature_index.mjs) | L3 | gen | "138 features in 10 areas" ✅ inventory.yml:1; AI-01…09 ✅; check-coverage contract ✅ inventory.yml:5 | Count now 158 — page regenerates at WP 11 (`make gen-docs`) |
| reference/field-types.md | ~850 | reference (gen: field_types.cr) | L3 | gen | 22 types = 22 files ✅; secret `sh_`+26 Crockford ✅ secret_type.cr:39; money currency fill ✅ money_type.cr:120-124 | — |
| reference/filter-operators.md | ~1100 | reference (gen: filter_operators.cr) | L3 | gen | unsupported_filter_operator ✅ filter_compiler.cr:294; malformed_filter_value ✅ :352; `in` ≤100 ✅ util/filter_set.cr:43 | Page silent on over-100 behaviour (code degrades to FALSE in one path) |
| reference/health-metrics-names.md | ~765 | reference (gen: health_metrics.cr) | L3 | gen | /Healthcheck, /live, /metrics ✅; facet_events_published_total etc ✅ metrics.cr:45-58; event_loss fields ✅ | — |
| reference/lua-api.md | ~755 | reference (gen: lua.cr) | L3 | gen | util.facet_hosts ✅ lua/sandbox.cr:53; util.valid_redirect_uri ✅ :55; math.clamp ✅ :50 | — |
| reference/system-settings-keys.md | ~755 | reference (gen: system_settings.cr) | L3 | gen | localization.* keys ✅ system_settings/spec.cr:197-203; auth.mode hybrid ✅ iam/config.cr:114; assistant.model gpt-4o ✅ assistant/config.cr:80 | — |

Batch E unverified: all vendor pricing/plan figures and third-party research
numbers (external); "2 vCPU / $20–60" sizing (no repo source); managed-hosting
and domain-design services (commercial offers); aggregate 503 mapping;
`*.*` role-authority guard location; Crinja quirks; over-100 `in` behaviour;
roadmap claims ("marketplace … planned" — future statements to remove in
rewrite).
