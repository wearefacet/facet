---
title: "Tâches de fond et cron"
description: "Exécutez la file de tâches de fond et les neuf tâches cron, et réglez les relances, les baux et les horaires."
type: how-to
audience: [operator]
features: [AUT-04, AUT-05, AUT-10]
verified_at: eee55a2
sidebar:
  order: 2
---

Les webhooks doivent atteindre leurs destinataires, les exports doivent
finir, et les vieilles données doivent être purgées — pendant que
personne ne regarde. Facet exécute ce travail lui-même, dans deux
moteurs à l’intérieur du processus backend. La file de tâches est une
table PostgreSQL ; une boucle worker réclame les lignes dues et exécute
un handler pour chacune. L’ordonnanceur cron déclenche les tâches de
maintenance sur un horaire. Tous deux démarrent avec le serveur, et
aucun ne demande de logiciel supplémentaire.

## Quand l’utiliser

- Vous voulez savoir quelles tâches de fond tournent et quand.
- Une tâche échoue ou reste `running`, et vous devez la récupérer.
- Vous réglez les relances, les baux, la taille de lot, ou un horaire cron.

## Avant de commencer

- Chaque clé `jobs:` et chaque horaire cron se lie au démarrage. Un changement demande un redémarrage.
- Le worker tourne dans chaque instance backend. Deux workers ne prennent jamais la même ligne : la réclamation verrouille les lignes avec `FOR UPDATE SKIP LOCKED`.
- Le worker garde une clé de vivacité dans Redis par instance. La passe de baux la lit pour détecter un worker mort.

## Étapes

### 1. Suivre une ligne de tâche

Une ligne dans `background_jobs` est une unité de travail. La ligne
n’est pas un document et n’a pas de journal d’événements. Elle traverse
quatre états :

*Une ligne de tâche, de la mise en file à l’état terminal.*

<!-- d2
direction: down
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
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c8f16496-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c8f16496-dark.svg" alt="Diagram" loading="lazy" />
</div>

- La réclamation d’un worker fait passer la ligne de `pending` à
  `running` et démarre un bail.
- Une tentative en échec avec des tentatives restantes la ramène à
  `pending`, avec un délai avant qu’elle soit de nouveau due.
- Une tentative en échec au plafond de relances la marque `failed`
  définitivement.
- La passe de baux ramène aussi les lignes `running` abandonnées à
  `pending`, ou à `failed` quand elles dépassent le plafond.

### 2. Connaître les types de tâches

Le serveur enregistre un handler par type :

| Type | Ce qu’il fait |
| --- | --- |
| `webhook_delivery` | Envoie un POST de webhook signé. Les relances suivent la configuration du webhook. |
| `document_export` | Exporte les documents d’un doctype. Tourne une fois, bail long. |
| `document_import` | Importe des documents. Tourne une fois, bail long. |
| `domain_export` | Exporte un bundle de domaine portable. Tourne une fois, bail long. |
| `domain_import` | Importe un bundle de domaine portable. Tourne une fois, bail long. |
| `doctype_reproject` | Reprojette chaque document en direct d’un doctype. Tourne une fois, bail long. |
| `doctype_migrate_ahead` | Exécute une migration de doctype en avance sur le chemin de migration paresseux. Tourne une fois, bail long. |

La politique par défaut autorise 5 tentatives par tâche. Une tentative
en échec avec des tentatives restantes retourne à `pending` après un
délai : 10, 60, 300, puis 1800 secondes entre les quatre relances. Les
types de tâches longs posent `max_attempts: 1` sur leurs propres
lignes : l’appelant corrige l’entrée et soumet de nouveau. Une ligne de
tâche peut porter ses propres limites à la mise en file.

### 3. Régler la file

La section `jobs:` optionnelle porte les réglages de la file :

| Clé | Défaut | Signification |
| --- | --- | --- |
| `poll_interval_s` | `5.0` | Attente au repos entre deux passes de réclamation. |
| `lease_ttl_s` | `60` | Durée pendant laquelle une ligne réclamée reste `running` avant que la passe la remette en file. |
| `long_lease_ttl_s` | `3600` | L’horizon de bail que les types de tâches longs posent sur leurs propres lignes. |
| `batch` | `32` | Maximum de lignes réclamées par passe. |
| `sweep_interval_s` | `30.0` | Cadence de la passe de baux et de l’actualisation de vivacité. |
| `retention_days` | `30` | Les lignes terminées plus vieilles que ce nombre sont purgées. |
| `enabled` | `true` | `false` ne démarre aucun worker ; les mises en file insèrent toujours des lignes. |

### 4. Connaître la récupération après crash

Deux détecteurs transforment un crash en reprise propre :

- La passe de baux tourne à chaque `sweep_interval_s`. Elle remet en
  file les lignes `running` dont le bail a expiré ou dont l’instance
  propriétaire est morte.
- Le contrôle de vivacité marque l’instance vivante dans Redis à chaque
  tick de passe. La clé tient 120 secondes, si bien que trois ticks
  manqués ne déclarent jamais morte une instance vivante.

Une ligne abandonnée au-delà de son plafond de relances passe à l’état
terminal `failed` avec l’erreur `job abandoned — worker lost`. Une
tâche en boucle de crash ne peut pas se remettre en file indéfiniment.

### 5. Séparer la mise en file du travail, au besoin

Avec `jobs.enabled: false`, le worker ne démarre jamais, mais les mises
en file insèrent toujours des lignes. Un autre processus avec le worker
activé les réclame. Utilisez cela pour garder le travail de tâches hors
d’une instance.

### 6. Connaître les tâches cron

Une fibre d’ordonnanceur par processus déclenche neuf tâches
enregistrées. Chaque déclenchement prend d’abord un bail sur le tick
planifié dans Redis, si bien que le tick s’exécute exactement une fois
sur le cluster. Une erreur Redis saute le déclenchement, et le tick
suivant réarme.

`facet cron:list` imprime cette table depuis votre propre
configuration — id de tâche, clé d’horaire, expression, et prochain
déclenchement (UTC) :

```text
task id                   schedule key                 expression     next run (UTC)
sidecar.reconcile         sidecar.reconcile_cron       0 */1 * * *    2026-11-26 15:00:00 UTC
artifact.grant_prune      artifact.grant_prune_cron    0 5 * * *      2026-11-27 05:00:00 UTC
tombstone.content_prune   tombstone.prune_cron         15 4 * * *     2026-11-27 04:15:00 UTC
secrets.prune             secrets.prune_cron           45 4 * * *     2026-11-27 04:45:00 UTC
assistant.turn_sweep      assistant.turn_sweep_cron    */5 * * * *    2026-11-26 14:55:00 UTC
assistant.usage_prune     assistant.usage_prune_cron   30 4 * * *     2026-11-27 04:30:00 UTC
mutations.compaction      mutations.compaction_cron    45 3 * * *     2026-11-27 03:45:00 UTC
webhook.reconcile         webhook.reconcile_cron       7 */1 * * *    2026-11-26 15:07:00 UTC
event.lag_check           event.lag_check_cron         */10 * * * *   2026-11-26 15:00:00 UTC
```

La commande ne lit que la configuration — pas de base, pas de Redis.
Une expression que l’analyseur refuse marque sa ligne, et la commande
sort avec `1` : le serveur refuse de démarrer sur la même erreur.

Ce que fait chaque tâche :

| Id de tâche | Passe |
| --- | --- |
| `sidecar.reconcile` | Remet en file les passes sidecar orphelines. |
| `artifact.grant_prune` | Détruit les lignes de liens de téléchargement éphémères expirées après `artifact.grant_prune_days`. |
| `tombstone.content_prune` | Efface les charges des documents supprimés après `tombstone.content_retention_days`. Nettoyage de stockage seulement — l’historique d’audit reste. |
| `secrets.prune` | Détruit les emplacements de secrets expirés et les lignes de staging. |
| `assistant.turn_sweep` | Marque `interrupted` les tours d’assistant `running` périmés. |
| `assistant.usage_prune` | Détruit les lignes d’usage de l’assistant au-delà de la fenêtre. |
| `mutations.compaction` | Fusionne les mutations plus vieilles que `mutations.retention_days` en un instantané par document. La profondeur du retour arrière égale cette fenêtre. |
| `webhook.reconcile` | Répare le saut de mise en file des webhooks depuis le journal `mutations`, dans la fenêtre `webhook.reconcile_window_hours`. |
| `event.lag_check` | Avertit avant qu’un groupe de consommateurs lent ne perde des entrées au rognage du stream. |

:::tip
Les horaires nocturnes s’étagent à dessein : compactage à 03:45, puis
les purges à 04:15, 04:30, 04:45 et 05:00. Gardez cet espacement quand
vous en déplacez une.
:::

## Exemple

Un fragment de configuration complet. Il montre les défauts de la file
et chaque horaire cron avec sa valeur par défaut :

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

artifact:
  grant_prune_cron: "0 5 * * *"

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

**Une tâche reste `running` plus longtemps que prévu.**

Le handler tourne peut-être encore : les types de tâches longs portent
un bail de 3600 secondes. Sinon, le worker est mort. La passe remet la
ligne en file au premier tick de passe après l’expiration du bail.
Attendez un `sweep_interval_s` après `lease_ttl_s`.

**Une tâche a échoué avec `job abandoned — worker lost`.**

La ligne a dépassé son plafond de relances pendant qu’elle était
abandonnée. Relancez le travail ; la file ne relancera plus la ligne.

**Une livraison de webhook échoue.**

Lisez le journal d’appels du webhook — voir
[Webhooks](/fr/build/model/automation/webhooks/). Les relances de
transport suivent les valeurs `max_attempts` et `backoff_seconds` du
webhook, pas les défauts de la file.

**Deux instances ont exécuté la même passe cron.**

Le bail de tick vit dans Redis. Pointez chaque instance vers la même
base Redis, si bien que le bail est une clé par tick.

**Un changement d’horaire ne fait rien.**

Les horaires se lient au démarrage. Redémarrez le backend après avoir
édité le fichier.

## Voir aussi

- [Réglages système](/fr/admin/configure/system-settings/) — quels réglages s’appliquent à chaud et lesquels se lient au démarrage.
- [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) — les métriques de tâches et de cron à surveiller.
- [Rétention : ce qui est conservé](/fr/admin/history/retention/) — les fenêtres que le compactage et les purges appliquent.
- [Webhooks](/fr/build/model/automation/webhooks/) — la tâche de livraison que la file porte.
- [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) — le bus que le contrôle de retard protège.
- Documentation interne sur GitHub : [jobs.md](https://github.com/wearefacet/facet/blob/main/doc/backend/jobs.md), [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
