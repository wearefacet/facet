# HTTP Layer

**Files:** `src/http/`

Kemal-based HTTP server with route definitions and request parsing utilities. The shared route helpers live in `HTTP::Responders` (`src/http/responders.cr`), `HTTP::Gates` (`src/http/gates.cr`), `HTTP::Caching` (`src/http/caching.cr`), and `Document::RowAccess` (`src/document/row_access.cr`). `HTTP::Helpers` (`src/http/helpers.cr`) re-exports all their methods, so `Helpers.x` call sites keep their names.

## Server Routes (`src/http/server.cr`)

Routes are registered via `Facet::HTTP::Server.routes` and served by Kemal.

### The casing invariant (route namespaces)

A **lowercase** first path segment is a domain id — the document space (`/{domain}/{doctype}`). An **uppercase** first path segment is an application or infrastructure route. There is no reserved-domain-id list; the casing rule is the whole contract, and `DomainGate` plus the SPA's `[domain=notApi]` matcher enforce it on both sides. The backend namespaces:

| Prefix | Surface | Source |
|---|---|---|
| `/Api` | REST document API + MCP (`/Api/_mcp/...`) + OpenAPI document | `src/http/rest_routes.cr`, `src/mcp.cr` |
| `/OAuth` | Facet app authorization (authorize, token, register, client-info) | `src/oauth/routes.cr` |
| `/A` | Artifact capability streaming (`/A/:gid`, `/A/upload/:uid`) | `src/artifact/routes.cr` |
| `/Ws` | WebSocket bridge | `src/websocket/route.cr` |
| `/Healthcheck`, `/Healthcheck/live` | Readiness + liveness probes | `src/http/healthcheck.cr` |
| `/Edge/HostAsk` | Caddy on-demand TLS ask endpoint | `src/app/host_ask.cr` |
| `/auth/oidc/:provider` | Inbound federated login redirects (legacy lowercase prefix, kept) | `src/iam/oidc/routes.cr` |
| `/.well-known/*` | Discovery documents (a dot cannot start a domain — the one exception) | `src/oauth/routes.cr`, `src/mcp/routes.cr` |
| `/metrics` | Prometheus scrape | `src/http/metrics_handler.cr` |

New application routes must use an uppercase first segment (CamelCase pseudo-resource, lowercase action segments after it — e.g. `/Edge/HostAsk`). A lowercase new prefix would be unreachable: the proxies route it to the SPA, which reads it as a domain.

**The edge answers the lowercase probe names with a bare `404` for every method.** `healthcheck` and `metrics` are not domain ids, so their lowercase twin never falls through to the SPA (F07-05). Without this rule, `GET /healthcheck` reaches the SPA auth hook and answers `303 → /Login` → `200` HTML — a redirect-following monitor reads that `200` as healthy while the backend is down. The edge rule lives in both Caddyfiles (`caddy/Caddyfile`, `docker/Caddyfile.prod`) and precedes the SPA fallback: the reserved probe names `healthcheck` and `metrics` answer `404` JSON for `GET`, `HEAD`, `OPTIONS`, and every other method. The real probe stays `/Healthcheck` (capital H), which the edge routes to the backend; the backend-origin `/metrics` is unaffected because the edge never proxies it. Every other lowercase twin keeps the older rule: a non-`GET`/`HEAD`/`OPTIONS` method answers `404` JSON that names the case rule, and `GET`/`HEAD`/`OPTIONS` fall through so `/{domain}/{doctype}` pages and CORS preflights are unchanged. The fix is at the edge only — the SPA's `[domain=notApi]` matcher and auth hook are untouched.

### Handler chain order

`Kemal.config.add_handler` installs the middleware in this order: **`MetricsHandler`** → `Telemetry.middleware` → **`App::Hosting::Handler`** → `JsonErrorHandler` → `DomainGate` → `OAuth::Cors` → `CsrfHandler` → `AuthHandler` → the router.

`MetricsHandler` sits before every other handler so it wraps the whole chain and reads the final status after the rest has run — every handled request increments `facet_http_requests_total` (see [`metrics.md`](metrics.md)).

`App::Hosting::Handler` sits before every other handler so a registered app host is served without running the API middleware, and Facet's own hosts fall through before any app lookup. See [`app-system.md`](app-system.md) → Deployment serving for the dispatch contract.

`CsrfHandler` enforces the CSRF admission gate globally, one position in front of `AuthHandler`: the check reads only the method, the `auth_token` cookie, and the headers, so it runs before any auth state exists and never depends on it. See Write-route admission gates below for the full contract.

`AuthHandler` answers 401 when a protected route presents an invalid credential. A route that receives **no credential at all** runs under the seeded `iam.Roles.anonymous` role instead — its read grants are the public API surface (see [`rbac.md`](rbac.md) → HTTP integration for the full contract). A presented-but-unparseable `Authorization` header (a raw token with no scheme, an unknown scheme such as `Basic`) is an invalid credential, not a missing one: it answers 401 and never falls back to the anonymous role. Only a request with no `Authorization` header (and no `auth_token` cookie) runs anonymous.

`PATCH` bodies are JSON merge patches (RFC 7386): a `null` value removes the key from the document (it lands as an `unset` diff entry in the mutation log), any other value sets or deep-merges it. A `null` on a required field is rejected at patch validation (`required`) before the merge. Two view tree fields opt out and **replace on write** — the `template` of a `core.DocumentView` and the `config` of a `core.CollectionView`: a patch that carries one replaces the stored value outright (a `null` still removes it), so a key the patch omits never survives as a leftover. The set is `Document::Update::REPLACE_ON_WRITE_FIELDS`, and the view gates validate the submitted value, not a merge product. Every other field keeps merge semantics.

### Connection modes per route family

Every HTTP entry point names its database connection mode (see [`workflow.md`](workflow.md) → Database quirks for the pin model):

| Route family | Mode | Escalation |
|---|---|---|
| `GET` / `HEAD` / `QUERY` document, list, audit history, settings, notifications, IAM profile reads, artifact listing, assistant reads, job status | `Database.with_db(:read_only)` | Lazy schema migration escalates to a nested rw block when a read meets a stale document (one unit per request) |
| `GET /Healthcheck` | Per-pool probe | — (probes every pool directly, one status per database and role) |
| `POST` / `PATCH` / `PUT` / `DELETE`, actions, rollback, restore, uploads | `Database.with_transaction(:read_write)` (default) | — |
| `AuthHandler` context build | `with_db(:read_only)` | The API-key `last_used_at` touch escalates to a nested rw write |
| OIDC callback (`GET`, writes LoginEvents + sessions) | rw | — (a GET that writes stays rw by the hard rule) |
| Artifact metadata + download gateway (`GET`, mints grant rows) | rw | — (the grant INSERT forces rw) |

The hard rule for new routes: `INSERT` / `UPDATE` / `DELETE` / DDL / `SELECT … FOR UPDATE` / `SELECT … SKIP LOCKED` / `nextval` forces `rw`. Everything else is a `ro` candidate.

### Healthcheck routes

| Method | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/Healthcheck` | Public (whitelisted in `AuthHandler::PUBLIC_ROUTES`; out of `DomainGate`'s `/Api/:domain` scope) | **Readiness probe.** Runs `SELECT 1` against every database pool (`database.pools` — one status per database entry and role), `PING` against Redis (via `Event::Publisher.manager.redis_health`), and aggregates the stream consumer health (`Event::ConsumerHealth`). Returns a JSON aggregate that also carries `service` (the boot's env and instance id, see [`event.md`](event.md) → Shard locking), `event_loss` (the `Event::Loss` counters) and `event_lag.max_lag` (the `Cron::EventLagCheck` gauge). |
| `GET` | `/Healthcheck/live` | Public (whitelisted) | **Liveness probe.** No dependency checks — always `200` `{"status":"ok","uptime_seconds":n}` while the process itself is alive. A dependency outage must not restart the process; restarts are the orchestrator's job only when the process is dead.

Response shape (`200` when healthy, `503` when any dependency — including one degraded stream consumer — is unhealthy):

```json
{
  "status": "ok" | "degraded",
  "service": { "env": "dev", "instance_id": "01JD…" },
  "database": { "status": "ok" | "error", "error": null | "…" },
  "redis":    { "status": "ok" | "error" | "in_process", "error": null | "…" },
  "events": {
    "status": "ok" | "degraded" | "in_process",
    "consumers": [
      { "name": "cg:repl:hr", "consecutive_failures": 4, "restarts": 0,
        "last_success_at": "2026-09-29T10:12:44Z", "last_error": "Connection refused" }
    ]
  }
}
```

`service` reports the process identity from `Facet::Service` — one instance id per boot. It is independent of the event manager, so the same value reports under the `InProcessManager` (tests, single-process dev) and the real manager; an operator matches it against the boot log and the shard-lock holders in Redis.

`redis.status` reports `"in_process"` when `Event::Publisher.manager` is an `InProcessManager` (tests / single-process dev) — `in_process` and `ok` are both treated as healthy. `events.status` is `"degraded"` when at least one registered stream consumer reports consecutive failures (the "green but dead" guard — the probe fails even when Redis itself answers again), `"in_process"` when no stream consumers run, and `"ok"` otherwise; each entry in `consumers` carries the per-consumer detail (`name` is the consumer group, e.g. `hr` or `cg:repl:hr`).

**Semantics: readiness.** Wire orchestrator probes (k8s readinessProbe, Docker healthcheck, `scripts/dev`) to `/Healthcheck`. Do not use it as a k8s livenessProbe — dependency health flaps it and causes restart loops; the kill policy belongs to the deployment layer. `/Healthcheck/live` is the livenessProbe counterpart — it flaps only when the process is actually gone. See [`event.md`](event.md) → Supervision and error backoff.

**Path collision with the frontend (B-155, resolved).** The SvelteKit app once served its own `GET /healthcheck` liveness stub; the route is removed. The casing invariant now covers the case: a lowercase first segment is always a domain id, so no SPA route can shadow `/Healthcheck`, and no orchestrator probes the frontend host for readiness. The edge additionally answers `GET /healthcheck` and `GET /metrics` with a bare `404` for every method (see the casing invariant above), so a mistyped probe fails loudly instead of following a login redirect to a `200` page. Probe the backend host (the backend port, the `ghcr.io/wearefacet/facet` image's HEALTHCHECK, or the backend-routed site blocks).

### Metrics route

| Method | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/metrics` | Public (whitelisted — no auth by decision; neither edge Caddyfile proxies it, so the edge answers `404`) | Prometheus scrape endpoint. `Facet::Metrics.render` in text exposition format 0.0.4 (`text/plain; version=0.0.4; charset=utf-8`). Scrape the backend origin directly (e.g. `http://127.0.0.1:3000/metrics`). See [`metrics.md`](metrics.md). |

### Document routes

| Method | Route | Status | Description |
|---|---|---|---|
| `POST` | `/Api/:domain/:doctype` | **Implemented** | Create a new document. Delegates to `Document::Create`. For `core.DocType` this is doctype registration: a duplicate `(domain, doctype)` answers **409** (`Doctype '<domain>.<Name>' already exists`) — registration is create-only, edits go through the dedicated `PUT /Api/core/DocType/:id`; unknown top-level definition keys answer 422 naming them |
| `POST` | `/Api/:domain/:doctype/:doctype_id/:action_name` | **Implemented** | Execute a named action. Delegates to `Document::Action` |
| `POST` | `/Api/:domain/:doctype/:doctype_id/:nested_resource` | **Implemented** | Create nested child document. Handled via `handle_rest` |
| `GET` | `/Api/:domain/:doctype` | **Implemented** | List documents (paginated, filtered, sorted). `?deleted=true` switches to the trash listing (tombstones instead of live rows). Accepts parameters from a JSON body, the query string, or a merge of both (query wins). Delegates to `Document::List` |
| `QUERY` | `/Api/:domain/:doctype` | **Implemented** | Same list as GET, with the parameters in a JSON body only (see [QUERY method](#query-method-rfc-10008)). Delegates to `Document::List` |
| `GET` | `/Api/:domain/search` | **Implemented** | Cross-doctype search inside one domain. One parameter `q`; short/missing term answers 200 with an empty result. Labels only, ranked by trigram similarity. Handled by `Search::Routes` — see [`search.md`](search.md) |
| `QUERY` | `/Api/:domain/search` | **Implemented** | Same search as GET, with `q` in a JSON body only (`{"q": ...}`). See [`search.md`](search.md) |
| `GET` | `/Api/:domain/:doctype/:doctype_id` | **Implemented** | Get document with lazy migration. Delegates to `Document::Read` |
| `GET` | `/Api/:domain/:doctype/:doctype_id/:nested_resource` | **Implemented** | List nested child documents. Handled via `handle_rest` |
| `GET` | `/Api/:domain/:doctype/:doctype_id/:nested_resource/:nested_resource_id` | **Implemented** | Get nested child document. Handled via `handle_rest` |
| `GET` | `/Api/:domain/:doctype/:doctype_id/history` | **Implemented** | Document mutation history. `?include=children` merges readable child changes into the parent timeline. Handled by `Audit::Routes` — see [`audit.md`](audit.md). |
| `GET` | `/Api/:domain/:doctype/:doctype_id/backrefs` | **Implemented** | Backlinks — the live documents whose `links` column contains this document's URN. Handled by `Document::Routes` through `Document::Backrefs` — see [`links.md`](links.md). |
| `PATCH` | `/Api/:domain/:doctype/:doctype_id` | **Implemented** | Partial update document. Delegates to `Document::Update` |
| `PATCH` | `/Api/:domain/:doctype/:doctype_id/:nested_resource/:nested_resource_id` | **Implemented** | Partial update nested child document. Handled via `handle_rest` |
| `DELETE` | `/Api/:domain/:doctype/:doctype_id` | **Implemented** | Soft-delete document. Delegates to `Document::Delete` |
| `DELETE` | `/Api/:domain/:doctype/:doctype_id/:nested_resource/:nested_resource_id` | **Implemented** | Delete nested child document. Handled via `handle_rest` |

**Core view authoring (`DocumentView`, `CollectionView`).** View templates are documents, not definitions: `core.DocumentView` and `core.CollectionView` are owned children of `core.DocType`, through the `document_view` and `collection_view` relationships the seed definition declares (`data/seeds/core.DocType/definition.yml`). Authoring rides the nested child routes — for `DocumentView`:

| Method | Route | Purpose |
|---|---|---|
| `POST` | `/Api/core/DocType/:doctype_id/document_view` | Create a view template owned by the doctype |
| `GET` | `/Api/core/DocType/:doctype_id/document_view` | List the doctype's view templates |
| `GET` | `/Api/core/DocType/:doctype_id/document_view/:view_id` | Read one template |
| `PATCH` | `/Api/core/DocType/:doctype_id/document_view/:view_id` | Edit a template |
| `DELETE` | `/Api/core/DocType/:doctype_id/document_view/:view_id` | Soft-delete a template |

`CollectionView` is identical with `collection_view`, and the flat document routes work for edits too — `PATCH /Api/core/DocumentView/:id`. The method convention follows the table above: document routes are **PATCH-only**; a `PUT` on a document or nested child route answers `405` with an `Allow` header naming the accepted methods, and the JSON error body names the same set (`"Method not allowed. Allowed: GET, HEAD, PATCH, DELETE"`) so a consumer that reads only the body gets the fix. `PUT` is reserved for definition authoring — `PUT /Api/core/DocType/:id` replaces the whole definition. A flat `PATCH` on `core.DocType` rides the same authoring pipeline (B-371): `Document::Update` merges the patch over the stored definition (RFC 7386, with `$force: true` honored at the root like the PUT) and dispatches to `Doctype::Update`, so the version gate, the same-version destructive-edit guards, and `Index::Manager.sync` apply — a same-schema_version field-type change answers the same `422` the PUT answers. View authoring has a UI surface: the Builder Views tab (`DoctypeViewsTab`) edits a view's `template` as JSON and writes it through these routes — `POST` on the child collection for a missing kind, `PATCH` on the child for a stored one. The flat routes remain the scripting surface, and the in-process domain-builder assistant edits views on draft domains through the same write tools.

Document write validation failures answer `422` with `{ "error", "details": [{ field, message, code, params? }] }`. `params` is an optional flat `{name: value}` map carrying the interpolations behind a templated `code` (standardized names: `value`, `expected`, `format`, `allowed`, `min`, `max`, `reason`) — it is present only when the producer stamps it, and `message` stays the universal English fallback for consumers that do not render it (MCP, webhooks, logs). The frontend renders templated codes through its seam renderer (`renderValidationError`), falling back to `message` when `params` are missing. See [`doc/frontend/workflow.md`](../frontend/workflow.md) → Internationalization. Money fields add one code: `inactive_currency` (on the `<path>.currency` field) — a money value pointing at a registered but **inactive** currency is rejected on create (every money path) and on update (only paths whose ticker changed; re-saving an unchanged ticker passes while the row stays inactive). Unknown tickers keep failing as `schema` errors in `MoneyType#validate`; the bulk-import path skips the rule. See [`util-money.md`](util-money.md) → Integration with Doctype system.

**Body-shape gate (B-59).** Every body-consuming JSON route answers `422` — never a 500 — when the body parses but is not a JSON object: `Body must be a JSON object (got <kind>)` with `kind` one of `string`, `number`, `boolean`, `array`, `null` (`Doctype::StrictKeys.json_kind`). Guarded at the service or route layer on: generic document create (`Document::Create.create_from_parsed`), the `core.Domain` create branch, doctype authoring (`DoctypeDefinition.from_json`), draft create (`Domain::Draft.create`), publish (`handle_publish`), document PATCH, and action arguments. The GET list routes share the gate through `ListRequest.from_request` (applied by `Gates.get_list_request`, the GET counterpart of `query_list_request`): a body that is not a JSON object — or does not parse — returns `422` from the parser instead of escaping as a 500. Every GET list handler (document, artifact admin, assistant conversations, audit history ×3, index, webhook calls) reads the request through `get_list_request || return`. The document read route joins the same gate through `ListRequest.from_json(String)`: its optional body rides `parse_body_object`, so a malformed or non-object body answers `422` — before the gate, a JSON string body escaped as a 500 and a JSON array was silently ignored (B-160).

**List parameter gate (B-169).** The list-request parser (`HTTP::ListRequest`) never drops a present `page` / `items` value silently: a query-string or JSON-body value that is present but not an integer — or is a number outside the server's integer range — answers `422 Parameter 'page' must be an integer` (same for `items`), the same named-parameter discipline the `sort` gate set (B-158). Values that were accepted before stay accepted — an absent key, an empty query-string value, a JSON `null`, numeric strings, and floats keep their previous meaning, and the `1..MAX_ITEMS` clamps still apply.

**Strict list admission (B-169 residual).** The document list surfaces admit only known parameters: the flat list routes (`GET` and `QUERY /Api/<domain>/<doctype>`) and the nested child-list renderer parse with `strict: true`, and an unknown top-level parameter answers `422 Unknown parameter '<key>'`. The parse runs after the doctype resolves (B-366): the flat routes fetch the definition through the cached `DefinitionStore` before the strict scan, and the nested child-list renderer resolves the root doctype, the child relationship, and the child's definition before its scan. An unknown `{domain}/{doctype}` answers the same `404 Unknown doctype: <domain>.<doctype>` the list service answers in-render, so the grammar's 422s never leak for a path that names no doctype. The audit list surfaces hold the same contract (B-279): the global audit GET (`/Api/Audit`), the document-history and child-history GETs, and the webhook-calls GET parse through `Gates.get_list_request` with `strict: true`, and each names the one key it reads beyond the grammar as `extra_query_keys` — `include` on the document history, `status` on the webhook-calls list — so that key keeps working while any other unknown key answers the same `422`. A strict route that reads only a subset of the grammar names it as `admitted_body_keys` / `admitted_query_keys`: the global audit list reads only `page`, `items`, `sort`, and `filters`, so the grammar keys it drops (`field`, `select`, `aggregate`, `scope`, `deleted`) answer `422` instead of vanishing into an unfiltered `200` (F07-03). The QUERY forms stay body-only and parse their body strictly under the same admitted set, with the handler-read extras named as `extra_body_keys` — `include` on the document history, `status` on the webhook-calls list — so a body `include` / `status` keeps working there while any other unknown body key answers `422`. The admitted `select` key validates against the doctype's declared fields (B-358): `select` projects each row's `content` to the named top-level keys, so an unknown key answers `422 Unknown select key '<key>' (accepted: …)` instead of `{}` rows. System identity (`id`, timestamps, `display_name`) lives in `meta`, never in `content`, so no system key is admitted. The sidecar/backref collections stay lenient by design. Strictness is opt-in per surface; the parser default stays lenient.

**Read masking on document GET (B-101ext).** A document GET presents content through `Document::Presenter` (`RBAC::FieldVisibility.mask_content`). The mask keeps only the keys the doctype schema declares. It drops unknown keys for Real principals; System and Preview see raw content. A system doctype that stores structured content must declare every stored key as a field. A `core.DocType` key the seed schema does not declare vanishes from a GET, and a GET → PUT round-trip of a definition then deletes the key from the stored definition. The guard spec `spec/doctype/core_doctype_seed_keys_guard_spec.cr` pins every definition key to a declaration.

**Write-route admission gates (B-165, B-166).** CSRF is enforced globally by `CsrfHandler` (Kemal middleware, one position in front of `AuthHandler`): a cookie-session request whose method is not `GET` / `HEAD` / `OPTIONS` requires the `X-Requested-With` header and answers `403` with the shared CSRF body when the header is absent or blank. A request that presents a `Bearer` or `DPoP` Authorization credential without an `auth_token` cookie is exempt: browsers never attach an Authorization header to cross-site requests, so the credential is non-ambient and cannot be replayed by a CSRF forgery (this subsumes the former static-API-key bypass). A request with no `auth_token` cookie at all is exempt too — there is no ambient credential to forge, so login-style flows stay ungated. A request that carries an Authorization header beside the session cookie stays CSRF-checked — the cookie is the ambient credential the defense exists for. `CsrfHandler::EXEMPT_PATHS` holds exact-path opt-outs for a third-party browser flow that must reach a mutating route without the header; it is empty. The per-route `HTTP::Helpers.require_csrf` calls — on the flat document POST / PATCH / DELETE, the nested REST writes and action POSTs, and the feature write routes (doctype authoring, domain lifecycle, grants, webhook replay/test, audit rollback/restore, secret staging, artifact upload and grant routes) — remain as defense in depth. The flat document create and update routes also hold the media-type gate the nested routes enforce (B-113): a declared non-JSON `Content-Type` answers `415` (the flat routes keep `multipart/form-data` as the file-upload intake), and a malformed body under a JSON media type answers `400` on create — update keeps its `422` answer from the B-59 gate inside `Document::Update`. A body with no `Content-Type` at all keeps the flat routes' tolerance: the body itself must parse.

### Document id forms

The flat `:id` routes and the nested root id of `handle_rest` accept two shapes for the same row:

| Shape | Example | Written by |
|---|---|---|
| Bare opaque id | `06GCXN34…` (a ULID) | The normal document write path (`Document::Create` mints it) |
| Fully qualified id | `identity.Person.1` | Seed bundle imports and the `core.*` meta-doctypes (the bundled id becomes `projections.id`) |

A third shape — the fully qualified **reference token** (`identity.Person.06GCXN34…`, `{domain}.{Doctype}.{bare id}`) — is what reference fields store and what clients send back (e.g. a reference capsule click opens `/Api/{domain}/{doctype}/{token}`). Before dispatch, `Document::RowAccess.canonical_doc_id` resolves it: the exact id wins; otherwise the `{domain}.{Doctype}.` prefix is stripped and the bare id is tried (mirroring `Document::DisplayName::DatabaseReferenceResolver`). Bare ids skip the lookup. A token whose row does not exist resolves to itself, so the route's normal answer is unchanged: the non-disclosing 404 (or the tombstone 410, since the lookup accepts tombstoned rows) for a caller that holds a read grant, and the 403 class denial for a caller that holds none. There is no information gain: a caller that can form the token already knows the bare id it contains.

### Doctype & draft domain routes

Dedicated Crystal endpoints (not Lua actions) — they need direct table access that the Lua `document.*` helpers can't provide.

| Method | Route | Status | Description |
|---|---|---|---|
| `PUT` | `/Api/core/DocType/:id` | **Implemented** | Update a doctype definition (PUT, not PATCH). Accepts `$force: true` at the root of the JSON body to bypass same-version destructive-edit guards (the flag is stripped before the definition is parsed — it is transport, not definition). An idempotent re-save (the body matches the stored definition) writes nothing and answers `200` with the unchanged projection — the body is `{mid: <current state>}` and the `ETag` matches the preceding GET. Delegates to `Doctype::Update`. |
| `GET` | `/Api/core/DocType/:id/check` | **Implemented** | Doctype diagnostics — read-only. Returns cross-doctype configuration issues (reference targets, replicate sources/grants, child targets) as `:warning`s. Gated by `write core.DocType` (the audience is the doctype author). Delegates to `Doctype::Check`. |
| `POST` | `/Api/core/Domain/draft` | **Implemented** | Create a draft domain (autogenerates `_`-prefixed name, sets `draft: true`). Delegates to `Domain::Draft`. |
| `GET` | `/Api/core/Domain/:id/check` | **Implemented** | Aggregate domain diagnostics — read-only. Runs `Doctype::Check` for every doctype owned by the domain and combines the per-doctype issues, plus a small set of domain-level warnings (`:no_doctypes`). Gated by `write core.Domain` (same audience as `/publish`). Delegates to `Domain::Check`. |
| `POST` | `/Api/core/Domain/:id/publish` | **Implemented** | Publish a draft into a fresh real-named domain. Body: `{"target_name": "…"}`. Copies structure (doctype defs + domain doc) and drops the draft. Delegates to `Domain::Publish`. |
| `POST` | `/Api/core/Domain/:id/drop` | **Implemented** | Delete a domain (draft or live). Tears down the whole owned surface (definitions, views, data, `doctype_indexes`, artifact provenance) and records a `delete` mutation on `core.Domain` for audit. Refuses system domains (`core`, `iam`, `app`, 422) and live domains with an open draft (409). Gated by `delete core.Domain`. Delegates to `Domain::Drop`. The generic `DELETE /Api/core/Domain/:id` returns 422 — a lone Domain tombstone would orphan the domain. |

### Response shape — `/check`

`GET /Api/core/DocType/:id/check` (200):

```json
{
  "data": {
    "doctype_id": "hr.Employee",
    "issues": [
      {
        "severity": "warning",
        "category": "reference",
        "field": "customer",
        "message": "Reference field 'customer' targets doctype 'identity.Person' which is not a registered doctype"
      }
    ]
  }
}
```

`field` is omitted when the issue is not tied to a single field (e.g. `:children`, or `:replication` aggregated summaries).

### Response shape — `/Api/core/Domain/:id/check`

`GET /Api/core/Domain/:id/check` (200):

```json
{
  "data": {
    "domain": "_abc",
    "issue_count": 2,
    "domain_issues": [
      { "severity": "warning", "category": "no_doctypes", "message": "Domain '_abc' has no registered doctypes" }
    ],
    "doctypes": [
      {
        "doctype_id": "_abc.Order",
        "issue_count": 1,
        "issues": [
          {
            "severity": "warning",
            "category": "reference",
            "field": "customer",
            "message": "Reference field 'customer' targets doctype 'identity.Person' which is not a registered doctype"
          }
        ]
      }
    ]
  }
}
```

`issue_count` is the sum of `domain_issues.length` and every doctype's `issue_count`. `domain_issues` carries domain-wide findings (currently only `:no_doctypes`); `doctypes` carries the per-doctype slice mirroring `Doctype::Check`'s output.

### Secrets route (`src/http/secrets_routes.cr`)

| Method | Route | Auth | Description |
|---|---|---|---|
| `POST` | `/Api/secrets/stage` | Session principal only — system and API keys rejected (`403`) | Stage a value for a doctype `secret` field. Body: `{domain, doctype, field_path, value?, doc_id?}`. Gates: the doctype and `secret` leaf must exist, the caller holds `create` (or `update` on `doc_id`), and the leaf's `tags` are covered by the caller's `visible_tags` — unknown/field/tag failures answer a non-disclosing `404`, RBAC denial `403`, plaintext-constraint failures `422`. Stores a codec payload in `secret_staging` and returns `201 {handle, token?}` — a single-use, TTL-bound handle the client puts into the document instead of a value; `token` is present only in token mode (the server-generated one-time token, shown once). See [`secrets.md`](secrets.md). |

### App deployment routes (`src/app/`)

Backend-app management routes (`src/app/routes.cr` — app-owned API keys) and the deploy route (`src/app/deploy.cr`) run under `/Api/app/...`. The deploy route is the multipart build upload:

| Method | Route | Auth | Description |
|---|---|---|---|
| `POST` | `/Api/app/:id/deploy` | Operator session (CSRF + `update` on `app.App`) **or** app-owned `fct_` API key (`IAM::ApiKey.verify`, key's `app_id` must equal `:id`) | Multipart create of an `app.Deployment` document: `$content` JSON part + one part per file (`files[<i>].file`). Uploads, owner rows, and the create share one transaction. `activate=true` (query string or `$content`) also flips `active_deployment` on the app in the same transaction. The app must be live and `active`. Returns `201 {id, revision, activated, files}`. See [`app-system.md`](app-system.md) → Deployment serving. |

### Artifact route

`POST /Api/{domain}/{doctype}` and `PATCH /Api/{domain}/{doctype}/{id}` accept a `multipart/form-data` body (a `$content` JSON part plus one part per `file`-field named by its normalized field path) in addition to the plain JSON body. See [`doc/backend/artifact.md`](artifact.md) → Multipart intake.

| Method | Route | Auth | Description |
|---|---|---|---|
| `POST` | `/Api/{domain}/{doctype}` | full | Create a document; multipart body uploads `file` fields atomically |
| `PATCH` | `/Api/{domain}/{doctype}/{id}` | full | Update a document; multipart body uploads `file` fields atomically |
| `POST` | `/Api/core/artifacts` | full (non-system) | Standalone upload. Multipart body with one `file` part. Returns `201` with `{id, filename, mime_type, size, sha256}`. Provenance is bound to the uploader's account via the synthetic `_account` owner-row convention (`Artifact::Store::ACCOUNT_OWNER_*`); the artifact is readable by the uploader until it is linked into a document or swept by prune |
| `GET` | `/Api/core/artifacts/:id` | full | Metadata + a freshly-minted ephemeral grant URL (`{id, filename, mime_type, size, sha256, url, expires_at}`) |
| `POST` | `/Api/core/artifacts/:id/grant` | `can_read?` | Mint an ephemeral grant |
| `POST` | `/Api/core/artifacts/:id/publish` | `publish_artifact` on owner doc | Mint a permanent grant (body must include `owner_id`) |
| `DELETE` | `/Api/core/artifacts/grants/:gid` | full | Revoke a grant — system, `publish_artifact` on the owner document, or the operator `revoke *.*` action |
| `GET` | `/A/:gid?exp=…&sig=…` | signature only | Stream artifact bytes (artifact origin, bearer URL) |
| `GET` | `/Api/Artifacts` | `read *.*` (deny-only-`Denied`) | Operator listing — pseudo-doctype path (outside `DomainGate`, like `/Api/Indexes`), spans every domain. Platform `{ data, meta }` shape with the capped count; filters `id__match`, `filename__match`, `mime_type__eq`/`__match`, `deleted__eq`; per-row owner / live-grant / reference counts. See [`artifact.md`](artifact.md) → Admin surface. |
| `GET` | `/Api/Artifacts/:id/grants` | `read *.*` | All grants for one artifact, newest first, capped at 500 (`meta.more`). `404` for an unknown artifact |
| `GET` | `/Api/Artifacts/:id/references` | `read *.*` | `artifact_references` rows joined with the referencing projection (`doc_type`, `display_name`), newest reference first, capped at 500 |

The standalone upload rejects: system principals (403 — provenance must bind to a real account); non-multipart requests (415); malformed multipart bodies or bodies without a `file` part (422). It does **not** enforce a target doctype's `file` field `accept` allow-list — that gate runs on document mutation in `Document::FileMimeCheck`; the standalone upload only registers bytes against the uploader's account. The serve route (`GET /A/:gid`) enforces the response hardening (`nosniff`, CSP, `Content-Disposition` gating by MIME) and strips query strings from access logs; see [`doc/backend/artifact.md`](artifact.md) → Serving.

### Assistant conversation routes

Virtual namespace (`/Api/assistant/...`), carven out of `DomainGate` like `/Api/Audit` and `/Api/iam`. Pure CRUD over the persistence layer plus the SSE streaming endpoint. The streaming and cancel routes call the live `agent-cr` `Agent`; the CRUD routes do not. See [`doc/backend/agent-conversations.md`](agent-conversations.md).

| Method | Route | Status | Description |
|---|---|---|---|
| `POST` | `/Api/assistant/conversations` | **Implemented** | Create a conversation. Body: `{session_id, cache_key, model, system_prompt?, config?, context?, enabled_tools?}`. `api_key` in `config` is hard-rejected (422) |
| `GET` | `/Api/assistant/conversations` | **Implemented** | List conversations, filtered + sorted + paginated via `ListRequest`. Default sort `-updated_at`. Supports `filters[context.<key>__eq]=...` for jsonb context filtering |
| `GET` | `/Api/assistant/conversations/:id` | **Implemented** | Fetch a single conversation (404 if not found) |
| `PATCH` | `/Api/assistant/conversations/:id` | **Implemented** | Archive or unarchive a conversation. Body: `{archived: true \| false}` (missing or non-boolean → 422). Owner-gated for reserved kinds. See [`doc/backend/agent-conversations.md`](agent-conversations.md) → Archiving |
| `GET` | `/Api/assistant/conversations/:id/turns` | **Implemented** | List turns of a conversation (`idx` ASC) |
| `POST` | `/Api/assistant/conversations/:id/turns` | **Implemented** | Record a turn. Body: `{request_messages, response_messages, usage, finish_reason?, error?}`. Run inside a transaction |
| `POST` | `/Api/assistant/conversations/:id/stream` | **Implemented** | SSE streaming endpoint. Body: `{content, attachments?}`. Emits `meta`/`chunk`/`done`/`error`/`cancelled` events. Persists a `Turn` on every exit path |
| `POST` | `/Api/assistant/cancel/:turn_token` | **Implemented** | Publishes a cancel signal via Redis Pub/Sub. Returns `200 {cancelled: true}` |

### OAuth app routes

Virtual namespace (`/OAuth/...` + `/.well-known/oauth-authorization-server`). **Not** a general OAuth provider — the endpoints serve Facet-registered `app.App`s only. `OAuth::Cors` is registered in the Kemal chain **before** `AuthHandler` so it can attach CORS headers to preflight and actual responses without the auth check pre-empting it. See [`doc/backend/oauth.md`](oauth.md).

| Method | Route | Auth | Description |
|---|---|---|---|
| `GET` | `/OAuth/authorize` | Browser session (cookie or `Authorization: Bearer …` read by the route itself, not `AuthHandler`; public in `AuthHandler::PUBLIC_ROUTES` so the route owns the unauthenticated response) | Render the consent screen — app metadata + the account's usable roles + resolved effective scope per role. Never issues a code. No session → 302 to the frontend login (see [`doc/backend/oauth.md`](oauth.md) → Login redirect contract). |
| `POST` | `/OAuth/authorize` | Browser session (same as GET) | Consent confirm. Body carries the authorize params + the elected `role`. Issues a 60-second single-use authorization code. No session → 303 to the login page. |
| `POST` | `/OAuth/token` | Public (`AuthHandler::PUBLIC_ROUTES`; PKCE-protected) | `grant_type=authorization_code`. Verifies PKCE, consumes the code, returns the app JWT. |
| `POST` | `/OAuth/register` | Public (`AuthHandler::PUBLIC_ROUTES`) | RFC 7591 dynamic client registration for MCP clients. Validates the client-metadata JSON, mints an opaque public-client `client_id`; no record is kept. Rate limited per IP. See [`doc/backend/oauth.md`](oauth.md) → Dynamic client registration. |
| `GET` | `/OAuth/client-info?slug=…` | Public (`AuthHandler::PUBLIC_ROUTES`) | Client metadata for first-party CLI clients — slug → `{slug, client_id, name, client_type}` for an active app. Every failure path (unknown slug, missing param, non-active app, missing `client_id`) returns the same `404 unknown_client` body. See [`doc/backend/oauth.md`](oauth.md) → Client-info endpoint. |
| `GET` | `/.well-known/oauth-authorization-server` | Public | Discovery metadata for off-the-shelf OAuth client libraries. |

### Response shapes

All document responses use a unified **`{ data, meta }`** response shape:

- **`data`** — the document's user-defined content fields (the projection's `content` column).
- **`meta`** — system metadata (identity, versioning, timestamps). Never user-writable.

**`meta` fields:** `id` (document ID, legacy dotted form), `uri` (canonical URN, see [`document.md`](document.md#documentdocuri)), `mid` (last mutation ULID), `domain`, `doc_type`, `version`, `schema_version`, `display_name` (doctype-defined human label, `null` when no template is declared), `created_at`, `updated_at`.

`mid` is the last mutation ULID. It changes on every mutation. It is not a document handle: a read by `mid` answers 404. Use `id` as the handle.

**Media type.** Every 2xx response that carries a JSON body — document create/read/update/action, list and aggregate, audit list/rollback, grants, domain lifecycle — answers `Content-Type: application/json`. Kemal's `InitHandler` stamps `text/html` on every response before dispatch; `JsonErrorHandler` corrects that default on a 2xx body, and the shared writers (`Helpers.write_result`, `write_json`, the list writers) set it explicitly. A `204 No Content` (delete) keeps no body and no media type.

#### Create request body

The fields ride at the **top level** of the JSON body — there is no
`content` wrapper:

```http
POST /Api/hr/Employee

{ "status": "active", "job_title": "Engineer", "salary": 75000 }
```

A wrapped body (`{"content": {...}}`) names no doctype field, so it fails
shape validation with `content: is not a defined field` (422). To create a
parent with its children in one call, send the compound form — `$content`
for the parent fields and an optional `$children` map keyed by relationship
name (one transaction; any child failure rolls the whole call back):

```json
{
  "$content": {
    "status": "active",
    "job_title": "Software Engineer"
  },
  "$children": {
    "career_events": [
      { "event_type": "hired", "effective_date": "2026-01-01" }
    ]
  }
}
```

See `src/document/create_with_children.cr` for the compound contract and
**Compound create** below for the response shape.

#### Single document responses

**POST /Api/:domain/:doctype** (201), **PATCH /Api/:domain/:doctype/:id** (200), and **named actions** (200):
```json
{
  "data": { "status": "active", "job_title": "Engineer", "salary": 75000 },
  "meta": {
    "id": "hr.Employee.abc123",
    "uri": "urn:facet:hr:Employee:abc123",
    "mid": "01J...",
    "domain": "hr",
    "doc_type": "Employee",
    "version": 1,
    "schema_version": 1,
    "created_at": "2025-01-01T00:00:00Z",
    "updated_at": "2025-01-01T00:00:00Z"
  }
}
```

**GET /Api/:domain/:doctype/:id** (200) — same shape plus the `X-Document-Migrated` header (`true`/`false`).

**Read denials split by gate class.** A caller that holds no read permission on the doctype at all — role denial, or the layer-1 app-grant ceiling — answers 403 (`ReadEnforcer.read_denied?`, checked before any row fetch). A grant holder that cannot see the document answers the non-disclosing 404: an inaccessible document is indistinguishable from a missing one. A tombstone answers 410 (see Deleted documents below).

**Compound create** — with children, an extra `children` key groups child results by relationship name:
```json
{
  "data": { ... },
  "meta": { ... },
  "children": {
    "career_events": [
      { "data": { ... }, "meta": { ... }, "children": {} }
    ]
  }
}
```

**DELETE** returns **204 No Content** — no body.

#### Collection responses

**GET /Api/:domain/:doctype** and **child list endpoints** (200):
```json
{
  "data": [
    { "data": { "status": "active", "job_title": "Engineer" }, "meta": { "id": "hr.Employee.xxx", "created_at": "2025-05-01T10:00:00Z", "updated_at": "2025-05-02T09:30:00Z", ... } },
    { "data": { "status": "active", "job_title": "Manager"  }, "meta": { "id": "hr.Employee.yyy", "created_at": "2025-05-03T08:00:00Z", "updated_at": "2025-05-03T15:11:42Z", ... } }
  ],
  "meta": {
    "count": 47,
    "more": false
  }
}
```

Each item in `data` is the same `{ data, meta }` shape as a single-document response — `data` holds the user-defined content fields, `meta` holds system metadata (`id`, `mid`, `domain`, `doc_type`, `version`, `schema_version`, `display_name`, `created_at`, `updated_at`). List consumers that need only `id` can lift it from `meta.id` without a follow-up read.

**Structural metadata lists (B-86).** A class-level read denial on a flat, non-metadata doctype answers 403 (`ReadEnforcer.list_denied?`) — the same gate state the write side denies with 403. `ReadEnforcer.list_where_clauses` still emits `1=0` on a denial, but it now serves only the composed fan-out surfaces (`Document::Backrefs`, `Document::Resolve`, `Artifact::Refs`, the audit child feed), where one unreadable doctype must narrow to nothing instead of failing the whole response. The two structural doctypes are the exception: on `Denied`, `core.DocType` serves the definitions of the doctypes the caller holds any grant on, and `core.Domain` the domains it holds grants inside (`RBAC::MetadataGate`, flat gate only — see [`rbac.md`](rbac.md) → Definition and domain visibility). The application renders every doctype surface (nav, forms, route loads) from these two lists, so a role with grants on `iam.Account` but no `read` line on `core.DocType` still resolves its granted pages; definitions it holds no grant on stay absent, and the row API is unchanged.

#### Pagination (count/more)

`meta.count` is the **real number of matching rows from the page offset, counted up to 1000**. `meta.more` is `true` only when counting was truncated — that is, more than 1000 rows match from the offset. So `count` is a floor when `more` is `true`, never an inflated figure, and the pair answers both questions a pager needs: how much is there, and did the server give up counting.

The cap lives in `HTTP::Responders::COUNT_CAP` (re-exported as `HTTP::Helpers::COUNT_CAP`) and every `meta.count`/`meta.more` surface uses it, so the numbers mean the same thing on every route. The server runs the count as:

```sql
SELECT COUNT(*) FROM (
  SELECT 1 FROM projections
  WHERE ...
  ORDER BY ...
  LIMIT {COUNT_CAP + 1} OFFSET {offset}
) AS sub
```

`Responders.capped_count(raw_count, offset)` then returns `offset + min(raw_count, COUNT_CAP)`. Reading one row past the cap (`COUNT_CAP + 1`) is enough to know the cap was hit. The extra row is a probe: it is never returned in `data` and never counted in `meta.count`.

| Matching rows from `offset` | `meta.count` | `meta.more` |
| --- | --- | --- |
| 37 | `37` | `false` |
| 1 000 | `1 000` | `false` |
| 1 001 | `1 000` | `true` |
| 50 000 | `1 000` | `true` |

`count` is offset-relative, so it grows as the caller pages forward, but it never goes above the cap: with `items=50`, page 1 of a 50 000-row set reports `count: 1000` and page 2 reports `count: 1000`, both with `more: true`. The offset adds to the count only while the remaining rows stay below the cap. Next-page presence is derived from `data.length === items`, not from `more` — `more` only says the count was truncated.

Benchmark on 50 000 rows (`items=50`, page 1): the count subquery costs 0.05 ms at `LIMIT 51` and 0.26 ms at `LIMIT 1001` on an indexed sort; on an unindexed JSONB sort the same statement costs 15.1 ms and 21.2 ms — the sort dominates, so the wider window is cheap.

`aggregate=count` uses the same cap from offset 0 (`LIMIT 1001 OFFSET 0`), so the caller learns the inclusive upper bound of the whole filtered set (0..1000). This is what the sidebar nav badge consumes. `aggregate=sum|avg|min|max` is uncapped and always reports `more: false` (see below).

The document-history route uses the same envelope. With `include=children`, one COUNT query covers the parent branch and every child branch, so the total counts each row once. Child lists are fully paginated — the flat route's contract scoped to one parent — so their count is offset-relative like any other list. Sidecar lists stay unpaginated (page 1, 1000 items), so their count starts at offset 0.

#### Aggregate responses

`?aggregate=<sum|avg|min|max>&field=<name>` computes an aggregate of a numeric field over the **full** filtered set. A field aggregate honours the total: there is no cap, `more` is always `false`, and `meta.count` is the number of matching rows that produced the value (computed by the same SQL statement). Runaway statement cost is bounded by the session `statement_timeout` instead of a row cap — see [`workflow.md`](workflow.md) → Database quirks.

Numeric fields (`integer`, `duration` — stored as integer seconds) return a scalar:

```json
{ "data": { "value": 123456 }, "meta": { "count": 87, "more": false } }
```

`value` is a JSON number when the result is integral and fits `Int64`; otherwise it is a decimal string — no exponent notation. For `sum`, `min`, and `max` the string is exact: no precision loss. `avg` is a rounded value. PostgreSQL computes it as numeric division (`SUM/COUNT`) and selects the result scale from the operands — at least 16 significant digits, and never fewer fractional digits than the aggregated values themselves carry (`select_div_scale` in PostgreSQL's `numeric` module). The scale therefore varies with the data: `26/11` returns `"2.3636363636363636"` (16 fractional digits), `5/6` returns `"0.83333333333333333333"` (20). Rows that match the filter but omit the field contribute nothing to the aggregate and still count in `meta.count`. An empty result set reports `value: 0` for `sum` (the total of nothing) and `value: null` for `avg` / `min` / `max` (there is no value to report), with `meta.count: 0` in both cases.

`money` fields return a currency bag — one entry per distinct currency present in the filtered set, never a single cross-currency total. Amounts are decimal strings (the same form `MoneyType` accepts for the `value` member). An `avg` amount follows the scalar rounding rule above — PostgreSQL numeric division — so it may be rounded:

```json
{
  "data": { "value": { "USD": "123456.78", "EUR": "9876.54" } },
  "meta": { "count": 87, "more": false }
}
```

No `__currency` filter is required: a caller who already filters with `__currency=USD` receives a one-key bag. An empty result set returns `value: {}` for every field aggregate, with `meta.count: 0`.

Errors:

| Status | Condition |
|---|---|
| 422 | field aggregate without `field` |
| 422 | `field` present without a field aggregate — no `aggregate`, or the field-free `count` (B-358) |
| 422 | dotted `field` — top-level doctype fields only |
| 422 | `field` not declared on the doctype |
| 422 | `field` declared but carries no type (`field '<name>' has no declared type` — checked before the numeric-type gate) |
| 403 | `field`'s `tags` are not covered by the caller's `visible_tags` (`RBAC::ReadEnforcer.field_visible?` — fail closed; an aggregate returns no rows, so the read mask cannot protect the field, and the denial is raised before the type check so the field's declared type never leaks) |
| 422 | `field` type is not `integer`, `duration`, or `money` |
| 503 | the statement exceeded the session `statement_timeout` (SQLSTATE `57014`, mapped by `Responders.statement_timeout?` on aggregate requests — retry with a narrower filter) |

The field checks above run only for a caller that holds a read grant on the doctype. A caller with no read grant on a non-metadata doctype answers 403 before any field check or SQL runs (`ReadEnforcer.list_denied?` — the same class-level denial its list answers), so the 403 / 422 / 200 distinctions cannot enumerate field names or sensitivity tags. The structural metadata doctypes keep the empty-set aggregate: their lists never answer 403 (B-86), `ReadEnforcer.read_denied?` mirrors their list gate, and `Document::List` serves the no-field shape — `value: 0` for `sum`, `value: null` for `avg` / `min` / `max`, with `meta.count: 0` — for every field name. The shape never reads the field definition, so a caller with zero reach into structural rows cannot list field names or tags; a `money` field also answers the scalar shape. For a caller that holds a read grant, a missing `field` still answers 422; that message does not depend on the field name.

All validation runs before any SQL. Row-level RBAC applies as on any list — the caller's scope clauses are injected into the aggregate's WHERE clause, so a caller cannot aggregate rows it could not list.

Child lists carry the same surface: `/Api/:domain/:doctype/:id/:rel` serves the full list contract scoped to one parent. The whole grammar is forwarded — `filters`, `sort`, `page`, `items`, `select`, `aggregate`, `field`, `scope`, `deleted` — with the flat route's validation and its defaults (`page: 1`, `items: 100`). The filter grammar is identical (a malformed filter answers 422, never a silently unfiltered result), and so is the `aggregate` / `field` pair gate — a `field` without a field aggregate answers 422 here too. `select` is validated against the child doctype's definition (an unknown key answers the flat route's 422) and narrows each row's content. The child list resolves the child's definition before its strict parameter scan, so an unknown child doctype answers the same 404 as the flat route (B-366). The child ETag fingerprint carries the full request (page, items, and sort always serialize), so two different pages or orders never share a validator, and two aggregates over different fields never alias.

#### Errors
```json
{ "error": "...", "details": ["..."] }
```
`details` is omitted when empty.

Every 4xx/5xx response is also logged at WARN (4xx) or ERROR (5xx) on the `facet.http` log source — a single line with `<method> <path> → <status> <message>` — so operators can see *why* a request failed without inspecting response bodies. Unexpected-exception 500s (`JsonErrorHandler`'s catch-all and PQ branches, and the `error 500` block in `Server.routes`) extend the line with the first 15 backtrace frames and attach the exception object to the log entry. Kemal's request log (source `kemal`) continues to log every request's status/method/path/elapsed at INFO; the two sources are deliberately separate so the request log stays low-noise and the error log carries the reason.

Every error response also sets `Cache-Control: no-store`. Browsers may store `404` and `410` responses with no explicit header at all (RFC 9111 — both are cacheable by default), so a cached tombstone would keep reporting a document as deleted after the database is reset and the same stable id is re-seeded (fixture ids like `crm.Company.1`). The header is set at the shared error paths — `Responders.error_response`, `Responders.write_json_error`, `Responders.write_json` (status ≥ 400), `write_result`'s `ServiceError` branch, `JsonErrorHandler`, `DomainGate`, `AuthHandler`, `App::Hosting`, and route-level 404/410 emissions. Headers must be set before the body is printed: Kemal commits them on the first write.

#### Deleted documents

`GET` on a soft-deleted document returns **410 Gone** with `X-Document-Deleted: true` and `Cache-Control: no-store` headers. The body carries the surviving tombstone fields so clients (e.g. the Capsule primitive) can render the deleted reference by label:

```json
{ "error": "...", "display_name": "Acme Corp", "deleted_at": "2026-01-01T12:00:00Z" }
```

#### Concurrent write conflict (409)

Mutation writes get their per-document order from `idx = MAX(idx)+1`, stamped by the `stamp_mutation_insert` trigger. The unique index `idx_mutations_doc_id_idx` (`db/migrations/0001_document_store.sql`) guards the one race the design cannot avoid: two writers that read the same `MAX(idx)` before either commits. Update and delete writers take the projection row lock (`SELECT ... FOR UPDATE`) first, so their `MAX(idx)` read is serialized — the remaining exposure is the create path with a client-supplied doc id (two concurrent creates both compute `idx = 1`).

When that guard fires, `JsonErrorHandler` maps the violation — SQLSTATE `23505` on constraint `idx_mutations_doc_id_idx`, detected by `Responders.mutation_write_conflict?` — to a **409** instead of a generic 500, and logs one WARN line on `facet.http`:

```json
{ "error": "Concurrent write on this document — retry the request" }
```

The retry contract: **re-issue the same request**. The losing write never landed (its transaction rolled back), so a fresh write reads the committed `MAX(idx)` and takes the next free slot. There is no server-side retry loop. Non-HTTP writers (cron, import) see the raw driver error.

#### Dependency unavailable (503)

When a backing service cannot be reached, `JsonErrorHandler` maps the connection-level exception — classified by `Responders.dependency_unavailable?` — to a **503** with the failing dependency named, instead of the opaque 500. Only connection-level classes match, so a programming error never masquerades as an outage:

| Exception | `dependency` |
|---|---|
| `Socket::ConnectError` (a refused dial — the Redis client dials a `TCPSocket`) | `redis` |
| `Socket::Addrinfo::Error` (an unresolved host — a `redis://` URL whose host does not resolve) | `redis` |
| `DB::ConnectionRefused` (the PostgreSQL pool cannot reach its server) | `postgresql` |

```json
{ "error": "Service unavailable", "dependency": "redis" }
```

This is the general request-path answer, so every dependency-backed route benefits — the login path (`POST /Api/iam/login`, which mints a session and reads the throttle state from Redis) answers the same 503 body during a Redis outage instead of an opaque 500 (F09-01). `Redis::Error` (the base class of every protocol and command error) is deliberately **not** matched: a malformed command would otherwise read as an outage. `/Healthcheck` remains the per-dependency status surface (see above); this mapping keeps the failing endpoint honest too.

---

### Nested child routes

Routes matching `/Api/:domain/:doctype/:id/*rest` are dispatched to `handle_rest`. The rest segments alternate relationship name and child id:

- Odd segment count → list children of the immediate parent (e.g. `contacts`)
- Even segment count → target a specific child (e.g. `contacts/c1`)

Before any child operation (list, read, update, delete) runs, `rest_get` resolves the **immediate parent** of the requested resource — the document at `segments[0...-1]` (or the root document for a single-segment list) — and applies the parent read gate to it. The class check runs first (`ReadEnforcer.read_denied?`): a caller that holds no read permission on the parent doctype at all answers 403 — the class-level denial the write side gives. `RBAC::ReadEnforcer.parent_authorized?` then runs `SELECT 1 FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL AND (<parent read scope clauses>)` in a single statement, so a grant holder that cannot see this parent answers the non-disclosing 404 — for them a missing and an out-of-scope parent are indistinguishable. This enforces the rule "read a subset of parents ⇒ read every active child of those parents" — a scoped permission on the parent doctype gates which parents' children are visible, even when the child doctype permission is unscoped.

For deeper nestings (e.g. `Customer/1/contacts/c1/notes`), the gate is applied to the **immediate** parent (the `Contact c1`), not the root. Each level in the composition tree is checked at its own route — a caller who can read the root but not the intermediate parent is denied at the deeper route.

Single-child reads additionally verify the structural `meta->>'parent_id'` linkage via `child_belongs_to_parent?` after the RBAC check, so a child can never be accessed through a parent path it does not belong to.

Child authorization uses the composition path from the aggregate root. For create, read, update, and delete on a nested child route, the role permission match and the app-grant ceiling run against the full composition path (`domain.Parent.Child...`) — not the bare child doctype. The parent read gate on `GET` stays as described above. Row-level scope expansion still uses the leaf (child) doctype. Flat-route authorization (`/Api/:domain/:doctype`) is unchanged.

**A caller with no child grant reads a parent's children through the nested route; the flat child route stays refused.** The composition path is a prefix path: a role line `read on lab.Specimen` prefix-matches `lab.Specimen.SpecLine` (see `Permission#matches_path?`). So `GET /Api/lab/Specimen/:id/lines` answers `200` with every child the parent gate admits, while `GET /Api/lab/SpecLine` and `GET /Api/lab/SpecLine/:id` answer `403` — the flat routes check the bare `lab.SpecLine` path, which the role does not hold. This is deliberate: a child is owned by its parent and reached through it, and the parent read gate scopes which parents' children the caller sees. A reviewer must not assume the flat route's `403` also covers the nested route — the two routes check different paths.

On create, the parent chain is verified too (B-276). The single-depth branch locks the root row with `RowAccess.lock_live_projection_for_update` before it stamps `meta.parent_id`; the deep branch verifies every parent hop the same way on the create transaction — the root row and each (relationship, id) pair before the last segment must be a live row of the doctype the URL resolves it to. A parent id that does not exist, or a real id of another doctype under the same domain, answers the non-disclosing 404 and creates nothing — the same answer for every principal, because the lock supplies the existence check for all of them. The answer rides the lock: `lock_projection_for_share` locks nothing on a missing row, so it cannot serve this check.

### ListRequest (`src/http/list_request.cr`)

Parses pagination, filtering, sorting, the optional `aggregate` mode, and the optional `scope` named-scope filter from JSON bodies or query strings.

Query admission is lenient by default. With `strict: true`, a query parameter outside the known set (or, for `from_json`, a body key outside it) answers `422 Unknown parameter '<key>'`. A strict route that reads keys beyond the grammar names them as `extra_query_keys` (GET) / `extra_body_keys` (QUERY) — `include` on the document-history route, `status` on the webhook-calls route — and the strict scan admits them. A strict route that reads only a subset of the grammar narrows it with `admitted_body_keys` / `admitted_query_keys` (the global audit list admits only `page`, `items`, `sort`, and `filters`); a grammar key outside the narrowed set answers the same `422`.

In addition to the parameters listed below, the parser exposes four `aggregate` modes:

| Value  | Behaviour                                                                                                                                                                                                 |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `count` | Runs only the capped COUNT subquery — returns `{ data: [], meta: { count, more } }` with no projection rows read. `page` and `items` are ignored; the count is the full filtered total capped at 1000 from offset 0. RBAC scope clauses apply. Filters and sort are honored. |
| `sum`  | Field aggregate over the full filtered set — requires `field`. Returns `{ data: { value }, meta: { count, more: false } }`. See [Aggregate responses](#aggregate-responses) below. |
| `avg`  | Field aggregate over the full filtered set — requires `field`. Same response shape; an empty result set reports `value: null`. |
| `min`  | Field aggregate over the full filtered set — requires `field`. Same response shape; an empty result set reports `value: null`. |
| `max`  | Field aggregate over the full filtered set — requires `field`. Same response shape; an empty result set reports `value: null`. |

The `aggregate` value is **not** validated at the parse layer — unknown values are surfaced verbatim and `Document::List.call` returns `422 Unknown aggregate: <value>`. This keeps validation single-sourced in the service layer. `field` (the target field of `sum` / `avg` / `min` / `max`) follows the same rule: the parse layer carries the value verbatim, and the service layer validates it (missing, dotted, unknown, and non-numeric fields return 422; a field whose `tags` the caller cannot see returns 403). The gate is symmetric: a `field` without a field aggregate — no `aggregate`, or the field-free `count` — returns 422 too (`field=<name> requires an aggregate parameter (sum, avg, min, or max)`), because the parameter would otherwise be silently ignored (B-358).

`aggregate` is included in `ListRequest#to_json` (the canonical form used by `Caching.list_request_fingerprint`), so a `?aggregate=count` request and a non-aggregate list request with otherwise-identical parameters produce distinct ETags — a count-then-data sequence never collapses to a false 304. `field` follows the same rule, so two aggregates over different fields never share an ETag either.

The boolean `deleted` flag (`?deleted=true`, or `"deleted": true` in the body) switches the listing to the **trash listing**: `Document::List` swaps the tombstone predicate (`deleted_at IS NOT NULL` instead of `IS NULL`) and returns tombstones instead of live rows. Pagination, RBAC scope clauses, field-level read masking, and the response shape are unchanged — tombstone rows carry the retained pre-delete `content` (cleared later by `Cron::TombstoneContentPrune`) plus the surviving `display_name`/`meta`/`version`/timestamps. Only the literal `true` enables the flag; any other value keeps the live listing. The flag is honoured by `aggregate=count` (a trash count is a tombstone count) and is part of the `to_json` fingerprint, so a trash listing and the live listing never share an ETag.

The optional `scope` parameter (`?scope=mine`, or `"scope": "mine"` in the body) applies one of the doctype's **named scopes** as a query-time filter — see [`rbac.md`](rbac.md) → Named scopes. `Document::List` AND-compiles the scope's predicate through `ScopePredicateParser` + `ScopePredicateSql` after the RBAC row-scope clauses, so it only narrows what the caller can already see; `$self` and context sets bind to the calling account. An unknown scope name answers 422 `Unknown scope: <name>`. The parse layer carries the value verbatim; validation stays single-sourced in the service layer. `scope` is part of the `to_json` fingerprint, so a scoped request and its unscoped form never share an ETag. The parameter is served on the document list/aggregate route (GET, QUERY, and the aggregate modes); other `ListRequest` consumers (audit history, sidecar lists, artifact admin lists) do not expose it.

When both a JSON body and query string are present, they are **merged** — query-string values take precedence over body values for colliding keys. (The QUERY method does not merge — see [QUERY method (RFC 10008)](#query-method-rfc-10008) for its body-only contract.)

| Source | Format |
|---|---|
| **JSON body** | `{"page": 1, "items": 100, "filters": {"field__eq": 1}, "sort": ["-created_at", "id"]}` |
| **Query string** | `?page=1&items=100&filters[field__eq]=1&sort=-created_at,id` |
| **Both** | Query-param wins on `page`, `items`, `filters`, `sort`, `aggregate`, `field`, `scope`, `deleted` |

- **Page:** minimum 1
- **Items:** clamped between 1 and 1000
- **Sort:** shape-gated via regex `^-?[a-z_\.]+$`. A `sort` entry outside the shape answers `422` from the parser (`Invalid sort field: '<entry>' …`) — the silent drop and its `["id"]` fallback hid caller typos behind the default order, so nothing drops (B-158, the strict contract the B-100 array-shape gate and the filter grammar hold). A `sort` value (and a `select` value) that is not an array of strings answers `422` from the parser (`sort must be an array of strings`) — a parseable body with a wrong shape is a caller error, never a 500 from `JSON::Any#as_a` (B-100). An absent — or wholly empty — sort keeps the `["id"]` default. The semantic check is single-sourced in the service layer: `Document::List#build_order_clause` answers `422 unknown_sort_field` for a field that is neither a doctype field nor a system sort column (`id`, `created_at`, `updated_at`, `deleted_at`), and `422 unsortable_field` for a doctype field whose type cannot sort. The ORDER BY expression is type-aware: `Document::List#sort_expression_for` dispatches on the field's declared type so `integer`, `money`, and `duration` fields route through the IMMUTABLE `jsonb_as_numeric(content->'field')` helper — they sort numerically (`0, 10, 20, 100`) rather than lexicographically (`'0', '10', '100', '20'`). Scalar text types (`string`, `longtext`, `enum`, `color`, `date`, `datetime`, `reference`, `boolean`) keep `content->>'field'`. Non-scalar types (`period`, `dateperiod`, `object`, `array`, `dictionary`, `any`, `data`) answer the `unsortable_field` 422. `jsonb_as_numeric` returns NULL when the stored JSON value's type is not `number` (e.g. an `integer` field holding `"abc"` — only reachable via a direct snapshot mutation, since the validator rejects such inputs at create/update time), so a single malformed row never turns a list call into a 500; NULL sorts consistent with the column default (NULLS LAST for ASC). The sort expression matches the `btree_numeric` index access expression so typed ORDER BY can use the index. See migration `0002_indexing.sql`.
- **Filters:** key-value pairs where keys are `field__operator` (e.g. `status__eq`, `age__gte`). Valid operator suffixes: `__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`, `__match` (ILIKE contains-substring), `__starts_with` (ILIKE prefix match — valid on the same string-typed fields as `__match`), `__between` (two-element array value), `__in` (array value — membership; serves `id`, scalar (enum keys match by their stored key), and typed fields only, at most 100 entries), `__currency` (money fields), and the range operators `__contains`, `__overlaps`, `__within` (valid only on `period` / `dateperiod` fields — see [filter-set.md](filter-set.md#range-operators-__contains-__overlaps-__within)). The exact set per field family is `Document::FilterCompiler.allowed_operators` (`src/document/filter_compiler.cr`); a filter key that names an unserved operator raises 422 with code `unsupported_filter_operator` — it never silently matches nothing.

  Array-valued filters on the query string ride **JSON-encoded**: the frontend DataSource emits `filters[value__between]=%5B%22USD%2025000%22%2C%22USD%20100000%22%5D`, and `HTTP::ListRequest.from_query` decodes a `filters[...]` value that starts with `[` and parses as JSON back into a real array. Every other value keeps the raw string form (the historical contract — a numeric-string filter such as `age__gt=18` stays a string, and `[`-prefixed text that is not valid JSON stays a string too), so scalar comparison semantics are unchanged. The JSON-body and QUERY transports carry arrays natively.

  A bare `search` filter key (no operator suffix) performs a case-insensitive substring match against the `search` column: `search::text ILIKE '%' || $n || '%'`. `search` is an operator-keyword of the filter grammar, not a column — it takes no operator suffix, and `search__match`, `search__eq`, or any other `search__*` form is not a production of the grammar: the strict grammar answers 422 (`unsupported_filter_operator`) instead of silently widening to a contains match — the same rule as `created_at__match` (B-20). Both sides of the match are accent-folded (case fold + NFKD decomposition + diacritic-mark strip, via `Util::DiacriticFold`): the corpus folds at write time (`Document::Search`), the term folds before LIKE escaping (`\`, `%`, `_` stay literal — contains semantics), so a term without diacritics matches an accented corpus. The `search` column is rendered by Crystal from the doctype's `search` Jinja2 template (see [doctype-system.md](doctype-system.md#doctypedefinition-doctype_definitioncr)); a doctype that declares no template stores the folded `display_name` as its corpus instead (B-115 — the write path runs the label through the same pipeline), so its rows keep a searchable corpus. On such a doctype the bare `search` filter does not ride the corpus grammar: `Document::List` rewrites it into a three-arm contains match — `(search ILIKE '%' || $n || '%' ESCAPE '\' OR display_name ILIKE '%' || $m || '%' ESCAPE '\' OR id ILIKE '%' || $n || '%' ESCAPE '\')`. The `search` and `id` arms bind the folded, LIKE-escaped term (the corpus side folds too, so both sides fold); the `display_name` arm binds the raw, LIKE-escaped term — it covers rows with no staged corpus (definition-less writes via `ProjectionGucs.clear_all`, e.g. `core.Domain`) and lets an accented term match an accented label. So the reference picker keeps working on a doctype with no template (B-115). The fallback covers the bare key only; a suffixed `search__*` key keeps its 422 answer (see [`search.md`](search.md) → The searchability flag). When the doctype declares **neither** a `display_name` nor a `search` template, there is no corpus and no label to fall back to, so the bare `search` filter matches only the row `id`. The reference picker detects that state from the target's `core.DocType` row and labels results by id, steering the user to search by id (B-296); an aggregate root in that state is refused at authoring time, so only pre-gate doctypes and owned children reach it.

  Comparison operators (`__eq`, `__ne`, `__gt`, `__gte`, `__lt`, `__lte`, `__between`, `__in`) on `integer` / `duration` fields are routed through `Document::List#build_typed_clauses`, which reads the JSONB value directly (`content->'field'`) and applies the IMMUTABLE `jsonb_as_numeric` helper. `__eq`/`__ne` take this path only when the field declares an `equality` / `comparison` capability — the declaration that makes `Index::Planner` create the `btree_numeric` index. Without it (for example a unique integer field with no `filters`), they stay on the text path so the text `unique_btree` remains usable. The same builder serves the ordering operators (`__gt`, `__gte`, `__lt`, `__lte`, `__between`, `__in`) on `boolean` fields through `jsonb_as_boolean`; `__eq`/`__ne` on `boolean` stay on the text path because the boolean index is a plain btree on `content->>'field'`. `money` has its own builder (`facet_money_value_as_numeric`). The cast is chosen from the **field's declared type**, not the bound value's runtime JSON type, so query-string scalar filters (parsed as `JSON::Any(String)` by `HTTP::ListRequest.from_query` — array values arrive decoded, see the Filters bullet above) and JSON-body string values are compared numerically rather than lexicographically. The bound value is coerced to the matching SQL type on the parameter side (`$1::numeric` / `$1::boolean`). `__in` (array value) rides the same typed cast on `integer` / `duration` fields — `jsonb_as_numeric(content->'field') = ANY(ARRAY[$n::numeric, …])` — and the text extract on other scalar fields. A non-array `__between` or `__in` value answers 422 (`malformed_filter_value` — the up-front shape validation, see [document.md](document.md) → Behaviour contracts); an empty or over-100-entry `__in` array still degrades to `FALSE`. All other scalar filters (text-typed comparison ops, `__match`/`__starts_with`, and `__eq`/`__ne` on text-typed and `boolean` fields) route through the schema-agnostic `Util::FilterSet` (using the text extract `content->>'field'`).

  Reference fields (`type: reference`, single value) accept both id forms in `__eq` and `__ne`: the bare row id (`meta.id`) and the fully qualified reference token (`{domain}.{Doctype}.{id}`) — the same duality `Document::RowAccess.canonical_doc_id` resolves on single-document routes. A qualified value normalizes down to the bare id, and the clause matches the bare and re-qualified stored forms together. A polymorphic reference (no declared `doctype:` — e.g. the sidecar `target`) has no prefix to derive and keeps the exact match on the caller's value.

  Filter field names must match a doctype `field` that declares a `filters` capability, **or** be one of the system columns exposed as filter targets on every doctype: `id`, `created_at`, `updated_at`, `deleted_at`. A declared field without `filters` has no index and answers 422 (`unsupported_filter_operator`). The capability is opt-in at authoring time; no authoring door applies a default — see [`doctype-system.md`](doctype-system.md#filter-capabilities-filter_capabilitycr). The system-column filters do **not** route through `FilterSet` (whose LHS is `content->>'field'`); `Document::List#build_system_clauses` generates direct comparison clauses against the `projections` columns. `id` accepts `__eq`/`__ne`/`__match`/`__gt`/`__gte`/`__lt`/`__lte`/`__between`/`__in` (lexicographic ULID comparison — chronological by embedded timestamp). `created_at`/`updated_at`/`deleted_at` accept `__eq`/`__ne`/`__gt`/`__gte`/`__lt`/`__lte`/`__between`; `__match` is refused with 422 (`unsupported_filter_operator`) because `ILIKE` has no useful semantics on a `timestamp` column (B-20 — the strict grammar refuses the key instead of degrading to FALSE). `deleted_at` is only meaningful on the trash listing (`?deleted=true`) — live rows always have it NULL. ISO-8601 inputs with timezone offsets are normalized to UTC RFC-3339 before binding (see Time / Timezone in [`workflow.md`](workflow.md)).

  The reserved `parent_id__eq` key scopes the listing to one parent's owned children — the same `meta->>'parent_id' = $n` clause (backed by `idx_projections_parent`) the nested child route drives through `NestedPathResolver`. `Document::List#extract_parent_filter` strips the key before field-filter compilation. The value may be the bare parent doc id or its fully qualified reference token — the anchored `domain.{member_of}.` prefix is stripped, the same convention `Document::ReferenceCheck.strip_qualified_id` uses. The doctype must be an owned child (`member_of` set — otherwise 422, since such rows never carry `parent_id`), a non-string value answers 422, and on a nested child route the key must agree with the path's parent (a conflict answers 422). Other `parent_id__*` suffixes reach the field grammar and 422 as unknown fields.

  Unknown filter field names raise 422 (`unknown_filter_field`, with the filterable list in the message) — a typo never degrades to a no-op or an unfiltered result (the B-20 contract; see [document.md](document.md) → Behaviour contracts).

### QUERY method (RFC 10008)

`QUERY` is a safe, cacheable request whose parameters ride the body. It exists so list calls stop overloading GET with a request body. The QUERY routes mirror the GET routes that already accept a JSON list body; GET keeps the body + query-string merge for backward compatibility, and QUERY is the format new clients should use. The search endpoint (`GET|QUERY /Api/:domain/search`, `GET|QUERY /Api/search`) joins the same pair with a route-specific body key (`q`) — see [`search.md`](search.md).

| Route | File |
|---|---|
| `QUERY /Api/:domain/:doctype` | `src/document/routes.cr` |
| `QUERY /Api/:domain/:doctype/:id/backrefs` | `src/document/routes.cr` |
| `QUERY /Api/:domain/search` | `src/search/routes.cr` |
| `QUERY /Api/search` | `src/search/routes.cr` |
| `QUERY /Api/Audit` | `src/audit/routes.cr` |
| `QUERY /Api/:domain/:doctype/:id/history` | `src/audit/routes.cr` |
| `QUERY /Api/:domain/:doctype/:id/:child/:child_id/history` | `src/audit/routes.cr` |
| `QUERY /Api/Indexes` | `src/index/routes.cr` |
| `QUERY /Api/Artifacts` | `src/artifact/routes.cr` |
| `QUERY /Api/core/Webhook/:id/calls` | `src/webhook/routes.cr` |
| `QUERY /Api/assistant/conversations` | `src/assistant/routes.cr` |

The parse gate is `Gates.query_list_request` (`src/http/gates.cr`). The contract:

- **Body only.** A request that carries any query-string parameter answers `422` — a silently dropped `?page=2` would return wrong results.
- **Empty body** means the defaults (page 1, items 100, sort `id`) — the same as GET with no parameters.
- **JSON object body.** A malformed or non-object body answers `422`.
- **JSON media type required.** A body with a non-JSON `Content-Type` answers `415` (`application/json` and `application/*+json` are accepted). Kemal answers `400` before the route when a QUERY body carries no `Content-Type` at all (RFC 10008) — `JsonErrorHandler` renders it as JSON.
- **Route-specific body keys.** Keys outside the `ListRequest` contract move to the body on QUERY: `include: "children"` on the document-history route (GET reads `?include=children`), and `status` on the webhook-calls route (GET reads `?status=...`). Unknown values behave like GET (ignored / 422 for a bad `status`).
- **Strict body keys.** The body is admitted strictly (the B-169 remainder), like the GET list: a key outside the route's admitted set answers `422 Unknown parameter '<key>'`, never a silent drop. A route that reads keys beyond the grammar names them as `extra_body_keys` (`include`, `status`); a route that reads only a subset of the grammar narrows it with `admitted_keys` (the global audit list admits only `page`, `items`, `sort`, and `filters`).

Responses set `Accept-Query: application/json` on both the GET and QUERY forms, so a client can discover the format from any list response. An unregistered QUERY path answers `405` with the `Allow` header (Kemal router; rendered by `JsonErrorHandler`), and the JSON error body names the accepted methods — see the method convention above.

### HTTP caching (ETag)

**Files:** `src/http/caching.cr`, `src/http/server.cr`, `src/http/rest_routes.cr`, `src/http/list_request.cr`, `src/document/list.cr`, `db/migrations/0001_document_store.sql`

All document read routes emit `ETag` validators honored on the request side by `If-None-Match`. Document write routes (create, update, action) emit the same single-document validator on the response, so a writer holds the fresh validator without a follow-up read. The QUERY forms of the collection routes share the validator of their GET counterpart — the request digest comes from `ListRequest#to_json`, which is transport-independent, so the same parameters via GET and QUERY produce the same `ETag` and a client can switch methods and keep its validator:

| Route | Validator | Bumps on |
|---|---|---|
| `GET /Api/:domain/:doctype/:id` (single document) | `result.projection.state` — the ULID of the last mutation applied | any mutation on this document (create / update / soft-delete / action / rollback to a newer state) |
| `GET /Api/:domain/:doctype/:id/:rel/:child_id` (nested child read, any depth) | same — the child projection's `state`, emitted by the `Document::Read::Result` branch of `Responders.write_result` | any mutation on the child document |
| `GET`/`QUERY /Api/:domain/:doctype` (collection) | `<role>:<request_digest>:<version_tag>` | any mutation on *any* row of this doctype, live or tombstoned |
| `GET /Api/:domain/:doctype/:id/:rel` (nested child list, any depth) | `<role>:<request_digest>:<version_tag>` — `version_tag` is `max(updated_at)` scoped to *this parent's* children (`meta->>'parent_id' = $parent_id`) | any mutation on a child of this parent, live or tombstoned |
| `GET /Api/:domain/:doctype/:id/:sidecar` (sidecar list) | `<role>:sidecar:<version_tag>` — `version_tag` is `max(updated_at)` over the host's live sidecars (matched by the `target` reference column) plus every tombstone of the sidecar doctype | any mutation on a sidecar of this host, or any soft-delete in the sidecar doctype |

The `version_tag` is always serialized via `Time#to_rfc3339(fraction_digits: 6)` and rendered as `"empty"` when no matching rows exist.

#### Single-document ETag

The projection's `state` column already mirrors the mutation row that last touched it (see `db/migrations/0001_document_store.sql` — the projection trigger sets `state = mutation.id` on every action). The HTTP read route adds it on the response and short-circuits to `304 Not Modified` when the client sends a matching `If-None-Match`. The write branches of `Responders.write_result` (create, update, action) emit the same `state` value on their responses; on a write path `state` equals the new mutation id, so the header matches the body's `meta.mid`.

```http
GET /Api/identity/Person/<id>
→ 200
ETag: "01J..."

GET /Api/identity/Person/<id>
If-None-Match: "01J..."
→ 304
```

A `PATCH` that changes the document also produces a new `state`, so the next read returns the new ETag — a stale client never gets a false 304. Lazy migrations set the same state and are visible via the `X-Document-Migrated` header (also set on 304).

#### Collection ETag

For collections, the server needs a single validator that bumps on any data change for the doctype, without running the (potentially expensive) listing query. The validator is composed of three parts:

```
"<role_fingerprint>:<request_digest>:<version_tag>"
```

- **`role_fingerprint`** — `Caching.role_fingerprint(auth_context)`: `"system:<account_id>"` for the system bypass, `"<account_id>:<role_id>"` for an authenticated principal, or `"preview:<account_id>:<preview_domain>"` for a preview-mode capability principal (a preview principal carries no `ActiveRole` — the bound draft domain is the authorization boundary). Prevents a body cached under one role (or an admin's broader view) from being served with a 304 to a different account with the same `version_tag`.
- **`request_digest`** — `Caching.list_request_fingerprint(list_req)`: a 16-char SHA-256 hex digest of `ListRequest#to_json` (the canonical, filter-sorted JSON serialization). The endpoint accepts parameters via JSON body, query string, or both, so the URL alone is insufficient — two semantically-equivalent `ListRequest`s collapse to the same digest regardless of transport.
- **`version_tag`** — `Document::List.collection_version(db, domain, doc_type)`: the result of `SELECT max(updated_at) FROM projections WHERE domain = $1 AND doc_type = $2`, serialized via `Time#to_rfc3339(fraction_digits: 6)` to preserve microsecond precision (the default Crystal `to_rfc3339` strips sub-second parts and would alias same-second mutations). Returns `"empty"` when the doctype has no rows.

On a cache hit, the collection route returns `304` *before* running the items query — the only DB cost is the O(log n) `max(updated_at)` lookup served by the composite index `idx_projections_doctype_updated_at ON projections (domain, doc_type, updated_at)` (`db/migrations/0001_document_store.sql`). Tombstones are intentionally included in the query (no `deleted_at IS NULL` filter) so soft-deletes bump `max(updated_at)` and bust stale caches.

#### Nested child and sidecar collection ETags

The nested child list route (`RestRoutes.rest_get`, odd rest segments at any depth) composes the same three-part tag, with two differences from the top-level list:

- **Version scope** — `Document::List.child_collection_version(db, domain, doc_type, parent_id)` filters `meta->>'parent_id' = $parent_id`, so two parents of the same child doctype never share a validator. Tombstoned children keep `meta` (delete clears only `content`/`links`/`search`), so a soft-deleted child still matches the parent filter and bumps the tag. The lookup is served index-only by `idx_projections_parent_updated_at ON projections (domain, doc_type, (meta->>'parent_id'), updated_at)`.
- **Request digest** — the child list forwards the full list grammar (the flat route's rule), so the fingerprint digests the whole parsed `ListRequest`: page, items, and sort always serialize, so two different pages or orders never share a validator, and two aggregates over different fields never alias.

The short-circuit runs **after** the RBAC parent gate, so a caller without access always gets an authorization answer — the 403 class denial when it holds no read grant on the parent doctype, the non-disclosing `404` when a grant holder cannot see the parent — never a cache short-circuit (an `If-None-Match: *` must not buy a 304 past authorization).

The sidecar list route composes `<role>:sidecar:<version_tag>` — every list parameter is fixed by the path (the `target` filter is the host URN), so the digest slot holds a constant marker. The version query (`Document::List.sidecar_collection_version`) matches live rows by the sidecar's declared `target` reference column, but includes every tombstone of the sidecar doctype **without** the column filter: `delete` clears `content`, so a tombstoned sidecar no longer carries its `target` and cannot be matched to its host. The tag therefore stays correct (a delete must bust the cache) at the cost of precision — a soft-deleted sidecar busts the tag of every host listing that sidecar doctype, not only its own host's. Gates (`ReadEnforcer.parent_authorized?` then `sidecar_authorized?`) run before the ETag check.

```http
GET /Api/core/DocType
→ 200
ETag: "system:system:9d9adb31646a4256:2026-07-19T17:47:39.000123Z"

GET /Api/core/DocType
If-None-Match: "system:system:9d9adb31646a4256:2026-07-19T17:47:39.000123Z"
→ 304
```

#### Why `updated_at`, not the ULID `state`

`max(state)` is non-monotonic within the same millisecond. Each `ulid()` call (`db/migrations/0001_document_store.sql`) uses `clock_timestamp()` for the millisecond prefix but **freshly samples** the 80-bit random suffix on every call. Two mutations landing in the same millisecond therefore sort in arbitrary lexicographic order — `max(state)` can stay on the older ULID on a real data change, producing a false 304.

`updated_at` is microsecond-resolution and is advanced by the projection trigger on every mutation (`UPDATE ... updated_at = mutation.emitted_at`). Microsecond-level collisions are negligible for cache validation. Document IDs are also user-selectable, so any id-derived signal is unsafe as a version tag.

#### `If-None-Match` parsing

`Caching.not_modified?(env, tag)` handles the standard `If-None-Match` shapes:
- `*` — always matches (returns 304).
- `"value1", "value2"` — comma-separated validators; matches if any equals the strong ETag the server would emit.
- `W/"value"` — weak validators sent by the client are treated as equivalent to the strong validator we emit (per RFC 7232 § 3.2, weak validators are acceptable for `If-None-Match` on GET).

The server only emits strong validators. `Cache-Control: no-cache` is set on `304` responses so browsers and intermediaries revalidate every subsequent request (the validator is the cache, not a freshness lifetime).

#### Scope

ETag covers the document read routes:
- `GET /Api/:domain/:doctype` (collection) and `GET /Api/:domain/:doctype/:id` (single document)
- Nested child routes under `/Api/:domain/:doctype/:id/:rel/...` resolved through `NestedPathResolver` — child lists, single child reads, and single-segment sidecar lists

Not covered:
- `/Api/Audit` and `/Api/assistant/...` (separate concern routes, not documents).
