---
title: Is Facet right for you?
description: Check where Facet fits, where it does not, and what you need to run it.
type: explanation
audience: [evaluator]
features: []
verified_at: eee55a2
sidebar:
  order: 4
---

Facet is opinionated software: one model of domains, roles and history,
applied to every write. That model is what makes it safe to depend on — and
it is the wrong tool for some jobs. This page tells you which is which, so
you can decide before you install.

## Facet fits well when

Most of these hold for you:

- **The business side builds its own tools.** A person who knows the work
  describes the tool to an AI coding agent and ships it. Facet carries
  accounts, permissions, history and hosting, so the app stays small.
- **The records must outlive the apps.** A customer stays a customer, whatever
  tool edits it next. Delete an app; the data, the rules and the history stay.
- **People must see different rows and fields.** A salesperson sees their own
  clients; the warehouse does not see purchase prices. When an auditor asks
  who changed what, you have an answer.
- **The data must stay on your infrastructure.** Facet is self-hosted. Your
  data lives in your PostgreSQL and your file store, wherever you run it.
- **Access to developers is limited.** The platform carries sign-in, rights
  and audit once, for every app. A small team can ship many tools.
- **Your processes are your own.** You describe a domain — its record types,
  fields and rules — in a draft, check it, and publish it. There is no module
  to bend your work into.
- **Accountability is part of the job.** Facet records every change: who made
  it, when, and through which app. You set how long the history is kept.

Facet replaces the classical stack under the app — the bespoke backend, the
auth plumbing, the audit scripts. It does not replace the app; it makes the
app small enough to throw away.

## Facet is not the right tool when

These workloads need a lower level of control. Use a plain database and
hand-built services for them:

| Workload | Why it does not fit | Use instead |
| --- | --- | --- |
| **Heavy data load** | Every write is checked, recorded, and kept with its history. That costs time and storage per row. | A plain PostgreSQL schema, tuned for the load |
| **Statistics and analytics** | Lists and filters serve daily operations, not aggregate scans over very large row counts. | An analytics engine, fed by exports |
| **B2C products** | Facet serves the people of one organization. Accounts come from invites and SSO — there is no public self-service sign-up. | A custom-built consumer stack |
| **Multi-tenancy** | One deployment serves one organization. Facet has no walls between separate customer companies. | A purpose-built multi-tenant design |
| **Time-series entries** | High-frequency timestamped rows want append-only storage with retention pruning, not per-row history. | A time-series database |
| **A house IT architecture** | Facet applies its model as-is: domains, record types, roles, and the change log. It does not reshape around your own architecture. | Custom services around your architecture |
| **Wanting a hosted service** | Facet is self-hosted software; you run the servers. | A hosted platform |

## What Facet does not have

We would rather you hear this from us. Each line is checkable in the source:

- No built-in reports or charts. Export the data or read it through the API;
  a BI tool connects there, under the same role rules.
- No workflow engine. Event hooks and webhooks react to single events; there
  is no engine for multi-step flows or approval chains across domains.
- No prebuilt business modules: no CRM, accounting, inventory or HR to
  install. You model your domains; the assistant helps.
- No public sign-up. Accounts come from invites or SSO.
- No mobile app and no hosted version. You run Facet on your servers.
- No passkeys. Sign-in is password with MFA, SSO, or API keys.
- No role templates. You define each role's permissions yourself.

## What you need to run it

- **A server you control.** PostgreSQL 14 or newer, and Redis — one of each
  is enough for most installs. The full list sits on [System
  requirements](/admin/install/requirements/).
- **Docker with Compose** for the container path. The release stack is five
  services behind a TLS edge; you can also build from source.
- **One config file per environment.** Secret values can come from
  environment variables instead of the file.
- **An administrator account**, created on first start.
- **Someone who models the first domain.** No code is needed: you work in the
  **Builder**, with the assistant.
- **About an hour** to try it: [Your first hour](/build/first-hour/).

Facet is a young product: releases carry 0.x versions, and the ecosystem
around it is small. What balances that is on the [licensing
page](/discover/licensing-and-services/): you hold the source, and every
release converts to Apache 2.0 after four years.

## Decide in one afternoon

Run the stack, click through it, and build one small domain of your own:

1. Run the stack:

   ```sh
   git clone https://github.com/wearefacet/facet.git
   cd facet
   cp docker/.env.example docker/.env   # fill in hostname, SMTP, secrets
   docker compose -f docker/compose.prod.yml up -d --build
   docker compose -f docker/compose.prod.yml run --rm backend seed:admin ops@your-company.tld
   ```

2. Sign in with the printed one-time password and set a real password.
3. Click through the workspace: lists, filters, document history.
4. Build one small domain of your own — see
   [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/).

If step 4 took an hour and most of the fits above hold for you, Facet fits.

## Related

- [Why Facet](/discover/why-facet/) — the problems behind the model.
- [A day at Brightwater](/discover/a-day-at-brightwater/) — the product in
  one story.
- [Security and governance](/discover/security/) — the model a security
  review will ask about.
- [Licensing and services](/discover/licensing-and-services/) — what the
  licence lets you do.
- [Deploy to production](/admin/install/production/) — the full install
  walkthrough.
