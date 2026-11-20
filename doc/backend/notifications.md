# Notifications

The in-app notification store: per-account messages in the `notifications`
table, produced by doctype Lua scripts, read and dismissed by the recipient
through self-service HTTP routes. A notification is **not** event-sourced —
it is a derived side effect, not an auditable business event — so it lives
outside `projections` / `mutations`, following the `account_settings` precedent.
There is no `core.Notification` doctype.

The recipient's `notifications.in_app` account setting (see
[`settings.md`](settings.md) → Key registry) gates the recipient's client-side
delivery — the bell, the badge poll, the WebSocket subscription. The gate is
presentation-only: `Send` inserts unconditionally, so nothing is lost while
the preference is off, and re-enabling shows what accrued. See
[`frontend/notifications.md`](../frontend/notifications.md) → Preference gate.

**Source files:**

- `src/notifications.cr` — namespace root
- `src/notifications/send.cr` — `Notification::Send` (the single write path)
- `src/notifications/queue.cr` — `Notification::Queue` (the deferred producer path: enqueue validation + drain)
- `src/notifications/list.cr` — `Notification::List`
- `src/notifications/mark_read.cr` — `Notification::MarkRead`
- `src/notifications/invoke_action.cr` — `Notification::InvokeAction`
- `src/notifications/routes.cr` — `Notification::Routes`
- `src/document/lua_notification_helpers.cr` — `LuaNotificationHelpers` (the `notification.*` Lua global)
- `db/migrations/0009_notifications.sql` — table, indexes, FK

## Storage

`notifications` (see `db/migrations/0009_notifications.sql`):

| Column | Type | Notes |
|---|---|---|
| `id` | text | ULID, generated Crystal-side |
| `account_id` | text | The recipient — bare `iam.Account` id. No FK: the store is a standalone side table; the enqueue-time account check is the producer guard |
| `domain`, `doc_type`, `doc_id` | text | The source document the notification points at; the frontend routes a click back to it |
| `kind` | text | Free-form discriminator (max 64 chars) |
| `icon` | text | Optional icon name (max 32 chars) |
| `title` | text | Required, max 256 chars |
| `body` | text | Longer text, defaults to empty string |
| `data` | jsonb | Structured context, defaults to `{}`. The reserved `download` key (a same-origin path) stages a file the recipient's panel offers as a download — the export jobs write it; see [`frontend/notifications.md`](../frontend/notifications.md) |
| `actions` | jsonb | Array of action descriptors, defaults to `[]` |
| `read_at` | timestamp | Nullable — `NULL` means unread |
| `actioned_at` | timestamp | Nullable — set on the first successful action; `NULL` means the actions are still live |
| `created_at` | timestamp | `now()` at insert |

Indexes: `notifications_account_unread_idx` (partial, `(account_id, created_at DESC, id DESC)` `WHERE read_at IS NULL`) serves the unread badge; `notifications_account_all_idx` (full, same columns) serves the paginated list. Ordering is always `created_at DESC, id DESC` — the ULID tiebreaker makes pagination deterministic for rows sharing a millisecond. This is an invariant of the API; no `sort` parameter is accepted.

Action descriptors are `{ key, label, variant?, confirm? }`. Every descriptor is a named doctype action on the notification's source document — the descriptor does not repeat the document reference. Keys starting with `__` are reserved; `__read` is the dismiss control and only lives on the HTTP route (`Send` rejects them at write time).

Actions are **one-shot per notification**: the first successful invocation stamps `actioned_at` and consumes every action on the row — the frontend disables all action buttons once it is set (UI/UX double-fire prevention), and `InvokeAction` rejects any later invocation with `409`. Dismissal (`read_at`) does not consume actions.

## Public API

```crystal
# Send one notification (the single write path — every producer goes through it).
Facet::Notification::Send.send(
  db, account_id, domain, doc_type, doc_id,
  kind, title,
  icon: nil, body: "", data: JSON::Any.new({} of String => JSON::Any),
  actions: [] of Facet::Notification::Action,
) # => SendResult(id, created_at)

# List one account's notifications (newest first).
items, count, more = Facet::Notification::List.list(
  db, account_id, only_unread: false, kind: nil, page: 1, per_page: 20)
Facet::Notification::List.unread_count(db, account_id) # => Int32

# Mark one / all read.
Facet::Notification::MarkRead.mark_read(db, account_id, id)   # => Bool
Facet::Notification::MarkRead.mark_all_read(db, account_id)   # => Int32 (rows affected)

# Execute a notification's action under the recipient's RBAC context.
outcome = Facet::Notification::InvokeAction.invoke_action(
  db, account_id, id, action_key, auth_context, args)
outcome # => InvokeResult(result: JSON::Any, read_at: Time, actioned_at: Time)
```

Semantics:

- `Send` raises `ArgumentError` on blank `account_id` / `kind` / `title`, on oversized `kind` / `icon` / `title`, and on `__`-prefixed action keys. A non-existent `account_id` surfaces as a PG foreign-key violation, unwrapped. `Send.validate!` is public — the queue reuses it as the authoritative validator at enqueue time.
- `list` returns `{Array(Item), Int32, Bool}` — the `Int32` is the page size, not the global total; the `Bool` is whether a next page exists (no second `count(*)` per page).
- `mark_read` is scoped by `account_id` and idempotent — it returns `true` only when an unread owned row transitioned.
- `InvokeAction` resolves the notification, verifies ownership, and finds the descriptor by `key` — in that order, with the one-shot guard between ownership and the key lookup: a notification whose `actioned_at` is set rejects every key with `409` (`InvokeAction::AlreadyActioned`), even a key it never had. It then dispatches through `Document::Action` — the same path `POST /Api/:domain/:doctype/:id/:action` takes (the action name is the one path segment after the document id; see [`http-layer.md`](http-layer.md) → Document routes). RBAC is enforced at execute time: a notification action is not a privilege escalation. On success the notification is marked read and `actioned_at` is stamped; a pre-existing `read_at` is preserved.

## Deferred producer queue

Notifications are low-quality data: a lost notification is acceptable, a notification that breaks a business mutation is not. Producers therefore never insert directly — `Notification::Queue` is the deferred path:

- `Queue.enqueue(queue, db, account_id, kind, title, icon:, body:, data:, actions:, doc_ref:)` validates synchronously and appends a `Pending` to the producer's queue. Nothing is inserted. It runs `Send.validate!` (the authoritative validator), a `doc_ref` format check (`nil`, or a qualified `{domain}.{Doctype}.{id}` via `DocURI`), and a cheap indexed `iam.Account` existence check — a typo'd account id raises `ArgumentError` at enqueue instead of a silent drop at drain.
- `Queue.drain(db, pending, domain, doc_type, self_doc_id)` applies the queue after the owning operation's mutation persists, on the same connection. `doc_ref = nil` resolves to the operation's own coordinates; an explicit `doc_ref` resolves via `DocURI`. Each insert goes through `Send.send` inside `Database.with_transaction(db)` — standalone its own transaction, inside an ambient transaction a savepoint — so one failed notification is logged (via `Log.for("facet.notifications")`) and dropped without aborting the already-persisted mutation or its sibling notifications. A crash between commit and drain loses the queued notifications; a transactional outbox is out of scope.

Queue scope is one queue per script evaluation context (one `ScriptContext`). A nested `document.create` inside a hook drains its own queue when the child operation persists; the parent's queue stays pending until the parent's own operation persists. The drain points are `Document::Create.create_from_parsed`, `Document::Update.call`, `Document::Delete.call`, and `Document::Action.call` — each drains only its own context's queue, and only after its operation succeeds, so notifications are never applied for a failed operation.

## Lua producer — `notification.send`

Registered on every `ScriptContext` that gets `document.*` (create, update, delete, action — see [`lua-engine.md`](lua-engine.md)). The helper validates its arguments and enqueues on the context's `Notification::Queue`; the owning flow drains the queue after its mutation persists. A malformed send raises a Lua error at send time, catchable with `pcall`. Uncaught, it fails the script and can prevent the rows from being created; the driver surfaces the unwind as a `422` refusal carrying the validation message with `code: "script"` — the same envelope a `ctx.error(msg)` call produces, never an opaque `500`. There is no insert and no transaction at send time: a successful send can never break or outlive the parent mutation.

```lua
-- notification.send(account_id, doc_ref, kind, title, [options])
--
--   account_id  string  The bare iam.Account id (or qualified
--                       "iam.Account.<id>", stripped defensively).
--   doc_ref     string  "{domain}.{Doctype}.{id}" — the document the
--                       notification is about. nil means "the document
--                       being mutated by the current hook", resolved at
--                       drain time — including from a create hook, where
--                       the generated document id does not exist yet.
--   kind        string  Free-form discriminator.
--   title       string  One-line summary.
--   options     table   Optional: icon, body, data (table), actions (array).
--
-- Each action descriptor: { key = "approve", label = "Approve",
--   variant = "primary", confirm = "Approve this request?" }
--
-- Returns true. Raises a Lua error on malformed input.
local ok, sent = pcall(
  notification.send,
  ctx.root.owner_id,               -- account_id (recipient)
  nil,                             -- doc_ref: nil = this document
  "leave_approved",                -- kind
  "Your leave request was approved",
  {
    icon = "check",
    body = "Approved by " .. tostring(ctx.actor_id),
    data = { previous_status = "pending" },
    actions = {
      { key = "reopen", label = "Reopen", variant = "primary" }
    }
  }
)
```

A bare `doc_ref` without the `domain.Doctype` prefix is rejected at send time, so the producer is explicit about all three coordinates. An explicit qualified string lets a producer point at a different document (e.g. a comment notification pointing at its parent conversation). The notification id is not exposed — notifications are not referenced from the document system.

## Seeded producer — `comment_mention`

`data/seeds/core.Comment/script.lua` ships the one seeded notification producer: a mention scan in the `core.Comment` create and update hooks.

- **Scan:** every `urn:facet:iam:Account:` URN in `body` with a length-26 id segment (link and bare forms), deduped. The author is skipped; system contexts (no actor) never notify.
- **Create** notifies every mention. **Update** notifies net-new ids only, on a real body change — a mention kept through an edit stays silent; a removed and re-added one notifies again (the hook diffs the previous body's scan).
- **Title:** `<actor label> mentioned you[ on <host label>]` — the actor label from the caller's account document, the host label from the comment's `target` document (first non-empty conventional name field — the Lua surface cannot render a doctype's `display_name` template). Both clipped to 80 chars.
- **Routing:** `doc_ref` is the comment's qualified `target`, so the notification points at the host document; `kind = "comment_mention"`, `icon = "at-sign"`.

Degradation is total, by design: every fetch and every send is `pcall`-wrapped, so a failed label lookup degrades the title (the suffix drops; a failed actor lookup yields "Someone mentioned you") and a failed send drops that one notification — neither can fail the comment. An unknown recipient account fails `Send.validate!` at enqueue, is contained the same way, and logs.

Cross-domain note: the host-label lookup is a `document.get` across domains — subject to the domain-grant ceiling like any cross-domain read. A deployment without an active `iam → core` grant degrades every title to the no-suffix form.

Specs: `spec/doctype/comment_mentions_spec.cr` (create/update/author-skip/degrade matrix).

## Event emission

Every successful insert publishes a `notified` event through `Event::Publisher`
(fiber-local enqueue; the owning flow flushes after its transaction commits, so
a rollback discards the event). The event rides the **source document's stream**
(`FACET:RESOURCE:{domain}:{doc_type}`), so it is ordered with that document's
other events. The event name lives in `Event::NOTIFIED`.

- **Content:** `{"id": "<source doc id>", "notification": {...}}`. The
  `notification` object carries `notification_id`, `account_id`, `domain`,
  `doc_type`, `doc_id`, `kind`, `icon` (null when absent), `title`, `body`,
  `data`, `actions`, and `created_at` (UTC RFC-3339).
- **Headers:** `domain`, `doc_type`, `actioner_id = "system"`. There is no
  `mutation_id` — a notification is not a mutation.
- **Fanout:** only `fanout:notifications:{account_id}`. The document fanout
  channel never receives the event, because a notification is private to its
  recipient and every watcher of the document listens on that channel.

### Webhook delivery

A webhook on the source doctype fires on `notified` only when its `events`
list names it explicitly. A match-all webhook (`events` absent) never fires
for it. The six-step `AuthCheck` authorizes against the source document — the
notification is about that document, so "the bound role can read it" is the
gate. See [`webhook.md`](webhook.md).

### WebSocket delivery

The recipient's UI subscribes once with the self-subscription path
`/notifications`. The channel is derived from the JWT subject — the path never
names an account, so a client can only reach its own channel. App-scoped
principals (app tokens, app-owned API keys) are refused the subscription —
the feed sits outside the app grant — with the standard non-disclosing error
frame. The frame shape matches document events, with `event: "notified"`. See
[`websocket.md`](websocket.md).

## HTTP routes

All under `/Api/notifications`, authenticated via the JWT `sub` claim. The SQL `WHERE account_id = $1` is the isolation boundary — there is no RBAC enforcer on read/mark-read routes (decision 6). POST routes require the `X-Requested-With` header (CSRF defense, decision 14); GET routes do not. Timestamps are serialized as UTC RFC-3339.

| Method | Path | Handler | Notes |
|---|---|---|---|
| `GET` | `/Api/notifications` | `Notification::List.list` | `?unread=true&kind=...&page=1&per_page=20` |
| `GET` | `/Api/notifications/unread_count` | `Notification::List.unread_count` | `{"count": N}` |
| `POST` | `/Api/notifications/:id/read` | `Notification::MarkRead.mark_read` | `{"id": ..., "read_at": ...}`; 404 on unknown/not-owned id |
| `POST` | `/Api/notifications/read_all` | `Notification::MarkRead.mark_all_read` | `{"marked": N}` |
| `POST` | `/Api/notifications/:id/actions/:key` | `Notification::InvokeAction.invoke_action` | Body is the optional argument object; 200 on success, 403 on RBAC denial, 409 when the notification already fired an action, 422 on unknown key, 404 on unknown/not-owned notification |

## Specs

- `spec/notifications/queue_spec.cr` — enqueue validation (blank/oversized fields, reserved keys, malformed `doc_ref`, unknown account) and drain semantics (FIFO order, `doc_ref = nil` resolution, log-and-drop isolation).
- `spec/notifications/send_spec.cr` — write-path validation, JSONB round-trip, reserved-key rejection, FK violation; the `notified` event (stream + account fanout only, payload shape, no `mutation_id`, no event on a failed insert).
- `spec/notifications/list_spec.cr` — ordering, pagination, filters, ownership isolation, unread count.
- `spec/notifications/mark_read_spec.cr` — idempotent mark-one/mark-all semantics.
- `spec/notifications/invoke_action_spec.cr` — dispatch envelope, RBAC denial, ownership, dismissal.
- `spec/notifications/routes_spec.cr` — auth, CSRF, isolation, action route matrix.
- `spec/document/lua_notification_helpers_spec.cr` — the Lua producer: hook contexts, `doc_ref` resolution (including `doc_ref = nil` from a create hook), send-time rejection, notify-then-fail, ambient-transaction drain, and dispatch target.
- `spec/doctype/comment_mentions_spec.cr` — the seeded `comment_mention` producer: create notifies every mention, update notifies net-new ids only, the author is skipped, system contexts stay silent, and the pcall degrades (failed label lookup, failed send) without failing the comment.

## Design decisions

Source comments and the `notifications` migration cite these plan decisions by number. The numbers are stable — do not renumber them.

- **Decision 6 — No RBAC enforcer on the read and mark-read routes.** The JWT `sub` claim selects the account, and the SQL `WHERE account_id = $1` is the isolation boundary — the same rule `account_settings` uses. `mark_read` is scoped by `account_id` and id, so an account cannot mark another account's notification.
- **Decision 7 — `account_id` carries no foreign key.** The store is a standalone side table; liveness is enforced at enqueue time (the `iam.Account` existence check), which is strictly stronger for producers than a cascade. An account that vanishes between enqueue and drain leaves an orphaned notification — harmless, unreadable, and pruned by no dedicated sweep today.
- **Decision 10 — Action execution dispatches through `Document::Action` under the recipient's RBAC context, with RBAC enforced at execute time.** A notification action is not a privilege escalation: the producer suggests an action, and the recipient fires it only when their own role permits it on the source doctype. A successful action marks the notification read and stamps `actioned_at`.
- **Decision 14 — POST routes require the `X-Requested-With` header; GET routes do not.** The routes are cookie-reachable and scoped only by the JWT subject, so the header check is the CSRF defense.