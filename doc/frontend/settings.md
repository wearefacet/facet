# Settings Page

The settings surfaces let the authenticated user manage their personal
preferences (timezone, language, notification delivery), their API keys, and
their webhooks. They are self-service surfaces — the user only ever touches
their own rows, enforced by the backend's SQL `WHERE account_id = $1` for
API keys and by an own-account list filter for webhooks.

- `/Settings` — personal preferences.
- `/Settings/api-keys` — API key management (create, one-time reveal, revoke).
- `/Settings/webhooks` — webhook management (create, edit, pause, delete,
  test, call log with replay).

Pinned doctypes are also stored as an account preference (`core.pinned_doctypes`)
but are managed from the sidebar (`NavPanel`), not the settings page.

## Layout

The personal preferences page uses the chaptered layout of the platform
settings page: a `PageHeader`, then a shell with a sticky chapter rail
(`ChapterNav`) on the left and one column of full-width groups on the right.
Each group owns its chrome — icon, uppercase heading, note — in the page;
the scroll-spy and the smooth scroll come from the shared
`createChapterScroll` helper (see
`primitives/surfaces/chapterScroll.svelte.ts`), the same mechanism the
platform settings form uses.

The chapters are General, Notifications, the admin-only Welcome tour, the
MCP endpoints, and the active sessions. `McpEndpoints` and `Sessions`
render their bodies only; the page owns the group chrome. Saves are
per-field and instant — each control flashes its own saved/error state, so
the page has no global save row.

## Source Files

| File                                                             | Role                                                                                                                                                                                                                                        |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/routes/Settings/+page.svelte`                               | Page component — the chaptered personal-preferences page (chapter rail + grouped sections) inside the `AppShell` chrome                                                                                                                     |
| `src/routes/Settings/api-keys/+page.svelte`                      | Page component — mounts the API key manager                                                                                                                                                                                                 |
| `src/lib/settings.svelte.ts`                                     | Reactive store — `loadSettings`, `saveTimezone`, `saveLanguage`, `savePinnedDoctypes`, `togglePinnedDoctype`, `savePinnedCollectionViews`, `togglePinnedCollectionView`, `saveShowWelcome`, `systemTimezone`, `displayTimezone`             |
| `src/lib/settings.spec.ts`                                       | Pure-logic tests — URL construction, CSRF header, `auto` sentinel, pinned-doctype and pinned-view round-trips, `show_welcome` mapping and write                                                                                             |
| `src/lib/iam/apiKeys.ts`                                         | Thin client for `/Api/iam/keys` — `listApiKeys`, `createApiKey`, `revokeApiKey` (injectable fetch)                                                                                                                                          |
| `src/lib/webhooks/webhooks.ts`                                   | Thin client for the webhook call-log routes — `listCalls`, `findCall`, `replayCall`, `testWebhook` (injectable fetch); the webhook documents themselves ride the standard DataSource layer                                                  |
| `src/lib/components/features/settings/ApiKeyManager.svelte`      | Key list + create button + revoke action; API surface is injectable for stories                                                                                                                                                             |
| `src/lib/components/features/settings/NewApiKeyDialog.svelte`    | Create form — name, role select (bindable `role` prop), optional expiry via the timezone-aware `DatetimePicker` (UTC RFC-3339 value; see `doc/frontend/datetime-picker.md`)                                                                 |
| `src/lib/components/features/settings/ApiKeyRevealDialog.svelte` | One-time raw-key reveal with copy button; the host clears the raw key from memory on close                                                                                                                                                  |
| `src/lib/components/features/settings/WebhookManager.svelte`     | Webhook list + create/edit dialog + pause toggle + secret copy + test dialog + delete confirm; embeds the call log per row. List CRUD rides `DocumentDataSource('core','Webhook')` with an own-account filter; every write is `can()`-gated |
| `src/lib/components/features/settings/WebhookDialog.svelte`      | Create/edit form — label, target URL, source doctype (`ReferencePicker` on `core.DocType`), the events tri-state ("all events" toggle + `StringListEditor`), and a headers key/value editor with the `X-Facet-` courtesy check              |
| `src/lib/components/features/settings/WebhookCalls.svelte`       | Per-webhook call log — newest first, status filter chips, prev/next pager on the `more` flag, expandable detail (error, receiver response snippet), replay with the async "queued" notice                                                   |
| `src/lib/components/features/settings/WebhookTestDialog.svelte`  | Runs `POST .../test` on open; renders the receiver's answer as data (status, duration, response snippet, signed body) — a receiver 4xx is a result, not an error                                                                            |
| `src/lib/components/features/welcome/WelcomeTour.svelte`         | First-run tour modal for admins — seven steps; gates on the active role and `core.show_welcome`; save + navigation are injectable props for stories                                                                                         |

## Backend API

The backend exposes a complete settings concern (`src/settings/`) with a
`account_settings` table, key registry, validation, and self-service HTTP routes
under `/Api/settings`. See [`doc/backend/settings.md`](../backend/settings.md)
for the full contract.

The settings page uses two endpoints:

| Method | Path                      | Purpose                                                                                                                                                    |
| ------ | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`  | `/Api/settings/core`      | Read all registered `core` preferences (defaults merged for unwritten keys)                                                                                |
| `PUT`  | `/Api/settings/core/:key` | Upsert a single preference; requires `X-Requested-With` header for a cookie session (CSRF — a Bearer/DPoP credential without the session cookie is exempt) |

The `/Api/iam/me` response also carries a `settings` block with the `core`
values, but the settings page loads fresh from `/Api/settings/core` to stay
self-contained.

## Timezone

- The page presents "Automatic ({zone})" as the first option, resolved
  client-side via `Intl.DateTimeFormat().resolvedOptions().timeZone`.
- Selecting "Automatic" PUTs the `"auto"` sentinel — a legal stored value
  (`Keys::AUTO_TIMEZONE` server-side): it means "follow the browser", and
  `displayTimezone()` resolves it at render time, so a user who travels
  keeps following their device zone without re-picking. Only the export
  body carries a concrete zone — the export resolves the sentinel
  client-side first (the server never converts with `"auto"`).
- The backend registry default for `core.timezone` and the built-in
  `localization.default_timezone` are both `"auto"`, so a fresh account on
  a stock install renders in its browser zone. An admin can pin the
  instance policy to a concrete IANA name (Configure → Platform →
  Settings); "Server default" then follows the pin.
- The timezone list is built from `Intl.supportedValuesOf('timeZone')` when
  available, with a curated fallback list for older runtimes. The list
  always contains `UTC`: `allTimezones()` adds it when the runtime omits it
  (V8 does). The builder lives in `src/lib/timezones.ts` (`allTimezones`,
  `zoneOffsetLabel`) and is shared with the platform SystemSettingsForm's
  default-timezone select.
- The first option after "Automatic" is "Server default ({value})" — the
  server-effective default from the `defaults` block of
  `GET /Api/settings/core` (the instance's `localization.default_timezone`
  policy; see `doc/backend/settings.md` → The default chain). Selecting it
  calls `clearSetting('timezone')` — `DELETE /Api/settings/core/timezone`,
  idempotent — and reloads the store, so the page shows the merged
  server-default value. The sentinel is frontend-only and never PUT.
- A plain "UTC" option (value `UTC`, label `UTC`) sits after "Server
  default", and `UTC` never renders as a continent group — the
  `(GMT{offset}) {city}` template has no city for it. The merged value can
  be `UTC` (a server policy that pins it, or an explicit choice), so the
  picker always holds an option that matches the bound value.
- A failed save reverts the select to the loaded value — the select
  binding flips before the PUT resolves, and the `catch` puts the stored
  value back so the picker never shows a state the backend refused.
- The language select carries the same server-default option; the concrete
  entries mirror the backend `ALLOWED_LANGUAGES` registry.

### Display timezone

`displayTimezone()` (in `settings.svelte.ts`) is the single resolver for the
zone datetimes render in: it returns the browser's zone when the stored
`core.timezone` is the `auto` sentinel (the default) or the store has not
loaded yet, and the stored concrete IANA name otherwise. Every surface that
shows or enters a datetime resolves through it
— `RelativeTime` (and therefore every table, audit, notification, and sidecar
timestamp), the audit detail labels, the API-key expiry note, the dashboard
day/night icon, `DatetimePicker`, and the table's "CSV — current view" export
(the resolved zone rides the export body — the export never receives the
`auto` sentinel) — so a settings change re-renders the affected surfaces.
Read the function inside a `$derived` or a template expression to keep that
reactivity.

`date` / `dateperiod` values are calendar dates, not instants: they render
verbatim (`YYYY-MM-DD`) and never pass through a timezone converter — the
same rule the backend storage contract sets (`doc/backend/workflow.md` →
Time / Timezone). Range fields render as `start → end` via
`formatRangeValue` (`dateperiod` bounds verbatim, `period` bounds through the
display timezone).

## Language

- The account's `core.language` value is the source of truth for the
  interface language. The concrete entries (`en`, `fr`) mirror the backend
  `ALLOWED_LANGUAGES` registry (`src/settings/keys.cr`). Adding a language is
  a one-line change in the backend registry and a new option in the frontend
  list.
- The Paraglide locale cookie (`PARAGLIDE_LOCALE`) is a **mirror** of that
  value, never an independent preference: it exists so the Paraglide
  middleware resolves the same language for every request between full
  reloads. `reconcileLocale` (`settings.svelte.ts`) runs after every
  successful `loadSettings` — the layout's boot effect, the settings page
  mount, and `clearSetting` all land there — and re-aligns the cookie when it
  disagrees with the stored language, so a stale cookie (backend re-init,
  another account on the same browser) self-heals on the next load. The
  mirror write is verified before the reload, so a refused cookie write
  degrades to "stay on the current locale" instead of a reload loop.
- Selecting "Server default" deletes the row (`clearSetting`); the store
  reload makes the `localization.default_language` policy value effective and
  re-syncs the cookie to it in the same pass.
- Pre-login surfaces have no account setting to mirror, so the cookie keeps
  its last value until the next authenticated boot reconciles it.

## Notifications

The notifications section persists one preference: the account's
`notifications.in_app` setting, registered in the backend's `notifications`
settings scope (see `doc/backend/settings.md` → Key registry). The toggle
reads through the notifications store (`ensureNotificationsPreference`) and
persists with `setInAppEnabled` (`PUT /Api/settings/notifications/in_app`,
with the `X-Requested-With` CSRF header). A failed write reverts the switch
and shows an inline error; a successful one shows the same per-field "Saved"
feedback as timezone and language. What the preference controls lives in
`doc/frontend/notifications.md` → Preference gate.

The email and digest toggles are gone: no delivery subsystem exists for them,
so the section shows only the control that does something.

## Welcome tour

The welcome tour is the first-run popup for admins — a seven-step modal that
positions Facet (a governance layer) and drives the first action: create a
domain or import a bundle. Its flag is the per-account `core.show_welcome`
setting (default `true`, see `doc/backend/settings.md` → Key registry).

- The popup shows on app load when the account's **active role** is exactly
  `iam.Roles.admin` (the seeded role — a bespoke admin-equivalent role does
  not match) and the flag is `true`. The component
  (`features/welcome/WelcomeTour.svelte`) mounts in the root layout next to
  `NotificationPanelHost`.
- The "Don't show again" checkbox writes the flag through `saveShowWelcome`
  (checked writes `false`, unchecking restores `true`) and never closes the
  popup: the open decision happened at app load, so the session keeps the
  popup open after the write. The close intents are the popup's close
  (`&times;`) button, `Esc`, the overlay click, and the final-step Done
  button. Closing on the final step writes `false` too: exiting at the end
  is a completed tour, so the popup does not come back at the next load. A
  failed write keeps the popup open and shows an error, and reverts the
  checkbox; a CTA does not navigate on failure. A close on an earlier step
  closes for the session only — the flag keeps its value.
- The CTAs hand off to `/Configure/domains`; the import CTA deep-links
  `/Configure/domains?import=1`, which opens the import dialog and strips the
  param (see `doc/frontend/configure-editors.md`). After the tour closes, the
  dashboard's `EmptyDomainsCard` carries the same call to action.
- The Settings section below renders only for accounts whose active role is
  admin: the toggle writes the flag through `saveShowWelcome`, so a flipped
  toggle opens the tour again at the next app load. A non-admin sees no
  section and no popup; the flag sits inert on their row.

## API keys

The API keys screen at `/Settings/api-keys` manages the caller's API keys
through the IAM endpoints (see `src/iam/routes.cr` and
[`doc/backend/iam.md`](../backend/iam.md)):

| Method   | Path                | Purpose                                                                                    |
| -------- | ------------------- | ------------------------------------------------------------------------------------------ |
| `GET`    | `/Api/iam/keys`     | List the caller's keys (never the secret — only `display_prefix`)                          |
| `POST`   | `/Api/iam/keys`     | Create a key (`name`, `role`, optional `expires_at`); the raw key is returned exactly once |
| `DELETE` | `/Api/iam/keys/:id` | Soft-revoke; idempotent                                                                    |

Behaviour:

- The entry point is the sidebar footer profile menu (`SidebarShell` →
  "API keys").
- The create dialog preselects the caller's **active role** (bindable `role`
  prop); the role must be assigned to the caller — the backend rejects
  anything else with a 422.
- The raw key is shown once in the reveal dialog. Copying uses the async
  clipboard API with an `execCommand` fallback for non-secure contexts.
  Closing the dialog drops the raw key from memory; the list only ever shows
  the `display_prefix`.
- Revocation asks through the global confirm dialog (`$lib/confirm.svelte`)
  and keeps the row visible with a "Revoked" badge; the backend keeps the
  record.

## Webhooks

The webhooks screen at `/Settings/webhooks` manages the caller's
`core.Webhook` documents — the outbound counterpart of API keys. A webhook
binds to the creating account (`account_id` + `role_id` stamped at create,
immutable), so the screen is self-service: the list filters to the caller's
own rows.

Backend surface (see [`../backend/webhook.md`](../backend/webhook.md)):

| Concern       | Path                              | Notes                                                                                                                                    |
| ------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Document CRUD | `/Api/core/Webhook...`            | The standard document API through the DataSource layer; every write is RBAC-gated (`create` / `read` / `update` / `delete core.Webhook`) |
| Call log      | `GET /Api/core/Webhook/:id/calls` | Paginated, optional `status` filter (`pending` / `succeeded` / `failed`); a denial is a non-disclosing 404                               |
| Replay        | `POST .../calls/:call_id/replay`  | Re-runs the enqueue-time RBAC gate; `202` with a fresh `job_id` — the new attempt appears in the log later                               |
| Test          | `POST .../test`                   | `200` regardless of the receiver's status — the receiver's answer is data, only a Facet-side failure is a 4xx                            |

Behaviour:

- The entry point is the sidebar footer profile menu (`SidebarShell` →
  "Webhooks"), next to "API keys".
- The list is narrowed with an `account_id` equality filter — the stored
  value is a qualified reference token (`iam.Account.<id>`), so the filter
  value gets the same qualification. The filter is a UI-level narrowing;
  a broad `read core.Webhook` grant would return other accounts' rows from
  the API itself.
- The `events` field is tri-state on the backend — _absent_ means all
  events, _empty_ means none. The dialog carries the absent state with an
  "all events" toggle; off shows a `StringListEditor` for the named subset.
  The update payload always carries the dialog's explicit decision, so a
  webhook can move between all-events and a subset through the form. The
  update hook rejects PATCHes touching `secret` / `account_id` / `role_id`
  with a 422.
- The per-webhook `secret` is readable any time (unlike the one-time API
  key reveal) — the row shows it with a copy button so the receiver can be
  configured to verify `X-Facet-Signature`.
- Replay shows the "queued" notice and refreshes the list; test probes
  (`job_id` null) carry no replay button.
- The call-log and test surfaces route through `src/lib/webhooks/webhooks.ts`
  (injectable fetch, `AuditSource` pattern); stories drive them with canned
  pages.

## Pinned doctypes

The account's pinned doctypes are stored under the `core.pinned_doctypes` key as a
JSON array of qualified doctype names (e.g. `["crm.Company"]`). The store
exposes:

- `getPinnedDoctypes()` — read the current list.
- `savePinnedDoctypes(names)` — PUT the whole list (the backend replaces the
  stored array wholesale).
- `togglePinnedDoctype(qualified)` — add/remove one name and persist. It
  updates the store optimistically and reverts if the backend rejects the
  write.

The sidebar (`NavPanel`) renders pinned doctypes in the **Pinned** section and
omits them from the **Doctypes** list. The root layout loads settings on the
client and rebuilds the nav model with the pinned set; pinning a doctype
triggers the same rebuild.

## Pinned collection views

The account's pinned collection views are stored under the
`core.pinned_collection_views` key as a JSON array of CollectionView projection
ids (ULIDs, globally unique — no doctype qualifier is stored). The store
exposes `getPinnedCollectionViews()`, `savePinnedCollectionViews(viewIds)`, and
`togglePinnedCollectionView(viewId)` (add/remove one view and persist, with
optimistic update + revert on backend rejection).

The listing component (`ListView.svelte`) shows a pin toggle for the active
collection view. It reads the pinned set from this store by default, but accepts
injected `pinnedViewIds` / `onTogglePin` props so stories and other surfaces can
drive the list without touching the backend. Pinning is surface-agnostic: it applies to any view on any surface (`table`, `calendar`, and
`kanban`).

## Store pattern

The settings store (`settings.svelte.ts`) mirrors the `theme.svelte.ts` /
`permissions.svelte.ts` pattern: module-level `$state`, getter/setter
functions, no `setContext`. State is **not** persisted to `localStorage` —
the backend is the source of truth.

## SSR safety

`loadSettings` accepts an optional `fetchFn` (SvelteKit's `event.fetch`) for
SSR-safe cookie forwarding. Module-level state writes are guarded on
`typeof window !== 'undefined'` so one account's settings never leak into
another account's SSR request.
