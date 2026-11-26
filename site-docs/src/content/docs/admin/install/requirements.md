---
type: reference
title: System requirements and topology
description: Check what a host needs to run Facet and how the backend, frontend, PostgreSQL, and Redis connect.
audience: [operator, evaluator]
features: [PLT-10, PLT-16]
sidebar:
  order: 0
verified_at: f1409cdc
---

Facet is one backend binary, one frontend server, and two state stores. The
backend holds every durable fact in PostgreSQL. Redis is the reaction bus.
This page lists what a host needs and how the pieces connect, so you can size
a deployment before you run it.

## When to use this

Use this page when:

- You plan a host or a container stack for Facet.
- You decide between one database and a routed cluster.
- You check a machine against the requirements.

## Requirements

| Component | Requirement | Notes |
| --- | --- | --- |
| PostgreSQL | 14 or newer | The `ulid()` function needs PostgreSQL 14. One instance is enough for most installs. |
| Redis | Required | The event bus, sessions, OAuth codes, and rate limits use it. The release stack runs the `redis:7` image. |
| Config file | `config.{APP_ENV}.yml` | The boot fails without it. See [Configuration files](/admin/configure/configuration-files/). |
| Backend binary | Release image, or `make build_release` | Migrations, Lua event scripts, and the seed corpus ride inside the binary. |
| Docker with Compose | For the container path | The release stack is five services. See [Deploying with containers](/admin/install/containers/). |

:::note
The release stack ships the `pgvector/pgvector:0.8.0-pg17` image. A stock
PostgreSQL image also works. Retrieval-augmented assistant features stay off
until the `vector` extension exists on the server.
:::

## Topology

<!-- d2
direction: down
browser: Browser {class: external}
caddy: Caddy edge
frontend: Frontend server
backend: Backend API
postgres: PostgreSQL {class: store}
redis: Redis {class: store}

browser -> caddy
caddy -> frontend
caddy -> backend
frontend -> backend
backend -> postgres
backend -> redis
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/5a512ccc-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/5a512ccc-dark.svg" alt="Diagram" loading="lazy" />
</div>

The container stack runs five services:

| Service | Image | Faces the network? |
| --- | --- | --- |
| `postgres` | `pgvector/pgvector:0.8.0-pg17` | No |
| `redis` | `redis:7` | No |
| `backend` | `ghcr.io/wearefacet/facet` | No — the edge routes to it |
| `frontend` | `ghcr.io/wearefacet/facet-frontend` | No — the edge routes to it |
| `caddy` | `caddy:2` | Yes — it publishes the TLS port |

The backend image runs as uid 10001. The frontend image runs as `node`.
A source deployment replaces the two application images with
`make build_release` and the SvelteKit dev or build server — see
[Install for development](/build/dev-environment/).

## Database topology

By default the backend opens one pool from `DATABASE_URL`. Every read and
every write shares that pool. Most installs stop here.

A larger install can split load with the optional `database.cluster` route
table. Each entry names one physical database and the resources it serves:

- A resource is a domain id, a `$`-prefixed subsystem tag, or `*`.
- Exactly one entry carries `*`. It serves the control plane and everything
  unrouted.
- A specific resource appears in one entry only.
- An entry can carry an optional read-only `replica` pool. Every read-only
  pool runs `SET default_transaction_read_only = on`, so a mislabelled write
  fails loud.
- Entries that share one URL keep separate pools. This gives pool isolation
  without a second database.

  `database.statement_timeout_ms` applies to every pooled connection of the
  server process. CLI entry points keep no timeout, so long DDL cannot be
  cancelled.

## Steps

1. Provision the state stores. Install PostgreSQL 14 or newer and Redis.
   Create one empty database for the first deploy.
2. Put the config file in place. Set `event.url` to the Redis address and
   `DATABASE_URL` in the environment. See
   [Configuration files](/admin/configure/configuration-files/).
3. Choose the database topology. Start with the single `DATABASE_URL` pool.
   Add the route table when one pool no longer fits the load.
4. Run the stack. Use the container path for production —
   [Deploying with containers](/admin/install/containers/) — or build from
   source. The copy-paste walkthrough is
   [Deploy to production](/admin/install/production/).

## Example

A cluster route table with one main database and one small bulk pool. Both
entries share the same URL, so the bulk pool is pool isolation only:

```yaml
database:
  statement_timeout_ms: 5000
  cluster:
    databases:
      main:
        url: !env DATABASE_URL
        max_pool_size: 20
        resources: ["*"]
      bulk_pool:
        url: !env DATABASE_URL
        max_pool_size: 8
        resources: ["$bulk"]
```

## Troubleshooting

**The boot fails and names the config path.**

The file does not exist at the resolved location. The boot never falls back
to another environment's file.

**The boot fails with `Missing required config key 'artifact_base_url'`.**

Add the required top-level keys. See
[Configuration files](/admin/configure/configuration-files/).

**PostgreSQL raises an error inside `ulid()`.**

The server is older than PostgreSQL 14. Upgrade the server.

**The boot fails with `Missing 'event' key in config`.**

Add the `event:` section with the Redis URL. Redis is a required dependency.

**Checkouts wait under load.**

Watch the `facet_db_checkout_total{database, role}` metric and tune
`max_pool_size` per entry. A nested write inside a read scope holds two
connections for its duration.

## Related

- [Deploying with containers](/admin/install/containers/) — the images and the TLS edge.
- [Deploy to production](/admin/install/production/) — the copy-paste walkthrough.
- [Configuration files](/admin/configure/configuration-files/) — every key the config file takes.
- [Database migrations](/admin/keep-running/migrations/) — how the schema reaches the database.
- [The big picture](/discover/how-it-works/) — the concepts behind the services.
- Internals on GitHub: [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
