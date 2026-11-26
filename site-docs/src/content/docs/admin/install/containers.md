---
type: how-to
title: Deploying with containers
description: Run the release container images behind a Caddy edge with automatic TLS.
audience: [operator]
features: [PLT-16, APP-06]
sidebar:
  order: 1
verified_at: 008dd880
---

Facet ships two release images on GHCR: one for the backend, one for the
frontend. The release stack adds PostgreSQL, Redis, and a Caddy edge that
terminates TLS and routes to app hosts. This page covers the images, the
config contract, and the edge. The step-by-step walkthrough stays in
[Deploy to production](/admin/install/production/).

## When to use this

Read this page when:

- You deploy with Docker or Compose.
- You choose which image tag to pin.
- You mount a config file or serve extra app hosts over TLS.

## Before you start

- Docker with Compose is on the host.
- You know the public hostname and the SMTP relay values.
- The host requirements are met — see
  [System requirements and topology](/admin/install/requirements/).

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

Pin a release tag in production. Use `sha-<sha>` when you must reproduce a
build exactly.

### 2. Supply the config

The backend resolves exactly one config file, in this order:

1. `FACET_CONFIG_FILE` — an explicit path, any mount point.
2. `/app/config.{APP_ENV}.yml` — your mount, or the entrypoint's copy of the
   shipped example, written only when the file is absent.
3. Nothing — the boot fails and names the missing path.

Three ways to overwrite the shipped example:

| Path | How |
| --- | --- |
| Mount over the default name | `-v ./facet.yml:/app/config.production.yml` |
| Use a custom environment | `-e APP_ENV=staging -v ./config.staging.yml:/app/config.staging.yml` |
| Use any path | `-e FACET_CONFIG_FILE=/etc/facet/facet.yml -v ./facet.yml:/etc/facet/facet.yml:ro` |

Every `!env NAME` in the config must exist in the environment. A missing
variable fails the boot at config load. The shipped example needs this set:

| Variable | Role |
| --- | --- |
| `FACET_HOST` / `FACET_BASE_URL` | The public main URL. Must be the exact origin browsers see. |
| `FACET_ARTIFACT_BASE_URL` | The origin that streams artifact bytes. |
| `FACET_ARTIFACT_GRANT_SECRET` | HMAC secret for artifact capability URLs. |
| `FACET_REDIS_URL` | The event bus Redis. |
| `FACET_MAIL_FROM_ADDRESS` / `FACET_MAIL_FROM_NAME` | Outbound email identity. |
| `FACET_SMTP_HOST` / `FACET_SMTP_USERNAME` / `FACET_SMTP_PASSWORD` | The SMTP relay. |
| `FACET_SECRETS_MASTER_KEY` | Protects every stored secret. Fails closed under 32 bytes. |

`DATABASE_URL` and `APP_ENV` stay environment-only. The backend reads them
outside YAML.

:::caution
A mounted config file must be readable by uid 10001. A root-owned `600`
mount fails the boot with `File::AccessDeniedError`.
:::

### 3. Let the entrypoint bootstrap the database

The backend entrypoint runs one chain on every boot:

```text
render config (when absent) → migrate → seed:core → exec facet server
```

Every step is idempotent and non-destructive. The chain never drops
anything. A one-off container runs any other command directly, so
`facet migrate` in a one-off container just works.

### 4. Serve TLS through the Caddy edge

The edge config has three site blocks:

| Site block | Routes | TLS |
| --- | --- | --- |
| The main hostname | `/Healthcheck`, `/Api`, `/app`, `/.well-known`, `/a`, and `/Ws` go to the backend. Everything else goes to the frontend. | Internal CA on local names, ACME on public names. |
| Catch-all on the same port | Every other SNI goes to the backend, where app hosting resolves the host. | On-Demand TLS, gated by an ask endpoint. |
| Port 80 | HTTP to HTTPS redirect. | — |

The main hostname gets a certificate from the internal CA when the name is
local (the default `facet.localhost`), and from Let's Encrypt when it is
public. Public certificates through the ACME HTTP-01 challenge need port 80
published.

The catch-all block serves registered app hosts — see
[Controlling app reach](/admin/apps-access/app-grants/) and
[App hosting and deployment](/build/apps/host/deploy/). Before it issues a
certificate, Caddy asks the backend at `/Edge/HostAsk`. The backend answers
`200` for a registered, active app host and `404` for everything else. A
host that is not a registered app host gets no certificate.

### 5. Verify the stack

The release pipeline runs a smoke gate on every image: the stack boots, the
backend answers `status: ok` on `/Healthcheck`, the login page loads through
the frontend, and the core doctypes exist. Run the same gate locally:

```sh
make docker_images   # build the local tags: facet, facet-frontend
make docker_smoke    # run the smoke stack and its checks
```

## Example

Mount a custom config with a Compose override file. Save this as
`docker/compose.override.yml`, then run Compose with both files:

```yaml
services:
  backend:
    environment:
      FACET_CONFIG_FILE: /etc/facet/facet.yml
    volumes:
      - ./facet.yml:/etc/facet/facet.yml:ro
```

```sh
docker compose -f docker/compose.prod.yml -f docker/compose.override.yml up -d
```

The mounted file may use `!env` references itself. The same expansion runs on
every config file, so secrets stay out of the mounted file too.

## Troubleshooting

**The boot fails and names a missing environment variable.**

A `!env NAME` in the config has no value. Define it in the environment or in
`docker/.env`.

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

- [Deploy to production](/admin/install/production/) — the copy-paste Compose walkthrough.
- [System requirements and topology](/admin/install/requirements/) — what the stack needs.
- [Configuration files](/admin/configure/configuration-files/) — the keys inside the mounted file.
- [Database migrations](/admin/keep-running/migrations/) — what the entrypoint runs at boot.
- [App hosting and deployment](/build/apps/host/deploy/) — the hosted-app surface.
- Internals on GitHub: [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
