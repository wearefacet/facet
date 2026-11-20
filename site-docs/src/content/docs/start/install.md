---
title: Install for development
description: Set up a local Facet development environment from source.
audience: [developer]
features: [PLT-01, PLT-16, IAM-12, DOM-24]
sidebar:
  order: 6
verified_at: 7a6cb462
---

Facet runs from source on Linux and macOS. If you only want to try the
product, run the Docker Compose stack instead — see
[Deploy to production](/operate/production/).

## Prerequisites

Install these tools first. The table lists what each one serves:

| Tool                       | Notes                                                                              |
| -------------------------- | ---------------------------------------------------------------------------------- |
| Crystal 1.21               | The toolchain in use. The `agent-cr` shard needs Crystal 1.19 or newer.            |
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
scripts/import-fixtures   # optional: load the sample CRM / HR / production domains
./scripts/dev             # Caddy + backend + frontend at https://facet.localhost:3443
```

`scripts/init` runs `facet db_reset seed:dev`: it drops and re-creates the
database, applies all migrations, and seeds the core schema with a dev
administrator.

Open `https://facet.localhost:3443` and sign in with the seeded dev
administrator: `admin@example.tld` / `admin`. This credential is for throwaway
dev data only — the platform refuses it in production.

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
`:5173`).

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

## Next steps

- Read [Domains, drafts and domain editors](/build/domains-drafts-editors/) to learn how Facet organizes data.
- Read [Deploy to production](/operate/production/) when you are ready to ship.
