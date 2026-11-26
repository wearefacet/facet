---
title: The change log, in detail
description: The change log appends one row per accepted write — who changed what, how, and why — and serves audit and rollback.
type: explanation
audience: [developer, admin]
features: [AUD-01, AUD-05, AUD-08, DOC-08]
verified_at: eee55a2
sidebar:
  order: 1
---

Facet keeps history in a plain database table. Every accepted write appends
exactly one row to `mutations`. The row records the change, the actor, and
the cause. Reads never parse the log; they read current state from the
projections. The sections below walk one row, the two mechanisms that bound
the table, and the reason Facet does not call it event sourcing.

*One write, one row; the current state lives beside it, not inside it.*

<!-- d2
direction: down
caller: "Caller writes a document" {class: external}
row: "One row appended to mutations" {class: store}
trigger: "Projection trigger applies the row"
projection: "projections: current state" {class: store}
reader: "Readers and the ETag" {class: external}

caller -> row
row -> trigger
trigger -> projection
projection -> reader
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/78d3a3f0-light.svg" alt="Caller writes a document" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/78d3a3f0-dark.svg" alt="Caller writes a document" loading="lazy" />
</div>

## The columns

| Group | Columns | What they record |
| --- | --- | --- |
| Target | `domain`, `doc_type`, `doc_id`, `idx` | Which document changed, and its per-document order |
| Payload | `action`, `arguments` | `create`, `update`, `delete`, or `snapshot`, with content or diff |
| Provenance | `actioner_id`, `channel`, `app`, `api_key`, `acting_role` | Who wrote the row, and through which surface |
| Cause | `cause_kind`, `cause_name`, `cause_event`, `cause_source`, `cause_parent`, `cause_trace` | What triggered the write, one hop per row, and its causal cluster |

Writers only append. No application path edits a row in place. A write the
enforcers refuse leaves no row at all, because the permission check runs
before any database change. System writes carry the same stamps: the channel
column is never empty, database triggers included.

## The projection and the ETag

A database trigger applies each row to `projections`, the table that holds
current state. Reads never replay history. The projection stores the id of
its last row, and reads return that id as the entity tag (ETag). A client
checks that tag with `If-None-Match`. Document copies travel the same path:
a copy appends its own `create` rows through the same mutation client. The
audit shape matches any other write.

## Two mechanisms keep the table bounded

### Write-time coalescing

When the same actor writes through the same channel and credentials inside
the window, Facet folds the two updates into one row. The window is
`mutations.coalesce_window_minutes`, three minutes by default. The merged row
gets a fresh ULID. The previous id stops resolving for the rest of the
window; a fetch answers `404`. The projection stores the fresh id, so its
ETag matches the served content. A window of zero disables the fold.

Three rules bound what may fold:

- Only plain root requests fold. A driven write — an action's own update, a
  nested `document.*` write, an assistant tool call, a replication recompute
  — never folds, and never folds into.
- The fold composes the two diffs into one, inserts the merged row, and then
  deletes the previous row. The merged row takes the next free `idx`, so the
  previous position stays vacant — the gap is the clue that rows folded.
- A write whose diff is empty against the live content writes no row at all
  and emits no event; the response carries the current ETag.

### Retention compaction

A daily job replaces every row older than the retention window
(`mutations.retention_days`, 180 days by default) with one synthetic
`snapshot` row stamped `cause_kind: compaction`. The snapshot keeps the
original timestamp, so the audit timeline stays truthful, and the row order
stays contiguous. Replay stays possible from that boundary. Rollback depth
equals the window: a target older than the window answers `404`. A deleted
document keeps its trailing delete and the row before it, so restore stays
reachable inside the window.

:::caution
Do not treat a mutation id as a permanent reference. A coalesced fold makes
the old id answer `404` inside the window, and compaction removes rows past
the retention window. Read the document history when you need current rows.
:::

## Why this is not domain event sourcing

The log serves two jobs inside this application: audit and state. Replay
exists, but only in the service — rollback and compaction replay a
document's rows to rebuild a state. No external consumer replays the log.
It is not the integration contract of the product.

**Reactions travel separately.** After the database commit, the write path
publishes events to Redis Streams. Hooks, webhooks, replication, and live
updates consume there. Delivery on that bus is at-most-once by decision.
PostgreSQL stays the data of record.

**The trade-offs are deliberate.** Coalescing hides intermediate states: two
rapid saves leave one row. Compaction caps how far back an undo can reach.
In exchange, the log stays bounded, and storage stays predictable.

## Related

- [Architecture at a glance](/discover/how-it-works/) — the log's place in the write path.
- [Documents and projections](/build/deeper/documents-and-projections/) — the current state the log feeds.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the reaction bus, separate from this log.
- [See who did what](/admin/history/audit/) — reading the log as an administrator.
- [Retention: what is kept](/admin/history/retention/) — the windows that bound the table.
- [Glossary](/reference/glossary/) — the mutation term, defined in one line.
- Internals on GitHub: [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
