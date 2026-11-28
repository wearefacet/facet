---
title: Background jobs and cron
description: Run the background job queue and the nine cron tasks, and tune retries, leases, and schedules.
type: how-to
audience: [operator]
features: [AUT-04, AUT-05, AUT-10]
verified_at: eee55a2
sidebar:
  order: 2
---

Webhooks must reach their receivers, exports must finish, and old data must
be pruned — while nobody watches. Facet runs this work itself, in two engines
inside the backend process. The job queue is one PostgreSQL table; a worker
loop claims due rows and runs a handler for each. The cron scheduler fires
maintenance tasks on a schedule. Both start with the server, and neither
needs extra software.

## When to use this

- You want to know which background tasks run and when.
- A job fails or stays `running`, and you must recover it.
- You tune retries, leases, batch size, or a cron schedule.

## Before you start

- Every `jobs:` key and every cron schedule binds at boot. A change needs a
  restart.
- The worker runs in every backend instance. Two workers never take the same
  row: the claim locks rows with `FOR UPDATE SKIP LOCKED`.
- The worker keeps one liveness key in Redis per instance. The lease sweep
  reads it to detect a dead worker.

## Steps

### 1. Follow one job row

One row in `background_jobs` is one unit of work. The row is not a document
and has no event log. It moves through four states:

*One job row from enqueue to a terminal state.*

<!-- d2
direction: down
pending: pending
running: running
succeeded: succeeded {class: ok}
failed: failed {class: danger}

pending -> running
running -> succeeded
running -> failed
running -> pending: retry
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c8f16496-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c8f16496-dark.svg" alt="Diagram" loading="lazy" />
</div>

- A worker claim moves the row `pending` → `running` and starts a lease.
- A failed attempt with attempts left moves it back to `pending`, with a
  delay before it is due again.
- A failed attempt at the retry cap marks it `failed` for good.
- The lease sweep also moves stranded `running` rows back to `pending`, or to
  `failed` when they are past the cap.

### 2. Know the job kinds

The server registers one handler per kind:

| Kind | What it does |
| --- | --- |
| `webhook_delivery` | Sends one signed webhook POST. Retries follow the webhook config. |
| `document_export` | Exports the documents of one doctype. Runs once, long lease. |
| `document_import` | Imports documents. Runs once, long lease. |
| `domain_export` | Exports a portable domain bundle. Runs once, long lease. |
| `domain_import` | Imports a portable domain bundle. Runs once, long lease. |
| `doctype_reproject` | Re-projects every live document of one doctype. Runs once, long lease. |
| `doctype_migrate_ahead` | Runs a doctype migration ahead of the lazy path. Runs once, long lease. |

The default policy allows 5 attempts per job. A failed attempt with attempts
left goes back to `pending` after a delay: 10, 60, 300, then 1800 seconds
between the four retries. The long job kinds set `max_attempts: 1` on their
own rows: the caller fixes the input and submits again. A job row can carry
its own limits at enqueue time.

### 3. Tune the queue

The optional `jobs:` section holds the queue knobs:

| Key | Default | Meaning |
| --- | --- | --- |
| `poll_interval_s` | `5.0` | Idle wait between claim passes. |
| `lease_ttl_s` | `60` | How long a claimed row stays `running` before the sweep requeues it. |
| `long_lease_ttl_s` | `3600` | The lease horizon the long job kinds set on their own rows. |
| `batch` | `32` | Max rows claimed per pass. |
| `sweep_interval_s` | `30.0` | Cadence of the lease sweep and the liveness refresh. |
| `retention_days` | `30` | Finished rows older than this are pruned. |
| `enabled` | `true` | `false` starts no worker; enqueues still insert rows. |

### 4. Know the crash recovery

Two detectors turn a crash into a clean re-run:

- The lease sweep runs every `sweep_interval_s`. It requeues `running` rows
  whose lease expired or whose owner instance is dead.
- The liveness check marks the instance alive in Redis on every sweep tick.
  The key holds 120 seconds, so three missed ticks never declare a live
  instance dead.

A stranded row past its retry cap goes terminal `failed` with the error
`job abandoned — worker lost`. A crash-looping job cannot requeue forever.

### 5. Split enqueue from work, if you need it

With `jobs.enabled: false` the worker never starts, but enqueues still insert
rows. Another process with the worker on claims them. Use this to keep job
work off one instance.

### 6. Know the cron tasks

One scheduler fiber per process fires nine registered tasks. Each dispatch
first leases the scheduled tick in Redis, so the tick runs exactly once
across the cluster. A Redis error skips the fire, and the next tick re-arms.

`facet cron:list` prints this table from your own config — task id, schedule
key, expression, and the next fire time (UTC):

```text
task id                   schedule key                 expression     next run (UTC)
sidecar.reconcile         sidecar.reconcile_cron       0 */1 * * *    2026-11-26 15:00:00 UTC
artifact.grant_prune      artifact.grant_prune_cron    0 5 * * *      2026-11-27 05:00:00 UTC
tombstone.content_prune   tombstone.prune_cron         15 4 * * *     2026-11-27 04:15:00 UTC
secrets.prune             secrets.prune_cron           45 4 * * *     2026-11-27 04:45:00 UTC
assistant.turn_sweep      assistant.turn_sweep_cron    */5 * * * *    2026-11-26 14:55:00 UTC
assistant.usage_prune     assistant.usage_prune_cron   30 4 * * *     2026-11-27 04:30:00 UTC
mutations.compaction      mutations.compaction_cron    45 3 * * *     2026-11-27 03:45:00 UTC
webhook.reconcile         webhook.reconcile_cron       7 */1 * * *    2026-11-26 15:07:00 UTC
event.lag_check           event.lag_check_cron         */10 * * * *   2026-11-26 15:00:00 UTC
```

The command reads config only — no database, no Redis. An expression the
parser refuses marks its row, and the command exits `1`: the server refuses
to boot on the same error.

What each task does:

| Task id | Pass |
| --- | --- |
| `sidecar.reconcile` | Re-enqueues orphaned sidecar sweeps. |
| `artifact.grant_prune` | Deletes expired ephemeral download-link rows after `artifact.grant_prune_days`. |
| `tombstone.content_prune` | Clears tombstone payloads after `tombstone.content_retention_days`. Storage cleanup only — the audit history stays. |
| `secrets.prune` | Drops expired secret slots and staging rows. |
| `assistant.turn_sweep` | Marks stale `running` assistant turns `interrupted`. |
| `assistant.usage_prune` | Deletes assistant usage rows past the window. |
| `mutations.compaction` | Folds mutations older than `mutations.retention_days` into one snapshot per document. Rollback depth equals that window. |
| `webhook.reconcile` | Repairs the webhook enqueue hop from the `mutations` log, within `webhook.reconcile_window_hours`. |
| `event.lag_check` | Warns before a slow consumer group loses entries to the stream trim. |

:::tip
The night schedules spread out on purpose: compaction at 03:45, then the
prunes at 04:15, 04:30, 04:45, and 05:00. Keep that spacing when you move
one of them.
:::

## Example

A complete configuration fragment. It shows the queue defaults and every
cron schedule with its default value:

```yaml
jobs:
  poll_interval_s: 5.0
  lease_ttl_s: 60
  long_lease_ttl_s: 3600
  batch: 32
  sweep_interval_s: 30.0
  retention_days: 30
  enabled: true

sidecar:
  reconcile_cron: "0 */1 * * *"

artifact:
  grant_prune_cron: "0 5 * * *"

tombstone:
  prune_cron: "15 4 * * *"

secrets:
  prune_cron: "45 4 * * *"

assistant:
  turn_sweep_cron: "*/5 * * * *"
  usage_prune_cron: "30 4 * * *"

mutations:
  compaction_cron: "45 3 * * *"

webhook:
  reconcile_cron: "7 */1 * * *"

event:
  url: !env FACET_REDIS_URL
  lag_check_cron: "*/10 * * * *"
```

## Troubleshooting

**A job stays `running` longer than it should.**

The handler may still run: the long job kinds hold a 3600-second lease.
Otherwise the worker died. The sweep requeues the row at the first sweep tick
after the lease expires. Wait one `sweep_interval_s` past `lease_ttl_s`.

**A job failed with `job abandoned — worker lost`.**

The row passed its retry cap while stranded. Re-run the work; the queue will
not retry the row again.

**A webhook delivery fails.**

Read the call log on the webhook — see
[Webhooks](/build/model/automation/webhooks/). Transport retries follow the
webhook `max_attempts` and `backoff_seconds` values, not the queue defaults.

**Two instances ran the same cron pass.**

The tick lease lives in Redis. Point every instance at the same Redis
database, so the lease is one key per tick.

**A schedule change does nothing.**

Schedules bind at boot. Restart the backend after you edit the file.

## Related

- [System settings](/admin/configure/system-settings/) — which knobs are hot and which bind at boot.
- [Health, metrics and logs](/admin/keep-running/monitoring/) — the job and cron metrics to watch.
- [Retention: what is kept](/admin/history/retention/) — the windows compaction and the prunes enforce.
- [Webhooks](/build/model/automation/webhooks/) — the delivery job the queue carries.
- [Events and delivery guarantees](/admin/under-the-hood/events-and-delivery/) — the bus the lag check guards.
- Internals on GitHub: [jobs.md](https://github.com/wearefacet/facet/blob/main/doc/backend/jobs.md), [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
