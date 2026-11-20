# Plan — Restore a dropped domain (`Domain::Restore`)

Status: **draft — feasibility study. Awaiting decisions (§8). No code
written.** Verified against the tree on 2026-11-13. Extends
[`../backend/draft-domains.md`](../backend/draft-domains.md) (`Domain::Drop`,
`Scratch`) and [`../backend/audit.md`](../backend/audit.md) (restore and
rollback machinery).

Motivation: the 2026-11-13 dev-database incident. A published domain
(`recycling`) was dropped after a bundle export; the bundle re-import failed
(the empty-script gate bug, fixed in commit `008dd880` the same day), and the
audit rollbacks the user tried instead restored one orphaned doctype row —
the domain stayed gone.

---

## 1. Summary

`Domain::Drop` tears a domain down with one `delete` mutation on the
`core.Domain` document plus direct-SQL tombstones for everything else. The
teardown writes no mutation rows for the destroyed surface, so the audit
rollback machinery cannot undo a drop:

- `Audit::Rollback`'s cascade restore follows `cause_kind = 'cascade'`
  mutation rows. The teardown writes none.
- Rolling back the `core.Domain` delete resurrects an empty domain shell.
- Rolling back a child row (a `core.DocType` create) resurrects that one row
  as an orphan. Both effects showed up in the incident.

This plan studies option (c): a first-class **`Domain::Restore`** service
plus route and CLI that inverts the teardown. The core insight makes it
cheap: **the teardown is soft.** Every destroyed projection row is a
tombstone that still holds its exact at-drop content, until
`Cron::TombstoneContentPrune` clears the payload after
`tombstone.content_retention_days` (default 30). A restore is the inverse bag
of SQL plus rebuild steps for the three things a drop destroyed beyond
tombstones.

## 2. Current state (verified against the code)

### 2.1 What a drop destroys, and what survives

| Surface | Drop behaviour | Where | Restorable from |
|---|---|---|---|
| `core.Domain` row | tombstone (via the one delete mutation) | `src/domain/drop.cr` | tombstone payload |
| `core.DocType` rows of the domain | tombstone (direct SQL, no mutations) | `src/domain/scratch.cr` → `dispose_definitions!` | tombstone payload |
| `core.DocumentView` + general `core.CollectionView` rows | tombstone | same | tombstone payload |
| `core.DomainEditor` rows (editor grants) | tombstone | same | tombstone payload |
| Data rows (`projections WHERE domain = $1`) + personal CollectionViews | tombstone (`dispose!`) | same | tombstone payload |
| `doctype_indexes` tracking rows | **hard delete** | same | re-derive (`Index::Manager.sync`) |
| `artifact_owners` + `artifact_references` | **hard delete** (grants cascade) | same | re-derive from document content |
| `mutations` log | untouched | — | survives in full |
| `sequence_identifiers` rows | untouched | — | survive (sequence numbering continues) |

The runtime replication registry derives its bindings from live definitions
(`Replication::Registry`), so a restore needs no replication-table work. Side
observation: the `replication_subscriptions` table (migration `0004`) has no
reader or writer in `src/` today — nothing maintains it, so nothing needs
restoring. (Worth a separate cleanup decision, out of scope here.)

### 2.2 The clock that bounds the restore

Two retention clocks exist:

- `tombstone.content_retention_days` (default 30) — `Cron::TombstoneContentPrune`
  clears `content`/`links`/`search` on tombstones past the window.
  `display_name` survives forever (audit labelling).
- `mutations.retention_days` (default 180) — `Cron::MutationCompaction`
  compacts old history. Irrelevant here: restore reads tombstones, not the
  log.

The binding clock is the tombstone one: **a restore is only possible within
`tombstone.content_retention_days` of the drop.** Past it, the definitions
and the data are gone from the tombstones; only names survive.

### 2.3 Artifact prune interplay

The artifact prune is join-derived (`src/artifact/prune.cr`): after a drop,
the domain's artifacts have no live owner rows and (as references age out)
become eligible. The default prune **soft-deletes** the `artifacts` row;
`--hard` purges row + bytes. So a restore within the window relinks live
artifacts; a restore after a soft prune meets soft-deleted rows (operator
recovery); after a hard purge the document fields keep dangling ids — the
same accepted behaviour as deleting any referenced artifact.

## 3. Design

### 3.1 Two scopes, mirroring `Scratch`

The restore mirrors the teardown's own scope split, so the mental model stays
symmetric:

- `restore_definitions!` — the `core.Domain` row, the domain's `core.DocType`
  rows, their `DocumentView`/general `CollectionView` rows, and the
  `DomainEditor` rows.
- `restore!` — everything above, plus the domain's data rows and personal
  CollectionViews, plus the artifact provenance rebuild.

A `definitions_only` flag exposes the first scope alone (§8 D1).

### 3.2 The inverse operation

| Drop did | Restore does |
|---|---|
| Tombstone `core.Domain` (via the delete mutation) | `persist_snapshot_mutation` with the tombstone's own content/meta — the snapshot clears `deleted_at` and writes the audit row (the exact primitive `Audit::Rollback` uses; the incident proved a snapshot resurrects a tombstoned row) |
| Tombstone `core.DocType` rows | per row: `persist_snapshot_mutation` (definition surface is small — pay the audit row) |
| Tombstone view rows | per row: `persist_snapshot_mutation` |
| Tombstone `DomainEditor` rows | per row: `persist_snapshot_mutation` |
| Tombstone data rows | direct `UPDATE … SET deleted_at = NULL` (mirror of the teardown, which wrote no per-row mutations); derived columns (`search`/`links`/`display_name`) ride along in the tombstone and stay correct because the definitions come back unchanged |
| Hard-delete `doctype_indexes` | `Index::Manager.sync` per restored doctype — idempotent (`CREATE INDEX IF NOT EXISTS`), re-creates the tracking rows; failures land on `facet index:retry`. Physical PG indexes may have survived the drop; the sync reconciles both cases |
| Hard-delete `artifact_references` | per restored data row: `ArtifactRefs` reconcile from content (the same walk `persist_snapshot_mutation(reconcile_artifact_refs: true)` performs) |
| Hard-delete `artifact_owners` | per restored data row: `Artifact::Owners.append_for_document` as system — idempotent (`ON CONFLICT DO NOTHING`); re-files the read-provenance rows |
| (publish/import only) grant tickets | re-run `Grants::PublishTickets.file` over the restored definitions — idempotent merge, mirrors `Portable::Import` (§8 D7) |

Ordering matters: domain row first (the RBAC and scope predicates read it),
then doctypes (definitions before data), then views and editors, then data,
then the rebuild passes (indexes, artifact provenance, tickets).

### 3.3 Audit and event semantics

- One `snapshot` mutation per definition-surface row, `cause_kind = 'rollback'`,
  `cause_event = 'rolled_back'` — the same vocabulary the document restore
  endpoint already uses. No CHECK-constraint change, no webhook-vocabulary
  change (`rolled_back` is already in `Event::WEBHOOK_EVENT_NAMES`).
  A dedicated `restore` cause kind would cost a migration plus a
  `derive_event_name` entry plus a webhook-vocabulary entry (§8 D2).
- Data rows get no per-row mutations (mirror of the drop). The response
  carries counts per surface so the operator sees what came back.
- Events: one `rolled_back` event on the `core.Domain` stream. The doctype
  cache invalidation makes running servers pick the definitions up; no
  per-document event fanout (a large domain would flood the bus for no
  subscriber benefit).

### 3.4 Guards (mirror `Domain::Drop`)

| Guard | Behaviour |
|---|---|
| Live-id collision | a live `core.Domain` row with the id → `409`. (The suite already proves a dropped id can be re-created live — `spec/domain/domain_create_guard_spec.cr` — so the collision case is real.) |
| System domains | `core` / `iam` / `app` → `422` (same `PROTECTED_DOMAINS` list) |
| Retention window | any definition-surface tombstone whose payload is pruned (`content = '{}'`) → `422` naming the window; a partial restore is worse than a refused one (§8 D4) |
| Not found | no tombstoned row with the id → `404` |
| Drafts | the `draft` flag rides the content; restoring a dropped draft hands the draft back (§8 D6) |
| RBAC | `WriteEnforcer.authorize_update` on the `core.Domain` row — the same gate the document restore path effectively applies (§8 D5) |

Transaction shape: the definition surface restores in **one transaction**
(all-or-nothing, like the drop); data rows restore in a streaming pass —
batched direct updates, the `Reproject`/`AheadMigration` shape — so a large
domain never runs one giant transaction.

### 3.5 The drift risk — the real architectural cost

`dispose!` and `restore` are twin bags of scope predicates. If a future
change adds a surface to the teardown and not to the restore, the restore
silently under-recovers. Mitigations, both mandatory:

1. A **round-trip spec**: seed a domain with doctypes, views, editors,
   documents (including composition children and a file-field document with
   an artifact), drop it, restore it, and assert the live set matches the
   pre-drop state row for row — content, meta, derived columns, index
   tracking rows, owner rows, reference rows. This spec is the single most
   important deliverable.
2. Colocation: the restore lives beside the teardown
   (`src/domain/restore.cr`, next to `scratch.cr`), with a comment on each
   scope naming its twin.

## 4. Complexity register

| # | Edge | Severity | Handling |
|---|---|---|---|
| 1 | Tombstone payload retention bounds the restore | fundamental | refuse loud past the window (§3.4) |
| 2 | `artifact_owners.view_tag` is an attach-time snapshot; the rebuild re-snapshots from the **current** definition | subtle | accept + one doc sentence: tag changes between attach and drop shift the rebuilt ACL floor |
| 3 | Artifact prune (soft by default) may have soft-deleted an artifact before the restore | subtle | detect during relink; surface a warning listing dangling ids; hard-purged ids stay dangling (accepted document behaviour) |
| 4 | Cause vocabulary has no `restore` kind | low | reuse `rollback` (§3.3, D2) |
| 5 | Live-id collision | low | `409` guard (§3.4) |
| 6 | Twin-bag drift | the real cost | round-trip spec + colocation (§3.5) |
| 7 | Audit granularity at scale | low | no per-data-row mutations; counts in the response |
| 8 | Compaction interplay | none | restore reads tombstones, not the log |
| 9 | `replication_subscriptions` | none | table is unmaintained today; registry rebuilds from definitions |

## 5. Alternatives considered

| Option | Idea | Verdict |
|---|---|---|
| (a) Document the limit | recovery = re-import a bundle (works for definitions even past the tombstone window, but needs an exported bundle and rebuilds history as new mutations) | stays as the documented fallback for old drops; not a first-class tool |
| (b) Make `Drop` write cascade delete mutations for the whole surface | the generic `Audit::Rollback` + cascade restore machinery undoes a drop end to end | much heavier drop; per-row mutation cost on every drop forever; rebuild work (indexes, provenance) still missing — rollback alone would not restore them |
| (c) `Domain::Restore` (this plan) | keep `Drop` exactly as is; add a bounded, domain-scoped inverse | drop stays cheap; recovery gets a named surface with its own guards; composes with (a) |

## 6. Scope

| Slice | Work |
|---|---|
| Backend | `src/domain/restore.cr` (service + guards), `POST /Api/core/Domain/:id/restore` in `src/domain/routes.cr`, CLI `facet domain:restore <name>`, event + cache wiring, specs (round-trip first) |
| Docs | a Restore section in `../backend/draft-domains.md`, an owner-row caveat in `../backend/artifact.md`, a quirk line in `../backend/workflow.md`; retire this plan into them |
| Frontend (optional, D3) | a "dropped domains" section on `Configure → Domains` (tombstoned `core.Domain` rows — `display_name` survives pruning, so the list works forever) with a Restore action |

## 7. Effort estimate

1.5–2 days backend + specs; +0.5–1 day for the frontend section. The
round-trip spec is the largest single item.

## 8. Discuss-first decisions

| # | Question | Proposal |
|---|---|---|
| D1 | Restore scope: definitions only, or definitions + data? | Definitions + data, with a `definitions_only` flag |
| D2 | Cause kind: reuse `rollback`, or add a real `restore` kind? | Reuse `rollback` — no migration, no webhook-vocabulary change |
| D3 | v1 surface: route + CLI only, or with the Configure UI section? | Route + CLI first; UI as a fast follow |
| D4 | Behaviour past the retention window | Refuse with `422` naming the window — a partial restore is worse than a refusal (definitions are pruned too, so there is no definitions-only fallback) |
| D5 | RBAC gate | `authorize_update` on the `core.Domain` row (the document restore gate), not `authorize_delete` |
| D6 | Restoring a dropped **draft** | Allow — the `draft` flag rides the content and the same code path covers it |
| D7 | Re-file grant tickets on restore? | Yes — idempotent merge, mirrors `Portable::Import` |

## 9. Phases

1. **Service core.** `Domain::Restore` with guards, definition-surface
   restore, the round-trip spec. `make check` green.
2. **Data restore.** Streaming data-row pass, artifact reference + owner
   rebuild, index sync, counts in the result. Round-trip spec extended to
   data + provenance.
3. **Surface.** Route, CLI, event, cache invalidation, integration specs
   (collision, retention refusal, system-domain refusal, RBAC).
4. **Frontend (D3).** Dropped-domains section + Restore action, stories.
5. **Finalize.** Full `make test`, `bin/ameba`, `pnpm check` (if UI), docs,
   retire the plan.

## 10. Verification gates

- Isolated specs during development (`crystal spec spec/domain/restore_spec.cr`);
  `make test` once at finalization (`make test_db_up` first).
- `bin/ameba` clean; `pnpm check` clean when the UI phase lands.
- The round-trip spec must assert per surface: projections (content, meta,
  derived columns, `deleted_at`), `doctype_indexes` rows, `artifact_owners`
  rows, `artifact_references` rows.

## 11. What this plan will not do

- **Point-in-time restore.** The restore target is always the at-drop state
  (the tombstones). No arbitrary-mutation time travel.
- **Restore past the retention window.** Refused by design (D4).
- **Audit-log replay as a restore source.** The tombstones are the source of
  truth; the log stays an audit surface.
- **`replication_subscriptions` maintenance.** Nothing writes the table
  today; if it gains a writer, the restore gains a step (and a round-trip
  assertion).

## 12. Relationship to other docs and plans

- [`../backend/draft-domains.md`](../backend/draft-domains.md) — hosts the
  `Domain::Drop` / `Scratch` contract today; the implemented Restore section
  lands there when this plan retires.
- [`../backend/audit.md`](../backend/audit.md) — the cascade-restore section
  gains a pointer: domain drops are undone by `Domain::Restore`, not by
  rollback.
- [`../backend/artifact.md`](../backend/artifact.md) — the owner-row rebuild
  caveat (§4 edge 2) lands in the Prune section.
- The incident's import failure is a separate, already-fixed bug (the
  empty-script gate, commit `008dd880`) — not part of this plan.
