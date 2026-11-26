---
title: Events and delivery guarantees
description: See how Facet publishes events after a commit, why delivery is at-most-once, and how webhooks are repaired.
audience: [developer, operator]
features: [AUT-01, AUT-05]
sidebar:
  order: 9
verified_at: 7a6cb462
---

Events in Facet are reactions, not records. After a write commits, Facet
publishes events on Redis Streams, and consumers react. PostgreSQL keeps the
durable state. Read this page to see what happens when a reaction is lost, and
why that is allowed.

## Explanation

<!-- d2
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
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/8cbdbef3-light.svg" alt="Document write commits" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/8cbdbef3-dark.svg" alt="Document write commits" loading="lazy" />
</div>

Every accepted write appends a row to the mutation log. After the database
transaction commits, the write path flushes its event queue to Redis Streams.
A rolled-back transaction discards the queue.

Consumers run in groups. Domain hooks run Lua scripts. Webhooks deliver signed
envelopes to external URLs. Replication copies fields across domains. The
WebSocket bridge pushes live updates to browsers.

**Delivery is at-most-once, by decision.** Consumers read with `no_ack`, and no
code acknowledges a message. A failed publish or dispatch is dropped with one
log line. PostgreSQL is the durable state; Redis is a reaction bus, not a
ledger.

**Loss stays visible.** The `event_loss` counters on `GET /Healthcheck` count
publish failures and dropped dispatches. The same endpoint answers `503` while
any consumer reports consecutive failures.

**Webhooks are the one repaired consumer.** A scheduled job,
`Cron::WebhookReconcile`, re-runs the enqueue decision from the `mutations`
log. It repairs misses inside a window set by `webhook.reconcile_window_hours`,
24 hours by default. The window must stay below the jobs retention period. A
wider window would re-send events whose delivery records are already pruned.

**A new consumer group picks a start position.** Replication groups start at
`0` and replay the retained stream. A replay converges, because each handler
re-derives rows from the current projection. Hooks and webhooks keep `$`, the
tail. A replay there would re-fire automations and re-deliver to external
systems.

**A lag check warns you early.** It runs every ten minutes by default. It reads
the lag of each group and warns before a slow group reaches the trim point.
The maximum lag appears as a gauge on `/Healthcheck`, next to `event_loss`.

**One loop, one lease.** Facet runs these jobs on its cron scheduler. A cron
expression names when a task fires. The scheduler runs one loop. A
once-per-cluster lease makes each tick fire exactly once across backend
instances. A failing task logs an error, and the scheduler keeps running.

:::note
The `event_loss` counters reset on restart. Read them as a signal, not a
ledger. The durable state stays in PostgreSQL.
:::

**What at-most-once costs.** At-most-once buys simplicity and throughput. It
costs guaranteed delivery. A consumer must tolerate loss, or carry a repair
path like the reconciler. Replication tolerates loss, because its handlers
re-derive from durable state and a replay converges.

## Related

- [Architecture at a glance](/discover/how-it-works/) — where the event bus sits in the request path.
- [The mutation log](/admin/under-the-hood/change-log/) — the durable record the reconciler reads.
- [Operate](/admin/) — healthcheck, Redis, and jobs in day-to-day running.
- [Production](/admin/install/production/) — probes and Redis sizing for a live deployment.
- Internals on GitHub: [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md), [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
