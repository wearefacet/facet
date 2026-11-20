# WP 00 — Site conventions (read first; not a dispatch)

Every work package (WP) in this directory follows this contract. When you dispatch a WP to an agent, always include this file.

The durable rules for documentation work live in [`doc/documentation.md`](../../documentation.md) — verification, style, gates, page contract. This file holds only the WP-specific parts: write scopes, the front-matter values per page, and the dispatch prompt. When the two disagree, `doc/documentation.md` wins.

Source: [`whole-doc.md`](whole-doc.md) §4, §5, §8.

---

## Scope

This file defines:

- where pages live,
- the front-matter contract,
- the page skeleton,
- style rules,
- the validation gate,
- parallel-dispatch rules.

The content WPs do not repeat these rules. They only list their pages and sources.

## Locations

| What | Path |
|---|---|
| English pages | `site-docs/src/content/docs/<section>/<page>.md` |
| French pages | `site-docs/src/content/docs/fr/<section>/<page>.md` (only WP 15 writes these) |
| Sections | `start`, `tutorials`, `concepts`, `workspace`, `build`, `govern`, `apps`, `operate`, `reference`, `compare`, `changelog` |
| Sidebar | `site-docs/astro.config.mjs` — only WP 01 edits this file |
| Concern doc | `doc/site-docs.md` — only WP 01, 02, 03 edit this file |

## Front-matter contract

Every page carries this front-matter:

```yaml
---
title: Row scopes
description: Limit which documents a role can see or change.
audience: [admin, author]
features: [RBC-05, DOM-12]
verified_at: <short SHA>
---
```

| Key | Rule |
|---|---|
| `title` | The page title. Matches the WP page table. |
| `description` | One sentence, active voice. Max 160 characters. |
| `audience` | One or more of: `evaluator`, `user`, `author`, `admin`, `developer`, `operator`. Copy from the WP page table. |
| `features` | The feature IDs from the WP page table. Use `IAM-*` style wildcards only where the WP shows them. WP 02 expands them. |
| `verified_at` | Output of `git rev-parse --short HEAD` when you write the page. It marks the source snapshot the page was checked against. |

WP 01 extends the Starlight schema (`site-docs/src/content.config.ts`) so these keys survive the build.

## Page skeleton

How-to pages use this skeleton (whole-doc §8):

```markdown
---
<front-matter>
---

<A short lead paragraph in plain prose. No callout box, no fixed template —
write the lead this page needs.>

## When to use this
## Before you start
## Steps
## Example
## Troubleshooting
## Related
```

Rules:

- Concept pages replace `## Steps` with `## Explanation`. They drop `## Example` when no example helps.
- Every page opens with a lead paragraph in plain prose and keeps `## Related`. Do not repeat one lead formula across pages.
- Drop a section only when it truly has no content. Do not ship an empty heading.
- Tutorials use the tutorial skeleton defined in WP 05 / WP 06.
- Reference pages use a table-first skeleton; the WP 13 parts define details.

## Style rules (ASD-STE100 plain English)

The site uses the same plain wording as the repo `AGENTS.md` (whole-doc §5).

- One idea per sentence. Max ~20 words per sentence.
- Active voice. Present tense.
- Use everyday verbs: read, write, run, add, show, set, check.
- Use glossary terms with one meaning. The glossary page (WP 04) is the term source.
- No marketing words. No idioms. No humor.
- Document what exists. No "planned", "coming soon", "future".
- Code blocks are complete and runnable. No `…` elisions, no "rest of the config here".
- Define an acronym at first use.
- For all copy: write for a non-native English reader.

## Diagrams

- Use a ```mermaid fence. The site renders it as SVG (`doc/site-docs.md` → Mermaid).
- Keep diagrams narrow. Label every node. No HTML in labels.
- Check the diagram syntax. A parse failure keeps the raw code block on the page; the build does not fail.

## Links

- Internal links use site-absolute paths with a trailing slash: `/build/field-types/`.
- Link to repo docs for internals, on GitHub: `https://github.com/wearefacet/facet/blob/main/doc/...`.
- Do not mirror repo `doc/` content into the site. The site is product documentation; the repo docs are contributor and agent documentation (whole-doc §4).

## Validation gate

Run this after every change:

```sh
cd site-docs && npm run build
```

Definition of done for a page:

- [ ] `npm run build` passes.
- [ ] The page renders at its URL (check `npm run preview`, or inspect `dist/`).
- [ ] Front-matter is complete and matches the WP page table.
- [ ] Mermaid diagrams show as diagrams, not raw fences (visual check).
- [ ] No edits outside the WP write scope.

## Parallel dispatch rules

- Each WP lists a **write scope**: the only paths it may create or edit.
- Write scopes are disjoint across WPs. Stay inside yours.
- If two agents share one checkout, run `npm run build` sequentially. Concurrent builds collide in `dist/`.
- Content WPs never edit `site-docs/astro.config.mjs`. WP 01 pre-provisions all sidebar groups.

## Suggested dispatch prompt

Copy this when you dispatch any WP:

> Read `doc/plans/documentation/00-conventions.md`, then implement
> `doc/plans/documentation/<NN-name>.md` (Batch <X> only). Stay inside the
> write scope. Run the validation gate when done. Report pages added and
> gate results.
