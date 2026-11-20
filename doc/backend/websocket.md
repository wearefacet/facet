# WebSocket Real-Time Bridge

**Files:** `src/websocket.cr`, `src/websocket/manager.cr`, `src/websocket/connection.cr`, `src/websocket/subscription_resolver.cr`, `src/websocket/route.cr`

The WebSocket concern provides real-time document change delivery over a single `/Ws` endpoint. Authenticated clients send `subscribe`/`unsubscribe` JSON frames referencing single-document resource paths. The server resolves each path to its Redis fanout channel, checks RBAC read access, and registers the connection against that channel in a process-singleton `Websocket::Manager`.

---

## Source files

| File | Role |
|---|---|
| `src/websocket.cr` | Namespace root — requires sub-files, declares `Facet::Websocket::Log` |
| `src/websocket/manager.cr` | `Websocket::Manager` — process singleton; owns `listened_resources` map; wraps an `Event::Subscriber::Fanout` as its pub/sub driver |
| `src/websocket/connection.cr` | `Websocket::Connection` — wraps one `HTTP::WebSocket`; handles incoming JSON frames; lifecycle cleanup |
| `src/websocket/subscription_resolver.cr` | `Websocket::SubscriptionResolver` — resolves a resource path to `{domain, doc_type, doc_id, fanout_channel}` and runs the RBAC read check |
| `src/websocket/route.cr` | `Websocket::Route` — registers the Kemal `ws "/Ws"` handler; per-request origin allowlist, `HandshakeHandler` for the `Sec-WebSocket-Protocol` token transport, auth at upgrade |

---

## Components

### `Websocket::Manager` (process singleton)

| Method | Returns | Description |
|---|---|---|
| `new(fanout)` | `Manager` | Creates a manager with an injected `Subscribable` pub/sub driver |
| `instance` | `Manager` | Returns the singleton or raises |
| `instance?` | `Manager?` | Nilable variant — never raises; used by the shutdown path |
| `instance=` | `Nil` | Sets the singleton |
| `start` | `Nil` | Starts the fanout driver |
| `stop` | `Nil` | Stops the fanout driver |
| `register(conn, channel, cap = nil)` | `Bool` | Registers a connection; subscribes channel if new. With `cap`, registration fails (`false`) when the channel already holds `cap` subscribers |
| `unregister(conn, channel)` | `Nil` | Unregisters a connection; unsubscribes if empty |
| `unregister_all(conn)` | `Nil` | Removes connection from all channels |
| `track(conn)` / `untrack(conn)` | `Nil` | Marks a connection live/dead in the manager's full connection set (including sockets with no subscriptions, which never appear under a channel) |
| `close_all` | `Nil` | Closes every tracked connection with a close frame — the graceful-shutdown step (see [`shutdown.md`](shutdown.md)); one failing close does not stop the others |
| `dispatch(channel, message)` | `Nil` | Delivers a message to all connections on the channel; collection channels and aggregate `child_changed` frames take the RBAC-filtered path |

The manager wraps an `Event::Subscriber::Fanout` as its pub/sub driver. The `Subscribable` module defines an interface (`subscribe`, `unsubscribe`, `start`, `stop`, `started?`) that both `Fanout` and test doubles satisfy. `Fanout` is declared to include `Subscribable` — see `manager.cr`.

Connection modes: the per-emit RBAC checks (collection dispatch, aggregate `child_changed`, subscription resolution) run on `Database.with_db(:read_only)` — one ro pin per message. The dispatch fibers write nothing; a write there would fail loud under the ro enforcement hook.

### `Websocket::Connection`

| Method | Returns | Description |
|---|---|---|
| `new(socket, auth_context)` | `Connection` | Wraps a WebSocket with an RBAC auth context |
| `run` | `Nil` | Sets up frame handlers and enters the read loop |
| `deliver(message)` | `Nil` | Serializes an `Event::Message` to a JSON text frame and sends it |
| `close` | `Nil` | Closes the underlying socket |
| `handle_frame(data)` | `Nil` | Parses an incoming JSON frame and dispatches subscribe/unsubscribe |

**Incoming frame protocol:**

```json
{"action": "subscribe",   "args": ["/hr/Employee/e1", "/hr/Employee/e2"]}
{"action": "unsubscribe", "args": ["/hr/Employee/e1"]}
{"action": "unsubscribe", "args": ["*"]}
```

**Outgoing frame shape:**

```json
{
  "channel": "fanout:hr.Employee:hr.Employee.e1:updated",
  "event":   "updated",
  "payload": {"id": "hr.Employee.e1"},
  "headers": {"mutation_id": "01J...", "actioner_id": "account_1", "domain": "hr", "doc_type": "Employee"}
}
```

The `channel` value is the resolved event channel: `Event::Message.unpack`
appends the frame's `event` header to the fanout channel. A client matches a
frame to its subscription by channel prefix, not by equality.

**Frame contract for client refreshes:** a frame whose `payload.id` names a
subscribed document is a mutation of that document. This holds for every
event name — `created`, `updated`, `deleted`, and each named-action event
(for example `closed`). `child_changed` is the one exception: the frame is
keyed to the parent, and its `payload.id` names the parent, so it never
describes the parent's own content.

### `Websocket::SubscriptionResolver`

| Method | Returns | Description |
|---|---|---|
| `resolve_and_authorize(db, path, auth_context)` | `Resolved \| Error` | Resolves a path and checks RBAC read access |
| `resolve_channel(path)` | `String?` | Computes the fanout channel string (no DB/RBAC, for unsubscribe) |
| `notifications_path?(path)` | `Bool` | True for the `/notifications` self-subscription path (any equivalent spelling) |
| `notifications_channel(auth_context)` | `String` | The caller's own notifications fanout channel, from the principal |

**Path grammar**:

- `/domain/Doctype` — **collection subscription** to the whole doctype
  channel `fanout:{domain}.{doc_type}` (see § Collection subscriptions)
- `/domain/Doctype/:id` — root document
- `/domain/Doctype/:id/:rel/:child` — nested child document
- `/notifications` — self-subscription to the caller's own notification
  channel (`fanout:notifications:{account_id}`, derived from the
  authenticated principal). The path never names an account, so a client
  can only reach its own channel — no RBAC check is needed.

Deeper even segment counts (a path ending with a relationship name = a
list-of-children) are rejected with a 400 error.

**Fanout channel format:** `fanout:{domain}.{doc_type}:{doc_id}` for a
document, `fanout:{domain}.{doc_type}` for a collection — both match
`Event::Manager#publish_resource_event`.

### `Websocket::Route` (Kemal `ws "/Ws"` handler)

- Origin validation against `Config.instance.host` **plus every origin
  registered on an active `app.App`** (`OAuth::OriginCache`, the same set
  `OAuth::Cors` mirrors for `/Api/*`), checked per request
- Token transports, in selection order:
  1. `Sec-WebSocket-Protocol` bearer entry — `facet-ws-v1, <app JWT>`, for
     browser apps (see § App tokens on the handshake)
  2. Cookie / `Authorization: Bearer`/`DPoP` via
     `AuthHandler.auth_context_from_request` (transport-independent)
- Test mode: when `AuthHandler.enabled? == false`, uses `AuthContext.system`

Close codes:

| Code | Meaning |
|---|---|
| 4401 | Authentication required / invalid token |
| 4403 | Origin not allowed |

RBAC denial on a `subscribe` frame is **not** a close — it sends a text error frame and the socket stays open.

### App tokens on the handshake

A browser cannot set an `Authorization` header on a WebSocket upgrade, and
the `auth_token` cookie does not travel cross-site (`SameSite=Lax`). Apps
therefore authenticate the upgrade through `Sec-WebSocket-Protocol`:

```js
const ws = new WebSocket("wss://facet.host/Ws", ["facet-ws-v1", accessToken]);
```

`Websocket::Route::HandshakeHandler` (registered before Kemal's upgrade
handler) reacts to a JWT-shaped entry in the offered list:

1. Strips the token from the request header — no downstream layer can echo
   it back.
2. Answers the 101 with `Sec-WebSocket-Protocol: facet-ws-v1` (browsers
   require the echo to come from the offered set).
3. Hands the token to `HTTP::AuthHandler.auth_context_from_token` with the
   `WS_SUBPROTOCOL` scheme.

The transport is **`typ: "app"` only**. Static `fct_` keys, browser-session,
and preview tokens are rejected on it (4401), and a DPoP-bound token fails
closed — the handshake cannot carry a proof. An app-scoped `AuthContext`
carries the same grant ∩ role ceiling as on REST: subscribe-time checks and
the per-emit collection filter run through `ReadEnforcer`, whose Layer-1
pre-check consults the app grant (fail-closed). The captured grant lives as
long as the socket — a grant change applies on reconnect, matching the role
capture contract (never leaks on revocation; accepts staleness on grant).

The `/notifications` self-subscription is refused to app-scoped principals
(error frame, socket stays open): the channel is the account's private
notification feed, which sits outside the app grant and has no RBAC on the
path.

---

## Configuration

The `host` key in `config.{env}.yml` names Facet's own origin — always
allowed on `/Ws`:

```yaml
host: "localhost:3000"
```

Default: `"localhost:3000"`. Every origin registered in an active app's
`allowed_origins` is allowed additionally (no config change — the list is
live and event-invalidated through `OAuth::OriginCache`). Origins registered
nowhere close with `4403`; absent `Origin` (header-capable non-browser
clients) is allowed and still authenticates.

Kemal's own upgrade gate is switched to its `"*"` escape hatch
(`Kemal.config.websocket_allowed_origins`) at registration: Kemal 1.13 would
otherwise reject cross-origin and missing-`Origin` upgrades with an HTTP 403
before the route block runs. Origin enforcement happens inside the block —
same allowlist, one notch later (post-upgrade close instead of HTTP 403).

The optional `websocket` section tunes the collection-subscription cap:

```yaml
websocket:
  collection:
    max_subscribers_per_doctype: 32
```

Default cap: `32`.

---

## Wiring (`main.cr`)

```crystal
fanout = Event::Subscriber::Fanout.new(
  redis_url: event_config.url,
  service_id: Facet::Service.service_id("facet-ws"),
) do |channel, message|
  ws_manager.dispatch(channel, message)
end

ws_manager = Websocket::Manager.new(fanout)
ws_manager.start
Websocket::Manager.instance = ws_manager

Facet::HTTP::Server.routes
Facet::Websocket::Route.register
Kemal.run
```

---

## Relationship to `Event::Subscriber::Fanout`

`Fanout` (`src/event/subscriber/fanout.cr`) is the pub/sub driver. The `Fanout` opens its own Redis pub/sub connection (from the event config's URL) — it does not borrow `Event::Manager`'s Redis client or connection pool. It is a separate, long-lived Redis connection managed by a single control fiber.

Both `Fanout` fibers (connection loop + command drain) run under `Util::FiberSupervisor` — a raise restarts them after a backoff instead of dying silently. The drain is the connection's single writer (the subscription loop is the single reader); commands that fail on a live connection are retried, then logged and counted on `facet_fiber_loop_errors_total` — a failed command never kills the drain, which would leave every later sub/unsub queued forever.

**Reconnect re-subscription.** Redis drops the per-connection `SUBSCRIBE` state when the socket dies. `Fanout` therefore tracks the set of channels the process wants subscribed (`register`/`unregister` on the manager keep it in step), and every reconnect re-subscribes the sentinel plus that set before the message loop starts. Messages published inside the reconnect window (bounded by the 1 s backoff) are lost — Pub/Sub is fire-and-forget; clients recover through the refresh protocol below. A sub/unsub command issued while the connection is down is dropped and re-established by the resubscribe pass, so the tracked set, not the command queue, is the source of truth.

---

## Collection subscriptions

A two-segment subscribe path (`/domain/Doctype`) subscribes the connection
to the whole doctype collection channel `fanout:{domain}.{doc_type}`. The
publish side issues a second Redis `PUBLISH` on that channel for every
document mutation on the default fanout path (override paths — e.g. the
`notified` event or the aggregate `child_changed` frame — skip the
collection channel).

### Frame shape

Identical to the single-document frame; only the `channel` value differs
(no trailing `:id`). `payload` carries the document `id` only — never full
content:

```json
{
  "channel": "fanout:hr.Employee:created",
  "event":   "created",
  "payload": {"id": "hr.Employee.abc"},
  "headers": {"mutation_id": "01J...", "actioner_id": "account_1",
              "domain": "hr", "doc_type": "Employee"}
}
```

### RBAC contract

- **Subscribe time** — the resolver checks the app grant and the role
  ceiling (`read` on `{domain}.{doc_type}` not `Denied`). A principal with
  no read grant at all is rejected with the same non-disclosing
  "not found or forbidden" error the single-document path uses; the socket
  stays open. Preview principals are rejected: their capability model has
  no collection semantics.
- **Per emit** — the authoritative row-level check. For every collection
  message, `Manager#dispatch` runs `ReadEnforcer.authorized?` against the
  projection row **per non-system connection**, before delivery. A `false`
  suppresses delivery to that connection with no error frame.

  This diverges deliberately from single-document subscriptions: a role
  change on an open connection takes effect on the next mutation, because
  the per-emit check re-evaluates the captured `AuthContext` against the
  current projection row. A role **revocation** is enforced immediately; a
  role **grant** is seen only after reconnect (the captured `AuthContext`
  does not re-load grants). Never leaks; accepts staleness on grant.

### Cost model and backpressure

The per-emit check is **fetch-then-check**: one `content` JSONB fetch plus
in-process scope evaluation per message per non-system subscriber (not a
bare indexed `SELECT`). The dispatch runs on the Fanout's single control
fiber, so the cost is serialized behind ALL fanout delivery in the
process — one collection message with S subscribers costs roughly
`S × per-check latency` before any other channel's messages flow.

| Mechanism | Value | Where |
|---|---|---|
| Per-connection mailbox | 64 messages (`MAILBOX_CAPACITY`), drop-and-close on overflow | `Connection#deliver` |
| Collection subscriber cap | `websocket.collection.max_subscribers_per_doctype` (default 32) | `Manager#register` |
| Over-cap behaviour | Error frame; socket stays open, client may retry | `Connection#handle_subscribe` |
| Per-emit RBAC cost | 1 content fetch + scope evaluation per message per non-system subscriber | `Manager#dispatch` collection branch |

With the default cap, a single check is ms-scale, bounding collection
dispatch at roughly 30–100 collection messages per second before other
channels feel the delay. If production shows stalling, the escape hatch is
a bounded fiber pool inside `Manager#dispatch_collection`.

### Refresh protocol (client contract)

Collection messages are **hints, not source of truth**:

- On `created`/`updated`/`deleted`, the client SHOULD re-fetch the affected
  document (REST `GET`) or the doctype list before acting.
- On reconnect after a dropped mailbox, the client MUST re-fetch the full
  list — the server delivers no replay (see Known Limitations).

---

## Aggregate child-change frames

An owned-child mutation publishes one `child_changed` frame to the
**parent's** per-document fanout channel
`fanout:{domain}.{parent_doctype}:{parent_doc_id}`; the collection channel
is skipped. The frame is keyed to the parent, but it names a child
mutation — subscribe-time RBAC covered only the parent. The payload is an
envelope (`id`, `action`, `child`, `parent`), never a document body.

`Manager#dispatch` handles one message per call. It branches on
`event == "child_changed"` after the collection-channel branch. The
filtered path mirrors `dispatch_collection`:

- One `Database.with_db` per frame.
- System principals take the direct-delivery fast path — no check.
- Each non-system connection runs one `ReadEnforcer.authorized?` check
  against the **child** document. The child identity comes from the
  payload's `child` pointer; the domain rides the headers (owned children
  share the parent's domain).
- A `false` check suppresses the frame for that connection, with no error
  frame. A frame without a usable child pointer is dropped. A failed check
  (for example, the child row gone mid-flight) is logged and skips only
  that connection.

All dispatch runs on the Fanout's single control fiber, so each
`child_changed` frame adds one `authorized?` query, serialized behind all
fanout delivery in the process. As with the collection filter, a role
revocation applies on the next frame; a role grant needs a reconnect (the
captured `AuthContext` does not re-load grants).

---

## Known Limitations (v1)

- **Captured auth context lives as long as the socket** — the `AuthContext`
  is captured at upgrade time; per-document fanout messages are delivered
  without an RBAC re-check (the subscribe-time check is authoritative for
  that channel), and the captured app grant / role are not re-loaded
  mid-connection. Collection subscriptions and aggregate `child_changed`
  frames differ: they re-check per emit — against the current projection
  row and the child document respectively (see § Collection subscriptions,
  § Aggregate child-change frames).
- **Synchronous writes** — `WebSocket#send` is synchronous; a slow client that blocks the write stalls the `Fanout` handler fiber. Per-connection send queues are a follow-up.
- **No reconnection / replay** — clients that disconnect miss messages sent while disconnected (both per-document and collection channels).