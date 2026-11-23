# Metrics

In-process metrics registry exposed on `GET /metrics` in the Prometheus text exposition format 0.0.4.

## Source files

- `src/metrics.cr` — `Facet::Metrics`: the registry (`inc` / `set` / `value` / `render` / `reset`) and the metric catalog
- `src/http/metrics_route.cr` — `HTTP::MetricsRoute`: the scrape endpoint plus the scrape-time gauges
- `src/http/metrics_handler.cr` — `HTTP::MetricsHandler`: the request counter middleware

## Why in-process

The OpenTelemetry shard carries a traces-only API — no metrics. The registry is a small, local series store (counters and gauges keyed by metric name plus a bounded label set, mutex-guarded) — the same posture as `Event::Loss` and `Event::ConsumerHealth`: process-wide, reset on restart, no new shard dependency. Counters are per process; multi-instance deployments scrape every instance and Prometheus does the aggregation.

## Registry API

```crystal
Facet::Metrics.inc("facet_jobs_enqueued_total", {"kind" => kind})     # counter, +1
Facet::Metrics.inc("facet_events_published_total", by: 3)            # counter, +3
Facet::Metrics.set("facet_event_lag_max", lag)                       # gauge, absolute value
Facet::Metrics.value("facet_jobs_failed_total", {"kind" => "x"})     # current value (specs / diagnostics)
Facet::Metrics.render                                                # exposition body
Facet::Metrics.reset                                                 # spec support only
```

`render` emits one `# HELP` / `# TYPE` pair per metric name (names sorted), then one sample per series sorted by label set. Label values are escaped (`\`, `"`, newline). Catalog-less names render as counters with a generic help line. Integer-valued series render without a decimal point.

## Scrape topology

`GET /metrics` is whitelisted in `AuthHandler::PUBLIC_ROUTES` — **no auth, by decision** (D1). The dev Caddyfile does not route `/metrics` to the backend, so the endpoint is not reachable through the public origin; the scrape address is the backend origin on the private network (e.g. `http://127.0.0.1:3000/metrics`). Content type: `text/plain; version=0.0.4; charset=utf-8`.

## Metric catalog

Counters (hooks in existing code):

| Metric | Labels | Hook |
| --- | --- | --- |
| `facet_events_published_total` | — | `Event::Manager#publish_resource_event` + `#publish`, after the successful `xadd` |
| `facet_messages_processed_total` | `consumer` | `Subscriber::Stream#process_messages_for_channel`, per message after `process_message` — all managers' consumers (general, replication, hooks, webhook, sidecar sweep) report under their consumer-group name |
| `facet_jobs_enqueued_total` | `kind` | `Jobs::Worker#enqueue` + the `Jobs::Manager` enqueue-only branch — one increment per inserted row, whichever path staged it |
| `facet_jobs_claimed_total` | `kind` | `Jobs::Worker#tick`, per claimed row |
| `facet_jobs_succeeded_total` / `facet_jobs_failed_total` | `kind` | `Jobs::Worker#write_result`, by `result.status` |
| `facet_jobs_abandoned_total` | `kind` | `Jobs::Worker#run_maintenance`, per lease-swept row |
| `facet_http_requests_total` | `method`, `route`, `status_class` | `HTTP::MetricsHandler`, registered **first** in the middleware stack so it wraps every other handler and reads the final status after `call_next` |
| `facet_db_checkout_total` | `database`, `role` | `Database.with_connection`, per pool checkout (pin reuse never counts). `database` names the route-table entry (back-compat single pool: `main`); `role` is `rw` or `ro`. The series is the pool-sizing input — tune `max_pool_size` from the observed checkout rate and the escalation paths (a nested rw block inside a ro scope holds two connections per fiber for its duration) |
| `facet_db_poisoned_discards_total` | — | `PG::Connection#release` (`src/database/wire_guard.cr`), when a connection is closed instead of pooled because a response was still queued on its socket. Any increment means a code path abandoned a result set — see [`workflow.md`](workflow.md) → Database quirks |
| `facet_cron_task_failures_total` | `task` | `Cron::Scheduler#spawn_fire`, in the task-fiber rescue |
| `facet_cron_task_lease_skips_total` | `task` | `Cron::Scheduler#spawn_fire`, per dispatch skipped because another instance holds the tick lease |
| `facet_fiber_restarts_total` | `fiber` | `Util::FiberSupervisor#supervise`, per supervised restart — covers every long-lived fiber (stream consumers, cache subscribers, fanout, cron/hooks/jobs loops, dev watcher) |
| `facet_fiber_loop_errors_total` | `fiber` | The long-lived loop rescues: `PatternSubscriber#run`, `Fanout#run` + resubscribe pass + command drain, `Hooks::Scheduler` tick, `Jobs::Worker#tick`, `Dev::DomainWatcher#poll_once` — one increment per rescued loop turn |

Label value sets:

| Label | Values |
| --- | --- |
| `consumer` | Consumer-group names (`hr`, `cg:repl:hr`, `cg:hooks:hr`, …) — one per running stream consumer |
| `kind` | Registered job kinds (`webhook_delivery`, `document_export`, `document_import`) |
| `method` | HTTP verb |
| `route` | First path segment, one of a fixed set: `/Api`, `/OAuth`, `/A`, `/auth`, `/Ws`, `/.well-known`, `/Healthcheck`, `/metrics` — anything else collapses into `other` (request scanners cannot mint label values). The domain segment collapses into `/Api` (tenant cardinality stays out) |
| `status_class` | `1xx` … `5xx` |
| `task` | Registered cron task ids (`sidecar.reconcile`, `mutations.compaction`, …) |
| `fiber` | Supervised fiber names — a bounded per-process set (`Event Stream Subscriber (hr)`, `Event Stream Liveness (hr)`, `DoctypeCache Subscriber (<service_id>)`, `Fanout Subscriber (<service_id>)`, `Fanout Command Drain (<service_id>)`, `Cron Scheduler`, `Hooks Scheduler`, `Jobs Worker`, `Dev Domain Watcher`). The service-id suffix is a per-boot ULID (`Facet::Service`): bounded per process, one new label value per subsystem per restart |

Gauges and scrape-sourced counters (no hooks — rendered from existing state at each scrape, in `MetricsRoute.collect_gauges`):

| Metric | Type | Source |
| --- | --- | --- |
| `facet_event_loss_publish_flush_failures_total` | counter | `Event::Loss.snapshot` |
| `facet_event_loss_publish_events_dropped_total` | counter | `Event::Loss.snapshot` |
| `facet_event_loss_messages_dropped_total` | counter | `Event::Loss.snapshot` |
| `facet_consumer_consecutive_failures{name}` | gauge | `Event::ConsumerHealth.snapshot` |
| `facet_consumer_restarts_total{name}` | counter | `Event::ConsumerHealth.snapshot` |
| `facet_event_lag_max` | gauge | `Cron::EventLagCheck.max_lag` |

## Cardinality policy

Labels must come from bounded sets — the sets above, declared in the catalog and enforced by review, not at runtime. A label with unbounded cardinality (document id, tenant, path) must never reach `inc` / `set`.

## Deliberately not here

- Histograms (HTTP latency, shard-lock wait) — counters first; histograms need a bucket policy. A follow-up if operators ask for latency SLOs.
- `facet_jobs_pending` (queue depth) — needs a scrape-time DB query; can be added later without breaking the registry.
- `mutations` growth and artifact-storage gauges — runbook material; scrape-time SQL or cron aggregation.
- `facet_build_info{version}` — blocked on the version finding (32).
