---
type: how-to
title: Health checks, metrics, tracing, logs
description: Check health, scrape metrics, collect traces, and set the log format and level.
audience: [operator]
features: [PLT-06, PLT-07, PLT-08, PLT-09, AUT-01]
sidebar:
  order: 1
verified_at: f1409cdc
---

The backend exposes four observability surfaces. `/Healthcheck` answers
readiness probes. `/metrics` answers a Prometheus scrape. OpenTelemetry
exports traces to a collector. Logs print to stdout as text or JSON. The
probes, the metrics, and the logs work with no setup. Tracing sends
nothing until you set one environment variable.

## When to use this

Set up observability when:

- You wire orchestrator probes to the backend.
- You scrape metrics or alert on them.
- You ship traces to a collector.
- You set the log format and level for the deployment.

## Before you start

- The probes and `/metrics` sit on the backend port, on the private
  network. The public edge does not route `/metrics`.
- The backend listens on `3000`. The edge (Caddy) publishes the TLS port
  instead — `3443` by default. Every `127.0.0.1:3000` address on this page is
  the backend port, reachable from inside the Docker network only. Run a
  `curl` against it from a shell in the stack, for example
  `docker compose -f docker/compose.prod.yml exec backend curl -sf
  http://127.0.0.1:3000/Healthcheck`.
- Tracing reads three standard OTLP environment variables. They are the
  one deliberate exception to the config-file rule: the OpenTelemetry
  shard reads them itself.

## Steps

### 1. Wire the probes

| Route | Use | Behaviour |
| --- | --- | --- |
| `GET /Healthcheck` | Readiness probe | Checks every database pool, Redis, and the stream consumers. Answers `200` or `503`. |
| `GET /Healthcheck/live` | Liveness probe | No dependency checks. Always `200` while the process is alive. |

Use `/Healthcheck` as the readiness probe only. Dependency health flaps
it, and a restart loop helps no one. Use `/Healthcheck/live` as the
liveness probe: it fails only when the process is gone.

The readiness body names the part that fails:

```json
{
  "status": "ok",
  "service": { "env": "production", "instance_id": "01JD8ZQ7M5T3R8XK2VBN4QW7TY" },
  "database": {
    "status": "ok",
    "error": null,
    "pools": [
      { "database": "main", "role": "rw", "status": "ok", "error": null }
    ]
  },
  "redis": { "status": "ok", "error": null },
  "events": {
    "status": "ok",
    "consumers": [
      {
        "name": "hr",
        "consecutive_failures": 0,
        "restarts": 0,
        "last_success_at": "2026-11-13T07:52:32Z",
        "last_error": null
      }
    ]
  },
  "event_loss": {
    "publish_flush_failures": 0,
    "publish_events_dropped": 0,
    "messages_dropped": 0
  },
  "event_lag": { "max_lag": 0 }
}
```

`service.instance_id` is one id per boot. Match it against the boot log
when you debug one instance of many.

### 2. Read the event-loss counters

Event delivery is at-most-once by decision. The `event_loss` object
makes the silent part visible:

| Key | Counts |
| --- | --- |
| `publish_flush_failures` | Failed publisher flush passes. |
| `publish_events_dropped` | Events discarded in those failed flushes. |
| `messages_dropped` | Messages a consumer dropped after a handler error. |

The counters are in-process and reset on restart. They are visibility,
not accounting: PostgreSQL holds the durable state.

`event_lag.max_lag` is the largest consumer-group lag the last lag-check
pass observed. The pass runs every 10 minutes by default. A rising value
warns before a slow consumer loses entries to the stream trim.

### 3. Scrape the metrics

`GET /metrics` serves the Prometheus text format 0.0.4. It needs no
auth. Counters are per process, so scrape every instance and let
Prometheus do the aggregation.

Counters raised by the code:

| Metric | Labels | Counts |
| --- | --- | --- |
| `facet_events_published_total` | — | Events published to the bus. |
| `facet_messages_processed_total` | `consumer` | Messages a consumer group processed. |
| `facet_jobs_enqueued_total` | `kind` | Job rows inserted. |
| `facet_jobs_claimed_total` | `kind` | Job rows claimed by a worker. |
| `facet_jobs_succeeded_total` | `kind` | Job rows that finished `succeeded`. |
| `facet_jobs_failed_total` | `kind` | Job rows that finished `failed`. |
| `facet_jobs_abandoned_total` | `kind` | Rows the lease sweep recovered. |
| `facet_http_requests_total` | `method`, `route`, `status_class` | HTTP requests, by final status class. |
| `facet_db_checkout_total` | `database`, `role` | Connection-pool checkouts. The pool-sizing input. |
| `facet_cron_task_failures_total` | `task` | Cron task runs that raised. |
| `facet_cron_task_lease_skips_total` | `task` | Dispatches another instance already fired. |
| `facet_fiber_restarts_total` | `fiber` | Supervised fiber restarts. |
| `facet_fiber_loop_errors_total` | `fiber` | Long-lived loop turns that rescued an error. |

Gauges and counters read from live state at each scrape:

| Metric | Type | Source |
| --- | --- | --- |
| `facet_event_loss_publish_flush_failures_total` | counter | The `event_loss` publisher counter. |
| `facet_event_loss_publish_events_dropped_total` | counter | The `event_loss` dropped-events counter. |
| `facet_event_loss_messages_dropped_total` | counter | The `event_loss` dropped-messages counter. |
| `facet_consumer_consecutive_failures{name}` | gauge | One stream consumer's failure streak. |
| `facet_consumer_restarts_total{name}` | counter | One stream consumer's supervised restarts. |
| `facet_event_lag_max` | gauge | The max consumer-group lag of the last lag-check pass. |

### 4. Turn on tracing

Set three environment variables before the boot:

```sh
export OTEL_SERVICE_NAME=facet
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4318
export OTEL_RESOURCE_ATTRIBUTES=environment=production
```

With no endpoint set, the process builds spans and drops them. That is
the safe default for dev and test.

Every HTTP request opens a root span named `http.server.request`. Every
SQL statement opens a `db.query` span, with the SQL text truncated to
2000 characters. A span that ends in an error carries error status, so
failed writes are findable in the trace. Telemetry failures never fail
the request they observe.

### 5. Set the log format and level

The optional `logs:` section drives the whole process:

| Key | Values | Default |
| --- | --- | --- |
| `format` | `text`, `json` | `text` |
| `level` | `trace`, `debug`, `info`, `notice`, `warn`, `error`, `fatal` | `info` |

An unknown value fails the boot. The `LOG_LEVEL` environment variable
does not affect the app process; the file is the one source.

In `json` format, one object prints per line:

| Field | Content |
| --- | --- |
| `ts` | Entry timestamp, RFC-3339 UTC. |
| `level` | Severity label, for example `INFO`. |
| `source` | Log source, for example `facet.jobs.manager`. |
| `message` | The entry message. |
| `exception` | `{class, message}`, when the entry carries one. |
| `context` | The fiber-local log context, when set. |

:::tip
Log lines never carry credentials. The Redis URL prints as `host:port/db`,
never with its password.
:::

## Example

A complete production setup: JSON logs at `info`, tracing on, and a probe
check after a deploy.

```yaml
logs:
  format: json
  level: info
```

```sh
export OTEL_SERVICE_NAME=facet
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4318
export OTEL_RESOURCE_ATTRIBUTES=environment=production

curl -sf http://127.0.0.1:3000/Healthcheck
```

## Troubleshooting

**`/Healthcheck` answers `503` with `status: degraded`.**

A stream consumer reports consecutive failures, or a database pool or
Redis is down. Read `events.consumers`, `database.pools`, and `redis` in
the body. The consumer state self-heals on the next clean turn.

**`/Healthcheck` is green but events do not react.**

The consumer group may be gone, for example after a Redis data loss. The
loop logs a WARN that names the group and the stream. A backend restart
re-creates the groups at boot.

**`/metrics` answers 404 through the public hostname.**

The edge does not route it. Scrape the backend port on the private network,
for example `http://127.0.0.1:3000/metrics` from inside the Docker network.
From the host, run the scrape in the backend container:
`docker compose -f docker/compose.prod.yml exec backend curl -sf
http://127.0.0.1:3000/metrics`.

**No traces reach the collector.**

`OTEL_EXPORTER_OTLP_ENDPOINT` is unset or unreachable. Without it the
process builds spans and discards them. The exporter speaks the OTLP
HTTP protocol.

**A level change does nothing.**

`LOG_LEVEL` does not drive the app process. Set `logs.level` in the
config file and restart.

## Related

- [Event delivery](/admin/under-the-hood/events-and-delivery/) — the at-most-once contract the loss counters make visible.
- [Background jobs and cron](/admin/keep-running/jobs-cron/) — the job kinds behind the job metrics.
- [Deploying with containers](/admin/install/containers/) — the image healthcheck that curls `/Healthcheck`.
- [Database migrations](/admin/keep-running/migrations/) — the boot chain the readiness probe guards.
- Internals on GitHub: [metrics.md](https://github.com/wearefacet/facet/blob/main/doc/backend/metrics.md), [telemetry.md](https://github.com/wearefacet/facet/blob/main/doc/backend/telemetry.md), [logging.md](https://github.com/wearefacet/facet/blob/main/doc/backend/logging.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
