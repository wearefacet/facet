# WP 15 — French translations

Phase 1 (batch A) · Phase 2 (batch B) · Depends on: the matching English WPs · Write scope: `site-docs/src/content/docs/fr/` only.

Source: [`whole-doc.md`](whole-doc.md) §4. Rules in `doc/site-docs.md` → i18n:

- A page is linked to its translation when both files share the same filename under `fr/`.
- A missing translation still serves the `/fr/...` route with the English content and an untranslated notice — the site works while batches land.
- Reference stays in English (whole-doc §4).
- Sidebar group labels stay English in both locales.
- Translate in this order (whole-doc §4): Start here, tutorials, workspace, then the rest.

## Batches

### Batch A — Phase 1 (after WP 04 and WP 05)

- `fr/index.mdx` (rework per WP 01's landing update)
- `fr/start/` — all five pages from WP 04, plus `fr/start/index.md`
- `fr/tutorials/` — T1, T2, T4 from WP 05, plus `fr/tutorials/index.md`

### Batch B — Phase 2 (after WP 08 and WP 10)

- `fr/workspace/` — all twelve pages from WP 08, plus `fr/workspace/index.md`
- `fr/govern/` — all fourteen pages from WP 10, plus `fr/govern/index.md`
- `fr/concepts/`, `fr/compare/`, `fr/changelog/` — optional follow-on, same rules

## Translation rules

- Translate meaning, not structure. Keep code blocks, commands, config keys, and feature IDs (`DOM-03`) untranslated.
- Keep front-matter keys English; translate `title` and `description` values only.
- Keep the same mermaid diagrams; translate node labels when short.
- Use consistent French terms; glossary translations go in `fr/start/glossary.md` with the English term in parentheses.
- ASD-STE100 spirit applies to French too: one idea per sentence, active voice, plain words.

## Definition of done (per batch)

- [ ] Every translated file shares the filename with its English source.
- [ ] `cd site-docs && npm run build` passes; `/fr/` routes render with no untranslated banner for the batch pages.
- [ ] Code blocks and feature IDs untouched.
