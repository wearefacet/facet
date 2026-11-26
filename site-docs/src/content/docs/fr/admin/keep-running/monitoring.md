---
title: Health checks, métriques, tracing, logs
description: Vérifiez la santé, scrapez les métriques, collectez les traces, et réglez le format et le niveau des logs.
audience: [operator]
features: [PLT-06, PLT-07, PLT-08, PLT-09, AUT-01]
sidebar:
  order: 13
verified_at: f1409cdc
---

Le backend expose quatre surfaces d’observabilité. `/Healthcheck` répond aux
sondes de disponibilité. `/metrics` répond à un scrape Prometheus.
OpenTelemetry exporte des traces vers un collecteur. Les logs s’impriment sur
stdout, en texte ou en JSON. Les sondes, les métriques et les logs fonctionnent
sans aucune configuration. Le tracing n’envoie rien tant que vous ne définissez
pas une variable d’environnement.

## Quand l’utiliser

Mettez en place l’observabilité dans ces cas :

- vous branchez les sondes de l’orchestrateur sur le backend ;
- vous scrapez des métriques ou alertez dessus ;
- vous envoyez des traces vers un collecteur ;
- vous réglez le format et le niveau des logs pour le déploiement.

## Avant de commencer

- Les sondes et `/metrics` se trouvent sur le port du backend, sur le réseau
  privé. L’edge public ne route pas `/metrics`.
- Le backend écoute sur `3000`. L’edge (Caddy) publie à la place le port TLS —
  `3443` par défaut. Chaque adresse `127.0.0.1:3000` de cette page est le port
  du backend, joignable uniquement depuis l’intérieur du réseau Docker. Lancez
  un `curl` depuis un shell dans la pile, par exemple
  `docker compose -f docker/compose.prod.yml exec backend curl -sf http://127.0.0.1:3000/Healthcheck`.
- Le tracing lit trois variables d’environnement OTLP standard. Elles forment
  la seule exception délibérée à la règle du fichier de configuration : le
  shard OpenTelemetry les lit lui-même.

## Étapes

### 1. Branchez les sondes

| Route | Usage | Comportement |
| --- | --- | --- |
| `GET /Healthcheck` | Sonde de disponibilité | Vérifie chaque pool de base de données, Redis et les consommateurs de flux. Répond `200` ou `503`. |
| `GET /Healthcheck/live` | Sonde de vivacité | Aucune vérification de dépendance. Toujours `200` tant que le processus est en vie. |

Utilisez `/Healthcheck` comme sonde de disponibilité, et seulement pour cela.
La santé des dépendances la fait osciller, et une boucle de redémarrage n’aide
personne. Utilisez `/Healthcheck/live` comme sonde de vivacité : elle n’échoue
que quand le processus a disparu.

Le corps de la sonde de disponibilité nomme la partie en échec :

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

`service.instance_id` est un id par démarrage. Rapprochez-le du log de
démarrage quand vous déboguez une instance parmi d’autres.

### 2. Lisez les compteurs de perte d’événements

La livraison des événements est au plus une fois, par conception. L’objet
`event_loss` rend visible la part silencieuse :

| Clé | Compte |
| --- | --- |
| `publish_flush_failures` | Passes de flush du publisher en échec. |
| `publish_events_dropped` | Événements jetés lors de ces flush en échec. |
| `messages_dropped` | Messages jetés par un consommateur après une erreur de handler. |

Les compteurs vivent dans le processus et se remettent à zéro au redémarrage.
Ils sont là pour la visibilité, pas pour la comptabilité : PostgreSQL détient
l’état durable.

`event_lag.max_lag` est le plus grand retard de groupe de consommateurs observé
par la dernière passe de vérification du retard. La passe tourne toutes les
10 minutes par défaut. Une valeur qui monte prévient avant qu’un consommateur
lent ne perde des entrées à la troncature du flux.

### 3. Scrapez les métriques

`GET /metrics` sert le format texte Prometheus 0.0.4. Aucune authentification
requise. Les compteurs sont par processus : scrapez chaque instance et laissez
Prometheus faire l’agrégation.

Compteurs incrémentés par le code :

| Métrique | Étiquettes | Compte |
| --- | --- | --- |
| `facet_events_published_total` | — | Événements publiés vers le bus. |
| `facet_messages_processed_total` | `consumer` | Messages traités par un groupe de consommateurs. |
| `facet_jobs_enqueued_total` | `kind` | Lignes de job insérées. |
| `facet_jobs_claimed_total` | `kind` | Lignes de job réclamées par un worker. |
| `facet_jobs_succeeded_total` | `kind` | Lignes de job terminées en `succeeded`. |
| `facet_jobs_failed_total` | `kind` | Lignes de job terminées en `failed`. |
| `facet_jobs_abandoned_total` | `kind` | Lignes récupérées par le balayage des baux. |
| `facet_http_requests_total` | `method`, `route`, `status_class` | Requêtes HTTP, par classe de statut finale. |
| `facet_db_checkout_total` | `database`, `role` | Emprunts de connexions au pool. La donnée d’entrée pour dimensionner le pool. |
| `facet_cron_task_failures_total` | `task` | Exécutions de tâche cron qui ont levé une erreur. |
| `facet_cron_task_lease_skips_total` | `task` | Déclenchements déjà effectués par une autre instance. |
| `facet_fiber_restarts_total` | `fiber` | Redémarrages supervisés de fiber. |
| `facet_fiber_loop_errors_total` | `fiber` | Tours de boucle longue durée ayant intercepté une erreur. |

Jauges et compteurs lus depuis l’état vivant à chaque scrape :

| Métrique | Type | Source |
| --- | --- | --- |
| `facet_event_loss_publish_flush_failures_total` | compteur | Le compteur publisher de `event_loss`. |
| `facet_event_loss_publish_events_dropped_total` | compteur | Le compteur des événements jetés de `event_loss`. |
| `facet_event_loss_messages_dropped_total` | compteur | Le compteur des messages jetés de `event_loss`. |
| `facet_consumer_consecutive_failures{name}` | jauge | Série d’échecs d’un consommateur de flux. |
| `facet_consumer_restarts_total{name}` | compteur | Redémarrages supervisés d’un consommateur de flux. |
| `facet_event_lag_max` | jauge | Le retard maximal d’un groupe de consommateurs à la dernière passe de vérification. |

### 4. Activez le tracing

Définissez trois variables d’environnement avant le démarrage :

```sh
export OTEL_SERVICE_NAME=facet
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4318
export OTEL_RESOURCE_ATTRIBUTES=environment=production
```

Sans endpoint défini, le processus construit des spans et les jette. C’est le
réglage sûr pour dev et test.

Chaque requête HTTP ouvre un span racine nommé `http.server.request`. Chaque
instruction SQL ouvre un span `db.query`, avec le texte SQL tronqué à

2000 caractères. Un span qui se termine en erreur porte le statut d’erreur :
les écritures en échec se retrouvent donc dans la trace. Un échec de télémétrie
ne fait jamais échouer la requête observée.

### 5. Réglez le format et le niveau des logs

La section facultative `logs:` pilote tout le processus :

| Clé | Valeurs | Défaut |
| --- | --- | --- |
| `format` | `text`, `json` | `text` |
| `level` | `trace`, `debug`, `info`, `notice`, `warn`, `error`, `fatal` | `info` |

Une valeur inconnue fait échouer le démarrage. La variable d’environnement
`LOG_LEVEL` n’affecte pas le processus applicatif ; le fichier est l’unique
source.

Au format `json`, un objet s’imprime par ligne :

| Champ | Contenu |
| --- | --- |
| `ts` | Horodatage de l’entrée, RFC-3339 UTC. |
| `level` | Étiquette de sévérité, par exemple `INFO`. |
| `source` | Source du log, par exemple `facet.jobs.manager`. |
| `message` | Le message de l’entrée. |
| `exception` | `{class, message}`, quand l’entrée en porte une. |
| `context` | Le contexte de log propre à la fiber, quand il est défini. |

:::tip
Les lignes de log ne contiennent jamais d’identifiants. L’URL Redis s’imprime
sous la forme `host:port/db`, jamais avec son mot de passe.
:::

## Exemple

Une configuration de production complète : logs JSON au niveau `info`, tracing
actif, et une vérification de sonde après un déploiement.

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

## Dépannage

**`/Healthcheck` répond `503` avec `status: degraded`.**

Un consommateur de flux signale des échecs consécutifs, ou un pool de base de
données ou Redis est en panne. Lisez `events.consumers`, `database.pools` et
`redis` dans le corps. L’état du consommateur se répare seul au prochain tour
sans erreur.

**`/Healthcheck` est au vert mais les événements ne réagissent pas.**

Le groupe de consommateurs a peut-être disparu, par exemple après une perte de
données Redis. La boucle journalise un WARN qui nomme le groupe et le flux. Un
redémarrage du backend recrée les groupes au démarrage.

**`/metrics` répond 404 via le nom d’hôte public.**

L’edge ne la route pas. Scrapez le port du backend sur le réseau privé, par
exemple `http://127.0.0.1:3000/metrics` depuis l’intérieur du réseau Docker.
Depuis l’hôte, lancez le scrape dans le conteneur backend :
`docker compose -f docker/compose.prod.yml exec backend curl -sf http://127.0.0.1:3000/metrics`.

**Aucune trace n’atteint le collecteur.**

`OTEL_EXPORTER_OTLP_ENDPOINT` n’est pas défini ou est injoignable. Sans lui,
le processus construit des spans et les jette. L’exporter parle le protocole
OTLP HTTP.

**Un changement de niveau ne fait rien.**

`LOG_LEVEL` ne pilote pas le processus applicatif. Définissez `logs.level` dans
le fichier de configuration et redémarrez.

## Voir aussi

- [Livraison des événements](/fr/admin/under-the-hood/events-and-delivery/) — le contrat au
  plus une fois que les compteurs de perte rendent visible.
- [Jobs de fond et cron](/fr/admin/keep-running/jobs-cron/) — les types de jobs derrière
  les métriques de jobs.
- [Déployer avec des conteneurs](/fr/admin/install/containers/) — le healthcheck
  de l’image, qui appelle `/Healthcheck` par curl.
- [Migrations de base de données](/fr/admin/keep-running/migrations/) — la chaîne de
  démarrage que la sonde de disponibilité protège.
- Internes sur GitHub :
  [metrics.md](https://github.com/wearefacet/facet/blob/main/doc/backend/metrics.md),
  [telemetry.md](https://github.com/wearefacet/facet/blob/main/doc/backend/telemetry.md),
  [logging.md](https://github.com/wearefacet/facet/blob/main/doc/backend/logging.md),
  [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
