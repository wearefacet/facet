---
type: explanation
title: Facet vs Airtable and Notion databases
description: Airtable and Notion make it easy to start a database. Facet makes it safe to depend on one. Compare them before your business records outgrow the workspace.
audience: [evaluator]
features: []
sidebar:
  order: 2
verified_at: bd4be053
---

**In one line:** Airtable and Notion are built to start fast and collaborate; Facet is built for records your business must protect, prove and keep, whatever tool edits them next.

## Who this page is for

You run operations in a company of 20 to 200 people. Your team likes the spreadsheet feel, someone proposed Airtable or a Notion database, and the data is starting to matter: clients, machines, contracts, money. This page shows where those tools hold up, and where the answer changes once the data has to be governed.

## The core difference

Airtable and Notion minimize the time from "I have an idea" to "I have a base". That is their strength, and for many jobs it is the right one. Facet is built for what comes next: proof. Who can see each record, who changed what, and whether the record survives the tool it was born in.

The difference shows in the features you reach for once data becomes sensitive. On Airtable, the audit log is on the Enterprise Scale plan only, with 180 days of retention. On Notion, the audit log is on the Enterprise plan. Both vendors also keep data residency (where your data physically sits) for their top tier: Airtable on Enterprise Scale, Notion on Enterprise.

These are reasonable choices for a SaaS business. In practice, they mean a 50-person company usually runs a mid-tier plan and answers audit questions with exports and memory. In Facet, the audit trail, field-level permissions and choice of hosting location are not a plan. They are how the product works, for every user, at no licence cost.

Notion is also, first, a documents and wiki tool. Facet does not compete there: keep Notion for knowledge. The comparison below is about the *database* side of both tools, used for operational records.

One more fact worth knowing: in August 2026, Bending Spoons agreed to acquire Airtable; the deal had not closed when this page was last checked. Whoever owns a SaaS product decides its pricing, plans and roadmap. Facet is software you run; those decisions stay yours.

## Side by side

| Dimension | Airtable and Notion | Facet |
| --- | --- | --- |
| Primary purpose | Airtable: app-like workspaces on bases; Notion: docs and wikis with databases | Governed home for business data, plus the apps that run on it |
| Who builds | You, the business user; AI features assist | A business person with the AI assistant; custom apps through AI tools or the SDK |
| Data ownership & portability | The vendor's cloud. Airtable exports CSV one table at a time; Notion exports the workspace (HTML, Markdown, CSV) | Your own PostgreSQL; domain export/import, API, webhooks |
| Hosting & data residency | Cloud only. Choice of region on the top tier: Airtable Enterprise Scale (US by default); Notion Enterprise (US by default; EU, Tokyo, Seoul) | Self-host anywhere, or managed hosting with your choice of location. Available from day one, not a plan upgrade |
| Scale | Airtable caps records per base by plan: 1,000 on Free, 50,000 on Team, 125,000 on Business | No plan-based record caps; capacity is your server's |
| Permissions | Roles at workspace, base or page level. Notion's row-level rules (Business and up) key on an assigned person. Airtable field-level restriction needs workarounds below the top tier | Roles with row scopes and field tags, enforced in the data layer on every access path: portal, API, apps and AI |
| Audit & history | Airtable record history: 2 weeks on Free, 1 year on Team and Business; audit log on Enterprise Scale only, 180 days. Notion page history: 7 / 30 / 90 days by plan; audit log on Enterprise | Full change log by default: who changed what, and when; roll any document back to a prior state. You set the retention, globally or per document: keep everything forever, or compact old history into snapshots |
| File storage | Attachments with per-plan caps (Airtable: 1–100 GB per base; Notion: 5 MB per file on Free, 5 GB on paid plans) | Built-in, on S3-compatible storage, under the same grants as the records. Total volume is limited only by your storage; uploads default to 50 MB per file, configurable |
| Custom apps on top | Airtable interfaces and extensions; Notion API and automations | Any app your AI tool builds, on the SDK, signed in over OAuth. Facet hosts it: the person who built it can publish it and roll it back, with no server to run |
| AI | Airtable Omni with monthly AI credits per seat; Notion AI bundled on Business and Enterprise, trial below | In-app assistant and builder on your own API key (any provider); embeddable assistant for your apps; MCP for coding agents. Every AI acts within the user's role |
| Logic & automation | Automations with monthly run caps (Airtable); automation rules (Notion) | Lua lifecycle hooks on document events inside a domain; real-time updates; webhooks to drive external automation tools |
| Reporting & analytics | Airtable extensions (charts, pivots, Gantt); Notion charts and dashboards | No built-in charts; BI reads data through export or the API, so the role rules still apply. Direct database access is an admin privilege, outside the role model |
| Ready-made business modules | Large template libraries | None prebuilt; the assistant models your domain with you, or our team designs it |
| Pricing model | Per seat: every editor and member is billed, readers are free; AI credits on top | Free to use and self-host (source-available, BSL 1.1), for any number of users; paid services only if you want them |
| Maturity | Airtable since 2012, large ecosystem; Notion very widely adopted | Young product in beta, small ecosystem, built on proven foundations: PostgreSQL, Redis, an event log |

## When Airtable or Notion is the better choice

- The team is small (five to ten people), nobody has ever asked for an audit trail, and speed matters more than structure.
- The work is mostly documents (briefs, wikis, meeting notes) and records are secondary. Notion is the better wiki; Facet has no equivalent.
- You need charts, pivots or Gantt views today, without connecting a separate BI tool.
- You depend on the integration ecosystem (Slack, Drive, Jira and hundreds more) that these platforms built over a decade.
- The data is not sensitive, and the per-seat bill stays small because most collaborators only read.

## When Facet is the better choice

- **An auditor, a client or a regulator asks "who changed this record, and when?"**, and on your current plan the honest answer is "we don't know".
- **Different people must see different rows or fields**, such as salaries or client lists, without splitting the data into copies.
- **The data must stay in the EU or on your own servers**, and "buy the top tier" is not an acceptable answer.
- **The records must outlive the tool.** A customer, a machine or a contract stays a record, whatever app edits it next year.
- **Nearly everyone in the company works with the data**, and paying for every editor means the bill grows with each hire.
- **Files must follow the rules of their records**: contracts, photos and identity documents get the same access rules as the record they belong to.
- **You want tailored screens, not just views.** Your team builds the exact tool it needs with AI, and Facet hosts it, governs it and keeps every version.

## Using both

They work well side by side:

- **Keep Notion as the knowledge base.** Move the governed records (clients, assets, cases) to Facet. A workspace export or a CSV gets the data out; Facet's import and API bring it in.
- **Keep an Airtable base that works for a small team.** When a base starts holding sensitive records, move that one: Airtable exports each table as CSV, and Facet's API supports ongoing syncs.
- **Link rather than duplicate.** Keep one system of record for governed data, and let the workspace tools point to it instead of copying it.

You do not switch in one move. Facet grows domain by domain (a client file here, an equipment log there) and each domain lands on the same sign-in, roles, history and files. The setup you do once serves every domain after.

## What Facet does not do (yet)

We would rather you hear this from us:

- **Facet is opinionated.** Domains, document types, an event log, role-based grants. That structure is what makes governance possible, but check that it fits how you work before you commit.
- **There is no template library yet.** You start from your own model, built with the assistant or with our team.
- **There is no built-in reporting.** Airtable's extensions and Notion's charts exist today; with Facet, you export or connect a BI tool through the API.
- **Facet is in beta.** Its ecosystem, community and integrations are small next to these two platforms.

## FAQ

**Is Facet a self-hosted Airtable?**
No. Airtable is a collaborative workspace that keeps your data in its cloud, with governance features gated by plan. Facet is a data platform you run yourself, or that we run for you, in the location you choose. Permissions, history and hosting come with the software at no licence cost, and the data lives in your PostgreSQL.

**Can I import my Airtable or Notion data?**
Yes. Airtable exports tables as CSV; Notion exports a workspace as HTML, Markdown or CSV. Facet imports documents and domains, and its API supports ongoing syncs. Plan the mapping first: field types and links need decisions, not just a file copy. The assistant can help you design the target model, or our team can run the migration.

**Do I lose the spreadsheet feel?**
You lose free-form cells; you keep the views. Facet's portal gives list, calendar and kanban views plus an edit page per document, and the assistant sets them up for you. Formulas and cell-level improvisation are not the model; structure is. When a team needs a screen shaped exactly to its work, it can build one with an AI tool and publish it on Facet.

**What does Facet cost as the team grows?**
There is no per-seat licence. The software is free to use and self-host, for any number of users. You pay for your servers, the AI usage on your own key, and, if you want them, our managed hosting or design services.

**We already pay for Notion. Why add Facet?**
Because they do different jobs. Notion holds what your team writes; Facet holds what your business must account for. See [Facet vs "just let the AI build it"](/discover/compare/vs-ai-built-apps/) for what happens when tools multiply.

## Related

- [Compare](/discover/compare/): all comparison pages.
- [Facet vs "just let the AI build it"](/discover/compare/vs-ai-built-apps/)
- [Security & governance overview](/discover/security/)
- [Row scopes](/admin/people/row-scopes/): how per-record permissions work in Facet.
- [Auditing activity](/admin/history/audit/): the change history in practice.

## Sources

- Airtable pricing: per-seat billing (editors billed, readers free), plan prices, AI credits, CSV export per table — https://airtable.com/pricing — checked 2026-11-13
- Airtable plans overview: record caps (1,000 / 50,000 / 125,000 per base), revision and snapshot history (2 weeks on Free, 1 year on Team and Business), attachment caps per base, Omni AI credits per plan — https://support.airtable.com/docs/airtable-plans — checked 2026-11-13
- Airtable audit logs: Enterprise Scale plan only, 180-day retention — https://support.airtable.com/docs/accessing-enterprise-audit-logs-in-airtable — checked 2026-11-13
- Airtable data residency: Enterprise Scale only; US default; Europe and Australia; migration with downtime; no downgrade — https://support.airtable.com/docs/european-data-residency-at-airtable — checked 2026-11-13
- Airtable community thread: field-level restriction below the top tier needs workarounds — https://community.airtable.com/other-questions-13/how-to-restrict-a-new-collaborator-s-access-to-historical-records-and-sensitive-fields-47259 — checked 2026-11-13
- Notion pricing: per-member plans; granular database permissions (rows where the collaborator is assigned) from Business; audit log on Enterprise; page history 7 / 30 / 90 days; AI bundling; workspace export — https://www.notion.com/pricing — checked 2026-11-13
- Notion data residency: Enterprise only; US default; EU, Tokyo and Seoul regions — https://www.notion.com/help/data-residency — checked 2026-11-13
- Simone Smerilli, on how Notion's database access rules key on a Person or Created-by property — https://simonesmerilli.com/writing/notion-database-access-rules — checked 2026-11-13
- Reworked, "Bending Spoons Acquires Airtable" (August 4, 2026; deal pending close when checked) — https://www.reworked.co/digital-workplace/bending-spoons-acquires-airtable-for-1285b/ — checked 2026-11-13
- Facet's own claims come from this site: the [Security & governance overview](/discover/security/).
