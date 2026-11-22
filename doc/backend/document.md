# Document Services

**Files:** `src/document/`

Services for creating documents, executing named actions on existing documents, running Lua lifecycle scripts, and evaluating computed fields.

```
src/document/
├── create.cr                # Facet::Document::Create — create documents
├── create_with_children.cr  # Facet::Document::CreateWithChildren — atomic parent+child create
├── read.cr                  # Facet::Document::Read — read with lazy migration
├── resolve.cr               # Facet::Document::Resolve — batch URN → masked projection resolution
├── migrate.cr               # Facet::Document::Migrate — lazy migration engine
├── action.cr                # Facet::Document::Action — execute named actions
├── compute.cr               # Facet::Document::Compute — computed field evaluation
├── update.cr                # Facet::Document::Update — incremental document updates
├── coalesce.cr              # Facet::Document::Coalesce — update persist step + write-time coalescing
├── delete.cr                # Facet::Document::Delete — soft-delete documents
├── filter_compiler.cr       # Facet::Document::FilterCompiler — shared filter grammar compiler
├── list.cr                  # Facet::Document::List — paginated/filtered list
├── list/
│   └── aggregate.cr         # Facet::Document::List::Aggregate — field aggregates (sum, avg, …)
├── collection_version.cr    # Facet::Document::CollectionVersion — collection-version validators
├── sequence_id.cr           # Facet::Document::SequenceId — sequential identifier generation
├── row_access.cr            # Facet::Document::RowAccess — row access primitives (id canonicalization, lock chain, definition lookup)
├── script_context.cr        # Facet::Document::ScriptContext — require root; concern lives in script_context/
├── script_context/
│   ├── json_bridge.cr       # JSON ↔ Lua value converters
│   ├── base.cr              # ScriptContext::Base — shared runtime (boots through Lua::Sandbox)
│   ├── actor_table.cr       # the ctx.actor RBAC surface
│   ├── create.cr            # ScriptContext::Create
│   ├── update.cr            # ScriptContext::Update
│   ├── delete.cr            # ScriptContext::Delete
│   ├── action.cr            # ScriptContext::Action
│   └── migrate.cr           # ScriptContext::Migrate
├── strip_write_only.cr      # Facet::Document::StripWriteOnly — removes write_only fields
├── apply_defaults.cr        # Facet::Document::ApplyDefaults — default field values
├── validation.cr            # Facet::Document::Validation — document-level validation
├── unique_constraint.cr     # Facet::Document::UniqueConstraint — shared `unique: true` checker (create + update)
├── lua_document_helpers.cr  # Facet::Document::LuaDocumentHelpers — document.* Lua helpers
├── lua_notification_helpers.cr # Facet::Document::LuaNotificationHelpers — notification.* Lua producer (validate-and-enqueue; see notifications.md)
├── artifact_refs.cr         # Facet::Document::ArtifactRefs — artifact_references projection reconciler
└── uri.cr                   # Facet::Document::DocURI — canonical document URN
```

---

## Document::DocURI (`src/document/uri.cr`)

A `DocURI` is the canonical, unique, human-readable string referencing a single Facet document. It follows the URN syntax (RFC 8141):

```
urn:facet:{domain}:{Doctype}:{opaque}[?state={mutation_ulid}]
```

The URN is **derivable** from the stored `projections.id` (the legacy dotted form `{domain}.{Doctype}.{opaque}`). The HTTP layer exposes it as `meta.uri` on every single-document response (see [HTTP Layer → Response shapes](http-layer.md#response-shapes)). It is not stored separately.

### Examples

```
urn:facet:hr:Employee:01J5X2ABC            # regular document
urn:facet:core:DocType:hr.Employee         # DocType registration
urn:facet:core:Domain:hr                   # Domain registration
urn:facet:hr:Employee:01J5X2ABC?state=01J5Y…  # pinned to a mutation
```

### Public API

| Method | Returns | Description |
|---|---|---|
| `DocURI.build(domain, doctype, opaque, state = nil)` | `DocURI` | Construct a URI without validation (use `parse` for untrusted input) |
| `DocURI.parse(str)` | `DocURI?` | Parses a URN or the legacy dotted `projections.id`; returns `nil` on malformed input |
| `DocURI.from_projection_id(domain, doctype, id)` | `DocURI` | Derives a URI from a stored `projections.id` (handles the two-segment `core.DocType`/`core.Domain` special case) |
| `#to_s(io)` | `Nil` | Renders the canonical URN, including `?state=` when set |
| `#to_projection_id` | `String` | Converts back to the dotted `projections.id` storage form |
| `#valid?` | `Bool` | True when `domain`, `doctype`, `opaque` match their character-class rules |

### Format rules

The `domain` and `doctype` segments follow the same naming rules enforced at doctype registration (see [`doctype-system.md`](doctype-system.md)). The `opaque` segment is the document's locally-unique id — typically a ULID for user documents, the qualified `{domain}.{Doctype}` for `core.DocType` registrations, or the bare domain name for `core.Domain` registrations.

The optional `?state=` q-component pins the reference to a specific historical state of the document (a mutation ULID). When absent, the URI refers to the current state.

---

## Document::Resolve (`src/document/resolve.cr`)

Resolves a batch of document URNs to masked, authorized projections in one query per target doctype. Every reference an agent holds — a reference-field value, an inline longtext link, a `links` entry — is a bare URN until something resolves it; this service replaces the one-`Read.call`-per-id fan-out.

### Public API

```crystal
Document::Resolve.call(
  db : DB::Connection,
  refs : Array(String),
  auth_context : RBAC::AuthContext,
) : Hash(String, Mutation::Client::Projection)
```

### Behaviour

- Refs are parsed with `DocURI.parse` (canonical URN form; the legacy dotted form parses too) and grouped by `(domain, doctype)`.
- Per group, one SELECT: `domain = $1 AND doc_type = $2 AND deleted_at IS NULL AND id = ANY(...)` AND-composed with `ReadEnforcer.list_where_clauses` — the same scope composition the fan-out surfaces use, so a denied target never appears (the response omits it; it never fails on a denied target).
- Results are masked with `ReadEnforcer.mask_content` against the target doctype's definition.
- The returned hash is keyed by the canonical URN string. Tombstoned, denied, unknown, and unparseable targets simply do not appear.
- No lazy migration — a projection whose schema version lags is served as stored; use `Document::Read` when the migrated form matters.

---

## Document::ArtifactRefs (`src/document/artifact_refs.cr`)

Reconciles the `artifact_references` projection inside the mutation transaction that created / updated / deleted a document. It is **prune bookkeeping only** — it never participates in an access decision, and it is rebuilt from the mutation log: a rollback snapshot repopulates it on the snapshot content. See [`artifact.md`](artifact.md) for the design invariants.

`artifact_references` is a projection in the same sense as the `links` GUC: the walker walks the post-mutation `content` against the `DoctypeDefinition`, emits normalized `(artifact_id, resource_field)` pairs, and inserts them via `ON CONFLICT DO UPDATE` so unchanged references keep a fresh `last_reference_at` (used by the prune window). Duplicate inline links to the same artifact in one longtext field collapse to a single row.

References to artifacts that no longer exist — a stale or fabricated id pasted into a `file` field or a longtext URN — are skipped: the `artifact_references.artifact_id` FK would otherwise raise and turn the whole mutation into a 500. A nonexistent artifact has no bytes to prune, so dropping the reference is lossless.

### Public API

| Method | Description |
|---|---|
| `ArtifactRefs.set_guc(db, content, definition, domain, resource_id)` | Reconcile references for the document against `content`; called from `Document::Create`, `Document::Update`, and `Audit::Rollback` inside their mutation transaction |
| `ArtifactRefs.clear_guc(db, domain, resource_id)` | Delete every reference row for the document; called from `Document::Delete` |
| `ArtifactRefs.extract_from_content(content, definition)` | Pure walker; returns the in-memory list of references — exposed for testing and for Phase 3's owner-row path normalizer |

### Sources walked

| Field type | Contribution |
|---|---|
| `file` | The bare artifact id (a 26-char ULID) stored on the field. `collection: true` arrays emit one reference per entry with a distinct indexed path. |
| `longtext` | Inline `urn:facet:artifact:<id>` links anywhere in the text — both bracketed (`[label](urn:facet:artifact:…)`) and bare mentions. |
| `array` / `object` / `dictionary` | Recurses into nested schemas, appending `[i]` / `.key` / `[key]` to the running path. |
| `child` and `data` | Never contribute. |

### Field path normalization

Paths are fully qualified with array indices: `avatars[0].file`, not `avatars`. The same normalizer produces `artifact_owners.field_path` in the upload flow (Phase 3), so array entries get distinct owner rows with their own `view_tag` snapshots, and the path resolves unambiguously against the doctype definition at read time.

---

## Document::Create (`src/document/create.cr`)

Service for creating a new document of a given doctype. Delegates to `Doctype::Create` when the target is a `core.DocType` registration.

### Public API

```crystal
Facet::Document::Create.call(
  db : DB::Database,
  domain : String,
  doc_type : String,
  body : String,
  actioner_id : String = "system"
) : Result | Error
```

### Return types

| Type | Fields | Description |
|---|---|---|
| `Result` | `projection : Mutation::Client::Projection`, `mutation_id : String` | Success |
| `Error` | `status : Int32`, `message : String`, `details : Array(ValidationError)?` | Failure — see [`ValidationError`](../../../src/validation_error.cr) (`field`/`message`/`code`) |

### Behaviour

- **`core.DocType`** — validates the body as a `DoctypeDefinition` via `Doctype::Validation`, then persists it as a `create` mutation.
- **Other doctypes** — fetches the doctype definition from projections, validates via `Document::Validation`, runs the Lua script's `create()` hook (if defined), then persists.
- Both paths set `actioner_id` (defaults to `"system"`).

## Document::CreateWithChildren (`src/document/create_with_children.cr`)

Service for atomically creating a parent document with its child documents in a single transaction.

Accepts a **compound body** with `$content` (parent fields) and an optional `$children` map (child relationship name → array of child bodies). When only `$content` is present, it behaves identically to `Document::Create`.

### Wire format

```json
POST /Api/hr/Employee
{
  "$content": {
    "status": "active",
    "job_title": "Software Engineer"
  },
  "$children": {
    "career_events": [
      { "event_type": "hired", "effective_date": "2025-01-01T00:00:00Z" }
    ]
  }
}
```

### Public API

```crystal
Facet::Document::CreateWithChildren.call(
  db : DB::Database | DB::Connection,
  domain : String,
  doc_type : String,
  body : String,
  auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
) : Result | Error
```

### Return types

| Type | Fields | Description |
|---|---|---|
| `Result` | `projection`, `mutation_id`, `children : Hash(String, Array(ChildResult))` | Success — children grouped by relationship name |
| `Error` | `status : Int32`, `message : String`, `details : Array(ValidationError)?` | Failure — see [`ValidationError`](../../../src/validation_error.cr) (`field`/`message`/`code`) |

All creates (parent + children) run in a single PG transaction. If any child fails (RBAC, validation, script error), the entire operation is rolled back. The HTTP route dispatches to `CreateWithChildren` automatically when the body contains a `$content` key.

A compound body carries exactly two top-level keys, `$content` and `$children`. Any other top-level key answers `422` naming it — a relationship name sent bare (e.g. `{"$content": …, "lines": […]}`) is refused, not silently dropped. Child rows go under `$children.<relationship_name>`.

Each child create runs the parent-recompute pass for the parent's
relationship-named computed fields, so a relationship-named value converges
inside the same transaction: on create the parent's own compute first sees
an empty `ctx.children` table, and after the children land the recompute
pass runs those fields again. The wire response re-reads the parent
projection after the children, so it carries the final (converged) content.

---

## Document::ApplyDefaults (`src/document/apply_defaults.cr`)

Applies default values from a doctype definition's fields to a document. For every field in the definition that has a `default` value, if the document does not already have that field set, the default is applied.

Called **before** validation, the Lua script, and persistence so that defaults are visible to validation, the script, and the stored content. A required field with a declared default is satisfiable by omission; the materialized default is normalized and type-validated like a submitted value.

The read-only caller-write gate runs **before** this service (B-349). A default on a `read_only` field is a platform write, so the materialized key must never trip the gate. `core.DomainGrant.active` is the seed case: a create without `active` stores `active: false`.

```crystal
Facet::Document::ApplyDefaults.call(
  document : JSON::Any,
  definition : Doctype::DoctypeDefinition,
) : JSON::Any
```

---

## Document::Validation (`src/document/validation.cr`)

Validates a JSON document against a `DoctypeDefinition`. Performs schema-level validation: required fields, field types, unknown fields, read-only fields, reserved fields, and server-owned keys. References and children are not resolved here — they are separate documents.

The read-only caller-write gate is also exposed standalone. The create pipeline runs it on the raw caller body, before `ApplyDefaults` materializes declared defaults; a default on a read-only field is a platform write, never a caller write (B-349). The post-defaults validation pass then runs with the gate off. The update pipeline has no defaults step; `validate_update` runs the gate as part of its checks.

Server-owned keys (`id`, `doctype`, `domain`, `created_at`, `updated_at`) are rejected as top-level body keys with `code: "reserved"` unless the doctype declares the name as a field — on update the patch would otherwise deep-merge them into `content` as stray fields. The check is top-level only (nested keys inside declared `any`/`object` fields are user data). `parent_id` is rejected unconditionally. The create path runs its own body-`id` guard first (`Create.flat_create_guards`), with an exemption for `core.Domain`, whose create branch reads the body id as the domain name.

| Method | Returns | Description |
|---|---|---|
| `Validation.validate(document, definition)` | `Array(String)` | Full validation (required fields, types, unknown, read-only). `check_readonly: false` skips the read-only gate |
| `Validation.validate_update(patch, definition)` | `Array(String)` | Partial update validation (skips required-field checks) |
| `Validation.readonly_write_errors(document, definition, allow_system_writes)` | `Array(String)` | The read-only caller-write gate on its own: no key on a `read_only` or `replicated` field, unless the caller is a system write |

---

## Document::LuaDocumentHelpers (`src/document/lua_document_helpers.cr`)

Crystal-backed Lua functions for inter-document operations within the same domain. Registered as `document.*` globals in script contexts that provide `db` and `domain` (create, update, delete, action hooks). Each operation runs under the system auth context (full RBAC bypass) and uses the parent transaction's DB connection.

| Lua function | Crystal backend | Returns |
|---|---|---|
| `document.create(doc_type, content_json)` | `Document::Create.create_from_parsed` | projection table \| error. A doctype that declares `member_of` is refused — children are created through the parent's nested route, never from a script |
| `document.get(doc_type, doc_id)` | `Mutation::Client.fetch_projection` | projection table \| error |
| `document.update(doc_type, doc_id, content_json)` | `Document::Update.call` | projection table \| error |
| `document.delete(doc_type, doc_id)` | `Document::Delete.call` | `true` \| error |
| `document.list(doc_type, [filters], [sort], [page], [per_page])` | `Document::List.call` | `{items={...}, total=N}` \| error |

All `document.*` functions raise Lua errors on failure — use `pcall` to handle failures gracefully. The create binding shares the flat-create guards of `Document::Create`: a `member_of` child without parent linkage is refused with the same message the REST route raises, and a body `id` key (not a declared field) is refused as a reserved key.

A refusal carries its native HTTP status through the script boundary: when a helper returns a `Facet::ServiceError` and the script does not recover through `pcall`, the driving service (named action, create/update/delete hook) answers with that status — the flat-create guard answers 422 with its guard text, an unknown list filter 422, a missing update target 404. A script bug with no recorded refusal (a typo, a call to an undefined function) still unwinds as a runtime error and surfaces as 500.

---

## Document::Compute (`src/document/compute.cr`)

Service for evaluating computed (`data`) fields after a document mutation. Computed fields are defined in the doctype schema with a `compute` suffix (e.g. `compute` = `"employee_tenure_days"` calls the Lua function `compute_employee_tenure_days`) and a `compute_when` list of trigger names — field names and child relationship names (see [`doctype-system.md`](doctype-system.md#fielddefinition-field_definitioncr)).

**The compute function returns the value.** The returned value is merged into the document at the field's key. A `ctx.root` write to the computed field is honoured too (hook-style), but only when it differs from the pre-call value; the returned value wins when both are present. A `nil` return with no write clears the field — the conditional-compute form.

```lua
local export = {}

function export.compute_cost_cents(ctx)
  -- Preferred: return the value.
  return (ctx.root.hours or 0) * (ctx.root.rate or 0)
end

return export
```

The compute function lives in the script's export table — the full module
pattern is in [`lua-engine.md`](lua-engine.md) → Module pattern.

A compute function that only mutates `ctx.root` and returns nothing still populates the field; a function that returns nil without touching `ctx.root` removes it. Returning nil while the `ctx.root` copy still holds the previous value clears it — the stale value is never kept.

**Script surface.** When the caller passes `db` and `domain`, the sandbox
exposes a **read-only** `document` global: `document.get` and
`document.list` work (with the cross-domain grant ceiling); the three
writers refuse with the Lua error `computed fields must not write — use an
action or a hook`. A compute runs mid-mutation; a write from it would
re-enter the pipeline and blur the cause chain. The JSON helpers
(`util.json_encode` / `util.json_decode`) are registered, because the read
helpers return `content` as a JSON string.

**`ctx.children`.** When a to-run field's `compute_when` names a child
relationship, the run stages `ctx.children.<relationship>` — an array of
the live child rows' content, deleted rows excluded (one indexed query per
relationship per run). See [`lua-engine.md`](lua-engine.md#ctxchildren).

### Flow

1. `Compute.call` receives the script, definition, current document, optional set of changed field names, optional `db` / `domain` / `cause` / `provenance` (for the read-only helpers), and the staged `children` table.
2. For each computed field: if `changed_fields` is `nil` (initial create), always evaluate; otherwise, skip if none of the field's `compute_when` triggers appear in `changed_fields`.
3. A single Lua engine runs all computed fields in definition order. The engine boots through `Lua::Sandbox` (`src/lua/sandbox.cr`). `ctx.root` is updated after each field so subsequent computations see the latest state.
4. Returns the enriched document and any error messages.

Two public helpers serve the callers:

- `Compute.candidate_fields(definition, changed_fields)` — the selection rule as data: the computed fields that run for a changed-field set.
- `Compute.stage_children(db, domain, definition, parent_doc_id, changed_fields)` — builds the `ctx.children` table for one run (empty tables, no query, when `parent_doc_id` is nil — the create pass).

### Wiring

- **`Document::Create`** — runs all computed fields after the `create` hook (all fields are new, so `changed_fields` is `nil`; `ctx.children` stages empty tables — the document id does not exist yet).
- **`Document::Update`** — runs computed fields after the update hook, using the changed fields; relationship-named fields stage their live children.
- **`Document::Action`** — runs computed fields after the action script, using the diff between original and action-mutated document to determine `changed_fields`.
- **`Document::Recompute`** — runs the relationship-named fields of a composition PARENT when one of its children mutates. See below.

---

## Document::Recompute (`src/document/recompute.cr`)

The parent recompute walk (B-110 part 2). A computed field whose
`compute_when` names a **child relationship** re-runs when the children of
that relationship mutate — the value lives on the parent, the trigger lives
on the child.

```crystal
# The document services call this after a child mutation persisted,
# inside the same transaction. Returns a ServiceError when the parent's
# compute or the recompute write fails — the caller surfaces it, and the
# whole operation (child mutation included) rolls back.
Facet::Document::Recompute.after_child_mutation(
  db, domain, child_doc_type, child_doc_id,
  driving_mutation_id, driving_cause, provenance, actioner_id,
) : Facet::ServiceError?
```

| Aspect | Behaviour |
|---|---|
| Trigger points | `Document::Create`, `Update`, `Delete`, and `Action` — every surface that mutates a composition child in a transaction: nested child routes, compound-create children, agent tools, Lua `document.*` writes. Sidecar mutations do not trigger (a sidecar attaches through a reference column, not `meta.parent_id`). |
| The walk | From the mutated child, resolve the parent (`meta.parent_id`). Collect the parent definition's computed fields whose `compute_when` names a relationship pointing at the child's doctype. Re-run them against the parent content (`ctx.children` staged) and write the changed values with a partial-patch `Document::Update.call` (system auth, `reentrant: true`). Continue upward until no parent remains, no relationship matches, the parent content stops changing, or the depth cap (8) is reached. |
| Cause | Kind `replication`, name `recompute`, `parent` = the driving child mutation, `trace` inherited — see [`mutation.md`](mutation.md#computed-field-recompute). The write carries `actioner_id = system:recompute` and lands in the audit log as a normal `update` row. |
| Loop guard | The services skip the walk when the driving mutation's cause is itself a recompute write (`Recompute.recompute_write?`). A parent update hook that writes a child produces a recompute-descended write whose walk is skipped. |
| Failure | A compute error or a refused write returns a `ServiceError` (422) — the child mutation rolls back instead of persisting a stale aggregate. |

---

## Document::Action (`src/document/action.cr`)

Service for executing a named action on an existing document. The action logic lives in the doctype's Lua script.

### Public API

```crystal
Facet::Document::Action.call(
  db : DB::Database,
  domain : String,
  doc_type : String,
  doc_id : String,
  action_name : String,
  args_body : String = "{}",
  actioner_id : String = "system"
) : Result | Error
```

### Flow

1. Fetch the doctype definition and validate the action exists
2. Fetch the current projection
3. Run the action's Lua function in a `ScriptContext::Action`, which receives `ctx` and `args`
4. Compute a JsonDiff between the original and resulting document (from `ctx.root_document`)
5. If changes exist, persist an `update` mutation with the diff; otherwise return the existing projection

## Document::Update (`src/document/update.cr`)

Service for partially updating a document via PATCH. Deep-merges the patch over the current content, runs the Lua `update()` lifecycle hook, re-evaluates computed fields, computes a JsonDiff, and persists it as an `update` mutation.

`unique: true` fields are enforced on the merged document: only fields whose value changed in this update are queried, and the target document's own row is excluded. The check runs after the merge and before the Lua hook (the hook is trusted system code).

### Public API

```crystal
Facet::Document::Update.call(
  db : DB::Connection,
  domain : String,
  doc_type : String,
  doc_id : String,
  body : String,
  auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
  cause : Mutation::Cause? = nil,
  provenance : Mutation::Provenance? = nil,
  reentrant : Bool = false,
  actioner_id : String? = nil,
  skip_authorization : Bool = false,
  currency_check_mode : MoneyCurrencyCheck::Mode = MoneyCurrencyCheck::Mode::Write,
  authorize_path : Array(String)? = nil,
  allow_computed_writes : Bool = false,
) : Result | Facet::ServiceError
```

### Return types

| Type | Fields | Description |
|---|---|---|
| `Result` | `projection : Mutation::Client::Projection`, `mutation_id : String` | Success |
| `Error` | `status : Int32`, `message : String`, `details : Array(ValidationError)?` | Failure — see [`ValidationError`](../../../src/validation_error.cr) (`field`/`message`/`code`) |

1. Lock the projection row (`RowAccess.lock_live_projection_for_update`, `SELECT ... FOR UPDATE`) and answer `404` for a missing row or a tombstone. Every later step reads inside the same transaction, so an internal writer (the Lua `document.update` helper, an IAM account patch, app deploy, parent recompute) that holds no outer lock can no longer merge, check, and persist over a write that committed in between. Callers that already pre-lock with `lock_with_chain` re-enter the transaction without a second lock.
2. Authorize via `RBAC::WriteEnforcer.authorize_update`
2. Fetch the doctype definition, parse the patch, run the invisible-field write guard on the raw body (before any format validation — a caller who cannot see a field never learns its type contract from a 422), and validate the patch via `Document::Validation.validate_update`. `allow_computed_writes` (the recompute write) validates the patch without its computed entries — the compute pipeline owns those values, and `DataType#validate` exists to refuse user input only.
3. Fetch the current projection (returns 404 if deleted/not found)
4. Deep-merge the patch over the current content
5. Check `unique: true` fields on the merged document (changed fields only, own row excluded)
6. Re-check authoring-time RBAC definitions (`iam.Roles` permissions, `core.Domain` context sets)
7. Run the Lua `update()` lifecycle hook (if defined)
8. Re-run computed fields based on changed fields; relationship-named fields stage their live children into `ctx.children`
9. Strip `write_only` fields, pull replica `via` values, restore explicit nulls, compute a JsonDiff, and persist as an `update` mutation. The persist step lives in `Document::Coalesce` (`src/document/coalesce.cr`); `Update.persist_update` forwards to it. With write-time coalescing enabled, `Coalesce` folds the write into the document's previous update row — see [mutation.md → Write-time coalescing](mutation.md#write-time-coalescing).
10. Parent recompute: when this update mutated a composition child, `Document::Recompute.after_child_mutation` walks the composition tree upward (skipped when the driving cause is itself a recompute write — the loop guard). See [Document::Recompute](document.md#documentrecompute-srcdocumentrecomputecr).

---

## Document::Delete (`src/document/delete.cr`)

Service for soft-deleting a document. Inserts a `delete` mutation, which causes the PL/pgSQL trigger to set the `deleted_at` tombstone.

### Public API

```crystal
Facet::Document::Delete.call(
  db : DB::Database | DB::Connection,
  domain : String,
  doc_type : String,
  doc_id : String,
  auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
  reason : String? = nil,
) : Result | Error
```

### Return types

| Type | Fields | Description |
|---|---|---|
| `Result` | `mutation_id : String` | Success |
| `Error` | `status : Int32`, `message : String`, `details : Array(ValidationError)?` | Failure — see [`ValidationError`](../../../src/validation_error.cr) (`field`/`message`/`code`) |
2. Fetch the doctype definition and the current projection (returns 410 if already deleted)
3. Run the Lua `delete()` lifecycle hook (if defined)
4. Insert a `delete` mutation

---

## Document::Copy (`src/document/copy.cr`)

Generic recursive document-copy primitive. Copies a single document and all its owned children (depth-first) from a source domain into a target domain.

### Public API

```crystal
# Copies a document + all owned children. Returns the new top-level doc_id,
# or a ServiceError when an owner-row append fails (the actor cannot read a
# copied artifact).
Document::Copy.deep_copy(
  db : DB::Connection,
  from_domain : String, to_domain : String,
  doc_type : String, doc_id : String,
  actioner_id : String,
  *,
  new_parent_id : String? = nil,
  content_transformer : ContentTransformer? = nil,
  auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
) : String | Facet::ServiceError

# Copies only the children of a document (the parent was already created
# by a specialised path). Used by Domain::Copy.structure for DocType →
# DocumentView.
Document::Copy.copy_children_of(
  db : DB::Connection,
  from_domain : String, to_domain : String,
  parent_doctype : String, source_parent_id : String, new_parent_id : String,
  actioner_id : String,
  content_transformer : ContentTransformer? = nil,
  auth_context : RBAC::AuthContext = RBAC::AuthContext.system,
) : Nil | Facet::ServiceError

alias ContentTransformer = JSON::Any, String, String -> JSON::Any
```

### Identity handling

| Aspect | Behaviour |
|---|---|
| `doc_id` | Always regenerated as a fresh ULID. |
| `meta.parent_id` | Remapped to the new parent's doc_id via `new_parent_id` (or recursion). Without `new_parent_id` the key is dropped — the copy becomes a root; the source's linkage is never inherited. |
| Reference fields | Copied verbatim — cross-domain references are not resolved. |
| `unique: true` fields | Copied verbatim — target draft domain is empty, so no conflict. |
| `file` fields | Copied verbatim (the artifact id). An `artifact_owners` row is appended for each referenced artifact against the target document, so the artifact stays readable through the copy. The actor must be able to read each artifact (system bypasses); a non-readable artifact fails loud (`403`) and the copy rolls back to a savepoint, leaving no half-copied document. See [`artifact.md`](artifact.md) → Owner-append lifecycle. |

### Child traversal

Mirrors `Delete#cascade_delete_children`: only `children:` entries whose target doctype declares `member_of == parent_doctype` are walked. Composition is mutual — a one-sided `children:` entry is rejected at publish/import time (see `Doctype::Composition`), so every `children:` entry the copy finds is an owned edge.

### Used by

`Domain::Copy.structure` — after copying each `core.DocType` definition, calls `copy_children_of` to copy `core.DocumentView` templates, rewriting `parent_doctype` to the target domain's qualified id.

---

## Document::FilterCompiler (`src/document/filter_compiler.cr`)

Shared compiler for the document filter grammar. It takes a doctype definition and a raw filter hash, and returns the WHERE-clause fragments plus their bound parameters. `Document::List` calls it as its only filter-compile step; the partition step, the datetime UTC normalization, and every clause family live here so all callers compile filters the same way.

### Public API

```crystal
Facet::Document::FilterCompiler.compile(
  definition : Doctype::DoctypeDefinition,
  filters : Hash(String, JSON::Any),
  offset : Int32 = 0,
) : {Array(String), Array(::DB::Any)}
```

| Parameter | Meaning |
|---|---|
| `definition` | The doctype definition the filters run against |
| `filters` | Raw filter keys in the `field__op` grammar |
| `offset` | Number of bind parameters the caller already bound; filter placeholders start at `offset + 1` |

`compile` raises `Util::FilterClauses::MoneyFilterError` on a malformed money filter (non-decimal amount, unknown ticker, mixed-currency `__between` bounds). Callers turn it into a 422.

### Clause families (compile order)

The order fixes placeholder numbering. The clauses AND-compose, so the order does not change semantics.

| # | Family | Trigger | SQL builder |
|---|---|---|---|
| 1 | Range | `period` / `dateperiod` field with `eq` / `contains` / `overlaps` / `within` | `Util::FilterClauses.range_clauses` |
| 2 | System column | filter field in `SYSTEM_TIMESTAMP_FIELDS` (`id`, `created_at`, `updated_at`, `deleted_at`) | private `build_system_clauses` |
| 3 | Typed comparison | `gt`/`gte`/`lt`/`lte`/`between`/`in` on `integer` / `duration`, plus `eq`/`ne` when the field declares `equality`/`comparison`; `gt`/`gte`/`lt`/`lte`/`between`/`in` on `boolean` | `Util::FilterClauses.typed_clauses` |
| 4 | Money | `eq`/`gt`/`gte`/`lt`/`lte`/`between`/`currency` on `money` | `Util::FilterClauses.money_clauses` |
| 5 | Container | `eq`/`contains`/`overlaps` on `array` | `Util::FilterClauses.container_clauses` |
| 6 | Scalar | everything else on known fields | `Util::FilterSet` (text extraction) |
| 7 | Search | bare `search` key (a suffixed `search__*` form is `FALSE` — not a grammar production) | private `add_search_filter` (term accent-folded before escaping) |

### Behaviour contracts

- **Unknown fields raise** — `compile` first runs `validate_filters!`: a filter on a field not declared in the definition (and not a system column or `search`) raises `Util::FilterClauses::FilterGrammarError` (reason `unknown_filter_field`), which callers turn into a 422. An operator the field family does not serve raises the same error with reason `unsupported_filter_operator`.
- **Malformed array values raise** — an array-valued operator (`__in`, `__between`, the range intervals, money `__between`, system `id__between` / timestamp `__between`) that receives a non-array value raises `FilterGrammarError` (reason `malformed_filter_value`) before any SQL runs (B-41). Shapes the up-front check does not cover — wrong array arity, an empty or over-100-entry `__in` array — still degrade to `FALSE` inside the clause builders, and direct `Util::FilterClauses` / `Util::FilterSet` callers (e.g. the RBAC scope SQL) keep the degrade-to-`FALSE` contract. Money stays the other exception (see above).
- **Datetime normalization** — values on `datetime` fields and the `created_at` / `updated_at` / `deleted_at` system columns convert to UTC RFC-3339 through `Util::TimeHelper.to_utc_rfc3339` before binding (see AGENTS.md → Time / Timezone).
- A `period` / `dateperiod` filter with a non-range operator (e.g. `__gte`) drops silently.

---

## Document::List (`src/document/list.cr`)

Service for paginated/filtered listing of documents for a given doctype. Only non-deleted projections are returned.

### Public API

```crystal
Facet::Document::List.call(
  db : DB::Database,
  domain : String,
  doc_type : String,
  filters : Hash(String, JSON::Any) = {},
  sort : Array(String) = ["id"],
  page : Int32 = 1,
  items_per_page : Int32 = 100,
) : Result
```

### Return types

| Type | Fields | Description |
|---|---|---|
| `Result` | `items : Array(Mutation::Client::Projection)`, `total : Int64` | Paginated results |

### Filter syntax

Filters compile through `Document::FilterCompiler` (see above). Filter keys use double-underscore suffixes for operator:

| Suffix | Operator | Example key |
|---|---|---|
| *(none)* | `=` | `name` |
| `__eq` | `=` | `name__eq` |
| `__gt` | `>` | `age__gt` |
| `__gte` | `>=` | `age__gte` |
| `__lt` | `<` | `age__lt` |
| `__lte` | `<=` | `age__lte` |
| `__ne` | `IS DISTINCT FROM` | `status__ne` |

The reserved key `parent_id__eq` scopes the listing to one parent's owned children — the same `meta->>'parent_id'` clause the nested child route drives. It is valid only on owned-child doctypes (`member_of` set — otherwise 422, since such rows never carry `parent_id`); the value may be the bare parent doc id or its fully qualified reference token (`{domain}.{Doctype}.{id}`). Other `parent_id__*` suffixes reach the field grammar and answer 422 as unknown fields.

### Sort fields

Sort fields prefixed with `-` use descending order. System sort columns are `id`, `created_at`, `updated_at`, and `deleted_at`; all others reference `content->>'field'` (or the typed cast helper — see `sort_expression_for`). An entry that is neither a system column nor a doctype field answers `422 unknown_sort_field`; a doctype field whose type cannot sort (period, dateperiod, object, array, dictionary, any, data) answers `422 unsortable_field` — a sort entry is never dropped silently (B-158).

### ⚠️ Database quirk

`List.call` uses `rs = db.query(...); rs.each do` instead of `db.query(...) do |rs|` because `crystal-db` 0.14.0 does **not** auto-position the cursor when `db.query` yields a block. See `AGENTS.md#database-quirks`.

---

## Document::ScriptContext (`src/document/script_context.cr`)

Lua script wrappers that prepare a Lua execution context for each lifecycle hook. `script_context.cr` is a require root. The concern lives in `script_context/`: `json_bridge` (JSON ↔ Lua converters), `base` (the runtime base), `actor_table` (the `ctx.actor` surface), and one file per lifecycle context (create, update, delete, action, migrate).

### Module pattern

Scripts must return a Lua table of exported functions:

```lua
local export = {}

function export.create(ctx)
  -- lifecycle hook: validate or mutate ctx.root
end

function export.promote(ctx, args)
  -- named action: mutate ctx.root, validate via ctx.error()
end

return export
```

### Context classes

Every context calls `_MODULE.validate(ctx)` before the lifecycle/action function (if defined in the script). This allows shared validation rules to be written once. On `ScriptContext::Action`, `_MODULE.update(ctx)` also runs after the action function against the final document state, with `ctx.changed` listing the fields the action mutated — a state-machine guard written in the update hook binds named actions too. `validate` keeps seeing the pre-action state.

| Class | Lua function | Purpose |
|---|---|---|
| `ScriptContext::Create` | `export.create(ctx)` | Validates and mutates document on creation |
| `ScriptContext::Update` | `export.update(ctx)` | Validates and mutates document on update |
| `ScriptContext::Delete` | `export.delete(ctx)` | Validates before deletion |
| `ScriptContext::Action` | `export.{name}(ctx, args)`, then `export.update(ctx)` | Executes a named action, then the update hook against the final state |
| `ScriptContext::Migrate` | `export.{func_name}(ctx)` | Runs a single migration function during lazy schema migration |

### ctx table

| Field | Type | Purpose |
|---|---|---|
| `ctx.root` | table | The document content. Mutate in-place for create/update/action hooks. On `update`, this is the **merged** document (current content with the patch applied) |
| `ctx.patch` | table \| nil | On `update` only: the partial PATCH body the caller submitted (post-normalize, pre-merge). Use it to distinguish "caller asked to change this field" from "the field kept its existing value"; absent on every other hook type and on `update` when no patch was supplied |
| `ctx.action` | string \| nil | On an action-driven run only: the named action (`"approve"`). Present for `validate`, the action function, and `update`. Absent on PATCH and every other hook type — scripts branch with `ctx.action ~= nil` |
| `ctx.changed` | table \| nil | On `update` when the run is action-driven: array of field names the action mutated, published right before the hook. On PATCH, read `ctx.patch` instead |
| `ctx.doc_id` | string \| nil | The document id, when supplied (create with explicit id, update, delete, action). Absent on pure-unit script specs |
| `ctx.error(msg)` | function | Collects a validation error string (produces a `code: "script"` `ValidationError` with `field: nil`) |
| `ctx.actor_id` | string | The account/actioner ID |
| `ctx.now` | string | ISO 8601 timestamp of the mutation |
| `ctx.actor` | table \| nil | When an `auth_context` is attached: the caller's identity, role, visible tags, scope alias, and resolved context sets. Absent on migration contexts and pure-unit specs |

### State guards that bind both update paths

An `update` hook can run on two drives. A PATCH-driven update carries
`ctx.patch` (the submitted patch; `ctx.changed` is nil). An action-driven
update carries `ctx.changed` (the fields the action mutated; `ctx.patch`
is nil there — `ScriptContext::Action` never passes a patch). A guard
written only on `ctx.patch` never fires for action-driven updates. Key on
both:

```lua
-- Hand-rolled state guard: fires on PATCH updates and on action
-- updates alike.
local ALLOWED_STATUS = { draft = true, submitted = true, approved = true }

function export.update(ctx)
  local touched = {}

  -- PATCH drive: the submitted patch keys are the touched fields.
  if ctx.patch ~= nil then
    for field in pairs(ctx.patch) do
      touched[field] = true
    end
  end

  -- Action drive: ctx.changed lists the fields the action mutated.
  if ctx.changed ~= nil then
    for _, field in ipairs(ctx.changed) do
      touched[field] = true
    end
  end

  if touched.status and not ALLOWED_STATUS[ctx.root.status] then
    ctx.error("status: '" .. tostring(ctx.root.status) .. "' is not a legal state")
  end
end
```

When the rule is only "this action may run in these states", prefer the
declarative gate: `ActionDefinition.states` (e.g.
`states: {status: [submitted, pending]}`) answers `422` before the script
runs and hides the menu entry in the UI — see
[`doctype-system.md`](doctype-system.md) → ActionDefinition. Write the Lua
guard only when the rule reads row content the gate cannot express.

### Available globals

In addition to the standard Lua libraries (`string`, `math`, `table`, `utf8`), all script contexts and computed field evaluation have access to:

- `util.*` — `ulid`, `sha256`, `clamp`, `is_empty`, `coalesce`
- `date.*` — `diff`, `now`
- `math.clamp`
- `document.*` — `create`, `get`, `update`, `delete`, `list` (inter-document operations, available where `db` and `domain` are provided: create, update, delete, action hooks)

See [Lua Engine → Available globals](lua-engine.md#available-globals) for the full reference.

### Runtime boot

`ScriptContext::Base` owns the shared setup. It boots the engine through `Lua::Sandbox` (`src/lua/sandbox.cr`), which registers the `error` global, the `util.*` / `date.*` / `math.clamp` helpers, and the `document.*` / `notification.*` helpers. `Document::Compute` and `Hooks::Executor` use the same sandbox. See [Lua Engine → Lua::Sandbox](lua-engine.md#luasandbox).

### Value conversion

The `script_context/json_bridge.cr` file holds the bridge helpers (`json_to_lua_value`, `lua_value_to_json`, `lua_table_to_json`, `emit_lua_table`, …). They convert Crystal JSON values to Lua tables and back.
