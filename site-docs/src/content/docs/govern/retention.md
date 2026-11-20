---
title: "Retention: what is kept and for how long"
description: See what Facet keeps for documents, mutations, events, tombstones, sessions, and files, and where each window is set.
audience: [admin, evaluator]
features: [AUD-05, AUD-06, AUD-07]
sidebar:
  order: 12
verified_at: fd345fe3
---

Facet keeps several classes of data with different lifetimes. PostgreSQL holds
the durable state. Redis holds short-lived state. This page lists what each
class keeps, the window that bounds it, and where you set the window.

## When to use this

- You write the data-retention policy for your organization.
- You set the windows for a deployment.
- You answer how far back a rollback can reach.

## Explanation

### What each class keeps

| Data class | What is kept | For how long |
| --- | --- | --- |
| Documents | The current state of every live document. | While the document lives. A delete makes a tombstone; it does not remove the row. |
| Mutations | The full change log of every document. | `mutations.retention_days`, default 180. `0` keeps everything. Older rows fold into one snapshot row per document. |
| Coalesced updates | Same-actor, same-channel updates inside `mutations.coalesce_window_minutes`, default 3, fold into one row. | The folded row replaces the old one. The old id answers `404` inside the window. |
| Tombstones | A deleted document keeps its content, links, and search text. The label and metadata stay. | The prune clears the payload after `tombstone.content_retention_days`, default 30. `0` keeps it forever. |
| Events | Each Redis stream keeps recent events for reactions. | Trimmed at `event.maxlen`, default 1,000,000 entries per shard. Delivery is at-most-once; PostgreSQL holds the durable state. |
| Jobs and webhook calls | Finished background-job rows and webhook call rows. | `jobs.retention_days`, default 30. |
| Sessions and tokens | Refresh sessions, access tokens, MFA challenges, credential links. | Refresh session 14 days. Access token 15 minutes. MFA challenge 5 minutes. Credential links 24 hours. Sign-out clears the session. |
| Files | Uploaded bytes and their metadata. | Kept while a live document owns them. Ownerless files prune after `artifact.prune_after_days`, default 30, when no recent reference names them. `0` keeps everything. |
| Login events | `iam.LoginEvent` documents record every authentication event. | They follow the document and mutation windows above. |

### Notes per class

**Mutations.** The daily compaction pass, by default at 03:45, replaces every
mutation older than the window with one synthetic snapshot row per document.
The snapshot row keeps the original timestamp and keeps the row order
contiguous. The document itself never changes, and no event is emitted. A
tombstoned document always keeps its trailing delete and the row before it, so
a restore stays reachable. A per-doctype override map can shorten the window
for single doctypes.

**Coalescing.** When one account saves the same document twice within the
window, through the same channel, Facet folds the two updates into one row
with a fresh id. The row holds one composed change. The history shows a small
gap in the row order where rows folded. A rollback to the folded row restores
the final state.

**Tombstones.** The retained payload lets Facet check row scopes on delete
events. The payload never leaks into lists, search results, or snapshots:
every list filter targets live rows only. The label stays, so audit views can
name a deleted document.

**Events.** Facet treats event delivery as at-most-once by decision. A lost
event is a lost reaction, and nearly every reaction has a repair path. The lag
check warns before a slow consumer reaches the trim point. The webhook
reconciler re-runs missed webhook enqueues from the mutation log inside
`webhook.reconcile_window_hours`, default 24. That window must stay below
`jobs.retention_days`.

**Sessions.** The lifetimes come from the config keys
`iam.jwt.refresh_token_ttl` (1,209,600 seconds), `iam.jwt.access_token_ttl`
(900 seconds), and `iam.change_password_expiration` (86,400 seconds) for
password reset, invite, and first-credential links. The MFA challenge lives 5
minutes. A full Redis loss only forces everyone to sign in again.

**Files.** A file that a live document owns stays. Owner rows go away only
with their document, their domain, or the file itself. A file with no live
owner is pruned after the window, unless a reference within the window still
names it.

:::caution[The mutation window bounds rollback depth]
A rollback target older than the window answers `404`. Widening the window
does not bring compacted rows back — see
[Rolling back changes](/govern/rolling-back/).
:::

## Steps

### Set the windows

1. Edit `config.<environment>.yml`. The file is the source of truth for every
   window. The example below shows the retention keys with their defaults.
2. To change a window without a restart, pin it at runtime. Open
   **Configure → Platform → Settings** and set `mutations.retention_days` or
   `tombstone.content_retention_days`. A pin applies from the next daily pass.
   A pin of `0` means keep forever.
3. Per-doctype overrides are file-only. The settings page does not carry them.

:::tip
The settings page marks each pinned value with an override badge. Clear
the pin to follow the file again.
:::

## Example

```yaml
# Retention keys with their defaults.
mutations:
  retention_days: 180
  retention_overrides:
    "core.SchematicLayout": 7
  compaction_cron: "45 3 * * *"
  coalesce_window_minutes: 3

tombstone:
  content_retention_days: 30
  prune_cron: "15 4 * * *"

event:
  maxlen: 1000000

jobs:
  retention_days: 30

artifact:
  prune_after_days: 30
```

## Troubleshooting

### The mutation log keeps growing

The window is `0`, which disables the pass. Check the effective value on the
settings page.

### A rollback answers `404` and names a window

The target is older than the window — see
[Rolling back changes](/govern/rolling-back/).

### The history shows a gap in the row order

Coalescing folded same-actor saves. The newest row holds the composed change.

## Related

- [Rolling back changes](/govern/rolling-back/) — the limit the window creates.
- [Auditing activity](/govern/auditing-activity/) — reading the log the window bounds.
- [The mutation log](/concepts/mutation-log/) and [Event delivery](/concepts/events-delivery/) — the concepts.
- [Deploy to production](/operate/production/) — where the config file lives.
- Internals on GitHub: [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
