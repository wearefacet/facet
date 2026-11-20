# Facet documentation website — plan

Based on the feature inventory pinned to `envelope@c2f1427e` (138 features, 10 areas).

---

## 1. Goals

1. **Get an SMB from zero to a working, governed app**: deploy, build a domain, give people access, ship a frontend.
2. **Make the governance promise checkable.** Auth, RBAC, audit and rollback are why people pick Facet, so explain them so a sceptical CTO or auditor can trust them.
3. **Work as well for coding agents as for humans.** Every page is also served as clean markdown and indexed in `llms.txt`, because many readers will be Claude, Cursor and similar tools building apps on Facet.
4. **Stay maintainable by a small team.** Generate the reference sections from source, write the narrative sections by hand, and check coverage in CI against the feature IDs.

## 2. Audiences

| Persona | Who | Needs | Primary sections |
|---|---|---|---|
| **Evaluator** | SMB founder/CTO, IT lead, consultant | "What is it, is it safe, is it for me?" | Overview, Concepts, Security, Compare |
| **Workspace user** | Employees using the SPA | Find, edit, filter data; use the assistant | Use the workspace |
| **Domain author** | Power user, Amplitude consultant, domain editor | Model data, actions, automations | Build domains |
| **Administrator** | Org admin | Accounts, roles, SSO, audit | Govern access |
| **App developer** (human or agent) | Builds a frontend or integration | OAuth, SDK, deploy, MCP | Build apps |
| **Operator** | Self-hoster, Amplitude ops | Deploy, configure, monitor, upgrade | Operate |

Design rule: each page states its audience at the top, and the sidebar is ordered by persona journey, not by backend module.

## 3. Information architecture

Structure follows Diátaxis (tutorials / how-to guides / concepts / reference), with the how-to guides grouped by persona.

```
/                         Landing (what Facet is, 3 entry doors: Evaluate · Build · Operate)
/start/                   Start here
/tutorials/               Learn by doing (5 end-to-end walkthroughs)
/concepts/                How Facet thinks (explanation)
/workspace/               Use the workspace (end users)
/build/                   Build domains (authors)
/govern/                  Govern access (admins)
/apps/                    Build apps (developers & agents)
/operate/                 Operate (self-hosting)
/reference/               Reference (mostly generated)
/compare/                 Facet vs the world
/changelog/               Release notes
```

### 3.1 Start here — `/start/`

| Page | Content | Features |
|---|---|---|
| What is Facet | "Apps are disposable, your data isn't." Substrate vs app; what you get for free (auth, rights, audit, hosting). | — |
| Is Facet right for you? | Good fits, bad fits, honest limits (e.g. at-most-once events, OpenAPI subset). | AUT-01, PLT-12 |
| Architecture at a glance | One diagram: SPA / apps / agents → HTTP + MCP → auth contexts → enforcers → mutation log → projections → events. | RBC-10, AUD-01, AUT-01 |
| Security & governance overview | The evaluator/auditor page: identity, RBAC, non-disclosing reads, audit, secrets, data location. | IAM-*, RBC-*, AUD-*, DOC-09 |
| Glossary | Domain, doctype, document, sidecar, mutation, projection, scope, tag, grant, elected role, draft… | — |

### 3.2 Tutorials — `/tutorials/`

Each tutorial is linear, tested on every release, and ends with a working result.

| # | Tutorial | Outcome | Features |
|---|---|---|---|
| T1 | **Run Facet in 15 minutes** | Containers up, first admin seeded, logged in, welcome tour seen | PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24 |
| T2 | **Build your first domain** | A small "Inventory" domain: draft, doctypes, fields, refs, publish, list + kanban view | DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03 |
| T3 | **Build it with the assistant** | Same domain authored through the domain-builder chat | AI-02, AI-06, FE-10 |
| T4 | **Give your team access** | Invite users, create a "Sales" role with a row scope and a hidden field tag | IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11 |
| T5 | **Ship an AI-built app on Facet** | Scaffold, connect with the SDK, OAuth login, deploy, roll back | APP-01, APP-02, APP-09, APP-06, APP-10, FE-12 |
| T6 | **Connect an AI agent over MCP** | Claude/another MCP client reads and writes under a delegated role | AI-05, AI-04, APP-04, APP-05 |

### 3.3 Concepts — `/concepts/`

Explanation pages. Short, opinionated, diagram-led.

| Page | Features |
|---|---|
| Domains and isolation | DOM-01, DOM-14 |
| Documents, doctypes and projections | DOC-01, DOM-03, DOM-23 |
| The mutation log (and why it isn't domain event sourcing) | AUD-01, AUD-05, AUD-08, DOC-08 |
| Draft → publish | DOM-02 |
| Auth contexts: one model for every channel | RBC-10, IAM-14 |
| How authorization is enforced (read, write, metadata, non-disclosure) | RBC-03, RBC-06, RBC-09 |
| Roles, levels and the authority guard | RBC-01, RBC-07 |
| Apps: grants ∩ roles | RBC-08 |
| Events and delivery guarantees (at-most-once, reconcile crons) | AUT-01, AUT-05 |
| Schema evolution and lazy migration | DOM-17 |
| Cross-domain replication (one hop, grant-gated) | DOM-25, DOM-14 |
| AI under the caller's rights | AI-01, AI-04 |

### 3.4 Use the workspace — `/workspace/`

| Page | Features |
|---|---|
| Sign in, MFA, reset your password | FE-01, IAM-01, IAM-03, IAM-04, IAM-05, IAM-10 |
| The dashboard | FE-02 |
| Lists, filters and saved views (table, kanban, calendar) | FE-03, DOC-02, DOM-21 |
| Viewing and editing a document | FE-04, FE-05, DOC-13 |
| Comments and attachments | DOM-06, FE-04 |
| History and undo (rollback) | FE-06, AUD-02, AUD-04 |
| Search and the command palette | FE-07, DOC-06 |
| Keyboard shortcuts | FE-08 |
| Notifications | FE-09, AUT-06 |
| Import and export data | FE-18, DOC-11 |
| Using the assistant | FE-22, AI-01 |
| Your settings, sessions and API keys | FE-17, PLT-17, IAM-09, IAM-11 |

### 3.5 Build domains — `/build/`

| Page | Features |
|---|---|
| Domains, drafts and domain editors | DOM-01, DOM-02, DOM-13, FE-13 |
| Designing doctypes | DOM-03 |
| Field types (guide; full table in reference) | DOM-04, DOC-13 |
| References, links and backlinks | DOC-05, DOC-10 |
| Identifiers and unique constraints | DOM-10, DOM-11 |
| Parent/child composition | DOM-05, DOC-07 |
| Sidecars (comments, attachments) | DOM-06 |
| Files and artifacts in fields | PLT-04 |
| Secret and write-only fields | DOC-09, PLT-03 |
| Named actions | DOM-07 |
| Lifecycle scripts and guards | DOM-08 |
| Computed fields | DOM-09 |
| Display names and search text (Jinja2) | DOM-23 |
| Document view templates (show/form pages) | DOM-22, FE-04 |
| Collection views | DOM-21 |
| Named scopes | DOM-12 |
| Checking a domain before publish | DOM-16 |
| The schematic view | DOM-20 |
| Evolving a schema (migrations, reproject) | DOM-17, DOM-18 |
| Sharing data across domains (grants, replication) | DOM-14, DOM-25 |
| Automate: event hooks and scheduled hooks | AUT-02, AUT-08 |
| Automate: outbound webhooks | AUT-03 |
| Automate: notifications and @mentions | AUT-06 |
| Moving domains between instances (bundles) | DOM-15 |
| Authoring with the domain-builder assistant | AI-02, AI-06 |
| Local development: the dev domain watcher | DOM-19 |

### 3.6 Govern access — `/govern/`

| Page | Features |
|---|---|
| Accounts: invite, suspend, delete, restore | IAM-06, IAM-07, FE-11 |
| Roles and permission lines | RBC-01, RBC-07 |
| Assigning roles and role election | RBC-02 |
| Row scopes (`$self`, `$mine`, named scopes) | RBC-05, DOM-12 |
| Field visibility with tags | RBC-04, AUD-03 |
| Enforcing MFA | IAM-03, PLT-02 |
| Single sign-on with OIDC | IAM-08, FE-14 |
| Sessions, refresh tokens and lockouts | IAM-01, IAM-02, IAM-10, IAM-11 |
| Machine access: API keys | IAM-09 |
| Auditing activity | AUD-02, AUD-08, IAM-13, FE-16 |
| Rolling back changes | AUD-04 |
| Retention: what is kept and for how long | AUD-05, AUD-06, AUD-07 |
| Controlling app reach (grants) | RBC-08, FE-12 |
| Governing the assistant (availability, auto-execute, custom instructions) | AI-08, AI-07 |

### 3.7 Build apps — `/apps/`

Written for humans **and** agents: every page has a copy-paste code block and a "for agents" summary box.

| Page | Features |
|---|---|
| How apps work on Facet | APP-01, RBC-08 |
| Quickstart with the dev CLI | APP-09 |
| Registering an app (public vs confidential, headless) | APP-01, FE-12 |
| User login: OAuth 2.1 + PKCE | APP-02, APP-05, FE-21 |
| DPoP token binding | APP-03 |
| CORS and allowed origins | APP-08 |
| Backend apps: service accounts and API keys | APP-07 |
| Hosting your frontend: deploy, releases, rollback, custom domains | APP-06, APP-09 |
| The TypeScript SDK (`@facetapp/sdk`) | APP-10 |
| Working with the REST API (CRUD, filters, aggregates, ETags) | DOC-01, DOC-02, DOC-03, DOC-04, PLT-13 |
| Search | DOC-06 |
| Realtime with WebSockets | DOC-12 |
| Uploading and serving files | PLT-04 |
| Bulk import/export via API | DOC-11 |
| Gating your UI with the permission manifest | RBC-11, IAM-14 |
| Embedding the assistant (`@facetapp/chat`) | APP-11, AI-03 |
| MCP: connecting agents | AI-05, APP-04 |
| Agent tools | AI-04, AI-06 |
| Building apps with AI coding agents (prompting guide, `llms.txt`, skills) | AI-06 |

### 3.8 Operate — `/operate/`

| Page | Features |
|---|---|
| System requirements and topology | PLT-10, PLT-16 |
| Deploying with containers (+ Caddy TLS) | PLT-16, APP-06 |
| Configuration files | PLT-01 |
| System settings | PLT-02, FE-14 |
| Bootstrap and CLI tasks | IAM-12, DOM-24 |
| Email delivery | AUT-07 |
| File storage: filesystem or S3 | PLT-04 |
| Configuring the assistant (LLM endpoint, model, budgets) | AI-08, AI-07, AI-09 |
| Database migrations | PLT-11 |
| Managed indexes | PLT-05 |
| Background jobs and cron | AUT-04, AUT-05 |
| Health checks, metrics, tracing, logs | PLT-06, PLT-07, PLT-08, PLT-09, AUT-01 |
| Currencies and money | PLT-14, FE-15 |
| Retention tuning | AUD-05, AUD-06, AUD-07 |
| Upgrades and graceful shutdown | PLT-15, PLT-11 |
| **Backup and restore** | ⚠ not in inventory, see §6 |
| Localization | FE-20 |

### 3.9 Reference — `/reference/` (generated wherever possible)

| Reference | Source of truth | Generation |
|---|---|---|
| REST API | `doc/api/openapi.json` | Render with Scalar/Redoc; CI drift job already exists (PLT-12) |
| `facet` CLI (18 commands) | `src/cli/commands.cr` | Script over the registry |
| `@facetapp/cli` | `packages/cli/` | `--help` dump |
| Field types (22) | `src/doctype/field_types/` | Type, validation, normalization, filter operators |
| Filter grammar operators | `filter_compiler.cr` | Table per type |
| Permission line syntax | `src/rbac/` | Hand-written + examples |
| Doctype definition schema | doctype validator | JSON Schema → page |
| DVT template schema | `view_template_validator.cr` | JSON Schema → page |
| Lua API (`document.*`, `notification.*`, `util.*`, `date.*`, `math.*`) | `src/lua/` | Doc comments → page |
| Jinja2 template context | `src/templating/` | Hand-written |
| Agent tools (23 + `read_skill`) | `src/agent_tools/` | Tool schemas → page |
| System settings keys | SystemSettings spec registry | Generated table |
| Config file keys | `src/config.cr` loaders | Generated table |
| Account settings keys | settings key registry | Generated table |
| Webhook payloads and signatures | `src/webhook/` | Hand-written + examples |
| Error responses (422 shapes, non-disclosing 404) | `src/http/gates.cr` | Hand-written |
| Health/metrics names | `healthcheck.cr`, `metrics.cr` | Generated |
| Feature index (AREA-NN → pages) | this inventory | Generated |

### 3.10 Compare — `/compare/`

Honest "Facet vs the world" pages, including when **not** to choose Facet:
Facet vs Airtable/Notion databases · vs Retool/low-code builders · vs Odoo/ERP · vs Supabase/Firebase · vs "just let the AI build it on Vercel".

## 4. Technical stack

- **Astro + Starlight**: built-in i18n routing, Pagefind search, MDX, sidebar config, fast static output. You already know Astro.
- **Languages**: `en` is the source of truth, `fr` second. Starlight marks pages as untranslated and falls back to `en`. Translate in this order: Start here, tutorials, workspace, then the rest. Reference stays in English.
- **Agent-readable output**:
  - `/llms.txt` (index) and `/llms-full.txt` (concatenated), generated at build time.
  - Every page also available as `/<path>.md` (raw markdown), linked from a "Copy as markdown" button.
  - Code blocks always complete and runnable; no "…" elisions.
- **Diagrams**: Mermaid in markdown, so agents can read them too.
- **API reference**: Scalar or Redoc embedded from `openapi.json`.
- **Hosting**: a static build. Dogfood it as a Facet-hosted app (APP-06) as a showcase, or put it on any static host.

### Relationship with the repo `doc/` folder

`envelope/doc/` stays the **contributor and coding-agent** documentation (internals, module design). The website is **product** documentation. Do not mirror one into the other:

- Website pages may link to `doc/` files on GitHub for "how it works inside".
- Reference pages are generated from source, not copied from `doc/`.
- The site repo can live in `envelope/website/` so one PR can change code and docs together.

## 5. Maintenance model

- **Front-matter per page**: `audience`, `features: [DOM-03, DOM-04]`, `verified_at: <commit>`.
- **CI coverage check**: every inventory ID must appear in at least one page's `features`, or in an explicit `internal.yml` exclusion list (e.g. DOC-08). The build fails on an uncovered ID, so a new feature cannot ship undocumented.
- **Tested tutorials**: T1–T6 are scripted against a fresh container in CI (later also by a Passband-style agent run).
- **Staleness flag**: pages whose `verified_at` commit is more than N releases old get a banner in the build report.
- **Style**: the same ASD-STE100-style plain wording as `AGENTS.md`. One idea per sentence, active voice, consistent terms from the glossary.

## 6. Gaps found in the inventory

These need a decision before the docs can be complete:

1. **Backup and restore**: not in the inventory, but evaluators and operators will ask first. Document the read-replica + periodic backup + S3 approach, or name it as the operator's responsibility.
2. **Upgrade path / versioning policy**: how releases, migrations and breaking changes are communicated.
3. **OpenAPI covers only a subset** (PLT-12): either widen it before beta or label the generated reference as partial and fill the gaps by hand.
4. **Licensing page**: BSL 1.1 + Additional Use Grant in plain words ("what you can and cannot do").
5. **Data location and compliance**: hosting region options, GDPR posture, ISO 27001 mapping (auditors will look for this).
6. **Limits and quotas**: aggregate `count` cap of 1000, import staging caps, rate limits, history limits. Collect them on one page.
7. **Internal-only features** (DOC-08, parts of DOM-19): confirm they stay out of user docs.
8. **Support and services**: the free tier is "docs + tutorials, no SLA". Link the Administration and Design & Development offers from the docs footer.

## 7. Phasing

### Phase 0 — release day (minimum credible docs)
- Landing, What is Facet, Is it right for you, Architecture, Security overview, Glossary
- T1 Run Facet, T2 First domain, T4 Team access
- Concepts: domains, mutation log, authorization enforcement
- Reference: REST (OpenAPI), `facet` CLI, field types, filter grammar
- `llms.txt` + raw `.md` pages

### Phase 1 — first month
- T5 Ship an app, T6 MCP agent, T3 Assistant
- Full **Build apps** and **Govern access** sections
- Operate: deploy, config, system settings, storage, mail, health/metrics, backups
- Reference: agent tools, Lua API, permission syntax, system settings
- French for Start here + tutorials

### Phase 2 — first quarter
- Full **Build domains** section (actions, scripts, templates, replication, bundles)
- **Workspace** user guide
- Compare pages
- CI coverage check enforced, tutorials auto-tested
- French for workspace and govern sections

## 8. Page template

```markdown
---
title: Row scopes
description: Limit which documents a role can see or change.
audience: [admin, author]
features: [RBC-05, DOM-12]
verified_at: c2f1427e
---

> **In short (for humans and agents):** two or three sentences that answer the page.

## When to use this
## Before you start
## Steps / Explanation
## Example
## Troubleshooting
## Related
```
