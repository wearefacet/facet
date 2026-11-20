---
title: Retention tuning
description: Set how long edit history and deleted-document payloads stay, in the config file or at runtime.
audience: [operator]
features: [AUD-05, AUD-06, AUD-07]
sidebar:
  order: 15
verified_at: 008dd880
---

Two windows bound stored data on the document store: the edit-history
log and the payload of deleted documents. Two cron passes trim both once
a day. You set the windows in `config.{env}.yml`, and you can pin them
at runtime. The full model — every data class and its window — is in
[Retention: what is kept and for how long](/govern/retention/).

## When to use this

Tune retention when:

- You set or change `mutations.retention_days` or
  `tombstone.content_retention_days`.
- You need a shorter window for one doctype.
- You change a window without a restart.

## Before you start

- A window of `0` keeps everything: the pass skips, and rollback reaches
  all history.
- Rollback depth equals the mutation window. Rows the compaction folded
  away do not come back — see [Rolling back changes](/govern/rolling-back/).
- Both windows accept `0` or more. A negative value is refused.

## Steps

### 1. Set the windows in the config file

```yaml
mutations:
  retention_days: 180
  retention_overrides:
    "core.SchematicLayout": 7
  compaction_cron: "45 3 * * *"
  coalesce_window_minutes: 3

tombstone:
  content_retention_days: 30
  prune_cron: "15 4 * * *"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `mutations.retention_days` | `180` | Edit-history rows older than this fold into one snapshot per document. `0` keeps everything. |
| `mutations.retention_overrides` | — | One window per doctype, keyed by the qualified name. File-only. |
| `mutations.compaction_cron` | `"45 3 * * *"` | When the compaction pass runs. Binds at boot. |
| `mutations.coalesce_window_minutes` | `3` | Same-actor saves inside the window fold into one row. `0` disables. |
| `tombstone.content_retention_days` | `30` | Deleted-document payloads clear after this. `0` keeps them forever. |
| `tombstone.prune_cron` | `"15 4 * * *"` | When the prune pass runs. Binds at boot. |

### 2. Pin a window at runtime

Open **Configure → Platform → Settings** and set
`mutations.retention_days` or `tombstone.content_retention_days`. Each
pass reads its window at the top of the run, so a pin applies from the
next daily pass. Clear the pin to follow the file again.

The per-doctype overrides have no settings field. The config file
carries them, and a restart applies a change.

### 3. Know what the passes do

The compaction pass, `mutations.compaction` at 03:45, replaces every
mutation older than the window with one synthetic snapshot row per
document. The document itself never changes, and no event is emitted. A
tombstoned document always keeps its trailing delete and the row before
it, so a restore stays reachable.

The prune pass, `tombstone.content_prune` at 04:15, clears the `content`,
`links`, and `search` payload of tombstones past the window, in bounded
batches. The label stays, so audit views can still name the deleted row.

### 4. Mind the edges

- A rollback target older than the window answers `404`, and the body
  names the effective window for the doctype.
- Coalescing folds same-actor saves inside `coalesce_window_minutes`
  into one row. The old id answers `404` inside the window, and the
  history shows a small gap in the row order.
- A base window of `0` also stops the per-doctype overrides for that
  pass.
- The webhook reconcile window, `webhook.reconcile_window_hours`, must
  stay below `jobs.retention_days`. The boot refuses a config that
  breaks the rule — see [Background jobs and cron](/operate/jobs-cron/).

## Example

Pin a 90-day history window at runtime, then give it back to the file:

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mutations": {"retention_days": 90}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

The next compaction pass, at the next `03:45` UTC, applies the pin. The
settings page marks the field with an override badge. Clear the pin with
an explicit `null` in the same PATCH shape.

## Troubleshooting

**A rollback answers `404` and names a window.**

The target is older than the window. See
[Rolling back changes](/govern/rolling-back/).

**The mutation table keeps growing.**

The window is `0`, so the pass skips. This is a valid choice: rollback
depth becomes full history. Set a window to restart the trims.

**A per-doctype override does nothing.**

The base window is `0` — a file-side `0` or a runtime pin. The overrides
do not apply while the pass is off. Set the base window to a number of
days.

**The history shows a gap in the row order.**

Coalescing folded same-actor saves. The following row holds the composed
change. This is normal.

**A config change does nothing.**

The path is pinned on the settings document. Clear the pin — see
[System settings](/operate/system-settings/).

## Related

- [Retention: what is kept and for how long](/govern/retention/) — the model: every data class and its window.
- [Rolling back changes](/govern/rolling-back/) — the depth limit the window creates.
- [The mutation log](/concepts/mutation-log/) — what the log records.
- [System settings](/operate/system-settings/) — how the runtime pins work.
- [Background jobs and cron](/operate/jobs-cron/) — the schedules and the jobs-retention rule.
- Internals on GitHub: [mutation.md](https://github.com/wearefacet/facet/blob/main/doc/backend/mutation.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
