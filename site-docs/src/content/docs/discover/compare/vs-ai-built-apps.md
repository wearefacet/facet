---
type: explanation
title: 'Facet vs "just let the AI build it"'
description: AI can build your team's next tool in an afternoon. Keep doing that. Here is what that tool should stand on before real data and real colleagues depend on it.
audience: [evaluator, developer]
features: []
sidebar:
  order: 1
verified_at: bd4be053
---

**In one line:** keep the vibe coding. Just AI builds the app *and* everything under it, again for every app. AI on Facet builds only the screens, on data that stays protected and outlives the app.

## Who this page is for

You lead or work in an organization of 20 to 200 people. Someone on your team, maybe with no programming background, just showed you a working tool that an AI built in an afternoon: a quote tracker, a maintenance log, a hiring pipeline. It works, and people already want to use it.

This page helps you decide what that tool should stand on before real data and real colleagues depend on it.

## The core difference

Start with what is true: AI can build a working business tool in hours. Building the app is no longer the hard part, and Facet does not ask you to stop.

This page does not compare AI against a platform. In both columns, the AI does the building. The question is what the app stands on: nothing but its own generated code, or a governed layer underneath.

A tool that several people use every week needs more than screens:

- a login for each person, with a password reset that works;
- roles, so a trainee does not see salaries;
- a per-record check, so a client list does not leak because one link was shared;
- a history of who changed what, and a way to undo it;
- backups;
- a place for files, with the same access rules as the records;
- hosting, TLS (the padlock in the browser), updates and security fixes;
- someone who still understands all of the above after the original author moves on.

An AI-generated app rebuilds this list for itself on every project, usually in part, and nobody checks which part it skipped. Each new app is one more thing to deploy, host, patch and explain, and the person who prompted it usually cannot do any of that alone. The tenth app costs as much plumbing as the first.

### What the research says

AI-written code works, but it needs checking. A 2025 Veracode study of more than 100 language models found that, given a secure and an insecure way to write the same code, models chose the insecure one in 45% of tasks, and larger or newer models did no better. Other research found that explicit security instructions in the prompt improve the results. A business user does not know which instructions to give.

The pattern shows up at scale. In October 2026, UpGuard scanned about 300,000 domains and found 16,326 Supabase databases with tables anyone could read; more than half held indicators of personal data. The researchers' conclusion: these apps are built by AI coding agents, and the people behind them do not know how the database is configured. In one exposed database, an immigration coaching service stored client names next to plain-text passwords. In February 2026, the Supabase backend behind an AI-agent social network leaked 35,000 email addresses and 1.5 million API tokens (found by Wiz).

None of this means the AI built a bad app. It means a generated app should not be the thing that decides who can read which record. That job belongs to the layer underneath, built once, tested once, and shared by every app you make.

<!-- d2
prompt: "You describe the tool" {class: external}
build: "The AI writes the app"
choice: "What does it stand on?" {class: decision}
justAI: "Login, roles, audit, files, hosting rebuilt per app" {class: warn}
facet: "OAuth sign-in, rights subset of your role"
enforce: "Facet enforces permissions, history, files"
records: "Records outlive the app" {class: ok}

prompt -> build
build -> choice
choice -> justAI: Just AI
choice -> facet: AI on Facet
facet -> enforce
enforce -> records
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9ba49688-light.svg" alt="You describe the tool" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9ba49688-dark.svg" alt="You describe the tool" loading="lazy" />
</div>

## Side by side

| Dimension | Just AI | AI frontend + Facet |
| --- | --- | --- |
| Primary purpose | Whatever the prompt asked for | The same app, standing on governed data |
| Who builds what | You and the AI, at every layer: data, permissions, screens, hosting | The AI writes the screens; Facet already provides data, rights, history and hosting |
| Data ownership & portability | Wherever the AI put it: a generated database, a spreadsheet, files on a laptop | Your own PostgreSQL; domain export/import, API, webhooks |
| Hosting & data residency | You host it, or it sits on a free tier somewhere | Self-hosted (a small deployment runs on 2 vCPU and 2–4 GB RAM), or managed hosting with your choice of location |
| Deploying the app | A server, a pipeline, a domain, a certificate, and someone who knows how they fit together | Upload the built files to Facet. No server, no pipeline; any earlier version can be restored |
| Permissions | Whatever was generated, if anything, and rarely reviewed | Roles with row and field grants, enforced in the data layer on every access path |
| Audit & history | Only if someone asked for it, and then different in every app | Every change recorded by default: who, what, when; roll any document back |
| File storage | Ad hoc: local disk, or a cloud bucket with its own rules | Built-in, on S3-compatible storage, under the same grants as the records |
| Custom apps | It is the app | Your vibe-coded app on the SDK, signed in over OAuth; Facet hosts its files |
| AI | One builder; AI inside the app is your problem | The same builder, plus an in-app assistant, an embeddable assistant for your apps, and MCP for coding agents, all bound by the user's role |
| Logic & automation | Whatever was generated, per app | Lua scripts inside a domain; real-time updates; webhooks |
| Reporting & analytics | Only if it was built in | No built-in dashboards; BI reads data through export or the API, so the role rules still apply. Direct database access is an admin privilege, outside the role model |
| Ready-made business modules | No | None prebuilt; the in-app assistant models your domain with you, or our team designs it |
| Cost | Model tokens, then hosting, TLS, maintenance and your time, per app | Free to use and self-host (source-available, BSL 1.1); you bring your own AI key; paid services only if you want them |
| Maturity | Each app starts at day zero | Beta product on proven foundations: PostgreSQL, Redis, an event log |

## When just AI is the better choice

Use AI alone, with nothing underneath, when:

- the tool is a throwaway: a demo for Friday, an experiment to learn what you actually need;
- one person uses it, so there are no roles to model;
- nothing sensitive goes in, and losing the data costs a rebuild, not a breach;
- nobody will rely on it in six months.

The day one of these stops being true, the tool has earned a foundation.

## When AI on Facet is the better choice

- **Several people rely on the tool every week**, and the records must survive the app. A customer stays a customer, whatever tool edits the record.
- **Different people must see different records**: salaries, client lists, contract terms.
- **Someone will ask who changed what, and when**: an auditor, a client, a manager, or a regulator. If the tool holds personal data about EU clients or staff, GDPR applies to it, whoever wrote the code.
- **Files belong with the records**: contracts, photos, identity documents.
- **You want to keep building with AI** without rebuilding the plumbing each time.
- **The person who builds the tool should be able to ship it.** No server, no pipeline, no ticket to IT: the business user who prompted the app can deploy it, and roll it back.
- **You plan more than one tool.** The first app sets up accounts, roles, audit, files and hosting. Every app after that starts from what exists, so each one is faster and cheaper than the last.

## Using both: prototype with AI, ship on Facet

The two columns are not rivals; one grows into the other.

Keep prototyping with your AI tool. When a prototype earns real data, point it at Facet:

1. An admin registers the app in Facet. The app signs users in over OAuth (an open authorization standard), so it never sees or stores a password, and you never build a login screen.
2. The app receives a DPoP-bound token: a token tied to the app's own key, so a copied token fails anywhere else. Its rights are always a subset of the signed-in user's role.
3. Your AI tool builds the screens against the Facet SDK (software development kit). Facet hosts the finished files: no separate hosting, no deployment pipeline. Whoever built the app can publish it, and restore an earlier version if a new one breaks. <!-- TODO(link): custom-apps and SDK pages when the apps section ships -->
4. One call adds the embeddable assistant to the app. It inherits the signed-in user's role and acts only within it.

Coding agents can also connect to Facet through MCP (Model Context Protocol, a standard way for AI tools to call a product's functions) and work under one role you pin. Facet checks every call, whatever wrote the code. See [What is Facet](/discover/why-facet/).

Keep throwaway prototypes out of the governed store. Facet's job starts when the data becomes worth governing.

From there, grow domain by domain. A domain is one slice of the business, such as clients, equipment or hiring. The governance you set up once (accounts, roles, history, files) is the same governance every next domain uses. One governed home for your data, one facet per slice of the business.

## What Facet does not do (yet)

We would rather you hear this from us:

- **Facet is in beta.** The ecosystem, community and third-party integrations are still small.
- **Logic is scoped to one domain.** Lua scripts run inside a domain. Workflows that span domains, or approval chains, run in an automation tool such as n8n, driven by Facet's webhooks or API.
- **There is no built-in reporting.** Export the data, or connect a BI (business intelligence) tool through the API.
- **Facet is not a full application backend.** Complex custom server-side logic still needs your own services.
- **Facet governs the data, not the screens.** It does not review the code the AI wrote, so a generated interface can still be clumsy or wrong. What it guarantees is that a clumsy screen cannot read or change data the user is not allowed to touch.

## FAQ

**The AI can write login and permissions too. Why a platform?**
It can, and sometimes it does it well. But every app re-implements them, every implementation carries its own risk, and you maintain all of them forever. In Facet, the rules belong to the data, not to any one app. Delete the app, and the rules, the history and the records stay.

**What does the AI still own in this setup?**
The screens. Facet owns identity, permissions, audit, files and hosting. The AI writes against the SDK, and it cannot grant itself rights.

**Does the assistant see everything?**
No. The in-app assistant and the embeddable assistant act within the current user's permissions; coding agents connect through MCP under one role you pin. You bring your own model API key, so you also choose the provider.

**What if the generated app turns out badly?**
Throw it away. The data, the roles and the history remain. Build version two on the same foundation. That is the point: apps are disposable now, your data is not.

**Can a non-developer deploy and update the app?**
Yes, and that is safe by design. Facet serves the app's files itself, so publishing a new version needs no server and no pipeline. The app can change as often as its owner likes; the data model, the permissions and the history cannot be touched from the app. If a release turns out broken, restore the previous version. The worst case is a bad screen for a few minutes, never a data leak or a lost record.

**Who maintains it after launch?**
For the app: nobody, beyond the screens themselves. Hosting, TLS, sign-in, permissions, backups and security fixes live in Facet and are maintained once for every app on it, by you if you self-host or by us with managed hosting.

**Are we locking ourselves in?**
Less than with a generated app. Your records live in standard PostgreSQL, on your own server if you choose. You can export any domain, read everything through the API, and the source code is available to you.

**Can we start without a developer?**
Yes. The portal gives you list, calendar and kanban views plus an edit page per document, generated from templates the assistant writes for you. Daily data work needs no code. For a specific workflow screen, use an AI tool against the SDK.

**Do we have to move everything at once?**
No. Start with one domain: the records that hurt most in spreadsheets. It sets up the accounts, roles, history and hosting, and each domain after that reuses them. Value starts small and compounds.

## Related

- [Compare](/discover/compare/): all comparison pages.
- [Facet vs Supabase and Firebase](/discover/compare/vs-supabase-firebase/): the developer-backend version of this question.
- [Facet vs Airtable and Notion databases](/discover/compare/vs-airtable-notion/): the spreadsheet-stage version.
- [What is Facet](/discover/why-facet/)
- [Security & governance overview](/discover/security/)

## Sources

- Veracode, 2025 GenAI Code Security Report: models chose the insecure implementation in 45% of 80 task types across more than 100 models; larger and newer models did no better — https://www.veracode.com/press-release/ai-generated-code-poses-major-security-risks-in-nearly-half-of-all-development-tasks-veracode-research-reveals/ — checked 2026-11-13
- UpGuard, "Everything Everywhere: Systemic Data Exposure in Supabase Apps" (October 2026): 16,326 databases with readable tables across about 300,000 domains; more than half with personal-data indicators; the Moltbook leak of February 2026; the immigration-coaching example — https://www.upguard.com/blog/everything-everywhere-systemic-data-exposure-in-supabase-apps — checked 2026-11-13
- SC World, on Backslash research: explicit security instructions in prompts improve model output — https://www.scworld.com/news/llms-make-insecure-coding-choices-for-45-of-tasks-study-finds — checked 2026-11-13
- Facet's own claims come from this site: [What is Facet](/discover/why-facet/) and the [Security & governance overview](/discover/security/).
