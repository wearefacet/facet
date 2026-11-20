---
title: Facet vs Retool and low-code builders
description: Retool builds screens on top of databases you already run. Facet is the governed data layer itself, with a portal, app hosting and per-record rules built in, and no per-user licence.
audience: [evaluator]
features: []
sidebar:
  order: 3
verified_at: bd4be053
---

**In one line:** Retool builds screens on top of your data. Facet *is* the data, with the rules, the history and the app hosting built in.

## Who this page is for

Your team needs admin panels and internal tools. A developer proposed Retool; someone else asked whether the data should be sorted out first. This page separates the two jobs, and helps you decide which one you actually have.

## The core difference

Retool is a mature UI (user interface) layer. You connect your databases and APIs, and its visual builder turns them into admin panels, dashboards and internal apps. Its pricing page states the model plainly: your queries run against your own data sources, and Retool does not store your data. Retool also offers a hosted PostgreSQL database and a workflow engine, but the core product is the layer of screens.

That model assumes you already have a database worth building on: one with a clear schema, backups, and someone who owns it. Many 20-to-200-person companies do not. Their records live in spreadsheets, and the "internal tool" question is really a data question.

Facet answers that one. It holds the data in PostgreSQL, enforces who can read and change each record, keeps the history, stores the files, and hosts the apps your team uses. It also ships its own portal (list, calendar and kanban views plus an edit page per document), generated from templates the assistant writes. Many domains need no custom screen at all.

### AI changed the economics

Retool's builder is now AI-assisted: describe the app, and it generates a starting point in Retool's format. With Facet, any AI coding tool builds the app as plain JavaScript on the Facet SDK, and the person who built it publishes it to Facet directly, with no server and no pipeline. When screens take an afternoon to build, the builder stops being the valuable part. The data underneath, and the rules that protect it, are what you keep.

### Who protects the records?

Retool's audit logs (Business plan and up) record queries run and actions taken *in Retool*. The history of the records themselves (who changed that client, when, and what it was before) is left to your database. So are the per-record rules: if two Retool apps query the same table, each one must apply them correctly.

In Facet, both live in the data layer. Every access path (the portal, the API, your apps, the AI assistant, a Retool app calling the API) goes through the same permission check and lands in the same history.

## Side by side

| Dimension | Retool and low-code builders | Facet |
| --- | --- | --- |
| Primary purpose | Visual builder for internal tools over your databases and APIs; also a hosted PostgreSQL database and workflows | A governed home for your business data, plus the apps that run on it |
| Who builds | Developers and analysts in a visual builder, on paid builder seats; an AI builder assists on every plan | Business people with the domain-builder assistant; apps through any AI coding tool or the SDK. No builder seats |
| Data ownership & portability | Your databases and APIs keep the data; Retool queries them. The apps are stored in Retool's format | Your own PostgreSQL; domain export/import, API, webhooks. Apps are plain JavaScript you keep |
| Hosting & data residency | Retool Cloud; self-hosted and air-gapped deployments on the Enterprise plan | Self-host anywhere on any plan, or managed hosting with your choice of location |
| Deploying an app | Published inside Retool | The person who built it uploads it to Facet; any earlier version can be restored |
| Permissions | Rich permissions from the Business plan; granular roles on Enterprise. Per-record rules live in each app's queries or in your database | Roles with row scopes and field tags, enforced in the data layer on every access path. Included, not a plan tier |
| Audit & history | Audit logs from the Business plan: Retool activity, not your records' history | Full change log per record by default: who, what, when; per-document rollback. Retention set by you, globally or per document |
| File storage | Through connected storage services you set up | Built-in, on S3-compatible storage, under the same grants as the records. Volume limited only by your storage |
| AI | AI app builder on all plans; pooled AI credits; your own provider key on Enterprise only | In-app assistant and builder on your own API key, any provider, on day one; embeddable assistant for your apps; MCP for coding agents. Every AI acts within the user's role |
| Logic & automation | Workflows with monthly run quotas, schedules and webhook triggers | Lua lifecycle hooks on document events inside a domain; real-time updates; webhooks to drive external automation tools |
| Reporting & analytics | Dashboards you build | No built-in charts; BI reads data through export or the API, so the role rules still apply. Direct database access is an admin privilege, outside the role model |
| Ready-made business modules | No; a template gallery | None prebuilt; the assistant models your domain with you, or our team designs it |
| Pricing model | Per builder per month, plus a per-internal-user rate; external users metered separately | Free to use and self-host (source-available, BSL 1.1), for any number of users; paid services only if you want them |
| Maturity | Mature platform, large customer base and connector library | Young product in beta, small ecosystem, built on proven foundations: PostgreSQL, Redis, an event log |

## When Retool is the better choice

- You already run PostgreSQL, MySQL, MongoDB or a set of APIs, and they work. You need admin panels over them this quarter, not a new data platform.
- You have developers who want component-level control, custom JavaScript and direct SQL.
- You need many third-party connectors (Stripe, Salesforce, internal REST APIs) from a mature library, today.
- You want workflows and scheduled automations inside the same tool.
- Your team prefers a visual builder to AI-written code.

## When Facet is the better choice

- **There is no governed data store yet.** The records live in spreadsheets, and nobody owns the schema, the backups or the row-level rules. A screen builder cannot fix that; a data layer can.
- **Many people will use the tools.** Per-user pricing grows with every colleague who opens an app. Facet has no per-user licence.
- **The record history must be provable**: who changed what, with rollback, enforced in the data layer rather than reconstructed from a tool's activity log.
- **The data must stay on your infrastructure**, and self-hosting should not require an enterprise contract.
- **The people who need the tools should be able to build and ship them**, with an AI tool and without a developer seat or a deployment pipeline.
- **More tools will follow.** Each new app lands on the same governed store, with the same sign-in, roles and audit, so the second tool costs less than the first.

## Using both

The tools can cooperate: Retool connects to APIs, and Facet exposes an HTTP API.

- **A Retool app can read and write Facet through the API.** Every call passes Facet's permission checks and lands in its history, so the record rules hold whichever tool made the request. <!-- TODO(link): REST API reference when it is published -->
- **Keep Retool for the screens your developers already maintain.** Put new governed data in Facet and point the Retool queries at its API.
- **The reverse flow works too.** Facet's webhooks notify other systems when records change.

## What Facet does not do (yet)

We would rather you hear this from us:

- **The portal is not an app builder.** It covers list, calendar, kanban and edit views. A screen shaped to one specific workflow needs a custom app, built with an AI tool or with code.
- **There is no visual builder.** Custom apps are written by an AI tool or a developer. If your team will use neither, the portal is what you get.
- **There is no cross-domain workflow engine.** Lua hooks run inside one domain. Workflows that span domains, or approval chains, run in an automation tool such as n8n, driven by Facet's webhooks or API.
- **Facet is in beta.** Retool's connector library, component set and community are far larger today.

## FAQ

**We already have PostgreSQL. Is Facet a Retool replacement?**
No, they are different layers. Retool builds screens over your existing database; Facet stores the data itself, with permissions, history, files and hosting. If your database works, your developers own it, and the per-record rules are already handled, Retool over it is a sound choice. If any of those is missing, start with the data.

**Can Facet connect to our existing databases?**
Not as a live layer: Facet is the store, not a view over someone else's. Data comes in through import or the API, and from then on it lives in Facet's PostgreSQL under its permissions and history. During a transition, a sync script or an automation tool can keep Facet fed from the old system.

**Who hosts what in each setup?**
With Retool, you host (or rent) the database, and Retool Cloud or your self-hosted Retool serves the apps. With Facet, one deployment holds the data, the rules, the files and the apps.

**Is the per-user pricing a problem?**
It depends on how many people use the tools. Retool charges per builder plus a rate per internal user. Audit logs need the Business plan, listed at $50 per builder and $15 per internal user per month, billed annually. Three builders and 60 colleagues using the apps come to about $1,050 a month, before external users. For a five-developer team it is modest; for a company where most staff open an internal tool every week, count the user line before you commit. Facet's licence costs nothing at any headcount; you pay for servers, your own AI usage and, if you want them, our services.

**Where does the AI fit?**
Both products moved here. Retool's builder generates a starting app in its own format. With Facet, the assistant designs the domain, any AI tool builds the app on the SDK, and Facet hosts it. See [Facet vs "just let the AI build it"](/compare/vs-ai-built-apps/).

## Related

- [Compare](/compare/): all comparison pages.
- [Facet vs "just let the AI build it"](/compare/vs-ai-built-apps/)
- [Facet vs Supabase and Firebase](/compare/vs-supabase-firebase/): when the alternative is a backend instead of a builder.
- [Domains, drafts and domain editors](/build/domains-drafts-editors/): how Facet organizes data.
- [Webhooks](/build/webhooks/): Facet's outbound event delivery.

## Sources

- Retool pricing: per-builder and per-internal-user pricing (Team $10/$5, Business $50/$15 annually; Free up to 5 users); audit logs and rich permissions from Business; granular roles, SSO, SCIM, self-hosted and air-gapped deployments on Enterprise; the AI builder and pooled AI credits on all plans; workflows with run quotas; "Your queries run against your own data sources. Retool doesn't store your data." — https://retool.com/pricing — checked 2026-11-13
- Retool docs: the Retool-managed self-hosted deployment is Enterprise only — https://docs.retool.com/self-hosted/retool-managed/concepts — checked 2026-11-13
- Facet's own claims come from this site: [What is Facet](/start/what-is-facet/).
