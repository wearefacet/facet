# WP 01 — Site scaffold: IA realignment, sidebar, landing, changelog

Phase 0 · Depends on: nothing · Write scope: `site-docs/astro.config.mjs`, `site-docs/src/content.config.ts`, `site-docs/src/content/docs/` (moves, `index.mdx`, section `index.md` files, link fixes), `doc/site-docs.md`, `site-docs/README.md` (only if paths change there).

Source: [`whole-doc.md`](whole-doc.md) §3, §4.

The site scaffold exists, but it diverges from the planned IA. This WP aligns the scaffold with the IA and prepares the contract (WP 00) so content WPs can run in parallel.

## Current state

- Sidebar has three groups: `start`, `domains`, `deploy`.
- Content: `index.mdx`, `start/install.md`, `domains/doctypes.md`, `deploy/production.md`, plus `fr/index.mdx`, `fr/start/install.md`.
- `site-docs/src/content.config.ts` uses `docsSchema()` with no custom keys.

## Deliverables

### 1. Realign directories to the IA

The whole-doc IA (§3) names sections `build` and `operate`. The scaffold uses `domains` and `deploy`.

- Rename: `src/content/docs/domains/` → `src/content/docs/build/`; `src/content/docs/deploy/` → `src/content/docs/operate/` (use `git mv`).
- Update every internal link to the old paths. Known: `start/install.md` links to `/deploy/production/` and `/domains/doctypes/`; the same two links exist in `fr/start/install.md`. Grep for `(/domains/|/deploy/)` across `site-docs/src/` to catch the rest.
- Decision note (recorded in `99-decisions.md` D10): rename now, while the site is not public. No legacy URLs exist.

### 2. Sidebar: all groups, persona-journey order

Replace the sidebar in `site-docs/astro.config.mjs` with all groups, in this order (whole-doc §3, §2 design rule — persona journey, not backend modules):

```js
sidebar: [
  { label: 'Getting started', items: [{ autogenerate: { directory: 'start' } }] },
  { label: 'Tutorials', items: [{ autogenerate: { directory: 'tutorials' } }] },
  { label: 'Concepts', items: [{ autogenerate: { directory: 'concepts' } }] },
  { label: 'Use the workspace', items: [{ autogenerate: { directory: 'workspace' } }] },
  { label: 'Build domains', items: [{ autogenerate: { directory: 'build' } }] },
  { label: 'Govern access', items: [{ autogenerate: { directory: 'govern' } }] },
  { label: 'Build apps', items: [{ autogenerate: { directory: 'apps' } }] },
  { label: 'Operate', items: [{ autogenerate: { directory: 'operate' } }] },
  { label: 'Reference', items: [{ autogenerate: { directory: 'reference' } }] },
  { label: 'Compare', items: [{ autogenerate: { directory: 'compare' } }] },
  { label: 'Changelog', items: [{ autogenerate: { directory: 'changelog' } }] },
],
```

Keep the Starlight v0.39+ shape (`items: [{ autogenerate: ... }]`) — see `doc/site-docs.md` → Quirks. Group labels stay English in both locales (`doc/site-docs.md` → i18n).

### 3. Front-matter schema extension

Extend the docs schema in `site-docs/src/content.config.ts` so the WP 00 keys survive the build:

```ts
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro:content';

schema: docsSchema({
  extend: z.object({
    audience: z.array(z.string()).default([]),
    features: z.array(z.string()).default([]),
    verified_at: z.string().optional(),
  }),
}),
```

All three keys are optional, so existing pages still build.

### 4. Landing page: three doors

Rework `src/content/docs/index.mdx` (splash template, sidebar hidden — keep that): what Facet is in two or three sentences, then three doors (whole-doc §3):

- **Evaluate** → `/start/` · **Build** → `/tutorials/` · **Operate** → `/operate/`. Point the doors at section roots — these URLs are stable even while section content grows.
- Same for `fr/index.mdx`: update its door links to the same section roots. Leave its text as is (WP 15 owns French copy).

### 5. Section overview pages

Create one `index.md` per section directory, so every autogenerate group has content: `tutorials/index.md`, `concepts/index.md`, `workspace/index.md`, `build/index.md`, `govern/index.md`, `apps/index.md`, `operate/index.md`, `reference/index.md`, `compare/index.md`, `changelog/index.md`.

Each overview page:

- Front-matter per WP 00 (`features: []`, `audience: [...]` for that persona — copy from whole-doc §2 table: workspace → `user`; build → `author`; govern → `admin`; apps → `developer`; operate → `operator`; tutorials → `author`; concepts/compare/reference → `evaluator`).
- One paragraph: what the section covers, present tense.
- A list of the pages the section plan will add, as plain text (not links), so readers see the scope. This list comes from the WP page tables in this directory.
- Keep it short. The section WPs own the final copy.

Also create `start/index.md` (the `start/` directory exists with only `install.md`).

### 6. Changelog first page

`changelog/index.md` — "Releases": how Facet versions and ships releases, and the latest release notes. Sources: `doc/ops/container-images.md`, `doc/packages/release.md`, `git tag` output. If no release tags exist yet, document the versioning scheme only and note that release notes start with the first release (present tense: "Release notes start with the first release"). Avoid future-talk elsewhere.

### 7. Backfill the three existing content pages

Add WP 00 front-matter to `start/install.md`, `build/doctypes.md`, `operate/production.md` (audience, features — derive from content; `verified_at` = current HEAD). Their full rewrite belongs to WP 04, WP 09, WP 12.

### 8. Update the concern doc

`doc/site-docs.md`: update the Structure table (new directories), and record the IA + front-matter contract (one short section pointing to WP 00 rules as they now stand in the site). Per repo rules, the doc reflects the codebase as it is.

## Definition of done

- [ ] Build passes: `cd site-docs && npm run build`.
- [ ] All 11 sidebar groups render; each has content.
- [ ] `/start/`, `/build/doctypes/`, `/operate/production/` resolve; no link to `/domains/` or `/deploy/` remains (grep `dist/` or source).
- [ ] Custom front-matter keys survive (check a page's rendered props or the checker from WP 02 once it exists).
- [ ] `doc/site-docs.md` matches reality.
