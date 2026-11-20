# WP 03 — Agent-readable output: raw `.md` per page, "Copy as markdown"

Phase 0 · Depends on: nothing · Write scope: `site-docs/scripts/emit-md.mjs`, `site-docs/package.json` (build line), `site-docs/src/scripts/copy-as-markdown.ts`, `site-docs/astro.config.mjs` (script injection + one component override, if used), `doc/site-docs.md`.

Source: [`whole-doc.md`](whole-doc.md) §1 goal 3, §4.

## Goal

Many readers are coding agents (whole-doc §1 goal 3). The `starlight-llms-txt` plugin already emits `/llms.txt`, `/llms-small.txt`, `/llms-full.txt` at build. Missing: every page also served as raw markdown at `/<path>.md`, with a "Copy as markdown" button on the page.

## Deliverables

### 1. Emit raw markdown: `site-docs/scripts/emit-md.mjs`

A postbuild step copies each content file into `dist/`, mirroring the URL space:

- `src/content/docs/build/field-types.md` → `dist/build/field-types.md`
- `src/content/docs/start/index.md` → `dist/start.md` (section roots get a flat `.md` next to their directory)
- `src/content/docs/fr/<path>` → `dist/fr/<path>.md`

Rules:

- Keep the front-matter in the emitted file. `audience`, `features`, `verified_at` are useful to agents.
- Do not rewrite content. Keep mermaid fences as fences.
- Wire it: `"build": "astro build && node scripts/emit-md.mjs"` in `site-docs/package.json`.

### 2. "Copy as markdown" button

On every page, a small button near the title copies the page's raw markdown (it fetches the `.md` URL from deliverable 1 and copies the body; on failure, it copies the URL).

Implementation route (pick the robust one):

- **Preferred:** a Starlight component override (`PageTitle`) that renders the button plus a small inline script. See Astro/Starlight docs — Starlight supports `components: { PageTitle: './src/components/PageTitle.astro' }` inside the `starlight()` config.
- **Fallback:** a client script injected the same way as `src/scripts/mermaid.ts` (whole config pattern in `doc/site-docs.md` → Mermaid), which inserts the button after `#content h1`.

Button behaviour:

- Label: "Copy as markdown".
- URL mapping: current path `/build/field-types/` → `./field-types.md`; section root `/start/` → `./start.md` (the emit step guarantees both files exist).
- No layout shift; hide the button when the fetch 404s.

### 3. Verify and document the LLM files

- Confirm `dist/llms.txt`, `dist/llms-small.txt`, `dist/llms-full.txt` exist after build (plugin: `starlight-llms-txt`; needs `site` in `astro.config.mjs` — set to a placeholder, see `doc/site-docs.md` → LLM-friendly output).
- `llms-full.txt` must contain the new pages.
- Document the `.md` output and the button in `doc/site-docs.md` (extend the LLM-friendly output section).

## Definition of done

- [ ] `npm run build` emits `.md` for every page; spot-check three URLs.
- [ ] The button works on a section page and on a section root (checked via `npm run preview`).
- [ ] `llms.txt`, `llms-small.txt`, `llms-full.txt` present; `llms-full.txt` includes new content.
- [ ] `doc/site-docs.md` reflects the output contract.
