---
title: Go to production
description: Run the Facet stack in production with Docker Compose, from empty host to first sign-in.
type: how-to
audience: [operator]
features: [PLT-16, APP-06, PLT-11, IAM-12]
sidebar:
  order: 3
verified_at: eee55a2
---

The board signed off and Monday is the go-live. The production path is
Docker Compose pulling the release images from GHCR: PostgreSQL, Redis, the
backend, the frontend, and a Caddy edge with TLS. No local toolchain is
needed — the host needs Docker with Compose, and nothing else. You do not
clone the repository; you download three files and run Compose.

## Before you start

- Docker with Compose is on the host.
- You know the public hostname and the SMTP relay values.
- The config keys are familiar — see
  [Configuration files](/admin/configure/configuration-files/).

## Steps

1. Make a folder and download the three stack files:

   ```sh
   mkdir facet && cd facet
   curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/compose.yml
   curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/Caddyfile.prod
   curl -fsSL  https://github.com/wearefacet/facet/releases/latest/download/.env.example -o .env.example
   cp .env.example .env
   ```

   `compose.yml` pulls `ghcr.io/wearefacet/facet` and
   `ghcr.io/wearefacet/facet-frontend`; it never builds. Pin a release tag in
   `.env` with `FACET_VERSION` (default `latest`).

2. Fill in `.env` — public hostname, SMTP relay, secrets. The file
   documents each key. Set `JWT_SIGNING_KEY` too: it is the access-token
   signing key. Keep one stable value — without it, every restart signs out
   bearer-token API clients. Compose fails loud on any missing required
   key, naming it.

3. Start the stack:

   ```sh
   docker compose up -d
   ```

   The backend entrypoint applies migrations and seeds the core schema on
   every boot. No manual schema step.

3. Create the first administrator:

   ```sh
   docker compose run --rm backend seed:admin ops@your-company.tld
   ```

   The command prints a one-time password. It is shown once — record it in
   a password manager.

4. Open `https://<your-hostname>` (default:
   `https://facet.localhost:3443`), sign in with the one-time password, and
   set a real password when prompted.

   That address is the Caddy edge port. `HTTPS_PORT` in `.env` sets
   it (default `3443`). The backend listens on `3000` inside the Docker
   network, and the edge proxies to it. Port `3000` is not published on the
   host.

5. Check the stack is healthy:

   ```sh
   curl -fsS https://<your-hostname>/Healthcheck
   ```

   The answer carries `"status":"ok"` when the backend, its PostgreSQL
   pool, and Redis are all reachable.

## What to know in production

- **Migrations are embedded in the binary.** A deployed binary needs no
  `db/` tree on disk. After the first release, the migration directory is
  append-only — never edit an applied migration file.
- **The images are pulled, not built.** `docker compose pull` fetches the
  pinned `FACET_VERSION` tags; `up -d` starts them. To move to a newer
  release, change `FACET_VERSION` in `.env`, then `docker compose pull &&
  docker compose up -d`.
- **Timestamps are stored as UTC.** The schema stores tz-naive UTC values.
  The application pins its PostgreSQL session to UTC. A client that
  connects with a different role (psql, BI tools) must set `TimeZone=UTC`
  itself, or writes skew by the session offset.
- **Redis is required.** The event bus, sessions, OAuth codes, and rate
  limits use it. PostgreSQL holds the durable state; Redis is the reaction
  bus.
- **One password source.** Compose interpolates both sides of
  `DATABASE_URL` from the same `POSTGRES_*` keys, so the Postgres password
  exists in exactly one place — `.env`.
- **The master key protects the stored secrets.** `FACET_SECRETS_MASTER_KEY`
  encrypts password hashes, API credentials, and TOTP seeds at rest. The
  store refuses to boot with a key shorter than 32 bytes. Losing it makes
  the stored secrets unreadable — keep it with the rest of your secrets.

## Before you go live

Each item links the page that covers it. Work through the list before the
first real user signs in.

- **TLS** — [Run with containers](/admin/install/containers/). The edge
  issues certificates for local names from its internal CA and for public
  names through Let's Encrypt; a public hostname needs port 80 published.
- **Email** — [Email](/admin/configure/email/). Password resets and invites
  travel by email; an install that cannot deliver locks people out.
- **File storage** — [File storage](/admin/configure/file-storage/). Pick
  the filesystem or S3 backend before the first upload; the adapter wires
  once per process.
- **Backups** — [Back up and restore](/admin/keep-running/backup-restore/).
  Backup is the operator's job; decide what to back up and test a restore
  before go-live.
- **Monitoring** — [Health, metrics and logs](/admin/keep-running/monitoring/).
  Point your checks at `/Healthcheck` (capital H) and scrape the metrics
  from the backend origin.
- **Upgrades** — [Upgrade Facet](/admin/keep-running/upgrades/). Know the
  upgrade procedure before you need it under pressure.
- **MFA policy** — [Require MFA](/admin/people/mfa/). Decide whether sign-in
  demands a second factor, and set it before accounts accumulate.

## Related

- [Run with containers](/admin/install/containers/) — images, tags, config mounting, and the TLS edge.
- [First start and bootstrap](/admin/install/bootstrap/) — the commands behind step 3.
- [Configuration files](/admin/configure/configuration-files/) — every key the config file takes.
- [Database migrations](/admin/keep-running/migrations/) — what the entrypoint runs at boot.
- Internals on GitHub: [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md).
- [Security and governance](/discover/security/)
- [System requirements](/admin/install/requirements/)
