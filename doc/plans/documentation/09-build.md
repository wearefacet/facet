# WP 09 — Build domains section (`/build/`)

Phase 2 (whole-doc §7) · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/build/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.5. Audience: domain authors (power user, consultant, domain editor). How-to pages: WP 00 skeleton with `## Steps`.

Split into two batches with disjoint page sets. Dispatch one batch per agent.

## Batch A — modeling (12 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `build/domains-drafts-editors.md` | Domains, drafts and domain editors | `audience: [author]`, `features: [DOM-01, DOM-02, DOM-13, FE-13]` | `doc/backend/draft-domains.md`, `doc/backend/domain-editors.md` |
| `build/designing-doctypes.md` | Designing doctypes | `audience: [author]`, `features: [DOM-03]` | `doc/backend/doctype-system.md` — rewrites the existing `build/doctypes.md`; keep the filename `designing-doctypes.md` and delete the old file |
| `build/field-types.md` | Field types (guide) | `audience: [author]`, `features: [DOM-04, DOC-13]` | `doc/backend/doctype-system.md` — guide with the common types; link to `/reference/field-types/` for the full table |
| `build/references-links-backlinks.md` | References, links and backlinks | `audience: [author]`, `features: [DOC-05, DOC-10]` | `doc/backend/links.md`, `doc/frontend/backlinks.md` |
| `build/identifiers-unique-constraints.md` | Identifiers and unique constraints | `audience: [author]`, `features: [DOM-10, DOM-11]` | `doc/backend/doctype-system.md` |
| `build/parent-child-composition.md` | Parent/child composition | `audience: [author]`, `features: [DOM-05, DOC-07]` | `doc/backend/doctype-system.md`, `doc/backend/document.md` |
| `build/sidecars.md` | Sidecars (comments, attachments) | `audience: [author]`, `features: [DOM-06]` | `doc/backend/sidecar.md` |
| `build/files-artifacts.md` | Files and artifacts in fields | `audience: [author]`, `features: [PLT-04]` | `doc/backend/artifact.md` |
| `build/secret-write-only-fields.md` | Secret and write-only fields | `audience: [author, admin]`, `features: [DOC-09, PLT-03]` | `doc/backend/secrets.md` |
| `build/named-actions.md` | Named actions | `audience: [author]`, `features: [DOM-07]` | `doc/backend/doctype-system.md` (actions) |
| `build/lifecycle-scripts-guards.md` | Lifecycle scripts and guards | `audience: [author]`, `features: [DOM-08]` | `doc/backend/lua-engine.md`, `doc/backend/doctype-system.md` |
| `build/computed-fields.md` | Computed fields | `audience: [author]`, `features: [DOM-09]` | `doc/backend/doctype-system.md`, `doc/backend/templating.md` |

## Batch B — views, evolution, automation (14 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `build/display-names-search-text.md` | Display names and search text (Jinja2) | `audience: [author]`, `features: [DOM-23]` | `doc/backend/templating.md` |
| `build/view-templates.md` | Document view templates (show/form pages) | `audience: [author]`, `features: [DOM-22, FE-04]` | `doc/backend/templating.md`, `doc/frontend/document-view.md` |
| `build/collection-views.md` | Collection views | `audience: [author]`, `features: [DOM-21]` | `doc/backend/collection-view.md` |
| `build/named-scopes.md` | Named scopes | `audience: [author, admin]`, `features: [DOM-12]` | `doc/backend/rbac.md` (scopes) |
| `build/checking-before-publish.md` | Checking a domain before publish | `audience: [author]`, `features: [DOM-16]` | `doc/backend/draft-domains.md` |
| `build/schematic-view.md` | The schematic view | `audience: [author]`, `features: [DOM-20]` | `doc/frontend/schematic.md` |
| `build/evolving-schema.md` | Evolving a schema (migrations, reproject) | `audience: [author]`, `features: [DOM-17, DOM-18]` | `doc/backend/schema-migration.md` |
| `build/sharing-across-domains.md` | Sharing data across domains (grants, replication) | `audience: [author, admin]`, `features: [DOM-14, DOM-25]` | `doc/backend/domain-grants.md`, `doc/backend/replication.md` |
| `build/event-hooks.md` | Automate: event hooks and scheduled hooks | `audience: [author]`, `features: [AUT-02, AUT-08]` | `doc/backend/hooks.md`, `doc/backend/lua-engine.md` |
| `build/webhooks.md` | Automate: outbound webhooks | `audience: [author, developer]`, `features: [AUT-03]` | `doc/backend/webhook.md` |
| `build/notifications-mentions.md` | Automate: notifications and @mentions | `audience: [author, user]`, `features: [AUT-06]` | `doc/backend/notifications.md` |
| `build/bundles.md` | Moving domains between instances (bundles) | `audience: [author, operator]`, `features: [DOM-15]` | `doc/backend/portable-domains.md` |
| `build/domain-builder-assistant.md` | Authoring with the domain-builder assistant | `audience: [author]`, `features: [AI-02, AI-06]` | `doc/backend/assistant.md`, `doc/backend/domain-builder-skills.md` |
| `build/dev-domain-watcher.md` | Local development: the dev domain watcher | `audience: [author, developer]`, `features: [DOM-19]` | `doc/backend/dev-domain-watcher.md`. Note: whole-doc §6 item 7 marks parts of DOM-19 as internal-only — document the user-facing part only; check D7 in `99-decisions.md` before writing. |

`build/index.md` (from WP 01): the batch that runs last finishes the index with all pages as links.

## Writing notes

- Every page ends `## Related` with: the matching reference page, the matching concept page, and one next action.
- Lua examples (lifecycle scripts) are complete scripts, not fragments (WP 00).
- Jinja2 examples (display names, templates) are complete templates with sample input and output.
- The existing `build/doctypes.md` is good raw material for `designing-doctypes.md`; read it first.

## Definition of done (per batch)

- [ ] Batch pages written, front-matter per WP 00.
- [ ] Every config/code example validated against the current validator (publish check on a dev instance where possible).
- [ ] `cd site-docs && npm run build` passes.
