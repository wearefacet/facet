---
title: "Retention: what is kept"
description: What Facet keeps for how long, and where you set each window.
type: how-to
audience: [admin, operator]
features: [AUD-05, AUD-06, AUD-07]
verified_at: eee55a2
sidebar:
  order: 2
---

Before Brightwater's data-protection review, Ravi must answer one question in
plain words: what does Facet keep, and for how long? The short answer: the
full history of every document is kept for 180 days by default. Older changes
fold into one snapshot per document, so you can roll back at most 180 days.
Every other class of data has its own, shorter window. The sections below
list each class, then show where you set the windows.

## When to use this

- You write the data-retention policy for your organization.
- You set the windows for a deployment.
- You answer how far back a rollback can reach.

## What Facet keeps

PostgreSQL holds the durable state. Redis holds short-lived state. Each class
below names its window and where the window is set.

| Data class | What is kept | For how long |
| --- | --- | --- |
| Documents | The current state of every live document. | While the document lives. A delete makes a tombstone; it does not remove the row. |
| History | The full change log of every document. | `mutations.retention_days`, default 180. `0` keeps everything. Older rows fold into one snapshot row per document. |
| Coalesced updates | Same-actor, same-channel updates inside `mutations.coalesce_window_minutes`, default 3, fold into one row. | The folded row replaces the old one. The old id answers `404` inside the window. |
| Tombstones | A deleted document keeps its content, links, and search text. The label and metadata stay. | The prune clears the payload after `tombstone.content_retention_days`, default 30. `0` keeps it forever. |
| Events | Each Redis stream keeps recent events for reactions. | Trimmed at `event.maxlen`, default 1,000,000 entries per shard. Delivery is at-most-once; PostgreSQL holds the durable state. |
| Jobs and webhook calls | Finished background-job rows and webhook call rows. | `jobs.retention_days`, default 30. |
| Sessions and tokens | Refresh sessions, access tokens, MFA challenges, credential links. | Refresh session 14 days. Access token 15 minutes. MFA challenge 5 minutes. Credential links 24 hours. Sign-out clears the session. |
| Files | Uploaded bytes and their metadata. | Kept while a live document owns them. Ownerless files prune after `artifact.prune_after_days`, default 30, when no recent reference names them. `0` keeps everything. |
| Login events | `iam.LoginEvent` documents record sign-ins, lockouts, security changes, and app or SSO denials. | They follow the document and history windows above. |

Notes per class:

**History.** The daily compaction pass, by default at 03:45, replaces every
change older than the window with one synthetic snapshot row per document.
The snapshot row keeps the original timestamp and keeps the row order
contiguous. The document itself never changes, and no event is emitted. A
tombstoned document always keeps its trailing delete and the row before it,
so a restore stays reachable. A per-doctype override map can shorten the
window for single doctypes.

**Coalescing.** When one account saves the same document twice within the
window, through the same channel, Facet folds the two updates into one row.
The row carries a fresh id and one composed change. The history shows a small
gap in the row order where rows folded. A rollback to the folded row restores
the final state.

**Tombstones.** The retained payload lets Facet check row scopes on delete
events. The payload never leaks into lists, search results, or snapshots:
every list filter targets live rows only. The label stays, so audit views can
name a deleted document.

**Events.** Facet treats event delivery as at-most-once by decision. A lost
event is a lost reaction, and nearly every reaction has a repair path. The
lag check warns before a slow consumer reaches the trim point. The webhook
reconciler re-runs missed webhook enqueues from the history inside
`webhook.reconcile_window_hours`, default 24. That window must stay below
`jobs.retention_days`.

**Sessions.** The lifetimes come from the config keys
`iam.jwt.refresh_token_ttl` (1,209,600 seconds) and `iam.jwt.access_token_ttl`
(900 seconds). Password reset, invite, and first-credential links last
`iam.change_password_expiration` (86,400 seconds). The MFA challenge lasts
5 minutes. A full Redis loss only forces everyone to sign in again.

**Files.** A file that a live document owns stays. Owner rows go away only
with their document, their domain, or the file itself. A file with no live
owner is pruned after the window, unless a reference within the window still
names it.

:::caution[The history window bounds rollback depth]
A rollback target older than the window answers `404`. Widening the window
does not bring compacted rows back — see
[Roll back a change](/admin/history/roll-back/).
:::

## Set the windows

You need access to the server's config file, or the admin UI with rights on
the platform settings.

1. Edit `config.<environment>.yml`. The file is the source of truth for every
   window. The example below shows the retention keys with their defaults.
2. To change a window without a restart, pin it at runtime. Open
   **Configure → Platform → Settings** and set `mutations.retention_days` or
   `tombstone.content_retention_days`. A pin applies from the next daily
   pass. A pin of `0` means keep forever.
3. Per-doctype overrides are file-only. The settings page does not carry
   them.

:::tip
The settings page marks each pinned value with an override badge. Clear the
pin to follow the file again.
:::

### Example

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

### The change log keeps growing

The window is `0`, which disables the pass. Check the effective value on the
settings page.

### A rollback answers `404` and names a window

The target is older than the window — see
[Roll back a change](/admin/history/roll-back/).

### The history shows a gap in the row order

Coalescing folded same-actor saves. The newest row holds the composed change.

## Related

- [Roll back a change](/admin/history/roll-back/) — the limit the window creates.
- [See who did what](/admin/history/audit/) — reading the log the window bounds.
- [The change log, in detail](/admin/under-the-hood/change-log/) and
  [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the concepts.
- [Go to production](/admin/install/production/) — where the config file lives.
- Internals on GitHub: [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
- [Security and governance](/discover/security/)
