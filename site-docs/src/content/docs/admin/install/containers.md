---
title: Run with containers
description: Run the release container images behind a Caddy edge with automatic TLS.
type: how-to
audience: [operator]
features: [PLT-16, APP-06]
sidebar:
  order: 1
verified_at: eee55a2
---

You are deploying Facet with Docker or Compose. You need to know what each
image carries, how the config reaches the backend, and who terminates TLS.
Facet ships two release images on GHCR: one for the backend, one for the
frontend. You pull them — you do not build them and you do not clone the
repository. The release stack adds PostgreSQL, Redis, and a Caddy edge that
terminates TLS and routes to the app hosts. The step-by-step walkthrough
stays in [Go to production](/admin/install/production/).

## When to use this

Read this page when:

- You deploy with Docker or Compose.
- You choose which image tag to pin.
- You mount a config file or serve extra app hosts over TLS.

## Before you start

- Docker with Compose is on the host.
- You know the public hostname and the SMTP relay values.
- The host requirements are met — see
  [System requirements](/admin/install/requirements/).

## Steps

### 1. Pick the images and a tag

| Image | Contents | Healthcheck |
| --- | --- | --- |
| `ghcr.io/wearefacet/facet` | The backend binary, `src/` (assistant skill corpora), the config example, the entrypoint | `curl` on `/Healthcheck` |
| `ghcr.io/wearefacet/facet-frontend` | The adapter-node build output with production `node_modules` | A `node` fetch probe |

Tags follow the publish pipeline:

| Tag | Moves when |
| --- | --- |
| `X.Y.Z`, `X.Y` | A `v*` release tag is published. These are release-only. |
| `latest` | A `v*` release tag is published. Never moves on branch pushes. |
| `master`, `nightly` | Every green push to `master`. |
| `sha-<sha>` | Every build. One tag per commit. |

Pin a release tag in production (set `FACET_VERSION` in `.env`). Use
`sha-<sha>` when you must reproduce a build exactly.

### 2. Get the three stack files

A deployment needs three files in one folder. None of them needs the
repository — download them from the release:

| File | Role |
| --- | --- |
| `compose.yml` | The stack: PostgreSQL, Redis, the two GHCR images, the Caddy edge. It pulls, it never builds. |
| `Caddyfile.prod` | The edge config the Caddy service mounts. |
| `.env` | Your values — copy from `.env.example` and fill it in. |

```sh
mkdir facet && cd facet
curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/compose.yml
curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/Caddyfile.prod
curl -fsSL  https://github.com/wearefacet/facet/releases/latest/download/.env.example -o .env.example
cp .env.example .env
```

In a checkout, the same files live in `docker/` as `compose.ghcr.yml`,
`Caddyfile.prod`, and `.env.ghcr.example`; copy them into a clean folder to
run the image-only path.

### 3. Supply the config

The backend resolves exactly one config file, in this order:

1. `FACET_CONFIG_FILE` — an explicit path, any mount point.
2. `/app/config.{APP_ENV}.yml` — your mount, or the entrypoint's copy of the
   shipped example, written only when the file is absent.
3. Nothing — the boot fails and names the missing path.

By default the entrypoint writes the shipped example, so no config mount is
required to start. To override it, mount your own file over the default name
with a Compose override:

```yaml
services:
  backend:
    volumes:
      - ./facet.yml:/app/config.production.yml:ro
```

Every `!env NAME` in the config must exist in the environment. A missing
variable fails the boot at config load. Compose fails loud on the same
keys, so a missing value stops the stack before the backend starts. The
shipped stack needs these set:

| Variable | Role |
| --- | --- |
| `POSTGRES_PASSWORD` | The database password. Compose builds `DATABASE_URL` from it — one password source. |
| `FACET_HOST` / `FACET_BASE_URL` | The public main URL. Must be the exact origin browsers see. |
| `FACET_ARTIFACT_BASE_URL` | The origin that streams artifact bytes. |
| `FACET_ARTIFACT_GRANT_SECRET` | HMAC secret for artifact capability URLs. |
| `FACET_REDIS_URL` | The event bus Redis. Compose points it at the `redis` service. |
| `FACET_MAIL_FROM_ADDRESS` / `FACET_MAIL_FROM_NAME` | Outbound email identity. |
| `FACET_SMTP_HOST` / `FACET_SMTP_USERNAME` / `FACET_SMTP_PASSWORD` | The SMTP relay. |
| `FACET_SECRETS_MASTER_KEY` | Protects every stored secret. The store fails closed under 32 bytes. |
| `JWT_SIGNING_KEY` | The access-token signing key, a P-256 private key in PEM form. Not a config key — the backend reads it straight from the environment. Without it, each boot mints a temporary key and every restart signs out bearer-token API clients. |

`DATABASE_URL` and `APP_ENV` stay environment-only. The backend reads them
outside YAML.

:::caution
A mounted config file must be readable by uid 10001. A root-owned `600`
mount fails the boot with `File::AccessDeniedError`.
:::

### 4. Let the entrypoint bootstrap the database

The backend entrypoint runs one chain on every server boot:

```text
render config (when absent) → migrate (3 attempts) → seed:core → exec facet server
```

Every step is idempotent and non-destructive. The chain never drops
anything — it never runs `db_reset`. A one-off container runs any other
command directly: the entrypoint skips the server branch and execs the
command, so `run --rm backend seed:admin …` works without extra flags.

### 5. Serve TLS through the Caddy edge

The edge config has three site blocks:

| Site block | Routes | TLS |
| --- | --- | --- |
| The main hostname | `/Api`, `/OAuth`, `/A`, `/Ws`, `/Healthcheck`, `/auth`, and `/.well-known` go to the backend. Everything else goes to the frontend. | Internal CA on local names, ACME on public names. |
| Catch-all on the same port | Every other SNI goes to the backend, where app hosting resolves the host. | On-Demand TLS, gated by an ask endpoint. |
| Port 80 | HTTP to HTTPS redirect. | — |

The main hostname gets a certificate from the internal CA for a local name
(the default `facet.localhost`), and from Let's Encrypt for a public name.
Public certificates through the ACME HTTP-01 challenge need port 80
published.

Two edge guards worth knowing:

- A request to a lowercase twin of a backend namespace — `/api/Deal`, for
  example — answers a 404 JSON that names the case rule. Caddy path
  matching is case-insensitive, and the lowercase twins are legal domain
  ids, so the edge routes them by case, not by name.
- The probe names are reserved. `GET /healthcheck` (lowercase) answers 404
  for every method, so a monitor that typoes the name fails loud instead of
  reading the login page as health. `/metrics` is not routed through the
  edge at all — scrape the backend origin.

The edge sends `Strict-Transport-Security` (max-age 3600) and
`X-Content-Type-Options: nosniff` on every main-host response. The frontend
surface also carries a Content-Security-Policy and `X-Frame-Options:
SAMEORIGIN`.

The catch-all block serves registered app hosts — see
[Controlling app reach](/admin/apps-access/app-grants/) and
[App hosting and deployment](/build/apps/host/deploy/). Before it issues a
certificate, Caddy asks the backend at `/Edge/HostAsk`. The backend answers
`200` for a registered, active app host and `404` for everything else. A
host that is not a registered app host gets no certificate.

### 6. Verify the stack

The release pipeline runs a smoke gate on every image. The gate boots the
stack, checks `status: ok` on `/Healthcheck`, loads the login page through
the frontend, and confirms the core doctypes exist. After `docker compose
up -d`, run the same check against the live stack:

```sh
curl -fsS https://facet.localhost:3443/Healthcheck
```

The answer carries `"status":"ok"` when the backend, its PostgreSQL pool,
and Redis are all reachable. In a repository checkout the local smoke gate
is `make docker_images && make docker_smoke`; it builds the images instead
of pulling them, so it is for contributors, not for an install.

## Example

Mount a custom config on the image-only stack. Add a Compose override file
`compose.override.yml` in the same folder, then run Compose with both files:

```yaml
services:
  backend:
    environment:
      FACET_CONFIG_FILE: /etc/facet/facet.yml
    volumes:
      - ./facet.yml:/etc/facet/facet.yml:ro
```

```sh
docker compose -f compose.yml -f compose.override.yml up -d
```

The mounted file may use `!env` references itself. The same expansion runs on
every config file, so secrets stay out of the mounted file too.

## Troubleshooting

**The boot fails and names a missing environment variable.**

A `!env NAME` in the config has no value. Define it in the environment or in
`.env`.

**The boot fails with `File::AccessDeniedError`.**

The mounted config is not readable by uid 10001. Fix the file mode or mount
it read-only from a readable path.

**A local hostname answers with a certificate error.**

Local names use the internal CA. Trust the Caddy root certificate on the
client, or use a public name for ACME.

**An app host gets no certificate.**

The ask endpoint answered `404`. The host is not a registered, active app
host. Register the app and set its host — see
[Registering an app](/build/apps/connect/register/).

**`/Healthcheck` fails after an image upgrade.**

Check the backend logs for a failed migration. The entrypoint retries the
migrate step three times, then the boot stops.

## Related

- [Go to production](/admin/install/production/) — the copy-paste Compose walkthrough.
- [System requirements](/admin/install/requirements/) — what the stack needs.
- [Configuration files](/admin/configure/configuration-files/) — the keys inside the mounted file.
- [Database migrations](/admin/keep-running/migrations/) — what the entrypoint runs at boot.
- [App hosting and deployment](/build/apps/host/deploy/) — the hosted-app surface.
- Internals on GitHub: [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
- [Apps: built fast, replaced freely](/discover/how-it-works/apps/)
