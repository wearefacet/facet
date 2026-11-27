---
title: Upgrade Facet
description: Upgrade Facet to a new release, undo one safely, and stop the backend without cutting in-flight work.
type: how-to
audience: [operator]
features: [PLT-15, PLT-11]
verified_at: eee55a2
sidebar:
  order: 4
---

A new release is out and the installation is two releases behind. Upgrading
Facet is deliberately boring. A release is a new container image, and the
entrypoint migrates the schema on boot. An upgrade is pull, restart, and a
health check. A stop is a signal too. On one signal the backend closes its
listeners and sends a close frame to every WebSocket. It waits for in-flight
requests, then tears its subsystems down in a fixed order.

## What a release is

Releases so far — 0.2.0-beta (2026-11-20), 0.2.1 (2026-11-24), 0.2.2
(2026-11-26), 0.2.3 (2026-11-28) — follow `MAJOR.MINOR.PATCH`, with `0.x`
treated as beta. The
project is pre-1.0: a release can contain breaking changes. Every release
carries a **Deployment notes** section in `CHANGELOG.md`; read it before you
pull. It names the steps this page cannot know in advance — a required
environment variable, a changed default, a re-pull requirement.

Database migrations are append-only and carry tested `-- DOWN` sections, so a
schema change can be reverted through `facet migrate:down`. That is the whole
committed policy today; this page states no stronger promise than the
changelog and the code keep.

## When to use this

- You move an install to a new release tag.
- You stop or restart a backend instance.
- You verify that a stop was clean.

## Before you start

- Pin a release tag, for example `0.2.2`. Do not track `latest` in production
  — see [Run with containers](/admin/install/containers/).
- Read the release's **Deployment notes** in `CHANGELOG.md`.
- Take a database snapshot before you revert a migration. A revert runs DDL
  that only a snapshot can undo.
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

Every step is idempotent. The migrate step retries three times, then the boot
stops. After the boot, check readiness:

```sh
curl -sf https://facet.example.tld/Healthcheck
```

### 2. Respect the two schema constraints

- The binary embeds its migrations at compile time. A deployed image needs no
  `db/` tree on disk, and a changed migration file requires a rebuild.
- After the first release, `db/migrations/` is append-only. Never edit,
  renumber, or merge a file that any installed database has applied.

To undo an upgrade, revert the schema with `facet migrate:down` from a
one-off container of the new image, after the snapshot. The full apply and
revert rules are in [Database migrations](/admin/keep-running/migrations/).

### 3. Know the stop sequence

The handler traps `SIGTERM`, `SIGINT`, and `SIGHUP` from the first moment of
the boot. One signal runs this sequence:

*One signal, five steps, exit 0.*

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

The teardown stops the subsystems newest first: cron, jobs, hooks, webhook
delivery, sidecar sweeps, replication, cache subscribers, WebSocket fanout,
and the event manager last. It drains background index DDL with a 5-second
bound, then closes the database pools. Every step runs even when an earlier
step raises. A second signal exits at once: the teardown still runs, but the
drain wait does not.

On a multi-instance deployment, a graceful stop releases the Redis shard
locks at once. A peer instance takes the streams over without waiting out the
lock lifetime.

### 4. Give the drain enough grace

The app bounds its own drain at 30 seconds. The container runtime kills the
process earlier if its grace period is shorter. Docker Compose gives 10
seconds by default, and the shipped compose file does not raise it. Set it
above the drain bound:

```yaml
services:
  backend:
    stop_grace_period: 45s
```

## Example

A full upgrade runbook for a Compose install:

```sh
# 1. Read the release's Deployment notes in CHANGELOG.md.

# 2. Pull the new release images.
docker compose -f docker/compose.prod.yml pull

# 3. Recreate the stack. The entrypoint migrates and re-seeds the core doctypes.
docker compose -f docker/compose.prod.yml up -d

# 4. Check readiness.
curl -sf https://facet.example.tld/Healthcheck

# 5. Later, when you stop the backend, confirm the clean stop in the logs:
#    the line "graceful shutdown complete" ends the sequence.
```

The image also runs its own healthcheck on
`http://127.0.0.1:3000/Healthcheck` every 10 seconds. `docker ps` shows the
state without extra tooling.

## Troubleshooting

**The runtime kills the backend before the teardown finishes.**

The grace period is shorter than the drain. Set `stop_grace_period` above 30
seconds, as in the fragment above.

**The boot stops after three migrate attempts.**

Read the backend logs: an unreachable database or a permissions problem is
the usual cause. Fix the cause, then run `docker compose up -d` again.

**You must undo the schema part of an upgrade.**

Take a snapshot, then run `facet migrate:down` from a one-off container of
the new image. See [Database migrations](/admin/keep-running/migrations/) for
the target syntax and the safeguards.

**`/Healthcheck` answers `503` after the upgrade.**

Read `database`, `redis`, and `events` in the body — see
[Health, metrics and logs](/admin/keep-running/monitoring/). A failed
migration names itself in the backend logs.

## Related

- [Database migrations](/admin/keep-running/migrations/) — apply and revert in full, and the UTC rule.
- [Run with containers](/admin/install/containers/) — images, tags, and the entrypoint chain.
- [Go to production](/admin/install/production/) — the full deployment walkthrough.
- [Health, metrics and logs](/admin/keep-running/monitoring/) — the probes this runbook checks.
- [Releases](/reference/changelog/) — the changelog this page reads its notes from.
- Internals on GitHub: [shutdown.md](https://github.com/wearefacet/facet/blob/main/doc/backend/shutdown.md), [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md).
- [facet CLI](/reference/cli-facet/)
