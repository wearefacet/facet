---
type: how-to
title: Deploy to production
description: Run the Facet stack in production with Docker Compose.
audience: [operator]
features: [PLT-16, APP-06, PLT-11, IAM-12]
sidebar:
  order: 2
verified_at: e7c24a4
---

The production path is Docker Compose: PostgreSQL, Redis, the backend, the
frontend, and a Caddy edge with TLS. No local toolchain is needed.

## Requirements

Docker with Compose. That is all.

## Steps

1. Clone this repository and create the environment file:

   ```sh
   cp docker/.env.example docker/.env
   ```

   Fill in the values — public hostname, SMTP relay, secrets. The file
   documents each key.

2. Build and start the stack:

   ```sh
   docker compose -f docker/compose.prod.yml up -d --build
   ```

   The backend entrypoint applies migrations and seeds the core schema on
   every boot. No manual schema step.

3. Create the first administrator:

   ```sh
   docker compose -f docker/compose.prod.yml run --rm backend seed:admin ops@your-company.tld
   ```

   The command prints a one-time password. It is shown once — record it in a
   password manager.

4. Open `https://<your-hostname>` (default:
   `https://facet.localhost:3443`), sign in with the one-time password, and set
   a real password when prompted.

   That address is the Caddy edge port. `HTTPS_PORT` in `docker/.env` sets it
   (default `3443`). The backend listens on `3000` inside the Docker network,
   and the edge proxies to it. Port `3000` is not published on the host.

## What to know in production

- **Migrations are embedded in the binary.** A deployed binary needs no `db/`
  tree on disk. After the first release, the migration directory is
  append-only — never edit an applied migration file.
- **Timestamps are stored as UTC.** The schema stores tz-naive UTC values. The
  application pins its PostgreSQL session to UTC. A client that connects with a
  different role (psql, BI tools) must set `TimeZone=UTC` itself, or writes
  skew by the session offset.
- **Redis is required.** The event bus, sessions, OAuth codes, and rate limits
  use it. PostgreSQL holds the durable state; Redis is the reaction bus.

## Reference

- [Deploying with containers](/admin/install/containers/) — images, tags, config mounting, and the TLS edge.
- [Configuration files](/admin/configure/configuration-files/) — every key the config file takes.
- [Bootstrap and CLI tasks](/admin/install/bootstrap/) — the commands behind step 3.
- [Database migrations](/admin/keep-running/migrations/) — what the entrypoint runs at boot.
- Runbooks in the repository: [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md).
