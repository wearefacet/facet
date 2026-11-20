# Sidecar Doctypes

A sidecar doctype is a document type that attaches to another document
through a `reference`-typed field, not through the `parent_id` composition
tree. The sidecar doctype lives in the `core` domain and is flagged
`sidecar: true` on its `DoctypeDefinition`. A host doctype declares a
`sidecars` map that names each sidecar relationship and points it at a
qualified sidecar doctype plus a reference column on it.

The canonical sidecar is `core.Comment`: comments attach to any document
(a contact, an employee, an account) through their `target` reference
field, and they are created through the host's nested route rather than
through the flat `POST /Api/core/Comment` route.

The sidecar contract is:

- **Cross-domain attachment.** The sidecar's home domain (`core`) and the
  host's home domain (`hr`, `crm`, `iam`, …) differ. A sidecar record's
  `target` stores a fully-qualified reference value
  `{host_domain}.{host_doctype}.{host_id}`.
- **Flat-create block.** A flat create of a sidecar doctype is rejected
  with 422 — sidecar records are created through the host's nested route,
  which sets `target` from the path. The block lives twice:
  `Document::Routes.nested_create_guard` pre-checks the REST flat route
  (before multipart uploads run), and `Document::Create` re-checks after
  the definition fetch so every other flat path (agent tools, compound
  creates) reports the route hint instead of the missing-`target` schema
  error. The agent surfaces reach the nested route through the
  `create_sidecar` / `list_sidecars` tools (see
  [`agent-tools.md`](agent-tools.md)).
- **Two-gate authorization.** A nested sidecar operation checks read
  permission on the host record — no read grant on the host doctype at
  all answers 403; a missing host, or one a grant holder cannot see,
  answers the non-disclosing 404 — PLUS a nested sidecar grant on the
  host-scoped path (`create hr.Employee.Comment`), whose denial answers
  403.
  The path is prefix-matched, so a host permission implies the nested
  grant for the same action. Flat grants on the sidecar doctype
  (`core.Comment`) serve the flat endpoint only and do not participate.
- **Author-ownership anchor, not composition.** A sidecar record carries
  its own ownership anchor (for `core.Comment`, the `author` field is
  forced by the Lua `create` hook from the caller's identity). The
  composition cascade in `Document::Delete` does NOT touch sidecar
  records — orphan handling is a separate subsystem
  (`Event::Subscriber::SidecarSweep` + `Cron::SidecarReconcile`).

Concern source files: `src/doctype/sidecar_ref.cr`,
`src/document/sidecar_handler.cr`, `src/document/routes.cr` (flat-create
block), `src/document/create.cr` and `src/document/list.cr`
(`skip_authorization` flag), `src/rbac/write_enforcer.cr`
(`authorize_sidecar_create`), `src/rbac/read_enforcer.cr`
(`sidecar_authorized?`), `src/agent_tools/sidecar.cr` (the host-scoped
MCP tools — `create_sidecar` / `list_sidecars`, see
[`agent-tools.md`](agent-tools.md)),
`src/event/subscriber/sidecar_sweep.cr`, `src/cron/sidecar_reconcile.cr`,
`src/config.cr` (`SidecarConfig`).
Seed data: `data/seeds/core.Comment/` and `data/seeds/core.Attachment/`
(definition + Lua script each), `data/seeds/iam.Roles/` (`comment_author`
and `attachment_owner` production roles).

## Definition shape

A sidecar doctype's `DoctypeDefinition` sets:

| field       | type                              | meaning                                                                                                                                       |
| ----------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `sidecar`   | `Bool = false`                    | `true` on a sidecar doctype. Triggers publish-time validation (`core` domain, `target` reference field, required + read_only, no default).    |
| `sidecars`  | `Hash(String, SidecarRef) = {}`    | Declared on a HOST doctype. Keys are route segment names (`"comments"`); values name the qualified sidecar doctype + reference column on it. |
| `surface`   | `String?`                         | Optional custom-surface id on a sidecar doctype (e.g. `"comment"`). Presentation belongs to the type: one declaration serves every host. The frontend resolves the id through its surface registry; an absent or unknown id falls back to the basic DVT surface. Validated as a lowercase identifier and only meaningful with `sidecar: true`. |

A doctype is one of: a sidecar (`sidecar: true`, empty `sidecars` map), a
host (`sidecars` map present), or neither. A sidecar itself never hosts
another sidecar.

### `SidecarRef`

`struct SidecarRef` (`src/doctype/sidecar_ref.cr`) — one entry in a host
doctype's `sidecars` map.

| field     | type   | meaning                                                                |
| --------- | ------ | ---------------------------------------------------------------------- |
| `doctype` | `String` | Qualified sidecar doctype id (e.g. `"core.Comment"`). Must contain a dot — verified by `from_json`. (A `children` entry, by contrast, names a bare same-domain CamelCase doctype — the two maps demand opposite forms.) |
| `column`  | `String` | Reference field on the sidecar that points back at the host. Defaults to `"target"`. |
| `order`   | `Int32 = 0` | Optional author-controlled tab order. PostgreSQL `jsonb` re-orders object keys, so declaration order cannot decide tab order — hosts that care sort by `{order, segment name}`; the default `0` collapses to the stable alphabetical default. Not emitted on the wire when `0`. |
| `label`   | `String?` | Optional host-owned tab label override (e.g. `"Notes"`). When absent the frontend falls back to the humanized segment name. It lives on the host ref, not on the sidecar doctype: sidecar doctypes are forced into `core`, so a domain author could not reword a shared system-owned definition. Not emitted on the wire when absent. |

```crystal
SidecarRef.from_json(raw : JSON::Any) : SidecarRef
SidecarRef#to_json(builder : JSON::Builder) : Nil
SidecarRef.new(doctype : String, column : String = "target", order : Int32 = 0, label : String? = nil)
SidecarRef#sort_key(segment : String) : {Int32, String}  # tab-order key {order, segment}
```

### Publish-time validation (`Doctype::Validation`)

`validate_sidecar` runs on every sidecar doctype and rejects:

- a sidecar doctype that does not live in the `core` domain;
- a sidecar doctype without a `target` field;
- a `target` field that is not of type `reference`;
- a `target` field that is not `required`, not `read_only`, or has a
  `default` (only the system sets `target`, through the nested route).

`validate_sidecar_surface` rejects a `surface` value that is not a
lowercase identifier, or a `surface` declared on a doctype that is not
`sidecar: true`. A surface id the frontend does not register is never a
hard gate — the frontend falls back to the basic DVT surface.

`validate_sidecars_keys` runs on every host doctype and rejects a
`sidecars` entry whose segment name is not a valid lower-case identifier,
that collides with a `children` relationship of the same name, or whose
`column` is empty.

### Cross-doctype diagnostics (`Doctype::Check`)

The `/Api/core/DocType/:id/check` endpoint runs `check_sidecars` for each
host doctype. Broken configurations surface as `:warning` issues of
category `:sidecar` (NOT hard gates — runtime silently skips a broken
sidecar entry):

- the sidecar doctype is not registered;
- the sidecar doctype is not flagged `sidecar: true`;
- the sidecar doctype has no reference field named by the entry's `column`.

## core.Comment thread fields

`core.Comment` carries two thread-related fields beyond `target` / `author`
/ `body`, both enforced by the doctype's Lua hooks:

| field       | type       | contract                                                                                                                                                                                |
| ----------- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `reply_to`  | `reference` → `core.Comment` | Optional. Settable only at create time; the Lua `update` hook rejects any change or clear afterwards. Must reference a **live comment attached to the same `target`** — threads nest to any depth but can never cross host documents. Existence of the referenced comment is gated by the standard reference existence check; the hook adds the same-target rule. A deleted parent leaves its live replies in place; the list endpoint hides the tombstone, so the comment surface renders a `<deleted>` placeholder in its place and nests the replies under it. |
| `edited_at` | `datetime`, `read_only` | Never supplied by callers. The Lua `update` hook stamps it with `ctx.now` when a patch actually changes `body`; a patch that resubmits the same body stays a no-op. |

```json
POST /Api/hr/Employee/01HQ.../comments
{"body": "good catch", "reply_to": "01HQ...parent_ulid"}
```

A bare ULID is accepted and normalized to the qualified `core.Comment.<id>`
form by the reference normalize pass before the hook runs. The referenced
comment may itself be a reply — threads nest to any depth; the comment
surface caps the rendered indent and marks deeper replies with a
"replying to @author" note.

## Routes

### Flat routes (read / update / delete only)

The flat routes under `/Api/core/Comment` are open for read, update, and
delete — a sidecar record is a normal document outside the create path.
`POST /Api/:domain/:doctype` is blocked for sidecar doctypes by
`Document::Routes.nested_create_guard`, which returns 422 before
`Document::Create` runs:

```
Sidecar doctypes cannot be created through the flat route; use the nested route on the host document
```

Flat-route RBAC on a sidecar doctype uses the normal enforcer path
(`ReadEnforcer.list_where_clauses` / `WriteEnforcer.authorize_update` /
`authorize_delete`) against the sidecar's own domain and doctype
(`core.Comment`). The seeded `comment_author` role grants `$mine`-scoped
read/update/delete on `core.Comment` for this purpose.

### Nested routes

The host doctype's nested routes serve the sidecar collection. Dispatch
lives in `RestRoutes` (`src/http/rest_routes.cr`):

| route                                                 | method | behaviour                                                                                                                                |
| ----------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `/Api/:domain/:doctype/:id/:segment`                  | `POST` | If `:segment` is a key in the host's `sidecars` map → `SidecarHandler.create`. Otherwise → child create or named action. |
| `/Api/:domain/:doctype/:id/:segment`                  | `GET`  | If `:segment` is a sidecar key (single-segment path only) → `SidecarHandler.list`. Otherwise → child list / read.       |
| `/Api/:domain/:doctype/:id/:segment/:sidecar_id`                  | `GET`  | If `:segment` is a sidecar key → `SidecarHandler.read` (single-document ETag path). Otherwise → child read.             |
| `/Api/:domain/:doctype/:id/:segment/:sidecar_id`                  | `PATCH`  | If `:segment` is a sidecar key → `SidecarHandler.update`. Otherwise → child update.             |
| `/Api/:domain/:doctype/:id/:segment/:sidecar_id`                  | `DELETE`  | If `:segment` is a sidecar key → `SidecarHandler.delete`. Otherwise → child delete.             |

Sidecar dispatch is checked BEFORE the child resolver — the per-document
GET dispatch runs before the parent resolver (a 2-segment sidecar path is
not a child walk), and the PATCH/DELETE dispatch runs before
`resolve_child_for_write`. A segment cannot be both a sidecar and a child
(publish-time validation rejects the collision), so the dispatch order is
unambiguous. Deeper than two segments never dispatches to a sidecar — a
sidecar never hosts anything.

**Content type (B-113).** The nested write routes (POST and PATCH) accept
`application/json` only. The gate sits before any body parse:
`multipart/form-data` answers `415` and names the documented intake (the
standalone upload at `POST /Api/core/artifacts`, then a JSON sidecar
create); any other declared non-JSON type answers `415`; a malformed body
under a JSON type answers `400` at the earliest parse point. A wrong
content type is a caller error, never a 5xx. A body with no `Content-Type`
header keeps the flat routes' tolerance: the body itself must parse.
Read routes (GET) take no body and stay ungated.

### `Document::SidecarHandler`

`SidecarHandler.create`, `list`, `read`, `update`, and `delete`
(`src/document/sidecar_handler.cr`) implement the nested sidecar routes. All
run the authorization contract below; the collection operations populate
the sidecar's `target` reference filter from the path, the create sets
`target` from the path; every one delegates to the matching
`Document::*` service with `skip_authorization: true`.

| method     | signature (abridged)                                                                                                                                                                                                                                                                       | returns                                       |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| `create`   | `create(db, host_domain, host_doctype, host_id, segment, body : JSON::Any, auth_ctx) : Result \| ServiceError`                                                                                                                                                                            | creates one sidecar record, `404`/`400`/`422`/`403` on failure        |
| `list`     | `list(db, host_domain, host_doctype, host_id, segment, auth_ctx) : Result \| ServiceError`                                                                                                                                                                                                | lists the host's sidecars, `403`/`404` on failure         |
| `read`     | `read(db, host_domain, host_doctype, host_id, segment, sidecar_id, auth_ctx) : Document::Read::Result \| ServiceError`                                                                                                                                                                    | reads one sidecar record, `403` on a grant denial, non-disclosing `404` on a missing or invisible host |
| `update`   | `update(db, host_domain, host_doctype, host_id, segment, sidecar_id, body : String, auth_ctx) : Document::Update::Result \| ServiceError`                                                                                                                                                 | updates one sidecar record, `403` on a grant denial, `404` on a missing or invisible host |
| `delete`   | `delete(db, host_domain, host_doctype, host_id, segment, sidecar_id, auth_ctx) : Document::Delete::Result \| ServiceError`                                                                                                                                                                | tombstones one sidecar record, same gates as `update` |

`create` rejects a `target` key supplied in the request body with 400
(`target` is set by the route); it then sets `target` to
`{host_domain}.{host_doctype}.{host_id}` and calls
`Document::Create.call(..., allow_system_writes: true, skip_authorization: true)`.

After the host read gate, `create` locks the host projection row
`FOR UPDATE` and requires it to be live — it exists and is not
soft-deleted (`RowAccess.lock_live_projection_for_update`, B-344). A
missing or tombstoned host answers the non-disclosing 404 for every
principal: `parent_authorized?` returns true immediately for the system
bypass, so the handler carries the existence check itself. The row lock
holds to the end of the transaction, so a concurrent host delete cannot
commit between the gate and the create.

## Authorization

### Two-gate contract

A nested sidecar create or list runs two authorization gates in order:

1. **Host read gate.** The class check runs first
   (`ReadEnforcer.read_denied?`): a caller that holds no read permission
   on the host doctype at all answers 403. `ReadEnforcer.parent_authorized?`
   then checks the caller can read the host record: a missing host, or
   one a grant holder cannot see, answers the non-disclosing 404 — the
   handler does NOT distinguish the two. The
   system bypass answers true with no row check; the handler-level host
   lock below supplies the existence check for every principal.
2. **Nested sidecar grant gate.** A permission for the action on the
   host-scoped path (`create hr.Employee.Comment` /
   `read hr.Employee.Comment`). The path is prefix-matched, so a host
   permission implies the nested grant for the same action (`read
   hr.Employee` ⇒ `read hr.Employee.Comment`; `create hr.Employee` ⇒
   `create hr.Employee.Comment`). A scoped nested match authorises the
   action — the host read gate already restricts to reachable host
   records.

Flat grants on the sidecar doctype (`create core.Comment`) do NOT
authorise the nested routes — they serve the flat endpoint only.

Failure on gate 2 returns 403 for every action — create, read, list,
update, and delete. The nested sidecar grant is a class-level grant: a
caller that holds none is denied the resource class, and the answer
matches the sidecar write gates.

### `WriteEnforcer.authorize_sidecar_create` / `_update` / `_delete`

```crystal
def self.authorize_sidecar_create(
  db : DB::Connection,
  host_domain : String,
  host_doctype : String,
  sidecar_domain : String,
  sidecar_doctype : String,
  auth_context : AuthContext,
) : Bool
```

System context bypasses. App grants are checked first through
`app_grant_permits?` (Layer-1 ceiling), then `can?` resolves the named
permission against the host-scoped nested path. The nested path is
constructed as `[host_doctype, sidecar_doctype]` against the host's
`domain` and is prefix-matched, so a host `create` grant implies the
nested grant. `authorize_sidecar_update` and `authorize_sidecar_delete`
are the same contract against the `update` / `delete` action names —
each write action checks its own action name. All three delegate to the
shared `RBAC::EnforcerSupport.sidecar_action_authorized?` — only the
action string differs.

### `ReadEnforcer.sidecar_authorized?`

```crystal
def self.sidecar_authorized?(
  db : DB::Connection,
  host_domain : String,
  host_doctype : String,
  sidecar_domain : String,
  sidecar_doctype : String,
  auth_context : AuthContext,
) : Bool
```

Mirrors `authorize_sidecar_create` for the read path, against the same
prefix-matched nested path. Scopes are NOT evaluated here — the
row-level filter (only sidecar records whose `target` points at a host
the caller can read) is enforced by the handler's `target` reference
filter plus the host read gate that already ran.

### `skip_authorization` flag

`Document::Create.call`, `Document::List.call`, `Document::Read.call`,
`Document::Update.call`, and `Document::Delete.call` all accept a
`skip_authorization : Bool = false` kwarg (threaded through
`create_document` → `create_from_parsed` on the create path, through
`build_where_clause` on the list path, and through the `authorize_read`
/ `authorize_update` step-0 gate helpers on the read / update / delete
paths). When `true`, the service-layer flat gate is skipped:

- `Document::Create.create_from_parsed` skips the step-0
  `WriteEnforcer.authorize_create` call.
- `Document::List.build_where_clause` skips the
  `ReadEnforcer.list_where_clauses` scope clause injection (so an
  unsatisfiable `1=0` clause does not collapse a nested-grant-only
  caller's result set).
- `Document::Read` / `Document::Update` / `Document::Delete` skip their
  step-0 enforcer call via the `authorize_read` / `authorize_update`
  private helpers.

`SidecarHandler` sets `skip_authorization: true` on every call. Two
internal writers set it too: `Domain::Editors` and `App::Deploy`, both
through `Document::Create.create_from_parsed`. Field-level
read masking (`visible_tags`) is NOT skipped — it still applies to sidecar
reads through the service layer.

### Grant grammar

| grant shape                | example `on` value       | use                                                                                                  |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| flat sidecar grant         | `core.Comment`           | serves the flat route's read/update/delete path only. Does NOT authorise the nested route.            |
| nested sidecar grant       | `hr.Employee.Comment`    | authorises the nested route. Implied by a host grant on `hr.Employee` for the same action. Use an explicit line to let a read-only host role comment (`read hr.Employee` + `create hr.Employee.Comment`). |
| `$mine`-scoped flat grant  | `core.Comment` + `scope: ["$mine"]` | author on the sidecar doctype drives ownership-scoped read/update/delete on the flat route (the seeded `comment_author` role). |

`Permission#matches_path?` is prefix-based: a `read hr.Employee` grant
prefix-matches `hr.Employee.Comment`, so a caller who can read the host
inherently holds the nested sidecar read at the route gate, and a caller
who can create the host inherently holds the nested sidecar create. An
explicit nested line adds the action the host grants do not carry — a
read-only role with `create hr.Employee.Comment` may comment on hosts it
can read.

## Orphan handling

A sidecar record is NOT a composition child of its host. The
`Document::Delete` composition cascade tombstones owned children
(`parent_id` tree) but leaves sidecar records intact. Two subsystems
tombstone sidecar records whose host is gone:

1. **Event-driven sweep** — `Event::Subscriber::SidecarSweep` tombstones
   sidecar records the moment a host document is soft-deleted through the
   normal `Document::Delete` path.
2. **Periodic reconcile** — `Cron::SidecarReconcile` is the backstop: it
   catches the orphans the sweep misses (a lost `deleted` event, a host
   row hard-deleted by a maintenance script, a referential race between
   the host read gate and the sidecar create commit).

Both delete sidecar records through `Document::Delete.call` with
`auth_context: AuthContext.system` (system bypasses all RBAC) and an
`actioner_id` of `system:sidecar-sweep` or `system:sidecar-reconcile` for
audit attribution.

### `Event::Subscriber::SidecarSweep`

`src/event/subscriber/sidecar_sweep.cr` — two parts:

| part      | class                            | role                                                                                                                                                                                            |
| --------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Handler` | `SidecarSweep::Handler`          | Per-message logic. Resolves the deleted host identity from the event headers (`domain` + `doc_type`) and payload (`content["id"]`), loads the host doctype's `sidecars` map, and tombstones every attached sidecar record through `Document::Delete.call`. Testable directly with a synthetic `Event::Message` (mirrors the `Replication::Handler` / `Replication::Manager` split). |
| `Manager` | `SidecarSweep::Manager`         | Owns its own `Event::Manager` instance (`consumer_group_prefix: "cg:sidecar:"`) so the sweep consumer group is isolated from the general-purpose and replication consumers on the same host-doctype streams. Subscribes to the `deleted` event on every host doctype that declares a `sidecars` map. |

The host-doctype set is rebuilt lazily. `Manager` installs a
`channel_provider` that re-queries the host set on every stream poll, so
a doctype create/update that adds or removes a `sidecars` entry is
picked up on the next polling turn — no restart, no separate invalidation
wiring. This mirrors `Replication::Manager`'s source-doctype set
approach and does NOT introduce a `DoctypeCache`-style cache (the set is
queried per poll).

`Handler#call` is idempotent: a redelivered `deleted` event re-runs the
sweep, finds the sidecar already tombstoned, and `Document::Delete`
returns 410 Gone — treated as success (the desired end state has already
been reached). The tombstone deletes the sweep emits are attributed to
`system:sidecar-sweep`; they enqueue `deleted` events on the sidecar
doctype streams, which the handler flushes with `Event::Publisher.flush`
at the end of each call (the sweep runs outside the HTTP layer, which is
where the post-request `Publisher.flush` normally runs).

### `Cron::SidecarReconcile`

`src/cron/sidecar_reconcile.cr` — `class Cron::SidecarReconcile`,
invoked as `Cron::SidecarReconcile.call` (class method).

Algorithm per pass:

1. Fetch every `core.DocType` projection whose definition carries
   `sidecar: true`.
2. For each sidecar doctype, read its live records' `target` reference
   values.
3. Parse each target on the FIRST TWO dots only into
   `(host_domain, host_doctype, host_id)` — the id segment may itself
   contain a dot (see the qualified reference storage contract).
4. Group host ids by `(host_domain, host_doctype)` and batch-check host
   existence in chunks of `BATCH_SIZE = 1000`:
   `SELECT id FROM projections WHERE domain = $1 AND doc_type = $2 AND id = ANY($3) AND deleted_at IS NULL`.
5. For each missing host id, soft-delete the sidecar records whose
   `target` equals the orphaned qualified host id, via
   `Document::Delete.call` with `auth_context: AuthContext.system` and
   `actioner_id: "system:sidecar-reconcile"`.

Each orphan is tombstoned in its own transaction so a failure on one
does not roll back the others. `Cron::Scheduler`'s per-task fault
isolation logs and reschedules on a raised exception; the per-batch
transactions mean a rerun resumes where the failed run left off
(already-tombstoned sidecars return 410 and are treated as no-ops). The
handler flushes enqueued `deleted` events at the end of
`tombstone_orphans` so the tombstone events land on the stream outside
the HTTP layer.

### Runtime wiring (`main.cr` — `server` command)

1. Construct `Event::Subscriber::SidecarSweep::Manager` with the event
   config and a `service_id` of
   `Facet::Service.service_id("facet-sidecar-sweep")`
   (`facet-sidecar-sweep-<env>-<boot ULID>`).
2. `start(db)` — register subscriptions, install the channel provider,
   start the event manager.
3. Register the cron task `"sidecar.reconcile"` with the cron scheduler
   at the configured schedule
   (`Facet::Config.instance.sidecar.reconcile_cron`, default
   `0 */1 * * *` — every hour at minute 0).
4. `at_exit` handler stops the sweep manager alongside the other
   managers.

## Config

`SidecarConfig` record on `Facet::Config` (`src/config.cr`):

| field             | default            | meaning                                                                                                                               |
| ----------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `reconcile_cron`  | `"0 */1 * * *"`    | Cron expression for the orphan-reconcile task. Validated lazily by `Cron::Parser` when the task is registered with the scheduler.    |

The `sidecar:` section in `config.{env}.yml` is optional; only
`reconcile_cron` is consumed.

```yaml
sidecar:
  reconcile_cron: "0 */1 * * *"
```

## Example — `POST /Api/hr/Employee/:id/comments`

A caller creates a comment on `hr.Employee#01HQ...`:

```
POST /Api/hr/Employee/01HQ.../comments
Content-Type: application/json

{"body": "Welcome aboard"}
```

1. `RestRoutes.rest_post` dispatches the single-segment path to
   `SidecarHandler.create` (because `"comments"` is a key in
   `hr.Employee`'s `sidecars` map).
2. `SidecarHandler.create` loads the host `hr.Employee` definition,
   resolves the `SidecarRef` for `"comments"`, and:
   - Gate 1: the host read gate. A caller with no read grant on the host
     doctype returns `403 Forbidden` (`ReadEnforcer.read_denied?`); a
     missing host, or one a grant holder cannot see, returns
     `404 Not found` (`ReadEnforcer.parent_authorized?(db, "hr",
     "Employee", "01HQ...", ctx)`).
   - Gate 2: `WriteEnforcer.authorize_sidecar_create(db, "hr", "Employee", "core", "Comment", ctx)`.
     A denial returns `403 Forbidden`.
3. The handler rejects a `target` key in the body (400), sets
   `target = "hr.Employee.01HQ..."` on the body, and calls
   `Document::Create.call(db, "core", "Comment", body, ctx, allow_system_writes: true, skip_authorization: true)`.
   The `core.Comment` Lua `create` hook forces `author = ctx.actor.id`
   from the caller's identity.
4. The created sidecar record events through the normal mutation /
   projection trigger / `Event::Publisher.enqueue` path.

The collection `GET` route (`GET /Api/hr/Employee/01HQ.../comments`) runs
the same host read gate, then
`ReadEnforcer.sidecar_authorized?(...)`, then
`Document::List.call(db, "core", "Comment", filters: {"target__eq" => "hr.Employee.01HQ..."}, ..., skip_authorization: true)`.
The handler returns up to 1000 results per call.

The per-document operations follow the same gates against the same
host-scoped path (`GET/PATCH/DELETE /Api/hr/Employee/01HQ.../comments/:comment_id`):
every operation surfaces a class-level denial — no read grant on the
host doctype, or no nested grant on the host-scoped path — as `403`, and
a missing host, or one a grant holder cannot see, as the non-disclosing
`404` (matching the nested create contract), then delegates to
`Document::Read` / `Document::Update` / `Document::Delete` with
`skip_authorization: true`.

## Test infrastructure

| file                                          | coverage                                                                                                                                                                       |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `spec/doctype/doctype_definition_spec.cr`     | `SidecarRef.from_json` happy + missing-`doctype` + unqualified-`doctype` paths; `DoctypeDefinition` round-trips `sidecar` / `sidecars` / `order` / `label` / `surface` (absent keys not emitted on the wire).                                      |
| `spec/doctype/doctype_validation_service_spec.cr` | `validate_sidecar` rejects: non-`core` sidecar; missing `target`; non-reference `target`; non-required / non-`read_only` / defaulted `target`. `validate_sidecars_keys` rejects: bad segment names, collisions with `children`, empty `column`. `validate_sidecar_surface` rejects: non-lowercase-identifier `surface`; `surface` on a non-sidecar doctype. |
| `spec/doctype/check_spec.cr`                  | `check_sidecars` emits `:warning`/`:sidecar` issues for unregistered / un-flagged / missing-column sidecar refs.                                                              |
| `spec/rbac/sidecar_grant_spec.cr`             | `WriteEnforcer.authorize_sidecar_create` and `ReadEnforcer.sidecar_authorized?` — nested-grant allow, host-grant prefix allow, flat-grant denial, denial without a nested grant, system bypass.                              |
| `spec/http/server_spec.cr`                    | Flat routes: 422 on `POST /Api/core/Comment`, plus read / update / delete through the flat routes.                                                                             |
| `spec/agent_tools/sidecar_spec.cr`            | The host-scoped MCP tools — `create_sidecar` / `list_sidecars`: create + list happy paths, segment resolution (unknown segment → `InvalidParams` naming the declared segments), both gates, `core.Attachment` genericity, the flat-create hint on `create_document`. |
| `spec/http/sidecar_integration_spec.cr`       | Nested routes: create + list happy path, host read 404, no-sidecar-grant 403, flat-grant-only 403, `target`-in-body 400, cross-domain nested grant (no flat `core.Comment`), `$mine` ownership end-to-end. Per-document nested routes: read / update / delete happy paths, unknown sidecar id, non-sidecar segment, host-read 404 denial, nested-grant-only caller works nested and is denied on the flat route, flat moderation still works for admins. Thread rules: same-host reply create, cross-host reply 422, reply-to-reply 422, reply to deleted 422, `reply_to` change/clear 422; `edited_at` stamped on body change only, unset at create, no stamp on same-body PATCH or value-identical `reply_to` PATCH. |
| `spec/event/subscriber/sidecar_sweep_spec.cr` | Tombstone on host delete, idempotency on redelivery, no-op on live host, no-op on sidecar-less doctype, malformed-event skip.                                                  |
| `spec/cron/sidecar_reconcile_spec.cr`         | Hard-delete orphan, live-host untouched, soft-delete host backstop, idempotency, no-sidecar-doctype no-op, dotted-id-split contract.                                           |

The sweep and reconcile specs use the global `Event::InProcessManager`
installed in `spec_helper.cr` (synchronous dispatch, no Redis). The Cron
specs invoke `Cron::SidecarReconcile.call` directly rather than through
the scheduler.
