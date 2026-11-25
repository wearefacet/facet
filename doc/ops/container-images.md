# Container images and the release stacks

How Facet ships as containers: the two release images, their config and env
contract, the release stack with the Caddy edge, the smoke gate, and the
publish pipeline. The plan that designed them:
[`doc/plans/container-release.md`](../plans/container-release.md).

**Files covered:** `docker/backend.Dockerfile`,
`docker/frontend.Dockerfile`, `docker/backend-entrypoint.sh`,
`docker/config.production.example.yml`, `docker/compose.prod.yml`,
`docker/Caddyfile.prod`, `docker/.env.example`, `docker/compose.smoke.yml`,
`docker/smoke.sh`, `Makefile` (`docker_images`, `docker_smoke`),
`.github/workflows/docker.yml`.

## Image contracts

| Image | Contents | Runs as | Healthcheck |
| --- | --- | --- | --- |
| `ghcr.io/wearefacet/facet` | The Crystal binary, `src/` (assistant skill corpora + `__DIR__`-relative config resolution), `shard.yml`, the shipped config example, the entrypoint | `facet` (uid 10001) | `curl -f http://127.0.0.1:3000/Healthcheck` |
| `ghcr.io/wearefacet/facet-frontend` | The adapter-node build output, `package.json`, production `node_modules` | `node` | `node -e fetch` — any status below 500 passes (the auth hook answers an anonymous caller with a 303/403) |

Load-bearing details:

- The runtime tree keeps `/app/{facet,src,shard.yml}` — the `__DIR__` config
  resolution and the assistant skill corpora read from it (see the plan §7).
- Migrations, Lua event scripts, and the seed corpus are embedded at compile
  time; a changed migration or seed file requires a rebuild.
- The backend runtime needs `liblua5.4-0`, `libxml2`, `libyaml-0-2` and
  `ca-certificates` (Crystal stdlib link deps + outbound TLS).
- The frontend ships production `node_modules` because Vite externalizes the
  `package.json` `dependencies` for the SSR build — the server chunks import
  them at runtime.

## Build args

| Arg | Feeds | Default |
| --- | --- | --- |
| `VERSION` | OCI label `org.opencontainers.image.version` | `dev` |
| `REVISION` | OCI label `org.opencontainers.image.revision` | `unknown` |

Labels only — no registry or secret access at build time.

## Config contract — the backend boot

The config resolver picks exactly one file, fail loud:

1. `FACET_CONFIG_FILE` — an explicit path, any mount point;
2. `/app/config.{APP_ENV}.yml` — the operator's mount, or the entrypoint's
   copy of the shipped example, written only when that file is absent;
3. nothing → the boot fails with the missing path in the message.

Every `!env NAME` in the shipped example must be defined in the environment;
a missing variable fails the boot at config load. The names:

| Variable | Role |
| --- | --- |
| `FACET_HOST` / `FACET_BASE_URL` | The public main URL — discovery, OAuth redirects, the reserved app-host set. Must be the exact origin browsers see (scheme, host, port): DPoP clients sign this origin as their proof `htu`, and a mismatch answers `400`/`401`. A reverse proxy must forward the public scheme and host unchanged — see [`../backend/oauth.md`](../backend/oauth.md) → `htu` is pinned to the configured origin |
| `FACET_ARTIFACT_BASE_URL` | The artifact byte-streaming origin |
| `FACET_ARTIFACT_GRANT_SECRET` | HMAC secret for artifact capability URLs |
| `FACET_REDIS_URL` | The event bus Redis |
| `FACET_MAIL_FROM_ADDRESS` / `FACET_MAIL_FROM_NAME` | Outbound email identity |
| `FACET_SMTP_HOST` / `FACET_SMTP_USERNAME` / `FACET_SMTP_PASSWORD` | The SMTP relay (`port` is static: 587 — `!env` expands to a string and the config reader casts integers) |
| `FACET_SECRETS_MASTER_KEY` | Protects every stored secret; fails closed under 32 bytes |

The `FACET_AI_API_ENDPOINT` / `FACET_AI_API_KEY` / `FACET_AI_MODEL` triplet
is **optional** — the shipped example reads the assistant keys through
`!env?`, so an image without them boots normally and ships the assistant
disabled (the dock explains the posture; system settings can enable it at
runtime). See [`../backend/config.md`](../backend/config.md) → The `!env?`
tag and [`../backend/assistant.md`](../backend/assistant.md) → Configured
state.

`DATABASE_URL` and `APP_ENV` stay env-only — the backend reads them outside
YAML. `JWT_SIGNING_KEY` is env-only too: it holds the ES256 access-token
signing key (a P-256 private key in PEM form) and is required by
`docker/compose.prod.yml`. Without it, each boot mints a temporary key and
invalidates outstanding access tokens. See [`../backend/iam.md`](../backend/iam.md)
→ `Facet::IAM::JWT`.

A mounted config file must be readable by the image user (uid 10001) — a
root-owned `600` mount fails the boot with `File::AccessDeniedError`. The
mounted file may use `!env` references itself; the same expansion runs on it.

## Entrypoint chain

`render config (when absent)` → `migrate` (3 attempts) → `seed:core` →
`exec facet server`. All steps are idempotent and non-destructive — the
chain never drops anything (`db_reset` appears in no image path). With any
first argument other than `server`, the entrypoint renders the config and
execs the binary directly (`facet migrate` in a one-off container just
works).

## Release stack — `docker/compose.prod.yml`

| Service | Image | Notes |
| --- | --- | --- |
| `postgres` | `pgvector/pgvector:0.8.0-pg17` | Named volume `pg-data`; internal only |
| `redis` | `redis:7` | Named volume `redis-data`; internal only |
| `backend` | `facet` | The `FACET_*` set, `DATABASE_URL`, volume `artifact-store:/data/store` |
| `frontend` | `facet-frontend` | `BACKEND_URL=http://backend:3000` (the reserved service-host pattern) |
| `caddy` | `caddy:2` | Publishes the TLS port; volumes `caddy-data` + `Caddyfile.prod` (read-only); network alias `facet.localhost` |

Env files: a git-ignored `docker/.env` supplies the Postgres credentials, the
edge placement, and every secret — compose interpolates the backend's
`DATABASE_URL` from the same Postgres keys, so the password exists in exactly
one place. `docker/.env.example` documents every key.

Edge routes (`docker/Caddyfile.prod`, all addresses env placeholders):

| Site block | Routes | TLS |
| --- | --- | --- |
| `https://{$FACET_HOSTNAME:facet.localhost}:{$HTTPS_PORT:3443}` | `/Healthcheck /Api /app /.well-known /a /Ws` → backend; everything else → frontend | Internal CA on local names, ACME on public ones |
| `https://:{$HTTPS_PORT:3443}` | Every other SNI → backend (`App::Hosting` resolves the Host) | On-Demand TLS — `issuer acme` + `issuer internal` in order, gated by the ask endpoint |
| `http://:80` | HTTP→HTTPS redirect | Inert unless the `.env` publishes the port (real domains: `CADDY_HTTP_PUBLISH=80:80` for ACME HTTP-01) |

The global `on_demand_tls` block points the ask at
`http://backend:3000/Edge/HostAsk`; the backend approves a registered active
app host with `200` and denies everything else with `404` (`Cache-Control:
no-store`). A site with no hostnames gets only public issuers by default, so
the catch-all names its issuer chain explicitly — local names fall through to
the internal CA.

### Ports

The stack uses two port numbers with different scopes:

| Port | Who listens | Reachable from | Source |
| --- | --- | --- | --- |
| `3000` | The backend (Kemal binds `0.0.0.0:3000`), and the frontend node server (`PORT=3000`) | The Docker network only — compose publishes no host port for either service | `docker/backend.Dockerfile`, `docker/frontend.Dockerfile` |
| `${HTTPS_PORT:-3443}` | The Caddy edge | The host and the network — compose publishes it | `docker/compose.prod.yml`, `docker/.env.example` |

The two services share port `3000` because they sit on separate containers.
Caddy reaches them by service name (`{$BACKEND_URL:http://backend:3000}`,
`{$FRONTEND_URL:http://frontend:3000}`), so the number never reaches the
public surface. A browser, a health probe from the host, or a `curl` against
the edge uses the `HTTPS_PORT` address. A probe or a scrape against
`http://127.0.0.1:3000` runs inside a container: the backend image carries
`curl` for that (`HEALTHCHECK CMD curl -f
http://127.0.0.1:3000/Healthcheck`).

## Smoke gate — `docker/compose.smoke.yml`

The minimum that proves the artifacts: postgres, redis, backend, frontend —
no Caddy, throwaway test env values, image refs parameterized
(`BACKEND_IMAGE` / `FRONTEND_IMAGE`; local defaults `facet` /
`facet-frontend`). `docker/smoke.sh` runs it and checks:

1. `up -d --wait` is green.
2. `GET /Healthcheck` on the published backend port answers `status: ok`.
3. The login page fetches end to end through the frontend port (final `200`).
4. A SQL probe confirms the core doctype rows — `migrate` + `seed:core`
   booted an empty volume.
5. A restart re-runs the bootstrap on the seeded database and stays healthy.
6. The `FACET_CONFIG_FILE` override: a copy of the shipped example with two
   values changed, mounted read-only, boots and passes `/Healthcheck`.

## Commands

```bash
make docker_images   # build the local tags: facet, facet-frontend
make docker_smoke    # run the smoke stack and its checks (docker/smoke.sh)
```

The local builds are native-arch. Cross-building the other arch locally
needs QEMU and multi-hour Crystal compiles — the CI runners are the arm
path.

## Publish pipeline — `.github/workflows/docker.yml`

| Job | Runner | Matrix | Pushes |
| --- | --- | --- | --- |
| `build` | `ubuntu-latest` (amd64) / `ubuntu-24.04-arm` (arm64) | image × arch | `sha-<sha>` by digest |
| `smoke` | matches the arch | arch | — |
| `merge` | `ubuntu-latest` | — | `X.Y.Z` + `X.Y` + `latest` (a `v*` tag) or `master` + `nightly` (a `master` push) |

Triggers: a `v*` tag runs the full release pipeline (this workflow claims
`v*`; `release-npm.yml` claims `cli-v*`); a push to `master` publishes the
rolling channel — `master` and `nightly` move on every green build and
`latest` stays release-only; `workflow_dispatch` pushes the `sha-*` tag only;
a PR touching `docker/**` builds and smokes on local tags and pushes nothing.
Channel tags are created in the merge job from the four per-arch digests,
after the smoke gate on both arches — a failed smoke leaves the registry
untouched apart from a prunable `sha-*` tag. Branch builds (master, PRs)
cancel their superseded runs; release tags are never cancelled. Caching:
`type=gha` per image and arch. After the first push, set both GHCR packages
to public once in the package settings; later pushes keep the setting.
