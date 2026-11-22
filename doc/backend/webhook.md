# Webhooks

A webhook is an outbound HTTP registration: a `core.Webhook` document points
at a source doctype, and every mutation of that source doctype delivers a
signed event envelope to the webhook's target URL. Delivery runs through the
`background_jobs` subsystem — one `webhook_delivery` row per delivery, with
retry, backoff, and a delivery log.

The contract is:

- **One doctype, many sources.** A webhook binds to exactly one source
  doctype (`source_doctype` reference to `core.DocType`) and filters by
  event name (`events` list; absent = all events, empty = nothing).
  The opt-in events are the exception: `notified`, `child_changed`, and the
  four import/export job lifecycle events (`export_completed`,
  `export_failed`, `import_completed`, `import_failed`) fire solely for
  bindings whose `events` list names them. A match-all webhook never
  receives a notification event (private to its recipient), an aggregate
  child frame (the payload is an envelope, not a document body), or a job
  lifecycle event (a pre-existing all-events webhook never signed up for
  job noise).
- **Enqueue-time authorization.** The seven-step RBAC check runs on the
  event-stream fiber, at enqueue time. A revoked binding or an unreadable
  source document produces no job row. The execute-time dispatcher does no
  RBAC and no projection reads.
- **Per-webhook signing key.** The `secret` field on the projection (a
  server-generated ULID, immutable after create) signs every body. There is
  no config-level signing secret.
- **No delivery table.** Delivery state lives in `background_jobs` rows of
  kind `webhook_delivery`. No dedicated migration exists.
- **Delivery guarantee.** The stream enqueue is at-most-once: a publish
  failure, a handler error, consumer downtime, or a stream trim can drop
  an enqueue. `Cron::WebhookReconcile` re-runs the enqueue decision from
  the `mutations` log within `webhook.reconcile_window_hours`, so enqueue
  is at-least-once inside that window. Transport after enqueue retries
  through `background_jobs`. Receivers must tolerate duplicates and late
  deliveries — see Reconciler → Duplicate tolerance.

Concern source files: `src/webhook/registry.cr`, `src/webhook/handler.cr`,
`src/webhook/auth_check.cr`, `src/webhook/dispatcher.cr`,
`src/webhook/manager.cr`, `src/webhook/routes.cr`, `src/webhook/calls.cr`
(the `webhook_calls` read side), `src/webhook/test.cr`,
`src/webhook.cr` (namespace root).
Seed data: `data/seeds/core.Webhook/` (definition + Lua script).

The attempt-log writer is not a separate module. `Webhook::Dispatcher`
implements the overridable hook methods `attempt_started`,
`attempt_finished`, `attempt_abandoned`, and `prune_expired` to write
`webhook_calls`.

## The `core.Webhook` doctype

Seeded by `Doctype::Seed` (`data/seeds/core.Webhook/`). Fields:

| field            | type                           | notes                                              |
| ---------------- | ------------------------------ | -------------------------------------------------- |
| `label`          | `string`, required             | display name                                       |
| `enabled`        | `boolean`, default `true`      | enable / disable through `PATCH enabled=...`       |
| `url`            | `url`, required                | the receiver target — https (or http under `allow_insecure_urls`) and a host that resolves public, per the two-step rule below |
| `headers`        | `object`                       | custom outbound headers                            |
| `secret`         | `string`, required, `min: 16`  | `read_only` — server-generated ULID                |
| `source_doctype` | `reference` → `core.DocType`   | required — the source doctype                      |
| `events`         | `array of string`              | absent = all events; empty = none; names validated at authoring against the closed event vocabulary (B-152) |
| `account_id`     | `reference` → `iam.Account`    | `read_only` — binding, stamped at create           |
| `role_id`        | `reference` → `iam.Roles`      | `read_only` — binding, stamped at create           |

The Lua lifecycle hooks (`script.lua`) enforce the authoring rules:

- `create` sets `secret = util.ulid()`. When the caller is a real principal
  (`ctx.actor.system == false`), it stamps `account_id` and `role_id` from
  `ctx.actor`, overwriting any caller-supplied value. A system caller
  leaves the binding fields unset — such a webhook must get a binding
  before it fires.
- `update` rejects any PATCH that touches `account_id`, `role_id`, or
  `secret` (422). The binding is immutable after create — ownership is
  locked at create time and cannot change hands.
- `create` and `update` validate the `headers` object: keys starting with
  `X-Facet-` (case-insensitive), keys outside the HTTP field-name grammar
  (RFC 7230 token), and non-string values are rejected with 422. This is
  the authoring-time ban behind the dispatcher's runtime header merge
  (below), so a spoofing key never reaches the delivery path.
- `create` and `update` validate the `events` list (B-152): the value must
  be an array of strings, and every name must sit in the closed event
  vocabulary the `util.webhook_event_names` binding returns — the mutation
  verbs (`created`, `updated`, `deleted`), the repair events (`migrated`,
  `rolled_back`), the opt-in events (`notified`, `child_changed`), and the
  eight job-lifecycle names. An unknown name is rejected with 422 and the
  message lists the allowed names, so a typo'd webhook cannot silently
  never fire. An empty list stays valid (fire on nothing). Named-action
  event names are dynamic per doctype and are not part of the vocabulary.
- `create` and `update` validate the actioner's connectivity: the real
  principal's active role must carry the `webhook` connectivity channel —
  `iam.Roles.connectivity` names the programmatic channels the role may
  use. A role without `webhook` is refused with 422 (the message names the
  channel and the role field that grants it), so a webhook that could
  never fire is not authored at all (the enqueue gate would skip every
  delivery with `ChannelClosed`). The gate rides the
  `util.role_has_channel` Lua binding (backed by
  `Util::ScriptHelpers.role_has_channel?`) and exempts system callers —
  seeding and migration stamp bindings after the fact. This is the
  authoring brake on outbound egress: by seed, only `admin` holds the
  `webhook` channel. `editor` and the other non-admin roles hold
  `[api, assistant]` and no `webhook`/`mcp`, so a non-admin cannot open a
  webhook even when its permission shape (`create *.*`) covers
  `core.Webhook`. The SSRF host gate bounds *where* a webhook may point;
  the channel bounds *who* may open one.
- `create` and `update` validate the target `url` in two steps, both on
  the create and the update path:

  1. **Scheme** (B-77): with `webhook.allow_insecure_urls` false (the
     default), a non-https target is rejected with 422 — the same message
     the dispatcher and `/test` use. This is the authoring-time guard
     behind the delivery-time check, so a webhook the server would refuse
     to deliver to cannot be created (a create that answered 201 for an
     `http://` target was the run-24 finding B-77). The rule rides the
     `util.valid_https_url` and `util.insecure_urls_allowed` bindings —
     the same Lua-hook pattern as the `iam.OIDCProvider` `issuer` rule
     (which carves out loopback http instead of reading a config flag).
  2. **Host** (B-76): the host must resolve, and every resolved address
     must be public — the `util.safe_webhook_url` binding, backed by
     `Webhook::TargetCheck`. A host that resolves private (loopback,
     link-local — which is where the cloud metadata service lives —
     RFC 1918 / unique-local, carrier NAT, multicast, reserved) or does
     not resolve at all is rejected with 422. An internal receiver a
     deployment actually wants is named on `webhook.allowed_hosts` in the
     YAML config; an allowlist match passes before the deny-list is
     consulted. The same gate re-runs at delivery time and on `/test`, so
     a URL that turns private after authoring (DNS re-pointing) is caught
     at the dial; the residual gap is one DNS TTL wide (see
     `Webhook::TargetCheck`'s header comment). Crystal's `HTTP::Client`
     does not follow redirects — if redirect following is ever enabled
     for webhooks, every hop must re-run the gate. Resolution goes
     through the `TargetCheck.resolver` proc (default: real `Addrinfo`
     lookup); specs swap it via `with_fake_resolver`
     (`spec/support/webhook_helper.cr`) so the suite stays
     DNS-independent.

actions: {}  # no named actions — enable/disable is `PATCH enabled=true|false`.
```

### Ownership scope

A named `mine` scope sits on the definition (`where: { account_id: '$self' }`),
and the seeded non-admin roles hold `core.Webhook` through it: create rides
their blanket grant unrestricted (the binding stamps the creator, so a
webhook is its creator's from birth), while read, update, and delete are
carved out of the blanket lines and re-granted with `scope: ["$mine"]`.
Admin keeps the plain wildcard and sees everything.

The practical shape: a non-admin role lists, reads, edits, tests, replays,
and deletes only the webhooks its own account created — the document list
compiles the scope into SQL, the single-doc gates fetch-then-check, and the
call-log routes (`ReadEnforcer`) and the test/replay routes
(`WriteEnforcer`) consult the same scope, so another author's delivery
history and webhook are equally invisible. A non-admin cannot probe an
internal target through someone else's webhook. The immutable binding plus
the target-host gate bound the data and the destination; the scope bounds
who may manage the registration.

## Registry

`Webhook::Registry` loads every non-deleted `core.Webhook` projection and
keys the resulting `Binding` records by qualified source doctype
(`"accountancy.Contract"`). The stored `source_doctype` value is a
reference token — the field targets `core.DocType`, so `qa.Widget`
persists as `core.DocType.qa.Widget` — and `build` strips the
`core.DocType.` prefix so the key, and every stream subscription,
handler lookup, and reconciler read derived from it, carries the same
bare form the event publisher keys streams by. A value stored without
the prefix passes through unchanged. The public surface mirrors
`Hooks::Registry`:

| member                                   | meaning                                                        |
| ---------------------------------------- | -------------------------------------------------------------- |
| `build(db)`                              | eager rebuild from the `projections` table                     |
| `webhooks_for(source_doctype)`           | bindings for one qualified source doctype (`.dup`)             |
| `source_selectors`                       | the key set — drives the event subscriptions                   |
| `mark_stale` / `stale?`                  | invalidation flag; the next read rebuilds lazily               |

A `Binding` carries `id`, `source_doctype`, `events`, `secret`,
`account_id`, `role_id`. Build-time filters: rows with `enabled == false`
are skipped, tombstoned rows are excluded, a corrupt row (no
`source_doctype`) is logged and skipped fail-closed, and a webhook whose
source domain fails the `domain_enabled` predicate is skipped (draft
domains).

The `DoctypeCache` Pub/Sub subscriber subscribes to
`fanout:core.Webhook:*` and calls
`Webhook::Manager.instance.try(&.mark_registry_stale)`. The next registry
read rebuilds lazily — a webhook create, update, or delete needs no restart.
A fanout lost during a Redis outage is bounded by `cache.staleness_ttl_s` —
reads past the bound rebuild without a fanout (see `doc/backend/replication.md`
→ `Event::Subscriber::DoctypeCache` → staleness bound).

## Enqueue path

`Webhook::Handler` runs on the event-stream fiber, one instance per
`Webhook::Manager`. Per source-mutation message:

1. **Reentrancy skip** — `headers["reentrant"] == true` is dropped.
2. **Resolve source** — domain, doc type, document id, event name.
3. **Registry lookup** — `webhooks_for("domain.Doctype")`; empty → done.
4. **Event filter** — keep bindings whose `events` is nil or includes the
   event name. The opt-in events (`notified`, `child_changed`, the four
   import/export job lifecycle events) require the binding's `events` list
   to name them (`binding_matches?` → `Event.opt_in_event?`).
5. **Authorization + enqueue** — one `Database.with_transaction(:read_write)` around the
   whole loop; each binding runs `Webhook::AuthCheck`, a pass enqueues one
   `webhook_delivery` row through `Jobs::Manager`. All-or-nothing on crash.
6. **Flush** — `Event::Publisher.flush` (mirrors `Hooks::Handler`).

### `Webhook::AuthCheck` — the eight-step gate

One code path, two callers: the handler above and the replay route. Steps:

1. Read the live `core.Webhook` projection — `enabled`, `url`, `headers`,
   `secret`, `account_id`, `role_id`. A toggle, delete, or unbinding
   between registry build and this call is caught here.
2. `enabled == true` (a stored NULL counts as enabled).
3. The bound account exists, is not deleted, and `status == "active"`
   (`RBAC::AccountLoader.load_role_ids` / `account_active?`).
4. The bound role is still assigned to the account
   (`AccountLoader.role_assigned?`; the stored `role_id` is the qualified
   `iam.Roles.<name>` form, passed as-is).
5. The bound role projection exists and is not deleted → the `ActiveRole`.
6. The bound role's `connectivity` list still carries the `webhook`
   channel — a role edited down to browser-only loses its webhook
   deliveries at the next event (`SkipReason::ChannelClosed`; derive,
   never mark). A missing or malformed list fails closed.
7. The bound role can read the event's subject. For a job lifecycle
   event the subject is a `background_jobs` row, not a projection — the
   gate swaps to the source doctype's own definition projection
   (`RBAC::ReadEnforcer.authorized?` on `core.DocType` id
   `{domain}.{doc_type}`). For every other event it is the source
   document itself. Context resolves fresh — no memoization across
   events or requests.
8. Aggregate `child_changed` frames only: the bound role must also read
   the child document the frame names (the payload's `child` pointer).
   Step 7 checks the parent — the frame is keyed to it — but the payload
   is an envelope, not a document body, so this step checks the child row
   too. A missing or malformed child pointer fails closed.

A pass returns `AuthCheck::Pass` with the fresh transport fields (`url`,
`secret`, `headers`). A failure returns a `SkipReason` (the reason the
caller logs and skips). The `SkipReason` members: `WebhookMissing`,
`Disabled`, `MissingTransport`, `Unbound`, `AccountMissing`,
`AccountInactive`, `RoleUnassigned`, `RoleDeleted`, `ChannelClosed`,
`SourceUnreadable`, `ChildUnreadable`. Both callers render the reason
through `skip_label`; `ChannelClosed` reads `bound role's connectivity
excludes the 'webhook' channel`.

### Job payload

The payload carries the signed envelope plus transport-only fields:

- Envelope: `webhook_id`, `delivery_id` (fresh ULID), `event`, `domain`,
  `doc_type`, `doc_id`, `mutation_id`, `actioner_id`, `cause`, `content`,
  `emitted_at`. That list is the exact wire order of `Payload#signed_body`;
  `origin` is not a body field — it rides the `X-Facet-Origin` header.
  `content` is `msg.content` verbatim. A document-mutation event passes no
  payload override, so its `content` is the default id frame
  `{"id": "<doc_id>"}` — never the document body. An opt-in event that
  carries more delivers it whole: `notified` ships the notification record,
  the import/export job events ship the job report. For a `child_changed`
  delivery, `content` is the aggregate envelope — parent `id`, `action`,
  `child` pointer, `parent` pointer — not the child document body. The
  envelope's `domain`, `doc_type`, and `doc_id` name the parent, because the
  frame is keyed to it.
- Transport (never signed, never POSTed): `url`, `secret`, `headers`.

Retry policy is stamped at enqueue: `max_attempts` and `backoff_seconds`
from `Webhook::Config`.

## Reconciler — `Cron::WebhookReconcile`

The enqueue hop is the one webhook seam without durability: the stream is
at-most-once, so a publish failure, a handler error, consumer downtime, or
a stream trim each lose the enqueue with one log line. The reconciler
makes that hop **at-least-once** by re-running the enqueue decision from
the durable `mutations` log — delivery state is derived, never marked, and
no schema is involved.

- **Trigger.** Cron task `webhook.reconcile`, schedule
  `webhook.reconcile_cron` (default hourly at minute 7).
- **Window.** Mutations from the last `webhook.reconcile_window_hours`
  hours (default 24), non-`core` domains, cause kinds outside
  `periodic_snapshot` / `webhook_test`, processed in `emitted_at` order so
  repaired deliveries keep causal order within the window. The window
  must stay below `jobs.retention_days` — validated at config load, since
  `background_jobs` rows are the dedupe authority and terminal rows are
  pruned after retention.
- **Reentrancy.** The same verdict the stream path reaches: hook and
  replication writes are skipped by their own cause kind, and cascade
  children under a reentrant delete by the cluster-root lookup (the
  earliest-emitted mutation sharing the row's `cause_trace`).
- **Dedupe.** One query per pass reads the `webhook_delivery` pairs for
  the window's mutation ids. A pair with a job row in **any** status
  counts as enqueued — a failed row has exhausted its retries, and
  re-enqueueing would bypass the retry policy.
- **New-binding bound.** A binding skips mutations emitted before its
  projection `created_at`: a new webhook receives events from mutations
  after its creation — close to the stream's "new groups start at `$`"
  semantics — and does not receive the window's history.
- **Shared decision logic.** The pass builds one synthetic `Event::Message`
  per mutation (headers `domain`, `doc_type`, `mutation_id`,
  `actioner_id`, `cause`, `event`, `emitted_at`; content `{"id": doc_id}`)
  and calls `Webhook::Handler#call` with the per-mutation skip set.
  Matching, the event filter, `AuthCheck`, and enqueue stay in one place.

**Duplicate tolerance.** A pass can race the stream path and enqueue a
duplicate (the dedupe read happens before a concurrent stream insert
commits). Receivers must tolerate duplicates — the same tolerance the
retry policy already requires. A repaired delivery carries its original
`mutation_id` and `emitted_at`, so receivers can detect and reorder.

**Bounds.** The reconciler covers document-mutation events on non-`core`
domains within the window. It does not cover `notified` events
(recipient-scoped, published with a payload override), `child_changed`
frames (aggregate envelopes keyed to the parent), or the four
import/export job-lifecycle events (they originate from `background_jobs`
rows, not mutations).

## Execute path — `Webhook::Dispatcher`

`Webhook::Dispatcher < Jobs::Handler` is a stateless, no-argument handler
registered under `KIND = "webhook_delivery"`. Pure transport: it builds the
body from the payload, signs it, merges the header set, POSTs, and maps
every outcome to a `Result`.

- `signed_body` emits the envelope **without** `url` / `secret` / `headers`,
  in a fixed field order — the signature covers these raw bytes, so the
  receiver verifies against the raw body it received.
- Signature: `X-Facet-Signature: sha256=<lowercase hex of HMAC-SHA256(secret,
  raw body)>` (`OpenSSL::HMAC`, per-webhook `secret` alone).
- Header merge order: `Content-Type` + `User-Agent` defaults → custom
  `headers` (a custom Content-Type / User-Agent wins) → the `X-Facet-*`
  mandate (always wins — the runtime guard behind the authoring-time ban on
  `X-Facet-` custom headers).

| Header                 | Value                              |
| ---------------------- | ---------------------------------- |
| `X-Facet-Signature`    | `sha256=<hex>` (never overridden)  |
| `X-Facet-Event`        | payload `event`                    |
| `X-Facet-Delivery`     | payload `delivery_id`              |
| `X-Facet-Webhook-Id`   | payload `webhook_id`               |
| `X-Facet-Mutation-Id`  | payload `mutation_id` (if present) |
| `X-Facet-Origin`       | `webhooks:{webhook_id}`            |

Outcome mapping: HTTP 2xx → `Succeeded`; any other status and every
transport error → `Failed` (with `http_status` or `error`). `execute`
never raises. One `HTTP::Client` per execute, with `connect_timeout` /
`read_timeout` from `webhook.timeout_s`. Non-`https` targets are rejected
unless `webhook.allow_insecure_urls` is true — the rejection flows through
the normal `Failed` path and the row retries.

The dispatcher also captures debug data into the `Result`: the POST wall
time (`duration_ms`) and a text snippet of the receiver's response body
(`response_body` — capped at 4 KB with a truncation marker; binary media
types are skipped). Transport errors keep `response_body` nil.

## Call log

One row per outbound HTTP attempt lives in `webhook_calls` (migration
`0008_jobs.sql`) — created `pending` when the worker claims the delivery, flipped
to `succeeded` / `failed` on the outcome. A retrying job produces one row
per attempt. The table is the user-facing debug log; `background_jobs`
stays the retry scheduler and keeps its own operational outcome columns.

- `Webhook::Dispatcher` (`src/webhook/dispatcher.cr`) is the write side,
  through the attempt hooks on the handler itself (`Jobs::Handler`
  no-op defaults, overridden here). The worker fires `attempt_started`
  after the claim, `attempt_finished` after the outcome write, and
  `attempt_abandoned` from the lease sweep (stale pending rows are then
  marked `failed` with `worker lease expired`). A raising hook is logged
  and skipped — the job outcome path is untouched.
- Envelope identity (`event`, `source_doc_id`, `mutation_id`) is
  denormalized onto the call row so the log is filterable without the job
  payload. The full envelope and the signing `secret` stay only in the
  `background_jobs` payload — the call row never holds the secret.
- `Webhook::Calls` (`src/webhook/calls.cr`) is the read side:
  `list(db, webhook_id, status?, page, per_page)` (newest first, optional
  `pending` / `succeeded` / `failed` filter) and `find(db, webhook_id,
  call_id)` (webhook-scoped).
- Retention mirrors the queue: the worker's maintenance prune calls the
  dispatcher's `prune_expired` hook, which deletes terminal call rows
  past the same `jobs.retention_days` horizon.

## Call log + replay routes

Registered by `HTTP::Server.routes` between the domain routes and the REST
catch-all. Authorization follows the platform convention
(`doc/backend/rbac.md` → Enforcement rules): the list / show routes need
`read core.Webhook`, replay and test need `update core.Webhook`.

| Route                                                       | Gate              | Behaviour                                                                                                                       |
| ----------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `GET` / `QUERY /Api/core/Webhook/:id/calls`                | `read` (404 when denied) | Paginated `webhook_calls` rows for the webhook, newest first; optional `status` filter (`pending` / `succeeded` / `failed`; an unknown value is a 422). GET reads `?status=...`; QUERY reads `status` from the JSON body (no query string on QUERY). |
| `GET /Api/core/Webhook/:id/calls/:call_id`                  | `read` (404 when denied) | One row; 404 when absent or owned by another webhook.                                                                    |
| `POST /Api/core/Webhook/:id/calls/:call_id/replay`          | `update` (404 when denied) | Resolves the call's `job_id`, re-runs `AuthCheck` against the current binding and the **original** source document. Pass → 202 with the fresh `job_id`; fail → 422 with the skip reason. |
| `POST /Api/core/Webhook/:id/test`                           | `update` (403 when denied) | Runs the test action (below).                                                                                           |

Replay reuses the handler's exact gate — never a duplicate. The stored
envelope feeds the gate, so the child-visibility step applies at replay
too: a binding that can no longer read the child document is a 422
(`ChildUnreadable`). The replayed
payload keeps the original envelope fields verbatim but carries a fresh
`delivery_id` and re-reads `url` / `secret` / `headers` from the projection
at replay time. The original call rows are untouched. Replay of a test
probe (`job_id` NULL) and replay after the parent job row was pruned are
both a 422 — there is nothing to replay. The table never holds the
secret, so no payload stripping is needed.

## Test action

`POST /Api/core/Webhook/:id/test` (`Webhook::Test`) issues one inline
outbound POST with a synthetic envelope and returns the receiver's
response as JSON. No `background_jobs` row, no retry machinery.

- The envelope is signed by `Dispatcher.build_signed_request` — the shared
  code path — so the signature verifies exactly like a real delivery. The
  receiver branches on `"event": "test"` or the `X-Facet-Test: true`
  header (overlaid after the shared merge).
- The route answers **200 regardless of the receiver's status** — the
  operator wants "my receiver returned 401" as data. Only Facet-side
  failures surface as their own status: 404 (no webhook), 403 (denied),
  422 (disabled, missing `url` / `secret`, an insecure target URL, or a
  bound role whose `connectivity` excludes the `webhook` channel — the
  same gate the dispatcher applies at enqueue, so the probe route is
  never a way around it).
- The response body is capped at 4 KB with a truncation marker. A
  transport error is data too: `http_status: null`, `transport_error` set.
- The probe is logged as a call row: `event = 'test'`, `job_id` NULL,
  attempt 1. A probe is a call; the log should show it. Facet-side
  rejections never reach the wire and write nothing.

## Manager lifecycle

`Webhook::Manager` owns the registry, the handler, and a dedicated
`Event::Manager` (`consumer_group_prefix = "cg:webhooks:"`, injectable for
tests). The singleton accessors (`instance`, `instance=`, `reset!`) mirror
`Hooks::Manager`; `DoctypeCache` reaches it through
`.instance.try(&.mark_registry_stale)`.

Webhooks live in `core` but consume their **source** doctypes' streams: a
webhook on `accountancy.Contract` subscribes to the
`FACET:RESOURCE:accountancy:Contract` stream. Every subscription carries
the single owning domain `core`, so one consumer group
(`cg:webhooks:core`) serves all source streams.

The `core` stream subscriber exists from boot, even when the registry
loads zero webhooks. `install_channel_providers` creates it through
`Event::Manager#ensure_stream_subscriber`, with the channel provider and
the channel-add callback installed before the polling fiber starts. The
provider re-queries the registry on each poll, so a webhook created (or
enabled) after boot arms live delivery for the next mutation without a
restart. Each source channel the provider adds at runtime is paired with
a dispatch registration through the add callback — the dispatcher only
delivers to registered subscriptions. `Cron::WebhookReconcile` stays the
repair path for events emitted before the new source channel's consumer
group exists (a new group starts at `$` — the tail).

`main.cr` wiring order:

```crystal
webhook_manager = Facet::Webhook::Manager.new(...)
Facet::Webhook::Manager.instance = webhook_manager
Facet::Database.with_db { |db| webhook_manager.start(db) }
webhook_manager.register_handler(jobs_manager) # BEFORE Jobs::Manager.start
jobs_manager.start
```

`Jobs::Manager#register_handler(kind, klass)` mutates the handlers map
before `start` — the worker snapshots the map at start, so
`webhook_delivery` must be dispatchable from the first claim. The call
log rides the same object: the dispatcher's own attempt hooks write it.
`stop` runs in the `at_exit` block, after
`hooks_manager.stop`.

## Config

`WebhookConfig` on `Facet::Config` (`src/config.cr`). The `webhook:`
section is optional; the defaults apply when it is absent.

| field                  | default                      | meaning                                            |
| ---------------------- | ---------------------------- | -------------------------------------------------- |
| `timeout_s`            | `10`                         | connect + read timeout for one outbound POST       |
| `max_attempts`         | `5`                          | retry ceiling stamped on each delivery row         |
| `backoff_seconds`      | `[10, 60, 300, 1800, 7200]`  | per-attempt delay list                              |
| `allow_insecure_urls`  | `false`                      | when false, non-`https` targets are rejected         |
| `allowed_hosts`        | `[]`                         | target hosts the B-76 host gate passes even when they resolve private — exact hostnames (string-matched, no DNS), IP literals (a bare IPv4 entry and its `::ffff:` spelling are the same address, matched against every resolved address), or CIDRs. Empty by default |
| `reconcile_cron`       | `"7 */1 * * *"`              | schedule of the enqueue-hop reconciler (`Cron::WebhookReconcile`) |
| `reconcile_window_hours` | `24`                       | how far back the reconciler looks for missed enqueues — must stay below `jobs.retention_days` |

No signing-secret keys exist here — the per-webhook `secret` field is the
whole signing key.

## Example — enqueue → deliver

A caller mutates `accountancy.Contract#01HQ...`:

1. The mutation events through the normal projection trigger /
   `Event::Publisher` path. The webhook `Event::Manager` consumes the
   `FACET:RESOURCE:accountancy:Contract` stream (group `cg:webhooks:core`).
2. `Webhook::Handler` resolves the source, finds the webhook bindings,
   filters by event name, and runs `AuthCheck` per binding. The bound
   account is active, the role is assigned, and the role can read the
   contract — the check passes with the fresh `url` / `secret` / `headers`.
3. One `webhook_delivery` row is enqueued with the signed envelope. The
   worker claims it and runs `Webhook::Dispatcher`.
4. The dispatcher signs the raw body with the webhook `secret`, merges the
   header set, and POSTs. A 2xx marks the row `Succeeded`; a 4xx / 5xx /
   transport error marks it `Failed` and the row retries per
   `backoff_seconds` up to `max_attempts`.

The receiver verifies:

```crystal
expected = OpenSSL::HMAC.hexdigest(:sha256, webhook_secret, raw_body)
valid = headers["X-Facet-Signature"] == "sha256=" + expected
```

## Test infrastructure

| file                                | coverage                                                                                                     |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `spec/webhook/doctype_spec.cr`      | Authoring rules: `secret` ULID stamping, binding stamps from the actioner, PATCH rejection (422), system bypass. |
| `spec/webhook/registry_spec.cr`     | Build from projections, stale / rebuild, disabled + tombstoned exclusion, fail-closed corrupt row, `events` shapes, draft-domain skip. |
| `spec/webhook/handler_spec.cr`      | One row per matching webhook, reentrancy skip, event filter, per-binding decisions, all `AuthCheck` failure paths, aggregate `child_changed` delivery (opt-in filter, `ChildUnreadable`, fail-closed child pointer), `skip_webhook_ids` + original `emitted_at` on the reconciler path |
| `spec/webhook/job_lifecycle_spec.cr` | Import/export job events: opt-in delivery with the report payload, match-all never fires, the `core.DocType` gate pass/skip. |
| `spec/webhook/dispatcher_spec.cr`   | Signature, body shape, header merge, outcome mapping, response-body capture, never-raises, insecure-URL guard. |
| `spec/webhook/call_log_spec.cr`     | Pending insert, outcome flip, lease-expired failure, idempotency, retention prune, test-probe rows.            |
| `spec/webhook/calls_spec.cr`        | Newest-first pagination, status filter, webhook-scoped find.                                                   |
| `spec/webhook/manager_spec.cr`      | Singleton, idempotent start / stop, channel provider, `core` subscriber at boot with zero webhooks + live delivery without a restart, no double registration, handler registration order, no Redis (stub). |
| `spec/webhook/routes_spec.cr`       | Call list / show pagination + scoping + status filter, replay via call id + 422 paths, RBAC denials.           |
| `spec/webhook/test_spec.cr`         | Test-action envelope, signature parity with real deliveries, receiver-status-as-data, probe call rows, no job row. |

`spec/support/webhook_helper.cr` seeds the source doctype, roles, accounts,
and bound webhooks. `background_jobs` and `webhook_calls` are not in the
global truncation list — specs that create rows delete them in
`before_each`.