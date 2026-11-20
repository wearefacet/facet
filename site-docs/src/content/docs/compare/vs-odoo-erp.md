---
title: Facet vs Odoo and ERP suites
description: Odoo ships finished business processes that you adapt to. Facet starts from your own processes, with governance built in. Many companies are best served by both.
audience: [evaluator]
features: []
sidebar:
  order: 4
verified_at: bd4be053
---

**In one line:** an ERP runs the processes every company shares: accounting, invoicing, payroll. Facet runs the ones that make your company yours. Many companies need both.

## Who this page is for

Your company outgrew spreadsheets, and someone proposed an ERP (enterprise resource planning) suite such as Odoo. You wonder whether one integrated system should hold everything, including the processes that make your company different. This page draws the line, and shows where each side of it belongs.

## The core difference

An ERP gives you finished processes, and you adapt your business to them. Odoo's catalogue is broad and well integrated: accounting, invoicing, inventory, manufacturing, CRM, HR, payroll, website, point of sale. The Community edition is open source and free to self-host; the Enterprise edition adds apps, features and services under a per-user subscription.

Facet starts from the other end: your process, not a template of one. You model your own domains (the document types, fields, roles and views your operation actually uses) with the AI assistant or with our team. Governance comes built in: permissions down to rows and fields, a full change history, rollback, and file storage under the same rules.

### Where the cost hides: customization

The two approaches meet where your business stops looking like the template.

In Odoo, the Custom plan unlocks Studio (no-code customization), the external API, multi-company and custom modules; the Standard plan runs no custom code. Every deviation you build becomes code you carry through each version upgrade. Odoo partners estimate upgrade costs in the thousands, driven by customizations rather than by data volume.

In Facet, your model is data, not code. Domains are versioned and published from drafts, and there is no upgrade treadmill for the model itself. Changing a field or adding a document type is something the assistant does with you in the product, not a module a partner writes and maintains.

### Where the cost grows: headcount

Odoo is priced per user per month, with promotional first-year pricing that renews higher and prices that vary by country. Studio and the API sit on the Custom plan, and that higher rate applies to every user, not just the ones who need customization. Facet has no per-user licence: you pay for servers, your own AI usage, and our services if you want them.

## Side by side

| Dimension | Odoo and ERP suites | Facet |
| --- | --- | --- |
| Primary purpose | Integrated business suite: accounting, inventory, CRM, HR, manufacturing, website, POS | Governed home for your own operational data, plus the apps that run on it |
| Who builds | The vendor ships the processes; staff and partners configure; Studio (Custom plan) and Python modules customize | You model your domains with the AI assistant, or our team does it with you |
| Data ownership & portability | Odoo Online (hosted, with database backup download); Community self-host; Custom plan: on-premise or Odoo.sh | Your own PostgreSQL; domain export/import, API, webhooks |
| Hosting & data residency | Odoo Online, Odoo.sh, or self-hosted (Community, or Custom plan) | Self-host anywhere, or managed hosting in France |
| Permissions | Per-app access rights and record rules, configured per model | Roles with row scopes and field tags, enforced in the data layer on every access path |
| Audit & history | Change tracking on the fields each module chooses to track; a complete audit trail needs an add-on module | Full change log on every record by default: who, what, when; per-document rollback. Retention set by you, globally or per document |
| File storage | Attachments on records; the Documents app on paid plans | Built-in, on S3-compatible storage, under the same grants as the records. Volume limited only by your storage |
| Changing the model | Studio on the Custom plan, or custom Python modules carried through each upgrade | Versioned domains, edited as drafts with the assistant and published; no code to migrate |
| Custom apps on top | Website builder and portal; anything else is a custom module | Any app your AI tool builds, on the SDK, signed in over OAuth. Facet hosts it; the person who built it can publish it and roll it back |
| AI | Agentic AI on the Custom plan | In-app assistant and builder on your own API key, any provider; embeddable assistant for your apps; MCP for coding agents. Every AI acts within the user's role |
| Logic & automation | Automation rules; custom modules | Lua lifecycle hooks on document events inside a domain; real-time updates; webhooks to drive external automation tools |
| Reporting & analytics | Reports inside each app, accounting in particular | No built-in charts; your data sits in standard PostgreSQL, reachable from any BI tool through export or the API |
| Ready-made business modules | Yes: the point of the product | None prebuilt yet; you model what is specific to you. A marketplace of one-click domains, with apps and roles, is planned |
| Pricing model | Per user per month; One App Free, Standard, Custom; promotional first year; priced by country | Free to use and self-host (source-available, BSL 1.1), for any number of users; paid services only if you want them |
| Maturity | Mature suite, large partner network | Young product in beta, small ecosystem, built on proven foundations: PostgreSQL, Redis, an event log |

## When Odoo is the better choice

- You need accounting, invoicing or payroll with local tax rules. This is the ERP's home ground; Facet has none of it.
- Your processes are standard (quotes to orders to invoices, stock in and stock out) and an off-the-shelf flow fits without surgery.
- You want one integrated suite, one vendor to call, and a partner network for implementation (Odoo routes mid-size implementations through partners).
- Your team wants ready-made mobile apps, e-commerce and point of sale, not a platform to shape.
- The Community edition plus a partner covers a standard setup on a small budget.

## When Facet is the better choice

- **Your core process is unusual**: a maintenance operation, a catalogue with its own rules, a field workflow no module matches. Fitting it into an ERP means a custom module you carry through every upgrade.
- **The ERP already handles finance, but the operational data around it does not fit.** Quality records, equipment, client files and planning live in spreadsheets, with no permissions and no history.
- **Different people must see different records and fields**, and an auditor may ask who changed what.
- **You want the bespoke part to be data** (versioned, publishable, portable) rather than code on an upgrade treadmill.
- **Your team wants screens shaped to its work.** It builds them with an AI tool and publishes them on Facet, with no partner project and no module to maintain.
- **Headcount is growing**, and the tool should not cost more with every hire.

## Using both

This is the most common setup for companies that already run an ERP:

- **Keep the ERP for finance** and the standard processes it does well.
- **Put the specific operational domains in Facet**: the catalogue, the field operations, the quality records, the client files.
- **Connect the two** through Odoo's external API, Facet's API, webhooks, or a scheduled export. An Odoo export can seed a Facet domain; a Facet webhook can notify the ERP when a record changes.
- **Give each fact one home.** Avoid keeping the same record in both systems; let one reference the other.

Move one domain at a time. Each lands on the same accounts, roles, history and files as the last, so each move costs less than the one before.

## What Facet does not do (yet)

We would rather you hear this from us:

- **There are no prebuilt business modules yet**: no CRM, accounting, inventory or HR. Today, your domains are modelled for you, which takes design time up front. The assistant shortens it; our team can take it on. A marketplace is planned: ready-made domains (B2B and B2C CRM, HR and more) that install in one click, with their apps and roles, and that you then adapt like any domain of your own.
- **There is no cross-domain workflow engine.** Lua hooks run inside one domain. Workflows that span domains, or approval chains, run in an automation tool such as n8n, driven by Facet's webhooks or API.
- **There is no built-in reporting.** Odoo's per-app reports exist today; with Facet, you export or connect a BI tool through the API.
- **Facet is in beta.** Odoo's maturity, partner network and localized accounting are real advantages that Facet does not match.

## FAQ

**Can Facet do accounting?**
Not today. Facet has no accounting, invoicing, payroll or tax localization, so for those, use an ERP. Facet is for the operational domains around it. Ready-made domains are on the roadmap (see below), but if you need accounting now, an ERP is the right answer.

**Will Facet become an ERP?**
In its own way. The plan is a marketplace of ready-made domains (CRM for B2B or B2C, HR and more), each installed in one click with its apps and roles. The difference from a classic ERP is what happens next: an installed domain is data, so you adapt it with the assistant like anything you built yourself, with no custom module to carry through upgrades. Until a module you need ships, judge Facet on what it does today.

**We already run Odoo. Where does Facet fit?**
Around it. Companies typically keep Odoo for finance and standard flows, and move the specific operational data (the parts that would otherwise become custom Odoo modules) into Facet domains, connected through the API or webhooks.

**Should we customize Odoo or model the process in Facet?**
Count the customization's lifetime cost, not just its build cost. A custom Odoo module must be re-validated at each version upgrade, and upgrade cost grows with customization. It also requires the Custom plan for every user. A Facet domain is data: it survives version changes, you can export it, and the assistant can change it with you.

**Which should we adopt first?**
If accounting and standard processes are the pain, the ERP comes first. If the pain is specific operational data that needs permissions and history, Facet can come first, and the ERP can join later through the API.

**Does Facet import Odoo data?**
Yes, through Odoo's export or external API. The import maps onto your Facet domain model; there is no ready-made Odoo connector today, so plan the mapping, or let our team run it.

## Related

- [Compare](/compare/): all comparison pages.
- [Facet vs "just let the AI build it"](/compare/vs-ai-built-apps/)
- [Facet vs Airtable and Notion databases](/compare/vs-airtable-notion/): the lighter end of the same question.
- [Domains, drafts and domain editors](/build/domains-drafts-editors/): how Facet models your processes.
- [Sharing across domains](/build/sharing-across-domains/): controlled field replication between domains.

## Sources

- Odoo editions: two versions, Community (open source) and Enterprise (licensed), with the feature-by-feature comparison — https://www.odoo.com/page/editions — checked 2026-11-13
- Odoo pricing: One App Free, Standard and Custom plans; US prices ($16.90 first year, then $21.10 per user per month on Standard, yearly billing); the Custom plan carries Studio, the external API, custom modules, multi-company, Odoo.sh and on-premise hosting; first-year discount terms; implementations for larger companies routed through partners — https://www.odoo.com/pricing — checked 2026-11-13
- Odoo upgrade-cost figures are partner estimates, not vendor figures: Ventor, on upgrade cost being driven by customizations — https://ventor.tech/services/odoo-upgrade/ — and Ecosire, on version-migration cost ranges — https://ecosire.com/blog/odoo-migration-v17-to-v18-guide — checked 2026-11-13
- Activepieces, on Studio and the external API requiring the Custom plan; the plan comparison itself is on https://www.odoo.com/pricing — https://www.activepieces.com/blog/odoo-pricing-2026-plans-hosting-and-implementation — checked 2026-11-13
- Facet's own claims come from this site: [Domains, drafts and domain editors](/build/domains-drafts-editors/).
