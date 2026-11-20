---
title: Sondes et métriques
description: Chaque champ de sonde de santé et chaque nom de métrique exposés par le serveur.
audience: [operator]
features: [PLT-06, PLT-07]
sidebar:
  order: 17
verified_at: 008dd880
---

> Généré depuis `src/http/healthcheck.cr`, `src/event/loss.cr`, `src/event/consumer_health.cr` et `src/metrics.cr` par `make gen-docs-health-metrics`. Ne modifiez pas ce fichier à la main.

Cette page sert à lire une réponse de sonde ou à nommer une métrique dans vos tableaux de bord et vos alertes.

Le serveur expose deux sondes et un point de collecte :
- `GET /Healthcheck` vérifie la préparation.
- `GET /Healthcheck/live` vérifie la vivacité.
- `GET /metrics` sert le format d’exposition texte Prometheus 0.0.4.

Les deux sondes répondent sans authentification. La sonde de préparation répond HTTP 503 quand une dépendance est injoignable ou qu’un consommateur de flux est dégradé.

## Sonde de santé

Tout ce que renvoie `GET /Healthcheck`. Un chemin `[]` est une entrée du champ tableau : la sonde renvoie une entrée de pool par pool de base de données et une entrée de consommateur par groupe de consommateurs de flux. La sonde de vivacité ne renvoie que les deux champs `live.*`.

| Champ | Signification |
|---|---|
| `database.error` | The first pool error, when a pool is broken. |
| `database.pools[].database` | The database entry name from the route table. |
| `database.pools[].error` | The error this pool raised, when it is broken. |
| `database.pools[].role` | The pool role: rw or ro. |
| `database.pools[].status` | ok when this pool answers the SELECT 1 probe. |
| `database.status` | ok when every pool answers the SELECT 1 probe. |
| `event_lag.max_lag` | Largest consumer-group lag the last lag-check pass observed. |
| `event_loss.messages_dropped` | Dispatched messages dropped by handler errors since process start. |
| `event_loss.publish_events_dropped` | Events dropped by failed publish flushes since process start. |
| `event_loss.publish_flush_failures` | Failed publish flushes since process start. |
| `events.consumers[].consecutive_failures` | Failed loop turns in a row for this consumer. |
| `events.consumers[].last_error` | The last error message this consumer reported. |
| `events.consumers[].last_success_at` | RFC-3339 time of the consumer's last successful loop turn. |
| `events.consumers[].name` | The stream consumer group name. |
| `events.consumers[].restarts` | Supervised restarts of this consumer since process start. |
| `events.status` | ok, in_process under the in-process manager, or degraded when a consumer reports consecutive failures. |
| `redis.error` | The Redis error, when the probe fails. |
| `redis.status` | ok when Redis answers, in_process under the in-process manager, error when unreachable. |
| `service.env` | The APP_ENV the process boots in. |
| `service.instance_id` | One instance id per boot; matches the boot log and the shard-lock holders in Redis. |
| `status` | ok when every dependency passes, degraded otherwise; HTTP 200 answers ok, HTTP 503 answers degraded. |
| `live.status` | Always ok while the process answers. |
| `live.uptime_seconds` | Seconds since the process started. |

## Métriques

Chaque nom de métrique émis par le serveur, avec son type d’exposition. Le même registre rend aussi tout nom non catalogué comme un compteur avec une ligne d’aide générique ; le catalogue ci-dessous est l’ensemble documenté complet.

| Nom | Type | Signification |
|---|---|---|
| `facet_consumer_consecutive_failures` | gauge | Consecutive failed loop turns per stream consumer group. |
| `facet_consumer_restarts_total` | counter | Supervised fiber restarts per stream consumer group since process start. |
| `facet_cron_task_failures_total` | counter | Cron task firings that raised, per task id. |
| `facet_cron_task_lease_skips_total` | counter | Cron task dispatches skipped because another instance holds the tick lease, per task id. |
| `facet_db_checkout_total` | counter | Pooled connection checkouts, by database entry and pool role (rw/ro). |
| `facet_event_lag_max` | gauge | Maximum consumer-group lag observed by the last Cron::EventLagCheck pass. |
| `facet_event_loss_messages_dropped_total` | counter | Dispatched messages swallowed by handler errors since process start. |
| `facet_event_loss_publish_events_dropped_total` | counter | Events dropped by failed publish flushes since process start. |
| `facet_event_loss_publish_flush_failures_total` | counter | Failed Event::Publisher.flush calls since process start. |
| `facet_events_published_total` | counter | Resource events written to the Redis streams by this process. |
| `facet_fiber_loop_errors_total` | counter | Long-lived loop turns that rescued an exception, by fiber name. |
| `facet_fiber_restarts_total` | counter | Supervised fiber restarts, by fiber name, since process start. |
| `facet_http_requests_total` | counter | HTTP requests handled, by method, route group, and status class. |
| `facet_jobs_abandoned_total` | counter | Background job rows requeued by the expired-lease sweep, per kind. |
| `facet_jobs_claimed_total` | counter | Background job rows claimed by the worker, per kind. |
| `facet_jobs_enqueued_total` | counter | Background job rows inserted, per kind. |
| `facet_jobs_failed_total` | counter | Background job attempts written as failed, per kind. |
| `facet_jobs_succeeded_total` | counter | Background job attempts written as succeeded, per kind. |
| `facet_messages_processed_total` | counter | Stream messages dispatched to a subscription handler, per consumer group. |

## Voir aussi

- [/fr/operate/health-metrics-logs/](/fr/operate/health-metrics-logs/)