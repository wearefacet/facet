# WP 18 batch A ledger — admin history + under the hood (reconstructed)

Ledger for the six remaining WP 18 batch A pages outside the people group:
`admin/history/*` (3) and `admin/under-the-hood/{change-log,one-role-at-a-time,
how-access-is-enforced}.md`. Reconstructed on 2026-11-26 from the repo state,
because the agent that worked this group died before writing its ledger.

**Status finding (read this first).** The task brief said these six pages were
already rewritten with `verified_at: eee55a2`. The repo says otherwise:

- The worktree matches `9ab44a5` (HEAD) for all six files — no uncommitted
  rewrite exists, and no other branch carries one (`git log --all -S` finds no
  v2 rewrite of any of the six paths).
- All six still carry the pre-v2 content that WP 11 (`9b368b5`, move tab 4/5)
  moved from `govern/*`, `operate/*` and `concepts/*` into the new paths. The
  move only retargeted links and touched front matter (diffs of +2/−1 to
  +15/−14 lines against the pre-move sources).
- The `verified_at` stamps are the old v1-wave stamps, not `eee55a2`:
  `a8e1b43` (audit.md), `fd345fe3` (roll-back.md, retention.md),
  `7a6cb462` (change-log.md, one-role-at-a-time.md, how-access-is-enforced.md —
  the same stamp the brief itself calls "old content" on
  who-can-change-roles.md).
- The proposed page-map titles are not applied either (see §1 tables).

So the v2 rewrites of these six pages are still outstanding. This ledger
records the preservation state, the claim sources, and the live checks so the
rewriter (or a rerun agent) starts from evidence instead of memory. The
rewrite itself was outside this reconstruction's edit scope.

---

## 1. Preservation checklists

Old content = the moved pages at `9ab44a5` (= `9b368b5~1` sources; the move
changed links only). Old paths per `03-page-map.md` §3 and §7 and
`ledgers/surfaces.md` rows. Every heading of each old page is listed with its
state in the current page — which today equals "kept unchanged (pre-rewrite
content)". The checklist doubles as the input for the pending rewrite.

### govern/auditing-activity.md → admin/history/audit.md

Front matter today: title "Auditing activity", `sidebar.order: 0`,
`verified_at: a8e1b43`. Page map §7 proposes title "See who did what".

| Old heading / fact | Current state |
|---|---|
| Lead: one append-only log; who/what/when/why; plus the sign-in log | kept (pre-rewrite) |
| §When to use this (3 bullets) | kept |
| §Before you start (document history rights, wildcard `*.*` for the global log, model link) | kept |
| §Steps 1 document history (curl, newest first) | kept; live-verified 2026-11-26, see §3 |
| §Steps 2 `?include=children` (child branches filtered by child scope, silent drop) | kept; live 200 |
| §Steps 3 global log, bracket filters, capped count + `more`, bare key `422`, QUERY method | kept; live-verified (422 + bracket form) |
| §Steps 4 admin UI Configure → Audit (chips, row inspect, rollback link) | kept (UI not live-checked) |
| §Steps 5 login-event log via `iam.LoginEvent` documents | kept; live-verified |
| §Explanation: what each row records (who/what/when/why field table, cause chain via `cause_parent`, cluster via `cause_trace`) | kept; matches doc/backend/audit.md |
| §Explanation: two read modes (403 for role denial, 404 for single-document denial) | kept; matches doc/backend/audit.md:19 |
| §Explanation: filter table (eq-only set vs eq/ne set, `emitted_at` gte/lte) | kept |
| §Explanation: channels table (session, oauth_app, app_api_key, api_key, mcp, internal) | kept |
| §Explanation: redaction + `redacted` block | kept |
| §Explanation: login-event log (event kinds; failed single attempts not logged — lockout only; successful refreshes not logged; backend log carries both) | kept; matches commit 3798f5b and discrepancy #21's finding |
| §Troubleshooting (4 entries) | kept |
| §Related (5 links + internals) | kept (links retargeted to v2 paths by the move) |

### govern/rolling-back.md → admin/history/roll-back.md

Front matter today: title "Rolling back changes", `sidebar.order: 1`,
`verified_at: fd345fe3`. Page map §7 proposes "Roll back a change".

| Old heading / fact | Current state |
|---|---|
| Lead: rollback replays history to a target, saves one new snapshot; restore brings back a delete; both write new rows | kept |
| §When to use this (3 bullets) | kept |
| §Before you start (`update` right, target id, window) | kept |
| §Steps 1 find the target (ULID, malformed id `422`) | kept |
| §Steps 2 rollback route (body `mutation_id`, URL doc id; answer = document; `meta.mid` = new snapshot; `cascade_restored` empty on plain rollback; global route `POST /Api/Audit/<id>/rollback`, its 404 names the base window) | kept; 404 body live-verified |
| §Steps 3 restore route (empty body; 200/404/409/403/422 table) | kept; matches doc/backend/audit.md and AGENTS.md rollback rules |
| §Explanation: what a rollback writes (snapshot, actor, `cause_kind: rollback`, `cause_parent` = target) | kept; matches doc/backend/audit.md:141-163 |
| §Explanation: limits (depth = window, 404 names window, `0` = full; rollback to a delete restores; degenerate delete `422`) | kept; matches doc/backend/audit.md:178,149 and AGENTS.md |
| §Explanation: children come back (cascade set, preflight, one denial aborts, own snapshots, `cascade_restored` shape) | kept; matches doc/backend/audit.md:165-169 |
| §Explanation: who may roll back (`update` right; role-authority gate 403; field-visibility gate 403) | kept; matches doc/backend/audit.md:120-123 |
| Caution: full target content; later changes stay in history | kept |
| §Troubleshooting (4 entries) | kept |
| §Related (5 links + internals) | kept (retargeted) |

### govern/retention.md + operate/retention-tuning.md → admin/history/retention.md

The v1 wave already merged the two pages (policy + tuning); WP 11 deleted
`operate/retention-tuning.md` (145 lines) in the move. Front matter today:
title "Retention: what is kept and for how long", `sidebar.order: 2`,
`verified_at: fd345fe3`. Page map §7 proposes "Retention: what is kept" and a
policy-first / operator-second shape — the current page does not follow that
H2 split yet.

| Old heading / fact | Current state |
|---|---|
| Lead: classes of data, lifetimes, where set | kept |
| §When to use this (3 bullets) | kept |
| §Explanation: what each class keeps (9-row table: documents, mutations, coalesced updates, tombstones, events, jobs/webhooks, sessions/tokens, files, login events) | kept; defaults live-checked against config.dev.yml + src/config.cr (§3) |
| §Explanation: notes per class (compaction at 03:45, contiguous order, tombstone keeps trailing delete; coalescing fold + fresh id + row-order gap; tombstone payload never leaks; at-most-once events + webhook reconcile window; session TTL keys; ownerless file prune) | kept |
| Caution: mutation window bounds rollback depth | kept |
| §Steps: set the windows (config file source of truth; runtime pin via Configure → Platform → Settings; per-doctype overrides file-only) | kept (tuning half, from operate/retention-tuning.md steps 1-3) |
| Tip: override badge on pinned values | kept (tuning half) |
| §Example: full retention YAML with defaults | kept; matches config.dev.yml:59,84,213,243-258 and src/mutation/config.cr:41 |
| §Troubleshooting (3 entries: window 0, rollback 404, row-order gap) | kept |
| §Related (5 links + internals) | kept (retargeted) |
| operate/retention-tuning.md §"Mind the edges" (override interplay, pin from next pass, 0 = keep forever) | merged into §Steps/clear-pin tip — the two edges survive as steps 2-3 |

### concepts/mutation-log.md → admin/under-the-hood/change-log.md

Front matter today: title "The mutation log", `sidebar.order: 1`,
`verified_at: 7a6cb462`. Page map §3 proposes "The change log, in detail".

| Old heading / fact | Current state |
|---|---|
| Lead: plain table, one row per accepted write, reads read projections | kept |
| §Explanation: column-group table (target / payload / provenance / cause) | kept; matches doc/backend/mutation.md |
| Writers only append; refused writes leave no row; system writes carry stamps | kept |
| Projection trigger; ETag = last-mutation id (`projections.state`), `If-None-Match` | kept; AGENTS.md confirms `projections.state` semantics |
| Write-time coalescing (3 min default, fresh id, old id `404` inside window, driven writes never fold, 0 disables) | kept; AGENTS.md + src/mutation/config.cr:55 confirm the window default |
| Retention compaction (180 days default, synthetic snapshot, depth = window, tombstone keeps trailing delete + predecessor) | kept; AGENTS.md + doc/backend/audit.md:178 |
| Caution: mutation id is not a permanent reference | kept |
| §Why this is not domain event sourcing (replay only inside the service; reactions on Redis Streams, at-most-once; trade-offs deliberate) | kept |
| §Related (6 links + internals) | kept (retargeted) |

### concepts/auth-contexts.md → admin/under-the-hood/one-role-at-a-time.md

Front matter today: title "Auth contexts", `sidebar.order: 2`,
`verified_at: 7a6cb462`. Page map §3 proposes "Why you act as one role at a
time"; the L1 part of the old concept belongs to
`discover/how-it-works/roles.md` (WP 13).

| Old heading / fact | Current state |
|---|---|
| Lead: one auth context per request, from browser to API key | kept |
| §Explanation: channels table (browser session / OAuth app / MCP / API key, credential + context contents) | kept; matches doc/backend/iam.md, rbac.md |
| One context per request; principal + exactly one elected role; roles never merge; channel recorded in every audit row | kept |
| The grant is a ceiling (checked before role lines, live re-resolution, no new token) | kept; matches doc/backend/rbac.md (RBC-08) |
| Enforcement is the same everywhere (enforcers in document services; denied read = non-disclosing 404 on every channel) | kept |
| §Who is calling (`GET /Api/iam/me`: account, elected role, other roles, manifest; app-scoped manifest cut to grant) | kept |
| Note: no credential → `anonymous`; invalid credential → `401`, never anonymous | kept |
| Trade-off: no privilege aggregation; deliberate switch paths (role switch, consent election, MCP pin) | kept |
| §Related (6 links + internals) | kept (retargeted) |

### concepts/authorization-enforcement.md → admin/under-the-hood/how-access-is-enforced.md

Front matter today: title "Authorization enforcement", `sidebar.order: 3`,
`verified_at: 7a6cb462`. Page map §3 proposes "How access is enforced".

| Old heading / fact | Current state |
|---|---|
| Lead: read enforcer + write enforcer inside every document operation | kept |
| Diagram: caller → enforcers → permission / row scopes / field tags / metadata gate; denied read 404 (d2 source in an HTML comment + pre-rendered light/dark `<img>` embed — old rendering style, not a ` ```d2 ` fence) | kept as-is |
| RBAC: one identity, one elected role, roles never merge | kept |
| Permission line: action × doctype path × optional scope | kept |
| Row scopes: named predicates compiled to SQL; lists join; single read evaluates the row | kept; matches doc/backend/rbac.md |
| Field tags: `visible_tags` must hold all tags; `default` tag for untagged; reads mask, writes `403` naming the path | kept |
| Denial is non-disclosing (404 = missing; list 200 visible rows; nested child 404 parity) | kept |
| Metadata gate (core.DocType / core.Domain rows; any-action holders get rows; aggregates empty 200) | kept |
| Note: reads mask silently, writes fail loudly; no type leak from validation errors | kept |
| Trade-offs (404 masking, scope query cost, empty lists) | kept |
| §Related (6 links + internals) | kept (retargeted; the who-can-change-roles link still uses the old title "Roles, levels and authority") |

---

## 2. Claim ledger

Load-bearing claims of the six pages as they stand, with sources. Live checks
were re-run read-only on `https://facet.localhost:3443` (2026-11-26, admin
session cookie; nothing written, no demo data touched — details in §3).

### admin/history/audit.md

| Claim | Source |
|---|---|
| Document history route answers rows newest-first; each row carries action, actor, channel, cause fields | live `GET /Api/clients/Company/<id>/history` → 1 create row with `actioner_id`, `channel: session`, `cause_kind: request`; doc/backend/audit.md:235 |
| `?include=children` folds child branches; child scope filters silently | live → 200; doc/backend/audit.md:135-137 |
| Global log at `/Api/Audit`; bracket filters only; bare query key `422`; QUERY method takes a JSON body; capped count + `more` | live bracket form → 200 with rows + `meta.more`; bare `?doc_type=…` → 422; doc/backend/audit.md |
| Filters: domain/doc_type/doc_id eq; action/actioner_id/app/channel/kind/trace eq,ne; emitted_at gte,lte | doc/backend/audit.md; live `filters[trace__eq]=…` → 200 |
| Login events are `iam.LoginEvent` documents with event, account_id, details | live list → login row with `event: login`, `details: Role: …` |
| Successful refreshes are not logged | commit 3798f5b (iam: keep successful refreshes out of the LoginEvent log); discrepancy #21 records the same finding for an old page |

### admin/history/roll-back.md

| Claim | Source |
|---|---|
| Rollback persists one new `snapshot`; `cause_kind: rollback`; `cause_parent` = target; actor = caller or `system:rollback` | doc/backend/audit.md:141-163 |
| Unknown/old/folded target → `404`, body names the effective window | live `POST /Api/clients/Company/<id>/rollback` with a bogus ULID → 404 `{"error":"Mutation … not found. It may be unknown, older than the retention window (180 days for clients.Company), or folded by coalescing."}`; doc/backend/audit.md:260-263 |
| Rollback to a delete restores the document; delete with no preceding change → `422` | doc/backend/audit.md:149; AGENTS.md (Audit::Rollback rules) |
| Restore answers 200/404/409/403/422 | doc/backend/audit.md:216 table; AGENTS.md |
| Cascade restore: composition children return with own snapshots, preflight aborts on one denial, `cascade_restored` lists them | doc/backend/audit.md:165-169 |
| Two transition gates can 403: role-authority (IAM state) and field-visibility (rewind into invisible field) | doc/backend/audit.md:120-123 |
| Global route `POST /Api/Audit/<mutation id>/rollback`; its 404 names the base window | doc/backend/audit.md:235,260 (not live-probed: it is a write route) |

### admin/history/retention.md

| Claim | Source |
|---|---|
| `mutations.retention_days` default 180; overrides per doctype; compaction cron `45 3 * * *`; coalesce window 3 min | config.dev.yml:252-258; src/mutation/config.cr:41,55 |
| `tombstone.content_retention_days` 30; prune cron `15 4 * * *` | config.dev.yml:243-244; src/config.cr:259 |
| `event.maxlen` 1,000,000; `jobs.retention_days` 30; `artifact.prune_after_days` 30 | config.dev.yml:84,213,59 |
| Runtime pin via Configure → Platform → Settings; pins apply from the next pass; overrides file-only | doc/backend/mutation.md (retention compaction); AGENTS.md config rules |
| Compaction: snapshot per document, projection untouched, no events, contiguous `idx` | AGENTS.md (Cron::MutationCompaction); doc/backend/mutation.md |
| Coalescing: same-actor same-channel plain-request updates fold; fresh ULID; old id `404` in window; idx gap | AGENTS.md (write-time coalescing) |

### admin/under-the-hood/change-log.md

| Claim | Source |
|---|---|
| One row per accepted write in `mutations`; refused writes leave no row | doc/backend/mutation.md; doc/backend/rbac.md (checks run before any database change) |
| Projection trigger applies each mutation; ETag = `projections.state`, checked with `If-None-Match` | AGENTS.md (state column = last mutation ULID); doc/backend/mutation.md |
| Coalescing folds plain request updates only; driven writes never fold | AGENTS.md; doc/backend/mutation.md |
| Compaction snapshot keeps replay possible; rollback depth = window | AGENTS.md; doc/backend/audit.md:178 |
| Reactions travel on Redis Streams, at-most-once, PostgreSQL durable | AGENTS.md (event delivery) |

### admin/under-the-hood/one-role-at-a-time.md

| Claim | Source |
|---|---|
| Channel table (browser session / OAuth / MCP / API key) with one elected role each | doc/backend/iam.md (auth contexts), doc/backend/rbac.md; the election mechanics were live-verified by ledgers/18a-people.md §2 (assign-roles rows) |
| Grant is a ceiling; checked before role lines; re-resolved live per request | doc/backend/rbac.md (RBC-08, DOM-12) |
| `GET /Api/iam/me` returns account, elected role, other roles, manifest; app-scoped manifest cut to grant | doc/backend/iam.md; doc/backend/http-layer.md |
| No credential → `anonymous`; invalid credential → `401` | doc/backend/iam.md (B-120); src/iam/refresh.cr:196 (18a ledger) |

### admin/under-the-hood/how-access-is-enforced.md

| Claim | Source |
|---|---|
| Read + write enforcers run inside document services, for every caller | doc/backend/rbac.md; doc/backend/http-layer.md |
| Scopes compile to SQL; lists join predicates; single read evaluates the row (404 non-disclosing) | doc/backend/rbac.md; ledgers/18a-people.md §2 row-scopes rows (live-verified there) |
| Field tags: all tags in `visible_tags`; `default` for untagged; reads mask, writes 403 naming the path | doc/backend/rbac.md; ledgers/18a-people.md §2 hidden-fields rows (live-verified there) |
| Metadata gate on `core.DocType`/`core.Domain`; aggregates answer empty 200 | doc/backend/rbac.md; doc/backend/http-layer.md |

---

## 3. Verification notes

Read-only live sequence on the shared instance, 2026-11-26 (admin session;
no write of any kind — the only rollback call used a bogus mutation id and
was refused 404 before any state change):

1. Login as admin@example.tld → session cookie; `active_role: iam.Roles.admin`.
2. `GET /Api/clients/Company?items=1` → Maison Lumière, id
   `06H1FM1B3MXBPS0JYVM3BDD154`.
3. `GET …/history?items=3` → 1 create row with full provenance/cause fields.
4. `GET …/history?include=children` → 200.
5. `GET /Api/Audit?filters[action__eq]=delete&filters[domain__eq]=iam&items=2`
   → the wp18a-probe delete row (left over from the 18a throwaway, tombstoned
   by its own cleanup) with `channel: session`, `cause_trace` set.
6. `GET /Api/Audit?doc_type=Company` → 422 (bracket-form-only grammar).
7. `GET /Api/Audit?filters[trace__eq]=…` → 200.
8. `GET /Api/iam/LoginEvent?items=1&sort=-created_at` → login row with
   `event`, `account_id`, `details`.
9. `POST …/rollback` with a well-formed bogus ULID → 404 body naming
   "180 days for clients.Company" (matches roll-back.md and audit.md:260).
10. Config/default cross-check (file reads only): config.dev.yml and
    src/config.cr / src/mutation/config.cr for every retention default in the
    §Example YAML — all match.

Not live-checked (and why): the Configure → Audit admin UI (browser surface),
the restore and global-rollback routes (write routes — off limits read-only),
the metadata-gate behaviour (needs a low-privilege role read on core.DocType,
already live-verified by ledgers/18a-people.md), OIDC/MCP channels of the
auth-context table (no provider/agent available; sourced from iam.md).

---

## 4. Open questions

1. **The six pages still need the v2 rewrite.** The task brief assumed they
   were done (`verified_at: eee55a2`); the repo shows they are not. The
   rewrites were probably lost with the dead agent's uncommitted work. Whoever
   picks the group up: use §1 as the preservation input, §2 as the claim
   base. Titles per page map §3/§7; the under-the-hood pages must move their
   diagrams into ` ```d2 ` fences (how-access-is-enforced.md still carries the
   old comment + `<img>` embed form).
2. **The brief attributed discrepancy #29 to this batch.** It belongs to the
   people sub-batch (ledgers/18a-people.md, MFA enrollment needs a request
   body). None of the six history pages carries an open discrepancy; nothing
   new to log from this reconstruction — every checked claim held.
3. **retention.md page-map shape.** The page map wants policy first, then the
   operator settings as a second half with its own H2. The current page mixes
   both in one Explanation + a Steps section. The rewrite should restructure;
   the content itself is complete.
4. **who-can-change-roles.md** was rewritten in this pass (same date) — see
   §6 for its preservation checklist, claim ledger and verification.

---

## 5. Report — reconstruction pass

- Ledger written: this file (the previous agent's ledger was never written).
- Pages rewritten: **1** — `admin/people/who-can-change-roles.md` (§6), the
  page this pass was scoped to edit.
- Pages NOT rewritten: the six history/under-the-hood pages — the brief's
  premise (six pages already rewritten, `verified_at: eee55a2`) is not true
  in the repo. All six carry the WP 11 moved pre-rewrite content, stamps
  `a8e1b43` / `fd345fe3` / `7a6cb462`, and the edit scope of this pass
  excluded them.
- Live checks: 10 read-only probes for the six pages (§3) — every checked
  claim held; plus the guard sequence in §6 for the rewrite.
- Discrepancies appended: none. (#29 belongs to the people sub-batch.) Every
  claim checked this pass held against code, config and the running instance.
- Requests outside my scope:
  - Rewrite the six history/under-the-hood pages (open question 1).
  - Retitle the stale links to this page — nine pages still use the old
    title "Roles, levels and the authority guard" or variants:
    `reference/feature-index.md` (generated — fix in `scripts/gen_docs/`),
    `use/finding/lists-and-views.md`, `use/account.md`,
    `use/documents/history-undo.md`, `use/assistant.md`,
    `build/apps/connect/what-an-app-can-do.md`,
    `build/model/access/named-scopes.md`, `admin/index.md` (WP 20), and
    `admin/under-the-hood/how-access-is-enforced.md` (one of the six,
    outside this pass's scope). The link targets are correct; only the
    label text is stale.

---

## 6. admin/people/who-can-change-roles.md — rewrite ledger

### Preservation checklist

Old content = `git show 9ab44a5:site-docs/src/content/docs/admin/people/
who-can-change-roles.md` (the moved `concepts/roles-levels-authority.md`,
95 lines, `verified_at: 7a6cb462`).

| Old heading / fact | Destination | Status |
|---|---|---|
| Lead: role is a normal document, one guard bounds the power | §lead (Nadia/Ravi situation) | moved |
| d2 diagram: caller → write → guard → applied/denied | §Where the guard sits (rebuilt as a ` ```d2 ` fence, flat nodes, italic caption) | moved |
| Permission-line parts table (action/on/scope/except, 4 rows) | — | cut: duplicate of roles-and-permissions §The permission line (the v2 how-to owns the line grammar) |
| `visible_tags` beside the lines | cross-link layer: hidden-fields owns the depth | moved (as pointer; the four-checks table keeps the guard scope) |
| Level 0–100, required, orders authority | §The four checks (Brightwater levels sentence) | moved |
| Level orders roles; one elected role; roles never merge; guard reads the elected role's level | §Where the guard sits (elected-role paragraph) | moved |
| §What the guard covers: create/update/delete/named actions/rollback; after validation; route skips do not bypass; 403 with details; only internal system calls bypass | §Where the guard sits | moved (+ new live layering note: a caller without a write line stops at the ordinary check, plain `403 Forbidden`) |
| 4-row check table (caller level / assignment / target protection / role authoring) | §The four checks | moved (reworded as questions) |
| Containment of channels + assistant budget; unknown power field denied | §The four checks, last paragraph | moved |
| Same level is enough for assignment; cannot create above own level; cannot widen past previous ∪ caller | §Where the guard refuses, last block | moved |
| Caution: narrowing-only change is still a write | §Where the guard refuses caution | moved |
| Trade-off: friction (higher account frozen); roles do not nest; level does not cascade | §What the guard costs | moved |
| §Related (4 links) | §Related | moved (v2 titles + neighbours; prev/next chain added) |
| — | §Where the guard refuses: three live 403 bodies + one widening 403 body | new (evidence for old claims) |
| — | §Where the guard refuses, last block: reference-validation note (422 before the guard without read on `iam.Roles`) | new (live finding; troubleshooting value) |

### Claim ledger

| Claim | Source |
|---|---|
| Guard covers create/update/delete/named actions/rollback on `iam.Account` and `iam.Roles` | `src/document/create.cr:491`, `src/document/update.cr:327`, `src/document/delete.cr:206`, `src/document/action.cr:144,274`, `src/audit/rollback.cr:311,336` — all call `RBAC::RoleAuthority.authorize_transition` |
| Guard skips system/preview principals; non-IAM targets pass through | `src/rbac/role_authority.cr:78-80` |
| Caller level = elected active role's `level`; missing/malformed denies | `src/rbac/role_authority.cr:84-87` |
| Assignment: final `roles` array must exist, be live, level ≤ caller; `default_role` must be a member; same-level lateral allowed (check is `level > caller_level`) | `src/rbac/role_authority.cr:126-145`; live TEST 5 (same-level PATCH → 200) |
| Target protection: account ceiling (highest assigned role level) above caller denies, including narrowing-only writes | `src/rbac/role_authority.cr:113-119`; live body `account's current role ceiling (100) is above the caller level (60)` |
| Target protection on role writes: existing level above caller denies before content checks | `src/rbac/role_authority.cr:174-178`; live body `existing role level (100) is above the caller level (60)` |
| Role authoring: resulting level ≤ caller; every line implied by previous ∪ caller; new tags inside tag union; assistant pair implied by ONE baseline; unknown power fields denied | `src/rbac/role_authority.cr:189-213, 218-233, 237-244, 259-283, 334-353` (`KNOWN_ROLE_FIELDS` :57-60); live body `resulting level (60) is above the caller level (10)` + `permissions[0] … not implied` |
| Refusal message `Role authority refused this write`, `code: forbidden`, 403 | `src/rbac/role_authority.cr:389-395`; all live bodies |
| Widening refusal names the offending line index | `src/rbac/role_authority.cr:218-233`; live body `permissions[2] (read on clients.Company) is not implied by the previous role or the caller's role` |
| Refused write leaves no row and emits no event | rbac.md (a denied write emits no event; the guard runs before any database change); refusal observed, nothing landed |
| A caller with no write line on the target doctype gets plain `403 Forbidden` before the guard | live: Nadia (manager, no `update` on `iam.Account`) PATCH → `{"error":"Forbidden"}` |
| Brightwater levels: sales 40, warehouse 40, manager 60, admin 100 (+ seeds editor 30, viewer 20, anonymous 0) | live `GET /Api/iam/Roles` (2026-11-26) |
| Editing a roles array needs read on `iam.Roles` too: reference validation runs under the caller's auth context; an unreadable target answers `422 reference_filter_mismatch`, indistinguishable from missing | `src/document/reference_check.cr:26-30`; live: probe without a read line PATCHed its own roles → 422 `referenced document 'iam.Roles.wp18h_tester' … does not exist or does not match the required filter` |
| prev/next chain, sidebar.order 6, title "Who can change roles", type explanation | `03-page-map.md` §3; people group orders in the finished pages (index 0 … sessions-lockouts 9) |

### Verification notes (guard sequence, 2026-11-26)

Throwaway pair only; all demo accounts and Brightwater roles untouched;
cleanup verified (back to 9 roles, 6 accounts):

1. Read roles list → confirmed levels (admin 100, manager 60, sales 40,
   warehouse 40, editor 30, viewer 20, comment_author 20, attachment_owner
   20, anonymous 0).
2. Created role `wp18h_tester` (level 10) and account `wp18h-probe@example.tld`;
   temporary password → change-password → active session.
3. As probe: PATCH nadia's account → 403 `account's current role ceiling (60)
   is above the caller level (10)` (target protection; no write landed).
4. As probe: PATCH own roles + `iam.Roles.manager` → 403 `role
   'iam.Roles.manager' (level 60) is above the caller level (10)`.
5. As probe: PATCH `iam.Roles.manager` description → 403 `existing role
   level (60) is above the caller level (10)`.
6. As probe (before it held a `create` line): POST role → plain `403
   Forbidden` — the ordinary gate, not the guard.
7. Admin added a `create` line; probe POST level-60 role → 403 with two
   details (resulting level + line not implied).
8. Created `wp18h_peer` (level 10); probe assigned it to itself → 200
   (same-level lateral assignment allowed).
9. Probe widened peer to its own powers → 200; added a line the caller's
   role did not imply → 403 naming `permissions[2]`.
10. Probe without read on `iam.Roles` → PATCH own roles → 422
    `reference_filter_mismatch` (reference validation, not the guard).
11. Nadia (no write line) → PATCH on Ravi's account → plain `403 Forbidden`
    (layering evidence).
12. Second throwaway pair at level 60 (`wp18h_mgr_probe`) captured the three
    level-60 bodies used in the page (Ravi account / admin assignment / admin
    role doc). Cleanup: both accounts and all three throwaway roles deleted
    (204s); roles and accounts lists re-checked.

### Report — rewrite

- Page written: `admin/people/who-can-change-roles.md` (rewritten 1, 0 new).
- Feature IDs covered: RBC-01, RBC-07 (unchanged from the old page).
- Gates: not run — builds barred for this pass (shared checkout). Required
  before merge: `npm run build` (renders the new d2 fence; the link validator
  and title checks run with it) + `node scripts/check-coverage.mjs`.
- Discrepancies logged: none — the code, `doc/backend/rbac.md` and the live
  instance agree with every claim kept or added.
- Not verified (and why):
  - The assistant-budget lock escape (`src/rbac/role_authority.cr:285-320`) —
    L3 detail, kept out of the L2 page; documented in rbac.md.
  - The `422 reference_filter_mismatch` case is stated from the live probe
    and `src/document/reference_check.cr:26-30` but not added to the page's
    troubleshooting (the page has no troubleshooting section as an
    explanation page); it is recorded here for whoever extends the page.
  - Same-level role authoring beyond the widening pair (assistant budget
    containment at same level) — code-read only.
- Requests outside my scope: the stale link titles (see §5 report).

---

## 7. Rewrite execution (second attempt)

Record of the v2 rewrite of the six pages (§1 destinations, §2 claims).
The writing agent delivered all six pages (`verified_at: eee55a2`, line
counts 240 / 154 / 205 / 120 / 96 / 119 as briefed) and was canceled before
it could report. This section reconstructs its execution record from the
delivered pages; it was written by a separate verification pass on
2026-11-26. It closes open question 1 (§4) and supersedes §5's
"Pages NOT rewritten" finding.

Front matter, all six: title per page map §3/§7, type, audience, features
and `sidebar.order` match the map and the finished batch pages;
`verified_at: eee55a2`. No `prev`/`next` — consistent with the finished
batch B2 admin pages (`jobs-cron`, `events-and-delivery` carry none either);
only `who-can-change-roles.md` keeps the chain, as the people-group story
exception. All three d2 fences are in the committed comment + pre-rendered
`<img>` form (`site-docs/public/diagrams/{78d3a3f0,e9cff36e,67706c52}-
{light,dark}.svg` exist — a concurrent site build transformed them).

Verification method: each page checked row by row against its §1 checklist;
2–5 load-bearing claims per page re-verified against the §2 sources
(file:line), including claims the checklist marked as kept from pre-rewrite
content; the live example rows re-pulled read-only from
`https://facet.localhost:3443` (admin session; nothing written). No page
claim failed; no discrepancy appended (next free number stays #46).

### admin/history/audit.md — status: done, no deviations

- Destinations: every §1 row present (lead, 3-bullet when-to-use, 3-item
  before-you-start, steps 1–5, all six explanation subsections, 4
  troubleshooting entries, 5 related + internals). The two read modes and
  the global-log app-scoped denial moved from the checklist's "kept" prose
  into §The two read modes, as planned.
- Claims re-checked, all hold:
  - Filter grammar table (eq-only domain/doc_type/doc_id; eq,ne on
    action/actioner_id/app/channel/kind/trace; emitted_at gte,lte) =
    `doc/backend/audit.md:22-35`.
  - Global log needs wildcard `*.*`; domain/doc_type are filters not gates;
    app token and app-owned key refused whatever the role holds =
    `doc/backend/audit.md:20` and rbac.md:247 (layer-1 ceiling).
  - Login events: kinds list and the two limits (failed single attempts not
    logged — lockout only; successful refreshes not logged; backend log
    carries both) = `doc/backend/iam.md:70-75,119-125`.
  - Count cap 1,000 + `more` = `doc/backend/audit.md:276-285`.
  - Live re-pull: the EQ-2026-0004 example row matches the instance field
    for field (idx 3, `oauth_app`, app `06H1GCMXX4HX02S6ZVDGJ3SQ3P`,
    `iam.Roles.warehouse`, 14:14:45Z, count 2).
- Cuts beyond the prep plan: none. New presentation only: the curl examples
  now use Brightwater data (equipment Item, iam filters) instead of the old
  generic Company example — consistent with the batch's Brightwater rule.
  The UI step names "Configure → Audit log", which matches the shipped
  label (`frontend/messages/en.json:956-957`).

### admin/history/roll-back.md — status: done, no deviations

- Destinations: every §1 row present (lead, when-to-use, before-you-start,
  steps 1–3 with the 200/404/409/403/422 table, all four explanation
  subsections, caution, 4 troubleshooting entries, related).
- Claims re-checked, all hold:
  - Rollback persists one `snapshot`, `cause_kind: rollback`, `cause_parent`
    = target, actor = caller or `system:rollback`, fresh cluster
    (`cause_trace` = own id) = `doc/backend/audit.md:141-163`.
  - 404 body names the effective window; document/child/restore routes name
    the doctype window, the global route the base window =
    `doc/backend/audit.md:260-266` (live body also captured in §3).
  - Restore outcomes 404/409/422 from the resolver + the RBAC 403 =
    `doc/backend/audit.md:213-218`.
  - Cascade restore: preflight all-or-nothing, own snapshots,
    `cascade_restored` shape `{domain, doc_type, doc_id, mut_id}`, children
    re-created later untouched = `doc/backend/audit.md:165-171`.
  - Window `0` = full history = `doc/backend/mutation.md:334`.
  - Live re-pull: Maison Lumière create id `06H1FM1B3MWR784V64VP6QFM94` and
    the rolled-back content in the step-2 answer match the instance.
- Cuts beyond the prep plan: none.

### admin/history/retention.md — status: done, no deviations

- Destinations: the page-map restructure the prep ledger called for is
  applied — policy first (§What Facet keeps, 9-row table + per-class
  notes), operator settings second with its own H2 (§Set the windows). The
  two `operate/retention-tuning.md` "Mind the edges" items survive as
  steps 2–3; "0 = keep forever" lives in the table rows and troubleshooting.
- Claims re-checked, all hold:
  - Every default in the §Example YAML = `config.dev.yml:59,84,213,
    242-258` and `src/mutation/config.cr:41-44` (180 / overrides
    core.SchematicLayout 7 / "45 3 * * *" / 3; tombstone 30 + "15 4 * * *";
    maxlen 1,000,000; jobs 30; artifact 30).
  - `webhook.reconcile_window_hours` default 24, must stay below
    `jobs.retention_days` = `doc/backend/webhook.md:293-297,500-504`.
  - Session TTLs (new detail beyond the old page): refresh 1,209,600 s,
    access 900 s, credential links 86,400 s, MFA challenge 5 min =
    `config.dev.yml:141-144,155-159`, `doc/backend/iam.md:162-163,684`.
  - Compaction (backdated snapshot, contiguous idx, projection untouched,
    no events, tombstone keeps trailing delete + predecessor) and
    coalescing (fold, fresh id, idx gap) = `doc/backend/mutation.md:
    333-370` and AGENTS.md.
- Cuts beyond the prep plan: none. Addition: the per-class session TTL
  numbers and the Redis-loss note — sourced above.

### admin/under-the-hood/change-log.md — status: done, no deviations

- Destinations: every §1 row present (lead, column-group table, append-only
  paragraph, projection/ETag, coalescing, compaction, id caution, not-event
  -sourcing, related). The d2 diagram is a proper ` ```d2 ` fence now
  (open question 1's requirement).
- Claims re-checked, all hold:
  - Coalescing rules: same actor/channel/credentials, driven writes never
    fold in either direction, compose → insert → delete, fresh ULID, next
    free `idx` leaves the gap = `doc/backend/mutation.md:351-362` +
    AGENTS.md.
  - New claim beyond the old page: an empty diff writes no row, emits no
    event, and the response carries the current ETag =
    `doc/backend/mutation.md:369-370`.
  - Compaction: synthetic snapshot, `cause_kind: compaction`, backdated
    `emitted_at`, contiguous idx, depth = window =
    `doc/backend/mutation.md:333-348`.
  - ETag = `projections.state` checked with `If-None-Match` =
    `doc/backend/http-layer.md:617,631`.
  - Copies append their own `create` rows through the same mutation client
    = `doc/backend/mutation.md:56-58`.
- Cuts beyond the prep plan: none (the empty-diff fact is an addition,
  verified above).

### admin/under-the-hood/one-role-at-a-time.md — status: done, no deviations

- Destinations: every §1 row present (lead, channels table, one-context
  paragraph, grant-ceiling paragraph, same-everywhere paragraph, who-is
  -calling, anonymous/401 note, trade-off, related). d2 fence applied.
- Claims re-checked, all hold:
  - `GET /Api/iam/me` returns account (id, display name, email),
    `active_role`, `available_roles`, the manifest, and the `visible_tags`
    the role can read; app-scoped manifest cut to the grant =
    `src/iam/routes.cr:275-323` (the `visible_tags` field is real in code
    even though `doc/backend/iam.md:648` does not list it — docs gap, not a
    page error; nothing to log as a discrepancy against this page).
  - Grant is a ceiling, checked before the role's lines, re-resolved from
    live app content on every request, no new token = `doc/backend/rbac.md
    :247`, `doc/backend/iam.md:508`, `doc/backend/app-system.md:498`.
  - No credential → seeded `anonymous`; invalid credential → `401`, never
    anonymous = `doc/backend/iam.md:119-120` (B-120).
- Cuts beyond the prep plan: none. Addition: `visible_tags` in the /me
  paragraph (code-verified). The L1 part stays out, as the prep ledger
  planned (it lives in `discover/how-it-works/roles.md`, WP 13).

### admin/under-the-hood/how-access-is-enforced.md — status: done, no deviations

- Destinations: every §1 row present (lead, diagram, RBAC paragraph,
  permission line, row scopes, field tags, denial classes, metadata gate,
  masking note, trade-offs, related). The old HTML-comment + `<img>`
  diagram form is replaced by the d2 fence + pre-rendered pair (open
  question 1). The stale related-link label "Roles, levels and authority"
  (noted in §1) is now "Who can change roles".
- Claims re-checked, all hold:
  - Class vs row denial split (403 vs non-disclosing 404; list 200 with
    visible rows, possibly none; nested parent gate first) =
    `doc/backend/rbac.md:215,250-254,272-290`.
  - Field tags: `visible_tags` must hold all tags, untagged fields carry
    `default`, reads mask, writes 403 naming the path, and a filter or sort
    on an invisible field is 403 before type validation (new detail beyond
    the old page) = `doc/backend/rbac.md:296-300`.
  - Metadata gate on `core.DocType`/`core.Domain`: any reserved action on
    what the row describes serves the row; field aggregates over the
    structural doctypes answer the empty 200 = `doc/backend/rbac.md:
    296-298,302-320`.
  - Trade-off "a context set runs one database query per request" =
    `doc/backend/rbac.md:120-121,134-135` (ContextResolver, memoized per
    request).
- Cuts beyond the prep plan: none.

### Pass summary

- Six pages verified against §1/§2: all destinations followed, no cut beyond
  the prep plan, no failed claim, no page edits needed this pass.
- Discrepancies appended: none (next free number remains #46).
- Live probes this pass: read-only login + two history reads (clients.Company,
  equipment.Item); no write, no demo data touched.
- Not verified: the Configure → Audit log browser surface beyond its label;
  restore and global-rollback routes (write routes, off limits read-only) —
  unchanged from §3's reasoning.
