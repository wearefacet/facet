<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="frontend/src/lib/assets/facet-lockup-dark.svg">
  <img src="frontend/src/lib/assets/facet-lockup-light.svg" alt="Facet" width="420">
</picture>

&nbsp;

[![CI](https://github.com/wearefacet/facet/actions/workflows/ci.yml/badge.svg)](https://github.com/wearefacet/facet/actions/workflows/ci.yml)
[![E2E](https://github.com/wearefacet/facet/actions/workflows/e2e.yml/badge.svg)](https://github.com/wearefacet/facet/actions/workflows/e2e.yml)
[![Docker images](https://github.com/wearefacet/facet/actions/workflows/docker.yml/badge.svg)](https://github.com/wearefacet/facet/actions/workflows/docker.yml)
[![Release npm package](https://github.com/wearefacet/facet/actions/workflows/release-npm.yml/badge.svg)](https://github.com/wearefacet/facet/actions/workflows/release-npm.yml)
[![version](https://img.shields.io/badge/version-0.2.1--beta-D9822B)](CHANGELOG.md)

[Website](https://facetapp.tech) · [Documentation](https://docs.facetapp.tech)

</div>

Facet is a governed application platform for small and mid-sized businesses: it hosts the internal apps they build with AI and provides the data layer, authentication, permissions, and audit trail those apps need to run in production.

## Why

AI has made building a business app a matter of hours. Running it safely has not gotten easier: someone still has to host it, decide who can see what, and keep a history of changes. Facet takes that part off the table. Apps are disposable; the data and the rules around it are not, so Facet is where those live.

## What it does

**A governed home for business data.** Data is organized into domains (HR, Sales, Inventory…) and typed record types (doctypes), stored as JSONB in PostgreSQL. Fields are typed — text, numbers, money (with a world-currency registry), dates, periods, references between records — and every write is validated against the definition before it lands. Records can carry human-readable reference numbers generated from templates.

**Permissions enforced in the data layer.** Roles decide who reads, creates, updates, or deletes — per doctype, down to single fields and rows. Enforcement happens in the data layer, not in the app, so a quickly built frontend cannot bypass it. Sharing between domains is an explicit, auditable consent (domain grants), not an accident.

**A full history of every change.** Every mutation is appended to an event log: who changed what, and when. Any document can be audited, rolled back to a prior state, or restored after deletion.

**A working web app out of the box.** Table, kanban, grid, calendar, form, markdown, show, and relations surfaces. Saved views, schema-aware filters, cross-doctype search, a command palette, in-app notifications, and live updates over WebSocket. Teams run daily operations with no frontend work.

**Identity and access.** Accounts with passwords, TOTP multi-factor authentication, sessions and JWT, static API keys, and single sign-on through OIDC. An audit log of every login.

**Automation and integration.** Signed webhooks with a delivery-reconcile backstop, Lua domain hooks (event-driven or on a schedule), background jobs, cron, cross-domain field replication, document import and export (CSV), and transactional email.

**Files and secrets.** An artifact store with signed, expiring download grants, and an encrypted secret store for credentials the platform and scripts need.

**Portable by design.** Export any domain — definitions and, optionally, its documents — into a single bundle, and import it into another Facet instance. Move a schema from staging to production; take the data with you.

**Draft and publish.** Data-model changes are prepared in a draft domain and published when ready, so the model can evolve without breaking what is running.

**An assistant in every app.** Any app built on Facet can ship with its own AI assistant. The [`@facetapp/chat`](packages/chat) npm package embeds an inline chat or a floating window in any frontend, scoped to the app's identity and grants — the assistant answers and acts under the app's permissions. The main application carries the same assistant for everyday work, and a domain-builder assistant drafts doctypes and views from prompts.

**An open surface for apps and agents.** External apps sign in through OAuth 2.1 with PKCE and work under explicit grants. The REST API ships an OpenAPI document. A TypeScript SDK ([`packages/sdk`](packages/sdk)) and a CLI ([`packages/cli`](packages/cli)) cover app developers; the CLI also deploys apps that Facet serves behind its own authentication. An MCP server exposes tools to external agents under one pinned role.

## Status

This is still in beta: features are complete enough to build on, and the surfaces you use day to day keep improving — expect UI and UX refinements as we respond to feedback. See [`CHANGELOG.md`](CHANGELOG.md).

## Installation

### With Docker Compose (production or evaluation)

Requirements: Docker with Compose. The stack runs PostgreSQL, Redis, the backend, the frontend, and a Caddy edge with TLS.

1. Clone this repository and create the environment file:

   ```sh
   cp docker/.env.example docker/.env
   ```

   Fill in the values — public hostname, SMTP relay, secrets. The file documents each key.

2. Build and start the stack:

   ```sh
   docker compose -f docker/compose.prod.yml up -d --build
   ```

   The backend entrypoint applies migrations and seeds the core schema on every boot. No manual schema step.

3. Create the first administrator:

   ```sh
   docker compose -f docker/compose.prod.yml exec backend facet seed:admin ops@your-company.tld
   ```

   The command prints a one-time password. It is shown once — record it in a password manager.

4. Open `https://<your-hostname>` (default: `https://facet.localhost:3443`), sign in with the one-time password, and set a real password when prompted.

The detailed runbook is [`doc/ops/first-deployment.md`](doc/ops/first-deployment.md); images, config, and the edge are covered in [`doc/ops/container-images.md`](doc/ops/container-images.md).

### From source (development)

Requirements: Crystal 1.21, PostgreSQL 14+, Redis, Node.js 20+ with pnpm (pnpm only), Caddy, and Lua 5.4 or 5.5 headers.

```sh
scripts/init              # create the database, migrate, seed core doctypes + a dev admin
scripts/import-fixtures   # optional: load the sample CRM / HR / production domains
./scripts/dev             # Caddy + backend + frontend at https://facet.localhost:3443
```

Sign in with the seeded dev administrator: `admin@example.tld` / `admin`. This credential is for throwaway dev data only — the platform refuses it in production. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the full environment setup and the command map.

## Stack

- Backend: Crystal + Kemal + PostgreSQL + Lua scripting + OpenTelemetry
- Frontend: SvelteKit (Svelte 5) + TypeScript + Tailwind CSS + Bits UI
- App-developer CLI: [`packages/cli`](packages/cli) — TypeScript SDK: [`packages/sdk`](packages/sdk) — embeddable assistant chat: [`packages/chat`](packages/chat)

## Documentation

The full documentation site is [docs.facetapp.tech](https://docs.facetapp.tech). Key pages:

- [Start here](https://docs.facetapp.tech/start/): what Facet is, the architecture, the security model, and the install guide
- [Tutorials](https://docs.facetapp.tech/tutorials/): run Facet in 15 minutes, build your first domain, give your team access
- [Use the workspace](https://docs.facetapp.tech/workspace/): records, views, search, history, and notifications
- [Build domains](https://docs.facetapp.tech/build/): doctypes, fields, views, actions, and automation
- [Govern access](https://docs.facetapp.tech/govern/): roles, scopes, audit, and rollback
- [Build apps](https://docs.facetapp.tech/apps/): the TypeScript SDK, the REST API, OAuth, and the MCP server
- [Operate](https://docs.facetapp.tech/operate/): containers, configuration, monitoring, and upgrades
- [Reference](https://docs.facetapp.tech/reference/): field types, filter operators, config keys, the CLI, and API details

In this repository:

- [`CONTRIBUTING.md`](CONTRIBUTING.md): environment setup, daily commands, and a map from each subsystem to its concern document
- [`doc/project-structure.md`](doc/project-structure.md): architecture overview and directory layout
- [`doc/ops/first-deployment.md`](doc/ops/first-deployment.md): first-deployment bootstrap runbook
- [`CHANGELOG.md`](CHANGELOG.md): release notes

## License

Facet is source-available software, licensed under the Business Source License 1.1 (`BUSL-1.1`). You can use it, modify it, fork it, build products on it, and provide services around it. The two restrictions block self-service Facet offerings and public one-click deployments. Every release converts to Apache 2.0 four years after publication. See [`LICENSING.md`](LICENSING.md) for examples of what is allowed, and [`TRADEMARKS.md`](TRADEMARKS.md) for the naming rules.
