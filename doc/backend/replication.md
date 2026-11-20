# Cross-Domain Field Replication

Replication propagates field values from a source document to a
replica field on a consumer document that references it via a local
reference field. The typical edge is cross-domain (the producer and the
consumer live in separate bounded contexts), but same-domain edges are
also valid — they need no grant. The producer-consumer edge is declared
statically on the consumer doctype's field definition (the `replicate`
config), gated at doctype create/update time by `Replication::Validator`
(hard invariants), and processed at runtime by the replication registry
and handler.

The replication contract is:

- **Exactly one hop.** A replica may not itself be the source of another
  replicate edge, and a `via` field may not itself be a replica —
  `Replication::Validator.validate_invariants` rejects both at doctype
  create/update (422). Runtime reentrancy is enforced via the `reentrant`
  event header — the handler unconditionally skips reentrant source events.
- **No secret replication.** A replica may not pull from a `secret`
  source field — the runtime would copy the secret's marker object
  (`{mode, version, set_at}`) into the replica's public content, a
  tag-boundary bypass. `Replication::Validator.validate_invariants`
  rejects it at doctype create/update (422), and
  `Domain::Portable::Import` runs the same gate over every landed
  bundled definition (B-164). At runtime the registry drops a binding
  whose source field is a secret, and `SyncPull` leaves the replica
  null — both fail closed, so a consumer registered before its source
  field existed never starts copying the marker.
- **No tag escape.** A replica field must carry every tag its source
  field carries. The replica's own tags govern read visibility of the
  copied value. Tag-scoped read enforcement (`RBAC::FieldVisibility`)
  does not follow the value. A tag on the source but not on the replica
  would show the copied value to roles that cannot read the source.
  `Replication::Validator.validate_invariants` rejects the edge at
  doctype create/update (422), and `Domain::Portable::Import` runs the
  same gate over every landed bundled definition. `/check` reports a
  violation as a warning. The warning is the backstop for one hole the
  hard gate cannot close: an edit that adds a tag to a replicated source
  field does not re-run the consumer's hard gate, so a stored consumer
  can fall out of compliance without a new write to the consumer.
  Untagged fields resolve to `["default"]` on both sides, so an
  untagged replica of an untagged source stays legal.
- **New groups replay history.** The replication `Event::Manager` runs
  with `group_start_id = "0"`: a consumer group created after boot (a new
  consuming domain, a new source doctype added at runtime by
  `refresh_channels_if_changed`) replays the retained stream, so a new
  binding converges instead of missing every event emitted before its
  group existed. Existing groups keep their position (`BUSYGROUP` is
  ignored). Replaying is safe because the handler is convergent — it
  fetches the source's current projection value and diffs — and
  reentrant replay events are skipped by the existing gate.
- **Reference-field-scoped.** A replica pulls from a specific source field via
  a local `reference`-typed field on the same doctype; source updates
  propagate when the source document mutates.
- **Single source of truth (DB-direct).** The handler always re-fetches the
  source projection from PostgreSQL to compute the new replica value (no
  in-event payload diffing). The mutation is persisted normally and shows up
  in the audit log.
- **Same-domain edges need no grant.** The producer-side grant check applies
  only when the source and the consumer live in different domains — the grant
  is the data-sharing contract between bounded contexts, and a domain granting
  to itself would be pure ceremony. Cross-domain edges still fail closed:
  `Replication::Validator` surfaces a missing grant on `/check`, and
  `Replication::Registry` drops the binding at build time.
- **Replica fields are server-populated.** Users cannot write them (the
  document write gate rejects the key), and they cannot be `required` or
  `unique` — `Doctype::Validation` rejects that shape at authoring time, and
  the unique index would be governed by the source field, not the replica.
- **`on_source_delete` lives on the replica field** — the field that carries
  the `replicate` config. It is read only from there (`Replication::Registry`
  builds the binding from the replica field's definition), so a declaration on
  the `via` reference field is an authoring error (B-45): `Doctype::Validation`
  rejects `on_source_delete` on any field without a `replicate` config instead
  of storing a policy that never fires. There is no separate
  reference-clearing semantics: `on_source_delete` never governed the `via`
  reference itself, and it still does not — on source deletion the reference
  field is never touched and the dangling id remains (the same rule the
  handler applies to every binding). The `replicate` sub-config itself only
  accepts `via` and `field`; `on_source_delete` inside it is rejected at
  parse time.

Concern source files: `src/replication.cr`, `src/replication/*`.

## Public API

### `Replication::Binding`

`record Binding, consumer_domain, consumer_doctype, ref_field,
replica_field, source_doctype, source_field, on_source_delete`

Consumer-centric description of one replication edge.

| field              | meaning                                                              |
| ------------------ | -------------------------------------------------------------------- |
| `consumer_domain`  | Domain of the consumer document (e.g. `"hr"`).                       |
| `consumer_doctype` | Doctype name of the consumer (e.g. `"Employee"`).                    |
| `ref_field`        | Local reference field on the consumer (the `via`).                  |
| `replica_field`    | Local field that holds the replicated value (field name `F.name`).  |
| `source_doctype`   | Qualified source id `"domain.Doctype"` (e.g. `"identity.Person"`).  |
| `source_field`     | Source field name (e.g. `"full_name"`).                              |
| `on_source_delete` | `"keep"` (default) or `"unset"`.                                     |

### `Replication::Validator`

Two entry points with different enforcement levels:

- `validate_invariants` — the hard invariants, enforced at doctype
  create/update time. A violation rejects the definition with a 422.
- `validate` — the advisory diagnostics, invoked by `Doctype::Check` (the
  `/Api/core/DocType/:id/check` endpoint) on demand. Each failure becomes a
  warning issue, never a create/update rejection.

The advisory checks stay advisory because they depend on other domains
(grant coverage, source doctype/field existence, type match, draft-source
isolation) and would create ordering dependencies between domains. The
runtime registry / SyncPull fail closed on those broken configs.

| method                                              | description                                                                         |
| --------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `validate_invariants(consumer_def, db) -> Array(String)` | Hard invariants, called by `Doctype::Create` and `Doctype::Update` before persisting, and by `Domain::Portable::Import` over every landed bundled definition (after the bundle's doctype loop — a bundle may order the consumer before its producer; a violation aborts the import with a 422). Rejects (422) when the `via` field is itself a replica, the `via` reference target is unqualified (e.g. `doctype: Vault` — it can never resolve a source, so the gate fails closed instead of skipping the secret check), the source field is a replica (replica-of-replica), the source field is a `secret` field, or the replica field does not carry every tag the source field carries (untagged fields resolve to `["default"]` on both sides, so an untagged replica of an untagged source stays legal). A well-formed source that cannot be resolved yet (missing source doctype or source field) is left to the advisory diagnostics — no invariant fires on it, so a consumer may land before its producer. |
| `validate(consumer_def, db) -> Array(String)`       | Advisory diagnostics for all replicate fields on a `DoctypeDefinition`. Returns an array of error strings, each surfaced by `/check` as a `:replication` issue. The tag-coverage diagnostic repeats the hard invariant as a warning: a producer-side edit that adds a tag to a replicated source field never re-runs the consumer's hard gate, so `/check` is the only surface that flags the drift. Cross-domain edges verify grant coverage against the `core.DomainGrant` documents under the producer — see [`domain-grants.md`](domain-grants.md). |
| `draft_domain?(db, domain) -> Bool` | Public reader for the producer-side draft flag. Used by both `Registry#fetch_all_doctype_definitions` (independent EXISTS filter) and `Validator`'s live-consumer-replicating-from-draft-source warning emitted via `/check`. |

The write doors run only the hard invariants. `Doctype::Create`,
`Doctype::Update`, and `Domain::Portable::Import` give no message for a
replicate source that cannot resolve yet (missing source doctype or
missing source field) — the acceptance is by design (B-164), so a
consumer can land before its producer. `/check` is the only surface
that names the gap: the advisory `validate` reports "field 'x' does not
exist on source doctype" as a `:replication` warning.

### `Replication::Registry`

Process-wide map of replication edges, keyed by **source doctype
qualified id**. Built once at startup; kept in sync with `core.DocType`
mutations via a **stale-flag / lazy-rebuild** model (see `Manager` below).

| method                                | description                                                                                               |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `new(domain_enabled : String -> Bool)` | Constructor. Accepts a predicate that filters consumer domains. Defaults to `Config#domain_enabled?`.    |
| `build(db : DB::Connection) -> Nil`    | Rebuilds the binding map from all non-deleted `core.DocType` projections. Resolves the source field definition for every binding (same-domain edges included) and drops one whose source field is missing or a `secret`. Re-asserts grant coverage per cross-domain binding through `Grants::Registry.covers?`. Clears the stale flag. |
| `mark_stale -> Nil`                   | Sets the stale flag without rebuilding. Called by the `DoctypeCache` Pub/Sub subscriber on every `core.DocType` fanout event. Coalesces a flock of events into one on-read rebuild. |
| `bindings_for(source_doctype) -> Array(Binding)` | O(1) lookup by source doctype qualified id. Triggers `ensure_fresh` (lazy rebuild if stale). |
| `source_doctypes : Set(String)`       | All distinct source doctypes that this instance must subscribe to. Triggers `ensure_fresh` if stale.    |
| `consumer_domains : Set(String)`      | All distinct consumer domains (drives `cg:repl:{domain}` consumer groups). Triggers `ensure_fresh` if stale. |

Every rebuild also resolves the source field definition for **every**
edge, same-domain edges included. A binding whose source field does not
resolve is dropped, and a binding whose source field is a `secret` is
dropped. This closes the ordering hole: a consumer registered while its
source doctype does not exist yet passes the authoring gate (the
invariants skip an unresolvable source), so the registry re-asserts the
field rules when the producer lands.

When the grant coverage has been revoked since the doctype was created (or
was never present) on a **cross-domain** edge, the binding is **dropped**
and the miss is logged. Fail-closed — the runtime registry is the safety
net for `Replication::Validator`. Same-domain edges (source domain ==
consumer domain) skip the grant check: no grant is required (D7). Grant
coverage re-asserts against the producer's current field tags on every
rebuild — see [`domain-grants.md`](domain-grants.md) → The four gates.

#### Stale-flag / lazy-rebuild

The registry never rebuilds eagerly on a `core.DocType` mutation. The
`DoctypeCache` Pub/Sub subscriber calls `mark_stale` (a flag-set, no DB
access); the next read (`bindings_for` / `source_doctypes` /
`consumer_domains`) calls `ensure_fresh`, which rebuilds from the DB via
`Database.with_db` only when the flag is set, then clears it. This mirrors
`DefinitionStore`'s invalidate-only pattern: events signal staleness across
the cluster via Redis Pub/Sub fanout; each node recovers via its own direct
DB query and re-caches locally on the next read. A flock of mutations spaced
milliseconds apart (e.g. publishing a whole domain with N doctypes)
coalesces into a single rebuild — the flag is idempotent, and the rebuild
clears it.

### `Replication::SyncPull`

Write-time hook that pulls the **initial value** of a replica field from its
source at the moment a consumer document is created or its `via` reference
field is changed. Hooked from `Document::Create` (always at create) and
`Document::Update` (only when a `via` field changed).

```crystal
SyncPull.call(db, definition, content, changed_via_fields : Set(String)?) : JSON::Any
```

- `changed_via_fields = nil` — create path: pull every replicate field with a
  non-null `via` value.
- `changed_via_fields = Set{"via_field_name"}` — update path: pull only those
  replicate fields whose `via` field is in the set.

`SyncPull` runs in `Document::Create` BEFORE compute so any computed field
whose `compute_when` includes the replica field sees the freshly-pulled
initial value rather than a null placeholder. The portable-domain import
(`Domain::Portable::Import`) calls `SyncPull` for every bundled document it
creates, so an imported bundle lands consistent; a source document that has
not landed yet in the same import transaction leaves the replica null (best
effort, same soft-failure semantics).

`SyncPull` leaves the replica null when the source field is no longer
declared on the source doctype — a field removed from the source definition
must not be copied from a stale stored value into new replica rows. This
declaration gate applies to same-domain edges too, not only the
cross-domain grant path. The same gate refuses a `secret` source field —
the replica stays null and the miss is logged (B-164). A consumer
registered before the source field existed would otherwise start pulling
the secret's marker object the moment the producer lands.

### `Replication::Handler`

Async source-event handler registered as the no-filter subscription callback
on the replication `Event::Manager`. Processes each incoming `Message`:

1. **Reentrancy skip** — if `msg.headers["reentrant"] == true`, ACK and return
   immediately (one-hop gate).
2. **Resolve source** — `headers["domain"].headers["doc_type"]` is the source
   doctype; `content["id"]` is the source id.
3. **Registry lookup** — fetch bindings for the source doctype; none → return.
4. **Dispatch by event type:**
   - `deleted` → apply `on_source_delete` (`keep` is a no-op, `unset`
     patches `{replica_field: null}`, which the merge-patch update
     semantics turn into a key removal on every referencing consumer).
   - `created`, `snapshot`, `migrated`, `rolled_back` → full sync: re-pull the
     source value and apply to every referencing consumer.
   - `updated`, `action` → DB-direct source fetch + per-consumer diff
     against the consumer's current replica value; skip if equal
     (empty-diff suppression at the second safety net).
5. **Apply** — for each affected consumer, build a partial-patch body
   `{"<replica_field>": <new_value>}` and call `Document::Update.call` with
   `reentrant: true`. The service layer writes a **real mutation row**
   (visible in the audit log) and enqueues the event with `reentrant: true`
   via `Event::Publisher.enqueue`. The handler invokes `Publisher.flush` once
   at the end of `Handler#call`.

When the replicated value is a `file` field (a bare artifact id), the
handler appends an `artifact_owners` row in the consumer domain so the
artifact is readable through the consumer document — artifacts are
transversal, so a new owner row is the whole operation (see
[`artifact.md`](artifact.md) → Owner-append lifecycle). A replicated
longtext field carries its URN links inside the markdown value; those
shares append through the service layer (`Document::Update` →
`Artifact::Owners.append_readable_for_document`, system bypasses the read
gate) with no handler-side code.

ACK-on-arrival: the underlying `Subscriber::Stream` runs with `no_ack: true`.
A transient DB error during the consumer write is permanent until the next
source mutation (by design — logged, never retried in v1).

### `Replication::Queries`

| method | description |
| --- | --- |
| `Queries.referencing_docs(db, binding, source_id) -> Array(String)` | Returns the ids of all non-deleted consumer documents whose `via` field equals `source_id`. Backed by the per-reference btree index managed by `Index::Manager` (every `reference`-typed field gets a partial index on `((content->>'<ref_field>'))` scoped to `(domain, doc_type, deleted_at IS NULL)`). |

### `Replication::Manager`

Coordinator that owns the replication `Event::Manager` instance
(`consumer_group_prefix = "cg:repl:"`), the `Registry`, and the `Handler`.

Exposes a process-wide singleton accessor (`self.instance` /
`self.instance=`) mirroring `Websocket::Manager`. The `DoctypeCache` Pub/Sub
subscriber calls `Replication::Manager.instance.try(&.mark_registry_stale)`
on every `core.DocType` fanout event so new/removed/changed replication
edges are picked up on the next registry read without a server restart. The
accessor returns `nil` when no manager is installed (e.g. test contexts
that don't boot the replication subsystem); the subscriber uses `try` to
skip safely. The doctype mutation services (`Doctype::Create`,
`Doctype::Update`, `Domain::Publish`) do **not** call `refresh` directly —
they only enqueue `core.DocType` events; the fanout subscriber drives the
invalidation.

| method | description |
| --- | --- |
| `new(config, service_id, domain_enabled)` | Constructs the event manager, registry, handler. |
| `self.instance` / `self.instance=` | Process-wide singleton accessor (mirrors `Websocket::Manager`). |
| `start(db : DB::Connection) -> Nil` | Builds the registry, registers subscriptions, installs per-domain provider + add-callback wiring (runtime channel regeneration), starts the event manager, and starts the subscriber-sync fiber. |
| `stop -> Nil` | Stops the subscriber-sync fiber and the event manager. |
| `mark_registry_stale -> Nil` | Flags the registry stale (no DB access). Called by the `DoctypeCache` Pub/Sub subscriber on both `core.DocType` and `core.Domain` fanouts — a grants write is a domain-doc mutation and emits no doctype event, so the domain branch is what keeps grant changes from being invisible to a cached grant-less build. The next `bindings_for` / `source_doctypes` / `consumer_domains` read rebuilds lazily from the DB. |
| `refresh(db : DB::Connection) -> Nil` | Eager rebuild — builds the registry and re-installs the per-domain wiring. Used at `start`; not the event-driven invalidation path (use `mark_registry_stale`). No-op unless `started?` is true. |

#### Subscriber sync

A consuming domain that gains its first binding **after** boot has no stream
subscriber: the boot-time subscription set fixed it, and a provider cannot be
installed on a subscriber that does not exist. A supervised sync fiber
(`SUBSCRIBER_SYNC_INTERVAL`, 5 s) closes that gap: each tick reads
`registry.consumer_domains` (the read rebuilds the registry lazily when
stale) and, for every domain without one, creates the subscriber via
`Event::Manager#ensure_stream_subscriber` — initial channels subscribed
before start, provider and add-callback installed before start. The
subscriber is built with the manager's `group_start_id` (`"0"`), so a
late-created group replays the retained stream and converges instead of
missing the events published before it existed.

Every runtime channel addition is paired with a dispatch registration
(`register_stream_subscription`): the dispatcher delivers messages to
registered subscriptions only, so a channel added without its registration
would be read from the stream and silently dropped — the B-35 failure shape
(source updates consumed but no replica write, no mutation row, event bus
healthy). The pairing lives in the per-domain add callback; the sync fiber
registers the initial channel set the same way.

> **Note — same defect family elsewhere:** `Hooks::Manager` registers its
> stream subscriptions with the identical boot-time pattern and shares the
> channel-provider mechanism; the pairing fix above is applied to the
> replication manager only.

### `Event::Subscriber::DoctypeCache`

Long-lived Pub/Sub subscriber on five patterns (`fanout:core.DocType:*`,
`fanout:core.Domain:*`, `fanout:core.DomainGrant:*`, `fanout:core.Webhook:*`,
`fanout:core.Currency:*`) that invalidates process-local caches on any
doctype, domain, grant, webhook or currency event. All follow the
**invalidate-only** pattern — the subscriber never rebuilds, it only
signals staleness; each node recovers via its own direct DB query on the
next read.

> **Staleness bound (fanout-loss safety net):** Pub/Sub delivery is
> fire-and-forget, so a mutation published while Redis was down reaches no
> subscriber and an invalidate-only cache would serve the old data until
> restart. Every cache on the receiving end therefore also stamps the
> monotonic time of its last successful rebuild and treats reads past
> `cache.staleness_ttl_s` (default 300 s; `0` disables) as stale — see
> `Util::CacheFreshness`. The fanout stays the fast path; the bound only
> caps the worst case. Applies to the doctype definition cache
> (`ProcessDefinitionCache`), `OAuth::OriginCache`, `App::Hosting::HostCache`,
> the replication / hooks / webhook registries, and the currency registry.
> The MCP tools generation has no server-side cached data — `tools/list`
> computes the listing per call — so there is nothing to bound there.

- Started in `main.cr` BEFORE any `DefinitionStore.fetch` call at startup
  (subscribe-before-fetch prevents stale-forever windows).
- Pure pattern-subscribe; never inspects the payload. On each message it:
  1. DocType fanout → `Doctype::DefinitionStore.invalidate(doctype_id)` —
     evicts the cached definition so the next `fetch` reads from the DB.
  2. DocType fanout → `Replication::Manager.instance.try(&.mark_registry_stale)`.
  3. Domain fanout → `Replication::Manager.instance.try(&.mark_registry_stale)`
     AND `Hooks::Manager.instance.try(&.mark_registry_stale)`.
  4. DomainGrant fanout → `Grants::Registry.mark_stale` AND
     `Replication::Manager.instance.try(&.mark_registry_stale)` AND
     `Hooks::Manager.instance.try(&.mark_registry_stale)` — a grant change
     must cut or restore bindings and hook fires without a restart (see
     [`domain-grants.md`](domain-grants.md) → `Grants::Registry`).

## Runtime wiring (`main.cr` — `server` command)

1. Construct the general-purpose `Event::Manager` (no custom prefix) and
   start it (was wired earlier but never actually started).
2. Swap `DefinitionStore.cache` for `ProcessDefinitionCache.new` so the
   doctype-cache eviction is meaningful at process scope.
3. Start `Event::Subscriber::DoctypeCache` before `HTTP::Server.routes`.
4. Construct and start `Replication::Manager`, then install it via
   `Replication::Manager.instance =` so the `DoctypeCache` Pub/Sub
   subscriber can invalidate the registry via `mark_registry_stale` on
   every `core.DocType` fanout event.
5. Register an `at_exit` handler for clean shutdown of both managers.

> **Registry invalidation on doctype mutations:** `Doctype::Create.call`,
> `Doctype::Update.call`, and `Domain::Publish.call` enqueue a
> `core.DocType` event (`registered` / `updated`) during the mutation.
> The HTTP layer's post-commit `Event::Publisher.flush` delivers it to Redis
> Pub/Sub. The `Subscriber::DoctypeCache` receives the fanout and calls
> `Replication::Manager.instance.try(&.mark_registry_stale)`; the next
> registry read rebuilds lazily from the DB via `Registry#ensure_fresh`.
> No eager rebuild runs on the mutation path — the invalidation is
> fanout-driven and works across a multi-node cluster (each node's
> subscriber receives the same fanout and marks its local registry stale).
>
> **WebSocket note:** `Subscriber::Fanout` (used by the WebSocket bridge) is
> an independent Redis Pub/Sub path driven by `ws_manager.start`. It is NOT
> affected by the general `Event::Manager.start` being added.

## Reentrancy guard

The `reentrant` header is the one-hop gate. It is a boolean — read raw via
`msg.headers["reentrant"]?.try(&.as_bool?) == true`. The guard fires on the
source side when:

- A replication handler writes the consumer with `Document::Update.call(...
  reentrant: true)`, which `Event::Publisher.enqueue(..., reentrant: true)`
  surfaces as the `reentrant` header on the emitted event.

The downstream consumer's handler then sees the header and skips. This
prevents transitive A→B→C chains on computed fields: A.x → B.replica_x
(replicated) → B.c (computed, `compute_when: [replica_x]`) → C.replica_c
(replicated from B.c, allowed because B.c is computed, not a replica).

## Reference-field indexing (cross-cutting)

Per the indexing convention: **every `reference`-typed field gets a partial
btree index on `((content->>'<field>'))` scoped to
`(domain, doc_type, deleted_at IS NULL)`**. The `Index::Manager` materially
indexes reference fields; `operators` on reference fields are deliberately
ignored (only `eq` is implied).

This is the index used by `Replication::Queries.referencing_docs` to find
consumer documents pointing at a deleted/mutated source.

## Test infrastructure

Specs live in `spec/replication/`:

| file | coverage |
| --- | --- |
| `validator_spec.cr` | `Replication::Validator`, including the `upsert_domain_with_grants` and `create_simple_doctype` helpers (reused by the rest of the directory). |
| `registry_spec.cr` | `Replication::Registry` build, fail-closed grant re-assert, active-domain filter. Reusable helpers: `setup_replicate_pair`, `register_person_doctype`, `register_employee_with_replicate`, `create_person`. |
| `sync_pull_spec.cr` | `Replication::SyncPull` happy + sad paths (source deleted, null via, via change, unrelated via change). |
| `handler_spec.cr` | Async-source-event handler — propagation, empty-diff suppression, deletion policies (`keep` / `unset`), fail-closed, mutation-log visibility, one-hop skip on reentrant header. Reusable helpers: `setup_handler_pair`, `create_employee`, `source_message`. |
| `reentrancy_spec.cr` | The A→B→C invariant test (replica → computed → replica chain) — asserts B.replica_x + B.c propagate from A.x, and C.replica_c does NOT update on the reentrant downstream event. |

Tests use the global `Event::InProcessManager` installed in `spec_helper.cr`
(synchronous dispatch, no Redis). For real Redis stream tests, mirror
`spec/event/manager_spec.cr` with `EVENT_REDIS_URL=redis://localhost:6379/9`.
