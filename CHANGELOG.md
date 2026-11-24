# Changelog

Notable changes to Facet. The project is pre-1.0: a release can contain breaking changes.

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
