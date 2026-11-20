# Telemetry

Telemetry uses [OpenTelemetry](https://opentelemetry.io) (the `jgaskins/opentelemetry` Crystal shard) to instrument the application for distributed tracing. Spans are exported via the OTLP HTTP protocol.

## Source files

- `src/telemetry.cr` — require root. `Facet::Telemetry` module: configuration, init, the span error helpers, and `Facet::Telemetry.trace` — the guarded entry point every first-party span goes through
- `src/telemetry/middleware.cr` — `Facet::Telemetry::Middleware`, the first-party HTTP middleware
- `src/telemetry/span_patch.cr` — re-opens `OpenTelemetry::API::Span` to serialize the span status
- `src/telemetry/db_integration.cr` — Custom DB instrumentation compatible with crystal-db 0.14.x
- `lib/opentelemetry/` — The upstream shard (trace API, exporters, protobuf, `opentelemetry/integrations/redis`)

## Configuration

Telemetry is configured via standard OTLP environment variables. All are optional — when `OTEL_EXPORTER_OTLP_ENDPOINT` is unset, the `NullExporter` is used and all spans are discarded (safe for dev/test).

| Environment variable | Default | Purpose |
|---|---|---|
| `OTEL_SERVICE_NAME` | `facet` | Service name in traces and resource attributes |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | (none → NullExporter) | OTLP HTTP exporter endpoint (e.g. `https://Api.honeycomb.io`) |
| `OTEL_RESOURCE_ATTRIBUTES` | (none) | Comma-separated `key=value` resource attributes |

`Facet::Telemetry.init` sets `c.service_name = "facet"` as the in-code default only — the shard reads `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` itself, inside `OpenTelemetry.configure` (after the yield block), so both variables take precedence over the hardcoded default. No app code needs to forward them. These variables are the deliberate exception to the config golden rule: they are standard OTLP knobs read by the shard, not app config keys.

Example Honeycomb setup:

```bash
export OTEL_SERVICE_NAME=facet
export OTEL_EXPORTER_OTLP_ENDPOINT=https://Api.honeycomb.io
export OTEL_RESOURCE_ATTRIBUTES=environment=production
```

## Initialization

`Facet::Telemetry.init` is called in the `server` CLI command before `Kemal.run`. It configures the exporter and loads instrumentation integrations (Redis).

When `OTEL_EXPORTER_OTLP_ENDPOINT` is set, `init` first opens a TCP connection to the endpoint's host and port (2 s connect timeout). A connect failure — a refused port, a host that does not resolve, or a firewalled sink that drops packets (the connect times out) — downgrades the exporter to `NullExporter` with one WARN on `facet.telemetry`. The deployment loses telemetry, never its event pipeline (an unreachable sink left live can raise into the event-consumer fibers through the exporter queue). A firewalled sink therefore loses telemetry too: the probe cannot tell a firewall from a dead sink. The probe tests the TCP handshake only — a sink that accepts connections keeps the exporter, however slow it is after that. No other exception is caught: the probe cannot classify it, so it fails the boot.

The test suite also calls `Facet::Telemetry.init` before the template database is provisioned, ensuring the `NullExporter` is active during tests (no telemetry is sent from test runs).

## HTTP middleware

`Facet::Telemetry::Middleware` (first-party, in `src/telemetry/middleware.cr`) is added as the first handler in Kemal's middleware stack in `Facet::HTTP::Server.routes`:

```crystal
Kemal.config.add_handler Facet::Telemetry.middleware
```

The upstream shard's `OpenTelemetry::Middleware` is not used: its `http.client_ip` collection reads `request.remote_address.as(Socket::IPAddress).address`, which raises a `TypeCastError` on every request that has no socket behind it (in-process test harness, HTTP/1.0 clients) and on Unix-socket deployments — an observability failure that turned into a 500. The first-party middleware keeps the same span and attribute set and collects `http.client_ip` nil-safely through the shared client-IP resolver (`Util::ClientIp.resolve` — see [`util-client-ip.md`](util-client-ip.md)): the socket host, or the `X-Forwarded-For` hop the routes trust when the socket peer is a configured `trusted_proxies` entry. Attribute collection and response stamping are guarded: telemetry must never fail the request it observes, and route exceptions still propagate untouched to the error handlers.

This creates a root span named `http.server.request` for every HTTP request with semantic attributes: method, path, status code, user-agent, client IP, host, query parameters.

## Guarded spans (`Facet::Telemetry.trace`)

Every first-party span goes through `Facet::Telemetry.trace(name) { |span| ... }` (`src/telemetry.cr`), not through `OpenTelemetry.trace` directly. The shard ends the span and exports the trace in an `ensure` with no rescue, so with OTLP export on, a failure at span end or export time would otherwise propagate into — and fail — the operation the span observes (this exact crash motivated the wrapper). The guard's contract:

- Telemetry machinery failures (span end, serialization, export) are logged once on `facet.telemetry` and dropped; the block result is still returned.
- Exceptions raised by the traced block itself keep propagating — error handlers, `ServiceError` unions, and the Lua error conversion rely on them.
- On a double fault (the block raises and the exporter also raises mid-unwind), the block exception wins; the exporter failure is logged and dropped.

`spec/telemetry/trace_guard_spec.cr` pins the contract. Known residual: the shard's own Redis integration (`lib/opentelemetry/src/integrations/redis.cr`) still calls `OpenTelemetry.trace` directly, so a crash there can fail the Redis command it wraps — not reachable from first-party code without a fork.

On requests authenticated with an app token (`typ: "app"` JWT), `HTTP::AuthHandler.build_app_auth_context` sets three additional attributes on the current span before the grant is re-resolved (Phase 6):

| Attribute | Source |
|---|---|
| `app` | `app.App` projection id from the JWT `app` claim |
| `role` | `iam.Roles` name from the JWT `role` claim |
| `sid` | app session id from the JWT `sid` claim |

`current_span` is nil only when telemetry is fully disabled (the `NullExporter` still creates spans, so this is the no-config case).

## Instrumentation spans

### HTTP (root span)

| Span name | Source | Attributes |
|---|---|---|
| `http.server.request` | `Facet::Telemetry::Middleware` | `http.method`, `http.path`, `http.target`, `http.status_code`, `http.host`, `http.server_name`, `http.client_ip`, `http.user_agent`, `http.flavor`, `request.query_params.*` |

### Document operations

| Span name | Source | Attributes |
|---|---|---|
| `document.create` | `Document::Create.call` | `domain`, `doc_type`, `doc_id`, `mutation_id` |
| `document.read` | `Document::Read.call` | `domain`, `doc_type`, `doc_id`, `migrated` |
| `document.update` | `Document::Update.call` | `domain`, `doc_type`, `doc_id`, `mutation_id` |
| `document.delete` | `Document::Delete.call` | `domain`, `doc_type`, `doc_id`, `mutation_id` |
| `document.action` | `Document::Action.call` | `domain`, `doc_type`, `doc_id`, `action_name`, `mutation_id` |
| `document.create_with_children` | `Document::CreateWithChildren.call` | `domain`, `doc_type`, `doc_id`, `mutation_id`, `child_count` |
| `document.list` | `Document::List.call` | `domain`, `doc_type`, `page`, `items_per_page`, `total` |
| `document.migrate` | `Document::Migrate.call` | `domain`, `doc_type`, `doc_id`, `from_version`, `to_version`, `migration_count` |
| `document.compute` | `Document::Compute.call` | `field_count` |

### Doctype operations

| Span name | Source | Attributes |
|---|---|---|
| `doctype.create` | `Doctype::Create.call` | `domain`, `doc_type`, `doc_id`, `mutation_id` |
| `doctype.update` | `Doctype::Update.call` | `domain`, `doc_type`, `mutation_id` |

### Mutation client (low-level SQL persistence)

| Span name | Source | Attributes |
|---|---|---|
| `mutation.client.create` | `Mutation::Client.create` | `domain`, `doc_type`, `action`, `app` (when the mutation is app-attributed) |
| `mutation.client.update` | `Mutation::Client.update` | `domain`, `doc_type`, `action`, `app` (when the mutation is app-attributed) |
| `mutation.client.delete` | `Mutation::Client.delete` | `domain`, `doc_type`, `action`, `app` (when the mutation is app-attributed) |
| `mutation.client.snapshot` | `Mutation::Client.snapshot_mutation` | `domain`, `doc_type`, `action`, `app` (when the mutation is app-attributed) |

### Infrastructure

| Span name | Source | Attributes |
|---|---|---|
| `lua.evaluate` | `Lua::Engine.run` | — (lightweight wrapper) |
| `index.sync` | `Index::Manager.sync` | `domain`, `doc_type`, `to_add`, `to_remove` |
| `audit.rollback` | `Audit::Rollback.call` | `mutation_id`, `doc_id`, `new_mutation_id` |
| `db.transaction` | `Database.with_transaction`, `DB::BeginTransaction#transaction` | `db.pool` (the `with_transaction` form only — `database/role`, e.g. `main/rw`) |

### Automatic integrations (Redis)

Redis commands are instrumented automatically via `require "opentelemetry/integrations/redis"`. Each Redis command produces a span with the command name and arguments:

| Attribute | Value |
|---|---|
| `db.system` | `redis` |
| `net.peer.name` | Redis host |
| `db.statement` | Full command string |
| `db.redis.database_index` | Redis DB index |

## Error status

Every span that returns an `Error` result type sets `span.status` to `error` with the error message. This includes 403/404/422/500 responses from document/doctype operations.

## DB integration

The upstream `opentelemetry/integrations/db.cr` is **not** used because it depends on `connection.context.uri` which does not exist in crystal-db 0.14.0. Instead, a custom `src/telemetry/db_integration.cr` provides:

- `DB::Statement#around_query_or_exec` instrumentation — one `db.query` span per SQL statement. Pooled calls, connection-level calls, and transaction calls all pass through this hook. crystal-db 0.14 defines the `def_around_query_or_exec` macro on `DB::Statement` itself, so reopening the class after `pg` is loaded works (the hook chains through `previous_def` and keeps crystal-db's own query logging).
- `DB::BeginTransaction#transaction` instrumentation (`db.transaction` spans)

`Facet::Database.with_transaction` issues `BEGIN`/`COMMIT` directly and bypasses crystal-db's `DB::Transaction`, so it creates its own `db.transaction` span in `src/database.cr`.

| Span name | Attributes |
|---|---|
| `db.query` | `db.system` (`postgresql`), `db.statement` (SQL text, truncated to 2000 chars) |
| `db.transaction` | `db.pool` — `database/role` of the pinned pool (e.g. `main/rw`, `main/ro`); `external` when the transaction runs on a raw, unpinned connection (the seeds). The crystal-db integration's own `db.transaction` spans carry no attribute. |

The `db.pool` attribute names the route table entry and pool role the transaction ran on — the observability counterpart of the read/write segregation (see [`workflow.md`](workflow.md) → Database quirks). Checkout counts per pool are the metric `facet_db_checkout_total{database, role}` (see [`metrics.md`](metrics.md)).

Notes:

- Every statement gets a span — there is no duration threshold. This matches the Redis integration (one span per command).
- `BEGIN`, `COMMIT`, and `ROLLBACK` do not get spans; the enclosing `db.transaction` span measures them. `SAVEPOINT` / `RELEASE SAVEPOINT` / `ROLLBACK TO` do get spans — they show the nested-transaction structure.
- A failing statement sets the span status to `error` (via `Facet::Telemetry.trace`).
- For a read (`query`) call, the span ends when the driver receives the row description — the time spent reading rows back lands on the enclosing span. `exec` spans are exact.
- `PG::Connection#exec_all` (migrations) bypasses `DB::Statement` and stays uninstrumented.
- Query spans nest under the span that is current on the fiber: the HTTP root span, the `document.*` span, or the `db.transaction` span.

## Upstream shard gaps

One gap is fixed app-side in `src/telemetry/span_patch.cr` (no lib change):

1. **`API::Span#to_protobuf` drops the span status** — the upstream serializer never attaches `span.status`, so error states set via `span.status =` never reach the collector. `src/telemetry/span_patch.cr` re-opens `OpenTelemetry::API::Span` and attaches the status after the upstream serialization.

2. **`OpenTelemetry::Middleware` is not used** — replaced by the first-party `Facet::Telemetry::Middleware` (see HTTP middleware above); the shard's middleware class stays unreferenced.