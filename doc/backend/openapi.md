# OpenAPI Surface

**Files:** `src/http/openapi.cr`, `scripts/gen_openapi.cr`, `doc/api/openapi.json`

The machine-readable API surface: `GET /Api/openapi.json` serves an OpenAPI 3.0.3 document covering the first spec slice. The committed artifact is `doc/api/openapi.json`; CI regenerates it and fails on any drift.

## What v1 covers — and what it does not

The document is a **declarative slice**: paths, methods, summaries, and status codes are hand-maintained in `OpenAPI::DECLARATIONS` (`src/http/openapi.cr`); request and response **shapes stay in `doc/backend/*.md`** — the OpenAPI descriptions point at them rather than carrying full JSON Schemas. Coverage (26 path templates, 36 operations):

| Family | Paths |
| --- | --- |
| Documents | `GET|POST /Api/{domain}/{doctype}` (+ QUERY twin), `GET|PATCH|DELETE /Api/{domain}/{doctype}/{id}` |
| Audit | history (`GET` + QUERY twin, parent and child), rollback (parent, child, global), restore, global list (`GET` + QUERY twin) |
| IAM | `GET /Api/iam/me`, `GET /Api/iam/accounts/credential-states`, `POST /Api/iam/accounts/{id}/temporary-password`, `POST /Api/iam/accounts/{id}/invite` |
| Secrets | `POST /Api/secrets/stage` |
| Import/Export | `POST /Api/{domain}/{doctype}/export`, `POST /Api/{domain}/{doctype}/export_view`, `POST /Api/{domain}/{doctype}/import`, `GET /Api/{domain}/{doctype}/import_export/{job_id}`, `GET /Api/{domain}/{doctype}/import_export/{job_id}/download` |
| Platform | `GET|QUERY /Api/Indexes`, `GET|QUERY /Api/Artifacts`, `DELETE /Api/Artifacts/{id}`, `GET /Api/Artifacts/{id}/grants`, `GET /Api/Artifacts/{id}/references`, `GET /Api/SystemSettings` |

Roles are `iam.Roles` documents — they ride the document CRUD routes; there are no dedicated role-management paths, and the spec says so in `info.description`. Nested-children routes (the REST catch-all), actions, search, settings, notifications, webhooks, apps, and the portable-domain import/export are **out of scope**. Three surfaces stay out by decision, stated in the module header and in `info.description`:

- **MCP** (`/Api/_mcp/...`) is not an API surface — it is the agent data plane (see [`mcp.md`](mcp.md)).
- **OAuth** (`/OAuth/...`) is outside the declarative slice.
- The **assistant** (`/Api/assistant/...`) is outside the declarative slice.

Adding a route under one of those prefixes does not raise drift.

Write-plane semantics documented on the relevant operations:

- The `403` response of document create and update names both refusal classes: `Write refused: invisible field` and `Role authority refused this write` (the latter on IAM doctypes only). The update `403` is the class-level denial — no update permission on the doctype at all; a scoped grant whose row check fails answers `404`.
- Every history/audit-list operation documents the out-of-band `redacted` metadata: the content paths removed from `arguments` for the calling principal.

Read-plane denial semantics documented on the relevant operations:

- The document list, single read, history, and backrefs operations declare `403` for a caller that holds no read permission on the doctype at all — the class-level denial the write plane already answered. A caller that holds a read grant gets the scope-narrowed result; an inaccessible document answers the non-disclosing `404`.
- The QUERY twins of those operations declare the same `403`, next to their transport statuses (`400`, `415`, `422`).

The RFC 10008 QUERY method has no operation key in OpenAPI 3.0. Each QUERY twin is emitted as the `x-query` extension on its path item, with the transport statuses (`400` body without Content-Type, `415` non-JSON media type, `422` query-string parameters).

## The gate

`GET /Api/openapi.json` is gated like every other control-plane GET: the `AuthHandler` chain answers `401` for an invalid credential, and the handler requires the JWT `sub` (`HTTP::Helpers.require_account`) — the same pattern `/Api/settings` and `/Api/iam/me` use. The route is **not** in `AuthHandler::PUBLIC_ROUTES` and carries no role check of its own. DomainGate passes it through: `openapi.json` is listed in `DomainGate::RESERVED_SEGMENTS`, so the gate does not read it as a domain segment on deployments with a domains include-list.

The spec object is built at boot (module require time) and never rebuilt per request; the served body is byte-stable.

## Drift check

Kemal's route table is enumerable — `Kemal::RouteHandler::INSTANCE.routes` is a `Radix::Tree(Route)` keyed by `/METHOD/path`; `OpenAPI.registered_routes` walks the tree (`Node#children`, `node.payload?`) and returns every `(method, path)` pair. `OpenAPI.check_pairs` compares the declared pairs against the table and reports three drift classes:

| Issue | Meaning |
| --- | --- |
| declared but not registered | The spec documents a route the server no longer serves |
| registered but not declared | A new method landed on a documented path |
| registered but not declared (in scope) | A new route landed inside the v1 scope (audit `/Api/Audit*`, `/Api/iam/accounts*`, `/Api/iam/me`, `/Api/secrets*`, `/Api/Artifacts*`, `/Api/Indexes`, `/Api/SystemSettings`, the document path templates, and the import/export templates) and must be added to `DECLARATIONS` or scoped out explicitly |

Routes outside the v1 scope are ignored — adding an unrelated route does not fail the check; that is the documented v1 boundary. MCP, OAuth, and the assistant are outside the boundary by decision.

The check runs in three places:

1. **CI** — the `openapi-drift` job (`.github/workflows/ci.yml`) runs `crystal run scripts/gen_openapi.cr` and `git diff --exit-code doc/api/openapi.json`. The generator is DB-free: requiring and registering the route modules only adds closures to the in-memory Kemal tree — no database connection, no config load. It registers the document, audit, IAM, secrets, import/export, index, artifact, and system-settings route modules.
2. **Specs** — `spec/http/openapi_spec.cr` asserts the check is clean against the fully registered table and exercises the checker's report with synthetic tables.
3. **Runtime backstop** — on the first request the served route sees after boot, the handler re-runs the check and raises on drift (at require time the table is still empty, so the check cannot run earlier).

## Structural validation

No offline OpenAPI validator exists in the dependency tree, so `spec/http/openapi_spec.cr` validates structure: `openapi` field (3.0.x), `info` with title and version, non-empty `paths`, one `responses` object with a `description` per operation (the `x-query` twins included), and every `$ref` resolving inside the document (v1 has none; the walk stays for when shared schemas arrive).

## Quirks

- The QUERY twins exist only where the route family registers them; the `x-query` operation objects are extensions, so strict OpenAPI 3.0 tooling ignores them. Consumers wanting the QUERY contract read the extension or `doc/backend/http-layer.md` → QUERY method.
- The generator writes the artifact deterministically (fixed declaration order, no timestamps), so a byte-diff is a true drift signal.
