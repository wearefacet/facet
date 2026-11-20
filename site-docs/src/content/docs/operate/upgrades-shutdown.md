---
title: Upgrades and graceful shutdown
description: Upgrade to a new release and stop the backend without cutting in-flight work.
audience: [operator]
features: [PLT-15, PLT-11]
sidebar:
  order: 16
verified_at: 008dd880
---

A release is a new container image. The entrypoint migrates the schema
on boot, so an upgrade is pull, restart, and a health check. A stop is a
signal: the backend closes its listeners, sends close frames to every
WebSocket, waits for in-flight requests, and tears its subsystems down
in a fixed order.

## When to use this

Use this runbook when:

- You move an install to a new release tag.
- You stop or restart a backend instance.
- You verify that a stop was clean.

## Before you start

- Pin a release tag, for example `1.4.2`. Do not track `latest` in
  production — see [Deploying with containers](/operate/containers-tls/).
- Take a database snapshot before you revert a migration. A revert runs
  DDL that only a snapshot can undo.
- Know the append-only rule: applied migration files are never edited,
  renumbered, or merged.

## Steps

### 1. Upgrade the release

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

The new backend image boots and its entrypoint runs one chain:

```text
render config (when absent) → migrate → seed:core → server
```

Every step is idempotent. The migrate step retries three times, then the
boot stops. After the boot, check readiness:

```sh
curl -sf https://facet.example.tld/Healthcheck
```

### 2. Respect the two schema constraints

- The binary embeds its migrations at compile time. A deployed image
  needs no `db/` tree on disk, and a changed migration file requires a
  rebuild.
- After the first release, `db/migrations/` is append-only. Never edit,
  renumber, or merge a file that any installed database has applied. An
  edited file desynchronizes every deployment from the applied list in
  `_migrations`.

  To undo an upgrade, revert the schema with `facet migrate:down` from a
  one-off container of the new image, after the snapshot. The full apply
  and revert rules are in [Database migrations](/operate/migrations/).

### 3. Pin UTC for manual database work

Every timestamp column stores UTC with no timezone marker. Two layers
pin the session zone: the app appends `TimeZone=UTC` to every pooled
connection, and the schema migration set the application role default to
UTC. A client that connects with a different role gets the server
default and must set the zone itself.

:::caution
A non-UTC session does not corrupt reads, but it skews writes. `now()`
defaults and timestamp casts store local wall-clock time, and PostgreSQL
drops the offset without a warning. Pin `TimeZone=UTC` on `psql`, BI
tools, and upgrade-time scripts.
:::

### 4. Know the stop sequence

The handler traps `SIGTERM`, `SIGINT`, and `SIGHUP` from the first
moment of the boot. One signal runs this sequence:

<!-- d2
direction: down
signal: "Signal received"
listeners: "Listeners close"
websockets: "WebSockets get close frames"
inflight: "In-flight requests finish, max 30 s"
teardown: "Subsystem teardown in fixed order"
exit: "Exit 0" {class: ok}

signal -> listeners
listeners -> websockets
websockets -> inflight
inflight -> teardown
teardown -> exit
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/77baab5f-light.svg" alt="Signal received" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/77baab5f-dark.svg" alt="Signal received" loading="lazy" />
</div>

The teardown stops the subsystems newest first: cron, jobs, hooks,
webhook delivery, sidecar sweeps, replication, cache subscribers,
WebSocket fanout, and the event manager last. It drains background index
DDL with a 5-second bound, then closes the database pools. Every step
runs even when an earlier step raises. A second signal exits at once:
the teardown still runs, but the drain wait does not.

On a multi-instance deployment, a graceful stop releases the Redis shard
locks at once, so a peer instance takes the streams over without waiting
out the lock lifetime.

### 5. Give the drain enough grace

The app bounds its own drain at 30 seconds. The container runtime kills
the process earlier if its grace period is shorter. Docker Compose gives
10 seconds by default. Raise it above the drain bound:

```yaml
services:
  backend:
    stop_grace_period: 45s
```

## Example

A full upgrade runbook for a Compose install:

```sh
# 1. Pull the new release images.
docker compose -f docker/compose.prod.yml pull

# 2. Recreate the stack. The entrypoint migrates and re-seeds the core doctypes.
docker compose -f docker/compose.prod.yml up -d

# 3. Check readiness.
curl -sf https://facet.example.tld/Healthcheck

# 4. Later, when you stop the backend, confirm the clean stop in the logs:
#    the line "graceful shutdown complete" ends the sequence.
```

The Docker image also runs its own healthcheck on
`http://127.0.0.1:3000/Healthcheck` every 10 seconds, so `docker ps`
shows the state without extra tooling.

## Troubleshooting

**The runtime kills the backend before the teardown finishes.**

The grace period is shorter than the drain. Set `stop_grace_period`
above 30 seconds, as in the fragment above.

**The boot stops after three migrate attempts.**

Read the backend logs: an unreachable database or a permissions problem
is the usual cause. Fix the cause, then run `docker compose up -d`
again.

**You must undo the schema part of an upgrade.**

Take a snapshot, then run `facet migrate:down` from a one-off container
of the new image. See [Database migrations](/operate/migrations/) for the
target syntax and the safeguards.

**`/Healthcheck` answers `503` after the upgrade.**

Read `database`, `redis`, and `events` in the body — see
[Health checks, metrics, tracing, logs](/operate/health-metrics-logs/).
A failed migration names itself in the backend logs.

## Related

- [Database migrations](/operate/migrations/) — apply and revert in full, and the UTC rule.
- [Deploying with containers](/operate/containers-tls/) — images, tags, and the entrypoint chain.
- [Deploy to production](/operate/production/) — the full deployment walkthrough.
- [Health checks, metrics, tracing, logs](/operate/health-metrics-logs/) — the probes this runbook checks.
- Internals on GitHub: [shutdown.md](https://github.com/wearefacet/facet/blob/main/doc/backend/shutdown.md), [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md).
