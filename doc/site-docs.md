# Documentation Site

**Directory:** `site-docs/`

The public documentation website for Facet, built with Astro and Starlight. It serves the product documentation in English and French — eleven sections ordered by persona journey, from evaluation to operation — plus machine-readable `llms.txt` files. The engineering documentation for agents stays in `doc/`; this site is for product users.

## Commands

Run inside `site-docs/`:

| Command           | Purpose                                                                  |
| ----------------- | ------------------------------------------------------------------------ |
| `npm run dev`     | Dev server at `localhost:4321`; renders diagrams, then rebuilds pages as you edit. |
| `npm run build`   | Full static build into `dist/`. This is the validation gate for changes. |
| `npm run preview` | Serve the built `dist/` locally.                                         |
| `npm run diagrams` | Render every D2 fence to SVG. Add `-- --force` to re-render after a house-style change. |
| `node scripts/check-coverage.mjs` | Coverage and staleness report. The build runs it first in warn mode; add `--strict` to fail on uncovered or unknown IDs. |

The site has no spec suite. `npm run build` is the gate: the `prebuild` hook runs the coverage check, then the build compiles every page, builds the Pagefind search index, generates the `llms.txt` files, copies every content page into `dist/` as a raw markdown `.md` twin, and emits `dist/robots.txt`. Run it after every change.

## Structure

| File or directory      | Covers                                                         |
| ---------------------- | -------------------------------------------------------------- |
| `astro.config.mjs`     | Site config: i18n locales, sidebar, plugins |
| `src/content/docs/`    | English pages — the root locale                                |
| `src/content/docs/fr/` | French pages                                                   |
| `src/content/docs/<section>/` | One directory per section — see [Information architecture](#information-architecture) |
| `scripts/build-diagrams.mjs` | Renders every <code>```d2</code> fence to two SVGs (light + dark) under `public/diagrams/` |
| `scripts/diagram-theme.mjs` | The house style: palette mapping and shape classes for every diagram |
| `scripts/check-diagrams.mjs` | Fails the build on a leftover mermaid or D2 fence |
| `public/diagrams/`     | Built diagram SVGs — generated, not edited |
| `src/scripts/copy-as-markdown.ts` | Client script behind the "Copy as markdown" button           |
| `src/components/PageTitle.astro` | Starlight override: page title + the "Copy as markdown" button |
| `src/components/Hero.astro` | Starlight override: the landing-page hero — title, tagline and actions from front-matter, animated gem in place of an image |
| `src/components/landing/` | The landing-page blocks: `SectionHead`, `Pillar`, `FlowDiagram`, `Door`, `LandingGrid`, `Closing`, `FacetGem` — see [Landing page](#landing-page) |
| `src/styles/global.css`  | Tailwind + Starlight compatibility CSS, app theme token mapping |
| `scripts/emit-md.mjs`    | Postbuild step: copies every page into `dist/` as a raw `.md` twin |
| `scripts/emit-robots.mjs` | Postbuild step: emits `dist/robots.txt` from the site URL |
| `scripts/site-url.mjs`   | The canonical origin — the one place the production domain is named |
| `scripts/build-og-image.mjs` | One-off generator for `public/og.png`, the default social-card image |
| `public/og.png`          | Default Open Graph image — generated, not edited |
| `src/content.config.ts`  | Content collection wiring (Starlight loader + extended schema) |
| `inventory.yml`        | Feature inventory: one entry per feature ID, grouped by area   |
| `coverage-exclude.yml` | IDs exempt from the coverage check, with a reason              |
| `scripts/check-coverage.mjs` | Coverage check and staleness report; runs before every build |
| `../scripts/gen_docs/` (repo root) | Reference page generators — one script per generated page under `src/content/docs/reference/`, run by the `make gen-docs-*` targets |

## Information architecture

Five reader-sorted tabs — Discover, Use, Build, Administer, Reference. The sidebar in `astro.config.mjs` renders them as a topic list (the `starlight-sidebar-topics` plugin); each tab is one collapsed sidebar with its own groups. Tab labels localize (`Découvrir`, `Utiliser`, `Construire`, `Administrer`, `Référence`); group labels stay English in both locales.

| Directory       | Sidebar label | Answers                                        | Overview page          |
| --------------- | ------------- | ---------------------------------------------- | ---------------------- |
| `discover/`     | Discover      | "What is Facet, and is it for me?"             | `discover/index.md`    |
| `use/`          | Use           | "How do I work in the workspace day to day?"   | `use/index.md`         |
| `build/`        | Build         | "How do I model domains and build apps?"       | `build/index.md`       |
| `admin/`        | Administer    | "How do I run and govern a deployment?"        | `admin/index.md`       |
| `reference/`    | Reference     | "What are the exact keys, commands, limits?"   | `reference/index.md`   |

The old `changelog/` section is now one Reference page, `reference/changelog.md` ("Releases").

Every content page carries a `type` front-matter key from this list: `overview`, `tutorial`, `how-to`, `explanation`, `reference` (schema in `src/content.config.ts`; the splash landing page carries none). The type drives the sidebar grouping, the coverage rules, and the voice rules (see [`documentation.md`](documentation.md) → Rule 2b — the layer model maps explanation/how-to pages onto it).

Sections follow the rule "one page = one job". A tab index or section index opens with three to five job cards and then the full page list. The landing page (`index.mdx`, splash template) opens the site: two hero buttons (**Your first hour**, **How Facet works**) and one door per tab. See [Landing page](#landing-page).

### Old URLs

The v2 restructure moved most pages, so `redirects.mjs` (generated, imported in `astro.config.mjs`) maps every pre-v2 URL — English and French — to its new path. `scripts/apply-page-map.mjs` generates it from the page map in `scripts/page-map.mjs`; do not edit it by hand. Astro serves redirects as a 200 page with a meta refresh.

`scripts/check-redirects.mjs` is the gate for that contract: it loads the pre-restructure sitemap URLs from `doc/plans/documentation/documentation-v2/ledgers/old-sitemap-urls.txt`, requests each from a running preview server, and passes only when every URL serves a page, a redirect, or a 3xx — a served 404 page fails it. Run `npm run build && npm run preview`, then `node scripts/check-redirects.mjs`.

### Stubs for pages not yet written

A planned page whose owner workpackage has not written it yet exists as a one-line stub: a real route (the sidebars reference every slug, and Starlight errors on slugs without a route), `description: TODO`, and `pagefind: false` plus `pager: false` so it stays out of search and pager chrome until its owner WP fills it. Note: `draft: true` cannot be used for this — a draft page has no route, which is exactly what the sidebar forbids.

## Landing page

The landing page is the site's front door. Two pages share it: `src/content/docs/index.mdx` (English) and `src/content/docs/fr/index.mdx` (French). Both use the `template: splash` front-matter, which hides the sidebar, and a `hero` front-matter key, which turns on the Hero override.

| File | Covers |
| --- | --- |
| `src/components/Hero.astro` | The Starlight `Hero` override. It keeps the default hero contract — title, tagline, and actions come from the `hero` front-matter, and the h1 keeps the `_top` anchor — and swaps the optional image for the animated gem (`FacetGem`). The localized eyebrow lives in the component. |
| `src/components/landing/FacetGem.astro` | The animated gem: the logo geometry assembling facet by facet, with app cards, wires and orbiting data points. |
| `src/components/landing/SectionHead.astro` | A section heading: eyebrow, h2, optional lead paragraph (the slot). |
| `src/components/landing/Pillar.astro` | One promise card — `data`, `permissions` or `history` — with a small looping illustration. |
| `src/components/landing/FlowDiagram.astro` | The "how it fits" diagram: apps → Facet layers → domains, with travelling packets. All labels are props. |
| `src/components/landing/Door.astro` | An entry-door card, one per tab (Discover, Use, Build, Administer, Reference): icon, step number, hover reveal. |
| `src/components/landing/LandingGrid.astro` | The responsive grid for card rows; the `min` prop sets the column floor (default `15rem`). |
| `src/components/landing/Closing.astro` | The closing call-to-action band: title and links (the slot) over a drifting gem pattern. |

Rules:

- **All words live in the pages.** The `.mdx` files hold every sentence, so the raw `.md` twin stays the readable source for agents. `FlowDiagram` takes its labels as props so each locale passes its own words; `Hero` keeps only the eyebrow inside the component.
- **The hero sentence is the product definition.** The `tagline` says in one sentence what Facet is (from Why Facet: "One governed home for your business data, plus the apps that run on it"), and the two hero actions route to the golden path (`/build/first-hour/`) and the mental model (`/discover/how-it-works/`).
- **The five doors carry the tabs' questions.** Each `Door` opens one tab and answers the question that tab exists for (Discover: what is it and is it for me; Use: day-to-day work; Build: model data and build apps; Administer: install, configure, secure, govern, run; Reference: the exact key, field, operator, command, or payload).
- **Components opt out of prose styling** with the `not-content` class. Starlight's markdown styles would otherwise fight the component CSS.
- **Every animation sits behind `prefers-reduced-motion`**, including the SMIL packets, which hide under it. With motion off, the page must read complete.
- **Colours come from the theme tokens** — `--accent`, `--surface-2`, `--border`, `--sunken`, and friends. The few fixed golds (`#c26f22`, `#d9822b`, `#f2c14e`, `#e8a33d`, `#9a4f12` for light, plus `#f8dc94` and `#b8621b` for dark) copy the two logo lockups (`src/assets/facet-lockup-*.svg`); update the components when the lockups move.
- **Hero pages get a wider column.** `:root[data-has-hero]` in `src/styles/global.css` raises `--sl-content-width` to `68rem` and clips the hero backdrop bleed with `overflow-x: clip` on `main`.

The Hero override applies to any page with a `hero` front-matter key; today that is the two landing pages only.

## Page front-matter

Content pages carry the front-matter contract from [`doc/plans/documentation/documentation-v2/00-contract.md`](plans/documentation/documentation-v2/00-contract.md):

```yaml
---
type: how-to
title: Row scopes
description: Limit which documents a role can see or change.
audience: [admin, author]
features: [RBC-05, DOM-12]
verified_at: c2f1427e
---
```

`src/content.config.ts` extends the Starlight schema with four custom keys — `type` (enum, optional: the splash landing page carries none), `audience` (string array, default `[]`), `features` (string array, default `[]`), and `verified_at` (optional string) — so they survive the build and stay readable by coverage tooling. `audience` values come from this list: `evaluator`, `user`, `author`, `admin`, `developer`, `operator`. The `type` values and what each means live in [Information architecture](#information-architecture).

### Title length

`title` is the page heading, the sidebar label, the `<title>` tag, and the `og:title` tag — one string feeds all four. Keep it to **40 characters or fewer**, in sentence case, with no section prefix (`Automate:`, `Local development:`) and no parenthetical list (`(CRUD, filters, aggregates, ETags)`). The sidebar already groups the page, so the prefix repeats context.

Move the detail the short title drops into `description` or the lead paragraph. The file name sets the URL; a title change never breaks a link.

Generated reference pages carry their title in the generator (`scripts/gen_docs/`); change it there and run `make gen-docs`, never in the page.

## Coverage and staleness

The coverage check enforces the rule that a feature cannot ship undocumented: every inventory ID must appear in at least one page's `features` front-matter, or in the exclusion list.

| File | Covers |
| --- | --- |
| `inventory.yml` | One entry per feature ID (`id`, `name`, `area`) — 158 IDs in 10 areas (`AI`, `APP`, `AUD`, `AUT`, `DOC`, `DOM`, `FE`, `IAM`, `PLT`, `RBC`), pinned to `envelope@c2f1427e`. An entry may carry `reference-only: true` (the ID appears only on reference pages — rule R2 exempts it from coverage) or `removed: <version>` (the feature left the product — the check skips it for coverage, and a citation of it surfaces as unknown). |
| `coverage-exclude.yml` | IDs exempt from the check, each with a one-line reason. DOC-08 is the example: an internal primitive with no user-facing surface. |
| `scripts/check-coverage.mjs` | The check itself. Reads the two YAML files and every English page. |

The check scans `src/content/docs/**/*.md` and `.mdx`, English tree only — French pages share their IDs with the English source page. It reads the `features` key of the front-matter; the page contract fixes it as a flat array on one line, and the check reports a page whose value breaks that shape. A wildcard such as `IAM-*` expands to every `IAM-*` ID in the inventory; the expansion, not the wildcard, counts as coverage. IDs that a page cites but the inventory does not hold are unknown IDs — they surface typos. The check prints a per-area table (total, covered, uncovered), then the uncovered, unknown and front-matter problem lists.

Rule R2 scopes coverage to task pages: only a `how-to`, `tutorial` or `explanation` page establishes coverage of an ID. A `reference` or `overview` citation alone does not cover — a feature a reader can act on needs a page that acts. The check also reports:

- **R5** — non-`overview` pages with an empty `features` list (a how-to that covers nothing is a smell, not an error).
- **Missing `type`** — every page except the landing page must carry a `type`.
- **Long titles** — `title` over 40 characters.

The build runs the check in warn mode: it reports and always exits 0. `node scripts/check-coverage.mjs --strict` exits non-zero while any inventory ID is uncovered or any unknown ID is on a page. The warn-to-strict flip is tracked in the plan README status table while the documentation-v2 plan runs.

The same script prints the staleness report: a page is stale when its `verified_at` commit is more than 90 days old (`STALE_DAYS` in the script). The age resolves through git; pages without a marker, and markers git cannot resolve, are listed too. Staleness counts days, not releases (decision D11): release tags do not exist yet. Switch to a release-based measure when tags exist.

## Reference generators

Thirteen of the eighteen pages under `src/content/docs/reference/` are generated, and a fourteenth — the REST API page — embeds a vendored copy of the OpenAPI file that a target refreshes. The generator scripts live in `scripts/gen_docs/` at the repo root — one script per page — and each has a `make gen-docs-<name>` target at the repo root; `make gen-docs` runs them all. The target names are `rest-api` (vendors `doc/api/openapi.json` into `public/api/openapi.json`), `cli`, `field-types`, `filter-operators`, `npm-cli`, `doctype-schema`, `dvt-schema`, `lua`, `agent-tools`, `system-settings`, `config-keys`, `account-settings`, `health-metrics`, and `feature-index`.

Rules:

- Never hand-edit a generated page. Every generated page opens with a note naming its source of truth and its make target; fix the generator instead.
- A generator writes the whole page — front-matter included — and stamps `verified_at` from `git rev-parse --short HEAD` at generation time. Output is byte-stable for one commit: running a target twice changes nothing.
- A generator fails loudly (non-zero exit) when its source of truth has a shape it does not recognize. It never silently skips an entry.
- The release workflow must run `make gen-docs` before the site build so the pages track the code they describe. Wiring that line belongs to the release pipeline owner; this repo holds no release CI file yet — record the line there when it exists.
- Two generators have environment needs: `gen-docs-agent-tools` requires the dev AI settings (`.env.dev`, or the `FACET_AI_*` variables) because the tool registry loads `config.dev.yml`, and `gen-docs-npm-cli` refuses to run when `packages/cli/dist` is older than its TypeScript sources (build the package first).
- The feature index (`gen-docs-feature-index`) reads `site-docs/inventory.yml` and every English page's `features` front-matter — the same data, parsers, and wildcard rules as `scripts/check-coverage.mjs` — so run it after the other pages change; it is last in the `make gen-docs` chain.

## i18n

Two locales: `root` (English, the default) and `fr` (French). A page is linked to its translation when the two files share the same filename:

```
src/content/docs/start/install.md     → /start/install/
src/content/docs/fr/start/install.md  → /fr/start/install/
```

Rules:

- Write English first. Add the French page afterwards, with the same path under `fr/`.
- French pages follow the style guide in [`site-docs-fr-style.md`](site-docs-fr-style.md): translate the meaning, not the words; the glossary there fixes which terms stay English and which UI labels come from `frontend/messages/fr.json`.
- When a French page is missing, Starlight still serves the `/fr/...` route with the English content and shows an "untranslated" notice banner.
- UI strings (search, pagination, theme toggle) localize automatically; Starlight ships built-in French translations.
- Sidebar group labels in `astro.config.mjs` are author-defined strings. They stay English in both locales.

## Diagrams

Pages write **D2**, not mermaid. A <code>```d2</code> fence is rendered at build time into two SVG files — one per theme — and the fence is replaced in the page by an `<img>` pair that CSS toggles with `[data-theme]`. Nothing renders in the browser.

`scripts/build-diagrams.mjs` (run by `npm run build` and `npm run dev`):

1. Finds every <code>```d2</code> fence under `src/content/docs/`.
2. Compiles it with the house style from `scripts/diagram-theme.mjs`, once per theme.
3. Writes `public/diagrams/<hash>-light.svg` and `<hash>-dark.svg`. The hash is the source's SHA-256 prefix, so an unchanged diagram keeps its file.
4. Replaces the fence with an HTML comment holding the D2 source, then the `<img>` pair. The comment keeps the source copyable for readers and agents, and lets the build re-render an existing diagram without a separate source file.

A fence that does not compile **fails the build**, with the page and line. `scripts/check-diagrams.mjs` fails the build when a mermaid fence survives.

### The house style

`scripts/diagram-theme.mjs` owns every colour and shape. Pages never set a colour.

| Class | Use for |
| --- | --- |
| `node` | The default step. |
| `decision` | A question with two or more branches. |
| `store` | Durable state: PostgreSQL, Redis, a log. |
| `external` | Something outside the boundary: a browser, a caller. |
| `ok` / `warn` / `danger` / `info` | The outcome of a step. |

Rules for authors:

- **Keep nodes flat.** One label, no children. A node with children is a D2 container: D2 paints it with the accent fill and draws a large title on top, which no theme override makes look right.
- **Pick the direction.** A branching flow reads left to right; a linear chain of more than four steps reads top to bottom. Write `direction: down` as the first line for the latter; the default is `right`.
- **Keep labels short.** A wide diagram is scaled down to fit the content column, and the text shrinks with it. Prefer `Permission` over `The permission record that names an action`.

Each theme is its own compile, with its palette as the base override. D2 emits `dark-theme-overrides` inside a `prefers-color-scheme` media block, and the site switches theme with a `data-theme` attribute, so a single compile with both palettes would never apply the dark one.

## Screenshots

Playwright captures the UI screenshots the tutorial pages embed. One script, one shot list:

| File | Covers |
| --- | --- |
| `scripts/screens/capture.mjs` | The capture script. Reads a YAML shot file (`--shots`, default `scripts/screens/shots.yml`), accepts `--base` and `--only <id,...>`. One browser context per persona, signed in once through the real sign-in form (`/Login`, placeholder-driven, "Skip for now" on the MFA enrollment interstitial). Per shot: goto (networkidle, 30 s), optional `wait` selector, `settle` ms, optional `highlight` (2 px `#2563eb` outline), screenshot of the `crop` element or full page, `animations: disabled`, `caret: hide`, written to `src/assets/screens/<out>`. A `login: true` shot runs unauthenticated in a throwaway context. Run: `cd site-docs && NODE_PATH=$(pwd)/../frontend/node_modules node scripts/screens/capture.mjs`. |
| `scripts/screens/shots.yml` | The shot list: defaults (base `https://facet.localhost:3443`, viewport 1280×800, light theme), five personas (nadia, tom, lucia, ravi, admin), and one entry per shot with its output path under `src/assets/screens/`. |

Two classes of shot live in the list:

- **Standard shots** — reproducible on any instance with the Brightwater example loaded. They read live data, so views that show today-relative content (kanban boards, dashboard panels) differ on every run; the shots.yml header names them.
- **Captured-once shots** — listed in the shots.yml comment block. They depend on one-off UI states (an OTP sign-in screen, a filled New Account form, a generated temporary password) and were taken against scratch flows outside the standard run; recapture them by replaying those flows.

Pages embed the PNGs with markdown image syntax and a descriptive alt text; the alt text says what the shot shows, not "screenshot".

## Tailwind

Tailwind CSS v4 runs through the `@tailwindcss/vite` plugin. `src/styles/global.css` follows the official Starlight Tailwind setup: it defines the cascade-layer order and imports `@astrojs/starlight-tailwind`, the compatibility package that adapts Tailwind's theme and preflight to Starlight's styles. Tailwind `dark:` variants follow Starlight's dark mode.

## Theming

The site wears the app theme. `src/styles/global.css` copies the light and dark token sets from `frontend/src/lib/styles/tokens.css` — the source of truth the Svelte app renders; the `example/design-guideline.html` page is out of date and is not a colour reference — onto `:root` and `[data-theme='dark']`, then maps them onto Starlight's `--sl-color-*` variables. Starlight derives every surface from that palette — page, nav and sidebar backgrounds, text, links, the active sidebar item, tables, inline code, asides, the search modal, and the Expressive Code block chrome (its theming reads the same variables). Starlight and the app both key the theme off `data-theme` on `<html>`, so one attribute drives both token sets.

| Site surface | App token |
| --- | --- |
| Content background | `--surface` |
| Nav + sidebar background | `--ground` |
| Links and active sidebar item | `--accent-ink` (readable gold ink, never the raw fill) |
| Text on a gold fill | `--surface` (light) / `--on-accent` (dark) |
| Inline code background | `--sunken` (light) / `--border-strong` (dark) |
| Asides: note / tip / caution / danger | `--info` / `--ok` / `--warn` / `--danger` |

Fonts load through the `head` config in `astro.config.mjs`: Space Grotesk for headings and the site title, JetBrains Mono for code (`--sl-font-mono`, which Starlight's Expressive Code preprocessor also uses for blocks via `--__sl-font-mono`). Body text keeps the app's system sans stack. Shiki syntax colours inside code blocks stay Starlight's defaults. Do not pass an `expressiveCode.styleOverrides` object in `astro.config.mjs`: a user style override makes the EC stylesheet's emitted asset hash diverge from the hash the pages reference, so every code block 404s its stylesheet and loses its background, its syntax colours and its horizontal scrolling (verified on Astro 7.4 / Starlight 0.42).

The header logo is the app's gem + wordmark lockup, copied from `frontend/src/lib/assets` into `src/assets/` (`facet-lockup-light.svg` for light surfaces, `facet-lockup-dark.svg` for dark). Starlight's dual-logo config renders both `<img>`s and toggles them with `[data-theme]` classes — the same pattern as the app's `Logo.svelte` — and `replacesTitle: true` keeps the text title for screen readers only. When the frontend lockups change, re-copy the two files; the copies are not synced automatically.

Diagrams wear the same palette. `scripts/diagram-theme.mjs` maps the app tokens onto D2's 18 theme codes and defines the shape classes; it never reads a colour from a page. The two token blocks there are copies of the app tokens — update them when the palette moves.

## LLM-friendly output

Many readers of the site are coding agents. The build ships every page in two machine-readable forms: the `llms.txt` sets and a raw `.md` twin per page.

`starlight-llms-txt` generates three files at the site root on build: `/llms.txt`, `/llms-small.txt`, and `/llms-full.txt`. The `site` field in `astro.config.mjs` is required — the plugin builds absolute URLs from it. `llms.txt` is the index pointing at the other two; `llms-full.txt` holds the full text of every English page.

After `astro build`, `scripts/emit-md.mjs` copies every content page into `dist/` as a byte-for-byte `.md` twin of its URL, so each page is also fetchable as raw markdown:

| Source | Emitted file | URL |
| --- | --- | --- |
| `src/content/docs/build/designing-doctypes.md` | `dist/build/designing-doctypes.md` | `/build/designing-doctypes.md` |
| `src/content/docs/start/index.md` | `dist/start.md` | `/start.md` |
| `src/content/docs/fr/start/install.md` | `dist/fr/start/install.md` | `/fr/start/install.md` |
| `src/content/docs/index.mdx` | `dist/index.md` | `/index.md` |

Rules:

- A directory `index` page collapses to a flat `<section>.md` next to its directory — the same URL the built site serves.
- The copy is byte-for-byte: the front-matter (`audience`, `features`, `verified_at`) stays in the file, and a diagram stays an HTML comment holding its D2 source followed by the `<img>` pair. Nothing is rewritten.
- The twins mirror source files, not fallback routes: a French URL whose page only exists in English (Starlight serves the English content with a fallback banner) has no `.md` twin and answers 404.

The **Copy as markdown** button sits next to the page title on every standard page (`src/components/PageTitle.astro` renders it, `src/scripts/copy-as-markdown.ts` wires it). It fetches the `.md` twin of the current page (`/start/` → `/start.md`) and copies the file to the clipboard; if the fetch or the clipboard fails, it copies the page URL instead. It hides itself when the twin answers 404 — in `astro dev` (twins exist only after a build), on French fallback routes, and on the 404 page. Hero and splash pages (the landing page) skip the `PageTitle` component and carry no button; agents can fetch `/index.md` directly.

## SEO surface

The site is a public product page: every route ships indexable, and the head carries the full SEO set. Starlight generates most of it per page — `<title>`, `meta description` (front-matter `description`, falling back to the site description), `rel=canonical`, the Open Graph and Twitter Card tags, and `hreflang` alternates for English, French, and `x-default`.

Three pieces ride on top:

- **Sitemap.** `@astrojs/sitemap` emits `/sitemap-index.xml` + `/sitemap-0.xml` into `dist/` at build. Starlight already links the index from every page head; `robots.txt` names it too.
- **`robots.txt`.** `scripts/emit-robots.mjs` writes it into `dist/` after the build (not `public/`, so the domain is declared once). It allows everything and names the sitemap.
- **Social card.** `public/og.png` (1200×630, generated by `scripts/build-og-image.mjs` from the dark lockup on the dark surface) is the default `og:image` for every page; the head entries in `astro.config.mjs` carry the absolute URL plus width, height, and alt.

The canonical origin lives in `scripts/site-url.mjs` and feeds `site`, the `og:image` URL, and the sitemap line in `robots.txt`. It reads the `SITE_URL` environment variable first, so the container build injects the production domain without touching a source file.

Google Tag Manager (`GTM-T2PQ3L7L`) loads on every page through the Starlight `head` config in `astro.config.mjs`. The entries are gated on a production build — `npm run dev` never sends pageviews.

## Container image

`docker/docs.Dockerfile` builds the release image — a fully static build served by `nginxinc/nginx-unprivileged` on port 8080 (uid 101, non-root). The build context is the repository root, like the other release images. The server block is `docker/docs.nginx.conf` (replaces the image's `conf.d/default.conf`): immutable caching for `/_astro/` and `/diagrams/`, `must-revalidate` for everything else, gzip, the security headers, the Astro 404 page, and `text/markdown` for the `.md` twins.

The production origin rides in as a build arg — a placeholder default would ship a wrong sitemap and canonical URLs:

```sh
docker build -f docker/docs.Dockerfile \
  --build-arg SITE_URL=https://docs.example.com \
  --build-arg VERSION=v0.1.0 --build-arg REVISION=$(git rev-parse --short HEAD) \
  -t facet-docs .
```

The container holds no state and no secrets; the host's nginx edge terminates TLS and proxies to port 8080 over plain HTTP.

## Quirks

- Sidebar groups use the Starlight v0.39+ shape: `{ label, items: [{ autogenerate: { directory } }] }`. The old `{ label, autogenerate }` shape is rejected at build.
- YAML frontmatter in content files must use spaces. Tab indentation breaks the parser.
- `template: splash` (used by `index.mdx`) hides the sidebar on the landing page.
- Hero and splash pages skip the `PageTitle` component, so the copy-as-markdown button only renders on standard pages. In `astro dev` the button hides itself: the `.md` twins are a postbuild step and do not exist until `npm run build`.
- Diagrams are a build artifact. `public/diagrams/` is generated; edit the D2 source in the page, never the SVG. A new or edited fence needs `npm run diagrams` before `npm run dev` or `npm run build` shows it.
