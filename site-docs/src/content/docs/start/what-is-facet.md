---
title: What is Facet
description: Learn what Facet is — the governed home for your business data and the apps you build on it.
audience: [evaluator]
features: []
sidebar:
  order: 1
verified_at: 7a6cb462
---

Facet is a governed application platform for small and mid-sized
organizations. It hosts the internal apps you build. It owns the data, the
rights, and the history those apps run on.

## The problem it solves

A business person can describe the app they want to Claude Code or another
coding agent, and the agent writes it in hours. Running that app safely used
to be the slow part:

- someone must host it,
- someone must decide who can read and change each record,
- someone must keep a history of every change.

Facet takes that work off the table.

**Apps are disposable; your data is not.** The app your agent built last
quarter can be replaced. The records, the rules, and the history stay.

## The substrate and the app

Facet separates two things that custom stacks usually mix:

| Layer               | What it holds                                                                   | Lifespan                          |
| ------------------- | ------------------------------------------------------------------------------- | --------------------------------- |
| The substrate       | Documents, roles, permissions, audit log, files, secrets, identity              | Years — it outlives every app     |
| The app             | A frontend or an agent that reads and writes through the API                    | Weeks or months — replace it freely |

**The app stays outside.** An app never runs inside Facet and never touches
the database. It signs in over OAuth (an open authorization protocol) and
calls the HTTP API under the rights you gave it. Delete the app, and the data,
the rules, and the history remain.

## What you get for free

Every app on Facet inherits the same services. You do not build them again:

| Service  | What it means                                                                                                                       |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Identity | Accounts, passwords, MFA (multi-factor authentication), SSO (single sign-on) through OIDC, and API keys                              |
| Rights   | Roles decide who reads and writes — per record type, down to single fields and rows. Enforcement sits in the data layer, not in the app |
| Audit    | Every change lands in an append-only log: who changed what, when, and why. Roll any document back to a prior state                   |
| Hosting  | Facet serves the app frontend, signs users in, and proxies the API calls                                                             |

## Build with an agent, not an IT project

You do not need the classical development stack to ship an internal tool:

- **With a coding agent.** Connect Claude Code or any MCP (Model Context
  Protocol) client to Facet. The agent gets tools to read and write data under
  one role you pin. The platform checks every call, exactly as it checks a
  human user.
- **Inside the workspace.** The domain-builder assistant drafts doctypes and
  views from prompts.
- **By hand.** For a hand-written frontend, the TypeScript SDK and CLI cover
  the build, and Facet hosts the result and signs in its users.

  The agent never touches the database. Rights, audit, and history come from
  the platform, so the app your business person describes is safe by default.

## What it runs on

- **Backend:** Crystal, PostgreSQL, Redis. Documents are JSONB rows.
- **Workspace:** a web app with table, kanban, grid, calendar, form, and show
  surfaces. Your team works with no extra frontend work.
- **Apps and agents:** a REST API, a TypeScript SDK, a CLI, and MCP (Model
  Context Protocol) tools.

## See it running

```sh
git clone https://github.com/wearefacet/facet.git
cd facet
cp docker/.env.example docker/.env   # fill in hostname, SMTP, secrets
docker compose -f docker/compose.prod.yml up -d --build
```

The entrypoint applies migrations and seeds the core schema on boot. Then
create the first administrator:

```sh
docker compose -f docker/compose.prod.yml exec backend facet seed:admin ops@your-company.tld
```

The command prints a one-time password. Sign in at `https://<your-hostname>`
and set a real password when prompted. The full steps are in
[Deploy to production](/operate/production/).

:::tip
Load the sample domains with `scripts/import-fixtures` in a source checkout.
You get a customer, HR, and production model with data, before you build your
own.
:::

## Related

- [Is Facet right for you?](/start/is-facet-right-for-you/) — the good fits, the poor fits, and the business cases it answers.
- [Architecture at a glance](/start/architecture/) — how a request moves through the system.
- [Domains, drafts and domain editors](/build/domains-drafts-editors/) — how Facet organizes data.
