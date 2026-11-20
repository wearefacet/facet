# WP 04 — Start here section (`/start/`)

Phase 0 · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/start/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.1. Audience: evaluators (founder/CTO, IT lead, consultant) — whole-doc §2.

## Pages

| File | Title | Front-matter | Content notes (from whole-doc) |
|---|---|---|---|
| `start/what-is-facet.md` | What is Facet | `audience: [evaluator]`, `features: []` | "Apps are disposable, your data isn't." Substrate vs app. What you get for free: auth, rights, audit, hosting. |
| `start/is-facet-right-for-you.md` | Is Facet right for you? | `audience: [evaluator]`, `features: [AUT-01, PLT-12]` | Good fits, bad fits, honest limits. Named limits from the repo: at-most-once event delivery (`doc/backend/workflow.md` → Event delivery), OpenAPI covers only a subset (`doc/backend/openapi.md`). |
| `start/architecture.md` | Architecture at a glance | `audience: [evaluator, developer, operator]`, `features: [RBC-10, AUD-01, AUT-01]` | One mermaid diagram: SPA / apps / agents → HTTP + MCP → auth contexts → enforcers → mutation log → projections → events. Short walk-through of each hop. |
| `start/security-governance.md` | Security & governance overview | `audience: [evaluator]`, `features: [IAM-*, RBC-*, AUD-*, DOC-09]` | The evaluator/auditor page: identity, RBAC, non-disclosing reads, audit, secrets, data location. Wildcards expand at coverage time (WP 02). |
| `start/glossary.md` | Glossary | `audience: [evaluator, user, author, admin, developer, operator]`, `features: []` | One short definition per term, alphabet order. Terms (whole-doc): domain, doctype, document, sidecar, mutation, projection, scope, tag, grant, elected role, draft. Add terms the sources use: auth context, permission line, backlink, view template, webhook. Link each term to the page that explains it best. |

Also finish `start/index.md` (WP 01 created the overview): one paragraph + the page list above, now as real links.

## Sources

Read before writing (map concerns with `doc/project-structure.md`):

| Source | Use for |
|---|---|
| `AGENTS.md` (repo root) → "What is Facet?" | Positioning, substrate vs app, feature map for `what-is-facet` |
| `doc/project-structure.md` | Architecture overview, directory map for `architecture` |
| `doc/backend/workflow.md` | Cross-cutting truths: event delivery at-most-once, UTC storage, retention |
| `doc/backend/rbac.md` | Auth contexts, enforcement, non-disclosing reads |
| `doc/backend/iam.md` | Identity, sessions, MFA, API keys |
| `doc/backend/audit.md` | Audit log, rollback, retention |
| `doc/backend/mutation.md` | The mutation log model |
| `doc/backend/event.md` | Event bus, delivery guarantees |
| `doc/backend/http-layer.md` | Error shapes, non-disclosing 404 |
| `doc/backend/openapi.md` | What the OpenAPI file covers (PLT-12) |
| `doc/backend/secrets.md` | Secret and write-only fields (DOC-09) |
| `doc/backend/app-system.md` | What an app is; grants |

Rule: the site explains the product. Link to repo docs on GitHub for internals; do not copy them (WP 00 → Links).

## Definition of done

- [ ] Five pages + finished `start/index.md`, front-matter per WP 00.
- [ ] `cd site-docs && npm run build` passes.
- [ ] Architecture page renders one mermaid diagram correctly.
- [ ] `security-governance.md` states its feature coverage with wildcards or full lists.
- [ ] Glossary terms match the words used across the site (pick one spelling per term).
