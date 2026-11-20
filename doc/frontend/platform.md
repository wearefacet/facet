# Platform Admin Surfaces (`/Configure/platform/*`)

**Files:** `frontend/src/routes/Configure/platform/indexes/+page.svelte`, `frontend/src/lib/components/features/platform/IndexesTable.svelte`, `frontend/src/lib/components/features/platform/IndexesSource.ts`, `frontend/src/routes/Configure/platform/artifacts/+page.svelte`, `frontend/src/lib/components/features/platform/ArtifactsExplorer.svelte`, `frontend/src/lib/components/features/platform/ArtifactsSource.ts`, `frontend/src/routes/Configure/platform/settings/+page.svelte`, `frontend/src/lib/components/features/platform/SystemSettingsForm.svelte`, `frontend/src/lib/components/features/platform/SystemSettingsSource.ts`

The Configure sidebar's PLATFORM section holds operator-level technical surfaces. The whole section renders only for roles with wildcard read — `can('*.*', 'read')` is the client-side admin marker (the backend re-checks every call). It carries the index status page and the artifact management page.

## Index status page (`/Configure/platform/indexes`)

The page tracks the managed indexes behind `GET /Api/Indexes` — one row per physical PostgreSQL partial index the `Index::Manager` owns, with its lifecycle status (see [`backend/index-management.md`](../backend/index-management.md)). The backend gates the read on wildcard `read *.*` (same rule as the global audit log); a denied caller sees the page-level `403` state, matching the "UI hints, backend decides" doctrine.

The page owns filter and pagination state and delegates rendering to `IndexesTable`. Index DDL runs in background fibers, so the table is a snapshot — the Refresh button re-fetches on demand. Each load carries a request sequence number, so a slow response can never overwrite a newer one (per-keystroke text filters interleave fetches).

### Data layer (`IndexesSource.ts`)

| Export | Description |
|---|---|
| `listIndexes(params, fetchFn?)` | `GET /Api/Indexes` via `apiFetch`; returns `IndexListResponse`. |
| `buildIndexesQuery(params)` | Builds the query string (`page`, `items`, `sort` joined by `,`, `filters[key]`). |
| `IndexesError` | `Error` carrying the HTTP `status`, so the page renders `403` distinctly. |
| `IndexesFetch` | Fetcher type; injectable for tests. |

`IndexRow` mirrors the `doctype_indexes` row: `id`, `domain`, `doc_type`, `field_name`, `index_type`, `index_name`, `status`, `error_message`, `created_at`, `updated_at`.

### Table

Columns: Domain, Doctype, Field, Type, Index name, Status (badge), Error, Updated. Identifiers and codes render in the mono face (`--font-mono`). The status badge pairs a weak tint with the matching full-colour ink: `active` → `--ok`, `pending` → `--info`, `error` → `--danger`, `dropped` → neutral (`--sunken` / `--text-2`). The error cell truncates with the full message on hover (`title`).

### Filters

`filters[status__eq]` (fixed list: `pending`, `active`, `error`, `dropped`), `filters[domain__match]`, `filters[doc_type__match]`, `filters[field_name__match]` (text inputs, case-insensitive `ILIKE` on the backend). Default sort: `-updated_at`. Pagination is prev/next driven by `meta.more`; the exact total shows only when `more` is false (count capped at 1000, same as every collection response).

### Testing

- `IndexesSource.spec.ts` — pure-logic Vitest (`server` project): query building, response parsing, error mapping.
- `IndexesTable.stories.svelte` — component tests via play functions: rows and status badges, empty state, filter interaction (status `Select`, text inputs), `more`-driven pagination, refresh button, error banner.

## Artifact management page (`/Configure/platform/artifacts`)

The page manages the artifact store behind `GET /Api/Artifacts` (see [`../backend/artifact.md`](../backend/artifact.md) → Admin surface). The listing, the per-artifact grant listing, and the reference listing all gate on wildcard `read *.*`; a denied caller sees the page-level `403` state. The design is a **master–detail** layout, deliberately unlike the flat index table: the left card lists artifacts (filename / ID / MIME filters, uploader capsule, live-grant and reference counts, tombstone badge, `more`-driven pagination); the right card shows the selected artifact — content facts (artifact id, MIME, size, upload date, uploader, SHA-256), a detail-header action row, the **Grants** table (kind badge, expiry, minter, revoke) and the **Referenced by** table (resource capsule, domain, doctype, field, last seen).

The detail-header action row carries two controls:

- **Open / download** — a plain anchor to the cookie-auth download gateway (`GET /Api/core/artifacts/:id/download`, built by `artifactDownloadUrl` in `$lib/artifacts.js`), opened in a new tab. The gateway mints a fresh grant on every click and the serve route decides view vs download by MIME type (`Content-Disposition: inline` for browser-safe types). The link hides for tombstones — the mint answers `410` there.
- **Force delete** — renders only for roles holding the operator `purge *.*` action (`can('*.*', 'purge')`), a UI hint the backend re-checks. It opens the shared `confirmWithText()` dialog (danger variant) whose optional **Reason** input rides to the backend and lands on the `iam.ArtifactEvent` audit record. A successful purge clears the selection and reloads the listing (the row is gone from the store); a `403` renders the permission message.

A `QuickViewHost` wraps the layout (the audit page's pattern): the account capsules on the **Uploaded by** column and the grants' **Minted by** column, and the resource capsule on the references' **Resource** column, open the peek drawer on click. Capsules hydrate through the shared `DocumentDataDriver`: the account capsule resolves the `iam.Account` display name; the resource capsule hydrates the document's `display_name` and falls back to the qualified `domain.Type.id` on failure. Values that name no account (`system`, the `app:<app_id>` sentinel) and references whose projection is gone (`doc_type` null) render as plain text. The **Uploaded by** column reads the original uploader from the listing row (`uploaded_by`); an artifact with no owner row (a system upload) renders an em dash.

Revocation asks for confirmation (the shared `confirm()` store), calls `DELETE /Api/core/artifacts/grants/:gid`, and refreshes both the grants list and the listing (the row's live-grant count changes). The revoke button renders only for roles holding the operator `revoke *.*` action (`can('*.*', 'revoke')`) — a UI hint; the backend re-checks and a `403` renders the permission message. An expired ephemeral grant dims its row and reads "expired" in place of the expiry date.

`confirmWithText()` is the text-capturing sibling of `confirm()` in `$lib/confirm.svelte.ts` — same dialog host (`ConfirmDialog.svelte`), same single-shared-surface rule; the optional `prompt` option renders one free-text input and the promise resolves `{ ok, text }` instead of a boolean. A cancelled dialog never leaks the typed text.

The page owns all state — filters, pagination, selection, detail fetches (request-sequence-guarded, grants and references in parallel) — and delegates rendering to `ArtifactsExplorer`. Selecting an artifact whose row leaves the current page (e.g. after switching to the Deleted state filter) clears the detail panel.

### Data layer (`ArtifactsSource.ts`)

| Export | Description |
|---|---|
| `listArtifacts(params, fetchFn?)` | `GET /Api/Artifacts` via `apiFetch`; returns the `{ data, meta }` response. |
| `listArtifactGrants(id, fetchFn?)` | `GET /Api/Artifacts/:id/grants`; grants newest first. |
| `listArtifactReferences(id, fetchFn?)` | `GET /Api/Artifacts/:id/references`; rows joined with the referencing projection. |
| `revokeArtifactGrant(gid, fetchFn?)` | `DELETE /Api/core/artifacts/grants/:gid` (the shared grant route); resolves on `204`. |
| `purgeArtifact(id, reason, fetchFn?)` | `DELETE /Api/Artifacts/:id` (the force-delete route) with the `X-Requested-With` CSRF header and the `{reason}` JSON body; resolves on `204`. |
| `buildArtifactsQuery(params)` | Builds the query string (`page`, `items`, `sort`, `filters[key]`). |
| `formatArtifactSize(bytes)` | Human-readable byte size (`512 B`, `20.0 KB`, `900 MB`). |
| `ArtifactsError` | `Error` carrying the HTTP `status`, so the page renders `403` distinctly. |

`ArtifactRow` mirrors the listing row (`id`, `filename`, `mime_type`, `size`, `sha256`, `deleted_at`, `created_at`, `uploaded_by`, `owner_count`, `grant_count`, `reference_count`); `ArtifactGrantRow` mirrors `artifact_grants`; `ArtifactReferenceRow` carries `domain`, `doc_type?`, `resource_id`, `display_name?`, `resource_field`, `last_reference_at`.

### Testing

- `ArtifactsSource.spec.ts` — pure-logic Vitest (`server` project): query building, response parsing, revocation call, force-delete call (CSRF header + reason body), error mapping, size formatting.
- `ArtifactsExplorer.stories.svelte` — component tests via play functions: rows with counts, the uploader column (hydrated capsule, plain-text branches, em dash for a system upload) and the tombstone badge, empty state, selection shows the facts (artifact id included), grants and references, capsule hydration (account display name, resource display name, failed-hydration fallback, plain-text branches) and the reference click callback, revoke fires the callback, revoke hidden without `revoke *.*`, filter interaction, download link (gateway href, new tab, hidden for tombstones), purge button fires the callback and hides without `purge *.*`.

## System settings page (`/Configure/platform/settings`)

The operator surface for the runtime platform configuration — the assistant connection, the mail connector, the artifact serving knobs, the data retention windows, the localization defaults, and the security policy (see [`../backend/system-settings.md`](../backend/system-settings.md)). The page loads the effective snapshot from `GET /Api/SystemSettings` (`values` keyed by dot-path + `pinned`) and renders the chaptered `SystemSettingsForm` — six groups (Assistant, Mail, Localization, Security, Artifacts, Retention), built on the form primitives (`Input`, `Select`, `Toggle`, `Button`, `Badge`). The page column is capped at 1120px; each group lays its fields out on a two-column grid (collapsing to one column below 760px), with wide full-row cells for the system-prompt textarea, the storage-adapter row, the mail adapter, and each group's closing behavior switch (Auto-execute tools, Use TLS).

- **Chapter rail.** A sticky rail on the left lists the six chapters with their icons (Bot, Mail, Globe, KeyRound, Package, History); the active chapter follows the scroll position, and a click scrolls the group into view (a smooth scroll that respects `prefers-reduced-motion`; the spy holds while the programmatic scroll passes the other chapters). The group headings carry the same icons. Below 900px the rail becomes a horizontal strip pinned above the groups.
- **Field chrome.** Every field carries a helper line under the control that states what the field does and what an empty value means ("Empty follows the file — default …"). There is no legend block: the helpers carry the meaning. The Mail group splits its SMTP transport fields under an `SMTP` sub-heading, separated from the top-level mail fields by a rule; the sub-section renders only when the adapter is `smtp` — the `none` option (Facet will not send email) keeps it out of the DOM, and choosing `smtp` reveals it before the save.
- **Groups.** Assistant (connection + sampling) and Mail (adapter, from-header, SMTP) as before. Artifacts carries the storage adapter as a **read-only row** (mono value, no input, no patch path — the adapter wires at boot from the config file, and a runtime switch would strand the existing bytes), plus the grant TTLs and the prune delay. Retention carries the edit-history window (`mutations.retention_days`) and the deleted-content window (`tombstone.content_retention_days`).
- **Pin visibility.** A path the document currently pins carries the `override` badge and a reset-to-file control; resetting puts an explicit `null` into the outgoing patch (the reset is pending until save — undoable). Unpinned fields show no badge.
- **Sparse save.** The Save button stays disabled until a field is dirty. The patch carries only the dirty fields (nested like the config file), with explicit `null` for pending resets and the single-use handle for rotated secrets — untouched fields keep their server state through the deep-merge PATCH. A `422` from the write-time gate renders its structured field errors (message + path badge) in the banner.
- **Secrets.** Secret fields (`assistant.api_key`, `mail.smtp.password`) show set/not-set from `pinned`, never a value. Rotation is one Save with two calls under the hood: the save stages each typed plaintext out-of-band (`POST /Api/secrets/stage`), swaps the single-use handle into the form state, and sends the sparse PATCH with the handles — a secret path never carries plaintext on the wire. A failed stage aborts the whole save with the error on the row; the plaintext stays in the input for retry.
- **Test email.** The Mail group closes with a **Send test email** panel: a recipient field (pre-filled with the signed-in account's address) and a button. The action posts to `POST /Api/SystemSettings/mail/test`, which delivers one email through the **saved** connector — the same path a password reset takes — and the panel reports the outcome inline ("Delivered via smtp to …", or the transport's own error on a `502`). The call blocks until the transport answers. A dirty `mail.*` path replaces the outcome line with a reminder to save first, because the test runs the saved connector, not the pending form state. The panel renders only when the page supplies `onTestMail`.
- **Test assistant.** The Assistant group closes with a **Send test request** panel — the mail test's counterpart, with no input field (the saved settings are the whole input). The action posts to `POST /Api/SystemSettings/assistant/test`, which sends one minimal, non-streaming completion through the **saved** assistant settings — the same path a chat turn takes — and the panel reports the outcome inline ("{model} replied: …", or the transport's own error on a `422`/`502`). A `422` means no API key resolves — the unconfigured posture; setting the key and saving is the fix. A dirty `assistant.*` path shows the same save-first reminder as the mail panel. The panel renders only when the page supplies `onTestAssistant`.

### Data layer (`SystemSettingsSource.ts`)

| Export | Description |
|---|---|
| `getSystemSettings(fetchFn?)` | `GET /Api/SystemSettings` via `apiFetch`; returns `{ values, pinned }`. |
| `saveSystemSettings(patch, fetchFn?)` | `PATCH /Api/core/SystemSettings/settings` with the `X-Requested-With` CSRF header; a `422` carries the parsed field details on the thrown `SystemSettingsError`. |
| `stageSystemSecret(fieldPath, value, fetchFn?)` | `POST /Api/secrets/stage` bound to `core.SystemSettings` / `settings`; returns the single-use handle. |
| `sendTestMail(to, fetchFn?)` | `POST /Api/SystemSettings/mail/test` with the CSRF header; returns `{ adapter, from_address, to }`. A `422` (connector off, bad address) and a `502` (transport failure) both throw `SystemSettingsError` carrying the backend message. |
| `testAssistant(fetchFn?)` | `POST /Api/SystemSettings/assistant/test` with the CSRF header; no body. Returns `{ model, endpoint, reply }`. A `422` (no API key resolves) and a `502` (provider or transport failure) both throw `SystemSettingsError` carrying the backend message. |
| `parseFieldErrors(body)` | Parses the backend's `422` `details` array into `{ field, message, code }` rows. |
| `SystemSettingsError` | `Error` carrying the HTTP `status` (and the `422` field errors), so the page renders `403` / `422` distinctly. |

### Testing

- `SystemSettingsForm.stories.svelte` — component tests via play functions: the chapter rail lists all six chapters and tracks selection, all groups render with override badges only on pinned rows, the per-field helpers render and the legend is gone (the system-prompt helper answers the empty-value question; the SMTP sub-heading renders only for the smtp adapter and is hidden under none; the storage adapter renders read-only with no input), the sparse save carries only dirty fields (including the artifact TTL and the two retention windows), reset-to-file sends the explicit null, save-time secret staging (Save stages the typed plaintext then patches with the handle — no plaintext reaches the DOM or the patch; both secrets stage in one save; a failed stage aborts the whole save and keeps the plaintext for retry; no stage button remains), set/not-set display from `pinned`, bool/number coercions, the adapter enum select (choosing smtp reveals the transport rows), the security chapter's generic enum selects (the auth-mode patch carries `iam.auth.mode`; the enforcement select follows the pending factor type and disappears under `none`), and the test-email panel (the recipient seeds from the account address, the send reports the transport, a transport failure renders the backend message, and a dirty mail path shows the save-first reminder).
