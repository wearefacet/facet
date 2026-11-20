# Notifications

The notification panel: the client-side view of the in-app notification store.
A bell in the Topbar shows the unread badge; the panel lists the account's
notifications, marks them read, and fires inline actions on their source
documents. The backend contract (routes, one-shot action semantics, event
fanout) lives in [`doc/backend/notifications.md`](../backend/notifications.md).

## Source files

| File                                                                      | Role                                                                                                                          |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `src/lib/notifications.svelte.ts`                                         | Reactive store — badge count, list state, WebSocket subscription, mark-read and action calls                                  |
| `src/lib/notifications.spec.ts`                                           | Pure-logic tests — API paths, CSRF header, page dedup, badge and stamp handling                                               |
| `src/lib/notificationDownload.ts`                                         | The reserved `data.download` key — reads the download path out of a row, same-origin paths only                               |
| `src/lib/notificationDownload.spec.ts`                                    | Pure-logic tests — the download key contract (present, absent, non-string, non-same-origin)                                   |
| `src/lib/components/primitives/surfaces/NotificationPanel.svelte`         | Presentational panel — rows, badge, action buttons, download button, empty state                                              |
| `src/lib/components/primitives/surfaces/NotificationPanelHost.svelte`     | Fixed-position mount rendered by the root layout — reads the store, owns the close → mark-read → navigate/download flow (`onnavigate` / `ondownload`) |
| `src/lib/components/primitives/surfaces/NotificationPanel.stories.svelte` | Stories with `play` functions — the component tests                                                                           |

## Store pattern

`notifications.svelte.ts` holds module-level `$state` — the same pattern as
`settings.svelte.ts` and `navCounts.svelte.ts`: getter functions, no
`setContext`. The backend is the source of truth; nothing persists to
`localStorage`.

## Preference gate

The account's `notifications.in_app` setting (registered in the backend's
`notifications` settings scope, default `true`) controls whether this client
receives in-app notifications at all. The gate is presentation-only: the
backend keeps inserting, so re-enabling shows the notifications accrued while
muted.

- `initNotifications()` reads the setting once (`GET
/Api/settings/notifications`) and starts the badge fetch, the poll, and the
  `/notifications` subscription only when it is `true`. The read fails open:
  a broken settings route shows the registered default, never a silenced
  bell.
- `isInAppEnabled()` returns the loaded value, or `null` before the first
  read. `bellProps()` treats every non-`false` value as on, so the bell never
  flickers off during load; the Topbar renders the bell only when
  `showNotifications` is on.
- `setInAppEnabled(v)` persists the setting (`PUT
/Api/settings/notifications/in_app`) and starts or stops the channels to
  match. Disabling stops the poll, tears down the subscription, zeroes the
  badge, and closes the panel — the shared socket stays connected, because
  builder subscriptions ride it too. It throws on a failed write; the Settings
  page reverts the toggle then. Enabling after a disabled init starts the
  channels through the same idempotent path.
- `ensureNotificationsPreference()` returns the preference, loading it if
  needed — the Settings page toggle uses it so the control reflects the
  stored value even when `initNotifications` has not resolved yet. An explicit
  write always wins over an in-flight read.
- `resetNotifications()` clears the preference with the rest of the state on
  logout; the next session reads it fresh.

The email and digest channel toggles are not shown anywhere: those delivery
subsystems do not exist, so no preference key is registered for them.

## Bell wiring

`bellProps()` is the single wiring point for the Topbar bell. It returns the
`showNotifications` flag (on unless the preference is explicitly `false`), the
unread count, and the panel toggle handler. Both shells that render the bell —
the live AppShell and the Configure shell — spread it onto the `Topbar`, so the
two modes share one button and one behaviour. Builder mode has no bell: its
top bar carries draft controls only. `NotificationPanelHost` mounts once at
the root layout for both bell-bearing shells; the panel can open only where
the bell exists.

## Live updates

- `initNotifications()` runs once from the root layout on the live and
  Configure routes when the session is authenticated (the notification routes
  reject the preview token, so a preview session starts no channel). It
  fetches the unread count, subscribes to the
  `/notifications` WebSocket self-subscription path, and starts a 60 s badge
  poll (visible tabs only). The WebSocket bridge has no replay, so events
  missed while disconnected surface on the next poll.
- The subscription is the self-subscription path `/notifications` — the path
  never names an account, because the server derives the fanout channel from
  the JWT subject. A client can reach only its own channel.
- A `notified` event refreshes the badge count, and the list too when the
  panel is open.
- `resetNotifications()` clears all state, the poll timer, and the
  subscription. It runs on logout, and it disconnects the shared socket — the
  socket's auth context was captured at upgrade time, so a different account
  signing in on the same tab needs a fresh connection.

## List state

- `getNotificationItems()`, `hasMoreNotifications()`,
  `isNotificationsLoading()` — the page rows (newest first, the API's fixed
  order), the `meta.more` flag, and the in-flight marker.
- `toggleNotificationPanel()` / `closeNotificationPanel()` — open and close.
  Opening refreshes the list and the badge, so rows mutated elsewhere never
  render stale. The list is lazy: page 1 loads on first open.
- `loadMoreNotifications()` — appends the next page; `meta.more` gates it.
  Later pages dedup by id, so a row created between two fetches does not
  appear twice.

## Mark read

- `markNotificationRead(item)` — `POST /Api/notifications/:id/read`, with the
  `X-Requested-With` CSRF header. A no-op for rows that are already read. The
  row updates only after the API confirms, so a failed call leaves the state
  honest.
- `markAllNotificationsRead()` — `POST /Api/notifications/read_all`. Stamps
  the unread rows and zeroes the badge after the API confirms.

## Download notifications

A producer may stage a file under the reserved `data.download` key of a
notification — a same-origin path. The document-export and portable-domain
export jobs write it: the download URL of the finished export (see
[`backend/import-export.md`](../backend/import-export.md)).

`notificationDownloadUrl(item)` (`src/lib/notificationDownload.ts`) reads the
key and returns the path only when it is a same-origin one: it must start with
`/` and must not be protocol-relative (`//`, `/\`). The field is
producer-writable — the Lua `notification.send` helper takes arbitrary `data`
— so an absolute or malformed value renders nothing and never navigates.

A row with a download path behaves differently from the rest:

- The panel renders a **Download** button in the action row, beside any
  doctype actions. It is not a doctype action — `actioned_at` never gates it
  and firing it consumes nothing.
- The row's click target downloads the file instead of navigating to the
  source document (an export notification points at the `core.DocType`
  registration, which is not where the file is). The row's aria label reads
  `nav_download_notification_aria` to match.
- Both affordances run the same host flow as opening: close the panel, mark
  the row read, then the layout triggers the download through
  `window.location.assign` — the backend answers with
  `Content-Disposition: attachment`, so the page stays. This is the same
  contract the export toast's plain link uses.

## Action dispatch

`fireNotificationAction(item, action)` posts to
`/Api/notifications/:id/actions/:key`. When the descriptor carries a
`confirm` string, `window.confirm` shows it first (browser only). Actions are
one-shot per notification: on success — or on `409`, which proves the server
already consumed the actions — the store stamps `read_at` / `actioned_at`
from the response. That stamp is exactly what disables the panel's action
buttons. Navigation to the source document belongs to the host (the layout
navigates to `/{domain}/{doc_type}/{doc_id}`); the store only marks the row
read.

## Panel component

`NotificationPanel.svelte` is presentational: props in, callbacks out, no
backend calls. `NotificationPanelHost.svelte` is the mount the root layout
renders: it reads the store getters, applies the fixed positioning (top-right,
below the Topbar bell), and owns the open flow — close the panel, mark the row
read, then hand the item to the caller's `onnavigate` (navigation stays out of
the store, and the store stays free of SvelteKit).

Props: `notifications`, `more`, `unreadCount`, and the callbacks `onaction`,
`ondownload`, `onopen`, `onmarkallread`, `onclose`, `onloadmore`. The types
`NotificationItem` and `NotificationActionDescriptor` are exported from the
component and imported by the store.

Rendering rules:

- The item body is one click target that reports `onopen` — or, when the row
  carries `data.download`, the layout downloads instead (see Download
  notifications); the action row sits outside it, so buttons never nest.
- A row with `data.download` renders a `Download` button in the action row;
  rows without it never do. Action buttons map the producer's `variant` hint
  (`"primary"`, `"danger"`) onto real button variants; other values render as
  `secondary`.
- Unread rows show an accent dot and bold title; `RelativeTime` renders the
  age of `created_at`.
- The icon resolves through the doctype Lucide catalog, with a `Bell`
  fallback for names that do not match.
- When `actioned_at` is set, every action button renders disabled and an
  "Action taken" marker shows — one click consumes every action on the row.
- `unreadCount > 0` shows the badge and the "Mark all read" button;
  `more` shows the "Load more" footer. An empty list shows the
  "You're all caught up" state.

## SSR safety

Every store entry point is a no-op on the server
(`typeof window === 'undefined'`), so one account's notifications never leak into
another account's SSR request. Confirmation prompts are browser-only for the
same reason.

## Testing

The stories are the component tests — each `play` function asserts behaviour
against the rendered panel: mixed rows, one-shot action disabling
(`FiredActionDisablesAllActions`), the actioned state, the empty state, mark
all read, load more, open reporting, the download affordance
(`DownloadNotification`), and the anchored-to-bell composition. The host
stories cover the open flow and the download flow (close, mark read, hand to
the caller). `notifications.spec.ts` and `notificationDownload.spec.ts` cover
the store's and the download key's pure logic in the `server` Vitest
project.
