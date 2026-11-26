---
type: explanation
title: Facet vs Supabase and Firebase
description: Supabase and Firebase give developers building blocks. Facet ships the governed result (permissions, audit, a portal and app hosting) so your team builds the business, not the plumbing.
audience: [evaluator, developer]
features: []
sidebar:
  order: 5
verified_at: bd4be053
---

**In one line:** Supabase and Firebase hand your developers the blocks. Facet ships the finished, governed building, so your team spends its time on the business, not on the plumbing.

## Who this page is for

You are choosing the foundation for an internal tool or a small product. Your developers, or the AI tools standing in for them, mention Supabase or Firebase. You want to know what each platform gives you out of the box, and what you will still have to design, build and maintain yourself.

## The core difference

Supabase and Firebase are developer backends: a database, authentication, file storage, server functions, real-time sync. Both are mature, with large communities, and both are excellent at what they do. Facet is not trying to be a better backend. It takes a different position: most of what an internal business tool needs (roles, per-record permissions, a change history, an admin interface, app hosting) ships as governed defaults, so nobody designs them from scratch for each project.

A backend gives you the freedom to build anything, and the obligation to build everything. The difference shows in the work each setup leaves to you:

- **Permissions.** In Supabase you write row-level security (RLS) policies in SQL; in Firebase you write security rules in a dedicated rules language. The safe setup is not always the default path: Supabase enables RLS by default for tables created in its dashboard editor, but a table created in the SQL editor, by a migration tool, or through the API (the route AI coding agents take) does not; you enable RLS yourself. Since May 30, 2026, new projects also keep their public schema out of the Data API by default: without an explicit grant, the API cannot see a table, however it was created. Supabase has responded with warnings, alerts and a security advisor, and describes security as a shared responsibility. An October 2026 scan by UpGuard still found 16,326 Supabase databases with tables anyone could read. In Facet, roles, row scopes and field tags are enforced in the data layer on every access path; there is no "off" state to forget.
- **Audit.** A backend has no record history until someone builds one. Facet records every change (who, what, when) by default, with rollback per document.
- **The admin interface.** Supabase and Firebase give you consoles for developers. The people who work with the data every day need views and edit forms; in Facet, the portal provides them, generated from templates the assistant writes.
- **App hosting and deployment.** In a Supabase setup, you host and deploy the frontend yourself. Facet hosts your apps' files and signs their users in over OAuth. Whoever built an app can publish it, and roll back to an earlier version, with no pipeline.

Firebase adds two concerns of its own. It runs on Google Cloud only, with no version for your own servers. And Blaze billing is per operation (reads, writes, function invocations), with budget alerts that notify you but do not stop usage. A 2024 internet-wide scan found 916 misconfigured Firebase sites exposing about 19.9 million plain-text passwords. The lesson matches Supabase's: the platform gives you the tools, and the safe configuration is your job.

To be fair to both: Supabase is open source, free to self-host, and built on standard PostgreSQL you can export. And when you need arbitrary server logic, a public consumer app, or Firebase's mobile SDKs with offline sync, these platforms are the right tool. Facet is not a full application backend.

## Side by side

| Dimension | Supabase and Firebase | Facet |
| --- | --- | --- |
| Primary purpose | Developer backends: database, auth, storage, functions, real-time | Governed home for one organization's business data, plus the apps that run on it |
| Who builds | Developers, at every layer | Business people with the assistant; developers through the SDK and MCP |
| Time to a governed tool | Weeks of backend work: schema, policies, audit, admin screens, hosting | The governance exists on day one; you model the domain and build the screens |
| Data ownership & portability | Supabase: standard PostgreSQL, self-hostable, exportable. Firebase: proprietary data model and APIs, no self-hosting | Your own PostgreSQL; domain export/import, API, webhooks |
| Hosting & data residency | Supabase cloud or self-hosted (free, via Docker or CLI); Firebase on Google Cloud only | Self-host anywhere, or managed hosting with your choice of location |
| Permissions | You design and maintain them: RLS policies in SQL (Supabase), security rules (Firebase). Tables created outside the dashboard editor lack RLS by default; since May 2026, new projects also keep tables out of the Data API until you grant access | Roles with row scopes and field tags, enforced in the data layer on every access path. On by default, for every record |
| Audit & history | Auth audit logs (Supabase, 24 hours to 28 days by plan); record history is yours to build | Full change log per record by default: who, what, when; per-document rollback. Retention set by you, globally or per document |
| Admin interface | Developer consoles | A portal for daily users: list, calendar and kanban views, plus an edit page per document |
| File storage | Supabase Storage with its own access policies; Firebase Cloud Storage with its own rules | Built-in, on S3-compatible storage, under the same grants as the records. Volume limited only by your storage |
| Custom apps on top | You host and deploy the frontend; Firebase Hosting for Firebase apps | Apps on the SDK, signed in over OAuth with DPoP-bound tokens. Facet hosts them; the person who built an app can publish it and roll it back |
| AI | Developer-side AI tooling; AI inside your app for your users is yours to wire (Supabase AI features, Firebase AI Logic) | In-app assistant and builder on your own API key, any provider; embeddable assistant for your apps in one call; MCP for coding agents under a role you pin. Every AI acts within the user's role |
| Logic & automation | Edge Functions (Supabase), Cloud Functions (Firebase): arbitrary server code | Lua lifecycle hooks on document events inside a domain; real-time updates; webhooks to drive external automation tools |
| Reporting & analytics | None built in (SQL and the consoles) | No built-in charts; BI reads data through export or the API, so the role rules still apply. Direct database access is an admin privilege, outside the role model |
| Ready-made business modules | None | None prebuilt yet; the assistant models your domain with you, or our team designs it. A marketplace of one-click domains is planned |
| Pricing model | Supabase: free tier, Pro from $25/month plus usage. Firebase: free Spark plan, pay-as-you-go Blaze billed per operation. Plus the developer time to build the governance | Free to use and self-host (source-available, BSL 1.1), for any number of users; paid services only if you want them |
| Maturity | Large communities, mature tooling, years in the market | Young product in beta, small ecosystem, built on proven foundations: PostgreSQL, Redis, an event log |

## When Supabase or Firebase is the better choice

These platforms shine when four things are true at once: you have a development team that knows exactly what it wants to build, the data flows are heavy, you need deep control over how data is stored (for performance or architectural reasons), and you have the time to implement and maintain everything yourself. In particular:

- **Your developers want full control**: SQL, functions, queues, custom indexes, anything.
- **The product serves the public.** Consumer sign-ups, mobile apps at scale, push notifications, offline sync: Firebase in particular is built for this, and Facet is not. Facet accounts come from invites and SSO, with no public self-service sign-up.
- **You need arbitrary server-side logic today.** Facet's logic runs as Lua hooks inside one domain; anything beyond that belongs in an automation tool such as n8n, or in your own services.
- **You want the ecosystem**: the libraries, guides and hiring pool built around these platforms over a decade.
- **Supabase specifically:** you want an open-source backend on standard PostgreSQL, self-hosted or in the cloud, and you will own its security configuration.

## When Facet is the better choice

- **The tool serves your own staff**, and the records (clients, machines, cases, contracts) must outlive whichever app edits them.
- **There is no backend developer**, and the alternative is an AI-generated app deciding its own permissions. In Facet, the app receives a token whose rights are a subset of the signed-in user's role, and the data layer enforces the rules whatever the app's code does.
- **You have developers, but their time is better spent on the business** than on rebuilding auth, permissions, audit, admin screens and hosting for each tool.
- **Someone will ask who changed what.** The history is there from the first record, with rollback, not bolted on after the first incident.
- **The team needs a working interface on day one.** The portal's views and edit pages come with the product, not from a developer's sprint.
- **The people who build an app should be able to ship it**, without a hosting account or a deployment pipeline.
- **You want the data, and the option to run the whole stack, on your own infrastructure**, with no per-user licence and no per-operation bill.
- **You want one governed home that grows domain by domain**, where each new tool reuses the accounts, roles, history and hosting of the last.

## Using both

The split is clean, because the jobs differ:

- **Keep Supabase or Firebase for the consumer or mobile product**, if you have one.
- **Put the internal, governed records in Facet**: customers, operations, and the files that carry permissions.
- **Connect them** through the API, webhooks or exports. A Facet webhook can trigger your Supabase functions.
- **Promote prototypes.** If a Supabase prototype has earned real internal data, move the data layer to Facet and point the frontend at the SDK. Sign-in, permissions, history and hosting come with the move.

## What Facet does not do (yet)

We would rather you hear this from us:

- **Facet is not a full application backend.** Arbitrary server-side logic still needs your own services; Facet's logic is Lua inside one domain.
- **There is no cross-domain workflow engine.** Cross-domain workflows and approval chains run in an automation tool such as n8n, driven by Facet's webhooks or API.
- **Facet serves one organization.** There is no public self-service sign-up, so a B2C product is a poor fit.
- **Facet is in beta.** The Supabase and Firebase ecosystems, documentation and communities are far larger today.

## FAQ

**We have developers. Why would we choose Facet?**
For the same reason you use a framework instead of raw sockets: good defaults. Facet ships identity, permissions, audit, files and app hosting, enforced in the data layer, so your developers spend their time on what is specific to your business. If your team knows exactly what it needs, handles heavy data flows, needs low-level control over storage, and has the time to build and maintain the rest, Supabase is a great fit.

**Is Facet a Supabase replacement?**
No. Supabase is a backend for applications you develop; Facet is a governed home for business data, with apps on top. They coexist well: the consumer product on Supabase, the internal records in Facet, connected through the API.

**Is my data locked in?**
No. Facet's data lives in your PostgreSQL, exportable through the API and domain exports, and you can run the whole stack yourself. On Firebase, the data model and APIs are proprietary, and moving away means rewriting the data layer.

**Firebase is free to start. Is Facet?**
Facet is free to use and self-host, at any scale; you pay for your servers. Firebase's free tier is generous, but the Blaze plan bills per operation, and an inefficient query becomes a recurring bill with no hard spending cap.

**Which platform is more secure?**
That is the wrong question: all three give you the tools. The real question is what happens when nobody configures them correctly, and the scans above show the answer at scale. Facet's bet is that permissions and audit should be the floor, not a configuration task.

## Related

- [Compare](/discover/compare/): all comparison pages.
- [Facet vs "just let the AI build it"](/discover/compare/vs-ai-built-apps/): where the Supabase misconfiguration story meets AI-built apps.
- [Security & governance overview](/discover/security/)
- [Roles and permission lines](/admin/people/roles-and-permissions/)
- [Is Facet right for you?](/discover/is-it-right-for-you/): including the workloads that need a lower level of control.

## Sources

- Supabase pricing: Free, Pro from $25/month plus usage, Team $599/month; self-hosting free via Docker or CLI; auth audit log windows by plan; SOC 2 and ISO 27001 from Team — https://supabase.com/pricing — checked 2026-11-13
- UpGuard, "Everything Everywhere: Systemic Data Exposure in Supabase Apps" (October 2026): 16,326 databases with readable tables across about 300,000 domains; RLS by default only for tables created in the dashboard editor, not through the API — https://www.upguard.com/blog/everything-everywhere-systemic-data-exposure-in-supabase-apps — checked 2026-11-13
- Supabase security retro 2025: RLS defaults, warnings and the Security Advisor; security described as a shared responsibility — https://supabase.com/blog/supabase-security-2025-retro — checked 2026-11-13
- Supabase, "Securing your API" (docs): RLS on by default for dashboard-created tables, enable it yourself for the SQL editor and other tools; a table stays out of the Data API until a role is granted privileges on it; the platform default is moving to opt-in exposure for new objects — https://supabase.com/docs/guides/api/securing-your-api — checked 2026-11-20
- Open Source Alternatives, on Supabase as open source and self-hostable on standard PostgreSQL — https://www.opensourcealternatives.to/blog/supabase-vs-firebase — checked 2026-11-13 (the self-hosting claim is also on https://supabase.com/pricing)
- Firebase pricing: Spark (no-cost) and Blaze (pay as you go, billed per operation: document reads, writes, function invocations, egress) — https://firebase.google.com/pricing — checked 2026-11-13
- Appwrite (a Firebase competitor, so treat as context), on Firebase's lack of self-hosting and the cost of migrating away — https://appwrite.io/blog/post/firebase-vs-open-source-tradeoffs — checked 2026-11-13
- Verdent, on Firebase budget alerts not stopping usage — https://www.verdent.ai/guides/devtools/firebase-pricing — checked 2026-11-13
- Malwarebytes, on the 2024 scan: 916 misconfigured Firebase sites and 19.9 million plaintext passwords — https://www.malwarebytes.com/pt/blog/personal/2024/03/19-million-plaintext-passwords-exposed-by-incorrectly-configured-firebase-instances — checked 2026-11-13
- Facet's own claims come from this site: [Is Facet right for you?](/discover/is-it-right-for-you/) and the [Security & governance overview](/discover/security/).
