# Plan — Per-domain database placement (phase target 2)

Status: **draft — awaiting review.** No code written. Section 2 was
re-verified against the tree on 2026-10-25. This is the follow-up
plan the read/write segregation work promised (its phase target 2 — per-domain
placement, and the phase breakdown's §9 "After this plan"). The segregation is
implemented; the pin model and the `database.cluster` grammar are documented in
[`../backend/workflow.md`](../backend/workflow.md) (Database quirks) and
[`../backend/config.md`](../backend/config.md).

The read/write segregation (phases 1–5) is **implemented**: the pin model, the
cluster config grammar, per-pool hooks, the tripwire, and the doc set are in
place. This plan builds on that mechanism to route **specific domains to
specific databases** — the same `cluster.databases[].resources` route table,
now actually used by the entry points.

---

## 1. Summary

The cluster route table already knows how to hold resources per database:

```yaml
database:
  cluster:
    databases:
      main:
        url: !env DATABASE_URL
        resources: ["*", "core", "iam"]      # control plane + everything unrouted
      hr:
        url: "postgres://db2:5432/facet"
        resources: [hr, crm]                  # two domains, one physical database
```

`Database.resolve(resource)` already picks the entry that lists a resource, or
the `*` entry. The gap is not the config — it is that **no entry point passes
a resource**, so every request resolves to `*`. Making per-domain placement
real is three pieces of work:

1. **Thread the resource id into the entry points.** Each HTTP route, job,
   cron task, and subscriber asks for the connection with the domain it
   operates on (`with_db(:read_only, domain)`, `with_transaction(mode, domain)`).
2. **Tighten pin keying by pool.** Today a fiber holds one pin per mode, not
   per database. A request that touches two databases (a document + the
   `core`/`iam` reference data it reads) would wrongly reuse the first
   database's pin. Pins must become per-pool, with reuse resolving the pool
   first (design doc §4.3).
3. **Provision and migrate every database.** D6 — schema duplicated on every
   database — needs a per-database migration path, since `Migrate.run` and
   `db_reset` today only know `DATABASE_URL`.

Plus the two coupling lists from the design doc §2.2:

- **Kind 1 — reference data** (`core.Domain`, `core.DocType`, `iam.Account`,
  `core.Currency`) read on every request. Decide placement (§2.2, Q2): the
  proposal is a control-plane database holding `core` + `iam`, routed by
  explicit resource on those specific reads.
- **Kind 2 — cross-domain features** (sidecars, replication, global audit,
  artifacts, jobs, account-scoped side tables). Each gets an explicit routing
  or placement rule, one concern at a time.

## 2. Current state (verified against the code)

| Fact | Where |
| --- | --- |
| `enum Mode` (`ReadOnly` / `ReadWrite`), `with_connection(mode, resource)`, `with_db`, `with_transaction(mode, resource)`, plus the explicit-connection `with_transaction(db, ...)` form | `src/database.cr` |
| Cluster config records `ClusterConfig` / `ClusterDatabase` / `ClusterReplica` | `src/database/cluster_config.cr` |
| `load_cluster` parses `resources:`, `replica:`, pool sizing; validates one `*`, unique resources | `src/config.cr` |
| `resolve(resource)` → entry that lists it, else the `*` entry | `src/database.cr` |
| Tripwire: `config.test.yml` inits `main` + same-URL `replica:` with enforcement | `config.test.yml`, `spec/spec_helper.cr` |
| Pool/route specs | `spec/database_cluster_spec.cr`, `spec/database_pin_spec.cr`, `spec/database_spec.cr`, `spec/config_spec.cr` |
| **No entry point passes a resource** — ~100 call sites across ~40 families, every one uses the default `"*"`. The only two-argument calls are the definitions themselves | `src/http/rest_routes.cr`, `src/http/auth_handler.cr`, `src/document/routes.cr`, `src/agent_tools/registry.cr`, `src/app/routes.cr`, `src/jobs/worker.cr`, `src/cron/pass.cr`, and the families in §4.1 |
| Pins are single slots per mode (`Fiber#db_rw`, `Fiber#db_ro`); the `Pin` record already labels `database` / `role` for the `db.transaction` span and the checkout counters | `src/fiber_state.cr` |
| Direct cron callers request their own connections (`Cron::Pass`, `MutationCompaction`) | `src/cron/pass.cr`, `src/cron/mutation_compaction.cr` |
| CLI tools init pools two ways: the server boot and the spec helper init from the cluster config; `db_reset` / `seed_core` init a single `DATABASE_URL` pool; reproject inits a sized single-URL pool | `src/main.cr`, `spec/spec_helper.cr`, `src/migrate.cr`, `src/doctype/reproject_cli.cr` |
| Migrations target `DATABASE_URL` only | `src/migrate.cr` |

## 3. The core problem to solve first: pin keying

Today `with_pinned` reuses a pin without checking its database:

```crystal
fiber = Fiber.current
if pin = fiber.db_rw
  return yield pin.connection, pin   # reuses ANY rw pin, whatever database
end
if mode.read_only? && (pin = fiber.db_ro)
  return yield pin.connection, pin
end
```

This is correct for read/write segregation because every request resolves to
one logical database. It is **wrong** once a request can touch two databases.

Concrete case: `GET /api/hr/Contact/...` resolves to the `hr` database for the
document read, then reads `core.DocType` / `iam.Account` reference data on the
same fiber. If those reference reads come from the `core`/`iam` database (a
different pool), the inner `rw` or `ro` request would reuse the `hr` pin.

### Design: pins keyed by pool

A fiber holds one pin **per pool**, not one per mode. Reuse resolves the pool
first, then applies the existing reuse table within that pool:

```crystal
record Pin, pool_key : String, connection : DB::Connection, database : String, role : String

# Fiber holds a map: pool_key => Pin
property db_pins : Hash(String, Pin)?
```

`with_pinned(mode, resource)`:
1. `entry = resolve(resource)` → database entry.
2. `pool = mode.read_only? ? (entry.read_only || entry.primary) : entry.primary`.
3. `pool_key = "#{entry.name}/#{pool.role}"`.
4. Reuse the existing pin for that `pool_key` if present; otherwise check out
   from that pool and pin it.

Within one pool, the reuse table from the design doc §4.3 is unchanged
(`rw` reuses any pin on the same pool; an `ro` request inside a `rw` scope on
the same pool reuses the `rw` pin — reads see the outer scope's uncommitted
writes). Across pools, the fiber simply holds a second pin.

No new `Pin` field is needed: the record already carries `database` and
`role` (they label the `db.transaction` span and the checkout counters), so
the map key is `"#{database}/#{role}"`.

This is exactly the "pin keying tightens" sentence of the design doc §4.3.

## 4. Design

### 4.1 Threading the resource id into entry points

The resource id is **the domain the request operates on**. It is already
available where the connection is requested:

| Entry point | Resource source |
| --- | --- |
| HTTP document routes (`/api/:domain/...`) | `env.params.url["domain"]` |
| REST routes (children, sidecars) | the target domain (`t_domain`, `sidecar_domain`) |
| `AuthHandler` context build | `"core"` / `"iam"` — reference data lives on the control plane |
| Audit (`GET /api/Audit`) | `"*"` (global) or an explicit `$audit` tag |
| Jobs worker / handlers | the job's target domain |
| Cron tasks | the concern's domain, or `"*"` |
| Event subscribers | the source event's domain |
| Agent tools (`src/agent_tools/*`) | the tool call's `domain` argument |
| App platform — routes, hosting, deploy, API keys (`src/app/*`) | `"app"` — the family reads and writes `domain = 'app'` rows |
| Import/export and portable routes + job handlers (`src/import_export/*`, `src/domain/portable/*`) | the run's single domain (§4.3) |
| WebSocket collection subscriptions (`src/websocket/*`) | the subscribed document's domain |
| Webhook / hooks / notification consumers (`src/webhook/*`, `src/hooks/*`, `src/notifications/*`) | the event's target domain; the webhook and hook config CRUD is a plain route family |
| Control-plane route families (`iam`, `doctype`, `settings`, system settings, oauth) | `"core"` / `"iam"` |
| Domain-scoped route families (assistant, MCP, index, artifact, domain management) | the route's target domain |
| CLI tools (`iam/*_cli`, `doctype/reproject_cli`, `index/retry_cli`, `artifact/prune`, `artifact/reconcile`) | the concern's domain, or `"*"` |

The `with_db(mode, resource)` and `with_transaction(mode, resource)` signatures
already exist — no API change needed, only call-site arguments. Services keep
taking an explicit `db : DB::Connection` (D4); only entry points request
connections.

### 4.2 Reference data placement (Kind 1)

Reference data (`core.Domain`, `core.DocType`, `core.Currency`,
`iam.Account`/roles) is read through the caller's connection today. With
per-domain databases those reads must target the database that holds the row.

Decision (Q2 proposal): **a control-plane database holds `core` + `iam`**, and
every entry point requests reference reads with an explicit resource
(`with_db(:read_only, "core")` / `"iam"`) so they resolve to the control
plane regardless of the document's own database.

The affected reads are enumerated in the design doc §2.2 Kind 1:
`ScopeContext.load` / `AccountLoader`, `ContextResolver.fetch_domain_content`,
`DefinitionStore.load_from_db`, `Currency::Registry`. These run inside service
code that takes the caller's `db` today. Two sub-options:

- **(A) Route by resource at the entry point** — the entry point opens a
  control-plane pin and passes it to the service alongside the document pin.
  Keeps services routing-agnostic (D4) but threads a second `db` through
  callers that need it.
- **(B) Carry the values in `AuthContext` / process caches** — avoid the read
  entirely on the hot path; caches already exist for doctypes, currencies,
  roles. More work, but removes the second database from most request paths.

The plan proposes **A first**, because it reuses the existing pin mechanism and
the caches already invalidate via Redis Pub/Sub. B is a later optimization if
the read volume demands it.

### 4.3 Cross-domain features (Kind 2) — routing rules

Each item from the design doc §2.2 Kind 2 gets an explicit rule:

| Feature | Rule | Atomicity |
| --- | --- | --- |
| Sidecar create | stays on the **host's** database (writes the sidecar document beside its host) | preserved — one transaction |
| Replication `SyncPull` | reads the **source domain's** database on demand (explicit resource) | n/a |
| Portable export/import | single domain per run → that domain's database; `--into` cross-domain rewrites handled per-doc via explicit resources | per-database txn |
| Global audit (`GET /api/Audit`) | `*` resource (reads the control plane / aggregated view) or a `$audit` tag | n/a |
| `Domain::Drop` / dev watcher | writes `core` rows + tombstones target-domain docs → **cross-database**, drops single-transaction atomicity | accept eventual / best-effort (out of scope for 2PC, §10) |
| Artifact dedup / prune | artifacts live beside their owning document → a per-domain `$artifacts` placement, or an aliased `$artifacts` pool (§4.1 Q3) | n/a |
| Background jobs | jobs enqueue into the caller's database; the worker must poll **every** database's queue (or one control-plane queue) | per-database txn |
| Account-scoped side tables (`notifications`, `account_settings`, `auth_state`) | land in the control-plane database (`core`/`iam`) so account-facing reads are single-location | per-database txn |

These are routing/placement rules, not redesigns — except sidecar create
(stays single-database) and `Domain::Drop` (gives up atomicity), which the
design doc §10 already scopes out of cross-database atomicity.

### 4.4 Provisioning and migration (D6)

Every database in the cluster needs the schema. `Migrate.run` / `db_reset`
currently operate on `DATABASE_URL` only. The plan:

- A `facet migrate:all` (or `db_reset:all`) command that iterates the cluster
  entries' primary URLs and runs the migration set against each. Each entry
  keeps its own `_migrations` table.
- `db_reset` gains a `--cluster` flag (or a separate command) that drops /
  recreates / migrates / seeds every entry's database.
- Back-compat: an absent `cluster:` (or `DATABASE_URL` only) keeps the current
  single-database behavior.

The `_migrations` table is per-database, so the same migration files apply
everywhere. Seeding (`core`/`iam` reference data) runs on the control-plane
database only; domain data seeds into the domain's own database.

## 5. Testing strategy

1. **Pin-keying (pure).** `pg_backend_pid` assertions that two resources on
   one fiber resolve to two pools and hold two pins; a second request for the
   same pool reuses the first pin; the reuse table from §4.3 holds **within** a
   pool.
2. **Route resolution with a real resource.** A spec-scoped cluster with a
   second entry at a different database URL: a document request for `hr`
   resolves to the `hr` database, a `core` reference read to `main`, and a
   request touching both holds two pins.
3. **Cross-database spec.** Using a second real database (created by the spec
   provisioning helper): write a document in the `hr` database, read `core`
   reference data, assert each row lives in the right database.
4. **Migration over the cluster.** `facet migrate:all` applies to every entry;
   `_migrations` tracked per database; `db_reset` recreates all.
5. **Existing suite.** `make test` stays green. The `*`-only tripwire config
   (config.test.yml) means every current spec resolves to `main` and behaves
   as today — the sweep only changes behavior once a per-domain config exists.
6. **Tripwire extension (optional).** A second tripwire that maps one domain
   (`hr`) to a second database so the suite exercises the cross-database path
   in CI.

## 6. Phases

Each phase ends with `make check`, `make test`, and a clean `bin/ameba`.

### Phase A — Pin keying by pool

**Goal.** Pins become per-pool; a fiber holds one pin per pool, and reuse
resolves the pool first. No behavior change while every resource resolves to
one database.

- `src/fiber_state.cr` — replace `db_ro` / `db_rw` slots with `db_pins : Hash(String, Pin)?` keyed by pool.
- `src/database.cr` — `with_pinned` resolves the pool, keys the pin by it, applies the reuse table within it. The `db.transaction` span label and checkout counters keep `database/role`.
- Specs: the reuse table holds within a pool; two pools hold two pins.

### Phase B — Reference data placement (Kind 1)

**Goal.** `core` / `iam` reads route to the control-plane database explicitly.

- Enumerate the Kind 1 reads and give each an explicit resource
  (`ScopeContext`/`AccountLoader`, `ContextResolver`, `DefinitionStore`,
  `Currency::Registry`).
- Decide A vs B (§4.2) with the user; default is A (explicit resource at the
  request).
- Specs: a two-database cluster routes reference reads to `main`, document
  reads to the domain database.

### Phase C — Entry-point resource sweep

**Goal.** Every HTTP route, job, cron task, and subscriber passes its resource.
The inventory has grown since this plan was drafted: the sweep now covers
~40 families (§4.1). Land it family by family, not in one pass.

- Document/REST routes pass `env.params.url["domain"]`.
- Auth handler passes `"core"` / `"iam"` for reference reads.
- Jobs, cron, subscribers pass their target domain.
- Agent tools pass the tool call's `domain` argument.
- The app platform passes `"app"`; import/export and portable pass the run's
  domain; WebSocket subscriptions pass the subscribed document's domain.
- CLI tools pass the concern's domain, or `"*"`.
- Classify each against the Kind 2 rules (§4.3).

### Phase D — Provisioning and migration (D6)

**Goal.** Every cluster database is migrated and seedable.

- `migrate:all`, `db_reset` cluster support.
- Per-database `_migrations`.
- Fold the single-pool CLI inits (`db_reset`, `seed_core`, the sized
  single-URL pool in `reproject_cli`) into the cluster path, or keep them on
  `DATABASE_URL` as a recorded decision.

### Phase E — Cross-domain features (Kind 2) and docs

**Goal.** Each Kind 2 feature has a working routing rule, and the doc set says
what exists.

- Sidecar stays on the host database (verify no change needed).
- Replication, audit, artifacts, jobs, account-scoped tables per §4.3.
- Docs: `doc/backend/config.md` (per-domain example), `doc/backend/http-layer.md`
  (resource per route family), `doc/backend/schema-migration.md` (multi-db
  migrate), `doc/backend/jobs.md` (multi-database polling).

## 7. Open decisions

| # | Question | Proposal |
| --- | --- | --- |
| P1 | Reference data: route by explicit resource (A) or carry in AuthContext/caches (B)? | A first; B later if read volume demands |
| P2 | Jobs: one control-plane queue, or poll every database's queue? | Control-plane queue first (simpler worker); revisit if a domain needs isolation |
| P3 | `$artifacts`: aliased pool, or own database with rows beside the owner? | Aliased pool (§4.1 Q3) for now; placement deferred |
| P4 | Cross-domain writes (`Domain::Drop`, portable `--into`) that break single-transaction atomicity — accept eventual, or keep on one database? | Keep each flow on one database where possible; flag the exceptions (§10) |
| P5 | CI tripwire: add a second domain→database mapping so the suite exercises cross-database in CI? | Yes, as a separate optional tripwire |

## 8. Decision record

| # | Decision | Why |
| --- | --- | --- |
| PD1 | Pins become per-pool, keyed by pool; reuse resolves the pool first. | A request can touch two databases; the current single-slot pins would wrongly reuse a different database's connection |
| PD2 | Resource id = the domain the entry point operates on. | It is already available at every entry point (`env.params.url["domain"]`, auth context, event source) |
| PD3 | `with_db` / `with_transaction` signatures stay unchanged; only call sites add the resource. | The API from phases 1–5 already carries `(mode, resource)` — no new surface |
| PD4 | Services keep an explicit `db`; reference reads get a control-plane pin at the entry point (A). | Preserves D4 and reuses the existing pin mechanism |
| PD5 | Every cluster database carries the full schema; `_migrations` is per database. | D6; reuses the one migration file set |

## 9. Out of scope

- Writes to two physical databases in one operation (no 2PC, no saga). A
  cross-domain flow that needs atomicity stays on one database or accepts an
  eventual step (design doc §10).
- One database per tenant.
- Automatic read/write or resource detection by SQL inspection. Routing stays
  explicit at entry points.
- Reference-data mirroring into every database (a rejected alternative to the
  control-plane placement).

## 10. Relationship to the prior plans

- This is the "per-domain placement" phase target 2 of the read/write
  segregation plan (§3 there), and the phase breakdown's §9. The prior plans'
  design and decisions retired into `../backend/workflow.md` (pin model,
  classification rule) and `../backend/config.md` (the `database.cluster`
  grammar).
- Decisions D6 (schema duplicated), D7 (mode never changes the database), Q2
  (reference-data placement), Q3 (`$artifacts`) all land here.
- Rollback is plain `git revert` per phase. Config back-compat means any
  environment can delete the per-domain `resources:` and return to one pool.
