# WP 07 — Concepts section (`/concepts/`)

Phase 0 (Batch A) · Phase 1 (Batch B) · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/concepts/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.3. "Explanation pages. Short, opinionated, diagram-led."

## Format

Use the WP 00 skeleton with `## Explanation` instead of `## Steps` (concept pages). Every page leads with one mermaid diagram or one table. Target 400–800 words. These are opinion pages: state what Facet does and why, and name the trade-off honestly (for example, at-most-once delivery).

## Pages

### Batch A (Phase 0 — whole-doc §7)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `concepts/domains-and-isolation.md` | Domains and isolation | `audience: [evaluator, author]`, `features: [DOM-01, DOM-14]` | `doc/backend/doctype-system.md`, `doc/backend/domain-grants.md` |
| `concepts/mutation-log.md` | The mutation log (and why it isn't domain event sourcing) | `audience: [evaluator, developer]`, `features: [AUD-01, AUD-05, AUD-08, DOC-08]` | `doc/backend/mutation.md`, `doc/backend/audit.md` |
| `concepts/authorization-enforcement.md` | How authorization is enforced (read, write, metadata, non-disclosure) | `audience: [evaluator, developer]`, `features: [RBC-03, RBC-06, RBC-09]` | `doc/backend/rbac.md`, `doc/backend/http-layer.md` |

### Batch B

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `concepts/documents-doctypes-projections.md` | Documents, doctypes and projections | `audience: [author, developer]`, `features: [DOC-01, DOM-03, DOM-23]` | `doc/backend/document.md`, `doc/backend/doctype-system.md` |
| `concepts/draft-publish.md` | Draft → publish | `audience: [author]`, `features: [DOM-02]` | `doc/backend/draft-domains.md` |
| `concepts/auth-contexts.md` | Auth contexts: one model for every channel | `audience: [developer, admin]`, `features: [RBC-10, IAM-14]` | `doc/backend/rbac.md`, `doc/backend/oauth.md` |
| `concepts/roles-levels-authority.md` | Roles, levels and the authority guard | `audience: [admin, author]`, `features: [RBC-01, RBC-07]` | `doc/backend/rbac.md` |
| `concepts/apps-grants-roles.md` | Apps: grants ∩ roles | `audience: [developer, admin]`, `features: [RBC-08]` | `doc/backend/app-system.md` |
| `concepts/events-delivery.md` | Events and delivery guarantees (at-most-once, reconcile crons) | `audience: [developer, operator]`, `features: [AUT-01, AUT-05]` | `doc/backend/event.md`, `doc/backend/cron.md` |
| `concepts/schema-evolution.md` | Schema evolution and lazy migration | `audience: [author, developer]`, `features: [DOM-17]` | `doc/backend/schema-migration.md` |
| `concepts/cross-domain-replication.md` | Cross-domain replication (one hop, grant-gated) | `audience: [author, admin]`, `features: [DOM-25, DOM-14]` | `doc/backend/replication.md`, `doc/backend/domain-grants.md` |
| `concepts/ai-under-callers-rights.md` | AI under the caller's rights | `audience: [admin, developer]`, `features: [AI-01, AI-04]` | `doc/backend/assistant.md`, `doc/backend/agent-tools.md` |

`concepts/index.md` (from WP 01): finish with the full page list as links, one line per page.

## Definition of done

- [ ] Batch: all pages written, front-matter per WP 00, each led by a diagram or table.
- [ ] Each page names at least one honest trade-off or limit where one exists.
- [ ] `cd site-docs && npm run build` passes; every mermaid diagram renders.
- [ ] `## Related` links to the matching how-to pages (`/build/`, `/govern/`, `/apps/`) and to repo docs on GitHub.
