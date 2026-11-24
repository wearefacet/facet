# Frontend

The Facet frontend is a SvelteKit single-page application that provides a web UI for managing document stores, viewing audit trails, and interacting with the Facet API.

**Stack:** SvelteKit (Svelte 5, runes mode) + TypeScript + Tailwind CSS + Paraglide JS (i18n) + [Bits UI](https://bits-ui.com) (headless interactive primitives).

**UI Component integration notes:** See [`doc/frontend/bits-ui.md`](bits-ui.md) for Bits UI API rules, CSS targeting, and common pitfalls.

**Testing & Quality:** Vitest `server` project (pure logic) + `@storybook/addon-vitest` (component behaviour via story play functions, single headless Chromium), Prettier (formatting). Browser E2E lives in the top-level [`e2e/`](../../e2e/README.md) package, not here.

AS MUCH AS POSSIBLE, DO NOT USE `$effect` and use `$derived` or other runes instead; if `$effect` MUST BE used, ensure that the effect is guarded to prevent infinite loops.

---

## Dev topology — vhost routing through Caddy

In development the browser talks through the Caddy proxy (`caddy/Caddyfile`) on port `3443`. Routing is by **host**, not by path, and mirrors the production vhost model:

| Host                            | Routes                                                                                                                                                                                                                                 |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `https://facet.localhost:3443`  | Backend namespaces → Kemal (`127.0.0.1:3000`); everything else → SvelteKit dev server (`[::1]:5173`)                                                                                                                                   |
| `https://*.apps.localhost:3443` | Everything → Kemal. The `App::Hosting` pre-router resolves the `Host` header against live `app.App` documents and serves the app's active deployment (see [`../backend/app-system.md`](../backend/app-system.md) → Deployment serving) |
| `https://localhost:3443`        | `421` — stale origin from before vhost routing                                                                                                                                                                                         |

| Path prefix (facet.localhost only)                    | Upstream                            |
| ----------------------------------------------------- | ----------------------------------- |
| `/Api/*`, `/OAuth/*`, `/.well-known/*`, `/A/*`, `/Ws` | Kemal backend (`127.0.0.1:3000`)    |
| everything else                                       | SvelteKit dev server (`[::1]:5173`) |

A request with a method other than GET, HEAD, or OPTIONS to a lowercase twin of a backend namespace (`/api`, `/oauth`, `/a`, `/ws`, `/edge`) does not reach the frontend: the edge answers `404` with a JSON message that names the case rule. GET, HEAD, and OPTIONS keep the fall-through, so domain pages and CORS preflights do not change. The lowercase probe names are the exception: `/healthcheck` and `/metrics` are never domain ids, so the edge answers `404` for every method. Without that rule a GET follows the SPA auth hook to `303 → /Login` → `200` HTML, which a redirect-following monitor reads as healthy while the backend is down (F07-05).

Facet stays one origin (`facet.localhost`), so its cookies, backend-issued redirects (the OAuth authorize → login bounce), and fetches all stay same-origin in dev — no Vite-level `/Api` proxy exists (`vite.config.ts` deliberately has no `server.proxy`). A hosted app gets its own origin; session cookies are host-only (no `Domain` attribute), so the two surfaces never share a cookie jar. `./scripts/dev` starts Caddy, the backend, and the frontend together; pass `--no-caddy` for the raw two-port mode (backend `:3000`, frontend `:5173`).

`config.dev.yml` mirrors this: `host`, `base_url`, and `artifact_base_url` all point at `https://facet.localhost:3443` so every backend-generated absolute URL agrees with the origin the browser actually uses.

DNS: Chromium resolves `*.localhost` (any label depth) to loopback by itself. Every other client (Firefox, curl, the facet CLI, Node) needs hosts entries — `127.0.0.1 facet.localhost app.apps.localhost` plus one per extra hosted-app host. Hosted apps live under the `apps.localhost` suffix on purpose: verifiers refuse to match a two-label wildcard (`*.localhost`) against a subdomain, so a wildcard at that depth cannot carry valid certificates — Caddy would serve it for `facet.localhost` too and shadow the exact certificate. Because Facet no longer answers at bare `localhost`, every direct backend address (`BACKEND_URL`, probes) must use the loopback literal form `http://127.0.0.1:3000` — the `App::Hosting` dispatcher reserves `127.0.0.1` and `::1`, but not the name `localhost`.

The `/Api/` skip in `hooks.server.ts` (`handleAuth`) remains: it guards against SvelteKit's same-origin `event.fetch` re-entering the request pipeline, not against the Vite proxy.

### SSR fetches reach the backend directly

Because Vite is a plain-HTTP listener, SvelteKit derives the origin of the current request from its **own** server — so during SSR (a full page load through the `handle` hook, server `load`, or an endpoint) an `event.fetch('/Api/…')` is built against SvelteKit's origin, resulting in an `http://facet.localhost:3443/Api/…` URL. That is not a usable address: Caddy only speaks TLS on `:3443`, and replying to it returns `400 "Client sent an HTTP request to an HTTPS server"`. There is **no backend log** for this failure because the request never reaches the backend or Caddy's route table — it is a rejected TLS handshake.

The `handleFetch` hook in `src/hooks.server.ts` solves this (dev only). It rewrites requests to the `/Api/` and `/OAuth/` namespaces to the backend directly and forwards the session cookie manually, because SvelteKit's automatic cookie passthrough only applies to same-host / subdomain URLs and does not span across the backend host. `/app/*` is the OAuth surface — the consent page's server load fetches `/OAuth/authorize`, so it must reach the backend too. The backend is reached without going through Caddy's TLS, so the SSRF/cert concerns do not apply. This only runs when `dev` is true — production servers are not affected.

Two more pieces make the rewrite safe for the auth flow — both handled in `handleFetch` + `src/lib/ssrCookies.ts`:

- **The request body is buffered (`await request.arrayBuffer()`) before building the new `Request`.** Passing the original request's stream body straight through throws in Node (`RequestInit: duplex option is required when sending a body`), which silently killed every rewritten POST — the SSR token refresh included. `tryRefresh` swallows that error, so every full page load with an expired access token bounced the user to `/Login`.
- **The backend response's `Set-Cookie` headers are re-issued through `event.cookies.set` (`applySetCookies`).** SvelteKit propagates set-cookies back to the browser only for same-origin `event.fetch`; the rewrite makes the URL cross-origin, so `auth_token` / `refresh_token` rotation answers would otherwise be dropped and the browser would present a stale token — which the backend's reuse detection answers by revoking the session.

The forwarded cookie header is rebuilt from the event's live cookie jar (`event.cookies.getAll()`), not the page-load request's raw header, so a token rotated earlier in the same request (e.g. by `handleAuth`) reaches later same-event backend calls and the page load rotates at most once.

### `BACKEND_URL` — single source for the backend address

The backend address is **not** hardcoded. `BACKEND_URL` in the root `.env` is the single source, consumed by all three surfaces:

| Consumer                                              | How it reads `BACKEND_URL`                                                                                                                                       |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Caddy (`caddy/Caddyfile`)                             | `{$BACKEND_URL:http://127.0.0.1:3000}` placeholder on every backend upstream (the `:default` form keeps a bare `caddy run` working when the var is not exported) |
| Frontend SSR (`handleFetch` in `src/hooks.server.ts`) | `$env/dynamic/private` (`BACKEND_URL`)                                                                                                                           |
| Backend                                               | reads root `.env` itself via `load_dotenv`                                                                                                                       |

`scripts/dev` resolves the dotenv chain into the environment before launching Caddy and the frontend, following the same precedence as the backend's `load_dotenv` (shell wins, then `.env`, then `.env.$APP_ENV` — see [`doc/backend/cli.md`](../backend/cli.md) → Dotenv loader), so both inherit the same values and every entry point resolves `DATABASE_URL` identically. Change `BACKEND_URL` once to repoint the whole stack (e.g. a different backend port, or the raw two-port `--no-caddy` mode). The Caddy upstream for the SvelteKit dev server carries its own placeholder, `{$FRONTEND_URL:[::1]:5173}`, so another frontend listener (e.g. a production-build preview server) takes over without editing the Caddyfile.

---

## Design system

The canonical source of truth for the visual language is [`frontend/example/design-guideline.html`](../../frontend/example/design-guideline.html). It defines every token, type specimen, and usage rule. The companion [`frontend/example/table.html`](../../frontend/example/table.html) demonstrates the design language applied to the seven core surfaces (table, kanban, grid, markdown, form, show, relations).

When the guideline and any component CSS disagree, **the guideline wins**. Update the component to match.

### Tokens

All visual values live as CSS custom properties in [`src/lib/styles/tokens.css`](../../frontend/src/lib/styles/tokens.css), with a `:root` (light) and `[data-theme="dark"]` block. Token categories:

| Group         | Tokens                                                                                         | Purpose                                                   |
| ------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Neutrals      | `--ground`, `--surface`, `--surface-2`, `--sunken`, `--border`, `--border-strong`              | Page chrome, panels, dividers                             |
| Ink           | `--text`, `--text-2`, `--text-3`                                                               | Primary / secondary / tertiary text                       |
| Brand (gold)  | `--accent`, `--accent-press`, `--accent-ink`, `--accent-weak`, `--on-accent`                   | Fill, pressed fill, readable ink, weak tint, text-on-fill |
| Semantic      | `--ok`, `--warn`, `--danger`, `--info` (+ `-weak` variants) — `--ok-ink`, `--danger-ink` for text on `--ok`/`--danger` fills | Status colours                                              |
| Doctype tints | `--dt-invoice`, `--dt-shipment`, `--dt-contact`, `--dt-task`, `--dt-document`, `--dt-contract` | Per-doctype identity                                      |
| Shape         | `--r-sm`, `--r`, `--r-lg`, `--r-pill`, `--sh-1`, `--sh-2`                                      | Radii and elevation                                       |
| Type          | `--font-display`, `--font-sans`, `--font-mono`                                                 | Space Grotesk / system / JetBrains Mono                   |

### Usage rules

These rules are enforced by code review; they are not auto-checked.

1. **Spend boldness once.** Gold is the only accent. Keep surroundings quiet neutral; let the one gold thing be the thing the eye goes to.
2. **Gold fill ≠ gold text.** On a gold fill, text is `--on-accent` (dark). For gold text, links, and focus rings on light surfaces, use `--accent-ink` — never the raw `--accent` fill.
3. **Data is mono.** Identifiers, amounts, dates, codes, confidence, and event names render in `--font-mono`. This is the signal/noise rule made typographic.
4. **Identity is a capsule.** Any reference to a record is the branded capsule: one shape, coloured by `--dt-*`. Same shape in tables, cards, prose, and relations.
5. **Theme by token, never by structure.** Per-doctype and per-domain customisation overrides tokens (`--dt-*`, density, accent). Component structure is identical everywhere.
6. **Quiet by default.** Borders over shadows; one elevation step (`--sh-1`) for what lifts. Motion is a soft fade and hover only; `prefers-reduced-motion` is respected.

### Component CSS conventions

- **CSS is scoped inside `<style>` tags** — every `.svelte` file includes its own styles inline. There are no separate `.css` files.
- **Tokens only — no hardcoded colours.** Every colour, radius, shadow, and font family must reference a `--*` token. The only exceptions are `#fff` for toggle thumbs and danger-button text (matching the guideline) and the focus-ring `#fff` on dark fills.
- **Focus rings use `--accent-ink`**, not `--accent`. This applies to the global `:focus-visible` in `base.css` and to every component's `:focus-visible` / `:focus` rule.
- **Active fills use `--accent` + `--on-accent`.** The active pagination page, the checked toggle track, and the primary button all use the solid gold fill with dark text on top.
- **Weak tints pair with their full-colour ink.** A `*-weak` background is always paired with the matching full-colour text (e.g. `.badge-ok` uses `--ok-weak` background + `--ok` text).
- **Overlay z-tiers are fixed.** New dialogs land on the shared confirm tier, never on a bespoke value. The map (from a grep of `z-index` across `components/` and `routes/`): `50` calendar picker · `60` notification panel, OidcProviders dialog · `100/101` feature dialogs + the fullscreen-expand shell (`.fullscreen-overlay` scrim / `.fullscreen-panel`) · `110/111` TemporaryPasswordPanel (bespoke — no flow opens it together with a confirm dialog) · `120/121` ConfirmDialog, CommandPalette, ShortcutsDialog, ActionArgsDialog · `130/131` WelcomeTour (above every dialog — a first-run tour must not hide behind one) · `200+` popovers, menus, floats · `1200` toasts. Same-tier stacking falls to portal DOM order (= open order), which is the correct sibling behaviour — a tier bump is the fix when a surface must always win, not a larger number on one component.

### Base styles

[`src/lib/styles/base.css`](../../frontend/src/lib/styles/base.css) holds the reset (`box-sizing`, body font/colour), the `::selection` tint, the themed scrollbar defaults (`scrollbar-color`/`scrollbar-width` on `html`, inherited by every scroller), the `button` reset, the global `:focus-visible` ring, and the `prefers-reduced-motion` guard. Both `tokens.css` and `base.css` are imported once in [`src/routes/+layout.svelte`](../../frontend/src/routes/+layout.svelte).

---

## Source files

```
frontend/
├── .storybook/
│   ├── main.ts          # Storybook configuration
│   └── preview.ts       # Preview defaults (a11y addon, control matchers)
├── eslint.config.js     # ESLint flat config (js/ts/svelte recommended + prettier off-switch)
├── example/              # Canonical design guideline & surface mockups (HTML)
│   ├── design-guideline.html  # Source of truth for tokens, type, usage rules
│   └── table.html             # Design language applied to the 7 core surfaces
├── messages/
│   ├── en.json          # Paraglide messages — base locale (English)
│   └── fr.json          # Paraglide messages — French (same key set and order as en.json)
├── project.inlang/      # Paraglide project settings
├── src/
│   ├── routes/           # Four disjoint route subtrees — see "Routing" below
│   │   ├── +layout.svelte   # Root layout — auth, theme, AppShell, BuilderModeBar
│   │   ├── +error.svelte    # Global error page (status-driven classifier, lib/errorPage.ts)
│   │   ├── layout.css       # Tailwind v4 entry (`@import 'tailwindcss'`)
│   │   ├── +page.svelte     # Dashboard (live)
│   │   ├── login/           # Login + held-login steps (change, challenge, enroll) + SSO provider buttons
│   │   ├── reset-password/  # Reset link confirm / request (invite acceptance)
│   │   ├── oauth/           # OAuth consent (app + MCP)
│   │   ├── healthcheck/     # +server.ts liveness endpoint (fixed 200; handleAuth exempts it)
│   │   ├── [domain=notApi]/ # Live domain overview + doctype table
│   │   ├── Configure/       # Configure shell + admin surfaces (domains, apps, access: roles / assignments / accounts, currencies, audit, platform: indexes / artifacts)
│   │   ├── Settings/        # Personal preferences + API keys + active sessions
│   │   └── Builder/         # Builder subtree (URL-driven, not sessionStorage)
│   │       ├── +page.svelte     # Builder landing (draft grid)
│   │       └── [draftDomain]/   # Draft domain editor + nested [doctype] editor
│   ├── lib/
│   │   ├── app/             # OAuth app admin — appTypes.ts, appGrantsMapping.ts, appValidation.ts, deployments.ts (Vitest-tested)
│   │   ├── assets/          # Static module assets (favicon)
│   │   ├── assistant/       # AssistantDriver (http + mock), turn reconstruction, tool-call helpers, ui-tools (Vitest-tested)
│   │   ├── authorization/   # roleMembership.ts, accountRoles.ts, permissionRefresh.svelte.ts
│   │   ├── calendar/        # Calendar, DatePicker, Month/Week grids, discriminator.ts (Vitest-tested)
│   │   ├── collectionView/  # Collection-view config — types.ts + config.ts (pure builders/validators for CollectionViewEditor, Vitest-tested) + viewState.ts (per-view localStorage state of the listing, Vitest-tested)
│   │   ├── datasource/      # Document data abstraction layer
│   │   │   ├── interface.ts # DataSource<T> & DocumentRef<T>
│   │   │   ├── types.ts     # Document, ListResult, ListParams, DataSourceError
│   │   │   ├── filterParams.ts # serializeFilterValue — shared `filters[key]=value` query encoding (Vitest-tested)
│   │   │   ├── DocumentDataSource.ts # HTTP-backed implementation
│   │   │   └── MockDataSource.ts     # In-memory implementation
│   │   ├── doctype/         # Doctype-definition modules — types.ts (parse), serialize.ts, previewDocument.ts, relation modules, form seed/diff, filters, keys, icons (Vitest-tested)
│   │   ├── i18n/            # Locale helpers (localeNames.ts)
│   │   ├── iam/             # IAM content helpers (content.ts, apiKeys.ts)
│   │   ├── importExport/    # Import/export API client — pure, fetch-injectable (Vitest-tested)
│   │   │   └── importExportClient.ts # enqueue export/import, status poll, header preview, format detect
│   │   ├── kanban/          # Kanban board — Kanban.svelte, lanes.ts (Vitest-tested)
│   │   ├── mcp/             # MCP endpoint directory client (lib/mcp/endpoints.ts)
│   │   ├── paraglide/       # Generated i18n modules (gitignored)
│   │   ├── styles/          # Global CSS — tokens + base reset
│   │   │   ├── tokens.css  # Design tokens (:root + [data-theme=dark])
│   │   │   └── base.css    # Reset, ::selection, :focus-visible, reduced-motion
│   │   ├── components/      # Shared UI components (primitives / features / schematic)
│   │   │   ├── primitives/  # Feature-free widgets, one subfolder per role:
│   │   │   │   ├── actions/     # Button, IconButton, DropdownMenu
│   │   │   │   ├── data/        # Badge, Capsule, Chip, Money, RelativeTime, ListView, CollectionViewEditor, FieldValue (+ cellKind.ts — shared field-type dispatch)
│   │   │   │   ├── content/     # Avatar, Markdown, Card, DoctypeHeader, Logo
	│   │   │   │   ├── forms/       # Input, Select, Toggle, CodeEditor, TagPicker, CalendarPanel, StringListEditor, ReferenceListEditor, StructuredInput (+ calendarGrid / durationMath / moneyFormat / structuredSchema helpers)
│   │   │   │   ├── navigation/  # Link, Tabs, TabPane, Pagination, FilterBar
	│   │   │   │   └── surfaces/    # AppShell, Topbar, NavPanel, Panel, QuickView, PageHeader, ConfirmDialog, ToastHost, DangerZone, Can, SidebarShell, PreviewBanner, NotFoundPage, ChapterNav (+ chapterScroll.svelte.ts) (+ documentIdentity.ts / QvIdentity.ts identity helpers)
│   │   │   ├── features/    # Feature-owned UI, one subfolder per feature:
│   │   │   │   ├── admin/       # RbacEditor, NewRoleDialog, RoleAssignmentEditor, RoleMemberRow + account admin (AccountCredentialActions, TemporaryPasswordPanel)
│   │   │   │   ├── apps/        # OAuth app admin — SetupForm, CredentialsPanel, ReviewPanel, DeployPanel, AppSettingsForm
│   │   │   │   ├── audit/       # GlobalAuditTable, AuditDetail, ChangeList, History (+ HistoryDetailPane.svelte / historyDetail.ts)
│   │   │   │   ├── auth/        # LoginScreen (SSO provider list), ConsentScreen, TwoFactorScreen, TotpRegistrationScreen, ForcedChangeScreen, PasswordResetScreen, PasswordResetConfirmScreen
│   │   │   │   ├── builder/     # BuilderSidebar, BuilderModeBar, FloatingAssistant
│   │   │   │   ├── chat/        # AssistantWindow, WorkspaceAssistant, ChatPanel, ChatThread, ChatInput, ConversationList
│   │   │   │   ├── configure/   # DomainsList, DoctypeEditor, DomainEditor, AppGrantsEditor + their header/tab/card children (doc/frontend/configure-editors.md)
│   │   │   │   ├── dashboard/   # DomainDashboard, EditDomainDialog
│   │   │   │   ├── document-view/ # Template engine (DvtValue, DvtLabel, DvtTabs) + DocumentForm, ActionArgsDialog
│   │   │   │   ├── importExport/ # ImportExportActions (toolbar export menu + import dialog), ExportMenu, ImportDialog
│   │   │   │   ├── platform/    # IndexesTable (managed-index status), ArtifactsExplorer, SystemSettingsForm, OidcProviders (+ their *Source adapters), SettingsFieldRow
│   │   │   │   ├── settings/    # ApiKeyManager, NewApiKeyDialog, ApiKeyRevealDialog, McpEndpoints, Sessions (+ SessionsSource.ts)
│   │   │   │   ├── sidecar/     # CommentSurface, AttachmentSurface (+ surfaces.ts registration, commentThreads.ts)
│   │   │   │   └── welcome/     # WelcomeTour (first-run admin tour)
│   │   │   └── schematic/   # Domain graph visualisation (DomainSchematic)
│   │   ├── table/           # Table component + co-located files
│   │   ├── surfaces/        # lib/surfaces/registry.ts — the general surface registry
│   │   ├── utils/           # searchParams.ts, relativeTime.ts, color.ts, mutator.svelte.ts, saveFlash.svelte.ts
│   │   ├── *.svelte.ts      # Runes stores: auth, session, role, permissions, settings, theme, notifications, toast, websocket, assistantOpen, confirm, builderDraft, builderSocket, previewSession, recentDocuments, navCounts, navState
│   │   └── *.ts             # Pure modules: template-types.ts (node grammar) + template-resolve.ts (value resolution) + referenceLabel.ts (reference labels for the view renderer), navModel.ts, navTypes.ts, navCrumbs.ts, doctypeCatalogue.ts, errorPage.ts, loginFlow.ts, http.ts, ssrCookies.ts, systemDomains.ts, timezones.ts, zonedTime.ts, clipboard.ts, artifacts.ts, notificationDownload.ts
│   ├── params/              # Route param matchers (notApi.ts)
│   ├── hooks.ts             # Universal hooks (Paraglide)
│   ├── hooks.server.ts      # Server hooks (Paraglide — handleAuth session guard)
│   ├── app.html             # HTML template
│   └── app.d.ts             # SvelteKit ambient types
├── static/                  # Static assets
├── vite.config.ts           # Vite + Vitest + Tailwind + Paraglide
├── tsconfig.json
└── package.json
```

---

## Routing

The application uses four disjoint route subtrees — capitalized to avoid colliding with lowercase domain routes: **live**, **Builder**, **Configure**, and **Settings**. Settings renders inside the root `AppShell` (same as live routes). Builder and (where applicable) Configure mode are URL-driven (not `sessionStorage`), so state is shareable, deep-linkable, and SSR-friendly.

### Route tree

| Surface                                                              | Route                                              |
| -------------------------------------------------------------------- | -------------------------------------------------- |
| Live dashboard                                                       | `/`                                                |
| Login + held-login steps                                             | `/Login`                                           |
| Password reset / invite acceptance                                   | `/ResetPassword`                                   |
| OAuth consent (app + MCP)                                            | `/OAuthConsent`                                    |
| Live domain overview                                                 | `/{domain}`                                        |
| Live doctype table                                                   | `/{domain}/{doctype}`                              |
| Live doctype show (full-page view)                                   | `/{domain}/{doctype}/{id}`                         |
| Builder landing (draft list)                                         | `/Builder`                                         |
| Domain editor — overview tab                                         | `/Builder/{draftDomain}/overview`                  |
| Domain editor — doctypes tab                                         | `/Builder/{draftDomain}/doctypes`                  |
| Domain editor — editors tab                                          | `/Builder/{draftDomain}/editors`                   |
| Domain editor — grants tab                                           | `/Builder/{draftDomain}/grants`                    |
| Domain editor — check tab (draft-only)                               | `/Builder/{draftDomain}/check`                     |
| Doctype editor — fields tab                                          | `/Builder/{draftDomain}/{doctype}/fields`          |
| Doctype editor — logic tab + field `qty`                             | `/Builder/{draftDomain}/{doctype}/logic?field=qty` |
| Builder preview (wildcard seam)                                      | `/Builder/{draftDomain}/preview/[...path]`         |
| Configure landing (redirects to domains)                             | `/Configure`                                       |
| Configure — domain list                                              | `/Configure/domains`                               |
| Published config detail — overview                                   | `/Configure/domains/{slug}/overview`               |
| Published config detail — doctypes                                   | `/Configure/domains/{slug}/doctypes`               |
| Published config detail — editors                                    | `/Configure/domains/{slug}/editors`                |
| Published config detail — grants                                     | `/Configure/domains/{slug}/grants`                 |
| Published per-doctype detail                                         | `/Configure/domains/{slug}/doctypes/{dt}`          |
| Configure — apps (OAuth applications)                                | `/Configure/apps`                                  |
| Configure — new app wizard (setup, permissions, review, credentials) | `/Configure/apps/new/{step}`                       |
| App detail — overview                                                | `/Configure/apps/{slug}/overview`                  |
| App detail — settings                                                | `/Configure/apps/{slug}/settings`                  |
| App detail — deploy                                                  | `/Configure/apps/{slug}/deploy`                    |
| App detail — grants                                                  | `/Configure/apps/{slug}/grants`                    |
| Configure — roles list                                               | `/Configure/access/roles`                          |
| Configure — role detail (details)                                    | `/Configure/access/roles/{id}/details`             |
| Configure — role detail (members)                                    | `/Configure/access/roles/{id}/members`             |
| Configure — role detail (grants)                                     | `/Configure/access/roles/{id}/grants`              |
| Configure — assignments matrix                                       | `/Configure/access/assignments`                    |
| Configure — accounts (admin)                                         | `/Configure/access/accounts`                       |
| Configure — currencies (admin)                                       | `/Configure/currencies`                            |
| Configure — audit log                                                | `/Configure/audit`                                 |
| Configure — index status (admin)                                     | `/Configure/platform/indexes`                      |
| Configure — artifacts (admin)                                        | `/Configure/platform/artifacts`                    |
| Settings — personal preferences                                      | `/Settings`                                        |
| Settings — API keys                                                  | `/Settings/api-keys`                               |
| Settings — webhooks                                                  | `/Settings/webhooks`                               |

- **Domain editor tabs** (`overview`, `doctypes`, `grants`, `check`) are explicit static segments to avoid ambiguity with `[doctype]` dynamic routes — they cannot collapse into a single `[[tab]]` route. Instead, a route group `(editor)` wraps the tab routes with a shared `+layout.svelte` that renders `DomainEditor` once, so the component persists across tab switches (no remount, no domain-doc re-fetch, no flicker). The active tab is derived from the URL in `(editor)/+layout.ts`. The `check` tab is draft-only (hidden on live domains); the published config detail under `/Configure/domains/{slug}` exposes only `overview` / `doctypes` / `editors` / `grants`, hosted the same way: a route group `(tabs)` wraps those tab routes with a shared `+layout.svelte` that renders `DomainEditor` once (the per-doctype `[dt]` route stays outside the group), and a bare `/Configure/domains/{slug}` redirects to `./overview`.
- **Doctype editor tabs** use an optional `[[tab]]` param: `/Builder/{draftDomain}/{doctype}` redirects to `./fields`, and an empty or unknown tab value redirects to the default `fields` tab (canonical URL) instead of 404. Valid tabs: `general`, `fields`, `children`, `actions`, `logic`, `views` — the Configure shell opens the editor on `general` (its component default).
- **Published per-doctype detail** (`/Configure/domains/{slug}/doctypes/{dt}`) renders `DoctypeEditor` read-only with `allowMetadataEdit={can('core.DocType', 'update')}`: shape changes need a draft, but the General tab's presentation metadata (label, plural label, icon, color, description) saves in place through a metadata-only PUT — see [`configure-editors.md`](configure-editors.md) → Save, draft, drop. The defined `core.DocumentView` templates load read-only so the Views tab reflects reality, and an `Open records` header link to the doctype's workspace surface (`/{domain}/{doctype}`) — the workspace sidebar skips the `core` domain, so this link is how system records (e.g. `core.Currency`) are reached from the config side.
- **Builder preview** is a wildcard route (`/Builder/{draftDomain}/preview/[...path]`) — the entry page that moves the user from the Builder shell to the live application scoped to a draft dataset. It issues a preview capability token (`POST /Api/core/Domain/:id/preview-session`), stages it in the `previewSession` store (mirrored into the `facet.preview-session` cookie so a reload survives), then navigates to `/{draftDomain}` — a captured `path` wildcard is forwarded, so a deep link lands on the same live document. The live routes then render under `RBAC::PreviewEnforcer` and the `PreviewBanner`. Clicking the top bar's `Preview` segment navigates to `/Builder/{draftDomain}/preview/`; clicking `Build` returns to `overview` (or the prior tab if already in build mode).
- **Configure shell** (`/Configure/*`) bypasses `AppShell` entirely and renders its own sidebar + top bar (`routes/Configure/+layout.svelte`). The configure sidebar reuses the shared `SidebarShell` chrome (brand, collapse toggle, account footer) just like the live and builder shells, but supplies its own `nav` content with five sections: CONFIGURE (`Domains`), APPLICATIONS (`Apps`), ACCESS (`Roles`, `Assignments`, `Accounts`), SYSTEM (`Currency`, `Audit log`), PLATFORM (`Indexes`, `Artifacts`). The PLATFORM section holds operator-level technical surfaces and renders only when `can('*.*', 'read')` — the client-side admin marker; the backend re-checks (see [`platform.md`](platform.md)). It forwards the role store's active/available roles and wins `onSwitchRole` to `SidebarShell`, so the Switch Role submenu works here too (falling back to the server snapshot before hydration). Its top bar renders only controls with a working behaviour: the bell through the shared `bellProps()` (see [`notifications.md`](notifications.md) → Bell wiring), the search trigger, which opens the shell's own command palette (see [`command-palette.md`](command-palette.md)), and the assistant pill, which toggles the workspace assistant window when the account may use it (`me.assistant.access`). The window itself is mounted at the root layout (`AssistantHost`), so it floats over this shell like it does over the live app.
- **Configure access tabs** (`/Configure/access/roles/{id}/details`, `…/members`, `…/grants`) are sibling routes under a single role-detail layout (`routes/Configure/access/roles/{id}/+layout.svelte`) that owns the Details/Members/Grants tab strip and renders the active tab's child page. A bare `/Configure/access/roles/{id}` redirects to `details` (the default tab) via a `redirect()` in `+layout.ts`.
- **Configure accounts** (`/Configure/access/accounts`) is the admin surface over `iam.Account` — the standard tab-less `ListView` (`showTabs={false}`) with the shared filter toolbar, trash mode, and QuickView peek. Create and edit are the standard document form routes; the credential bootstrap actions (invite, temporary password, MFA reset) live on the account show page (see [`access-accounts.md`](access-accounts.md)).
- **Configure currencies** (`/Configure/currencies`) is the admin surface over `core.Currency` — the standard tab-less `ListView` with the shared filter toolbar, trash mode, and QuickView peek, mirroring the accounts page. The New button targets `/core/Currency/new` and the peek's Edit affordance targets `/core/Currency/{id}/edit`, both carrying a `?from=` return path so a save lands back in Configure instead of the app-domain show page (see `DocumentForm`). Boolean columns (`active`, `favorite`) seed with `editable: true`, so the listing offers inline green/red toggles gated on the viewer's `update` permission (see [`../backend/collection-view.md`](../backend/collection-view.md) → Inline-edit columns). All document surfaces render through the seeded `core.DocumentView` templates (see `data/seeds/core.DocumentView/documents.yml`); the workspace sidebar skips the `core` domain, so this page is how system currency rows are reached application-side.
- **SSO on the login page**: `routes/Login/+page.svelte` fetches the public `GET /Api/iam/oidc/providers` and renders one button per enabled provider, each a plain anchor to `/auth/oidc/{name}` (the backend starts the flow with a 302 — see [`../backend/oidc.md`](../backend/oidc.md)). A denial redirect renders a generic message on `error=oidc_denied`; the reason stays in the audit log. A failed provider read yields an empty list and never blocks the password form.
- **Live domain overview** at `/{domain}` renders `DomainDashboard.svelte` — a landing page with four sections: a header, pinned collection views (read from the `pinnedCollectionViews` account setting), recently-viewed documents (localStorage-backed `recentDocuments.svelte.ts`), and the doctype list with per-doctype record counts and saved-view sub-links. The pinned-view cards and the saved-view sub-links both read the same per-doctype `core.CollectionView` children list (cached by `collectionViewsCache`), so a dashboard view and a doctype listing visit share one round-trip. Doctype counts reuse the sidebar's `navCounts.svelte` store so the dashboard and the sidebar badges stay in sync.
- **Live doctype listing** at `/{domain}/{doctype}` renders `ListView` — the saved-view tab strip, the table surface, and the manual listing state. The manual sort, filters, search term, and rows-per-page persist in localStorage per collection view (`collectionView/viewState.ts`), so a return visit reopens the listing as the user left it; a `?filters[...]` deep link still wins over the stored map. See [`list-view.md`](list-view.md).
- **Selected field** in the doctype editor is tracked via the `?field=` query param. Every URL-backed UI state write goes through `setSearchParams` (`lib/utils/searchParams.ts`), which patches the query and navigates with `goto(url, { replaceState: true, noScroll: true, keepFocus: true })` — a history-replacing navigation, so `page.url.searchParams` readers update reactively and no history entry is added. It must stay a real navigation: SvelteKit pins `page.url` to the rendered page across a bare `history.replaceState` (both `history.replaceState` and `$app/navigation`'s `replaceState` update `page.state` only), so a shallow write would silently strand every `$derived` that reads the params. Load functions that read the touched params re-run per SvelteKit's dependency tracking; the loads on the surfaces using this helper read no params, so toggles cost one `__data.json` round trip and no load re-runs.
- **Session/auth guard** lives in `hooks.server.ts` (`handleAuth`), which runs the `/Api/iam/me` check and login redirect on every server request. The root layout `load` reads **no** `url`/`params` so it does not re-run on client-side navigation — this is what keeps tab switches flicker-free (session revalidation happens on full loads; `apiFetch` handles token refresh per API call). `App.Locals` carries the session; `+layout.server.ts` forwards it to `+layout.ts`, which hydrates the permission/expiry stores and builds the nav model.
- **Post-login redirect** is carried in the URL itself, not in client storage. When an unauthenticated user is sent to `/Login`, `handleAuth` embeds the requested path + query as a `redirectTo` query param on the redirect to `/Login` (via `buildLoginRedirect`). This is necessary because the server hook has no access to the browser's `sessionStorage`; a server-side write to client storage would silently no-op. The target is guarded: paths that are not `/`-prefixed or that echo back to `/Login` are dropped to `/`. The login page (`routes/Login/+page.svelte`) reads `page.url.searchParams.get('redirectTo')` after a successful sign-in and `goto`s to it (with `invalidateAll`); when no valid target is present it falls back to `goto('/', { invalidateAll: true })`.
- **Held-login branches** (`src/lib/loginFlow.ts`, pure + Vitest-tested): a `POST /Api/iam/login` response decodes to `tokens`, `mfa_challenge` (`{mfa, challenge_id}`), `must_change_password` (`{must_change_password, change_token}`), or `mfa_enroll` (`{mfa_enroll_required, enroll_token, secret, otpauth_uri}`). The login page renders the matching step: `ForcedChangeScreen` (posts `/Api/iam/change-password` with the `change_token`, then re-runs login), `TwoFactorScreen` (posts `/Api/iam/challenge`), or `TotpRegistrationScreen` (posts `/Api/iam/mfa/enroll/verify`). After any token-emitting response, `GET /Api/iam/me` decides the `preferred`-mode enrollment prompt: `mfa_enforcement === 'preferred' && !mfa_enabled` shows `TotpRegistrationScreen` as a dismissible interstitial ("Skip for now") before navigation — dismissal persists nothing, so the prompt reappears on the next login.
- **Public auth surfaces** in `handleAuth` (`hooks.server.ts`): `/Login` and `/ResetPassword` skip the unauthenticated login redirect. `/ResetPassword?token=…` posts to `/Api/iam/password-reset/confirm`; when the confirm emits a session (first-credential invite accepted) it hydrates and runs the enrollment prompt, otherwise it redirects to `/Login?reset=ok` (the login page shows a "Password updated" notice). A 401 (unknown/expired link) switches the page to the request form (`PasswordResetScreen`).
- The root layout owns `AppShell` and derives `isBuilderRoute` from `page.url.pathname.startsWith('/Builder')` and `isConfigureRoute` from `.startsWith('/Configure')`. The `navState.svelte.ts` store bridges the sidebar domain model (live vs draft) between the root layout and the Builder subtree; `builderDraft.svelte.ts` bridges the draft snapshot (id, name, isDraft, checkIssueCount, publishName, check) between the Builder `(editor)` subtree and the top-bar `BuilderModeBar` rendered by the root layout.
- The assistant is a floating, draggable, collapsible window mounted at the root layout when `assistantOpen` is true. Both surfaces — `FloatingAssistant.svelte` (Builder) and `WorkspaceAssistant.svelte` (live routes) — render the same `AssistantWindow.svelte` shell (`features/chat/`), so the window behaves identically everywhere. Open state persists in `sessionStorage` under `facet.assistant.open`; collapsed, maximized, and window size persist under `facet.assistant.*`; window position is NOT persisted (reset to the default inset each session). `assistantWindowState.ts` (also in `features/chat/`) owns the read/write helpers. The previous `AssistantPanel.svelte` (right-side fixed rail built into `AppShell`'s grid) is removed.
- **Global error page** (`routes/+error.svelte`) picks its kind from structured data, never from message text (audit 25). `page.status` carries the failing HTTP status on SSR responses, hydration, and client navigations; `page.error` is only the `{ message }` body and never carries a status. Route loads keep the backend status when they turn a `DataSourceError` into a SvelteKit error (`rethrowLoadError` in `lib/doctype/loadDoctypeDef.ts`), so a backend 500 renders as a server error and a 410 tombstone renders the deleted page. A backend 401 never reaches the error page — `handleAuth` turns it into the login redirect (or the Builder redirect when a preview session was active); see Auth and `apiFetch`. The classifier (`lib/errorPage.ts`, Vitest-tested) keeps the `/not found/i` message check only as the last resort for errors that carry no usable status. On the deleted page, a failed route of `/{domain}/{doctype}/{id}` or its `/edit` sibling gets a secondary History action pointing at the document's audit trail (`documentHistoryParams` in the same module; a tombstone keeps its trail readable). The router preserves route id + params when a load error renders the error page, and params are raw (still-encoded) segments — exactly what `resolve()` substitutes; without that context (unmatched route, redirect loop) the action stays hidden.
- **Live doctype show** (`/{domain}/{doctype}/{id}`) renders the Actions menu with the named actions the role holds. An action with required arguments opens the args prompt (`ActionArgsDialog` in `features/document-view/`) instead of firing the action. The prompt maps each argument type to the matching form control — `ActionArgDefinition` mirrors `FieldDefinition`, so the mapping is the DVT input mapping minus the template-node layer — checks required/min/max client-side, and submits the collected args with the action call; the backend 422 stays the final guard. A failed action keeps the prompt open and renders the backend's `details[].message`; the no-args path shows the same details in a page `AlertBanner` and an error toast. An argument type with no input renderer is left out of the prompt (its declared default applies); when a required argument has no renderer, the menu item stays disabled with the "(args required)" suffix. The disabled-menu-item behaviour for renderable args is gone.

---

## Public API

### NPM scripts

| Script                 | Command                           | Purpose                                                                        |
| ---------------------- | --------------------------------- | ------------------------------------------------------------------------------ |
| `pnpm dev`             | `vite dev`                        | Start dev server with HMR                                                      |
| `pnpm build`           | `vite build`                      | Production build                                                               |
| `pnpm preview`         | `vite preview`                    | Preview production build locally                                               |
| `pnpm test:unit`       | `vitest`                          | Run the test suite (server pure-logic + Storybook component tests, watch mode) |
| `pnpm test`            | `vitest --run`                    | Run the full test suite once (no watch)                                        |
| `pnpm storybook`       | `storybook dev -p 6006`           | Storybook dev server                                                           |
| `pnpm build-storybook` | `storybook build`                 | Static Storybook build                                                         |
| `pnpm check`           | `svelte-kit sync && svelte-check` | Type-check the project                                                         |
| `pnpm format`          | `prettier --write .`              | Format all files                                                               |
| `pnpm lint`            | `prettier --check . && eslint`    | Check formatting, then lint (`--max-warnings=0`)                               |
| `pnpm lint:eslint`     | `eslint --max-warnings=0 .`       | ESLint only (skip the prettier pass)                                           |

### Lint — ESLint

ESLint gates dead code and mechanical hazards; Prettier owns formatting (`eslint-config-prettier` runs last so no rule fights it). Config lives in `eslint.config.js` — flat config, three layers: `@eslint/js` recommended, `typescript-eslint` recommended, `eslint-plugin-svelte` recommended. `pnpm lint` runs Prettier first, then ESLint with `--max-warnings=0` — zero warnings is part of the gate. Both passes skip `example/` — the design reference mockups are static HTML, kept verbatim (`.prettierignore`, `eslint.config.js`).

Key rules of engagement:

- `@typescript-eslint/no-unused-vars` errors on everything, with a `_` prefix escape hatch (`_arg`, `_canvas`). Unused `$props()` members are renamed to `_name`, not removed — the prop stays part of the component API.
- `no-undef` is off inside `<script lang="ts">` (TS types like `RequestInit` are not runtime globals); TypeScript coverage comes from `pnpm check`.
- Two svelte rules are off, each with a justification comment in the config: `no-unused-svelte-ignore` (compiler-warning ignores are invisible to ESLint) and `prefer-svelte-reactivity` (see the `untrack` note below).

**Navigation goes through `resolve()`.** Every `goto()` and internal `<a href>` calls `resolve(routeId, params)` from `$app/paths` with the real SvelteKit route id — route groups and matchers included (`/Builder/[draftDomain]/(editor)/overview`, `/[domain=notApi]/[doctype]/[id]`). `pnpm check` validates each id and its params against the generated route manifest, so moving or deleting a route fails type-check instead of breaking links silently. `svelte/no-navigation-without-resolve` enforces this syntactically; it only accepts a literal `resolve()` call (or a `const` initialized to one) at the navigation call — ESLint has no type information, so a value that crosses a component prop, a model, or a `URL` object cannot pass. Conventions for the grey zones:

- Backend and external URLs (artifact/download endpoints, `/auth/oidc/{name}` starts, user-supplied `url` values) keep their href and carry `external` in `rel`.
- Where a producer builds a model href, build it with `resolve()` at the source; the leaf renderer (e.g. `Button`, `Topbar` crumbs) carries a one-line `eslint-disable-next-line` with the reason. Keep this class small.
- Genuinely dynamic targets — the current-page query rewrite in `lib/utils/searchParams.ts` and the login `redirectTo` — are the only non-leaf disables.
- In HTML comments the directive must stay on ONE line (`<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- reason -->`); a wrapped description breaks the directive recognition.

**Reactive collections and `untrack`.** `SvelteMap` / `SvelteSet` track every read and dirty on every write. A guard collection that an effect both reads (`has`) and writes (`add`) re-runs that effect — the cleanup cancels the in-flight work and the second run sees the key as started, so the work never happens. Where a collection is bookkeeping inside an `$effect` (a fetch-dedupe guard), wrap its reads and writes in `untrack(() => …)`, or use a plain `Map` / `Set` — plain collections do not subscribe on read and do not trigger on write.

**Never untrack a `$derived` body.** A derivation that tracks nothing evaluates once and never re-runs, so its result freezes at mount. A scratch map inside `$derived.by` must therefore be a plain `Map` / `Set`: plain reads and writes cannot self-dirty the derivation, no `untrack` is needed, and the derivation keeps tracking its real inputs (see `MonthGrid.svelte` → `chipsPerCell`). Never use `SvelteMap` / `SvelteSet` there — their tracked reads make interleaved get/set self-dirty the derivation. Render state stays in plain `$state`.

### CSS framework

Tailwind CSS v4 is configured via the `@tailwindcss/vite` plugin in `vite.config.ts`. No separate `tailwind.config` file is needed — Tailwind v4 uses CSS-based configuration.

### Internationalization

Paraglide JS manages i18n. Messages live in `messages/{locale}.json` — one flat file per locale, snake_case keys, `en` is the base locale. The runtime is generated into `src/lib/paraglide/` (gitignored); after editing a message file, recompile with `pnpm exec paraglide-js compile --project ./project.inlang --outdir ./src/lib/paraglide` (the Vite plugin also recompiles on `pnpm dev` / `pnpm build`). A fresh clone starts with no generated output. `pnpm check` resolves the generated `.d.ts` files directly, so it fails until the compile command runs; CI runs it right after `pnpm install`. The compile step also writes generated files into `project.inlang/` (`.meta.json`, `README.md`). `project.inlang/.gitignore` keeps only `settings.json` under version control; `.prettierignore` mirrors that rule, so Prettier checks `settings.json` only. Locale routing and `resolve` helpers are set up in `src/hooks.ts` and `src/hooks.server.ts`.

Two locales ship: `en` (base) and `fr` — `project.inlang/settings.json` lists both. `fr.json` mirrors `en.json` key-for-key, in the same order, so a diff shows what moved. When you add or change a key in `en.json`, add the matching `fr` entry in the same position; Paraglide falls back to the base locale for a missing key, but parity is the review bar. French copy follows the project typography: straight apostrophes, U+00A0 (NBSP) before `: ; ? !` and inside « » guillemets, and the source's `…` `—` `·` characters preserved (placeholder and character parity are script-checkable — see `frontend/tmp/validate_fr.cjs`). The language selector on the Settings page and the `core.language` backend allowlist (`ALLOWED_LANGUAGES` in `src/settings/keys.cr`) are the single source of truth for the shipped list — update both plus `settings.json` when a locale joins.

**Every new user-visible UI string must use a message key.** Do not add hardcoded English literals to production markup or to user-facing TS fallbacks. This stops the extraction debt from growing while the staged sweep moves the existing strings into the catalogue.

Usage pattern — import the generated messages and call them directly. No `t()` wrapper and no `$lib/i18n` facade: direct `m.*` imports keep one idiom, keep IDE tooling working, and keep tree-shaking.

```svelte
<script lang="ts">
	import * as m from '$lib/paraglide/messages';
</script>

<svelte:head>
	<title>{m.settings_page_title()}</title>
</svelte:head>

<h1>{m.settings_title()}</h1>
<Select label={m.settings_language_label()} helper={m.settings_language_helper()} … />
```

Key grammar — `<area>_<element>[_<variant>]`, two to four lowercase snake segments. Keys must be valid JavaScript identifiers: no dots, no dashes.

| Rule                                                                                                                                                                        | Examples                                                        |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Area first: `common`, `auth`, `nav`, `errors`, `settings`, `configure_*`, `doc_*` (live document surfaces), `builder`, `assistant`, `apps`, `audit`                         | `common_delete`, `configure_domains_title`, `doc_history_title` |
| Element uses the component's own word for the slot                                                                                                                          | `login_email_label`, `login_email_placeholder`                  |
| Suffix names the slot when useful: `_title`, `_label`, `_helper`, `_placeholder`, `_button`, `_error`, `_empty`, `_confirm`, `_toast`, `_aria`, `_page_title` (browser tab) | `settings_timezone_helper`, `errors_404_page_title`             |
| Whole sentences are one message. Never concatenate keys and never split a sentence across markup — word order differs per locale later                                      | `doc_deleted_toast` = "This document has been deleted."         |
| Dynamic data is a `{param}`; user content (display names, ids, doctype names) stays a param, never part of the key                                                          | `errors_doctype_not_found({ name })`                            |
| Numbers, dates, and enums stored in the database are data, not messages                                                                                                     | timezone names, role names, currency codes                      |

Paraglide generates typed functions from the `{param}`s, so a wrong or missing param fails `pnpm check`.

What gets keys — and what stays a literal:

| Gets keys                                                                                                                                               | Stays literal                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Static text in production markup: headings, labels, helpers, buttons, placeholders, empty states, toasts, confirm dialogs, `aria-label`s, error banners | Document content, `display_name`s, doctype/domain/role/app names — user data                              |
| Browser tab titles                                                                                                                                      | Enum values stored in the database, field keys, API names                                                 |
| User-visible fallback strings in TS: `apiErrorMessage` fallbacks, auth errors, route-load `error(404, …)` messages                                      | Developer-facing text: console logs, `MockDataSource` and fixture-loader messages, Storybook-only strings |
| Server-rendered strings in `hooks.server.ts` and server loads (they run under the Paraglide server middleware)                                          | Story sample props (stories pass sample content; component chrome comes from keys)                        |

Stories need no separate translation: story assertions run under the base locale, so existing `getByText('Cancel')` assertions keep passing. Specs that assert a string the production code now emits through a key switch to asserting `m.that_key()` — one source of truth. A story that must prove locale switching calls `setLocale` from `$lib/paraglide/runtime` and asserts the `fr` text.

**Backend validation details render only through the seam renderer.** `renderValidationError` (`src/lib/datasource/validationMessages.ts`) is the one place that turns a `ValidationError` into text. When a template exists for the `code` (a `validation_*` key) and the params it needs are present, it renders from the catalogue; otherwise it falls back to the pasted backend `message`. `joinFieldErrors` and `bannerError` route through it. Never parse or render `details[].message` directly: the backend keeps its English text for consumers that do not render it (MCP, webhooks, logs), and the UI copy comes from the catalogue.

### Testing strategy

The frontend test suite has two layers. There is no separate component-test layer — component behaviour is asserted through Storybook play functions, so stories are both the visual catalogue and the automated component tests.

- **Pure-logic tests** (`*.test.ts` / `*.spec.ts`, excluding `*.svelte.spec.ts`) — datasource, nav model, RBAC model, colour utils, template types. Run in Vitest's `server` project (`environment: 'node'`). Fast, isolated, no browser.
- **Component tests** — every `*.stories.svelte` story is a test. Run in Vitest's `storybook` project via `@storybook/addon-vitest` with a single headless Chromium. Each story renders in its own iframe, so tests are naturally isolated (no shared-`document.body` leakage). Add a `play` function to a `<Story>` to assert behaviour:

```svelte
<script lang="ts" module>
  import { defineMeta } from '@storybook/addon-svelte-csf';
  import { expect, within, userEvent, fn } from 'storybook/test';
  import Toggle from './Toggle.svelte';

  const { Story } = defineMeta({
    component: Toggle,
    args: { onchange: fn() }
  });
</script>

<Story
  name="TogglesOnClick"
  args={{ label: 'Toggle me' }}
  play={async ({ canvasElement, args }) => {
    const canvas = within(canvasElement);
    const sw = canvas.getByRole('switch');
    await expect(sw).toHaveAttribute('aria-checked', 'false');
    await userEvent.click(sw);
    await expect(sw).toHaveAttribute('aria-checked', 'true');
    await expect(args.onchange).toHaveBeenCalled();
  }}
/>
```

`expect`, `within`, `userEvent`, and `fn` come from the `storybook/test` package (re-exports `@testing-library/dom`, `@testing-library/user-event`, and Vitest's `expect`). `within(canvasElement)` yields the standard Testing Library queries (`getByText`, `getByRole`, `getByLabelText`, `getByPlaceholderText`, …).

- **Storybook `play` conventions**
  - Assert observable behaviour (visible text, ARIA states, callbacks fired), not internal CSS classes.
  - Don't `userEvent.click()` a `disabled` element — it has `pointer-events: none`; assert `toBeDisabled()` instead.
  - A story that closes a Bits UI modal can leave `pointer-events: none` on `<body>` for a tick — the cleanup timer is async, and pointer-events is inherited, so the next story's first pointer interaction fails with `Unable to perform pointer interaction as the element has \`pointer-events: none\``(the asserted target computes the inherited value). A global loader in `frontend/.storybook/preview.ts` waits the restore out before every story renders. If a play still hits it (a modal closing mid-play), retry the pointer interaction inside`waitFor`— see`ApiKeyManager.stories.svelte`and`DvtInputLongtext.stories.svelte`.
  - Avoid testing portalled dropdown content (Bits UI `Combobox.Content`, `Select` listbox) through `play` — these are flaky across iframes. Cover them visually in stories and leave interaction to manual review.
  - Accessibility runs in `error` mode (see `frontend/.storybook/preview.ts`): every story runs an axe scan and a violation fails that story's test. Pre-existing violations carry an explicit meta-level `a11y: { test: 'todo' }` override in `*.stories.svelte` (grep for `test: 'todo'`) — clear those starting with the primitives (`src/lib/components/primitives/`), then the features; when the last override is gone, remove the mechanism comment in `preview.ts`.
- **E2E a11y smoke** — `e2e/tests/smoke.e2e.ts` runs an `@axe-core/playwright` scan of the signed-in dashboard and fails on `critical` violations (audit 22).
- **E2E** — browser journeys against the real stack live in the top-level [`e2e/`](../../e2e/README.md) package (`dockerized Playwright stacks with Caddy, backend, PostgreSQL and Redis; one scenario file = one throwaway stack`). This `frontend/` package keeps no Playwright config or script; the `playwright`/`@playwright/test` devDependencies stay only because `@vitest/browser-playwright` needs them as its browser provider.

### Component development

Storybook is configured with the following addons:

- `@storybook/addon-svelte-csf` — Svelte 5 runes support in stories
- `@chromatic-com/storybook` — visual regression testing
- `@storybook/addon-vitest` — runs every story as a Vitest test (the `storybook` project); `play` functions assert component behaviour
- `@storybook/addon-a11y` — accessibility audits in `error` mode: a violation fails its story; the known backlog carries per-meta `test: 'todo'` overrides
- `@storybook/addon-docs` — auto-generated documentation

Stories are co-located with components using the `*.stories.svelte` convention.

#### Snippet props in stories — addon-svelte-csf v5 patterns

Components with `{#snippet}` props (like `children`, `header`, `footer`) cannot receive them via `args` — `args` expects `() => string` functions, but `{@render}` requires actual Svelte `Snippet` objects. You must pass snippets inline inside `<Story>`.

##### Rule 1: Use `template` for full control

When you need to wrap the component in a container (for positioning, sizing, etc.), or render multiple components, use `{#snippet template()}`. This snippet is a **full render override** — the addon does **not** auto-instantiate the meta component. You control the entire rendered tree.

```svelte
<Story name="MyStory">
	{#snippet template()}
		<div style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;">
			<MyComponent someProp>
				{#snippet children()}
					<p>Body content</p>
				{/snippet}
			</MyComponent>
		</div>
	{/snippet}
</Story>
```

`template` is the **only** pattern that works when you need a wrapper div, custom positioning, or any structure around the component.

##### Do NOT use `template` for simple components

Components with only plain props (no snippet props, no intrinsic height issues) should use the simple `args` pattern — the addon auto-instantiates the component and passes `args` directly. The `template` wrapper is only needed when you need a container or custom structure.

```svelte
<Story name="SimpleCard" args={{ title: 'Hello', variant: 'danger' }} />
```

##### DO NOT use `children` as the outer snippet

`{#snippet children()}` on `<Story>` is interpreted as the meta component's `children` prop. The addon auto-instantiates `component` from `defineMeta` and injects your snippet as its content. This creates **two** component instances (one from the addon, one you placed inside) and buries your real content inside the addon's shell — producing an invisible or broken story.

##### Fullscreen layout and zero-height components

The preview is configured with `layout: fullscreen`, which wraps the story in a flex container that collapses to `height: 0` when the component has no intrinsic height (padding/margin alone don't count). Components like cards, notices, and panels that only use border and padding for their dimensions will render invisibly.

**Fix:** use the `template` snippet wrapper with a `min-height`:

```svelte
<Story name="MyCard">
	{#snippet template()}
		<div style="min-height:200px;padding:24px">
			<MyCard />
		</div>
	{/snippet}
</Story>
```

The `min-height` gives the flex parent enough room. `padding` is added so the card isn't flush against the viewport edge.

This also applies to `position: absolute` components (like `QuickView`) that require a `position: relative` container with explicit height — the same `template` wrapper handles it.

##### Story args with template

`args` in `<Story args={{...}}>` is only used for the Controls panel in `template` mode — it doesn't automatically bind to the component. To make controls work, pass args explicitly:

```svelte
<Story name="MyStory" args={{ open: true }}>
	{#snippet template(args)}
		<MyComponent open={args.open}>
			{#snippet children()}<p>Content</p>{/snippet}
		</MyComponent>
	{/snippet}
</Story>
```

##### Null args crash the story-source emitter

A `template` snippet that references an arg whose value is `null` crashes
the addon's story-source emitter (`valueToString` in `emit-code.js` reads
a snippet symbol off the value; `typeof null === 'object'`). The throw
happens inside a render effect and kills the story's reactive updates, so
play assertions fail against stale DOM. Hardcode the null in the template
(`app={null}`) and keep the non-null args referenced via `args.*` — see
`SetupForm.stories.svelte` → `ContinueSubmitsFreshDraftSlug`.

##### `play` must precede snippet children

On `<Story>`, the `play` prop is silently dropped when it appears **after** a `{#snippet ...}` block in the tag. The story still registers and renders, and the test "passes" — the play function just never runs, so its assertions never execute. Always declare `play` before any snippet children:

```svelte
<Story name="MyStory" args={{ open: true }} play={async ({ canvasElement }) => {
	// assertions here
}}>
	{#snippet template(args)}
		<MyComponent open={args.open} />
	{/snippet}
</Story>
```

A test that passes in well under its expected sleep/render time is the tell-tale sign of a dropped `play`.

### Component directory structure

Components follow one placement rule: **a feature-free widget is a primitive, a component owned by one product feature lives in that feature's folder.** The folder path maps 1:1 to the Storybook title:

| Directory                 | Storybook title prefix              | Example                                                                                |
| ------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------- |
| `primitives/actions/`     | `Components/Primitives/Actions/`    | `Button`, `IconButton`, `DropdownMenu`                                                 |
| `primitives/data/`        | `Components/Primitives/Data/`       | `Badge`, `Capsule`, `Money`, `ListView`, `FieldValue`                                  |
| `primitives/content/`     | `Components/Primitives/Content/`    | `Avatar`, `Markdown`, `DoctypeHeader`                                                  |
| `primitives/forms/`       | `Components/Primitives/Forms/`      | `Input`, `Select`, `Toggle`, `StringListEditor`                                        |
| `primitives/navigation/`  | `Components/Primitives/Navigation/` | `Tabs`, `Pagination`, `Link`, `FilterBar`                                              |
| `primitives/surfaces/`    | `Components/Primitives/Surfaces/`   | `Panel`, `AppShell`, `Topbar`, `QuickView`, `Can`                                      |
| `features/auth/`          | `Components/Features/Auth/`         | `LoginScreen`, `ConsentScreen`                                                         |
| `features/admin/`         | `Components/Features/Admin/`        | `RbacEditor`, `RoleAssignmentEditor`, `AccountCredentialActions`                       |
| `features/configure/`     | `Components/Features/Configure/`    | `DomainsList`, `DoctypeEditor`, `DomainEditor`, `AppGrantsEditor`                      |
| `features/chat/`          | `Components/Features/Chat/`         | `ChatThread`, `ChatInput`, `ChatPanel`, `AssistantWindow`, `WorkspaceAssistant`        |
| `features/audit/`         | `Components/Features/Audit/`        | `GlobalAuditTable`, `AuditDetail`, `History`                                           |
| `features/apps/`          | `Components/Features/Apps/`         | `CredentialsPanel`, `AppSettingsForm`, `DeployPanel`                                   |
| `features/platform/`      | `Components/Features/Platform/`     | `IndexesTable`, `OidcProviders`, `SystemSettingsForm`                                  |
| `features/dashboard/`     | `Components/Features/Dashboard/`    | `DomainDashboard`, `EditDomainDialog`                                                  |
| `features/builder/`       | `Components/Features/Builder/`      | `BuilderSidebar`, `FloatingAssistant`                                                  |
| `features/document-view/` | `Components/Features/DocumentView/` | `DvtLabel`, `DvtTabs`, `DvtValue`, `DocumentForm`, `SidecarPanel`, `SidecarDvtSurface` |
| `features/sidecar/`       | `Components/Features/Sidecar/`      | `CommentSurface`, `AttachmentSurface`                                                  |
| `features/importExport/`  | `Components/Features/ImportExport/` | `ImportExportActions`, `ExportMenu`, `ImportDialog`                                    |
| `features/settings/`      | `Components/Features/Settings/`     | `ApiKeyManager`, `McpEndpoints`                                                        |
| `features/welcome/`       | `Components/Features/Welcome/`      | `WelcomeTour`, `WelcomeArtPitch`, `WelcomeArtDomains`, `WelcomeArtBuilder`, `WelcomeArtAccess`, `WelcomeArtAudit`, `WelcomeArtIntegrate`, `WelcomeArtStart` |
| `schematic/`              | `Components/Schematic/`             | `DomainSchematic`                                                                      |

Components may import primitives freely; primitives must never import from `features/` (the only exception is `AppShell`, which mounts the builder chrome).

Each component lives in a single `.svelte` file with its CSS inline via a `<style>` tag. Test files (`*.svelte.spec.ts`) and story files (`*.stories.svelte`) are co-located alongside the component.

### DataSource — document data abstraction

`src/lib/datasource/` provides an abstraction layer over document collections.
A `DataSource` represents a doctype (e.g. `"hr.Employee"`) and offers two levels:

| **Collection** | `DataSource<T>` | `list()`, `create()` |
| **Document** | `DocumentRef<T>` | `show()`, `update()`, `delete()`, `action()`, `history()`, `rollback()`, `restore()` |
| **Navigation** | `DocumentRef<T>.children(relName) => DataSource<C>` | Returns a child-scoped `DataSource` |
| **Sidecars** | `DocumentRef<T>.sidecars(segment) => DataSource<C>` | Returns a sidecar-scoped `DataSource` — same URL shapes as `children` (`/Api/:domain/:doctype/:id/:segment[/:docId]`); the mock driver filters records by the sidecar's `column` reference pointing at the host instead of by `parent_id` |

#### Response shapes

All methods return data in the same `{ data, meta }` response shape as the Facet API:

- **Single document** (show, create, update, action): `{ data: T, meta: DocumentMeta }` where `DocumentMeta` has `{ id, mid, domain, doc_type, version, schema_version, created_at, updated_at }`.
- **List**: `{ data: Array<{ data: T, meta: DocumentMeta }>, meta: { count, more } }` — each item uses the same `{ data, meta }` response shape as single-document endpoints. The `meta` includes `id`, `domain`, `doc_type`, `version`, etc. `count` is the real number of matching rows from the page offset, truncated at 1000; `more` is `true` only when counting was truncated. Derive next-page presence from `data.length === itemsPerPage`, not from `more`.
- **Delete**: `Promise<void>`.

`list()` accepts an optional `aggregate: 'count'` mode that mirrors the backend's `?aggregate=count`. In count mode no rows are read — the response is `{ data: [], meta: { count, more } }` where `count`/`more` reflect the full filtered total capped at 1000 from offset 0. Used by the sidebar's lazy count loader (`navCounts.svelte.ts`'s `loadForDomain`, triggered by `NavPanel` when a domain becomes active) so the sidebar badges issue one cheap COUNT subquery per doctype in the active domain — never for domains the user has not opened. Import paths invalidate the cached counts: the doctype table's row import calls `invalidateCount` for the imported doctype, and the domain-bundle import calls `clearDomainCounts`; `NavPanel` re-fetches on the store's version counter.

`list()` also accepts `includeDeleted: true`, which appends `?deleted=true` — the backend's trash listing. Tombstones carry the retained pre-delete payload plus the surviving `display_name`/`meta`/timestamps, and the response shape is unchanged. Used by `ListView`'s trash mode (the `?deleted=` toggle on the doctype page); consumed together with `DocumentRef.restore()`, which POSTs `/Api/:domain/:doctype/:id/restore` and rejects with `DataSourceError` 409 when the document is not deleted (a safe no-op — the owner refreshes instead of retrying). Both are gated by the existing `update` RBAC action; `RestoreButton` renders disabled without it.

`history()` accepts `include: 'children'` in `HistoryParams`. The param appends `?include=children` — the backend's aggregate mode. The timeline merges the readable child documents' mutations with the parent's rows, newest first. Child rows carry `display_name`: the child document's label, kept on tombstones. Plain history leaves the field unset. Each child branch applies the child doctype's own read scope, so rows the caller cannot read stay absent — the call does not fail with 403. The `History` component turns this on with its `includeChildren` prop; it needs `parentDocType` to badge child rows, and `driver` to route their reverts to the child documents (see [`../backend/audit.md`](../backend/audit.md) → Aggregate history).

The `History` timeline also resolves the actor label. `actioner_id` is a bare account ULID for mutations made by a signed-in account, and a readable principal name (`system`, `system:rollback`, …) for machine callers. For ULID-shaped ids the component fetches `iam.Account` through the driver (one show per distinct id; the shared show cache dedupes) and renders `meta.display_name`, then the content `name`, then `email`. A failed lookup (no read grant, unknown id) falls back to the raw id, so the label never blocks the timeline. The global audit page's actor `Capsule` hydrates the same account through the same show cache.

Two implementations:

- **`DocumentDataSource`** — makes real HTTP calls to `{baseUrl}/Api/:domain/:doctype`. The response JSON is already in `{ data, meta }` format, so it's passed through directly.
- **`MockDataSource`** — in-memory store (ideal for Storybook and unit tests). Produces the same `{ data, meta }` shapes. Supports filtering (`__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`), sorting, pagination (`count`/`more`), child navigation, and custom action registration via `onAction()`.

#### Constructor convention

`MockDataSource` takes flat seed documents — `{ id, ...content }` — rather than the old nested `{ id, content: {...} }` format:

```typescript
const ds = new MockDataSource("hr", "Employee", [
  { id: "e1", name: "Alice", status: "active" },
  { id: "e2", name: "Bob", status: "inactive" },
]);

const list = await ds.list({ filters: { status__eq: "active" } });
// => { data: [{ data: { name: "Alice", status: "active" }, meta: { id: "e1", ... } }], meta: { count: 1, more: false } }

const doc = await ds.doc("e1").show();
// => { data: { name: "Alice", status: "active" }, meta: { id: "e1", mid: "e1", domain: "hr", doc_type: "Employee", version: 1, schema_version: 1, ... } }

await ds
  .doc("e1")
  .update({ set: [{ op: "replace", path: "/name", value: "Bob" }] });
await ds.doc("e1").action("promote", { level: 4 });
await ds.doc("e1").children("career_events").list();
```

`DocumentDataSource` uses the same API but talks to the real backend:

```typescript
const ds = new DocumentDataSource("hr", "Employee");
const list = await ds.list({ filters: { status__eq: "active" } });
// list.data  => [{ data: { status: "active", ... }, meta: { id: "hr.Employee.xxx", ... } }]
// list.meta  => { count: 47, more: false }
```

Both implement the same `DataSource` / `DocumentRef` interfaces, so components can accept either interchangeably — critical for Storybook composability.

#### Filter-value wire form (`filterParams.ts`)

Every client that emits the query-string filter form (`filters[key]=value`) serializes values through `serializeFilterValue` (`src/lib/datasource/filterParams.ts`): scalars keep their string form, arrays go out JSON-encoded. The backend decodes a `filters[...]` value that parses as a JSON array back into a real array (`HTTP::ListRequest.from_query`); scalar values keep the raw string form, so numeric-string comparisons are unchanged. Used by `DocumentDataSource` (list + history), `AuditSource`, `ArtifactsSource`, `IndexesSource`, and the assistant driver — all of whose routes parse through `ListRequest`, so the decode applies on every one. The same sources use it for the GET query string; the QUERY method carries arrays natively and needs no encoding.

#### Auth and `apiFetch`

`DocumentDataSource` always routes its HTTP calls through `apiFetch` (`src/lib/session.svelte.ts`), even when a custom `fetchFn` is supplied. This is what keeps token refresh and 401 recovery active in load functions: SvelteKit's `event.fetch` is forwarded as `apiFetch`'s `opts.fetch` (so relative URLs resolve during SSR and cookies are forwarded) without bypassing refresh. Passing `event.fetch` directly to `fetch()` would silently skip pre-emptive refresh and 401 recovery — that was the source of a navigation-after-token-expiry 401 bug.

`apiFetch` module state (`expiresAt`, the in-flight `refreshing` promise) is gated on the browser. On SSR it is shared across concurrent users, so writes are no-ops and pre-emptive refresh is skipped server-side; the 401-recovery path (which uses the request's own cookies) is the server-side fallback.

When a token refresh fails, the recovery differs by request side:

- **Browser**: `authFailure` sends the browser to `/Login?redirectTo=<path+query>`, built by `buildLoginRedirect` (`src/lib/loginRedirect.ts`). After sign-in the login page returns the user to the original path. The helper drops targets that are not `/`-prefixed, start with `//`, or point at `/Login`; a bad target falls back to `/`.
- **SSR**: `authFailure` cannot redirect (no `window`), so the load fails with a `DataSourceError(401)`. `handleAuth` (`hooks.server.ts`) catches a 401 that escapes any load and throws `redirect(303, buildLoginRedirect(...))` — an expired session shows the login page, not the 500 error page. For `__data.json` requests SvelteKit converts this redirect into a JSON payload that the client router follows.
- **Preview**: when `event.locals.previewSession` is set, a 401 means a dead preview capability token, not a dead session — the cookie session is still valid. The hook deletes the `facet.preview-session` cookie on the redirect response (a server-side `clearPreviewSession()` cannot touch `document.cookie`, so only this stops the dead token from being re-injected on the next request) and redirects to `/Builder/{draftId}`. A login redirect here would loop.

#### Role switching

The sidebar footer's **Switch Role** submenu (`SidebarShell.svelte`) lists the roles the account is assigned and lets them activate a different one. The submenu renders only when the account holds two or more assigned roles — with zero or one role the entry is hidden (there is nothing to switch to). `auth.svelte.ts`'s `switchActiveRole(role)` POSTs a role-bearing `/Api/iam/refresh` (`{ cookie: true, role }`) — the backend rotates the session and returns a new access token plus the target role's permission & scope manifests. On success, state hydration runs in two layers:

1. **Optimistic** (immediate): writes the new role / expiry / permissions / scopes into the module stores (`role.svelte.ts`, `permissions.svelte.ts`, `session.svelte.ts`) so the sidebar footer label and `<Can>` / `canScope()` gates flip instantly; clears the datasource client cache so no list filtered by the previous role is rendered.
2. **Authoritative** (`invalidateAll()`): re-runs the root layout load. `+layout.server.ts` re-fetches `/Api/iam/me` (which re-reads the just-rotated session) and `+layout.ts` writes the result back into the same stores and rebuilds the nav model. `invalidateAll` is the single source of truth that keeps the layout's `data` snapshot (`data.activeRole` / `data.permissions` / `data.scopes`, the fallback inside `getActiveRole() ?? data.activeRole`) consistent with the stores after a switch.

`facet:permissions-update` is dispatched as a **signal-only** window event (no payload). The root layout's handler and every Configure page that listens treat it as "re-derive everything from the session" by calling `invalidateAll()`. Carrying only `permissions` in the event payload (the prior behaviour) left the `scopes` store stale after a switch — `canScope()`-driven affordances (e.g. the General/Personal CollectionView toggle) silently kept the old role's scope answer until the next full page load.

The role store (`role.svelte.ts`) holds the active role id and the available-role list. It is hydrated by the layout load from `App.Locals.availableRoles` (which `hooks.server.ts` reads from `/Api/iam/me`), by `login()`, and by `switchActiveRole()`. Like `apiFetch`, its module state is gated on the browser — on SSR the layout falls back to its per-request `data` snapshot (`getAvailableRoles() ?? data.availableRoles`), so the Switch Role submenu renders from the server snapshot before hydration. `availableRoles` starts as `null` (not yet hydrated) so callers can distinguish "unknown" from a genuinely empty role list. The main `AppShell`, the Builder shell, and the Configure shell (`routes/Configure/+layout.svelte`) all forward the store's active/available roles and `switchActiveRole` to `SidebarShell;` omitting them would hide the submenu there.

#### Permission matching (`can` / `canScope` / nav)

The matcher for the permission manifest lives in `permissions.svelte.ts`: `canInManifest(manifest, doctype, action)` is the pure core, `can()` / `canScope()` wrap it with the store and the preview overlay. Grant order:

1. **Admin short-circuit** — `"*.*" → ["*"]` grants every check (`canScope` returns `'unrestricted'`).
2. **Exact key** — `manifest[doctype]` grants when it holds the action or `"*"`. An explicit key grant always stands; the wildcard carve-outs never subtract it.
3. **Wildcard fallback** — when the exact key is absent or lacks the action, the `"*.*"` action list grants the doctype unless the reserved `"*.*.except.<action>"` key for that action subtracts it: an entry matches when it equals the doctype or is a path prefix of it (`core.DocType` also excludes `core.DocType.Comment`). This is what makes a wildcard-with-except role (the seeded `editor`) render its affordances; the backend folds the wildcard lines' `except` carve-outs per action under those reserved keys (see [`iam.md`](../backend/iam.md) → Permission manifest).

`canScope` resolves the scope from `scopes[doctype]` for an exact-key grant and from `scopes["*.*"]` for a fallback grant; an absent entry reads as `'unrestricted'`. The nav uses the same matcher: `buildNavModel` builds a per-doctype visibility predicate (`read` grant through exact key or fallback) instead of iterating manifest keys — the reserved `"*.*.except.<action>"` permissions keys and the `"*.*"` scopes key never name a doctype, and no consumer may iterate either map's keys to render one. Matching semantics are unit-tested in `permissions.spec.ts` and `navModel.spec.ts` (Vitest `server` project).

#### Client-side TTL cache (`clientCache.ts`)

Rarely-changing API responses are cached in browser memory for 60 seconds to cut redundant round-trips across navigations (the backend already serves 304s, but a 304 is still a network request + server-side etag evaluation). The cache lives in `src/lib/datasource/clientCache.ts`.

| Cache                  | Key                                 | Filled by                                                                                          | Invalidated by                                                                                                                                                                                                                                                        |
| ---------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `doctypeRegistryCache` | (singleton)                         | `DoctypeRegistry.cached(driver)`                                                                   | `doctypeRegistryCache.invalidate()` — route loads do this once before declaring 404 so a freshly-created doctype isn't racy against the TTL window                                                                                                                    |
| `domainListCache`      | (singleton)                         | `buildNavModel` (`navModel.ts`)                                                                    | logout (via `invalidateAllClientCaches`)                                                                                                                                                                                                                              |
| `doctypeViewsCache`    | parent `core.DocType` projection id | `loadDoctypeView` / `loadDoctypeViewByKind` / `loadDoctypeViewsWithIds` (`doctype/loadDocumentView.ts`) | logout; the Views tab invalidates the parent entry after a template save (`DoctypeViewsTab`)                    |
| `collectionViewsCache` | parent `core.DocType` projection id | `ListView.svelte` view-tab fetch, `DomainDashboard.svelte` pinned-view + saved-view sub-link fetch | `collectionViewsCache.invalidate(parentDocId)` after a create/update save                                                                                                                                                                                             |
| `documentShowCache`    | qualified doc URL                   | `DocumentDataSource.ConcreteDocumentRef.show()`                                                    | `update()` / `delete()` / `action()` / `rollback()` / `restore()` invalidate their own entry; `ref.invalidate()` covers out-of-band mutations (e.g. the IAM credential panel); the show route's live document channel invalidates on any actor's mutation (see below) |

All caches follow the same rules:

- **Browser-only.** `isBrowser = typeof window !== 'undefined'` is captured at module load; on the server every `get` calls the fetcher directly (same SSR gating rule as `apiFetch`).
- **TTL = 60 seconds.** Past `expiresAt` the entry is a miss. Fetcher errors do not poison the cache — only successful results are stored.
- **In-flight dedup.** Concurrent callers for the same key share the same fetch promise (`Promise.all([cache.get(k, f), cache.get(k, f)])` → one network call) and the shared promise is dropped on settle so the next call after expiry re-fetches.
- **Logout clears everything.** `auth.svelte.ts`'s `logout()` calls `invalidateAllClientCaches()` (and `clearCounts()` from `navCounts.svelte.ts`, `clearRecentDocuments()` from `recentDocuments.svelte.ts`) so a subsequent login (possibly as a different account) starts with an empty cache.

**Live invalidation on the show route.** The show route declares a per-document SvelteKit `depends()` key (`documentDependencyKey` in `documentSocket.svelte.ts`) and subscribes the document's WebSocket channel (`subscribeDocumentRefresh`). Any frame whose `payload.id` names the document — `created` / `updated` / `deleted` or a named-action event such as `closed` — from any actor (a second tab, an automation, the credential panel) drops the document's `documentShowCache` entry and re-runs the page load. The identity check is `isDocumentMutation` in `documentSocket.svelte.ts` (see `doc/backend/websocket.md` → Frame contract for client refreshes); an event-name allow-list would go stale on every new named action. Delivery has no replay, so every socket re-open runs the same refresh, and the 60s TTL bounds whatever still slips through. Frames are hints: the REST re-fetch re-checks RBAC, so a lost grant surfaces as the load error, never as stale-authorized content. `child_changed` frames are ignored — the payload id names the parent, and owned-child mutations do not alter the parent's content.

The `TtlCache` constructor accepts an optional `isBrowserFn` predicate for tests — the module-level `isBrowser` is `false` under the Vitest `server` project, so tests pass `() => true` to exercise the browser branch.

### Import/export — toolbar client and affordances

`src/lib/importExport/importExportClient.ts` wraps the concern's four routes. Every function takes an injectable `fetchImpl` (components pass `apiFetch`, so token refresh and 401 recovery stay in the loop), which keeps the module pure and Vitest-tested in the `server` project: `enqueueExport` / `enqueueViewExport` / `enqueueImport` (all set the CSRF `X-Requested-With` header; the view export also sends a JSON body with `Content-Type: application/json`), `fetchJobStatus`, `pollJob` (deadline-based, with the timeout outcome mapping to the enqueue-mode surface), `importReportOf` / `importRowErrorOf` (the terminal `result` normalizers), `downloadUrl`, and the preview helpers (`detectFormat`, `previewHeader` — client-side shape parsing, never authoritative). The client stays framework-free: the caller resolves the display timezone through `displayTimezone()` and passes it in the view state; the client never imports the settings store.

The UI mounts through one seam: `TableToolbar` accepts an optional `actions` snippet (`Table` and `ListView` forward it as `toolbarActions`), and the doctype page renders `features/importExport/ImportExportActions` there behind a `Can read` gate. The snippet receives the table's live state — `ToolbarActionsArgs` in `table/types.ts`: the current `columns`, the **compacted filter map the datasource receives** (freshly seeded empty chips dropped, so a raw mid-edit chip never rides into an export), and the current `sort`. The page maps it to the `view` prop (`column keys` minus the `__`-prefixed non-data columns, the filter map, and the single-key sort grammar) and passes `null` in trash mode:

- `ExportMenu` — format choice (CSV / JSON), immediate enqueue, then a fire-and-forget `pollJob`; a completion toast carries the download link (the backend notification is the durable surface). With a non-null `view` whose columns are non-empty, a third item — "CSV — current view" — enqueues the view export (the view state plus `displayTimezone()`) through the same flow; `null` or empty columns hide the item, and one `running` guard covers all three items.
- `ImportDialog` — Bits UI dialog: file pick, client-side header preview, submit, and the job outcome driven by the status poll — the `{row_count, created, updated, skipped}` report, or the failing row's `{row, field, message}` (an import is all-or-nothing). A wait-mode timeout closes the dialog while the job keeps running; the notification reports it. On a successful import the dialog calls the `onimported` callback; the doctype page bumps `ListView`'s `refreshSignal`, which re-wraps the listing `DataSource` and reloads the `Table` — the imported rows show without a manual reload.

Transients use the `toast()` store (`$lib/toast.svelte`), rendered once by `ToastHost` in the root layout — the same single-host pattern as `confirm()` / `ConfirmDialog`.

The domain-bundle surface mirrors the same job pattern for whole domains (the backend concern is `src/domain/portable/`, definition-only over HTTP). `src/lib/portableDomains/portableDomainsClient.ts` wraps its four routes: `enqueueDomainExport`, `enqueueDomainImport` (the bundle upload with the `into` / `merge` query), `fetchJobStatus` / `pollJob` on the shared `/Api/core/Domain/import_export/:job_id` status route, `domainDownloadUrl`, the `exportResultOf` / `importReportOf` normalizers, and the `isBundleFile` extension guard. The UI lives on `/Configure/domains`: the published-domain row menu carries "Export bundle" (enqueue plus a detached poll; the completion toast carries the download link — a draft domain refuses server-side, so the item is published-rows only), and the page header's "Import bundle" button opens `features/configure/ImportDomainDialog` — bundle pick, optional rename (`into`), merge toggle, then the job outcome: the doctype counters report, the backend's rejection message, or the timeout falling back to the notification surface. A successful import refreshes the page lists through the dialog's `onimported` callback.

### Document View Template

`src/lib/template-types.ts` (node grammar), `src/lib/template-resolve.ts` (value resolution), and `src/lib/components/features/document-view/` form a **recursive template engine** for rendering doctype document views. Each `core.DocumentView` document stores a `template` field — a tree of typed nodes that describe the UI layout.

#### Template node types

| Type             | Node shape                                                                                                    | Rendered by                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `label`          | `{ type: "label", value: string }`                                                                            | `DvtLabel.svelte` — resolves `$field` references against `document.data`, falls back to literal text                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `field`          | `{ type: "field", label?: string, value: string, children?: TemplateNode[] }`                                 | `DvtField.svelte` — labeled row with resolved value or child content. `label` is optional; when omitted the row renders a single full-width value column (useful when the surrounding `section` already provides the label). A `longtext` value renders as raw text here — bind a longtext through the auto `input` or a `markdown` node to render the markdown.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `tabs`           | `{ type: "tabs", tabs: TabDescriptor[] }`                                                                     | `DvtTabs.svelte` — renders tab navigation via existing `Tabs` + `TabPane`, recursively renders children                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `object`         | `{ type: "object", field: string, children: TemplateNode[] }`                                                 | `DvtObject.svelte` — shifts `$field` resolution to a nested object field. Renders only its children (no header); wrap it in a `section` node when a label is wanted.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `if`             | `{ type: "if", field: string, value?: unknown, children: TemplateNode[], else?: TemplateNode[] }`             | `DvtIf.svelte` — conditional rendering by field truthiness or equality                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `array`          | `{ type: "array", field: string, children: TemplateNode[] }`                                                  | `DvtArray.svelte` — iterates over an array field                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `dict`           | `{ type: "dict", field: string, children: TemplateNode[] }`                                                   | `DvtDict.svelte` — iterates over an object's entries                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `grid`           | `{ type: "grid", layout: string, children: TemplateNode[] }`                                                  | `DvtGrid.svelte` — CSS grid with proportional columns (integer fractions only, e.g. `"3 1"`). A 2-column grid shares a vertical divider between its cells. Use `row` for inline label/capsule rows, not `grid`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `col`            | `{ type: "col", children: TemplateNode[] }`                                                                   | `DvtCol.svelte` — vertical column wrapper                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `image`          | `{ type: "image", src: string, alt?: string, variant?: string }`                                              | `DvtImage.svelte` — renders an `<img>` with resolved src                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `markdown`       | `{ type: "markdown", field: string }`                                                                         | `DvtMarkdown.svelte` — renders a `longtext` field as readonly markdown prose through the shared `Content/Markdown` primitive (see `doc/frontend/markdown-editor.md`). The show-page counterpart of `input-longtext`: longtext is markdown, so a record view renders it as a document, never as a plain-text field row. Dotted field paths resolve (read-only). Renders nothing when the field is empty.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `image-artifact` | `{ type: "image-artifact", field: string, alt?: string, variant?: \"avatar\"\|\"thumbnail\", size?: number }` | `DvtImageArtifact.svelte` — renders a stored `file`-typed field as an `<img>` miniature. Resolves the bare artifact id to a grant URL on mount via `GET /Api/core/artifacts/:id` (the fetch is owned by the shared `ArtifactImage.svelte` cell). Used for logos / avatars stored as `file` artifacts.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `link`           | `{ type: "link", href: string, label: string }`                                                               | `DvtLink.svelte` — renders an `<a>` with resolved href and label                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `email`          | `{ type: "email", href: string, label: string }`                                                              | `DvtEmail.svelte` — renders a clickable email capsule with copy-to-clipboard                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `phone`          | `{ type: "field", value: "$phone" }` (field type `phone`)                                                     | `DvtValue.svelte` — a `phone`-typed field renders a `PhoneCapsule` (copy-to-clipboard, mirroring email). No dedicated template node; the shared `FieldValue` renderer (dispatch via `cellKind.ts`) behind `DvtValue` handles it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `url`            | `{ type: "field", value: "$website" }` (field type `url`)                                                     | `DvtValue.svelte` — a `url`-typed field renders a `UrlLink` (external link, `target="_blank"`, with an external icon). No dedicated template node; the shared `FieldValue` renderer (dispatch via `cellKind.ts`) behind `DvtValue` handles it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `file`           | `{ type: "field", value: "$avatar" }` (field type `file`)                                                     | `DvtValue.svelte` — a `file`-typed field renders a `FileArtifact` capsule labeled with the stored artifact id. The grant URL is fetched lazily on first click via `GET /Api/core/artifacts/:id` and cached in-process; no fetch happens on render. No dedicated template node; the shared `FieldValue` renderer (dispatch via `cellKind.ts`) behind `DvtValue` handles it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `title`          | `{ type: "title", value: string, level?: number }`                                                            | `DvtTitle.svelte` — renders a heading (h1–h6), defaults to h2                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `capsule`        | `{ type: "capsule", value: string }`                                                                          | `DvtCapsule.svelte` — renders a small pill badge with resolved text                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `hr`             | `{ type: "hr" }`                                                                                              | `DvtHr.svelte` — renders a horizontal rule separator                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `relation`       | `{ type: "relation", label, doctype, referenceField?, source, view?, editable?, limit?, columns? }`           | `DvtRelation.svelte` — renders related documents (child collection or inverse-filter list). `view: "inline"` renders each row via the relation doctype's `inline` template (falling back to `quickView`); `editable: true` (mutually exclusive with `view`) renders each row via the child's `form` template and exposes Add/Remove. `view: "table"` renders the list as a table with one column per `columns` entry; the table scrolls horizontally inside its own wrapper when nowrap columns exceed the pane, so a wide table never widens the document column; a column key may be a plain field on the row (`role`) or a dotted path crossing one or more `reference` fields (`contact.email`) — the renderer resolves the referenced document(s) on demand and caches per `(qualified, id)` so two rows sharing a reference cost one fetch. Cells dispatch through `DvtValue` — a thin wrapper over the shared `FieldValue` renderer — so typed fields (enum/phone/money/file) render identically to a show page — except a column marked `editable: true` over a plain boolean field: when the viewer holds `update` on the relation doctype and the surface is read-only (no form `values` bag), the cell renders as a green/red toggle that PATCHes the row document directly (optimistic, revert + toast on failure; dotted keys ignore the flag — their leaf lives on the referenced document — and `check_relation_columns` warns at authoring time). Only `children` sources support `editable: true` (filter-bound relations are read-only). When `editable` is set, `DocumentForm` collects the staged child drafts under `values["__relation_drafts__"][rel]` and persists them after the parent saves via `doc(parentId).children(rel)` (non-transactional). |
| `header`         | `{ type: "header", title, statusField?, chips?, subtitle?, logo? }`                                           | `DvtHeader.svelte` — document show-page header. Renders the title, a status chip (the only color-bearing chip, keyed off the `statusField`'s declared enum `values[].color`), optional neutral categorical `chips`, an optional `subtitle`, and an optional `logo` avatar (left of the title — a `file`-typed field whose stored artifact id resolves to a grant URL on mount via `ArtifactImage`). The page's `h1` is owned by the doctype chrome (`DoctypeHeader`); `DvtHeader` renders an `h2` to avoid two `h1`s.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `section`        | `{ type: "section", label, children }`                                                                        | `DvtSection.svelte` — a named field group with an uppercase eyebrow label and a stacked field grid. Replaces the ad-hoc `title` + stacked `field` pattern for grouped data.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sidebar`        | `{ type: "sidebar", children }`                                                                               | `DvtSidebar.svelte` — the right rail of a record view. Holds metadata that is not a business field (owner, tags, provenance). Place as the last child of a `grid` with an integer-fraction layout (e.g. `"3 1"`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `record-meta`    | `{ type: "record-meta", history? }`                                                                           | `DvtRecordMeta.svelte` — provenance block read from `document.meta`. Renders `Created`, `Updated` (relative), and an optional `History` link. The link's `href` is forwarded by the show route as `historyHref`; when omitted, the link is hidden even if `history` is `true`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `row`            | `{ type: "row", layout: string, children: TemplateNode[] }`                                                   | `DvtRow.svelte` — a single-line inline CSS grid. The `layout` is a raw `grid-template-columns` value (`"auto 1fr auto"`, `"auto auto auto 1fr"`), used for one-line summaries where columns size to content. In form templates, each cell holds an `input-*` node sized by its column. For column-based layouts (main + sidebar), use a `grid` node with integer fractions.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |

`tab` is a structural child of `tabs` (not a top-level node type):

```typescript
interface TabDescriptor {
  type: "tab";
  label: string;
  children: TemplateNode[];
}
```

#### Form input nodes

Form templates are built from input nodes. Each binds a single document field into the form's mutable `values` bag (string keys → field values), renders an editable control when `values` is present, and a read-only labeled row otherwise. Display templates reuse the same nodes for rich values: a `longtext` field binds through the auto `input`, and with no `values` bag the read-only branch renders the stored markdown through the Milkdown preview — the record view shows the rendered document, never the raw source. The `markdown` node is the label-less variant; it hides when the field is empty.

The auto `input` node is the default: `{ type: "input", field }` renders the correct control from the field's **declared type** in the doctype definition (`resolveAutoInput` in `src/lib/doctype/autoInput.ts`) — enum options derive from `values`, the reference target from the field's `doctype`, the required flag and label from the definition (explicit `label`/`placeholder`/`helper`/`required` props override). Specialized `input-*` nodes stay as **deliberate overrides** — they force a control the definition cannot express (an email keyboard on a string field, a url prefix). The auto node never binds `array` / `object` / `dictionary` / `data` fields: the validator rejects the binding at authoring time and the component renders a diagnostic (`input-list` is the one container control, for string arrays). Scope-shifting wrappers narrow the definition for their children (`DvtObject` to the bound object's `properties`, `DvtArray` to the item schema's), so nested `input` nodes dispatch from the sub-fields' own declared types.

| Node              | Field type                   | Bound value shape                                            | Control                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ----------------- | ---------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `input`           | every editable scalar        | depends on the dispatched control                            | dispatches to the matching specialized control from the declared type: `string`/`any` → text, `integer`/`duration` → number, `url` → url, `phone` → tel, `enum` → select (options from `values`), `boolean` → toggle, `datetime`/`date`/`period`/`dateperiod` → their pickers, `longtext` → markdown editor, `money` → money pair, `color` → color picker, `file` → uploader, `secret` → stage-and-store, `reference`/`child` → reference picker (target from the def; a `collection: true` reference edits as a chip list — see `input-reference`), Missing definition / unknown field degrades to a text control |
| `input-text`      | any scalar                   | string (html `inputType` selects text/email/number/date/...) | `Forms/Input`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `input-longtext`  | longtext                     | string                                                       | composed `Content/Markdown` editor (`Content/Milkdown` WYSIWYG + markdown source mode + expand overlay — see `doc/frontend/markdown-editor.md`)                                                                                                                                                                                                                                                                                                                                                                                       |
| `input-select`    | enum                         | string (enum key)                                            | `Forms/Select`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `input-datetime`  | datetime                     | string (UTC RFC-3339, `''` when cleared)                     | `Forms/DatetimePicker` (timezone-aware segmented entry — wall time in the user's `core.timezone`, committed value in UTC; see `doc/frontend/datetime-picker.md`)                                                                                                                                                                                                                                                                                                                                                                      |
| `input-toggle`    | boolean                      | boolean                                                      | `Forms/Toggle`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `input-reference` | reference                    | `string` (qualified id), or `string[]` when the field is `collection: true` | `Forms/ReferencePicker` (single) — a `collection: true` reference binds `Forms/ReferenceListEditor` instead: removable `Capsule` chips over the stored token array plus an embedded picker as the add control (a pick appends the qualified token, a repeated target shows the duplicate message — the backend rejects duplicates with `duplicate_reference_target`). The read-only branch renders one capsule per token through `referenceTokens` |
| `input-money`     | money                        | `{ value: string, currency: string }` (or `''` when cleared) | `Forms/MoneyInput` (amount field + internal left-side currency dropdown; combobox-style type-to-filter, field-declared `currency` pinned first; typing a ticker into the empty amount field engages currency typeahead — no need to click the currency button first; Space or Enter commits the typeahead selection; the displayed amount formats with `'` thousands grouping while the raw decimal `value` stays ungrouped)                                                                                                          |
| `input-file`      | file                         | string (artifact id)                                         | uploader (`POST /Api/core/artifacts`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `input-list`      | array of string-like scalars | `string[]`                                                   | `Forms/StringListEditor` (removable chips + add-value input; commits on Enter/comma/blur). The field must be an array of string items — object-item arrays edit through an `array` wrapper with child inputs                                                                                                                                                                                                                                                                                                                          |

`input-money` is the only composite-binding input. The `value` member is a canonical decimal **string** (never a JS number — the backend's `MoneyType#validate` rejects a numeric `value` member with `invalid_type`). The amount field validates the decimal shape client-side (mirroring the backend's `/^-?\d+(\.\d+)?$/` rule) and surfaces a local error; the backend re-validates authoritatively. The currency options and the display precision come from the shared currency store (`frontend/src/lib/components/primitives/data/currencyStore.svelte.ts`), which fetches the `core.Currency` documents once per session — the field definition's declared `currency` is a backfill hint pinned first in the picker, and a stored-but-inactive (or deleted) ticker keeps its option flagged while it stays the current value. The same `MoneyInput` is reused by `DocumentForm`'s fallback form.

**Fallback surfaces (no view template).** When a doctype has no `kind: form` / `kind: show` DocumentView, the routes render their own per-field surfaces. The fallback show page (and the QuickView's no-template peek) dispatch every stored field through the shared `DvtValue` renderer — the same typed pipeline the template path uses — so money, period, dateperiod, enum, and reference fields all render; objects, object-item arrays, and definition-less arrays fall back to JSON text, never `[object Object]`. The fallback form renders one control per editable field: the typed controls above for scalars, `Forms/ReferenceListEditor` for a `collection: true` reference and for an `array` field whose `items` are `reference` (both store the same token array the show side renders as capsules), and `Forms/StructuredInput` for the remaining `object` / `array` / `dictionary` fields — a JSON-text editor that parses and validates against the field schema (`structuredSchema.ts`: object → `properties`, array → `items`, dictionary → the parsed `dictionaryValue` entry schema) and binds the parsed structure, never the raw text. While the text is invalid, the last valid structure stays bound and a field-level error names the offending path. The form also blocks the save: the widget reports each validity flip through `onvaliditychange`, and `handleSave` returns before the mutation until every structured text parses or is blank (B-118). The patch builders pass these structures through untouched (`coerceValue` recurses declared object properties and preserves extra keys). Save sends a **minimal patch**: `buildFormPatch` diffs the coerced values against the persisted content and omits unchanged keys, so a save with no edits sends an empty patch (the backend stores no mutation). The diff keeps Lua-guarded immutable fields (`iam.Roles.name`, `app.App.slug`) working: their `update` hook refuses any patch that carries the key, even with an unchanged value. It also keeps untouched references out of the backend's reference checks, which read only the patch.

An `input-text` node may declare a `prefix` (e.g. `https://`) — inline chrome inside the field's left edge. The chrome is a hint, not part of the value: it shows for empty or scheme-less values and hides once the bound value starts with it or already carries a scheme. A `url` field commits absolute values with a shared completion rule (B-294): a scheme-less value whose authority is a **dotted** DNS-style host (`www.acme.tld`, with an optional `:port`) is completed with the scheme — on commit (change/blur) `DvtInputText` rewrites it so the field shows what will be stored, and the payload coercion in `formDiff.ts` re-applies the same rule — while a dotless value (`not-a-url`, `localhost:3000`) is never completed: the blur commit keeps the raw text and shows a field error, and the payload passes it through so the backend's 422 refuses it. The rule lives in the backend's `UrlType#normalize`, so a REST client's raw input stores the identical value; the frontend helpers (`$lib/doctype/urlValue.ts`) mirror it for the commit UX. The fallback form's url inputs render the same chrome and commit. `Forms/Input` measures the adornment and reserves its real width, so a wide prefix never covers the value text.

#### Value resolution

Template values prefixed with `$` resolve against `document.data`:

- `"$field_name"` → `document.data["field_name"]`
- `"$parent.child"` → dot-path traversal of `document.data`
- Plain text → rendered as-is
- Missing fields → raw value string shown (e.g. `"$missing"`)
- A money object (`{value, currency}`) → `"<currency> <value>"` (e.g. `"EUR 120000"`), matching the backend display-name templating; detection is shape-based, so computed money pairs format too
- A secret marker → empty text — the typed field badge shows the secret state, the marker never appears as text or JSON
- Any other object or array → JSON, never the JS `[object Object]` artifact

#### Layout conventions

Two rules govern how a doctype's view template is structured. They are recommendations to the fixture author, not renderer heuristics — the dispatcher stays dumb on purpose.

1. **Sections are declared, tabs are derived.** Declare field groups with `section` nodes. Use `tabs` only when a doctype has many sections or when `relation` lists would dominate the page. Relations always render as their own tab — they are lists of other records, not fields of this one. A small doctype does not inherit the navigation cost of a large one.
2. **Header-promoted fields are excluded from the body by convention.** Whatever fills `header.title`, `header.statusField`, and `header.chips` is not repeated in the body `section` blocks. The renderer does not deduplicate — exclusion is the author's responsibility. `header.subtitle` is display chrome, not a promoted field, so its underlying field may still appear as a labeled row in a section.
3. **Form layout combines `section` (grouping) with `row` (per-input width).** Inside a `section` block, a `row` node lays out its `input-*` children horizontally with `grid-template-columns`; each column sizes one input to its expected content. Widths are a fixture-author concern — the dispatcher stays dumb, and the same `row` node serves summary rows in display templates and input rows in form templates. See the `crm.Company` form fixture (`data/fixtures/core.DocumentView/crm.Company.yml`) for the canonical pattern: five sections, each a single `row` with column widths sized to the content.

#### Color policy

Color is reserved for the field where color changes what you would do next. Concretely:

- `header.statusField` is the only chip that receives a tint — it is a state machine, and the tint comes from the doctype's declared `enum` `values[].color`.
- `header.chips` always render neutral. Categorical labels (industry, size) never carry color in the header.
- `DvtCapsule` renders neutral by default.
- The enum path of the shared `FieldValue` renderer (behind `DvtValue`; used when an enum field appears as a standalone `field` row in a section) still honors a declared `values[].color`. This lets a non-status enum field (e.g. a Task `priority`) be tinted in the body, while the header stays neutral for categoricals.
- Blank field values render an explicit `—` (em dash), not an empty row, so loading / permission-denied / genuinely-empty are visually distinguishable from a missing affordance.

#### Architecture

`DocumentViewTemplate.svelte` acts as a **dispatcher**: it holds a `type → component` registry and renders the matching component via Svelte 5's dynamic component syntax. Adding a new template type means:

1. Add the type to the `TemplateNode` union in `template-types.ts`
2. Create a `Dtv*.svelte` component accepting `{ template, document }`
3. Register it in the registry inside `DocumentViewTemplate.svelte`

Each atomic component receives the full `document` as a `DocumentResponse` shape (`{ data, meta }`). This lets components access both content fields and system metadata.

**Malformed-node guard.** An `input` / `input-*` node whose `field` binding cannot render — missing entirely, or a **dotted path** (`config.enabled`). Every input component reads `template.field` during derived initialisation (missing → throw, blanking the page), and a dotted path binds a literal flat key no input can resolve or write back into the nested object. The dispatcher therefore renders a visible diagnostic (`.dvt-input-template-error`, `role="alert"`) instead of dispatching; for dotted bindings it names the fix — wrap the top-level field in an `object` node and bind the bare sub-field. The same diagnostic covers a missing `template` or `document` prop: the props are typed non-nullable, but a render torn down mid-flush (the shared-page story tests) can read them as undefined for one tick, and a throw there corrupts the page for the retry (see the story quirk “Args are read-only”). The backend validates template trees at every write door — the flat create/update and the nested child create all run `Doctype::ViewTemplateValidator` (structurally and against the doctype definition) through `Document::ViewTemplateGate`, so `:error` issues answer 422 at save time; `:warning` issues stay non-blocking (duplicate relation column keys included — the renderer collapses them to the first occurrence). The guard covers rows persisted before the gate existed.

#### Source files

```
src/lib/
├── template-types.ts                      # Template node grammar (types)
├── template-resolve.ts                    # resolveValue() + getDocContent() (value resolution) + normalizeRelationColumns (malformed relation-column coercion)
├── referenceLabel.ts                      # Reference label resolver (per-page cache over the driver)
├── doctype/                               # Relation implementation modules (Vitest-tested)
│   ├── relationColumns.ts                 # Column-key grammar + cell resolution (refKey, resolveColumnCell, rowToDraft…)
│   ├── relationDrafts.svelte.ts           # Editable-relation draft controller (userDrafts, tombstones, values-bag mirror)
│   ├── relationTemplates.ts               # Loads relation def + inline/form/quick templates for a doctype
│   └── autoInput.ts                       # Auto `input` node dispatch: resolveAutoInput (declared type → control)
└── components/
    └── features/document-view/
        ├── session-bag.svelte.ts          # Story-only: session-local values bag clone
        ├── DocumentViewTemplate.svelte     # Dispatcher (registry + recursive render)
        ├── DocumentViewTemplate.stories.svelte  # Integration stories
        ├── DvtArray.svelte                 # Atomic: array iterator
        ├── DvtCapsule.svelte               # Atomic: capsule badge
        ├── DvtCol.svelte                   # Atomic: column wrapper
        ├── DvtDict.svelte                  # Atomic: dict iterator
        ├── DvtEmail.svelte                 # Atomic: email capsule
        ├── DvtField.svelte                 # Atomic: labeled field row
        ├── DvtGrid.svelte                  # Atomic: CSS grid layout
        ├── DvtHr.svelte                    # Atomic: horizontal rule
        ├── DvtIf.svelte                    # Atomic: conditional
        ├── DvtImage.svelte                 # Atomic: image
        ├── DvtLabel.svelte                 # Atomic: label text
        ├── DvtLabel.stories.svelte
        ├── DvtLabel.svelte.spec.ts         # 4 tests
        ├── DvtLink.svelte                  # Atomic: hyperlink
        ├── DvtObject.svelte                # Atomic: nested object scope
        ├── DvtTabs.svelte                  # Atomic: tab container
        ├── DvtTabs.stories.svelte
        ├── DvtTabs.svelte.spec.ts          # 4 tests
        ├── DvtTitle.svelte                 # Atomic: heading
        ├── DvtRelation.svelte             # Relation node: inline / editable / table views
        ├── DvtRelationTable.svelte        # Table view: hydration maps + cell rendering (owns its fetches)
        ├── DvtHeader.svelte                # Atomic: document show-page header
        ├── DvtSection.svelte               # Atomic: named field group
        ├── DvtSidebar.svelte               # Atomic: right-rail lane
        ├── DvtRecordMeta.svelte            # Atomic: provenance block from meta
        ├── DvtRow.svelte                  # Atomic: inline CSS grid row
        ├── DvtValue.svelte                # Typed-value cell — thin wrapper over primitives/data/FieldValue
        ├── DvtImageArtifact.svelte        # Atomic: file-artifact miniature
        ├── ArtifactImage.svelte           # Shared artifact <img> cell (grant URL fetch)
        ├── DvtInput*.svelte               # Form inputs: auto, text, longtext, select, datetime, toggle, reference, money, file, list, color, secret (stories co-located)
        ├── DocumentForm.svelte            # Document form: values bag + relation drafts
        ├── DocumentForm.stories.svelte
        ├── SidecarPanel.svelte            # Sidecar rail: 0/1/N entries + tabs
        ├── SidecarPanel.stories.svelte
        ├── SidecarDvtSurface.svelte       # Basic DVT sidecar surface (registry fallback)
        └── SidecarDvtSurface.stories.svelte
```

#### Authoring a template in the Builder

The Builder doctype editor's **Views** tab (`DoctypeViewsTab.svelte`) previews each `core.DocumentView` kind and offers a **Display / Edit** toggle. Edit swaps the preview for a plain monospace `<textarea>` holding the view's `template` object as pretty-printed JSON — no editor library, no highlighting. Save parses the JSON locally (an invalid or non-object root shows an inline `role="alert"` error and sends nothing), then writes the view through the doctype's child route: `PATCH` `/Api/core/DocType/<parent>/document_view/<id>` for a stored kind, `POST` on the collection with `{ parent_doctype, kind, template }` for a missing one. The write client is `src/lib/doctype/viewAuthoring.ts`; the child ids ride the same route load as the templates (`loadDoctypeViewsWithIds`). The toggle renders only for a writer (`can('core.DocumentView', 'create' | 'update')`) on a non-readonly editor — the Configure shell passes `readonly` for published domains. Details: [`configure-editors.md`](configure-editors.md) → Views tab.

---

## Sidebar navigation — child doctype visibility

`buildNavModel` (`navModel.ts`) returns each domain's doctypes as a **tree**:
composition children nest under their parent entry's `children` array, and
both sidebars (`NavPanel.svelte` live, `BuilderSidebar.svelte` in builder
mode) render expandable rows. A doctype with `member_of` set (and
`aggregate_root: false`) shows as a child row of its parent — no flag
needed. Subtrees start expanded; the caret collapses a branch. `nav_visible`
remains a plain boolean on the doctype definition (see
`core.DocType.nav_visible`, parsed in `src/doctype/doctype_definition.cr`)
with one fallback job: when the parent cannot host the child in the tree —
the parent's definition is missing, lives in another domain, or RBAC hides
it — a `nav_visible: true` child renders as a flat top-level row, and an
unopted-in child stays hidden. The same rule is exported for single-domain
use: `navDoctypesForDomain(registry, domainId)` (`navModel.ts`) builds one
domain's tree from a `DoctypeRegistry` snapshot — the preview dashboard's
carve-out (`routes/[domain=notApi]/+page.ts`) fills its draft `NavDomain`
with it, without a manifest filter (the preview overlay suppresses
permissions).

Rules:

- Aggregate roots and the children-only spelling (parent declares `children:`,
  child has no `member_of`) render top-level.
- Nesting never bypasses RBAC — every child still needs its own `read` grant
  (`buildDomainNavTree` resolves the whole `member_of` chain, so a child of a
  hidden parent is not nestable either). Malformed chains (a `member_of` that
  loops, or points outside the domain) fall back to the flat/hidden rule
  above; they never recurse forever.
- Nested rows carry no pin button — pinning stays a top-level concept, and
  the Pinned group lists top-level entries only.
- Search flattens the tree: the nav search popover and the inline filter
  matches render flat over `flattenNavDoctypes(domain.doctypes)` so a child
  hit is visible without its parent's context.
- Counts, the domain dashboard, and the command palette also read the
  flattened list; the collapsed rail shows top-level rows only (no per-child
  rail slot exists).
- Children stay reachable regardless of the tree: through the parent
  document's relations surface and direct URL. Creating a nav-visible child:
  the child listing's New button opens the create form, which renders a
  required parent picker (locked to the `member_of` parent) and saves
  through `doc(parentId).children(rel)` — the flat create is rejected by the
  backend (422), because `meta.parent_id` is stamped only on the nested
  route. `DocumentForm` resolves the relation key from the parent
  definition's `children` map (`parentLink.ts`); `?parent=<id>` on the
  `/new` route preselects the picker.

---

## Quirks & good practices

### General frontend good practices

- Cut taglines, helper text and secondary label when unecessary. If a screen needs them to make sense, fix the layout instead.
- Make the best decision that would elevate those (3) things: the user experience (UX), the developer experience (DX) and the agent experience (AX), always.

### WebSocket collection subscriptions — nav refresh in builder mode

The builder-mode navbar refreshes through a **collection subscription**. In
`routes/+layout.svelte`, the WebSocket effect runs on every `/Builder` route
and subscribes to `/core/DocType` (two-segment path) instead of one path per
doctype. The per-draft `/core/Domain/{draftDomain}` subscription is added only
when the route param exists — the collection channel covers the landing page
too, where drafts are created from existing domains. There the copy enqueues a
`registered` event per copied doctype at flush time, before the client has a
draft-scoped subscription; only the collection channel can deliver them.

Do not replace the collection subscription with a per-doctype loop. A loop over
the doctypes that exist when the effect runs can never receive events for
doctypes created later —
the assistant or another tab creates the doctype, the `created` event has no
listener, and the navbar keeps the stale list. The collection channel
(`fanout:core.DocType` on the backend) carries every `core.DocType` event,
including `created`.

Notes:

- Collection messages are hints, not source of truth. The handler drops
  `doctypeRegistryCache` and `domainListCache` first, then re-fetches the
  doctype list (`buildNavModel`) and never trusts the event payload. Without
  the invalidation the rebuild re-reads the stale 60s-TTL snapshot taken
  before the mutation, and the navbar never changes. See
  `doc/backend/websocket.md` → Refresh protocol.
- The draft-creation handlers (`handleNewDomain` / `handleEditDomain` in the
  layout, `newDraftFromPublished` in `/Configure/domains`) must also drop the
  registry cache before rebuilding — the draft copy persists doctypes
  server-side before the HTTP response returns.
- Collection subscriptions need `read` on `core.DocType` at subscribe time,
  and preview principals are rejected (the socket is cookie-authenticated, so
  a preview tab subscribes as the real principal — the preview token never
  reaches the wire). The effect runs under `/Builder/*` and during an active
  preview session, where the handler rebuilds the live nav from the
  preview-scoped REST surface (`rebuildPreviewNav`).
- Do not add a `read` of the nav state inside this effect. Reading nav state
  there would re-run the effect (unsubscribe → resubscribe churn) every time
  the handler rebuilds the nav model.
- Dead-drop recovery: the socket delivers no replay while disconnected
  (`doc/backend/websocket.md` → Known Limitations). The layout therefore
  registers an `onWebSocketReconnect` handler that runs the refresh, and a
  `visibilitychange` listener that calls `ensureWebSocketConnected()` when the
  tab comes back — tab sleep can sit out the close event, so the first retry
  must not wait on the reconnect backoff. Both live inside the WS effect and
  are cleaned up with `wsUnsubs`.

### Never use `setContext` / `getContext`

Avoid `setContext` and `getContext` entirely. They introduce invisible data flow that is untrackable by TypeScript, unverifiable by tests, and incompatible with Svelte 5's runes reactivity system.

`setContext` stores a value on the component instance, and `getContext` reads it from any descendant. This means:

- The receiving component's props are incomplete — you can't tell what it needs by looking at its prop signature.
- TypeScript has no way to validate that the context value is actually provided upstream.
- `$state` proxies are not reliably shared through context — mutations through `getContext` may not propagate.

**Use props instead.** Thread state explicitly through component props — the same way `document` is threaded through the Document View Template tree. If the prop chain feels deep, that's a signal to colocate state closer to where it's consumed, not to reach for context.

If you really need dependency injection (theme, locale), do it at the SvelteKit app shell level, not in component subtrees.

### Prefer `$derived` over `$effect`

Avoid `$effect` as much as possible. Rely on `$derived` and global `$state` as the single source of truth. `$effect` is fragile, hard to reason about, and often leads to cascading updates that are difficult to debug. The vast majority of derived state can and should be expressed as pure computations with `$derived`.

If you think you need `$effect`, first ask:

- Can I express this as a `$derived` from existing `$state`?
- Can I lift the state up and compute it in the parent as a `$derived` before passing it down?
- Can I use an `onclick`/`oninput` handler to mutate state directly instead of reacting to it?

Only reach for `$effect` when you're interacting with non-Svelte APIs (browser events, timers, 3rd-party libraries).

### The equality-guard trap in writeback effects

A common reflex when syncing a prop into a local `$state` is to add an equality guard so the effect does not write the same value twice:

```svelte
<!-- ❌ DO NOT DO THIS — looks safe, but breaks user input -->
let activeTab = $state(tab);
$effect(() => {
	if (activeTab !== tab) activeTab = tab;
});
```

**This clobbers user input.** Reading `activeTab` inside the effect body subscribes the effect to that `$state`. Because the effect also writes `activeTab`, the effect re-runs on every mutation of it — including user clicks that do `activeTab = newTab`. At that point the prop `tab` has not yet caught up (URL navigation via `goto` resolves asynchronously, `$bindable` round-trips through the parent on the next microtask), the guard sees `activeTab !== tab` is true, and writes `activeTab = tab` — reverting the click immediately.

The same trap clobbers form values (typed text reverts on every keystroke), radio selections, scope pickers, and any local `$state` that is both user-mutable and synced from a prop.

**Rule:** an effect that writes `$state X` must never read `X` for an equality check. Two safe alternatives:

1. **Write unconditionally.** A redundant `$state` assignment of an equal value is a no-op at the Svelte layer (no downstream ping for primitives; Svelte also short-circuits content-equal array writes when the proxy stays the same). Prefer this for primitive values whose setter cost is trivial.

   ```svelte
   let activeTab = $state(untrack(() => tab));
   $effect(() => {
   	activeTab = tab;
   });
   ```

2. **Dedup via a plain `let` shadow.** When the write is genuinely expensive (calls a fetch, writes to `localStorage`, etc.) and you want to skip redundant work, keep a plain-`let` shadow of the last-seen value. Plain `let`s do not subscribe on read and do not trigger on write, so the loop is broken:

   ```svelte
   // svelte-ignore state_referenced_locally — intentional initial seeding.
   let lastCollapsed = collapsed;
   $effect(() => {
   	if (collapsed !== lastCollapsed) {
   		lastCollapsed = collapsed;
   		writeAssistantCollapsed(collapsed);   // expensive side effect
   	}
   });
   ```

   Always pair the shadow `let` with a `// svelte-ignore state_referenced_locally` comment explaining the intent — the codebase already uses this convention (see `Schematic.svelte`, `ThoughtBlock.svelte`, `FloatingAssistant.svelte`).

#### Async-variant: cancelled promises returning stale data

The form-input case above clobbers **synchronously**. The same self-write trap also breaks **async** resolution inside an effect, and the symptom is much harder to spot — no value visibly reverts, the result simply never arrives. The canonical shape:

```svelte
<!-- ❌ The fetch result is discarded — chip stays at `entry.id` forever -->
let labels = $state<Record<string, string>>({});
$effect(() => {
	for (const entry of ids) {
		if (labels[entry.id] !== undefined) continue; // tracked read of `labels`
		labels[entry.id] = entry.id;                  // dirties the same signal
		fetchName(entry.id).then((name) => {
			if (!cancelled) labels[entry.id] = name;     // never runs
		});
	}
	return () => { cancelled = true; };
});
```

**What happens:** the synchronous seed write `labels[id] = id` dirties `labels`, which the guard line just tracked. Svelte re-runs the effect to reconcile. The previous run's cleanup flips `cancelled = true`. The microtask that resolves `fetchName().then()` runs **after** the cleanup, sees `cancelled`, and discards the result. The dedup guard then `continue`s past every entry on the re-run (they are all seeded), so no second fetch is kicked off — the labels stay frozen at the id fallback forever.

**Why the failure is silent:** there is no console error, no Svelte warning (a self-write of equal data is normally a no-op), and the component never unmounts. The only signal is "the async value never shows up." A `findByText(..., { timeout })` in a story `play` function times out; in the running app a chip or label sits at its fallback.

**Fix — the plain-`let` shadow, applied to a Set:** dedup on a plain `Set<string>` of in-flight ids instead of reading the `$state` map. Plain `let`/`const` collections do not subscribe on read and do not trigger on write, so the effect is never re-driven by its own seed write:

```svelte
const inFlight = new Set<string>();
$effect(() => {
	for (const entry of ids) {
		if (inFlight.has(entry.id)) continue;
		inFlight.add(entry.id);
		labels[entry.id] = entry.id;                 // seed fallback
		fetchName(entry.id).then((name) => {
			if (!cancelled) labels[entry.id] = name;
		});
	}
	return () => { cancelled = true; };
});
```

`untrack(() => labels)` around the dedup read is **not** sufficient in practice — Svelte still re-runs the effect on the property write inside the same tick, and the cleanup fire discards the in-flight promise. Reach for the plain-`let` shadow from the start.

#### `??` merge vs a settled `null`

A sibling trap, without any effect loop: merging a partial async update into a tri-state `$state` with `??`. When the producer uses `null` as a **settled result** ("the load ran and found nothing") and `undefined` as "not loaded yet", the idiom `state = update.x ?? state` discards the result: `null ?? undefined` evaluates to `undefined`, so the first load's answer never lands. The state stays `undefined`, every re-run re-fetches (the cache never converges), and a `{#if x}…{:else if x === null}…{/if}` chain matches no branch — the surface renders an empty body while any `loading` flag clears normally. Canonical example: `loadRelationTemplates` returns `{formTemplate: null}` for a child doctype with no stored `form` view, and the `??` merge kept `DvtRelation`'s editable row bodies empty forever (`relationTemplates.ts` documents the contract; `DvtRelation.svelte` `loadTemplates` does the merge).

**Fix — merge by key presence, not by falsiness:**

```ts
if (update.formTemplate !== undefined) formTemplate = update.formTemplate;
```

Reach for the key-presence merge whenever the update's `null` carries meaning; reserve `??` for updates where `null` and "absent" genuinely mean the same thing.

#### Diagnostic playbook — "$effect async result never appears"

When a `play` assertion fails on a `findByText`/`findByRole` that waits for a value produced by an async side effect inside a `$effect`, work through this order rather than guessing:

1. **Confirm the data layer is innocent first.** Reproduce the fetch in isolation, outside Svelte, against the same mock/seed the story uses. A one-file `server`-project Vitest (any path under `src/` matching `*.{test,spec}.ts`) keeps Svelte out of the loop. If `show()` / `list()` resolves correctly here, the bug is in the component's effect, not the mock.
2. **Log the effect lifecycle, not the data.** Add `console.log` at three points: the effect body entry, the `.then()` / `.catch()` callback, and the cleanup `return () => {}`. The ordering of those three lines in the test stdout tells you everything: `seed → cleanup → resolved(cancelled=true)` is the signature of the self-write trap above; `seed → resolved(cancelled=false)` with the wrong value means the fetch itself is wrong; `seed → destroy` with no resolution means the component unmounted.
3. **Confirm the effect re-ran with no work.** If you log the entry of the effect body and see two entries for the same `recent` identity with no `seed` line between them, the effect re-ran and `continue`d past every entry — that is the dedup guard eating its own seed write.
4. **Reach for the plain-`let` shadow from the start.** Do not attempt `untrack(() => state)` for async side effects — it does not break the cycle for property writes. Use a plain `Set` / plain `let` accumulator as the dedup source of truth.
5. **Only after steps 1–4, suspect the addon/Storybook.** Most "async value never appears" failures in `*.stories.svelte` `play` functions are NOT Storybook iframe quirks — they are this trap. Exhaust the effect diagnosis before blaming `@storybook/addon-svelte-csf` or `within(canvasElement)`.

### Reactivity — deep property mutations on shared proxy objects

Svelte 5 runes mode wraps `$state` objects in **proxies**. This works great within a single component, but tracking mutations across component boundaries is unreliable in several patterns:

| Pattern                                                    | Reliability                                                                                   | Example                                                                           |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `$derived(readProp)` reading a prop's deep property        | ❌ Does **not** re-evaluate when the child mutates the property                               | `$derived(field?.key)` in parent component                                        |
| `$derived(readProp)` reading a local `$state` property     | ✅ Works                                                                                      | `$derived(field.key)` in the same component that owns the field                   |
| `$effect` reading a deep property on a shared proxy object | ⚠️ Fragile — works only in the same component as the mutation, breaks through prop boundaries | `$effect(() => { field.key })` in the editor component that calls `field.key = v` |
| Same `$effect` reading a prop in the **parent** component  | ❌ Unreliable — the parent's read goes through a different proxy wrapper                      | Passing a derived error string from parent to child                               |

**Rule of thumb:** If a child component mutates a property on a shared `$state` object (e.g. `field.key = v` in an `oninput` handler), any logic that depends on that property should live in the **same component** where the mutation happens, not in a parent.

### `bind:value` vs. `oninput` sanitization

When an `<input>` uses `bind:value`, the DOM display is controlled by Svelte's binding. Even if the `oninput` handler sanitizes the value and writes to the model (`field.key = v`), the displayed value in the input will stay as the raw typed character until the binding re-renders. This makes it impossible to **filter out** illegal characters on input.

**Workaround:** Use a plain `<input>` with a `value` attribute (no `bind:`) and overwrite `target.value` in the handler to force the display.

```svelte
<input value={field.key} oninput={handleFieldChange} />

function handleFieldChange(e: Event) {
  const target = e.target as HTMLInputElement;
  let v = sanitize(target.value);
  target.value = v;   // force DOM display
  field.key = v;      // update model
}
```

### Selection tracking by object reference

When editing a list of objects where keys are mutable (e.g. renaming a doctype field's key), do **not** track selection by key string — mutation of the key will lose the selection. Instead, track by object reference:

```svelte
let selectedFieldRef: FieldDef | undefined = $state(undefined);
let selectedField: FieldDef | undefined = $derived(
  fields.find((f) => f === selectedFieldRef)
);

function selectField(field: FieldDef) {
  selectedFieldRef = field;
}
```

This works for both the currently-selected field being renamed and a different field being renamed.

### CodeMirror / dependency instance duplication

CodeMirror relies heavily on **object identity**: state effects, highlight tags, and views all use referential equality to work correctly. If Vite or the module bundler resolves the same package to two different instances, the symptom is typically a crash at editor creation or missing syntax highlighting.

#### Dependency pitfall: undeclared `@codemirror/*` sub-packages

`svelte-codemirror-editor` declares only `codemirror` (the meta-package) as a peer, but its compiled `CodeMirror.svelte` imports `@codemirror/autocomplete`, `@codemirror/commands`, `@codemirror/lint`, `@codemirror/search`, `@codemirror/state`, and `@codemirror/view` as bare specifiers. Under pnpm's strict layout those live inside `codemirror`'s store entry and are invisible from `svelte-codemirror-editor`, so the dev server fails with `Failed to resolve import "@codemirror/autocomplete"`.

The failed transform then leaks the raw Svelte source into the virtual style module (`?svelte&type=style&lang.css`), which Tailwind parses as CSS — the misleading `Invalid declaration: <script lang="ts" module>` overlay.

**Fix:** keep all six sub-packages declared as direct dependencies of `frontend/package.json`, pinned to the versions the `codemirror` meta-package already resolves (so pnpm dedupes to single instances). They are currently installed at these exact versions — if `codemirror` is ever bumped, re-check that all six still dedupe (`ls node_modules/.pnpm | grep '^@codemirror+'` should show one entry per package).

#### Symptom: `tags is not iterable` on editor instantiation

The error appears in the browser console and looks like:

```
CodeMirror plugin crashed: TypeError: tags is not iterable
    at HighlightStyle.style (@lezer_highlight.js)
    at highlightTags (@lezer_highlight.js)
    at HighlightBuilder.highlightRange (@lezer_highlight.js)
    at highlightTree (@lezer_highlight.js)
    at TreeHighlighter.buildDeco (index.js)
```

**Root cause:** Two different copies of `@lezer/highlight` (and/or `@lezer/common`) exist at runtime. One copy's `HighlightStyle` builds an internal lookup keyed on `Tag` object instances from its own copy; a parser or language emits `Tag` objects from a different copy. The lookup misses, the tags come back non-iterable, and the `style()` function crashes.

#### How to diagnose

First, check if the package manager has multiple physical versions:

```bash
# For npm
npm ls @lezer/highlight @lezer/common

# For pnpm
pnpm ls --depth=5 @lezer/highlight
```

If that shows a single version, the duplication may still happen at Vite's bundling layer. Look at the Vite pre-bundle cache:

```bash
ls node_modules/.vite/deps/@lezer_highlight* 2>/dev/null
ls node_modules/.vite/deps/@lezer_common* 2>/dev/null
```

If these exist, Vite pre-bundled the packages separately from the excluded CodeMirror packages that import them raw.

#### How to fix

Two changes to `vite.config.ts` are needed together:

1. **Add to `optimizeDeps.exclude`** — prevents Vite from pre-bundling these packages in the first place:

```ts
optimizeDeps: {
  exclude: [
    // ... existing excludes ...
    "@lezer/highlight",
    "@lezer/common",
  ];
}
```

2. **Add to `resolve.dedupe`** — forces Vite to resolve to a single copy even when different dependency paths point to the same package:

```ts
resolve: {
  dedupe: [
    "@lezer/highlight",
    "@lezer/common",
    "@codemirror/state",
    "@codemirror/view",
  ];
}
```

3. **Clear the stale cache** so Vite re-evaluates:

```bash
rm -rf node_modules/.vite node_modules/.cache/storybook
```

Then restart the dev server.

#### Prevention checklist

- When adding any CodeMirror extension or related package (e.g. `@codemirror/lang-*`, `@lezer/*`), check if it should be added to `optimizeDeps.exclude` and `resolve.dedupe`.
- The `?v=<hash>` suffix in the browser's stack trace filenames (`@lezer_highlight.js?v=37cc5812`) is the giveaway that Vite's pre-bundler has touched the file. If a file you expect to be excluded has a `?v=` hash, it's being pre-bundled.
- For pnpm specifically, `pnpm dedupe` can help resolve duplicate physical copies, but the Vite-level dedupe is still needed because the duplication happens at the bundler layer, not the package manager layer.

### Storybook dev server loads the app `vite.config.ts`

`@storybook/builder-vite` loads `frontend/vite.config.ts` into Storybook's own dev server (port 6006) and merges every field except `build`. The `@storybook/sveltekit` `viteFinal` strips only the two SvelteKit plugins (`vite-plugin-sveltekit-compile`, `vite-plugin-sveltekit-guard`); every other app plugin stays active. This is why Tailwind and paraglide need no Storybook copies — and why app-only server middleware must skip Storybook explicitly.

The origin guard (`facet-origin-guard`) is the example: the browser reaches Storybook as `http://localhost:6006`, a host the guard rejects with 421. It checks `process.env.STORYBOOK` (the Storybook CLI sets it before it loads the file) in addition to `process.env.VITEST`. Without that skip, the manager shell still loads from cache, but every fresh module request in the preview iframe gets 421 — the main panel spins forever, and the manager logs `No existing state found for follower with id: 'storybook/test'`.

### Storybook stories — CSF indexer and play-context args

Two constraints on `*.stories.svelte` files:

- **No `$state` (or any rune) in `<script module>`.** The addon-svelte-csf indexer parses the module script statically; a rune there raises `SB_SVELTE_CSF_PARSER_EXTRACT_SVELTE_0009` (a bare `MultipleIndexingError` with no source location) and the whole story file fails to load. Keep reactive state in the instance `<script>` or inside `args`.
- **Object mutations through `args` are invisible to the play function.** The play context receives a snapshot of args: a component mutating `args.values.foo` (the DVT input pattern) will never be seen by `expect(args.values.foo)`. Assert mutations through a prop the component calls (an `onchange` mock with `toHaveBeenCalledWith`) or through the DOM the component renders. Function references on args work normally because the component calls the captured mock.
- **Args are read-only — mutable bags go in as session-local clones.** DVT input components own their field in the `values` bag and write at init and on user input; a bag passed straight from `args` turns every write into a deep write through the Storybook args proxy. The write lands on the shared module-level initialArgs (per-test args are a shallow copy), leaks into the next retry, and re-runs renderer effects that track the args tree. Pass bags through `sessionBag(args.values)` (`session-bag.svelte.ts` next to the DVT components) — a session-local `$state` clone with fresh top-level containers, so in-place mutations (StringListEditor's push/splice) stay reactive but land on the clone.
- **The storybook project runs all files in one long-lived page** (`isolate: false` — a memory cap, see the `vite.config.ts` comment). Vitest keeps that iframe for the whole run and recreates it only after the last file; there is no page-restart hook between retry attempts. A crash that corrupts the page must be fixed at the source, not retried — hence the args rule above and the DVT dispatcher's missing-node diagnostic.
- **A retry re-runs the play against the previous attempt's side effects.** Same long-lived page, no state reset between attempts: a module-level mock driver keeps every conversation a timed-out attempt created, so a count assertion on the rail then fails on the retry (`expected 3 to be 2` right after a timeout pair). Plays that send messages must rebuild their driver at the top of the play (`resetPlay()` in `WorkspaceAssistant.stories.svelte`).
- **Keep a play's inner `waitFor` budget below the project `testTimeout`** (10s in `vite.config.ts`). When the two tie, the opaque test-level `Test timed out` fires first, points at the virtual module tail, and hides which wait failed. The scripted default scripts stream word-by-word — one thread re-render per chunk — and a full workspace turn is CPU-bound enough to outrun 10s on a CI runner; plays stream `collapseContentChunks(workspaceScript)` instead (`$lib/assistant/mock/scripts.js`), which renders the same text and tools at a fraction of the cost.

### Render-crash recovery — `svelte:boundary`

An uncaught error during render or in an effect tears down the component tree up to the root. The router dies with the tree, so every later navigation fails too; only a full reload helps. `ErrorBoundary` (`src/lib/components/primitives/surfaces/ErrorBoundary.svelte`) wraps `<svelte:boundary>` and contains this damage.

- `src/routes/+layout.svelte` wraps each page-content render in `<ErrorBoundary>` (Configure, consent, AppShell children, and the signed-out branch). A page crash shows the `ErrorFallback` card inside the workspace while the sidebar, top bar, and router stay alive.
- One outer `<ErrorBoundary level="app">` wraps the whole layout body as a last resort for crashes in the shells or the global hosts. Its fallback covers the viewport.
- `AssistantWindow` wraps its own body in `<ErrorBoundary>`. The floating window mounts at the root layout — outside the page-level boundary — and renders model-generated content (preview cards, document cards), so a crash degrades to the fallback card inside the window while the application stays alive; closing and reopening the window remounts a fresh boundary.

Recovery rules:

- **A failed boundary never re-renders its content on its own** — not even after a navigation. `ErrorBoundary` tracks `page.url` and drops the fallback when it changes, which mounts a fresh boundary around the new page. One click on a sidebar link (or a browser Back) recovers; Retry does the same in place.
- The boundary has **no `failed` snippet** by design: the server boundary then re-throws, so SSR errors still reach SvelteKit and render the normal error page. Only client-side render/effect errors land in the fallback.
- Boundaries catch synchronous render and effect errors only. Rejections after `await` and event-handler errors do not break the tree and are not caught. A bug in the root layout's own script cannot be caught from inside it.

Do not wrap single widgets (a table, a form) in their own `ErrorBoundary` unless a crash there must not take down the page — the page-level boundary is the default containment.

### Theme-dependent assets — follow the DOM theme, not the theme store

An asset that changes with the theme (the mono Logo mark: charcoal on light, white on dark) must switch through CSS with the dual selectors the token CSS uses — `[data-theme='dark']` (the app pins it on `<html>`) and `.dark` (the Storybook preview class). Do not branch on `getTheme()` from `theme.svelte.ts`.

- The theme store is **app-only**: `initTheme()` runs in `+layout.svelte`, never inside Storybook, so `getTheme()` always returns `'light'` there. A store-driven branch renders the light asset on dark surfaces in the dark preview.
- The pattern (`Logo.svelte`): render both variants and let CSS show exactly one — `display: none` removes the hidden variant from the layout and from the accessibility tree. A nested `data-theme='light'` re-pins the light variant inside a dark context (story cards use this to show both variants side by side).
- The same rule covers accessibility: when the brand mark sits next to the brand name as text, pass an empty `title` so the `alt` does not repeat visible text (axe `image-redundant-alt`); keep the label when the text is hidden (collapsed rail).
