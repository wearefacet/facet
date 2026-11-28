---
title: "Santé, métriques et journaux"
description: "Câblez les sondes de disponibilité, lisez les compteurs de perte d’événements, scrapez les métriques, et réglez le tracing et les journaux."
type: how-to
audience: [admin, operator]
features: [PLT-06, PLT-07, PLT-08, PLT-09, AUT-01]
verified_at: eee55a2
sidebar:
  order: 1
---

Facet est tombé et personne ne l’a remarqué — voici la défaillance que
cette page prévient. Le backend expose quatre surfaces
d’observabilité, et chacune répond à une question différente.
`/Healthcheck` répond à « puis-je servir du trafic maintenant ? ».
`/metrics` répond à « quelle est la charge et qu’est-ce qui échoue ? ».
Les traces répondent à « quelle étape était lente ? ». Les journaux
répondent à « que s’est-il passé exactement ? ». Les sondes, les
métriques et les journaux fonctionnent sans configuration. Le tracing
n’envoie rien tant que vous ne posez pas une variable d’environnement.

## Quand l’utiliser

- Vous câblez des sondes d’orchestrateur au backend.
- Vous scrapez des métriques ou alertez dessus.
- Vous envoyez des traces à un collecteur.
- Vous réglez le format et le niveau des journaux du déploiement.

## Avant de commencer

- Les sondes et `/metrics` se trouvent sur le port backend, sur le
  réseau privé. L’edge public ne route pas `/metrics`. Le backend
  écoute sur `3000` ; l’edge (Caddy) publie à la place le port TLS,
  `3443` par défaut. Lancez les commandes sur port privé depuis
  l’intérieur du réseau Docker, par exemple :

  ```sh
  docker compose -f docker/compose.prod.yml exec backend \
    curl -sf http://127.0.0.1:3000/Healthcheck
  ```

- Le tracing lit trois variables d’environnement OTLP standard. Elles
  sont l’unique exception délibérée à la règle du fichier de
  configuration : le shard OpenTelemetry les lit lui-même.

## Étapes

### 1. Câbler les sondes

| Route | Usage | Comportement |
| --- | --- | --- |
| `GET /Healthcheck` | Sonde de disponibilité | Vérifie chaque pool de base de données, Redis, et les consommateurs de stream. Répond `200` ou `503`. |
| `GET /Healthcheck/live` | Sonde de vie | Aucun contrôle de dépendance. Toujours `200` tant que le processus est vivant. |

Utilisez `/Healthcheck` comme sonde de disponibilité seulement. La
santé des dépendances le fait osciller, et une boucle de redémarrage
n’aide personne. Utilisez `/Healthcheck/live` comme sonde de vie : il
n’échoue que quand le processus a disparu.

Le corps de disponibilité nomme la partie en échec. Celui-ci vient de
l’instance d’exemple en marche :

```json
{
  "status": "ok",
  "service": { "env": "dev", "instance_id": "06H1FKX674ASYAJJ3MRDZ84TX4" },
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
        "name": "cg:hooks:equipment",
        "consecutive_failures": 0,
        "restarts": 0,
        "last_success_at": "2026-11-26T14:57:55Z",
        "last_error": null
      },
      {
        "name": "cg:webhooks:core",
        "consecutive_failures": 0,
        "restarts": 0,
        "last_success_at": null,
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

`service.instance_id` est un id par démarrage. Faites-le correspondre
au journal de démarrage quand vous déboguez une instance parmi
plusieurs. Chaque champ a un sens documenté dans
[Noms des champs de santé et des métriques](/fr/reference/health-metrics-names/)
— la liste exhaustive des noms que cette page ne fait qu’échantillonner.

### 2. Lire les compteurs de perte d’événements

La livraison d’événements est au plus une fois, par conception — voir
[Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/)
pour la raison. L’objet `event_loss` rend visible la partie silencieuse :

| Clé | Compte |
| --- | --- |
| `publish_flush_failures` | Passes de flush du publisher en échec. |
| `publish_events_dropped` | Événements jetés dans ces flush en échec. |
| `messages_dropped` | Messages qu’un consommateur a jetés après une erreur de handler. |

Les compteurs sont dans le processus et se remettent à zéro au
redémarrage. Ils sont de la visibilité, pas de la comptabilité :
PostgreSQL porte l’état durable.

`event_lag.max_lag` est le plus grand retard de groupe de consommateurs
que la dernière passe de contrôle de retard a observé. La passe tourne
toutes les 10 minutes par défaut. Une valeur qui monte avertit avant
qu’un consommateur lent ne perde des entrées au rognage du stream.

### 3. Scraper les métriques

`GET /metrics` sert le format texte Prometheus 0.0.4. Il ne demande pas
d’authentification. Les compteurs sont par processus, donc scrapez
chaque instance et laissez Prometheus faire l’agrégation.

Les noms qui valent une règle d’alerte :

| Métrique | Compte |
| --- | --- |
| `facet_event_loss_publish_flush_failures_total` | Flush de publication en échec — la livraison d’événements jette des événements. |
| `facet_event_loss_messages_dropped_total` | Messages de consommateurs jetés après erreurs de handler. |
| `facet_event_lag_max` | Retard de groupe de consommateurs — monte avant qu’un groupe ne perde des entrées au rognage du stream. |
| `facet_consumer_consecutive_failures{name}` | Série d’échecs d’un consommateur de stream. |
| `facet_cron_task_failures_total{task}` | Exécutions de tâches cron qui ont levé une exception. |
| `facet_jobs_failed_total{kind}` | Lignes de tâches qui ont fini en `failed`. |
| `facet_fiber_restarts_total{fiber}` | Redémarrages de fibres supervisées. |
| `facet_http_requests_total{method,route,status_class}` | Requêtes HTTP, par classe de statut finale. |

Le registre émet 20 noms catalogués au total. Lisez la liste complète
avec types et significations dans
[Noms des champs de santé et des métriques](/fr/reference/health-metrics-names/).

Un scrape en direct de l’instance en marche :

```text
facet_consumer_consecutive_failures{name="cg:hooks:equipment"} 0
facet_consumer_consecutive_failures{name="cg:repl:rentals"} 0
facet_event_lag_max 0
facet_event_loss_messages_dropped_total 0
facet_event_loss_publish_events_dropped_total 0
facet_event_loss_publish_flush_failures_total 0
```

### 4. Activer le tracing

Posez trois variables d’environnement avant le démarrage :

```sh
export OTEL_SERVICE_NAME=facet
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal:4318
export OTEL_RESOURCE_ATTRIBUTES=environment=production
```

Sans endpoint posé, le processus construit des spans et les jette. C’est
le défaut sûr pour dev et test.

Chaque requête HTTP ouvre un span racine nommé `http.server.request`.
Chaque instruction SQL ouvre un span `db.query`, avec le texte SQL
tronqué à 2000 caractères. Un span qui finit en erreur porte un statut
d’erreur, si bien que les écritures en échec se retrouvent dans la
trace. Les défaillances de télémétrie ne font jamais échouer la requête
qu’elles observent.

### 5. Régler le format et le niveau des journaux

La section `logs:` optionnelle pilote tout le processus :

| Clé | Valeurs | Défaut |
| --- | --- | --- |
| `format` | `text`, `json` | `text` |
| `level` | `trace`, `debug`, `info`, `notice`, `warn`, `error`, `fatal` | `info` |

Une valeur inconnue fait échouer le démarrage. La variable
d’environnement `LOG_LEVEL` n’affecte pas le processus applicatif ; le
fichier est la seule source.

En format `json`, un objet s’imprime par ligne :

| Champ | Contenu |
| --- | --- |
| `ts` | Horodatage de l’entrée, RFC-3339 UTC. |
| `level` | Étiquette de sévérité, par exemple `INFO`. |
| `source` | Source du journal, par exemple `facet.jobs.manager`. |
| `message` | Le message de l’entrée. |
| `exception` | `{class, message}`, quand l’entrée en porte une. |
| `context` | Le contexte de journal local à la fibre, quand il est posé. |

:::tip
Les lignes de journal ne portent jamais d’identifiants. L’URL Redis
s’imprime sous la forme `host:port/db`, jamais avec son mot de passe.
:::

## Exemple

Une configuration de production complète : journaux JSON en `info`,
tracing activé, et un contrôle de sonde après un déploiement.

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

Un consommateur de stream rapporte des échecs consécutifs, ou un pool
de base de données ou Redis est tombé. Lisez `events.consumers`,
`database.pools` et `redis` dans le corps. L’état du consommateur se
répare seul au prochain tour propre.

**`/Healthcheck` est vert mais les événements ne réagissent pas.**

Le groupe de consommateurs a peut-être disparu, par exemple après une
perte de données Redis. La boucle journalise un WARN qui nomme le groupe
et le stream. Un redémarrage du backend recrée les groupes au démarrage.

**`/metrics` répond 404 par le nom d’hôte public.**

L’edge ne le route pas. Scrapez le port backend sur le réseau privé,
comme dans la commande sous **Avant de commencer**.

**Aucune trace n’arrive au collecteur.**

`OTEL_EXPORTER_OTLP_ENDPOINT` n’est pas posé ou est injoignable. Sans
lui, le processus construit des spans et les jette. L’exporter parle le
protocole OTLP HTTP.

**Un changement de niveau ne fait rien.**

`LOG_LEVEL` ne pilote pas le processus applicatif. Posez `logs.level`
dans le fichier de configuration et redémarrez.

## Voir aussi

- [Noms des champs de santé et des métriques](/fr/reference/health-metrics-names/) — chaque nom de champ et de métrique, généré depuis la source.
- [Garanties de livraison d’événements](/fr/admin/under-the-hood/events-and-delivery/) — le contrat au-plus-une-fois que les compteurs de perte rendent visible.
- [Tâches de fond et cron](/fr/admin/keep-running/jobs-cron/) — les types de tâches derrière les métriques de tâches.
- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — le healthcheck de l’image qui curl `/Healthcheck`.
- [Migrations de base de données](/fr/admin/keep-running/migrations/) — la chaîne de démarrage que la sonde de disponibilité garde.
- Documentation interne sur GitHub : [metrics.md](https://github.com/wearefacet/facet/blob/main/doc/backend/metrics.md), [telemetry.md](https://github.com/wearefacet/facet/blob/main/doc/backend/telemetry.md), [logging.md](https://github.com/wearefacet/facet/blob/main/doc/backend/logging.md), [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md).
