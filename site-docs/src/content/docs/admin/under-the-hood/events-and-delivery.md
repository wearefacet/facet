---
type: explanation
title: Events and delivery guarantees
description: How Facet publishes events after a commit, why delivery is at-most-once by decision, and how webhooks are repaired.
audience: [developer, operator]
features: [AUT-01, AUT-05]
verified_at: eee55a2
sidebar:
  order: 4
---

A booking is confirmed, and three reactions should follow. The hook marks
its items out. The webhook tells the external calendar. The browser tabs
update live. None of that is written by the booking request itself — each is
a reaction to an event. This page shows how those reactions travel, and why
Facet accepts that one can be lost.

## Explanation

*Every accepted write publishes events; consumers react; one cron repairs the one reaction that carries an external obligation.*

<!-- d2
direction: down
write: "Document write commits"
publish: "Publisher flushes the queue"
streams: "Redis Streams" {class: store}
hooks: "Hooks run Lua"
webhooks: "Webhooks deliver signed envelopes"
replication: "Replication copies fields"
live: "Live updates reach browsers"
cron: "Webhook reconcile cron"

write -> publish
publish -> streams
streams -> hooks
streams -> webhooks
streams -> replication
streams -> live
cron -> webhooks: repairs missed sends
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/291e43b3-light.svg" alt="Document write commits" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/291e43b3-dark.svg" alt="Document write commits" loading="lazy" />
</div>

### From commit to reaction

Events in Facet are reactions, not records. Every accepted write appends a
row to the mutation log. After the database transaction commits, the write
path flushes its event queue to Redis Streams. A rolled-back transaction
discards the queue.

Consumers run in groups, one per concern. Domain hooks run Lua scripts.
Webhooks deliver signed envelopes to external URLs. Replication copies fields
across domains. The WebSocket bridge pushes live updates to browsers.

### The delivery contract

**Delivery is at-most-once, by decision.** Consumers read with `no_ack`, and
no code acknowledges a message — no pending list, no reclaim. A failed
publish or dispatch is dropped with one log line. PostgreSQL is the durable
state; Redis is a reaction bus, not a ledger.

The contract has a logic. PostgreSQL owns the truth: `projections` and
`mutations` hold every fact. A lost event is a lost reaction, and nearly
every reaction has a repair path. The next mutation re-runs the same logic,
or a cron backstop covers it. What at-most-once buys in exchange is a simple,
fast bus with no acknowledgement bookkeeping and no redelivery storms.

### Loss is visible

The `event_loss` counters on `GET /Healthcheck` count publish failures and
dropped dispatches. The same endpoint answers `503` while any consumer
reports consecutive failures. The counters are in-process and reset on
restart — read them as a signal, not a ledger. The durable state stays in
PostgreSQL.

### Webhooks are repaired

Webhooks carry external obligations: a receiver is waiting. They are the one
repaired consumer. A scheduled task, `Cron::WebhookReconcile`, re-runs the
enqueue decision from the `mutations` log — the durable record — for recent
mutations that produced no delivery row. It derives; it does not mark: no
delivery state is written back onto mutations.

The repair covers a window set by `webhook.reconcile_window_hours`, 24 hours
by default. The window must stay below the jobs retention period
(`jobs.retention_days`, 30 days by default) — the boot refuses a config
where the window reaches it. A wider window would re-send events whose
delivery records are already pruned.

### Start positions

A new consumer group picks a start position. The default is `$`, the tail —
new events only. Replication passes `0`: a new binding replays the retained
stream. A replay converges, because each handler re-derives rows from the
current projection and skips the replay events it caused itself. Hooks and
webhooks keep `$`. A replay there would re-fire automations and re-deliver to
external systems.

### The lag check

Event streams are capped in size (`maxlen`, an approximate cap). Redis never
deletes an entry after delivery, so a stream sits at its cap in steady
state. A group loses entries to trim only when it falls more than one cap
behind on one shard. The usual causes are a dead consumer fiber or a down
instance.

`Cron::EventLagCheck` runs every ten minutes by default. It reads the lag of
every group and warns when one nears the trim point. The warning says loss
is approaching, not that it happened. The pass's maximum lag appears as a
gauge on `/Healthcheck`, next to `event_loss`.

### One loop, one lease

Facet runs these jobs on its own cron scheduler. A cron expression names when
a task fires. The scheduler runs one loop. A once-per-cluster lease makes
each tick fire exactly once across backend instances. A failing task logs an
error, and the scheduler keeps running.

### What at-most-once costs

At-most-once buys simplicity and throughput. It costs guaranteed delivery. A
consumer must tolerate loss, or carry a repair path like the reconciler.
Replication tolerates loss, because its handlers re-derive from durable state
and a replay converges. Hooks tolerate loss because the next matching
mutation re-fires them. If you write a consumer that cannot tolerate loss,
give it a repair path of its own — that is the price of joining the bus.

## Related

- [The big picture](/discover/how-it-works/) — where the event bus sits in the request path.
- [The change log, in detail](/admin/under-the-hood/change-log/) — the durable record the reconciler reads.
- [Background jobs and cron](/admin/keep-running/jobs-cron/) — the cron tasks this page names.
- [Health, metrics and logs](/admin/keep-running/monitoring/) — the counters this page describes, in operation.
- Internals on GitHub: [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md), [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
