# Lua Engine

**Files:** `src/lua/engine.cr`, `src/lua/sandbox.cr`, `src/document/script_context.cr` (require root; concern lives in `script_context/`), `src/document/lua_document_helpers.cr`, `src/doctype/script_validator.cr`, `src/document/compute.cr`, `src/util/script_helpers.cr`

`Facet::Lua::Engine` is a thin Crystal wrapper around the `Lua::Stack` from the `lua.cr` shard.

## Module pattern

Doctype scripts follow a **module pattern** — they must return a Lua table of exported functions:

```lua
local export = {}

function export.create(ctx)
  -- lifecycle hook (optional)
end

function export.promote(ctx, args)
  -- named action (matched to doctype actions)
end

return export
```

### `ctx` table passed to every function

| Field | Type | Present in | Purpose |
|---|---|---|---|
| `ctx.root` | table | All | The document content (mutate in-place). On `update` this is the **merged** document — the current content with the patch already applied (see [`document.md`](document.md) → ctx table). |
| `ctx.patch` | table | Update | The partial PATCH body the caller submitted (post-normalize, pre-merge). Absent when the update path is not driven by a PATCH. |
| `ctx.action` | string | Action | The named action this run executes (`"approve"`). Present for `validate`, the action function, and `update`; absent on PATCH — scripts branch with `ctx.action ~= nil`. |
| `ctx.changed` | table | Update (action-driven) | Array of field names the action mutated, published right before `export.update` runs. Absent on PATCH — read `ctx.patch` there. |
| `ctx.error(msg)` | function | All | Collects a validation error message |
| `ctx.actor_id` | string | All | The actioner/account ID |
| `ctx.now` | string | All | ISO 8601 timestamp |
| `ctx.doc_id` | string | Update, Delete, Action, Compute (not the create pass) | The current document's ULID — the id of the document the script mutates or computes for. Absent on the compute create pass: the id is generated at persist time, and the parent recompute pass re-runs relationship-named fields with the id set. |
| `ctx.get_children(name)` | function | Create, Update, Delete, Action (when DB is available) | Lists child documents by relationship name. Returns an array of child document ID strings. Internally resolves the relation via the doctype's `children` definition and filters by `parent_id`. |
| `ctx.children` | table | Compute (when a to-run field's `compute_when` names a relationship) | Live child rows per relationship — see [ctx.children](#ctxchildren). |
| `ctx.actor` | table | Create, Update, Delete, Action (when an `auth_context` is supplied) | Read-only RBAC surface for the caller. Lets a lifecycle hook / action enforce row-content rules RBAC cannot express (e.g. force `author_id`). See [ctx.actor](#ctxactor). |

A state guard in the `update` hook must key on `ctx.patch` **or**
`ctx.changed` — a PATCH-driven update carries only `ctx.patch`, an
action-driven update carries only `ctx.changed`. See
[`document.md`](document.md) → State guards that bind both update paths for
a worked example.

### `ctx.actor`

Available in `ScriptContext::Create`, `Update`, `Delete`, and `Action`
when an `RBAC::AuthContext` is threaded through the document service (the
production path always does). Transient (`Migrate`) and unit-test contexts
that omit it leave `ctx.actor` as `nil` — scripts should guard with
`if ctx.actor == nil then return end`.

The `scope` alias reflects the permission that authorized **this hook's own
action** — `create` for the create hook, `update` for update, `delete` for
delete, and the named action for an action hook. Each action checks its own
permission line; delete does NOT reuse the `update` permission.

The table exposes the caller's identity, role, and the create-permission's
scope alias, plus the resolved context sets for the caller's domain:

| Field | Type | Present when | Description |
|---|---|---|---|
| `ctx.actor.system` | boolean | always | `true` for the system bypass principal (seeding, migrations, internal callers); `false` for a real authenticated principal |
| `ctx.actor.id` | string | always | The caller's account ID (same value as `ctx.actor_id`) |
| `ctx.actor.role_id` | string | real principal only | The active role's ID |
| `ctx.actor.visible_tags` | array of strings | real principal only | The role's visible field tags |
| `ctx.actor.app_id` | string | app-scoped principal only | The `app.App` projection id when the caller is app-scoped (a service account acting for an app, through an app-owned API key or an OAuth app token). Absent for session callers. Lets a script branch on "this caller is an app, not a human" — e.g. the `app.App` update hook's self-grant guard. |
| `ctx.actor.scope` | string or nil | real principal, when `domain`/`doc_type` are set | The bare named-scope alias on the matching permission for this hook's own action (e.g. `"mine"`), or `nil` for an unrestricted (`$all`/absent scope) permission. Create→`create` perm, update→`update`, delete→`delete`, action→named action. |
| `ctx.actor.scopes` | array of strings | real principal, when at least one scoped permission for this action matches | The union of scope aliases across all matching permissions for this hook's action (intra-role OR). Absent when unrestricted. |
| `ctx.actor.context_sets` | table of `name -> array(string)` | real principal, when a DB and domain are available and the domain declares context sets | The materialized dynamic value sets for the caller (e.g. `{ my_teams = { "team_1", "team_2" } }`). Absent on resolution failure or when the domain has no context sets. |

`ctx.actor.scope` is the **alias as declared on the permission** for this
hook's own action, not the expanded `where` predicate. On create the row does
not exist yet, so RBAC treats any scoped `create` permission as authorized
and leaves row-content enforcement to this hook. On update/delete/action the
named scope's `where` is already enforced by the `WriteEnforcer` against the
existing document; exposing the alias here lets the script branch on "which
scope am I operating under" without re-querying. The expanded `where` map is
not exposed.

Example — force `owner_id` to the caller when the create permission is scoped
`$mine` (see `data/fixtures/production.Project/script.lua` for a live fixture):

```lua
local export = {}

function export.create(ctx)
  if ctx.actor == nil then return end
  if ctx.actor.scope == "mine" and ctx.actor.system == false then
    ctx.root.owner_id = ctx.actor.id
  end
end

return export
```

The `$mine` scope (`owner_id: '$self'`) matches the bare account id this
recipe stores **and** the qualified `iam.Account.<id>` form a
reference-typed `owner_id` field stores — either field type works (see
[`rbac.md`](rbac.md#named-scopes)).

### Action signatures

| Context | Lua function signature | When called |
|---|---|---|
| `ScriptContext::Create` | `export.create(ctx)` | On document creation — can validate and mutate `ctx.root` |
| `ScriptContext::Update` | `export.update(ctx)` | On document update — can validate and mutate `ctx.root`; `ctx.patch` exposes the partial PATCH body the caller submitted (see [`document.md`](document.md#ctx-table)) |
| `ScriptContext::Delete` | `export.delete(ctx)` | On document deletion — validate only |
| `ScriptContext::Action` | `export.{name}(ctx, args)`, then `export.update(ctx)` | On named action execution (`args` holds action parameters); afterwards `export.update(ctx)` runs against the final state (see [`document.md`](document.md#context-classes)) |
| `ScriptContext::Migrate` | `export.{func_name}(ctx)` | On lazy schema migration — runs a specific migration function; `ctx.args` is not available |

Lifecycle hooks (`create`, `update`, `delete`) are optional. If absent from the export table, no Lua code runs for that lifecycle event.

### Secrets and scripts

Scripts never see a secret value. For doctype `secret` fields the content a script reads and writes carries only the stage handle or the `{mode, version, set_at}` marker — the plaintext never enters a document body, so no script path can reach it. A script may pass a stage handle through to a secret field (e.g. from an argument of type `string`); the write pipeline's adoption step validates it like any other handle. A handle exfiltrated into a plain field is dead on arrival — adoption consumes the staging row, and the `created_by` binding blocks cross-account use. `secret` is not a valid action-argument type (rejected at definition time). See [`secrets.md`](secrets.md).

## ScriptValidator (`src/doctype/script_validator.cr`)

Validates at doctype registration time that:

1. The script compiles (no syntax errors)
2. The script returns a table (module pattern requirement)
3. Every action declared in `definition.actions` has a matching function key in the returned table
4. Every `type: data` field with a `compute` value has a matching `compute_{suffix}` function key in the returned table
5. Every `args.<name>` / `args["<name>"]` read inside an action's export function names an argument the action declares. A dynamic read (`args[var]`) escapes this static check.

## Engine lifecycle

- `Engine.new` — creates a new **sandboxed** Lua state. Only `base`, `string`, `math`, `table`, and `utf8` libraries are loaded.
- `Engine.open { \|e\| ... }` — yields a temporary engine and closes it automatically.
- `engine.close` / `engine.closed?` — explicit lifecycle management.

## `Lua::Sandbox` (`src/lua/sandbox.cr`)

`Lua::Sandbox` is the shared boot for script execution surfaces. It owns the setup steps every surface repeats: engine boot, the `util.*` / `date.*` / `math.clamp` globals, the `error(msg)` collector global, and the `document.*` / `notification.*` helper registration.

- `Sandbox.new` — boots one sandboxed `Lua::Engine` at construction (`sandbox.engine` exposes it).
- `register_util_globals!(json_helpers, db = nil)` — registers the `util.*`, `date.*`, and `math.clamp` globals. `json_helpers: true` adds `util.json_encode` / `util.json_decode` (the compute engine registers them, because `document.get` / `document.list` return `content` as a JSON string). `db` gates the query-backed bindings (`util.oidc_name_tombstoned`, `util.role_has_channel` — the `core.Webhook` authoring connectivity gate reads the actor's role through it); the compute engine does not register them.
- `register_error_global(errors, code)` — registers the `error(msg)` collector global. Each call appends one `ValidationError` to `errors`.
- `register_document_helpers!(...)` — registers the full `document.*` surface (writes pinned to `domain`).
- `register_notification_helpers!(db, queue)` — registers `notification.send`; the caller owns the queue and drains it.
- `close` — closes the engine. Repeat calls do nothing.

Each registration is a separate call, so every consumer keeps its exact setup order. Consumers: `Document::ScriptContext::Base`, `Document::Compute` (read-only `document` subset, see the context table below), and `Hooks::Executor`.

## Sandboxing

The engine is sandboxed to prevent escape from doctype scripts:

**Restricted libraries** — the following standard libraries are **not loaded**:

| Library | Risk |
|---|---|
| `os` | `os.execute`, `os.exit`, `os.rename`, `os.remove`, environment access |
| `io` | Filesystem read/write |
| `package` | C shared library loading (`package.loadlib`) |
| `debug` | Stack introspection, local variable mutation, debug hooks |
| `coroutine` | No legitimate use case for doctype scripts |

**Stripped globals** — from the `base` library, the following functions are removed:

| Global | Risk |
|---|---|
| `dofile`, `loadfile` | Filesystem access via Lua loader |
| `load` | Arbitrary bytecode/string compilation |
| `collectgarbage` | Can interfere with GC behavior |
| `rawget`, `rawset`, `rawequal` | Bypass metatable protections |

**Instruction limit** — a C-level instruction-count hook aborts any infinite loop or excessive computation. Default: 1 million instructions. The error message is "instruction limit exceeded (N)".

**Time limit** — wall-clock time is checked every 100k instructions. If the script exceeds the configured time limit, it is aborted with "time limit exceeded (Ns)". Default: 0.5 seconds.

**Memory limit** — a custom allocator installed via `lua_setallocf` tracks and caps total Lua heap allocations. When the limit is exceeded, the allocator returns NULL (OOM), which causes Lua to raise a memory error. Default: 32 MB.

**Pattern-match guards** — the instruction and time hooks do not fire inside a Lua C call, and `string.find`, `string.match`, `string.gmatch`, and `string.gsub` run their pattern match inside a C call. One pathological pattern would hold the single-threaded event loop past both budgets. `install_pattern_guards!` wraps those four functions with a dispatcher that runs before the C matcher: a subject above `PATTERN_SIZE_LIMIT` (65,536 bytes) is refused, and a pattern above `PATTERN_QUANTIFIER_LIMIT` (8 unescaped `*`, `+`, `-`, `?` — `quantifier_count`) is refused with "pattern is too complex". Capping the quantifier count caps the backtracking exponent and capping the subject caps the length, so the worst-case work stays well below the time budget. Doctype scripts match identifiers, slugs, and short field values, so the caps are generous for real scripts.

All three limits are per engine. The budget state lives in a heap tracker that the allocator owns; the instruction hook reads it back from the Lua state with `lua_getallocf`. Two overlapping runs — a script paused on a db call while another engine starts — keep separate budgets: one run cannot reset or stretch the other's counters.

All three limits are configurable via the `lua:` section in `config.{env}.yml`:

```yaml
lua:
  instruction_limit: 1000000
  memory_limit_mb: 32
  time_limit_s: 0.5
```

## Available globals

Every script context loads the standard Lua libraries (`string`, `math`, `table`, `utf8`). The Crystal-backed helpers differ per context. One table gives the post-registration reality:

| Context | `util.*` / `date.*` / `math.clamp` | `document` global | `notification.send` | `ctx.children` |
|---|---|---|---|---|
| Lifecycle hooks (`create`, `update`, `delete`) and named actions | Yes, with the JSON helpers | Full surface — `create`, `get`, `update`, `delete`, `list`. Writes are pinned to the domain and carry the driving cause | Yes, with a db and a domain | No — hooks read children with `ctx.get_children(name)` |
| Computed fields (`Document::Compute`) | Yes, with the JSON helpers | **Read-only subset** — `get` and `list` work; `create`, `update`, and `delete` raise the Lua error `computed fields must not write — use an action or a hook` | No | Yes, when a to-run field's `compute_when` names a relationship (see [ctx.children](#ctxchildren)) |
| Domain hooks (`Hooks::Executor`) | Yes, with the JSON helpers | Full surface, pinned to the owning domain; writes run `reentrant: true` | Yes | No |
| Transient contexts (migration) | Yes, without the JSON helpers | Not registered (no db) | No | No |

The write rule for the compute sandbox is one sentence: a compute runs mid-mutation, and a write from it would re-enter the pipeline and blur the cause chain — computed fields must not write, so the three writers refuse with a catchable Lua error and the script surfaces the sanctioned surfaces (an action or a hook) in the message.

### `util.*`

| Function | Returns | Description |
|---|---|---|
| `util.ulid()` | string | Generates a ULID (time-sortable, Crockford Base32) |
| `util.sha256(s)` | string | SHA-256 hex digest of a string |
| `util.clamp(x, min, max)` | number | Clamps a value to `[min, max]` |
| `util.is_empty(v)` | boolean | `true` for `nil`, `""`, `{}`, `[]`; `false` otherwise |
| `util.facet_hosts()` | array | Hosts Facet itself answers at — the reserved set the `app.App` `host` hook checks |
| `util.valid_hostname(s)` | boolean | True for a bare lowercase hostname — no scheme, port, path, or wildcard (the `app.App` `host` shape rule) |
| `util.valid_redirect_uri(s)` | boolean | True for an https URI on any host or an http URI on a loopback host (`localhost`, `*.localhost`, `127.0.0.1`, `::1`), with no fragment/userinfo/query; the only permitted wildcard is a `*` port on an http loopback host |
| `util.valid_https_url(s)` | boolean | True for an absolute `https` URL with a host — the `iam.OIDCProvider` provider URL rule (the parse is not expressible in Lua patterns) |
| `util.valid_issuer_url(s)` | boolean | True for an https issuer, or plain `http` on a loopback host so a dev or e2e mock IdP can register without TLS; also rejects a query or fragment (RFC 8414) |
| `util.insecure_urls_allowed()` | boolean | The `webhook.allow_insecure_urls` config flag (default `false`) — the scheme half of the webhook target rule |
| `util.safe_webhook_url(s)` | boolean | The host half of the webhook target rule: true when every resolved address of the URL's host is public or on the allowlist. The scheme rule stays with `util.valid_https_url` / `util.insecure_urls_allowed` |
| `util.coalesce(...)` | any | Returns the first non-nil, non-empty argument |
| `util.json_encode(value)` | string | Serialises any Lua value (table, string, number, boolean, nil) to a JSON string |
| `util.json_decode(json_str)` | table/nil | Parses a JSON string and returns a Lua table/array/value. Raises a Lua error on invalid JSON. |
| `util.webhook_event_names()` | array | The closed event-name vocabulary for the `core.Webhook` `events` field. The webhook create/update hooks reject an unknown name with 422 |
| `util.oidc_name_tombstoned(name)` | boolean | True when a tombstoned `iam.OIDCProvider` still holds `name`; the provider create hook refuses such a name. Needs the db connection — absent in sandboxes without one |
| `util.role_has_channel(role_id, channel)` | boolean | True when the named role's `connectivity` array carries the channel (accepts the bare role name or the projection id); a missing role counts as true, an unreadable connectivity as false. The `core.Webhook` authoring gate. Needs the db connection — absent in sandboxes without one |

### `date.*`

All date math runs in Crystal, in UTC — the backend's single reference frame (the process pins `TZ=UTC` and storage is tz-naive UTC). Values stay strings: a calendar date is `YYYY-MM-DD`, a datetime is a UTC RFC-3339 string, the stored forms. Every function accepts either form (offsets convert to UTC; a bare date reads as UTC midnight) and preserves it: date in → date out, datetime in → datetime out. Bad input — an unparseable value, an unknown unit, a wrong argument kind — raises a catchable Lua error, so a script can `pcall` user-controlled values.

| Function | Returns | Description |
|---|---|---|
| `date.now()` | string | Current UTC time as ISO 8601 |
| `date.today()` | string | Current UTC calendar date, `YYYY-MM-DD` — the server's "today", the same day every server-side reader sees; not the caller's local calendar day (that conversion is a frontend concern, the `core.timezone` setting) |
| `date.diff(a, b, unit)` | number | Signed distance from `a` to `b`. Two distance families: the elapsed units — `second`, `minute`, `hour`, `day`, `week` — measure the physical span and may be fractional (Jul 27 → Aug 6 is 10 days); the calendar units — `month`, `year` — measure the distance between calendar positions and are whole numbers (Jul 27 → Aug 6 is 1 month, Jan 1 → Jan 31 is 0 months). A caller who needs a fractional distance uses an elapsed unit |
| `date.add(iso, n, unit)` | string | Adds `n` units; negative `n` subtracts. Same units as `date.diff`. `month`/`year` clamp the day to the target month's length (Jan 31 + 1 month = Feb 28) and need a whole `n`; the elapsed units take fractions on a datetime. The sub-day units raise on a calendar date — it has no time component |
| `date.start_of(iso, unit)` | string | First day or instant of the `unit` containing the value: `day`, `week` (Monday, ISO-8601), `month`, `quarter`, `year` |
| `date.end_of(iso, unit)` | string | Last day of the unit (dates) or last whole second (datetimes). For a `[)` `period` bound use the next unit's `date.start_of` instead — it excludes nothing |
| `date.parts(iso)` | table | `{year, month, day, hour, minute, second, weekday}` in UTC; `weekday` is ISO-8601 (Monday = 1 … Sunday = 7); the time fields are zero for a calendar date |
| `date.period_overlaps(a, b)` | boolean | True when two `{start, end}` datetime ranges — the `period` field shape — share an instant. Touching ranges do not overlap: the exclusive upper bound (`[)`) excludes the shared instant |
| `date.period_contains(p, x)` | boolean | True when `x` falls inside the `{start, end}` range: start included, end excluded |
| `date.dateperiod_overlaps(a, b)` | boolean | Same for calendar-date ranges — the `dateperiod` field shape, inclusive on both ends. Touching ranges DO overlap: both bounds include their day |
| `date.dateperiod_contains(p, x)` | boolean | True when `x` falls inside the calendar range, inclusive on both ends; a datetime `x` truncates to its UTC date |

### `math.clamp`

```lua
math.clamp(x, 0, 100)  -- same as util.clamp
```

### `document.*` (inter-document operations)

Registered on every context with a `db` connection and a `domain` (see the context table above). Each operation runs under the system auth context (full RBAC bypass) and uses the parent transaction's
DB connection so child operations nest under PG savepoints.

| Function | Returns | Description |
|---|---|---|
| `document.create(doc_type, content)` | projection table \| error | Creates a new document of the given doctype in the same domain. `content` can be a Lua **table** or a JSON **string** — both are accepted. A doctype that declares `member_of` is refused (children are created through the parent's nested route, never from a script), and a body `id` key that is not a declared field is refused as reserved. On success returns a table with `id`, `domain`, `doc_type`, `state`, `version`, `content`, `meta`, `created_at`, `updated_at`, `deleted_at` fields. On failure raises a Lua error (catchable with `pcall`). |
| `document.get(doc_type, doc_id)` | projection table \| error | Fetches a document by doctype and ID. Raises on not-found. |
| `document.update(doc_type, doc_id, content)` | projection table \| error | Partially updates a document. `content` can be a Lua **table** or a JSON **string** — both are accepted. The content is deep-merged into the existing document. Raises on failure. |
| `document.delete(doc_type, doc_id)` | `true` \| error | Soft-deletes a document. Raises on failure. |
| `document.list(doc_type, [filters], [sort], [page], [per_page])` | `{items={...}, total=N}` \| error | Lists documents of the given doctype. All arguments except `doc_type` are optional. Raises on failure. |

**Doctype name form (writes):** `document.create` / `document.update` / `document.delete` write in the script's own domain. They take a **bare doctype name** (`"Expense"`). A qualified name whose domain equals the script's own domain is also accepted and the qualifier is stripped (`"fin.Expense"` inside a `fin` script works unchanged). A qualified name pointing at another domain is refused with `Document writes take a bare same-domain doctype name: ...` — the cross-domain grant path is read-only and does not exist for writes.

**ID shape:** `doc_id` is the bare projection id (the ULID). The stored qualified reference value (`{domain}.{Doctype}.{id}`) does not match — the HTTP layer's prefix-stripping (`canonical_doc_id`) does not apply here.

**Error handling:** All `document.*` functions raise Lua errors on failure. Use `pcall` to handle failures gracefully:

```lua
-- Passing a Lua table (preferred):
local ok, task = pcall(document.create, "Task", { title = "my task", priority = 1 })
if not ok then
  ctx.error("Failed to create task: " .. tostring(task))
  return
end
ctx.root.task_id = task.id
```

Passing a JSON string is also supported for backward compatibility:

```lua
local ok, task = pcall(document.create, "Task", '{"title": "my task"}')
```

**Cross-domain reads:** `document.get` / `document.list` accept a qualified `domain.Doctype` first argument (e.g. `"work.TimeEntry"`) to read across domains. The foreign read needs an active domain grant (see [`domain-grants.md`](domain-grants.md)); without one the call raises a catchable Lua error — `Cross-domain read denied: no active grant from 'work' to 'bill' on 'TimeEntry'`. If the script does not catch it with `pcall`, the hook/action aborts and the refusal surfaces as HTTP 422 carrying that message.

**Audit traceability:** Every `document.*` write stamps its provenance on the typed cause columns of its mutation row. `cause_source` holds the document the hook or action ran on (`domain.Doctype:id`); `cause_name` holds the hook id or action name; `cause_parent` holds the ULID of the driving mutation. The script driver pre-generates its mutation id, so the nested write stamps the driving mutation as its parent (see [`mutation.md`](mutation.md#mutations) for the column definitions, and [`mutation.md`](mutation.md#public-methods) for the parent stamping).

#### Projection table structure

Each `document.*` function that returns a document returns a table with these fields:

| Field | Type | Description |
|---|---|---|
| `id` | string | Document ULID (qualified as `{domain}.{doc_type}.{ulid}`) |
| `domain` | string | The domain |
| `doc_type` | string | The doctype |
| `state` | string | ULID of the last mutation |
| `version` | number | Schema version (only bumped by snapshots) |
| `content` | string | JSON string of the document content |
| `meta` | string | JSON string of document metadata |
| `created_at` | string | ISO 8601 timestamp |
| `updated_at` | string | ISO 8601 timestamp |
| `deleted_at` | string or nil | ISO 8601 timestamp or nil |

The `content` and `meta` fields are JSON strings. To work with them in Lua, parse them with a JSON decoder.

#### `document.list` usage

```lua
-- Basic: list all Notes (first 100)
local ok, result = pcall(document.list, "Note")

-- With filters (table), sort (table), page (number), per_page (number)
local ok, result = pcall(document.list, "Note", {status = "active"}, {"created_at"}, 1, 50)

-- Iterating results
if ok then
  ctx.root.count = result.total
  for i, item in ipairs(result.items) do
    -- item is a projection table
  end
end
```

### `ctx.children` (computed fields over composition children)

A computed field whose `compute_when` names a **child relationship** reads
its children through `ctx.children.<relationship>` — an array of the live
child rows' content, deleted rows excluded. Each entry is the child's
content table, so a compute function reads its fields directly
(`line.qty`, `line.price`).

The compute run stages the table before the function runs, only when a
to-run field's `compute_when` names the relationship — one indexed query per
relationship per run. A relationship the running fields do not name has no
entry. On the create pass (before the document id exists) every named
relationship stages an empty table. A compute that queries instead of
reading the staged rows scopes its `document.list` filter with
`ctx.doc_id` — the id of the document whose field is computed (absent on
the create pass, where the id is not yet resolved).

```lua
local export = {}

function export.compute_order_total(ctx)
  local total = 0
  for _, line in ipairs((ctx.children or {}).lines or {}) do
    total = total + (line.qty or 0) * (line.price or 0)
  end
  return total
end

return export
```

**The recompute trigger rule.** The value lives on the parent; the trigger
lives on the child. When a composition child is created, updated, deleted,
or actioned, the document services run the parent's relationship-named
computed fields and write the result with a partial-patch update that
carries a `recompute` cause — see [mutation.md](mutation.md#computed-field-recompute)
for the cause shape and [document.md](document.md#documentrecompute-srcdocumentrecomputecr)
for the walk. The walk continues upward, so a compute over a compute
converges in the same transaction.

### `notification.*` (producer API)

Registered alongside `document.*` on every context with a database connection (see [`notifications.md`](notifications.md) for the full contract).

| Function | Returns | Description |
|---|---|---|
| `notification.send(account_id, doc_ref, kind, title, [options])` | `true` | Produces one notification for an account. `doc_ref` is the qualified `{domain}.{Doctype}.{id}` of the source document — pass `nil` to mean "the document being mutated" (resolved at drain time, including from a create hook). `options` is an optional table: `icon`, `body`, `data` (table), `actions` (array of `{key, label, variant?, confirm?}` descriptors). The send validates and enqueues only — the row is applied after the owning operation's mutation persists, and a failed drain is logged and dropped. Malformed input raises a Lua error at send time (catchable with `pcall`); the notification id is not exposed. |

```lua
local ok, sent = pcall(
  notification.send,
  ctx.root.owner_id,       -- recipient account
  nil,                     -- doc_ref: nil = this document
  "leave_approved",        -- kind
  "Your leave was approved",
  { icon = "check", body = "Approved by a manager" }
)
if not ok then
  ctx.error("Failed to notify: " .. tostring(sent))
end
```

## Execution

- `engine.run(source : String) : Value` — compiles and runs a Lua chunk, returns the normalized result.
- `engine.function(name, proc)` — registers a Crystal proc (typed arguments and return value) as a Lua global.
- `engine.raw_function(name, &block)` — registers a C-level Lua function callback. The block receives `LibLua::State` and returns the number of return values left on the stack. Supports closures (blocks that capture local variables) via `Lua::Stack`'s `pushclosure` mechanism.
- `engine.raw_function_in_table(state, field_name, &block)` — like `raw_function`, but registers the callback as a field on an existing Lua table at stack index `-1`. The table remains on the stack for subsequent field registrations.
- `engine.raw_state` — returns the raw `LibLua::State` pointer for direct C API access.
- `engine.set_global(name, value)` / `engine.get_global(name)` — read and write Lua globals.

## Value normalization (`Engine::Value`)

| Lua type | Crystal type |
|---|---|
| `nil` | `Nil` |
| `boolean` | `Bool` |
| `number` | `Float64` |
| `string` | `String` |
| `{1, 2, 3}` (consecutive 1-indexed array) | `Array(Value)` |
| `{key = val}` (key-value table) | `Hash(String, Value)` |
| `function` | `::Lua::Function` (callable from Crystal via `.call(...)`) |

## Error handling

- `Engine::Error < ::RuntimeError` wraps any `Lua::LuaError` (syntax errors, runtime errors, memory errors). The original exception is accessible via `.lua_error`.
- **Error messages point at the author's script** (B-318). Lua names every engine chunk `[string "..."]` and numbers it past the engine's wrapper line; `Engine::Error` strips the chunk-name prefix and shifts the line number back by that one wrapper line, and each wrapper that prepends another line (`ScriptContext.wrap_script`, and the callers that feed its output to `run`) rebases once more. A 422 `Script error:` message therefore carries `<author line>: <lua message>` — no wrapper chunk name, no line shift. Messages without a position prefix pass through unchanged.
- `ScriptContext::Error < ::RuntimeError` wraps `Engine::Error` from context initialization; `.engine_error` provides access to the original error.
- The driving service maps a `ScriptContext::Error` to a `Facet::ServiceError` through `ScriptContext.refusal_or_script_error`. A `document.*` helper that recorded a refusal keeps its native status (flat-create guard → 422, missing target → 404); an uncaught script bug with no recorded refusal answers **422** with the Lua error message (`Script error: <lua message>`). A script error never surfaces as a bare 500.
- Scripts can collect validation errors by calling `ctx.error(msg)` — these don't raise; they accumulate in a list returned by `#run`.

## Specs

- 57 examples in `spec/lua/engine_spec.cr` covering lifecycle, arithmetic, strings, booleans, nil, tables, Crystal proc registration, global variables, syntax/runtime errors, sandboxing, safe libraries, stripped globals, and instruction limit.
- 37 examples in `spec/document/script_context_spec.cr` covering create, update, delete, and action contexts with the module pattern.
- 11 examples in `spec/doctype/script_validator_spec.cr` covering action and computed field export validation.
- 5 examples in `spec/document/script_document_helpers_spec.cr` covering `document.create`, `document.get`, `document.update`, `document.delete`, `document.list` in create and action hooks.
- 11 examples in `spec/document/lua_notification_helpers_spec.cr` covering the `notification.send` producer: hook contexts, `doc_ref` resolution (including `doc_ref = nil` from a create hook), send-time rejection, notify-then-fail, and dispatch target.
- 11 examples in `spec/document/compute_spec.cr` covering the compute merge contract, and the read-only `document` global: reads through `document.get` / `document.list`, the writers' refusal, and `ctx.children` staging.
- 7 examples in `spec/document/recompute_spec.cr` covering the parent-recompute walk: compound-create convergence with the cause chain, PATCH and DELETE propagation with the audit row, the no-match negative, the grandparent cascade, the hook loop guard, and the mixed field/relationship `compute_when`.