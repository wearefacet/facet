# Domain Hooks

Domain hooks are domain-owned Lua scripts that fire automatically on a trigger. An `event` hook fires when a mutation event is observed on a source doctype; a `schedule` hook fires on a cron schedule. Hooks are declared on the `core.Domain` document, so a domain carries its automation with it — export, import, and fresh publish move hooks as part of the bundle. Overwrite publish does not copy hooks; see **Publish and hooks** below.

**Source files:** `src/hooks.cr`, `src/hooks/definition.cr`, `src/hooks/validator.cr`, `src/hooks/registry.cr`, `src/hooks/executor.cr`, `src/hooks/handler.cr`, `src/hooks/scheduler.cr`, `src/hooks/manager.cr`

---

## Declaration

Hooks live in the `hooks` array of the `core.Domain` content. Each entry has this shape:

| Field | Kind | Rules |
|---|---|---|
| `id` | both | String, unique within the domain |
| `kind` | both | `"event"` or `"schedule"` |
| `script` | both | Lua source. Must return an export table with the required function |
| `source` | `event` | Object with `domain` (required), `doc_type` (optional), `events` (optional string array) |
| `schedule` | `schedule` | 5-field cron expression, UTC |

`Hooks::Definition.parse` reads the array and returns `{hooks, errors}`. A domain with no `hooks` key is valid. Malformed entries collect as `ValidationError`s — the caller decides to reject (authoring gate) or warn (`/check`).

Source selection for an `event` hook:

| `source` shape | Matches |
|---|---|
| `domain` only | Every doctype in the source domain |
| `domain` + `doc_type` | Only that doctype |
| `events` list | Restricts to the listed event names (`created`, `updated`, `deleted`, …); omit to match all events |

```json
{
  "id": "notify-credit",
  "kind": "event",
  "script": "local export = {}\nfunction export.on_event(ctx) ... end\nreturn export",
  "source": { "domain": "accountancy", "doc_type": "Contract", "events": ["created"] }
}
```

```json
{
  "id": "nightly-rollup",
  "kind": "schedule",
  "script": "local export = {}\nfunction export.on_schedule(ctx) ... end\nreturn export",
  "schedule": "0 3 * * *"
}
```

A complete, runnable `event` hook script — this text is the whole
`hooks[].script` value:

```lua
local export = {}

function export.on_event(ctx)
  -- ctx.event.content is already a Lua table — no JSON decode needed.
  if ctx.event.content.status == "on_hold" then
    ctx.error("Contract " .. ctx.event.doc_id .. " entered on-hold")
  end
end

return export
```

---

## Publish and hooks

Publish moves a draft's hooks to the target domain in fresh mode only.

- **Fresh publish** copies the draft's whole `core.Domain` content into the target — the draft's hooks land on the target, and the registry picks them up on the next rebuild.
- **Overwrite publish** does not copy hooks. It replaces only the doctype definitions and the `DocumentView` rows; the live `core.Domain` document stays as it is. The target keeps its own hooks, and the draft's hooks do not carry over.

The overwrite drop is not silent. When the draft declares hooks that the live domain does not carry, the publish response carries a `warnings` array with one entry that names the dropped hook ids, and the server logs one WARN line with the same text. The workaround is to patch the `hooks` field on the live domain after the publish. Note that the grant-ticket scan still reads the draft's hooks, so the publish can file a ticket from a hook that the same publish did not carry — the warning names the gap.

---

## Authoring gate (`Hooks::Validator`)

`Hooks::Validator.validate` runs at `core.Domain` create/update time through `Document::Update`'s definition validation, and on demand from `Domain::Check` (there it reports as a `:hooks` issue, not a hard 422). Checks:

1. Hook ids are unique within the array.
2. `script` compiles in a fresh `Lua::Engine` and returns a Lua table.
3. The export table carries the required function — `on_event` for `event`, `on_schedule` for `schedule` — and it is a function.
4. For `schedule`, the cron expression passes the restrictiveness check, then `Cron::Parser` range validation.

The cron surface is deliberately narrow: 5 numeric fields with `/` step repetition only. `@`-macros, the 6-field seconds form, and the `L` / `W` / `#` modifiers are rejected. The validator enforces this itself so the error points at the hook author, not at the shard's generic message.

---

## Registry (`Hooks::Registry`)

The registry is the static map of hooks, rebuilt from `core.Domain` projections. It follows the same stale-flag / lazy-rebuild model as `Replication::Registry`: reads rebuild when stale, events only mark stale. The `DoctypeCache` Pub/Sub subscriber calls `Hooks::Manager#mark_registry_stale` on every `fanout:core.Domain:*` event, so a hook edit takes effect on the next read without a restart. A fanout lost during a Redis outage is bounded by `cache.staleness_ttl_s` — reads past the bound rebuild without a fanout (see `doc/backend/replication.md` → `Event::Subscriber::DoctypeCache` → staleness bound).

A hook edit has two distinct delivery windows:

- **Domain that already owns a stream subscriber — no fixed lag.** The edit
  marks the registry stale and the rebuild runs synchronously on the next
  hook read (subscription sets re-derive on every poll, so new source
  channels attach at the same point). No timer is involved.
- **Domain that gains its first hook after boot — one bounded window.** The
  stream subscriber does not exist yet; the subscriber-sync fiber creates
  it on its next wake (`SUBSCRIBER_SYNC_INTERVAL`, 5 s). Events emitted
  inside that window are never delivered to the first hook — consumer
  groups start at `$`. See Subscriber sync below.

| Method | Returns |
|---|---|
| `#hooks_for(source_doctype)` | All `event` hooks bound to that source doctype, in declaration order |
| `#source_selectors` | Distinct source doctypes (`"accountancy.Contract"`) this node must consume |
| `#schedule_hooks` | All `schedule` hooks across published domains, with `owning_domain` stamped |
| `#build(db)` | Full rebuild from the DB |
| `#mark_stale` / `#stale?` | Invalidation flag — the next read rebuilds |

Key properties:

- **Draft isolation.** Hooks on draft domains are validated at authoring time but never load. The `domain_enabled?` predicate excludes them during `build`; a fresh publish picks them up on the next rebuild (overwrite publish does not copy hooks — see **Publish and hooks**).
- **Fail-closed parsing.** A malformed `hooks` array on a published domain logs the bad entries and loads the rest. The authoring-time validator is the hard gate; the registry never hard-fails on one bad entry.
- **Pre-expansion.** Domain-wide hooks (no `source.doc_type`) are expanded to one key per doctype in the source domain at build time, so lookups are single-key fetches and `source_selectors` can be used directly as Redis channel names.

---

## Execution (`Hooks::Executor`)

`Hooks::Executor` runs one hook script under a fresh `Lua::Engine` per fire. It registers the `document.*` helpers pinned to the **owning domain** — writes are domain-scoped by construction, reads may cross domains through a qualified `domain.Doctype` argument. Hook-driven writes run with `reentrant: true`, which breaks hook → event → hook cycles.

The `ctx` table:

| Field | Type | Present in |
|---|---|---|
| `ctx.event` | table | `event` hooks — the source mutation payload |
| `ctx.scheduled_at` | string | `schedule` hooks — the cron instant the fire was due |
| `ctx.error(msg)` | function | Both — validation error collector |
| `ctx.actor_id` | string | Both — always `"system:hooks"` |
| `ctx.now` | string | Both — ISO 8601 timestamp |

`ctx.event.content` is a ready Lua table — the payload is decoded before
the script runs. Only the `document.*` projection tables carry `content`
as a JSON string (see JSON helpers below).

`ctx.event` carries `{domain, doc_type, event, doc_id, mutation_id, actioner_id, content}` — the source mutation payload, so the common case needs no extra `document.get`. The bus message of a document event carries only `{id}`, so the handler loads the live document body from the projection at delivery time — `content` holds the current field values. The load reads one row per hook fire. When the source document is missing or deleted (a tombstone), the load finds no live row and `content` stays the `{id}` frame — the event still delivers. An opt-in event (`child_changed`, `notified`, the job-lifecycle events) carries its own payload on the bus; the handler delivers it as it arrived and does no load.

On a **foreign-source** hook (the source domain differs from the owning domain), the fire is gated by the grant system and the content is masked: the hook fires only when an active `core.DomainGrant` under the source (producer) domain admits the owning domain on that doctype (`Grants::Registry.active?`), and `content` is projected through the grant's tag mask (`Grants::Registry.project`) — only fields whose tags the granted tags cover survive. Same-domain events keep the full content. The projection runs after the body load, so the mask applies to the live body. See [`domain-grants.md`](domain-grants.md) → The four gates (G3).

For an aggregate `child_changed` frame, `content` is the envelope
`{id, action, child, parent}` — not the child document body. The frame is
keyed to the parent, so `doc_type` and `doc_id` name the parent document. A
hook that reads the source document reads this envelope; it fetches the
child body with `document.get` when it needs it.

Sandbox globals — the hook sandbox has full parity with the lifecycle
script contexts (`Document::ScriptContext::Base`):

| Global | Contents |
|---|---|
| `util.ulid` | Fresh, time-sortable ULID (`Util::ScriptHelpers.ulid`) |
| `util.sha256` | SHA-256 hex digest of a string |
| `util.clamp` / `math.clamp` | Numeric clamp to `[min, max]` |
| `util.facet_hosts` | The reserved Facet host set (config hosts + loopback literals) |
| `util.valid_hostname` | App-host shape rule — a bare lowercase hostname; the deployment target supplies the port (`Util::ScriptHelpers.valid_hostname?`) |
| `util.valid_redirect_uri` | Redirect-URI shape rule — https on any host, http on a loopback host only |
| `util.valid_https_url` | https URL shape rule |
| `util.valid_issuer_url` | OIDC issuer rule — https on any host, http on a loopback host only (`Util::ScriptHelpers.valid_issuer_url?`) |
| `util.insecure_urls_allowed` | The `webhook.allow_insecure_urls` config flag |
| `util.safe_webhook_url` | Webhook target host gate (`Webhook::TargetCheck.host_safe?`) |
| `util.webhook_event_names` | The closed event-name vocabulary for `core.Webhook` bindings |
| `util.is_empty` / `util.coalesce` | Pure-Lua value helpers |
| `util.json_encode` / `util.json_decode` | JSON ↔ Lua table conversion |
| `util.oidc_name_tombstoned` | db-backed — whether an OIDC display name is a tombstone |
| `util.role_has_channel` | db-backed — whether a role's `connectivity` carries a channel |
| `date.diff` / `date.now` | Date difference in a unit; the current UTC instant |

Two groups deserve their purpose stated:

- **JSON helpers.** `document.get`, `document.list`, `document.create`, and
  `document.update` return projection tables whose `content` and `meta`
  fields are JSON strings (parse cost stays zero until a hook reads them).
  A hook that reads a fetched document's fields decodes with
  `util.json_decode` first, the same rule the compute engine follows.
- **db-backed gates.** `util.oidc_name_tombstoned` and
  `util.role_has_channel` carry the same authoring gates lifecycle scripts
  use: a hook that writes a gated doctype (a `core.Webhook`, for example)
  can pre-check the rules the target doctype's own validation enforces,
  before it spends the write.

Error model:

- `ctx.error(msg)` calls collect into `ValidationError`s — the expected validation path. The hook's writes already happened; errors surface as logs and span attributes.
- Lua syntax or runtime errors raise `Hooks::Executor::Error` — the caller logs and skips.

Each fire opens a `hooks.event.run` or `hooks.schedule.run` OpenTelemetry span with `hooks.domain`, `hooks.id`, `hooks.kind`, `hooks.actor_id` (plus `hooks.scheduled_at` for schedule fires). The causal chain lives on the mutations the hook writes: each carries a `cause` of kind `hook_event` / `hook_schedule` with `parent` bound to the source mutation id (event hooks) and `trace` inherited from the source mutation's cause (schedule fires mint a fresh trace). `ctx.error` outcomes record as attributes, not as error status.

---

## Dispatch

**`Hooks::Handler`** — `event` hooks. Registered on the hooks `Event::Manager` as a stream subscriber per source doctype. Per message: skip `reentrant` events, resolve the source, look up matching hooks, filter by `source_events`, run each in declaration order, then `Event::Publisher.flush`. The filter is plain name matching — hooks have no opt-in list. An aggregate `child_changed` frame resolves to the parent doctype, so a hook on the parent doctype fires; a hook on the child doctype does not. A hook with no `source_events` fires on it; a scoped hook must name `child_changed`. Foreign-source hooks pass the grant gate first (`Grants::Registry.active?` for the owning domain on the source doctype; no grant → no fire) and receive `ctx.event.content` reduced to the granted tags (`project`) — same-domain hooks keep the full content. Delivery is ACK-on-arrival — a transient DB error during a hook is permanent until the next source mutation (logged, not retried), the same stance as `Replication::Handler`.

**`Hooks::Scheduler`** — `schedule` hooks. One poll-loop fiber, every `scheduler_poll_interval_s` (default 5s), reads `Registry#schedule_hooks` and fires due hooks exactly once per cluster. The loop is supervised by `Util::FiberSupervisor` — a raise that escapes the loop body (a tick failure is rescued in place and counted on `facet_fiber_loop_errors_total`) restarts the scheduler after a backoff:

1. Compute the fire bucket — `Cron::Parser#last(now)`, the most recent cron instant at or before now.
2. Acquire the lease `hooks:lease:{owning_domain}:{hook_id}:{fire_bucket_unix}` via `SET NX EX lease_ttl_s`.
3. On a win, run `on_schedule(scheduled_at: fire_bucket)`.

The unix-second bucket in the key makes the lease unusable for a different fire moment, so clock drift cannot double-fire. The lease TTL (default 600s) outlives `lua.time_limit_s`, so a slow script cannot cause a duplicate fire. There is no misfire catch-up: an outage longer than the lease TTL loses the missed bucket.

---

## Manager (`Hooks::Manager`)

The coordinator owns the registry, the handler, the scheduler, and a dedicated `Event::Manager` with `consumer_group_prefix = "cg:hooks:"` (one consumer group per owning domain). `main.cr` constructs it, calls `start` after the HTTP server boots, and `stop` on shutdown.

| Method | Effect |
|---|---|
| `.instance` / `.instance=` | Process-wide singleton; `nil` in contexts that do not boot hooks |
| `#start(db)` | Build the registry, register source subscriptions, start the event manager, start the scheduler and the subscriber-sync fiber |
| `#stop` | Stop the subscriber-sync fiber, the scheduler, and the event manager |
| `#mark_registry_stale` | Called by the `DoctypeCache` subscriber on `fanout:core.Domain:*` |
| `#build(db)` | Eager rebuild with a held connection |

Subscription sets and channel providers re-derive from the registry on every poll, so a hook edit adds or removes source subscriptions without a restart. Every runtime channel addition is paired with a dispatch registration through the per-domain add callback — without it the messages on the new channel would be read from the stream and silently dropped.

#### Subscriber sync

An owning domain that had no hooks at boot has no stream subscriber: the boot-time subscription set fixed it, and `set_channel_provider` cannot reach a subscriber that does not exist. A supervised sync fiber (`SUBSCRIBER_SYNC_INTERVAL`, 5 s) closes that gap: each tick reads the registry's owning domains (the read rebuilds the registry lazily when stale) and, for every domain without one, creates the subscriber via `Event::Manager#ensure_stream_subscriber` — initial channels subscribed before start, provider and add callback installed before start. The subscriber keeps the manager's `group_start_id` (`$`): it sees only events published from its creation onward — hooks do not replay (a replay would re-fire automations), so events emitted between boot and the first hook are not delivered to it. The drop is observable: `ensure_stream_subscriber` logs one WARN line naming the domain and the fact that entries published before its creation are skipped (B-337), and the channel-addition INFO line names the consumer kind and the same tail-start fact instead of a hardcoded "Replication" label. The WARN marks the window itself; it does not enumerate individual losses, and nothing re-delivers them. The per-event unmatched skip after the subscriber exists — an event whose source doctype carries no hook — is silent by design (`Hooks::Handler` returns without logging when `hooks_for` is empty).

---

## Config

| Key | Default | Purpose |
|---|---|---|
| `hooks.scheduler_poll_interval_s` | `5.0` | Schedule-hook poll interval |
| `hooks.lease_ttl_s` | `600` | Redis lease TTL for once-per-cluster fires |

The section is optional; defaults apply when absent. See [`config.md`](config.md).

---

## Wiring summary

| Touch point | Role |
|---|---|
| `Document::Update.validate_domain_hooks?` | Authoring-time hard gate on `core.Domain` writes (drafts included) |
| `Domain::Check.check_hooks` | Same validation as a read-only `/check` diagnostic |
| `Event::Subscriber::DoctypeCache` | Invalidates the registry on `fanout:core.Domain:*` |
| `Domain::Portable::Externalize` | Carries hook scripts into portable bundles as `hooks/{i}-{hook_id}.lua` |
| `main.cr` (`run_server`) | Constructs, starts, and stops `Hooks::Manager` |
