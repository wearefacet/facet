# Role-Based Access Control (RBAC)

**Files:** `src/rbac/`, `src/rbac.cr`

Access control system for Facet documents. Uses a single active role per request; roles never merge.

## Architecture

### Core types

| Type | File | Description |
|---|---|---|
| `RBAC::Error` | `src/rbac/error.cr` | Base error type for all RBAC failures (status 403 by default) |
| `RBAC::Permission` | `src/rbac/permission.cr` | A single permission line: `{action, on, scope?, except?}` where `scope` is an array of named-scope aliases (OR semantics) and `except` is an array of concrete `domain.Doctype` paths subtracted from the `on` reach |
| `RBAC::ScopeValue` | `src/rbac/scope_value.cr` | A typed predicate value used inside a named scope's `where` (literal, `$self`, `$<context_set>`, `$null`, or `$organizational_unit`) |
| `RBAC::ScopePredicate` | `src/rbac/scope_predicate.cr` | A parsed `where` entry: bare field name + `Doctype::Operator` (from an optional `__op` suffix) + `ScopeValue`. `ScopePredicateParser` parses the map; `ScopePredicateSql` compiles predicates to SQL — the single compiler shared by the named-scope list path and `ContextResolver` |
| `RBAC::ScopeContext` | `src/rbac/scope_context.cr` | Per-request actioner attributes used by scope evaluation: the account id (backing `$self`) and the account's `organizational_unit` path (backing `$organizational_unit`) |
| `RBAC::ScopeExpander` | `src/rbac/scope_expander.cr` | Resolves a permission's scope alias against the target doctype definition at enforcement time |
| `RBAC::EnforcerSupport` | `src/rbac/enforcer_support.cr` | Internal support shared by both enforcers: the permission gate dispatch, the scope-input loader, and the single-row gate (`row_authorized?`) that compiles a row's scope predicates to SQL and answers the row against them |
| `RBAC::ContextSet` | `src/rbac/context_set.cr` | Named, domain-owned query that resolves a set of values |
| `RBAC::ActiveRole` | `src/rbac/active_role.cr` | The one active role for a single request |
| `RBAC::AuthContext` | `src/rbac/auth_context.cr` | Bundles a `Principal` (System \| Real \| Preview) — the identity + role token threaded through every document operation |
| `RBAC::Principal` | `src/rbac/principal.cr` | Abstract struct: `System` (full bypass), `Real` (an authenticated caller with an `ActiveRole`), or `Preview` (a capability principal scoped to one draft domain — see [`draft-domains.md`](draft-domains.md#preview-mode)) |
| `RBAC::ContextResolver` | `src/rbac/context_resolver.cr` | Resolves context sets at request time with per-request memoization |
| `RBAC::AccountLoader` | `src/rbac/account_loader.cr` | Loads account role IDs from projections (trusted bypass) |
| `RBAC::ReadEnforcer` | `src/rbac/read_enforcer.cr` | Enforces RBAC on read operations (single, list, and nested-child parent gate); read masking delegates to the shared field-visibility walker |
| `RBAC::WriteEnforcer` | `src/rbac/write_enforcer.cr` | Enforces RBAC on write operations (create, update, delete, action) and owns the invisible-field write/change guards (`authorize_field_writes`, `authorize_field_changes`) |
| `RBAC::RoleAuthority` | `src/rbac/role_authority.cr` | Caller-authority boundary for the IAM doctypes (`iam.Account`, `iam.Roles`): caller level, target protection, assignment and role-power rules |
| `RBAC::FieldVisibility` | `src/rbac/field_visibility.cr` | The one recursive schema walker: read masking, submitted-write violations, changed-path violations, field visibility |
| `RBAC::Validator` | `src/rbac/validator.cr` | Authoring-time validator for permission definitions, context sets, and named scopes |
| `Doctype::NamedScope` | `src/doctype/named_scope.cr` | A named, server-defined predicate over a doctype's own fields |

### Permission grammar

Each permission in a role follows this structure:

- **`action`**: the operation the permission grants. One of `read`, `create`, `update`, `delete`, `*` (wildcard — matches all), or a named action (e.g. `promote`, `archive`)
- **`on`**: a dot-separated path in `domain.DocType` format. Supports wildcards: `*.*` matches all doctypes in all domains (admin role only). Path segments can be nested (e.g. `crm.Project.Comment`) — a permission on `Project` matches `Project.Comment` via prefix matching. The bare domain form (`"on": "hr"`) is the domain-wide scope: the empty path prefix-matches every doctype in the domain. A `domain.*` form is not valid grammar (the wildcard path is only valid as `*.*`) — write the bare domain for a domain-wide scope.
- **`scope`** *(optional)*: a single alias string or an array of alias strings naming named scopes declared on the leaf doctype. Roles cannot author custom query predicates — they reference reusable, server-defined predicates only. When multiple aliases are listed, they combine with OR semantics at enforcement time.
- **`except`** *(optional)*: an array of concrete `domain.Doctype` paths subtracted from the permission's `on` reach. A target matching any entry never matches the permission, even when it matches `on`; entries prefix-match exactly like `on` (an entry on `core.DocType` also excludes `core.DocType.Comment`). No wildcards — entries are validated at parse time (`Permission.from_json`, so authoring-time validation surfaces them as per-line errors and role loading fails loud on a malformed stored role). This is pure path arithmetic, not a deny system: it only shrinks what one line matches, so a scoped re-grant on the same paths becomes meaningful alongside a blanket line. Absent `except` parses as `[]` and `to_h` round-trips it.

The `scope` field accepts:

- **`$<named_scope>`** — references a named scope declared on the leaf doctype (e.g. `"$mine"`, `"$active_only"`). The enforcer expands the alias against the target doctype definition at enforcement time.
- **an array of `$<named_scope>`** — grants read on rows matching **any** of the listed named scopes (OR semantics), e.g. `["$mine", "$global"]` grants access on rows owned by the actioner OR rows with no owner.
- **`$all`** — the explicit unrestricted sentinel. Equivalent to omitting `scope` entirely. When `$all` appears in an array, the whole permission collapses to unrestricted.
- **omitted** — the permission is unrestricted (matches every row).

```json
// Unrestricted — grants read across all rows of production.Project.
{"action": "read", "on": "production.Project"}

// Domain-wide — grants read on every doctype in the hr domain.
{"action": "read", "on": "hr"}

// Explicit unrestricted (same as above).
{"action": "read", "on": "production.Project", "scope": "$all"}

// Restricted via a named scope — grants read only on projects the
// actioner owns (where the `mine` named scope's `where` matches).
{"action": "read", "on": "production.Project", "scope": "$mine"}

// OR of named scopes — grants read on personal projects (owned by the
// actioner) OR on global projects (no owner). Each alias's `where`
// predicate is OR-ed against the others within this permission.
{"action": "read", "on": "production.Project", "scope": ["$mine", "$global"]}

// Blanket update with a carve-out: matches every doctype except the two
// definition surfaces, letting a scoped re-grant on those paths apply.
{"action": "update", "on": "*.*", "except": ["core.Domain", "core.DocType"]}
```

The parser normalizes the legacy single-string form (`"scope": "$mine"`)
to a one-element array and serialises back in the array form. This
tolerance exists only when the system reads stored role content —
enforcement loads, reads, and audit views. Every write path requires the
array form: the `iam.Roles` definition declares `scope` as `type: array`,
so a string scope in a write body fails schema validation with `must be
an array` before the RBAC permission validator runs. Editors must emit
the canonical array form.

### Named scopes

A named scope is a reusable, declarative predicate over a doctype's own fields, declared on the doctype definition itself. Permissions reference them by alias; the enforcer expands the alias to the underlying `where` map at enforcement time.

**Declaration** lives on `{domain}.{Doctype}.definition.content.scopes`:

```yaml
# production.Project/definition.yml
fields:
  owner_id: { type: reference, doctype: 'iam.Account' }
  status:   { type: enum, values: [planned, active, on_hold, completed, cancelled] }
scopes:
  mine:
    description: "Projects owned by the actioner"
    where: { owner_id: '$self' }
  active:
    description: "Projects in the active status"
    where: { status: 'active' }
```

The `where` value grammar (a `ScopeValue`):

- a **literal** (compared verbatim against the field's content value)
- **`$self`** — the actioner's account id, matched against **both** stored forms: the fully qualified reference value (`iam.Account.<id>`, what a `reference` field targeting `iam.Account` stores) and the bare id (what a plain `string` field holds — e.g. a create hook writing `ctx.root.owner_id = ctx.actor.id`, see [`lua-engine.md`](lua-engine.md#ctxactor)). Either storage form satisfies the predicate, so a `$mine` scope works unchanged whether the owner field is reference-typed or a plain string.
- **`$<context_set>`** — a domain-declared context set, resolved at request time by `ContextResolver` into an array of values (membership-tested against the field's content value). `$my_teams` is not a built-in token: `ScopeValue.parse` maps every value that starts with `$` and is not `$self` / `$null` / `$organizational_unit` to `ContextSet`, so the name after the `$` is a key in the domain's `context_sets` map. `$my_teams` resolves only because the domain declares a set with that name — the production fixture declares `my_teams: { from: TeamMember, where: { account: $self }, select: $parent_id }`. An undeclared name fails authoring-time validation and, at runtime, fails closed. `EnforcerSupport.load_scope_inputs` resolves the whole domain's set map once per enforced read/write/list, so a named scope that references no set does not add a per-scope query on top of that.
- **`$null`** — matches rows where the field is absent or its content value is JSON null. Lets a named scope express `IS NULL` predicates (e.g. `global: { where: { owner_id: $null } }` matches rows whose owner is unassigned — global resources not owned by any account). Combines with other aliases through the permission's OR semantics, so a single permission line `["$mine", "$global"]` cleanly expresses "rows I own OR rows nobody owns". Valid only with `eq`.
- **`$organizational_unit`** — the actioner's own `iam.Account.organizational_unit` value (a folder-like path such as `/`, `/engineering/`, `/engineering/backend/`). Resolved per request from the account projection (trusted bypass, see `RBAC::ScopeContext`) and compared against the field's content value — e.g. `where: { ou: '$organizational_unit' }`.

The `where` field names may carry an **operator suffix**, using the same `__op` grammar as `Document::List` filter keys: `ou__starts_with`, `title__match`, `priority__gte`, `price__between`, and so on. A bare field name means `eq`. The valid operators for a field are exactly the ones its declared `filters` capabilities allow (a field with no declared `filters` accepts `eq` only). The reserved field tokens **`$parent_id`** (reads the system-managed parent linkage stored at `meta->>'parent_id'`) and **`$doc_id`** (reads the row's own `projections.id` — the identity of a `core.Domain` row lives in the row id, not in content) accept only `eq`/`ne`. Operator and value restrictions are enforced at authoring time by `RBAC::Validator` and mirrored at runtime by `RBAC::ScopePredicateSql`. One engine serves every enforcement surface: the list path and the parent gate compile the tokens against the `projections` columns, and the single-row gate (`EnforcerSupport.row_authorized?`) compiles the same predicates against the target row — so a row a scoped list shows is also readable, updatable, and deletable one-row-at-a-time, and `$null` means `IS NULL` on both paths.

#### Operator semantics in SQL (`ScopePredicateSql`)

`RBAC::ScopePredicateSql` is the single owner of scope → SQL compilation. Both the named-scope list path (`ReadEnforcer`) and context-set resolution (`ContextResolver`) compile through it, so the two SQL surfaces agree byte-for-byte on operator behaviour:

- **`Eq` against `$<context_set>`** — membership over the resolved values. An empty or unresolved set emits `1=0` (no rows).
- **`Ne` against `$<context_set>`** — `NOT (... = ANY(...))` over the resolved values. Against an empty or unresolved set this emits `FALSE` (no rows), **fail closed**: "not in an empty set" is vacuously true for every row, and emitting that would widen access when a dependency fails to resolve. This is an intentional unification — the two former compilers disagreed here.
- **`Gt`/`Gte`/`Lt`/`Lte`/`Between`/`Contains`/`Overlaps`/`Within`/`Currency`** — dispatch is **field-driven**, in order: a range operator routes to `range_clauses`; a `money` field routes to `money_clauses` (which covers the `currency` operator and numeric comparisons on the money value member); a typed field (integer/duration/boolean) routes to `typed_clauses`; a text field falls back to a text comparison for gt/gte/lt/lte and fails closed (`FALSE`) for every other operator. Field-driven routing (not operator-driven) is what keeps `price__gt` on a money field comparing the numeric `value` member instead of the raw JSONB text.

Named scopes are **stateless predicates** — they have no DB cost at request time beyond reading the doctype definition (which is cached, see `Doctype::DefinitionStore`). This differs from context sets, which run an actual query per request.

Named scopes are also **query-time filters**: the agent read tools (`list_documents`, `aggregate_documents`) and the HTTP document list/aggregate route (`?scope=<name>`) accept a `scope` parameter naming one declared scope, and `Document::List` AND-compiles it through `ScopePredicateParser` + `ScopePredicateSql` (`Document::List.build_named_scope_clause`) with the calling account's context — `$self` and context sets bind to the caller, exactly as at enforcement time. The RBAC scope clauses are untouched: a query-time scope only narrows what the caller can already see. The tool layer raises `InvalidParams` on an unknown name; the HTTP route answers the service's 422 `Unknown scope`.

### Context sets

Domain-owned, defined on `core.Domain` under `definition.content.context_sets`. Each context set describes a query:

- **`from`**: a DocType in the same domain
- **`where`**: field-value predicates (may reference `$self`, `$organizational_unit`, or other context sets via `$set_name`; field names may carry the same `__op` operator suffixes as named scopes)
- **`select`**: the field to project from matching rows

Both `where` field names and `select` accept the reserved tokens **`$parent_id`** and **`$doc_id`**. `$parent_id` reads the system-managed parent linkage stored at `meta->>'parent_id'` (set when a child document is created via its parent's nested route); `$doc_id` projects the row's own `projections.id` column. This lets a context set scope by ownership rather than by a content field — e.g. resolving the teams a caller belongs to from `TeamMember` child rows, or projecting the qualified ids of `core.DocType` rows (the row id is the `{domain}.{Doctype}` form `core.DocumentView.parent_doctype` stores) for the domain-editor scopes on the `core` domain document (see [`domain-editors.md`](domain-editors.md)).

Context sets are resolved at request time by `ContextResolver`, which walks the dependency DAG in topological order and memoizes results per domain. The set's `where` predicates are compiled by the same `RBAC::ScopePredicateSql` compiler the named-scope list path uses — a context set whose dependency resolves to an empty set fails closed (no rows), for both `Eq` and `Ne`. This is a trusted-bypass component — it reads raw projections directly.

### Named scopes vs. context sets

| Concept | Where declared | What it means | Server-side resolution | Examples |
|---|---|---|---|---|
| **Context set** | `core.Domain.content.context_sets` | Cross-doctype query that returns a *dynamic value set* per request | `ContextResolver` runs the query, memoizes per request | `$my_teams` (a set the domain declares — e.g. the teams the actioner belongs to) |
| **Named scope** | `{domain}.{Doctype}.definition.content.scopes` | A predefined predicate over *this doctype's own fields*, static | `ScopeExpander` expands `$<name>` → `Hash(field, ScopeValue)` once. No DB query. | `$active_only` → `{active: true}` |

Both coexist. A named scope's `where` may itself reference `$<context_set>` to encode "rows whose `team` field matches any of the teams the actioner belongs to" — the named scope acts as a reusable wrapper around the dynamic context set value.

## AuthContext

The `AuthContext` struct is the identity token passed through every document service call. It bundles a `Principal` that is either:

- **`Principal::System`** — full bypass, used for internal operations (migrations, projection triggers, replication) and specs.
- **`Principal::Real`** — an authenticated caller with a loaded `ActiveRole`. Two built shapes share the reserved identities: `AuthContext.authenticated` (a real account id) and `AuthContext.anonymous` (the reserved `"anonymous"` id, carrying the seeded `iam.Roles.anonymous` role — see [HTTP integration](#http-integration)). `AuthContext.denied` also builds a `Real` principal with the `"anonymous"` id and an empty role — the fail-closed fallback for a nil fiber-local context.
- **`Principal::Preview`** — a capability principal scoped to one draft domain. Built from a `typ: "preview"` JWT after the caller's real identity proved `create core.DocType` against the draft; the principal bypasses the role/permission system entirely and gates purely on domain identity. See [`draft-domains.md`](draft-domains.md#preview-mode).

```crystal
# System bypass (used internally)
ctx = AuthContext.system
ctx.system?  # => true
ctx.account_id  # => "system"

# Real authenticated principal (used for HTTP requests)
role = ActiveRole.from_projection_content(projection_content)
ctx = AuthContext.authenticated("account_abc123", role)
ctx.system?  # => false
ctx.account_id  # => "account_abc123"
ctx.principal.active_role.role_id  # => "crm_editor"

# Anonymous principal (credential-less request, seeded iam.Roles.anonymous role)
ctx = AuthContext.anonymous(role)
ctx.account_id  # => "anonymous" — reserved identity, audit-log exclusive with "system"
ctx.can?("read", "core", ["Currency"])  # => follows the anonymous role's permissions

# Preview principal (capability token issued by /preview-session)
ctx = AuthContext.preview("account_abc123", "_draft_domain")
ctx.preview?  # => true
ctx.preview_domain  # => "_draft_domain"
ctx.account_id  # => "account_abc123" — attributed in mutation audit log
```

The `AuthContext` carries both the identity string (used as `actioner_id` in mutation logging) and the role's permission map (used by the enforcers). It has no I/O — the `can?` method is a pure lookup against the role's permissions.

Scope semantics of the reserved `"anonymous"` identity: `$self` resolves to the literal `"anonymous"` (no account row carries that id, so `$self`-scoped grants are inert), and `$organizational_unit` resolves to `"/"` (the root-safe fallback `AccountLoader.organizational_unit` applies to a missing account).

## Enforcement

### How AuthContext flows through the system

Every document service accepts an `AuthContext` as its last parameter:

| Service | Signature |
|---|---|
| `Document::Create.call(…, auth_context, meta_overrides:)` | positional, defaults to `AuthContext.system` |
| `Document::Read.call(…, auth_context)` | positional, **required** (no default) |
| `Document::Update.call(…, auth_context, reason:)` | positional, defaults to `AuthContext.system` |
| `Document::Delete.call(…, auth_context, reason:)` | positional, defaults to `AuthContext.system` |
| `Document::List.call(…, auth_context:)` | keyword arg, defaults to `AuthContext.system` |
| `Document::Action.call(…, auth_context)` | positional, defaults to `AuthContext.system` |
| `Doctype::Create.call(…, auth_context)` | positional, defaults to `AuthContext.system` |
| `Doctype::Update.call(…, auth_context)` | positional, defaults to `AuthContext.system` |
| `Audit::List.call(…, auth_context:)` | keyword arg, defaults to `AuthContext.system` |
| `Audit::Rollback.call(…, auth_context)` | positional, defaults to `AuthContext.system` |

> `Read.call` has a required parameter because returning bypass-vs-restricted data has the most impact — every caller must consciously decide which principal they represent.

The `actioner_id` used for mutation logging is **derived from `auth_context.account_id`** inside each service. You never pass both — the identity and the authorization are unified.

### Where the enforcer is called

The enforcer is invoked **inside** each document service's `.call` method, at the top (after input parsing but before any DB mutation). This protects every caller equally — whether the call comes from an HTTP route, a migration script, a background job, or a spec.

- `Document::Create.call` → `WriteEnforcer.authorize_create(db, domain, doc_type, auth_context)`
- `Document::Read.call` → the class-level read gate (`ReadEnforcer.read_denied?` — a denial answers 403) + `ReadEnforcer.authorized?(db, domain, doc_type, doc_id, auth_context)` + `ReadEnforcer.mask_content(...)`
- `Document::Update.call` → the class-level action gate (`WriteEnforcer.action_denied?` — 403) then `WriteEnforcer.authorize_update(db, domain, doc_type, doc_id, auth_context)` (404 on a failed row check)
- `Document::Delete.call` → the class-level action gate (`WriteEnforcer.action_denied?` — 403) then `WriteEnforcer.authorize_delete(db, domain, doc_type, doc_id, auth_context)` (404 on a failed row check)
- `Document::List.call` → the class-level read gate (`ReadEnforcer.list_denied?` — a denial answers 403, see [Class-level vs row-level denial](#class-level-vs-row-level-denial)) + `ReadEnforcer.list_where_clauses(...)` merged into SQL + `ReadEnforcer.mask_content(...)` on items
  - `list_where_clauses(db, domain, doc_type, auth_context, start_idx : Int32 = 1)` returns the OR-joined scope fragments **and their bound parameters** as a tuple. `start_idx` is the placeholder index for the **first** bound parameter the scope clauses emit, so callers can compose them after WHERE fragments that already occupy earlier placeholders. `Document::List.build_where_clause` reserves `$1` (`domain`) and `$2` (`doc_type`) for its base filters, then passes `start_idx: all_params.size + 1` so the scope clauses get `$3`, `$4`, … — their params are concatenated to the same `all_params` array in the same order. `parent_authorized?` likewise reserves `$1..$3` for `domain`/`doc_type`/`doc_id` and threads `start_idx: 4`. The default `start_idx: 1` preserves the standalone unit-test contract (scope clauses emit `$1`, `$2`, … when invoked directly).
- Nested child routes (`GET /Api/:domain/:doctype/:id/:rest`) → `ReadEnforcer.parent_authorized?` on the immediate parent before delegating to `Document::List` or `Document::Read` (see [HTTP Layer → Nested child routes](http-layer.md#nested-child-routes)). On these routes, child authorization for create, read, update, and delete uses the composition path from the aggregate root (`domain.Parent.Child...`) — both the role permission match and the app-grant ceiling. The parent read gate on `GET` stays. Row-level scope expansion still uses the leaf (child) doctype. Flat-route authorization is unchanged. **The composition path is a prefix path, so a caller with no child grant reads a parent's children through the nested route; the flat child route stays refused.** A role line `read on lab.Specimen` prefix-matches `lab.Specimen.SpecLine`, so `GET /Api/lab/Specimen/:id/lines` answers `200` with the children, while the flat `GET /Api/lab/SpecLine` and `GET /Api/lab/SpecLine/:id` answer `403` (no line on the bare `lab.SpecLine` path). A child is owned by its parent and reached through it: the parent read gate scopes which children the caller sees, and no separate child grant is needed for the nested read. Do not read the flat route's `403` as also applying to the nested route — the two routes check different paths.
- `Document::Action.call` → the class-level action gate (`WriteEnforcer.action_denied?` — 403) then `WriteEnforcer.authorize_action(db, domain, doc_type, doc_id, action_name, auth_context)` (404 on a failed row check)
- `Doctype::Create.call` → `WriteEnforcer.authorize_create(db, "core", "DocType", auth_context)`
- `Doctype::Update.call` → `WriteEnforcer.authorize_update(db, "core", "DocType", doctype_id, auth_context)`
- `Document::ReferenceCheck.check(db, definition, document, auth_context)` → runs inside `Document::Create` and `Document::Update` for every `reference` field with `dangling: false`. The existence and `filter` lookup delegates to `Document::List.call(auth_context:)`, so the target doctype's read grant and read scope apply. A target the caller cannot read is refused with the same `reference_filter_mismatch` code as a missing one — the reference check never answers 403 and never reveals which ids exist. A `dangling: true` field skips the lookup entirely. See [`doctype-system.md`](doctype-system.md) → Reference existence check.
- `Audit::List.call` — document-history scope → the class gate (`ReadEnforcer.read_denied?`, 403) then `ReadEnforcer.authorized?` (404); global scope → wildcard `read` permission
- `Audit::Rollback.call` → `WriteEnforcer.authorize_update(db, domain, doc_type, doc_id, auth_context)`
- **Artifact upload** → `auth_context.account_id` is used as `created_by` (no separate enforcer; artifact storage is a simple INSERT). The route rejects the system bypass (403) and the anonymous principal (401) — the anonymous fallback would otherwise open a write channel no role permission governs.

### HTTP integration

Every HTTP route extracts the `AuthContext` via `Helpers.auth_context(env)` and passes it to the underlying service call. The `AuthHandler` middleware (registered before routes) decodes the JWT, loads the active role, and sets `Fiber.current.auth_context`. When auth is disabled (test mode), `Helpers.auth_context` returns `AuthContext.system`.

**The anonymous fallback.** A protected route that receives **no credential at all** does not answer 401. The handler loads the seeded `iam.Roles.anonymous` role (one indexed read on `projections`) and pins `AuthContext.anonymous(role)` on the fiber; the request then runs through the standard enforcers, so the anonymous role's read grants are the public API surface. The role document is the feature's only switch:

- Grants on `iam.Roles.anonymous` are editable in the role editor like any other role. The seed ships read on `core.Currency` (the money registry public clients resolve).
- Deleting the role (or its absence on a fresh install without seeding) re-disables the fallback: the handler answers 401 — fail closed.
- A **presented but invalid** credential (bad signature, unknown role, inactive app, failed DPoP check) always answers 401 — a broken token never downgrades to the anonymous principal. Only the complete absence of a credential engages the fallback.
- The fallback lives in the HTTP middleware only. The WebSocket route (own auth, `4401` close), the MCP surface (own bearer verification), and the identity routes (`require_account` reads the JWT `sub` → 401) never run under the anonymous principal.
- Existing `account_id == "anonymous"` guards keep the rest of the system closed: assistant access is refused, no usage-ledger rows are written, and account-management routes answer 401.

**Role content cache.** Every role lookup — authenticated JWT, anonymous fallback, static API key, login, refresh, MCP dispatch, OAuth consent, assistant gate — reads `iam.Roles` content through `IAM::Helpers.find_role_content`, which serves from the process-local `IAM::RoleStore` cache. The contract mirrors the doctype definition cache: `Event::Subscriber::RoleCache` evicts the mutated role's entry on every `fanout:iam.Roles:*` message (create, update, delete), and entries reload past `cache.staleness_ttl_s` when a fanout is lost (`0` disables the bound). The process cache is installed by `main.cr` for the server command only — CLI commands and the spec suite read through uncached (`PassThrough`), so a truncated projections table never serves stale roles mid-suite. Cached content is shared read-only across fibers; a mutation's visibility to concurrent readers is bounded by the Pub/Sub round trip, exactly like the doctype definition cache.

The critical safety invariant:

- **`AuthHandler.enabled? == true` and fiber-local is nil** → `Helpers.auth_context` returns `AuthContext.denied` (fail-closed). Every enforcer check on a denied context returns denial.
- **`AuthHandler.enabled? == false`** (test mode) → `Helpers.auth_context` returns `AuthContext.system` so tests run unrestricted.

The `AuthContext.system` values used as defaults in service signatures ensure that internal callers (migrations, background jobs, specs) continue to work without passing an explicit context — but when called from the HTTP layer, the extracted context is never the bypass variant unless auth is deliberately disabled.

### Enforcement rules

- **Layer-1 app-grant pre-check** (Phase 3). When `AuthContext#app_grant` is present (an app-scoped identity), every read / write / action enforcer entry point first consults `AuthContext#app_grant_permits?(action, domain, [doc_type])` and denies if it returns false. A present-but-empty `EffectiveScope` denies — fail-closed. When `app_grant` is `nil` (every non-app request), the pre-check is a single nil test and the rest of the enforcement flow is unchanged. See [`app-system.md`](app-system.md#layer-1-enforcement-phase-3) for the full contract. Resource scope (named scopes, context sets) is **not** intersected with the grant — the grant narrows which `(domain, path, action)` may be attempted at all; the role's scope predicates continue to apply unchanged. The audit global list applies the ceiling as a hard denial for app-scoped callers (see [`audit.md`](audit.md) → Authorization modes): a grant names one concrete domain, so no grant can cover the cross-domain view.

- **`ReadEnforcer`** — enforces reads (single document and list):
  - System actions (`Principal::System`) bypass.
  - **Class-level denial first** (`read_denied?` / `list_denied?`): a caller that holds no read permission on the doctype at all — role denial, or the layer-1 app-grant ceiling — answers 403 on the primary read surfaces. See [Class-level vs row-level denial](#class-level-vs-row-level-denial).
  - Loads the active role; a grant holder that cannot see a specific document answers the non-disclosing 404 — an inaccessible document is indistinguishable from a missing one.
  - Expands the permission's `scope` alias against the target doctype definition (fetched via `Doctype::DefinitionStore`; cached per request). Resolves any `$<context_set>` references inside the named scope's `where` via `ContextResolver`. Evaluates the row through the shared single-row gate (`EnforcerSupport.row_authorized?`): the row must exist, be live, and satisfy the scope predicates compiled to SQL by the same `RBAC::ScopePredicateSql` the list path uses. A missing row answers the same non-disclosing denial as an out-of-scope row.
  - For list queries, injects the expanded `where` as SQL WHERE fragments (one OR-clause per matching permission). A scoped list stays scope-narrowed, possibly empty — row-level scoping never turns into a 403.
  - **`parent_authorized?`** gates nested child routes: before listing or reading a child, the immediate parent document is checked for read access (named scope on the parent doctype resolved, existence + not-deleted verified in one SQL statement). A class-level read denial on the parent doctype answers 403; a grant holder that cannot see the parent gets the non-disclosing 404. This makes "read a subset of parents ⇒ read every active child of those parents" expressible: a scoped permission on the parent doctype is honored even when the child doctype is unscoped. The child grant itself resolves on the composition path (a prefix path), so a caller with **no** child grant still reads the children through the nested route — the parent line covers `domain.Parent.Child`. The flat child route checks the bare `domain.Child` path and stays refused with 403 for the same caller. The line on the parent doctype is what admits the child read; it is not a special case for scoped callers.
  - Applies a field-level read mask based on `visible_tags` on serialization.

- **`WriteEnforcer`** — enforces writes (create, update, delete, named action):
  - System actions bypass.
  - Create: the row does not exist yet, so `scope` is **not consulted** at create time. A matching `create` permission alone authorises the action; row-content rules belong to Lua `create(ctx)` lifecycle hooks (the `core.DocumentView` domain-editor gate) or — when the persist path bypasses hooks — a Crystal gate in the service (`Domain::Editors.authorize_doctype_create?` in `Doctype::Create`, `Domain::Editors.authorize_draft_from?` in `Domain::Draft.create_from` — the draft-from-live route — see [`domain-editors.md`](domain-editors.md)). The hook receives `ctx.actor` (identity, role, the create permission's scope alias, and the caller's resolved context sets) so it can force field values the role author intended (e.g. `$mine` → `author_id = ctx.actor.id`) and call `ctx.error(...)` to reject rows that don't meet constraints RBAC cannot express. See [Lua Engine → ctx.actor](lua-engine.md#ctxactor).
  - Update/Delete/Action: the target document must satisfy the permission's expanded named scope. **Each action is checked against its own permission `action` value** — `update`, `delete`, or the named action. Delete does NOT reuse the `update` permission; a role that may update but not delete must declare a separate `delete` permission. The matching hooks likewise receive `ctx.actor` with the scope alias of their own action's permission.
  - Any failed assertion or missing permission → 403.

> **`app.App` (Phase 1):** app registration uses the standard model with no special-case action. The seeded `admin` and `editor` roles (`create`/`update`/`delete` on `*.*`) can manage apps; `viewer` (`read` on `*.*`) can read but not write. A `manage_apps` gate is deliberately absent in this phase — see [`doc/backend/app-system.md`](app-system.md#rbac).

> **`core.SystemSettings` (runtime settings):** the editor and viewer seeds carve the doctype out of their wildcard grants — `except: [core.SystemSettings]` on the editor's `create`/`update`/`delete`/`read` lines and the viewer's `read` line — so the default posture is admin-only (settings expose infrastructure details app-facing roles do not need; see [`system-settings.md`](system-settings.md)). A bespoke operator role can still be granted `read`/`update core.SystemSettings` explicitly. The Lua lifecycle script refuses every create except the seed principal and every delete, for everyone.

### Class-level vs row-level denial

Every denial belongs to one of two classes, and the answer follows the class.

A **class-level denial** means the caller holds no permission for the operation on the doctype at all — the role's permission map has no matching line, or the layer-1 app-grant ceiling refuses. Knowing that a doctype exists is acceptable; document existence is not. The primary document surfaces answer a class-level denial with 403, the same answer the write gates already gave:

| Surface | Gate consulted | Answer |
|---|---|---|
| Flat list, count and field aggregates | `ReadEnforcer.list_denied?` | 403 |
| Single-document read | `ReadEnforcer.read_denied?` | 403 |
| Nested child route parent gate | `ReadEnforcer.read_denied?`, then `parent_authorized?` | 403 / 404 |
| Sidecar host gate and sidecar read grant | `ReadEnforcer.read_denied?` / `sidecar_authorized?` | 403 |
| Audit document history | `ReadEnforcer.read_denied?` | 403 |
| Export | `ReadEnforcer.list_denied?` | 403 |
| Update / delete / named action | `WriteEnforcer.action_denied?` | 403 |

Three enforcer methods report the gate state as pure permission arithmetic — no database access, no row scope:

- `ReadEnforcer.list_denied?(domain, doc_type, auth_context, authorize_path = nil)` — true iff the read gate is `Denied` on a flat, non-metadata doctype. System and preview principals answer `false`.
- `ReadEnforcer.read_denied?(domain, doc_type, auth_context, authorize_path = nil)` — true iff the read gate is `Denied`; keeps the B-86 structural-metadata carve-out, so a caller whose grants reach structural rows reads them through the metadata gate. It drives the single-read 403, the nested parent gate 403, the sidecar host gate, the audit document-history 403, and the aggregate no-field answer.
- `WriteEnforcer.action_denied?(action, domain, doc_type, auth_context, authorize_path = nil)` — true iff the action gate is `Denied`. It drives the update / delete / named-action split: no permission for the action on the doctype at all → 403; a scoped caller whose row check fails (or the row is missing) → 404.

A **row-level denial** means the caller holds a grant (allowed or scoped) but cannot see the specific document — the row misses the permission's scope, or the row does not exist. Row-level denials answer the non-disclosing 404: an inaccessible document is indistinguishable from a missing one. This is the contract that protects documents with manually assigned (enumerable) ids.

`ReadEnforcer.list_where_clauses` still emits `1=0` on a denial, but it serves only the composed fan-out surfaces (`Document::Backrefs`, `Document::Resolve`, `Artifact::Refs`, the audit child feed): there, one unreadable doctype must narrow to nothing instead of failing the whole response. The structural metadata doctypes (`core.DocType`, `core.Domain`) keep the B-86 metadata-gate contract: their lists never answer 403 (see Definition and domain visibility below).

### Field-level visibility

Fields carry free-form sensitivity `tags` (defined on `FieldDefinition`). The active role declares `visible_tags` — only fields whose tags are all present in `visible_tags` are visible. Default is `["default"]` (fail-closed: untagged fields are visible, tagged fields require explicit inclusion). The wildcard tag `["*"]` emits all fields.

A field aggregate runs the tag check only for a caller that holds a read grant on the doctype. On a non-metadata doctype, a caller with no read grant at all answers 403 before any field check runs (`ReadEnforcer.list_denied?` — see Class-level vs row-level denial above). The structural metadata doctypes keep the empty-set aggregate for every field name — their lists never answer 403 (B-86), and `ReadEnforcer.read_denied?` reports the gate state (pure permission arithmetic, no database access); `Document::List` serves `Aggregate.empty_field_result` for it.

### Definition and domain visibility (metadata gate)

`core.DocType` definitions and `core.Domain` rows are render-time metadata: the application builds the sidebar nav, every form, and every route load from them. A role that holds grants on a doctype's documents but no `read` line on `core.DocType` used to resolve an empty definition registry — every granted surface answered a misleading 404 (B-86).

When the generic read gate on `core.DocType` or `core.Domain` is **Denied** — the role holds no `read` line on the metadata doctype at all — `ReadEnforcer` consults `RBAC::MetadataGate` (`src/rbac/metadata_gate.cr`), pure permission arithmetic on the row id, no database access. A row is served when the caller holds any of the four reserved actions on what the row describes:

| Row | Served when the role holds any of `read`/`create`/`update`/`delete` on |
|---|---|
| `core.Domain` row `{domain}` | any doctype inside `{domain}` — the line's domain segment matches, or the line is wildcard-domain |
| `core.DocType` row `{domain}.{Doctype}` | that doctype — a line on `{domain}.{Doctype}`, a domain-wide line on `{domain}`, or a wildcard-domain line, minus `except` carve-outs |

Rules and edges:

- **Reading a doctype implies reading its configuration.** A nested route under `core.DocType` whose composition path is `["DocType", "CollectionView"]` or `["DocType", "DocumentView"]` passes the child gate when the caller holds a reserved action on the doctype the path descends from (the root `core.DocType` row id) — the same arithmetic as the definition row itself. Lists, single reads, and the row scope all follow: the configuration belongs to the doctype, so a reader of the doctype reads all of it. The rule is restricted to those two children by an explicit allow-list (`MetadataGate::DEFINITION_CHILDREN`); a doctype's other composition children and its sidecars are document-plane and keep their own grants. Writes are unaffected — creating or editing a view still needs its own `create` / `update` / `delete` grant.
- A line targeted at the structural doctypes themselves (`core.Domain`, `core.DocType`, or a nested path under them) is definition-plane, not document-plane: it implies no document surfaces to render and never unlocks structural visibility. A caller holding only such lines keeps the fail-closed empty answer (a write-only structure role sees no domains and no definitions, exactly as before).
- A line on a nested path (`hr.Employee.Comment`) exposes no definition — `Permission#matches_path?` prefix semantics reject it for the parent definition, so lists and single reads agree.
- `except` carve-outs subtract with their normal prefix semantics: a two-segment entry (`iam.Roles`) removes that definition; deeper entries subtract child rows of a doctype, never the definition.
- **The metadata gate is a union with the generic gate, so it is monotonic — more permissions never remove visibility (B-123).** A row is readable when the generic gate allows it OR the metadata gate reaches it. On a **`Denied`** gate the metadata gate alone decides (the total-absence case). On an **`Allowed`** gate the generic path already serves every row. On a **`Scoped`** gate the scope clause and the metadata clause are OR-ed, so a scoped `read core.DocType` line (e.g. `$domain_editor`) can no longer hide a definition the caller's document grants reach — the definition list keeps the granted doctype and its pages resolve.
- Single reads (`authorized?`, `parent_authorized?`) and lists (`list_where_clauses`) share the rule, so counts and rows stay consistent; `read_denied?` mirrors it, so field aggregates over the structural doctypes answer the same gate state their lists do.
- The definition-child rule reaches lists and single reads through the same three entry points: `list_denied?`, `read_denied?`, and `authorized?` each take an optional `authorize_root_id` — the `core.DocType` row id the nested route descends from. `RestRoutes` passes the aggregate root on every nested GET, so `GET /Api/core/DocType/:id/collection_view` and `.../document_view` answer `200` for a role holding only `read {domain}.{Doctype}`.
- Preview principals never reach the gate (the `PreviewEnforcer` owns draft domains). The same holds for `ReadEnforcer.readable_doctypes` — it branches on `preview?` before the permission walk (`can?` raises on a preview principal) and returns only the bound draft's doctypes (B-99). The Layer-1 app-grant ceiling applies on the metadata path itself — an app identity reads structural metadata only when its grant permits `read` on `core.DocType` / `core.Domain`. For non-metadata doctypes, `readable_doctypes` applies the full gate — the app-grant ceiling included — so the cross-doctype read surfaces (`Document::Backrefs`, the MCP `search_documents` tool) skip a ceiling-denied doctype instead of failing on it.
- The non-disclosing posture is unchanged: a caller with no grant on a doctype gets no row for it — the definition is absent, not a 403.
- Definition content (Lua `script`, named scopes, migrations) rides the row. This matches the exposure every wildcard-`read` role already has; it is a documented decision, not an oversight.

The frontend consumes this unchanged: `DoctypeRegistry` lists `core.DocType` and `buildNavModel` lists `core.Domain` — both now resolve for scoped roles, so granted doctypes render their pages and appear in the nav.

### Named-action conventions

The grammar admits arbitrary named actions alongside the four reserved ones (`read`, `create`, `update`, `delete`). Two subsystem-level conventions are codified as named actions the doctype author opts into by declaring them in the doctype's `actions` map (or, for IAM, by referencing them in route gates). Both reuse the existing permission line shape — no grammar extension was added for them.

| Action | Declared on | Semantics |
|---|---|---|
| `publish_artifact` | any doctype whose attachments may be exposed to the internet (e.g. `cms.Asset`) | Authorises minting a permanent artifact grant against an owner row whose `{domain}.{Doctype}` matches the permission's `on`, scoped to `doc_id`. A doctype that does not declare the action has no publishable attachments — the default. See [`doc/backend/artifact.md`](artifact.md) for the artifact subsystem. |
| `provision_credentials` | `iam.Account` | Authorises the operator credential-bootstrap routes: `POST /Api/iam/accounts/:id/temporary-password`, `POST /Api/iam/accounts/:id/invite`, and `GET /Api/iam/accounts/credential-states`. These routes mint and email credentials — the most sensitive surface in the identity domain. See [`doc/backend/iam.md`](iam.md) → `Facet::IAM::Invite`. |

A role must declare `publish_artifact` on the leaf doctype to mint permanent grants for that doctype's owner rows; `read` alone is insufficient. A role must declare `provision_credentials` on `iam.Account` to operate the credential-bootstrap routes; the seeded `admin` role covers it through its `*` on `*.*` wildcard — any other role needs an explicit permission line.

The role editor surfaces route-gated actions from a static table in the frontend — `ROUTE_GATED_ACTIONS` in `frontend/src/lib/components/features/admin/rbacModel.ts` — because a doctype definition cannot carry them: a declared action must export a Lua function of the same name (`src/doctype/script_validator.cr`) and would become callable as a document action. Extend that table when a new route-gated action is introduced.

A second family of named actions lives on the wildcard target `*.*` and gates the transversal operator surfaces — artifacts belong to no domain, so no doctype-scoped line can express them. All three are deny-only-`Denied` (a scoped result passes; artifacts are not RBAC doctype targets):

| Action | Semantics |
|---|---|
| `revoke *.*` | Revokes any artifact grant through `DELETE /Api/core/artifacts/grants/:gid` (the publisher privilege on the owner document is checked first and stays publisher-scoped). |
| `download *.*` | Downloads any artifact through the download gateway's operator path when provenance denies — the bytes behind the `read *.*` artifact listing. Does not ride on `read *.*`; field view tags stay meaningful inside document views. See [`artifact.md`](artifact.md) → Download gateway. |
| `purge *.*` | Force deletes an artifact (`DELETE /Api/Artifacts/:id`) — the audited security deletion. See [`artifact.md`](artifact.md) → Force delete. |

**App-facing roles must not hold `provision_credentials`, `mfa_disable`, or any of the operator actions above.** An app JWT carries an elected role (`POST /OAuth/authorize` — see [`app-system.md`](app-system.md)). A role that an external app can elect must not include these actions: with `provision_credentials` the app could mint temporary passwords and invite links over the API, with `mfa_disable` it could strip an account's second factor, and with `revoke`/`download`/`purge *.*` it could revoke URLs, read bytes, or destroy artifacts across every domain. Keep all five actions on human-operator roles only. The seeded roles already comply — the production seed gives only `admin` the covering `*` on `*.*` wildcard; no other seeded role declares any of them.

### Spec pattern

Every spec that calls a document service passes `AuthContext.system` explicitly. This keeps the bypass intent visible and makes it easy to write RBAC-specific specs that pass `AuthContext.authenticated(...)` with a test role instead:

```crystal
# Existing spec — full bypass
result = Facet::Document::Create.call(db, domain, doctype, body, Facet::RBAC::AuthContext.system)

# New RBAC spec — scoped access. The doctype must declare the `mine` named
# scope for the enforcer to resolve the alias.
perm = Facet::RBAC::Permission.new(
  action: "update", domain: "crm", path: ["Project"], scope: "$mine"
)
role = Facet::RBAC::ActiveRole.new(
  role_id: "self_editor", visible_tags: Set{"default"}, permissions: [perm]
)
ctx = Facet::RBAC::AuthContext.authenticated("account_1", role)
result = Facet::Document::Update.call(db, domain, doctype, doc_id, patch, ctx)
```

## Authoring-time validation

`RBAC::Validator` runs at document-create/update time and rejects malformed authorization definitions hard (fail closed, never a silent empty set):

- **`validate_permissions`** — invoked from `Document::Create.call` and `Document::Update.call` for `iam.Roles` documents. Checks path format, wildcard path rules, and that any named-scope alias resolves to a scope declared on the leaf doctype definition (fetched via `Doctype::DefinitionStore`). Unknown aliases or unregistered doctypes are rejected at authoring time. `except` entries are validated at parse time (`Permission.from_json`) and surface here as per-line errors.
- **`validate_named_scopes`** — invoked from `Doctype::Create.call` and `Doctype::Update.call`. For each named scope on the doctype, checks that `where` field names exist on the doctype (or are the reserved `$parent_id` token), and that `$<context_set>` value references resolve to context sets declared in the same domain.
- **`validate_context_set_definitions`** — invoked from `Document::Create.call` and `Document::Update.call` for `core.Domain` documents. Checks two things: (1) each context set's `select` field and `where` keys are SQL-safe identifiers matching `^[a-z_][a-z0-9_]*$` or `^[a-z][a-zA-Z0-9]*$` (or the reserved `$parent_id`/`$doc_id` tokens) — these are interpolated into `content->>'field'` / `projections.id` SQL expressions at resolution time and are a SQL-injection vector otherwise; (2) the dependency DAG declared in `core.Domain.context_sets` is acyclic.
- **`scoped_create_warnings`** — the scoped-create lint. A permission line whose action is the literal `create` and whose scope is non-empty is legal — the scope is an intent channel that a Lua create hook (`ctx.actor.scope`) or a Crystal create gate reads — but the enforcer never applies it at create time (no row exists). The lint returns one warning per such line; it is advisory and never blocks the write (an error would break the intent-channel lines the seeded roles rely on). It surfaces on `Domain::Check` for the `iam` domain (`:rbac` category, one warning per line, prefixed with the role id). The `$all` sentinel collapses to unrestricted at parse time and never warns; wildcard actions are ignored; malformed lines are skipped (they are `validate_permissions` errors).

## Role authority (IAM writes)

Every caller-controlled write on `iam.Account` and `iam.Roles` — document create, update, and delete, named actions, and rollback transitions — passes through one transition API: `RBAC::RoleAuthority.authorize_transition(db, operation, domain, doc_type, previous, resulting, auth_context)`. It returns a `403` `ServiceError` with structured details, or `nil` when the transition is allowed. The guard runs after normalization and structural validation, is independent of route-level `skip_authorization`, and only the System principal bypasses it (System is the repair path; Preview keeps its existing draft-domain bypass).

Rules (fail closed — a missing or malformed value denies the Real write):

- **The elected active role is the caller authority.** Roles never merge; a caller holding admin and editor has only the elected role's authority.
- **Caller level** — read from the elected role's `level` (0–100, required on the role definition). `nil` level → deny.
- **Account assignment** — every role in the final `roles` array must exist, be live, and have `level ≤ caller level`; `default_role`, when present, must be a member of `roles`. **Same-level lateral assignment is allowed by decision**: a caller may assign an existing role at or below its level even when that role holds permissions the caller does not.
- **Target protection** — a caller cannot update, delete, or action an account whose current ceiling (highest assigned role level) is above its level, nor a role whose current level is above it. A narrowing-only PATCH is still a write; this blocks the `admin.level 100 → 30` lowering attack before any assignment check.
- **Role authoring** — the resulting level must not exceed the caller level; every resulting permission line must be implied by a line from the previous role or the caller's role (`Permission#implied_by?`); new visible tags must sit inside the union of previous and caller tags; the assistant power pair (assistant channel + budget) must be implied by ONE baseline, never a merge of two (no channels is the narrowest state; unlimited budget is broader than every numeric budget — the assistant channel rides the `connectivity` list, so the same containment covers a widening from `[]` to a channel-carrying list); and any unrecognized role-power field the write adds or changes is denied. `name` and `description` are safe metadata. The known power fields are `name description level permissions visible_tags connectivity assistant_token_budget` (`KNOWN_ROLE_FIELDS`).
- **Assistant budget lock recovery** — the guard's baselines are the caller's elected role and the previous role content. When a caller writes its **own** active role, both baselines are that same role: a lowered `assistant_token_budget` becomes its own ceiling and no raise or clear can pass. The escape: a write that targets the caller's own active role may restore the budget to what the caller's **other** roles imply (read from the account projection). The restore is bounded by the widest other enabling role — `nil` (unlimited) when any of them is unlimited, otherwise their maximum budget, the same value `Assistant::Access.effective_budget` already enforces account-wide, so the escape cannot raise what the account may spend. The `iam.Roles` write permission, the caller level, and target protection still apply; the escape never extends to a role the caller does not elect. A caller holding no wider other role stays locked — System is the repair path, or direct SQL repair of `assistant_token_budget`. The SQL fix alone does not take effect: the process role cache serves the old budget until eviction, and eviction happens only on `fanout:iam.Roles:*` events (`IAM::RoleStore`, `Event::Subscriber::RoleCache`) — a denied write emits no event. Land one successful content-changing PATCH on the role (any field, for example `description`) to evict the cache. Reads past `cache.staleness_ttl_s` (default 300 s) reload the row anyway; `0` disables that bound.

`Permission#implied_by?(holder)` is pure conservative arithmetic (in `src/rbac/permission.cr`): holder action `*` or exact equality; the new `on` reach contained by the holder reach (wildcard and prefix semantics); every holder `except` entry intersecting the new reach also excluded by the new line; scope containment (unrestricted holder implies any scope; otherwise the new alias set is non-empty and contained). Unsupported or uncertain shapes return `false`.

## Field-level visibility (recursive)

`RBAC::FieldVisibility` is the one schema walker behind every field-tag question:

- **Reads** — `mask_content` (via `ReadEnforcer`) omits invisible fields at every nesting level: object `properties`, array `items`, dictionary `dictionary_value`. If a parent is invisible, the whole subtree is invisible. Unknown content keys are omitted for Real principals (fail closed against historical or junk fields); System and Preview see content raw.
- **Writes** — `WriteEnforcer.authorize_field_writes(definition, submitted, auth_context)` walks the caller-submitted body (full document on create, patch on update) and refuses (`403`, naming the content path) every write into an invisible field. An explicit `null` is a write. The guard runs on the raw caller body before any format validation, on create and update alike — a caller whose role cannot see a field never learns the field's type contract from a 422. Trusted lifecycle work — defaults, computed fields, replication, hooks — may still populate invisible fields.
- **Transitions** — `WriteEnforcer.authorize_field_changes(definition, before, after, auth_context)` compares two content states and refuses transitions that land inside invisible fields. Path resolution is shape-aware (`Doctype::FieldPath` in `src/doctype/field_path.cr`), so a change that lands as a member sub-path — a money `value`, a dictionary key, a secret marker member, any segment below a free-form shape — is judged by the field or descriptor that owns it, at every level of the descent; an invisible owner or descriptor refuses the transition. A path that does not resolve against the definition stays out of the guard (doctype validation rejects unknown writes, and a transition guard must not block a rollback on historical junk). `Document::Action` runs the guard on the final diff before persistence (action arguments are not document fields, but the resulting content diff is subject to the same refusal). `Audit::Rollback` runs it on the actual current-versus-replayed transition — not the selected mutation's own diff — for both document and cluster rollback (the cluster preflight refuses the whole undo on one invisible transition).

Visibility semantics (identical on every surface): System and Preview see every field; a Real caller with the wildcard tag `*` sees every field; otherwise a field is visible when all of its tags (`field_def.tags || ["default"]`) sit in the active role's `visible_tags`.

## Role documents (`iam.Roles`)

The `level` field is required on create (integer 0–100, no default). Write responses present role content through the shared presenter (`Document::Presenter`), so a masked caller never receives invisible fields back from a create/update/action/rollback response — the same shape a masked GET returns.

**The `name` grammar is `^[a-z][a-z0-9_]*$`.** The seed definition's field pattern (`data/seeds/iam.Roles/definition.yml`) enforces it at write time: one lowercase letter first, then lowercase letters, digits, and underscores. No hyphens. A role name is an identifier, not a URL segment — the account's `roles` array stores `iam.Roles.<name>`, and login resolves it with an exact id match. The identifier family uses underscores everywhere: role names, RBAC context-set names (`^[a-z_][a-z0-9_]*$`), and child relationship names (`Doctype::Validation`). URL-facing names are the split: `core.Domain.name` (`^[a-z][a-z0-9\-]*$`) and `app.App.slug` (`^[a-z0-9][a-z0-9-]*$`) allow hyphens because they appear in paths. The split is deliberate.

**Permissions and connectivity are two layers.** Permissions decide what a role may reach inside the application — the doctypes, actions, and scopes enforcement consults on every call. The `connectivity` field (array of string, closed vocabulary `mcp` / `webhook` / `api` / `assistant`, default `[]`) decides which **programmatic doors** the role may open at all: MCP agents (consent + refresh), outbound webhook authoring and delivery, API-key issuance and verification, and the workspace + per-app assistant. An empty list is a browser-only role — the core application and hosted apps; browser sessions and delegated OAuth app tokens are never gated by the field. Every channel gate reads the live role content (fail closed on a missing or malformed list) and the system bypass stays unrestricted. Enforcement is per channel: API keys die on their next request, MCP sessions at the next refresh, webhook deliveries at the next event, the assistant per request — derive, never mark.

## Key design decisions

- **One active role per request, roles never merge.** The effective permission set is exactly one role's permission map. Cross-role scope reconciliation has no non-surprising answer and is deliberately absent.
- **Trusted bypass tier.** `ContextResolver`, `AccountLoader`, raw `Client.fetch_projection`/`fetch_content`, and `Principal::System` bypass RBAC entirely.
- **AuthContext unifies identity and authorization.** The same token carries the caller's ID (used for mutation logging) and their role's permission map (used for enforcement). There is no separate `actioner_id` parameter — it's derived from `auth_context.account_id`.
- **Enforcement lives inside the document services, not in the HTTP layer.** Every caller (HTTP, migration, background job, console) hits the enforcer. The HTTP layer only constructs the `AuthContext`; it doesn't contain authorization logic.
- **Context set scope resolution is lazy and memoized** per request per domain, so repeated references within a single request see a consistent snapshot.
- **Named scope alias expansion happens at enforcement time, never persisted.** `Permission#to_h` preserves the alias verbatim. Redefining a named scope's `where` propagates to all roles that reference it on the next enforcement.
- **Roles cannot author custom query predicates.** A permission's `scope` is either `$all` or references a named scope declared on the doctype. This is the Rails named-scope discipline: the doctype author declares the predicates once; role authors pick from a catalogue.
- **Field tag visibility is tag-intersection-based**: a field is visible when all of its tags are in the role's `visible_tags`. Tags are free strings; `["*"]` is the admin escape hatch.
- **A role's `name` is immutable after creation.** The `iam.Roles` document id is `iam.Roles.<name>` (`aggregate_root: true`) — the dotted form the account's `roles` reference array stores and login resolves with an exact id match (`IAM::Helpers`). A rename would desync the id from the name, so the `update` hook (`data/seeds/iam.Roles/script.lua`) refuses any PATCH that carries `name`; re-create the role under the new name instead. The same rule applies to `app.App`'s `slug`. The name grammar is the underscore-identifier set — see Role documents above.
- **Scope validation at authoring time is a hard error** — unknown context set references, unknown named-scope aliases, and out-of-domain references are rejected at doctype creation/update time, never a silent empty set.
