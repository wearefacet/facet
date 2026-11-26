---
type: explanation
title: The mutation log
description: Every accepted write appends one row that records who changed what, how, and why, and serves audit and rollback.
audience: [evaluator, developer]
features: [AUD-01, AUD-05, AUD-08, DOC-08]
sidebar:
  order: 1
verified_at: 7a6cb462
---

Facet keeps history in a plain database table. Every accepted write appends
exactly one row to `mutations`. The row records the change, the actor, and
the cause. Reads never parse the log; they read current state from the
projections.

## Explanation

| Group      | Columns                                                                  | What they record                                              |
| ---------- | ------------------------------------------------------------------------ | ------------------------------------------------------------- |
| Target     | `domain`, `doc_type`, `doc_id`, `idx`                                    | Which document changed, and its per-document order            |
| Payload    | `action`, `arguments`                                                    | `create`, `update`, `delete`, or `snapshot`, with content or diff |
| Provenance | `actioner_id`, `channel`, `app`, `api_key`, `acting_role`               | Who wrote the row, and through which surface                  |
| Cause      | `cause_kind`, `cause_name`, `cause_event`, `cause_source`, `cause_parent`, `cause_trace` | What triggered the write, one hop per row, and its causal cluster |

Writers only append. No application path edits a row in place. A write the
enforcers refuse leaves no row at all, because the permission check runs
before any database change. System writes carry the same stamps: the
channel column is never empty, database triggers included.

A database trigger applies each mutation to `projections`, the table that
holds current state. Reads never replay history. The projection stores the
id of its last mutation, and reads return that id as the entity tag (ETag),
the version tag a client checks with `If-None-Match`. Document copies
travel the same path: a copy appends its own `create` rows through the same
mutation client, with the same audit shape as any other write.

Two mechanisms keep the table bounded:

- **Write-time coalescing.** When the same actor writes through the same
  channel and credentials inside the window (three minutes by default),
  Facet folds the two updates into one row. The merged row gets a fresh
  id. The previous id stops resolving for the rest of the window; a fetch
  answers `404`. The projection stores the fresh id, so its ETag matches
  the served content. A window of zero disables the fold.
- **Retention compaction.** A daily job replaces every mutation older than
  the retention window (180 days by default) with one synthetic snapshot.
  Replay stays possible from that boundary. Rollback depth equals the
  window: a target older than the window answers `404`. A deleted document
  keeps its trailing delete and the row before it, so restore stays
  reachable inside the window.

:::caution
Do not treat a mutation id as a permanent reference. A coalesced fold makes
the old id answer `404` inside the window, and compaction removes rows past
the retention window. Read the document history when you need current rows.
:::

### Why this is not domain event sourcing

The log serves two jobs inside this application: audit and state. Replay
exists, but only in the service — rollback and compaction replay a
document's rows to rebuild a state. No external consumer replays the log.
It is not the integration contract of the product.

**Reactions travel separately.** Reactions to a write travel on a separate
mechanism. After the database commit, the write path publishes events to
Redis Streams. Hooks, webhooks, replication, and live updates consume there.
Delivery on that bus is at-most-once by decision. PostgreSQL stays the data
of record.

**The trade-offs are deliberate.** Coalescing hides intermediate states: two
rapid saves leave one row. Compaction caps how far back an undo can reach.
In exchange, the log stays bounded, and storage stays predictable.

## Related

- [Architecture at a glance](/discover/how-it-works/) — the log's place in the write path.
- [Documents, doctypes and projections](/build/deeper/documents-and-projections/) — the current state the log feeds.
- [Events and delivery](/admin/under-the-hood/events-and-delivery/) — the reaction bus, separate from this log.
- [Glossary](/reference/glossary/) — the mutation term, defined in one line.
- [Govern access](/admin/) — the retention rules for the history the log keeps.
- Internals on GitHub: [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
