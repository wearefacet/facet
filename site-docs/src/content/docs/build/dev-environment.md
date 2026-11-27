---
type: how-to
title: Set up a dev environment
description: Run Facet from source — the dev environment for file-based domains, app development, and product work.
audience: [developer]
features: [PLT-01, PLT-16, IAM-12, DOM-24]
sidebar:
  order: 2
verified_at: eee55a2
---

Three kinds of work need Facet running from source:

- **Domains as files.** The dev watcher applies every save in a domain
  folder to the running database — the path
  [The same domain in files](/build/first-hour/first-domain-in-files/)
  walks through.
- **Applications.** A hosted app is a codebase you develop next to a live
  backend — [Ship your first app](/build/first-hour/first-app/) ends in
  this setup.
- **The product itself.** Backend specs, frontend components, and the CLI
  all run against a local stack.

If you only want to try the product, stop here: run the container stack
with one command — `facet-cli setup-dev`, described in
[Run Facet](/build/first-hour/run-facet/) — or follow
[Deploy to production](/admin/install/production/). This page is the source
route, for when you change the backend, the frontend, or the CLI itself.

:::tip
`facet-cli setup-dev` stands up a container dev instance without a clone.
It also creates a `domains/` watch folder by default. Use this page when
you need to modify Facet's own code.
:::

## Prerequisites

Install these tools first. The table lists what each one serves:

| Tool                       | Notes                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------- |
| Crystal 1.21 or newer      | The toolchain in use is 1.22. The `agent-cr` shard needs 1.19 or newer.            |
| PostgreSQL 14 or newer     | One instance for the app. The `ulid()` function needs PostgreSQL 14.               |
| Redis                      | Required. The event bus, sessions, OAuth codes, and rate limits use it.            |
| Node.js 20+ and pnpm       | Frontend, CLI package, E2E runner. pnpm only — the lockfiles are `pnpm-lock.yaml`. |
| Caddy                      | The dev proxy. `scripts/dev` expects it on PATH.                                   |
| Lua 5.4 or 5.5 headers     | The `lua` shard links the system library (`liblua5.4-dev` on Debian/Ubuntu).       |

## Get the code

Clone the repository:

```sh
git clone https://github.com/wearefacet/facet.git
cd facet
```

## Configure

Configuration lives in two files:

- `config.dev.yml` — backend configuration (database, Redis, mail, artifacts).
- the root `.env` — shared addresses, notably `BACKEND_URL`.

## Bootstrap

Run the three scripts in order:

```sh
scripts/init              # create the database, migrate, seed core doctypes + a dev admin
scripts/import-fixtures   # optional: load the sample domains under data/fixtures/
./scripts/dev             # Caddy + backend + frontend at https://facet.localhost:3443
```

`scripts/init` runs `facet db_reset seed:dev`: it drops and re-creates the
database, applies all migrations, and seeds the core schema with a dev
administrator. `scripts/import-fixtures` imports the fixture bundles under
`data/fixtures/` — sample CRM, HR, production, and identity domains. It is
safe to re-run: each import merges into what is already there.

## Check that it works

Give the stack about a minute, then run these checks:

1. Open `https://facet.localhost:3443` and sign in with the seeded dev
   administrator: `admin@example.tld` / `admin`. This credential is for
   throwaway dev data only — the platform refuses it in production.
2. Ask the backend for its health:

   ```sh
   curl -sk https://facet.localhost:3443/Healthcheck
   ```

   ```json
   {"status":"ok","service":{"env":"dev",…},"database":{"status":"ok",…},"redis":{"status":"ok",…},…}
   ```

   Every subsystem in the answer must read `"ok"`.
3. Compile both halves clean:

   ```sh
   make check            # backend type-check, no binary
   cd frontend && pnpm check   # svelte-check: types, syntax, accessibility
   ```

## What runs

Three processes serve the stack:

<!-- d2
caddy: Caddy
frontend: "SvelteKit frontend"
backend: "Crystal backend"
postgres: PostgreSQL {class: store}
redis: Redis {class: store}

caddy -> frontend: https
caddy -> backend: https
frontend -> backend: API calls
backend -> postgres
backend -> redis
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/18dda779-light.svg" alt="SvelteKit frontend" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/18dda779-dark.svg" alt="SvelteKit frontend" loading="lazy" />
</div>

`./scripts/dev` starts all processes in one terminal. Use
`./scripts/dev --no-caddy` for raw two-port mode (backend `:3000`, frontend
`:5173`). Hosted apps answer at their own hosts under
`https://*.apps.localhost:3443`.

## Daily commands

Backend (repository root):

| Command                             | Purpose                                                            |
| ----------------------------------- | ------------------------------------------------------------------ |
| `make check`                        | Compile gate, no binary. Fastest signal on type errors.            |
| `make build` / `make build_release` | Server binary into `build/`.                                       |
| `make run`                          | Backend only.                                                      |
| `make test`                         | Full spec suite. Starts a throwaway PostgreSQL on port 5433 first. |
| `bin/ameba`                         | Crystal linter.                                                    |

Frontend (in `frontend/`):

| Command          | Purpose                                               |
| ---------------- | ----------------------------------------------------- |
| `pnpm check`     | `svelte-check` — types, Svelte syntax, accessibility. |
| `pnpm lint`      | Prettier + ESLint.                                    |
| `pnpm test`      | Vitest: pure logic + Storybook story play functions.  |
| `pnpm storybook` | Component workbench.                                  |

## The example domains

The dev configuration watches `site-docs/examples/brightwater`
(`dev.domain_watch` in `config.dev.yml`, 500 millisecond poll). Save a
file in that folder and the running database changes with it — the
mechanism [The same domain in
files](/build/first-hour/first-domain-in-files/) demonstrates. To watch
your own folder instead, point `dev.domain_watch.path` at it. The watcher
refuses to start in production.

## Related

- [The dev domain watcher](/build/model/in-files/domain-watcher/) — the
  watch contract: config keys, modes, failure behavior.
- [Deploy to production](/admin/install/production/) — the container
  stack, when you ship.
- [Run Facet](/build/first-hour/run-facet/) — the container route of the
  first hour.
- [Security and governance](/discover/security/)
- [System requirements](/admin/install/requirements/)
