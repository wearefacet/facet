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
applied to every write. That model is what makes it safe to depend on, and it
is also why Facet is the wrong tool for some jobs. This page covers both, so
you can decide before you install.

## Facet fits when

If most of these rows describe you, Facet is built for you.

| When | What Facet gives you | Instead of |
| --- | --- | --- |
| **The business side builds its own tools** | A person who knows the work describes the tool to an AI coding agent and ships it. Facet carries accounts, permissions, history and hosting, so the app stays small. | A bespoke backend behind every app |
| **The records must outlive the apps** | A customer stays a customer, whatever tool edits it next. Delete an app; the data, the rules and the history stay. | Data locked inside each app |
| **People must see different rows and fields** | A salesperson sees their own clients; the warehouse does not see purchase prices. The same rules apply in every app and in the API. | Permission checks hand-coded per app |
| **Accountability is part of the job** | Every change is recorded: who made it, when, and through which app. When an auditor asks, you have the answer. You set how long history is kept. | Audit scripts and ad-hoc logging |
| **Developer time is scarce** | Sign-in, rights and audit are built once, on the platform, for every app. A small team can ship many tools. | Auth plumbing rebuilt for each tool |
| **Your processes are your own** | You describe a domain (its record types, fields and rules) in a draft, check it, and publish it. | A packaged module you bend your work into |
| **The data must stay on your infrastructure** | Facet is self-hosted. Your data lives in your PostgreSQL and your file store, wherever you run it. | A vendor holding your data |

Facet replaces the stack under the app, not the app itself. It makes the app
small enough to throw away.

## Facet does not fit when

First, a note on volume: an organization's business data is not a heavy load.
Millions of records, and tens of thousands of new ones a day, are ordinary
work for Facet on a standard setup. Its storage is PostgreSQL, so it scales
the same way PostgreSQL does.

The limit is data written by machines rather than by people's work. Facet
checks every write and keeps its history. That cost is negligible for a
customer record or an order. For a stream of clicks or sensor readings, it
is waste. Run those workloads on a store built for them, next to Facet, and
keep Facet as the system of record.

| When | Why Facet does not fit | Use instead |
| --- | --- | --- |
| **You ingest events at machine rate** | Clickstreams, sensor feeds, logs and tracking pixels arrive at thousands of writes per second. They need append-only storage with retention pruning, not a checked, versioned record per event. | A time-series database or an event store |
| **You run statistics and analytics** | Lists and filters serve daily operations, not aggregate scans across the whole history. | An analytics engine, fed by exports |
| **You build a consumer product** | Facet serves the people of one organization: staff, partners, a known set of clients. Accounts come from invites and SSO. There is no public sign-up, and it is not designed for millions of anonymous end users. | A custom-built consumer stack |
| **You serve several customer companies** | One deployment serves one organization. Facet has no walls between separate tenants. | A purpose-built multi-tenant design |
| **You have a house IT architecture to follow** | Facet applies its model as-is: domains, record types, roles, and the change log. It does not reshape itself around your architecture. | Custom services around your architecture |
| **You want a hosted service** | Facet is self-hosted software; you run the servers. | A hosted platform |

## What is not built in (yet)

Every item below can be checked in the source. Each one has a workaround. Most are planned in the future.

| Not built in | What to do instead |
| --- | --- |
| **Reports and charts** | Export the data or read it through the API. A BI tool connects there, under the same role rules. |
| **A workflow engine** | Event hooks and webhooks react to single events. Multi-step flows and approval chains across domains need an external tool. |
| **Prebuilt business modules** (CRM, accounting, inventory, HR) | Model your own domains in the Builder; the assistant helps. |
| **Role templates** | Define each role's permissions yourself. |
| **Passkeys** | Sign in with a password and MFA, SSO, or API keys. |
| **A mobile app** | Use the web workspace, or build a client on the API. |

## What you need to run it

- **A server you control.** PostgreSQL 14 or newer, and Redis. One of each is
  enough for most installs. The full list is on [System
  requirements](/admin/install/requirements/).
- **Docker with Compose** for the container path. The release stack is five
  services behind a TLS edge. You can also build from source.
- **One config file per environment.** Secret values can come from
  environment variables instead of the file.
- **An administrator account**, created on first start.
- **Someone to model the first domain.** No code is needed: you work in the
  **Builder**, with the assistant.
- **About an hour** to try it: [Your first hour](/build/first-hour/).

### A young product, with your exit covered

Facet releases still carry 0.x versions, and the ecosystem around it is small.
In return, you hold the source, and every release converts to Apache 2.0 after
four years. See [Licensing and services](/discover/licensing-and-services/).

## Decide in one afternoon

Run the stack, click through it, and build one small domain of your own.
[Run Facet](/build/first-hour/run-facet/) is the full walkthrough; the short
form:

1. Run the stack with one command, in an empty folder. It writes the stack
   files, starts the five containers, and seeds the admin:

   ```sh
   pnpx @facetapp/cli setup-dev
   ```

2. Sign in at `https://facet.localhost:3443` with `admin@example.tld` /
   `admin`, and take the welcome tour.
3. Click through the workspace: lists, filters, document history.
4. Build one small domain of your own. See [Model your first
domain](/build/first-hour/first-domain/) for the guided route, or [Drafts,
editors and publishing](/build/model/in-app/drafts-and-publishing/) for the
   reference.

If step 4 took about an hour and most of the rows in
[Facet fits when](#facet-fits-when) describe you, Facet fits.

## Related

- [Why Facet](/discover/why-facet/): the problems behind the model.
- [A day at Brightwater](/discover/a-day-at-brightwater/): the product in
  one story.
- [Security and governance](/discover/security/): the model a security
  review will ask about.
- [Licensing and services](/discover/licensing-and-services/): what the
  licence lets you do.
- [Deploy to production](/admin/install/production/): the full install
  walkthrough.
