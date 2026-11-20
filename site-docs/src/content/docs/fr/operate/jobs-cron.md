---
title: Jobs en arrière-plan et cron
description: Faites tourner la file de jobs et les tâches cron, et réglez les relances, les baux et les planifications.
audience: [operator]
features: [AUT-04, AUT-05]
sidebar:
  order: 12
verified_at: 008dd880
---

Facet exécute le travail en arrière-plan avec deux moteurs, à l’intérieur
du processus backend. La file de jobs est une seule table PostgreSQL. Une
boucle worker réclame les lignes arrivées à échéance et exécute un handler
pour chacune. Le planificateur cron déclenche des tâches de maintenance
selon un calendrier défini. Les deux démarrent avec le serveur, sans
logiciel supplémentaire.

## Quand l’utiliser

Lisez cette page quandà :

- vous voulez savoir quelles tâches tournent en arrière-plan, et quand,
- un job échoue ou reste `running`, et vous devez le récupérer,
- vous réglez les relances, les baux, la taille des lots ou une
  planification cron.

## Avant de commencer

- Chaque clé `jobs:` et chaque planification cron se lient au démarrage.
  Toute modification exige un redémarrage.
- Le worker tourne dans chaque instance du backend. Deux workers ne
  prennent jamais la même ligneà : la réclamation verrouille les
  lignes avec `FOR UPDATE SKIP LOCKED`.
- Le worker maintient une clé de vivacité Redis par instance. Le balayage
  des baux la lit pour détecter un worker mort.

## Étapes

### 1. Suivre une ligne de job

Une ligne de `background_jobs` est une unité de travail. La ligne n’est pas
un document et n’a pas de journal d’événements. Elle traverse quatre
étatsà :

<!-- d2
pending: pending
running: running
succeeded: succeeded {class: ok}
failed: failed {class: danger}

pending -> running
running -> succeeded
running -> failed
running -> pending: retry
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/6f049f94-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/6f049f94-dark.svg" alt="Diagram" loading="lazy" />
</div>

- Une réclamation par un worker fait passer la ligne de `pending` à

  `running` et démarre un bail.
- Une tentative échouée avec des tentatives restantes la renvoie en
  `pending`, avec un délai avant sa prochaine échéance.
- Une tentative échouée au plafond de relances la marque `failed`
  définitivement.
- Le balayage des baux renvoie aussi les lignes `running` bloquées en
  `pending`, ou en `failed` quand elles dépassent le plafond.

### 2. Connaître les types de jobs

Le serveur enregistre un handler par typeà :

| Type | Ce qu’il fait |
| --- | --- |
| `webhook_delivery` | Envoie un POST de webhook signé. Les relances suivent la configuration du webhook. |
| `document_export` | Exporte les documents d’un doctype. Tourne une fois, long bail. |
| `document_import` | Importe des documents. Tourne une fois, long bail. |
| `domain_export` | Exporte un bundle de domaine portable. Tourne une fois, long bail. |
| `domain_import` | Importe un bundle de domaine portable. Tourne une fois, long bail. |
| `doctype_reproject` | Reprojette chaque document vivant d’un doctype. Tourne une fois, long bail. |
| `doctype_migrate_ahead` | Exécute la migration d’un doctype en avance sur le chemin paresseux. Tourne une fois, long bail. |

Par défaut, un job se relance jusqu’à 5 fois, avec un délai de 10, 60, 300,
1800 puis 7200 secondes entre les tentatives. Une ligne de job peut porter
ses propres limites dès l’ajout en file.

### 3. Régler la file

La section `jobs:` facultative porte les réglages de la fileà :

| Clé | Valeur par défaut | Signification |
| --- | --- | --- |
| `poll_interval_s` | `5.0` | Attente au repos entre deux passes de réclamation. |
| `lease_ttl_s` | `60` | Durée pendant laquelle une ligne réclamée reste `running` avant que le balayage la remette en file. |
| `long_lease_ttl_s` | `3600` | L’horizon de bail que les types de jobs longs posent sur leurs propres lignes. |
| `batch` | `32` | Maximum de lignes réclamées par passe. |
| `sweep_interval_s` | `30.0` | Cadence du balayage des baux et du rafraîchissement de vivacité. |
| `retention_days` | `30` | Les lignes terminées plus vieilles que cette valeur sont élaguées. |
| `enabled` | `true` | À `false`, aucun worker ne démarre@NBSP;; les ajouts en file insèrent toujours des lignes. |

### 4. Connaître la reprise après crash

Deux détecteurs transforment un crash en reprise propreà :

- Le balayage des baux tourne à chaque `sweep_interval_s`. Il remet en file
  les lignes `running` dont le bail a expiré ou dont l’instance
  propriétaire est morte.
- Le contrôle de vivacité marque l’instance vivante dans Redis à chaque
  tick de balayage. La clé tient 120 secondes, si bien que trois ticks
  manqués ne déclarent jamais morte une instance vivante.

  Une ligne bloquée au-del à de son plafond de relances passe en `failed`
  terminal avec l’erreur `job abandoned — worker lost`. Un job en boucle
  de crash ne peut pas se remettre en file indéfiniment.

### 5. Séparer l’ajout en file du travail, au besoin

Avec `jobs.enabled: false`, le worker ne démarre jamais, mais les ajouts en
file insèrent quand même des lignes. Un autre processus, avec son worker
actif, les réclame. Utilisez ce réglage pour décharger une instance du
travail des jobs.

### 6. Connaître les tâches cron

Une fibre de planification par processus déclenche les huit tâches
enregistrées. Chaque déclenchement pose d’abord un bail sur le tick
programmé dans Redis, si bien que le tick s’exécute exactement une fois
dans le cluster. Une erreur Redis saute le déclenchement, et le tick
suivant réarme.

| Tâche | Clé de planification | Planification par défaut | Passe |
| --- | --- | --- | --- |
| `sidecar.reconcile` | `sidecar.reconcile_cron` | `"0 */1 * * *"` | Remet en file les balayages de sidecars orphelins. |
| `tombstone.content_prune` | `tombstone.prune_cron` | `"15 4 * * *"` | Efface les payloads des tombstones après la rétention. |
| `secrets.prune` | `secrets.prune_cron` | `"45 4 * * *"` | Supprime les emplacements de secrets expirés et les lignes de staging. |
| `assistant.turn_sweep` | `assistant.turn_sweep_cron` | `"*/5 * * * *"` | Marque `interrupted` les tours d’agent `running` obsolètes. |
| `assistant.usage_prune` | `assistant.usage_prune_cron` | `"30 4 * * *"` | Supprime les lignes d’usage de l’assistant au-del à de la fenêtre. |
| `mutations.compaction` | `mutations.compaction_cron` | `"45 3 * * *"` | Compacte les vieilles mutations en un instantané par document. |
| `webhook.reconcile` | `webhook.reconcile_cron` | `"7 */1 * * *"` | Répare le maillon d’ajout en file des webhooks. |
| `event.lag_check` | `event.lag_check_cron` | `"*/10 * * * *"` | Avertit avant qu’un consommateur lent ne perde des entrées emportées par le trim. |

`facet cron:list` affiche la même table d’après votre configuration :
l’identifiant de la tâche, la clé de planification, l’expression et la
prochaine exécution (UTC). La commande lit la configuration seule — ni
base de données, ni Redis. Une expression que l’analyseur refuse marque
sa ligne et la commande sort en code 1 : le serveur refuse aussi de
démarrer sur la même erreur.

:::tip
Les planifications se répartissent volontairement sur la nuità :
compactage à 03:45, élagage des tombstones à 04:15, élagage de l’usage à

04:30, élagage des secrets à 04:45. Gardez cet espacement quand vous en
déplacez un.
:::

## Exemple

Un fragment de configuration complet. Il montre les valeurs par défaut de
la file et chaque planification cron avec sa valeur par défautà :

```yaml
jobs:
  poll_interval_s: 5.0
  lease_ttl_s: 60
  long_lease_ttl_s: 3600
  batch: 32
  sweep_interval_s: 30.0
  retention_days: 30
  enabled: true

sidecar:
  reconcile_cron: "0 */1 * * *"

tombstone:
  prune_cron: "15 4 * * *"

secrets:
  prune_cron: "45 4 * * *"

assistant:
  turn_sweep_cron: "*/5 * * * *"
  usage_prune_cron: "30 4 * * *"

mutations:
  compaction_cron: "45 3 * * *"

webhook:
  reconcile_cron: "7 */1 * * *"

event:
  url: !env FACET_REDIS_URL
  lag_check_cron: "*/10 * * * *"
```

## Dépannage

**Un job reste `running` plus longtemps que prévu.**

Le handler tourne peut-être encoreà : les types de jobs longs portent
un bail de 3600 secondes. Sinon, le worker est mort. Le balayage remet la
ligne en file au premier tick qui suit l’expiration du bail. Attendez un
`sweep_interval_s` après `lease_ttl_s`.

**Un job a échoué avec `job abandoned — worker lost`.**

La ligne a dépassé son plafond de relances pendant qu’elle était bloquée.
Relancez le travail@NBSP;; la file ne réessaiera plus cette ligne.

**Une livraison de webhook échoue.**

Lisez le journal d’appels du webhook — voir
[Webhooks sortants](/fr/build/webhooks/). Les relances de transport suivent
les valeurs `max_attempts` et `backoff_seconds` du webhook, pas les
réglages par défaut de la file.

**Deux instances ont exécuté la même passe cron.**

Le bail du tick vit dans Redis. Faites pointer chaque instance sur la même
base Redis, pour que le bail soit une seule clé par tick.

**Un changement de planification ne fait rien.**

Les planifications se lient au démarrage. Redémarrez le backend après
avoir modifié le fichier.

## Voir aussi

- [Paramètres système](/fr/operate/system-settings/) — quels réglages
  s’appliquent à chaud et lesquels se lient au démarrage.
- [Health checks, métriques, tracing, logs](/fr/operate/health-metrics-logs/) —
  les métriques de jobs et de cron à surveiller.
- [La rétention : quoi et combien de temps](/fr/govern/retention/) — la
  fenêtre qui élague les lignes de jobs terminées.
- [Webhooks sortants](/fr/build/webhooks/) — le job de livraison que la
  file porte.
- [Événements et garanties de livraison](/fr/concepts/events-delivery/) —
  le bus que le contrôle de retard cron surveille.
- Internes sur GitHubà :
  [jobs.md](https://github.com/wearefacet/facet/blob/main/doc/backend/jobs.md),
  [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
