# Changelog

Notable changes to Facet. The project is pre-1.0: a release can contain breaking changes.

## 0.2.3 — beta (2026-11-28)

The new documentation site, a performance pass on the paths the 2026-11-27 load review flagged, and a developer-focused CLI. The grid gains an inline create line, filter bounds accept relative dates, and the domain-builder assistant no longer edits core doctypes without an explicit opt-in.

**Deployment notes**

- No new migration file. Migration `0001` gained the `idx_projections_doctype_created_at` index in its `-- UP` section, so a fresh database creates it. An upgraded instance does not re-run `0001` — the index is missing there and a doctype-wide `sort=-created_at` list keeps the slow plan. Create it once by hand:

  ```sql
  CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projections_doctype_created_at
      ON projections (domain, doc_type, created_at);
  ```

- The per-field extended statistics objects (see Performance) ride the index lifecycle: created with a field index, dropped with its last btree variant. Indexes that already exist keep running without one until the index is rebuilt or a new variant is added.

### Workspace UI

- **Create from the grid.** The grid surface gains a ghost line under the rows (the `allow_create` view flag AND the viewer's flat `create` grant): a `+` gutter, a "type to create" prompt on the first writable column, and the declared defaults previewing in the cells. Excel keyboard flow: typing opens the per-type editor from the create grant, Tab walks right, Enter commits; booleans stay inert until the row exists. The draft holds only committed values and the create body drops empty keys, so the server defaults apply; the create fires once the exposed required fields are filled, and the server re-checks everything on the POST. A `422` keeps the draft under error frames on the cells the details name; a `403` reverts, toasts, and locks the line off for the session. On success the row appends, a refetch restores the canonical order, and the fresh ghost line below takes the selection. The unsaved line reads red — the faint danger tint holds while the draft is staged, a create flies, or a `422` refusal stands, and drops when the create lands or Esc clears the draft.
- **The gutter is the row's commit status.** The line number yields to a spinner while the row has a write in flight — one edit, a pasted block (every touched row), or the ghost line's `+` on a create — and takes the danger tint with the first failure's tooltip when a write fails, the number staying so the row keeps its anchor. A success returns the plain number. Rejected writes keep the typed values in place (fix-and-retry, Esc is the explicit revert); the auto-revert stays a `403`-only contract. A failing cell also carries a floating failure label with the reason: the fields the `422` details name speak through the validation catalogue (format, duplicate, range), and the label holds only while the pointer sits on the cell. The grid's inline panels (enum listbox, floating editor frame, failure label) flip before paint when the grid's scroll box would cut them — upward when the room above holds them, right-aligned when the box cuts their right.
- The `/check` report — and the domain-builder agent's check tools — carries a warning when a show or form view template omits fields of the doctype. The show view requires every field except write-only ones; the form requires every editable field. Views without a template are skipped. The warning catches a doctype edit that left the views behind.

### HTTP API

- **Relative dates in filter bounds.** Every datetime-like bound accepts a relative value in place of an ISO-8601 one: `datetime` and `date` fields, the `created_at` / `updated_at` / `deleted_at` system columns, `period` / `dateperiod` range bounds, audit `emitted_at`, and assistant conversation timestamps. Grammar: `[+|-]<n><unit>` with units `y mo w d h m s` — `m` is a minute, `mo` a month, a leading `-` is the past. Months and years are calendar steps with a day clamp (`-1mo` from Mar 31 is Feb 28); weeks and below are fixed-length. On a date field the bound truncates to the UTC calendar day: `__lte` widens to the end of that day and `__gt` narrows to its start, the other operators stay exact, and a time-of-day unit against a date field answers `422`.

### Assistant

- `update_doctype` refuses a `core`-domain doctype unless the call passes `unsafe_core_edit: true`. The tool description and the system prompt warn that such an edit can break the application or block a future migration. The seed corpus reverts the tool change on the next boot.

### CLI

- **`setup-dev`** scaffolds, starts, and seeds a local dev instance from the GHCR images — no repository clone. It writes `compose.yml`, `config.dev.yml`, `.env` (mode 600), `Caddyfile.prod`, `facet.config.json`, and a `.gitignore`, then fetches the user's API key.
- **`connect`** signs in over OAuth and can issue a user-owned API key pinned to the active role, stored per folder (mode 600, gitignored). **`apikey`** prints the stored token for shell substitution. **`host`** prints the resolved instance URL with no trailing slash, so a request URL stays in one piece next to `$(facet-cli apikey)`.
- A new image-only compose stack (`docker/compose.ghcr.yml` + `docker/.env.ghcr.example`) pulls the published GHCR images and never builds. A `v*` release attaches `compose.yml`, `Caddyfile.prod`, and `.env.example` to the GitHub release, so an install needs no clone.

### Performance

- The 2026-11-27 load review closes three hot spots. Mutation coalescing deletes the folded row through its full primary key — the predicate named only `id`, could not use the key, and scanned the whole index (254 ms on a 2.6 M-row log). Doctype-wide `sort=-created_at` lists plan to the new `created_at` index instead of a parallel seq scan over the whole doctype. Equality filters on indexed fields use extended statistics objects created alongside each per-field btree index, so the planner stops preferring the primary-key walk of the default order.
- Import decodes and applies one row at a time inside the transaction instead of buffering every row's JSON tree — a 100k-row import peaked near 2.8 GB RSS and never released it between jobs. Each event's cause is buffered as a struct and serialized at flush, and one GC pass per job settles the high-water mark. Atomicity is unchanged: the whole file lands or nothing does.

### Fixed

- **Grant intersection.** A domain-wide role line (`{"on": "equipment", "action": "*"}`) or any ancestor line now intersects an app's grants. `Grant#covers?` compared paths as points and required the grant path to prefix the permission path, so the consent screen silently dropped such roles and key issuance refused them, while the same line worked on person channels. Observable on deployed instances: roles that previously vanished from consent screens or refused key issuance now qualify.
- **The sign-in form responds again under the 0.2.2 CSP.** The SvelteKit start shim is emitted at render time as a bare `<script>` tag, so the `script-src 'nonce-…'` policy blocked it: hydration never ran and every control was inert — the form fell back to a native submit that only reloaded the page. The shim now carries the nonce like the theme script.
- A connection whose statement was cancelled no longer returns to the pool with pending frames. The next user of the connection read them as its own answer and the driver reported a column type mismatch on a column it never selected. The pool discards such a connection and opens a clean one.

### Documentation

- The documentation site is rebuilt: five top tabs (Discover, Use, Build, Admin, Reference), the Brightwater Rentals running example carried through the pages, screenshots and theme-aware illustrations, a CLI-first quick start, and French translations beside the English pages. Every old URL answers a redirect — 288 of them. Request examples authenticate through the CLI (`$(facet-cli host)`, `$(facet-cli apikey)`) instead of placeholder credentials.

## 0.2.2 — beta (2026-11-26)

Workspace authoring and a security sweep. A new doctype starts with zero collection views, kanban boards gain per-view lane control and card moves, forms edit multi-reference fields as chips, and the 13 confirmed findings of the 2026-11-25 external security review are closed.

**Deployment notes**

- No new migration file.
- Compose deployments require `JWT_SIGNING_KEY` — a P-256 private key in PEM form (see `docker/.env.example`); the stack refuses to start without it. The backend reads the variable straight from the environment: without it, every boot minted a temporary signing key and each restart invalidated outstanding access tokens.
- The Caddy frontend now sets HSTS, `nosniff`, a content-security policy, and anti-framing headers; self-managed reverse proxies may want the same.
- The embedded seed corpus changed (email-id mentions). The next boot after the rebuild reconciles the drifted `core.Comment` script — no action beyond the normal rebuild and restart.

### Security

- iam — route identity comes from the verified auth context; every JWT claim read verifies the ES256 signature; change-password gains a per-account throttle; `/Api/iam/refresh` refuses app-scoped sessions; one live MFA challenge per account with a creation cap, and lockout blocks all.
- document — the field-visibility gate runs on filters and sorting (`403`) on the list and export paths; per-document sidecar handlers bind the sidecar target to the URL host record (non-disclosing `404`).
- oauth — `allowed_origins` validates at create and update (a bare origin, `https` on any host, `http` on loopback only); the MCP branch re-checks the redirect shape at consent and at code issue.
- lua — `string.find` / `match` / `gmatch` / `gsub` refuse an over-size subject or an over-complex pattern (more than 8 quantifiers) before the C matcher runs, closing the pattern-match time-limit escape.
- webhook — the transport dials the gate-checked IP while keeping the hostname for SNI and `Host`, closing the DNS-rebinding window.
- frontend — chat markdown applies a link and image scheme allowlist.

### Workspace UI

- **No default collection view.** A new doctype starts with zero views. The listing shows a starter screen — one card per layout (table, kanban, calendar) — that opens the view editor with the surface preselected; a view created there starts as a **personal** view. Without `create` permission on views the starter shows a note. Views created by earlier releases (the seeded `All Records`) remain; deleting the last view now stays deleted — the boot seed no longer recreates it.
- The doctype `/check` report (and the domain-builder agent's check tools) carries an `:info` notice — not a warning — when a doctype has no collection view.
- The grants editor renders named-action pills on child doctypes too. A custom action declared on a member-of child was ungrantable through the UI — the app token's effective scope never carried it and every invocation answered `403`. Activating a pill on an inherited child keeps the inherited level.
- **Kanban lane control and card moves.** A values-mode board orders and hides lanes per saved view (`config.kanban.lane_order`, `hidden_lanes`), and cards move between lanes by drag & drop when the view opts in (`allow_move` — absent keeps the board read-only, so deployed views are unaffected). A move writes the target lane's value through the document update path, gated on the viewer's update permission; lanes without a single writable `field__eq` filter accept no drops. Moves are optimistic and revert with a toast on failure. The kanban editor gains the lane list (visibility toggle, move up/down); hiding every lane blocks save.
- **Multi-reference fields edit as a chip list.** A `collection: true` reference field renders each stored target as a removable, hydrated capsule, with an embedded picker as the add control; a repeated target shows the same duplicate message the backend enforces. The fallback form renders it for `collection: true` references and arrays of reference too. Array bindings inside form templates stay read-only — `collection: true` is the supported declaration for an editable multi-reference field.
- Escape closes the peek drawer. When the drawer was reached through a reference, the first press walks back one entry of the nav stack and the next closes the drawer; loading, error, and tombstone states close too. An Escape a picker inside the drawer already handled is untouched.
- Reference picker — `Enter` no longer wipes a fresh pick (the chip row answers only its own keyboard events), focus moves to the chip row so the keyboard flow keeps working, and an embedded picker without a `Field` label names its combobox from the placeholder.

### HTTP API

- Child lists paginate. `GET /Api/:domain/:doctype/:id/:rel` now forwards the full list grammar — `page`, `items`, `sort`, `filters`, `select`, `scope`, `deleted`, `aggregate`, `field` — with the flat route's validation and defaults (`page: 1`, `items: 100`). Before, the route fixed page 1 at 1000 items and ignored every other parameter. Clients that passed `page` / `sort` to a child list and relied on the fixed answer must pass no parameters to keep the old (unsorted, first-page) shape. Child-list ETags changed value once (the fingerprint now covers page/items/sort); clients holding `If-None-Match` take one 200, then stable. Sidecar lists stay unpaginated.

### Audit

- Successful token refreshes stop writing `iam.LoginEvent` rows. A refresh ran on the 15-minute access-token clock, so an active session wrote four permanent rows an hour — rows nothing consumed and that 180-day retention never freed (a `LoginEvent` holds a single mutation, and the compaction cut refuses `idx <= 1`). One log line per refresh (`facet.iam.refresh` / `facet.oauth.refresh`) carries the trace instead; the security events (`refresh_reuse`, `refresh_failed`, lockout) stay. Code-only: historical rows are untouched.

### Fixed

- `GET /Api/:domain/Domain/:id/check` answered `500` (`DB::ColumnTypeMismatchError`) when a doctype's view declared a children-source relation — the view-template validator ran its nested query through a result set that was still open and desynced the connection.
- A denied draft-from names the requirement — "You must be an editor of domain 'X' to create a draft from it" — instead of a bare `403`.
- Mentions notify email-id accounts. Account ids are the account's lowercased email, but the comment scan, the notification queue, and document links all assumed a 26-char ULID, so a mention of a real account never notified. No retroactivity: an existing comment notifies when its body is edited again.

## 0.2.1 — beta (2026-11-24)

Post-release hardening. The first deployed instances exposed data-integrity, security, storage, and settings defects; this release closes them and lands the first usable npm packages.

**Deployment notes**

- No new migration file. `0001` and `0005` were edited to fold the unreleased `0012`–`0015` (which never ran on a deployed instance). A fresh database gets the final schema directly. A database that already ran `0001`/`0005` is unaffected.
- Lua limits and the snapshot interval moved to new defaults. Raise `lua.instruction_limit` / `lua.memory_limit_mb` / `lua.time_limit_s` (1M / 32 MB / 0.5 s) and `snapshot_every` (10) in `config.{env}.yml` if your hooks or scripts need the old budgets.
- `localization.default_timezone` now defaults to `auto` (the browser zone) instead of `UTC`.
- The backend image now ships `tzdata`. Re-pull the image; a non-UTC timezone setting answers `422` on the old image.
- Same-actor, same-channel plain document updates inside 3 minutes fold into one mutation row (`mutations.coalesce_window_minutes`, `0` disables). Set it to `0` if you depend on one mutation per request.

### Data integrity and security

- Document update — the update path locks the projection row (`FOR UPDATE`) before it authorizes, reads, and persists, closing a lost-update race that also affected Lua `document.update`, IAM patches, and app deploy.
- Named-id create — a transaction-scoped advisory lock serialises concurrent creates that derive the same id (account email, role name), so the second answers `409` instead of a silent duplicate success (fixed a duplicate OIDC provisioning).
- `unique: true` — a doctype update that adds the flag scans live rows and answers `422` naming the duplicates; the race window maps to the same `422`.
- CSRF — a new global handler answers `403` when a cookie-session request with a non-safe method lacks `X-Requested-With`; Bearer / DPoP requests without the session cookie stay exempt.
- RBAC scope gates — one SQL compiler now serves every surface. A `$parent_id`-scoped permission authorizes the single-document path (it denied every read, update, delete, and action before), `$parent_id eq $null` means root rows only on that path, and a missing row answers the non-disclosing denial.
- Lua sandbox — instruction, time, and memory budgets are per engine (they were shared class variables), and memory accounting works again. A hook refusal no longer leaks an open transaction and the projection row lock.
- Collection view gates — `config` is validated against the parent doctype at both write doors; `template` and `config` replace on write; `/check` warns on unservable group-by / discriminator fields.
- The audit route admits only the keys it reads (`422` otherwise); connection-level errors answer `503` naming the dependency; lowercase `/healthcheck` and `/metrics` answer `404` on every method.

### Storage (S3)

- Artifact serve and upload bypass two broken `shrine` S3 methods and use the `awscr` client directly: S3 reads return the object bytes (every S3 artifact served a truncated `200` before), uploads send an exact byte `Content-Length` (binary uploads failed at random), and a missing key answers `404` instead of `500`.
- New `Cron::ArtifactGrantPrune` removes artifact grants after a retention window past `expires_at`.

### Assistant

- Parallel agent threads — the chat panel keeps live turn state per conversation; switching conversations mid-stream is instant and several conversations can generate at once.
- Queued sends — a message typed while the agent works queues FIFO per conversation and drains when the turn settles; the composer stays editable with a queue hint, and the composer locks while an orphaned turn runs.
- Conversation titles — a conversation auto-titles from its first user message; `PATCH /Api/assistant/conversations/:id {title}` sets or clears it.
- Composer — `Enter` sends, `Shift+Enter` inserts a newline, `Ctrl`/`Cmd`+`Enter` still sends, and an IME composition `Enter` never sends.
- The workspace assistant is reachable on the Configure shell (`Mod+I` and the palette).
- `ok: false` tool results replay as errors instead of assistant text.
- Domain-builder tools gain `check_domain`; `check_doctype` names `CollectionView` configs, and a missing-argument error asks for a complete re-emit.
- A first-turn title write no longer answers `500` (`jsonb_build_object` could not infer the parameter type).

### Workspace UI

- List views — drag-reorder columns from the table header; the column picker offers computed fields; sort, filters, search term, and page size persist per view in `localStorage`.
- Array fields render as capsule chips instead of raw JSON in the table surface.
- Kanban surfaces fill the page and lanes scroll (cards keep their natural height).
- Saved collection views gain a delete affordance with a confirm; the DVT editor and the drafts surfaces refetch after external edits and navigation.
- The grants editor reads the canonical `create`/`update` grants, so grants authored outside the editor no longer render as `none`.
- `@` picker — `Enter` confirms the candidate while the popup is open; the next `Enter` sends.
- The minimized assistant bar is movable and resizable, with per-device persistence.
- The audit renders `LoginEvent` rows by label (they stored a NULL `display_name`), and `core.Comment` gains a `quickView` fixture.
- One money formatter (a value rounding to zero drops its sign); one column-label rule (`label` → `title` → humanize); file cells resolve the cached filename.

### Settings and timezone

- The backend image ships `tzdata`, so a non-UTC `core.timezone` setting saves instead of answering `422`.
- The `auto` timezone sentinel is a legal stored value and the default (`localization.default_timezone`); the settings page stores it verbatim and reverts the select on a failed save.

### Audit

- `iam.LoginEvent` attributes the resolved account as the actioner (synthetic principals keep `system`); `account_id` gains an equality filter and rides the boot seed reconcile on deployed instances.

### Packages

- `@facetapp/cli` `0.1.0` — deploys a static build folder as a new app revision, lists and activates revisions, and manages sign-in.
- `@facetapp/sdk` `0.1.0` — TypeScript SDK: documents, queries, actions, child collections, sidecars, aggregates, history, rollback, restore, backrefs, realtime, artifacts, and the caller's permission manifest. Zero runtime dependencies. First publish.
- `@facetapp/chat` `0.1.0` — the assistant chat as two custom elements, a `FacetAssistant` facade, and the driver layer. First publish.

### Fixed

- CI — the spec binary and the e2e backend build link with `--no-export-dynamic` (ELF symbol-version overflow), and the spec suite exports `DATABASE_URL` on a fresh checkout.

## 0.2.0 — V1 beta (2026-11-20)

First public beta: a document store with event sourcing for mid-sized organizations.

### Stable in this beta

- Document store — domains, doctypes with typed fields, JSONB projections
- Event sourcing — append-only mutation log, history view, rollback and restore
- RBAC — roles, named scopes, context sets, enforcement on every surface; an `anonymous` role served to credential-less API requests (read-only by default, seeded with `core.Currency`); process-local role content cache with event-bus invalidation
- IAM — accounts, passwords, TOTP MFA, sessions, JWT, static API keys, OIDC federated login
- Integrations — Redis event bus, webhooks with signed delivery and a reconcile backstop, background jobs, cron, domain hooks, WebSocket live bridge, cross-domain replication, sidecar doctypes, document import and export, transactional email
- Storage — artifact store with signed grants, operator download path and audited force delete (`iam.ArtifactEvent`), secret store
- Web application — table, kanban, grid, calendar, markdown, form, show, and relations surfaces; saved views; filter bar; notification centre; audit log UI
- OAuth 2.1 authorization server — PKCE authorization code flow for external apps; the `facet` CLI signs in through it
- App hosting — build upload through `facet deploy`, deployment serving, and host dispatch
- Domain-builder assistant — LLM-guided authoring of doctype definitions, views, and fixtures
- Workspace assistant — in-application chat with tool access to the workspace
- MCP resource server — tool access for external agents under one pinned role, with RFC 7591 dynamic client registration for MCP clients
