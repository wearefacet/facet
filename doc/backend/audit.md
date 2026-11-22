# Audit System

**Files:** `src/audit/` (routes in `src/audit/routes.cr`)

The audit system provides a read-only view of the append-only `mutations` table and a rollback mechanism for restoring documents to a previous state.

Unlike normal doctypes, `Audit` is a **virtual namespace** — it has no `core.DocType` entry, no seed directory, and no projections. It exposes the `mutations` table directly through its own business logic.

---

## Audit::List (`src/audit/list.cr`)

Queries the `mutations` table with optional filters and pagination. Returns mutation rows (not projections).

### Authorization modes

Two modes, selected by the `doc_id` argument:

- **Document history** (`doc_id` present, with `domain` and `doc_type`): the target document's read gate applies. A caller that holds no read permission on the doctype at all — role denial, or the layer-1 app-grant ceiling — answers `403`. A grant holder that cannot see the target document answers the non-disclosing `404`: an inaccessible document is indistinguishable from a missing one.
- **Global** (`doc_id` absent): requires wildcard `*.*` `read` (or system bypass). `domain` / `doc_type` act as **filters**, never as gates — a wildcard-read holder asks "what changed in domain X" in one call. Denied → `403`. App-scoped callers (channel `oauth_app` or `app_api_key`) are denied regardless of role: a grant names one concrete domain, so no grant can cover a cross-domain view, and the row's `arguments` would leak non-granted doctypes. Document history inside the grant reach stays open.

### Filterable fields

| Field | Filter operator | Description |
|---|---|---|
| `domain` | `__eq` | Filter by domain |
| `doc_type` | `__eq` | Filter by doctype — a bare name matches the bare column across every domain; the qualified `domain.Doctype` form filters domain and doctype in one conjunct (the picker form — the bare column is ambiguous across domains) |
| `doc_id` | `__eq` | Filter by document ID |
| `action` | `__eq`, `__ne` | Filter by action (`create`, `update`, `delete`, `snapshot`) |
| `actioner_id` | `__eq`, `__ne` | Filter by the identity that performed the mutation |
| `app` | `__eq`, `__ne` | Filter by the `app.App` projection id (`mutations.app`). `app__ne` includes rows with no app attribution |
| `channel` | `__eq`, `__ne` | Filter by the authentication surface (`session`, `oauth_app`, `app_api_key`, `api_key`, `mcp`, `internal`) |
| `kind` | `__eq`, `__ne` | Filter by the cause kind (`cause_kind`) |
| `trace` | `__eq`, `__ne` | Filter by the causal-cluster root (`cause_trace`) — one cluster is one query |
| `emitted_at` | `__gte`, `__lte` | Date range filter |

Filters ride the bracket form (`filters[<field>__op]=value`) or the QUERY
body. The GET admission is strict — a bare query parameter such as
`?doc_type=Invoice` answers `422` (see GET query admission (strict) below).
The document-history and child-history routes take `domain`, `doc_type`,
and `doc_id` from the path segments, not from filters.

`Audit::List.call` validates the filter map against this grammar before it
builds any SQL. An unknown field answers `422` (`unknown_filter_field`) with
the filterable list in the message; a known field with an unsupported
operator answers `422` (`unsupported_filter_operator`) with the allowed set.
The message and the structured detail (`field`, `code`) follow the same
shape as the document list's filter errors. A wrong filter key always
answers `422` — it never returns a silent unfiltered result (B-145, the
B-20 contract).

### Public API

```crystal
Audit::List.call(
  db,
  domain: "hr",
  doc_type: "Employee",
  filters: {"action__eq" => JSON::Any.new("create")},
  sort: ["-emitted_at"],
  page: 1,
  items_per_page: 100,
  include_children: false,
) # => Audit::List::Result | Audit::List::Error
```

### Return type

```crystal
record MutationRecord,
  domain : String,
  doc_type : String,
  id : String,
  doc_id : String,
  idx : Int32,
  action : String,
  actioner_id : String,
  arguments : JSON::Any,
  channel : String,
  app : String?,
  api_key : String?,
  acting_role : String?,
  cause_kind : String,
  cause_name : String?,
  cause_event : String?,
  cause_source : String?,
  cause_parent : String?,
  cause_trace : String,
  emitted_at : Time,
  display_name : String?,
  redacted : Array(Array(String)) = [] of Array(String)
```

The provenance and cause fields are typed columns on `mutations` (promoted from the former JSONB `meta` column). `app` is the `app.App` projection id when the mutation was made through an app-scoped identity; `nil` for ordinary browser-session and system-tier mutations. `channel`, `cause_kind`, and `cause_trace` are `NOT NULL` — every mutation is stamped, system triggers included (`periodic_snapshot` stamps `channel=internal`, `cause_kind=periodic_snapshot`).

`display_name` is the target document's label, read from the projection row. Aggregate mode populates it; plain mode leaves it `nil`.

### Argument redaction (`src/audit/redact.cr`)

`Audit::List` redacts each page's arguments for the calling principal before returning (definitions cache per `(domain, doc_type)` within the page). A tagged-down Real reader never sees invisible field values in the mutation log; the removed content paths land in `redacted` — each entry is an array of path segments, the same form the diff paths use. Redaction is out-of-band metadata only: no `"__redacted__"` markers ever enter the content itself.

Rules by row **shape** (never by `cause_kind`):

| Shape | What happens |
|---|---|
| `arguments.content` present (create, snapshot, delete tombstones) | invisible values are removed recursively (a visible parent keeps its visible portion); every removed path is appended to `redacted` |
| `arguments.diff` present (update, including named-action updates) | `diff.set` entries at invisible paths keep their `path` but lose `value` / `patch`; a visible parent set with invisible nested content keeps the visible portion and lists each removed nested path; `diff.unset` paths stay and never gain a redaction entry |
| missing definition | fail closed — all content values removed with the root path `[]`; each `diff.set` path loses its value |
| unknown historical field (absent from the current definition) | fail closed — value removed, path appended |
| System, Preview, or a wildcard-tag role | raw arguments, `redacted: []` |

Diff-path resolution is shape-aware and shared with the write guards (`Doctype::FieldPath` in `src/doctype/field_path.cr`). A path resolves through object `properties`, array `items`, and dictionary `dictionary_value`. The stored members of the object-valued scalar kinds (money `value` / `currency`; period and dateperiod `start` / `end`; secret markers `mode` / `version` / `set_at`) resolve to the owning field, and so does any segment below a free-form shape (an `object` without `properties`, `any`, `data`). Visibility is checked at every level of the descent — an invisible level hides every path below it. A path that does not resolve against the definition fails closed like an unknown historical path.

The serialized HTTP (`audit_mutation_hash` → `redacted`) and agent-tool (`list_mutations` → `redacted`) payloads share the contract, and neither contains the original values after redaction.

### Rollback transition gates

`Audit::Rollback` runs two caller-level checks on the **actual current-versus-replayed transition** before any persistence — the selected mutation's own diff is irrelevant:

1. **Role authority** (IAM doctypes) — a rollback that would resurrect stronger IAM state (a historical admin assignment, a stronger role, a higher level on a protected target) answers `403` before the snapshot is written.
2. **Field visibility** (every doctype) — a rollback that rewinds a value into an invisible field answers `403`, even when the selected target mutation touched only visible fields. A rollback whose actual diff touches only visible fields passes. The actual diff is resolved shape-aware (`Doctype::FieldPath`), so a rewind that lands on a member sub-path — a money `value`, a dictionary key, a secret marker member — is judged by the field or descriptor that owns it; an invisible owner or descriptor refuses the rollback the same way.

Cluster rollback preflight authorizes every resulting restore and delete the same way before writing any document; one denial aborts the complete cluster (no document changes, no events).

### Aggregate history (`include=children`)

`include_children` switches the document history into aggregate mode. The parent's timeline then merges the mutation rows of its child documents. It applies only when `domain`, `doc_type`, and `doc_id` are all set; every other call keeps the plain query.

- The child doctype set comes from the parent definition's `children` map. A missing child definition adds no branch.
- Per child doctype, the query pre-resolves readable child ids with that doctype's own `ReadEnforcer.list_where_clauses`. A denied scope resolves no ids, so the query omits the branch.
- One WHERE joins the parent branch and the per-child branches. A child branch pins the child `doc_type`, `parent_doc_id`, and the readable id list.
- The merge order is `emitted_at` (DESC by default) with the mutation id as tiebreak. The per-document `idx` does not join the merge sort.
- The COUNT query mirrors both branches, so the total counts each row once. The count itself is unbounded — the HTTP layer applies the cap.

Access follows a two-rule model. The parent read gates the request: a caller that holds no read permission on the parent doctype at all answers `403`; a grant holder that cannot see the parent answers the non-disclosing `404`. The query then filters each child branch through the child doctype's own list scope. A caller with no grant on a child doctype sees no child rows, never a `403`.

Tombstones shape child visibility. A delete tombstone keeps its payload until `Cron::TombstoneContentPrune` clears it after the retention window. Before the prune, a reader whose scope matches still sees the child's rows, with its label. After the prune, the scope no longer matches, and the rows drop out — fail-closed. A reader with an unrestricted grant keeps seeing them.

---

## Audit::Rollback (`src/audit/rollback.cr`)

Restores a document to the state it had at a specific mutation. The algorithm:

1. **Resolve the target mutation** by ULID → get `(domain, doc_type, doc_id, idx, action)`
2. **Replay the document history up to the target** via `Audit::Replay.state_at` (from the last snapshot at or below the target): `create` → set content from `arguments->content`, `update` → apply the diff, `snapshot` → overwrite content from `arguments->content`, `delete` → no-op for content replay
3. **Persist the result** as a new `snapshot` mutation with `actioner_id: "system:rollback"` and a `cause_kind` of `rollback` whose `cause_parent` is the target mutation id (used by consumers to trace the snapshot back to the exact mutation it rolled back to)

The target mutation is resolved as `(domain, doc_type, doc_id, idx, action)`. A `delete` target first resolves to the mutation immediately before the delete, so a rollback to a delete restores the document. Only a delete with no preceding mutation returns `Error.new(422, ...)` — there is no state to restore.

### Public API

```crystal
Audit::Rollback.call(
  db,
  mutation_id: "01ABCD...",
  auth_context: RBAC::AuthContext.system,
) # => Audit::Rollback::Result | Audit::Rollback::Error
```

The snapshot's `cause_parent` is the target mutation id and `cause_trace` is the snapshot's own id (each rollback starts a new causal cluster). `reentrant` controls whether the emitted `rolled_back` event is re-entrant. The `actioner_id` recorded on the snapshot mutation is derived from `auth_context`: `"system:rollback"` when the caller is the system context, otherwise the caller's `account_id`.

The snapshot persists the replayed meta — the projection meta as of the target state. A restored child keeps `meta.parent_id`, so it stays attached to its parent and its rows rejoin the aggregate read. `schema_version` falls back to the current projection's value, then to `1`. This is the same payload `Cron::MutationCompaction` stores on its boundary snapshot.

### Cascade restore

A restore also brings back the composition children that the undone delete cascade-tombstoned. The trigger is a rollback whose target document is tombstoned: the target itself is a `delete`, or the document's latest mutation is a `delete` (the restore endpoint passes the pre-delete mutation, so there the undone delete is the latest row).

The cascade set is the `cause_kind='cascade'` delete rows causally linked to the undone delete. `Document::Delete` stamps every cascade tombstone's `cause_parent` with the family root's delete id, so the whole subtree links to one id today; the collector still walks the links transitively, so a per-level parent stamping would keep working. A child restores only when that cascade delete is still its most recent mutation — a child re-created or re-deleted later stays untouched. Each child resolves its own pre-delete target and replays through the same persist path, writing its own `snapshot` mutation (`cause_kind=rollback`) and emitting its own `rolled_back` event.

The preflight is all-or-nothing and mirrors the cluster preflight: the caller's `update` right plus the role-authority and field-visibility gates run on every child before any write. One denial aborts the whole restore with `403` — no writes, no events. The parent snapshot and every child restore share one transaction. `Audit::Rollback::Result.cascade_restored` lists each restored child as `{domain, doc_type, doc_id, mut_id}`; it is empty for every other rollback. Cluster-scope undo is unchanged.

### Important notes

- Rollback produces a `snapshot` mutation, not a new action type. The `action CHECK` constraint only allows `create/update/delete/snapshot`.
- The rollback's snapshot mutation is recorded with `actioner_id` `"system:rollback"` (when called with the system auth context) so rollbacks are traceable in the audit log.
- **Rollback to a `delete` mutation restores the document.** The target resolves to the mutation immediately before the delete, and the persisted snapshot clears `deleted_at`, so the document is live again. Only a delete with no preceding mutation returns `422` (degenerate history — no state to restore).
- **Rollback depth equals the retention window.** `Cron::MutationCompaction` replaces mutations older than `mutations.retention_days` with one synthetic `snapshot` row (see [`mutation.md`](mutation.md) → Retention compaction). A rollback request for a mutation older than the window returns `404` (the row is gone); the 404 body names the effective window — see [Mutation-id shape (422)](#mutation-id-shape-422). Cluster-scope undo beyond the window is partial: a document whose first cluster mutation was compacted is not reverted by the undo, because the pre-cluster state no longer replays. Tombstoned documents always keep their trailing `delete` and its predecessor — the compaction clamps the cut to `delete_idx - 2` — so restore and rollback-to-delete stay reachable inside the window.

---

## Audit::Replay (`src/audit/replay.cr`)

Shared replay of one document's mutation history. `Audit::Rollback` replays content to a target mutation; `Cron::MutationCompaction` replays the document state at the retention cut. The replay rules are one concern here so the two services cannot drift.

Replay starts at the most recent `snapshot` mutation with `idx <= target_idx` (or `{}` when none exists) and applies every row through `target_idx`: `create` → content and meta from `arguments`, `version = 1`, `created_at` from the row's `emitted_at`; `update` → apply `diff` / `meta_diff` (`Mutation::JsonDiff.apply_diff`); `snapshot` → overwrite all four fields from `arguments`; `delete` → no-op.

```crystal
state = Audit::Replay.state_at(db, domain, doc_type, doc_id, target_idx)
state.content    # JSON::Any
state.meta       # JSON::Any
state.version    # Int32
state.created_at # String (RFC-3339)
```

---

## Audit::Restore (`src/audit/restore.cr`)

Resolves the restore target for a deleted (tombstoned) document: the mutation immediately preceding the document's most recent `delete`. This is the pure-read half of the restore workflow — the write half is `Audit::Rollback`, which owns the RBAC gate (`update`) and the audit trail entry. A prior restore snapshot is a valid target, so iterative delete/restore loops stay reachable.

### Public API

```crystal
Audit::Restore.resolve_target(
  db,
  domain: "hr",
  doc_type: "Employee",
  doc_id: "abc123",
) # => String | ServiceError
```

| Outcome | Status | Meaning |
|---|---|---|
| `String` | — | Mutation id to roll back to |
| `ServiceError` | `404` | No mutations exist for the document |
| `ServiceError` | `409` | The document is live (most recent mutation is not a `delete`) |
| `ServiceError` | `422` | A `delete` exists but no mutation precedes it (degenerate history) |

When the `delete` directly follows the `create`, the resolver returns the `create` itself — rolling back to it replays the create and skips the delete, restoring the create content.

Restoring a document also restores its cascade-tombstoned composition children (default-on). `Audit::Rollback` owns that walk and its RBAC preflight — see the Rollback section → Cascade restore.

---

## HTTP Routes

| Method | Route | Handler | Description |
|---|---|---|---|
| `GET` / `QUERY` | `/Api/Audit` | `Audit::List.call` | Global audit log (all mutations, paginated) |
| `POST` | `/Api/Audit/:mutation_id/rollback` | `Audit::Rollback.call` | Rollback to a specific mutation by ULID |
| `GET` / `QUERY` | `/Api/:domain/:doctype/:id/history` | `Audit::List.call` scoped | Document mutation history. `?include=children` (GET) / `{"include": "children"}` (QUERY body) merges readable child rows into the timeline (aggregate mode) |
| `POST` | `/Api/:domain/:doctype/:id/rollback` | `Audit::Rollback.call` scoped | Rollback document (body: `{"mutation_id": "..."}`) |
| `POST` | `/Api/:domain/:doctype/:id/restore` | `Audit::Restore.resolve_target` + `Audit::Rollback.call` | Restore a deleted document (empty body) |
| `GET` / `QUERY` | `/Api/:domain/:doctype/:id/:child/:child_id/history` | `Audit::List.call` scoped | Child document mutation history. `:child` is the relationship name from the parent definition's `children` map — the child-doctype-name shape and an unknown segment answer `404` |
| `POST` | `/Api/:domain/:doctype/:id/:child/:child_id/rollback` | `Audit::Rollback.call` scoped | Rollback child document (body: `{"mutation_id": "..."}`) |

The QUERY forms take the list parameters from a JSON body only — query-string parameters answer `422`. See [`http-layer.md`](http-layer.md) → QUERY method (RFC 10008).

### GET query admission (strict)

The GET list forms admit only the list-parameter grammar (`page`, `items`, `sort`, the `filters[field__op]=value` bracket form, and the other list keys — see [`http-layer.md`](http-layer.md) → ListRequest). An unknown query key answers `422 Unknown parameter '<key>'` (B-279): the bare-key shapes (`?doc_type=Invoice`, `?limit=2`) are not part of the grammar and never filter silently. Filters ride the bracket form or the QUERY body.

Each GET route names the one key it reads beyond the grammar, and the strict scan admits it:

| Route | Admitted extra key | Purpose |
|---|---|---|
| `/Api/:domain/:doctype/:id/history` | `include` | Aggregate mode (`include=children`) |
| `/Api/Audit`, `/:id/:child/:child_id/history` | — | No keys beyond the grammar |
| `/Api/core/Webhook/:id/calls` | `status` | Delivery-status filter (see `doc/backend/webhook.md`) |

The global audit list (`/Api/Audit`) reads only a subset of the grammar — `page`, `items`, `sort`, and the `filters` bracket form. It forwards exactly those to `Audit::List`, so the other grammar keys (`field`, `select`, `aggregate`, `scope`, `deleted`) answer `422 Unknown parameter '<key>'` instead of vanishing into an unfiltered `200` (F07-03): the audit log has no `select` projection, no field aggregate, and no named scope, so admitting the keys would be a silent drop. The document-history and child-history routes read the whole grammar and admit it all.

The QUERY forms parse the body strictly under the same admitted set. A route that reads a key beyond the grammar names it as an extra body key — `include` on the history routes, `status` on the webhook-calls route — and an unknown body key answers the same `422`.

### Mutation-id shape (422)

A mutation id must be a ULID: 26 characters of Crockford base32 (`0-9`, `A-Z` without `I`, `L`, `O`, `U`), uppercase. The route layer checks the shape before the service runs. A malformed id answers `422` `{"error": "mutation_id must be a ULID"}` and never reaches `Audit::Rollback`.

All four write handlers run the check: global rollback (path id), document rollback (body `mutation_id`), child rollback (body `mutation_id`), and restore (the internally resolved target — a defensive check; the database owns that id). A body `mutation_id` that is not a string answers the same `422`. Well-formed but unknown ids keep the service answer — a `404` whose body names the retention window in force, so a compacted-away target, a coalesced fold, and a never-existed id share one status while the caller still gets the context to self-serve:

```
Mutation 01ABC… not found. It may be unknown, older than the retention window (30 days for fin.Invoice), or folded by coalescing.
```

The window resolves the same way compaction resolves it (`Mutation::Retention`): the runtime pin on `core.SystemSettings` wins over the file value, and the per-doctype override applies when the route knows the doctype (document rollback, child rollback, restore). The global audit rollback names the base window — it does not know the target's doctype. When the window is `0` (keep forever), the window clause drops: age cannot be the reason.

### Route ordering

Audit routes are registered **before** the catch-all `/*rest` routes in `server.cr`. This prevents `history`, `rollback`, and `restore` from being consumed as child relationship names or action names.

A path deeper than the registered audit routes (for example `POST /Api/Audit/<id>/rollback/<extra>`) matches no audit route. The REST catch-all must not read `Audit` as a document domain: `RestRoutes::VIRTUAL_NAMESPACES` lists the first segments that host no doctypes (`Audit`, `Indexes`, `Artifacts`, `SystemSettings`, `openapi.json`), and the catch-all answers `404` `{"error": "Not found"}` for them — the same body `DomainGate` uses for reserved segments. `iam`, `search`, and `assistant` stay outside the list: real documents live (or may live) under them, and their nested children keep the catch-all service.

### Response shapes

All audit list endpoints (`GET /Api/Audit`, `GET /Api/:domain/:doctype/:id/history`,
`GET /Api/:domain/:doctype/:id/:child/:child_id/history`) share the same
response shape as document lists: `data` is the array of mutation records, and
`meta` carries the capped count and the `more` flag. The count subquery reads
`COUNT_CAP + 1` rows from the page offset, so `count` is the real number of
matching mutations from that offset, truncated at 1000, and `more` is `true`
only when counting was truncated — see
[`http-layer.md`](http-layer.md) → Pagination (count/more). With
`include=children`, one COUNT covers the parent branch and every child branch,
so the total counts each row once. Each row carries `display_name` — the
target document's label; plain mode returns `null`.

**GET /Api/Audit** (200):
```json
{
  "data": [
    {
      "id": "01ABCD...",
      "domain": "hr",
      "doc_type": "Employee",
      "doc_id": "hr.Employee.abc123",
      "idx": 1,
      "action": "create",
      "actioner_id": "account-1",
      "arguments": { "content": { "name": "Alice" } },
      "channel": "session",
      "app": null,
      "api_key": null,
      "acting_role": null,
      "cause_kind": "request",
      "cause_name": null,
      "cause_event": null,
      "cause_source": null,
      "cause_parent": null,
      "cause_trace": "01ABCD...",
      "emitted_at": "2025-01-01T00:00:00Z",
      "display_name": null
    }
  ],
  "meta": { "count": 42, "more": false }
}
```

**POST /Api/Audit/:mutation_id/rollback** (200):
```json
{
  "data": { "name": "Alice" },
  "meta": {
    "id": "01HRR...",
    "uri": "urn:facet:hr:Employee:01HRR...",
    "mid": "01XYZ...",
    "domain": "hr",
    "doc_type": "Employee",
    "version": 1,
    "schema_version": 1,
    "display_name": "Alice",
    "created_at": "2025-01-01T00:00:00Z",
    "updated_at": "2025-01-01T00:00:00Z"
  },
  "cascade_restored": []
}
```

A document-scope rollback or restore adds one top-level key to this body: `cascade_restored` lists every composition child the restore brought back — one `{domain, doc_type, doc_id, mut_id}` entry per child, always present, `[]` for a plain rollback.

**POST /Api/:domain/:doctype/:id/restore** — same success shape and status (`200`) as the rollback endpoints, with an empty request body (the target is the URL document). Failures: `404` (document not found / no history), `409` (document is not deleted — a safe no-op, the caller should refresh instead of retrying), `403` (caller may not `update` the document), `422` (no restorable target mutation). Resolve and rollback run inside one transaction, so concurrent restores of the same tombstone serialize: the second caller finds a live document and gets `409`.
