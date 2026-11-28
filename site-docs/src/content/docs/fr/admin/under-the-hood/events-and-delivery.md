---
type: explanation
title: Événements et garanties de livraison
description: Comment Facet publie les événements après un commit, pourquoi la livraison a lieu au plus une fois, et comment les webhooks rattrapent les envois manqués.
audience: [developer, operator]
features: [AUT-01, AUT-05]
verified_at: eee55a2
sidebar:
  order: 4
---

Une réservation est confirmée, et trois réactions devraient suivre. Le
hook marque ses articles comme sortis. Le webhook prévient le calendrier
externe. Les onglets du navigateur se mettent à jour en direct. La requête
de réservation n’écrit rien de tout cela : chaque effet est une réaction
à un événement. Cette page montre comment ces réactions voyagent, et
pourquoi Facet accepte que l’une se perde.

## Explication

*Chaque écriture acceptée publie des événements ; les consommateurs
réagissent ; un cron répare la seule réaction qui porte une obligation
externe.*

<!-- d2
direction: down
write: "Document write commits"
publish: "Publisher flushes the queue"
streams: "Redis Streams" {class: store}
hooks: "Hooks run Lua"
webhooks: "Webhooks deliver signed envelopes"
replication: "Replication copies fields"
live: "Live updates reach browsers"
cron: "Webhook reconcile cron"

write -> publish
publish -> streams
streams -> hooks
streams -> webhooks
streams -> replication
streams -> live
cron -> webhooks: repairs missed sends
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/291e43b3-light.svg" alt="Document write commits" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/291e43b3-dark.svg" alt="Document write commits" loading="lazy" />
</div>

### Du commit à la réaction

Dans Facet, les événements sont des réactions, pas des enregistrements.
Chaque écriture acceptée ajoute une ligne au journal des mutations. Une
fois la transaction validée en base, le chemin d’écriture pousse sa file
d’événements vers Redis Streams. Une transaction annulée abandonne la
file.

Les consommateurs tournent en groupes, un par préoccupation. Les hooks de
domaine exécutent des scripts Lua. Les webhooks livrent des enveloppes
signées à des URL externes. La réplication copie des champs entre
domaines. Le pont WebSocket pousse des mises à jour en direct vers les
navigateurs.

### Le contrat de livraison

**La livraison est au plus une fois, par conception.** Les consommateurs
lisent avec `no_ack`, et aucun code n’acquitte un message — pas de liste
d’attente, pas de récupération. Une publication ou une distribution en
échec est abandonnée avec une seule ligne de log. PostgreSQL porte l’état
durable ; Redis est un bus de réactions, pas un registre.

Ce contrat a sa logique. PostgreSQL détient la vérité : `projections` et
`mutations` portent chaque fait. Un événement perdu est une réaction
perdue, et presque chaque réaction a un chemin de réparation. La mutation
suivante rejoue la même logique, ou un cron prend le relais. En échange,
la livraison au plus une fois donne un bus simple et rapide, sans
comptabilité d’acquittements ni vagues de re-livraison.

### La perte reste visible

Les compteurs `event_loss` sur `GET /Healthcheck` comptent les échecs de
publication et les distributions abandonnées. Tant qu’un consommateur
rapporte des échecs consécutifs, le même endpoint répond `503`. Les
compteurs vivent dans le processus et se remettent à zéro au redémarrage —
lisez-les comme un signal, pas comme un registre. L’état durable reste
dans PostgreSQL.

### Les webhooks sont réparés

Les webhooks portent des obligations externes : un récepteur attend. Ils
sont le seul consommateur réparé. Une tâche planifiée,
`Cron::WebhookReconcile`, rejoue la décision de mise en file depuis le
journal des `mutations` — l’enregistrement durable — pour les mutations
récentes qui n’ont produit aucune ligne de livraison. Il déduit, il ne
marque pas : aucun état de livraison n’est écrit dans `mutations`.

La réparation couvre une fenêtre fixée par `webhook.reconcile_window_hours`,
24 heures par défaut. La fenêtre doit rester en dessous de la durée de
rétention des jobs (`jobs.retention_days`, 30 jours par défaut) — le
démarrage refuse une configuration où la fenêtre l’atteint. Une fenêtre
plus large renverrait des événements dont les enregistrements de livraison
sont déjà purgés.

### Points de départ

Un nouveau groupe de consommateurs choisit son point de départ. La valeur
par défaut est `$`, la fin du flux — les nouveaux événements seulement. La
réplication passe `0` : un nouveau binding rejoue le flux conservé. Un
rejeu converge, car chaque handler recalcule les lignes à partir de la
projection courante et saute les événements de rejeu qu’il a causés
lui-même. Les hooks et les webhooks gardent `$`. Un rejeu déclencherait
des automatisations une seconde fois et livrerait à nouveau vers des
systèmes externes.

### Le contrôle du retard

Les flux d’événements ont une taille plafonnée (`maxlen`, un plafond
approximatif). Redis ne supprime jamais une entrée après livraison, donc
en régime stable un flux sature à son plafond. Un groupe perd des entrées
par troncature seulement quand il prend plus d’un plafond de retard sur un
shard. Les causes habituelles sont une fiber de consommateur morte ou une
instance arrêtée.

`Cron::EventLagCheck` tourne toutes les dix minutes par défaut. Il lit le
retard de chaque groupe et avertit quand l’un approche le point de
troncature. L’avertissement dit que la perte approche, pas qu’elle a eu
lieu. Le retard maximal du passage apparaît comme une jauge sur
`/Healthcheck`, à côté de `event_loss`.

### Une boucle, un bail

Facet fait tourner ces jobs sur son propre ordonnanceur cron. Une
expression cron dit quand une tâche se déclenche. L’ordonnanceur exécute
une seule boucle. Un bail unique à l’échelle du cluster garantit que
chaque tick ne se déclenche qu’une fois, toutes instances backend
confondues. Une tâche en échec écrit une erreur dans les logs, et
l’ordonnanceur continue de tourner.

### Ce que coûte la livraison au plus une fois

La livraison au plus une fois achète la simplicité et le débit. Elle
renonce à la livraison garantie. Un consommateur doit tolérer la perte, ou
porter un chemin de réparation comme le réconciliateur. La réplication
tolère la perte : ses handlers recalculent à partir de l’état durable, et
un rejeu converge. Les hooks tolèrent la perte : la mutation suivante qui
correspond les redéclenche. Si vous écrivez un consommateur qui ne tolère
pas la perte, donnez-lui un chemin de réparation — c’est le prix d’entrée
sur le bus.

## Voir aussi

- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — la place du
  bus d’événements dans le chemin d’une requête.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) —
  l’enregistrement durable que lit le réconciliateur.
- [Jobs et cron](/fr/admin/keep-running/jobs-cron/) — les tâches cron que
  cette page nomme.
- [Santé, métriques et logs](/fr/admin/keep-running/monitoring/) — les
  compteurs décrits ici, en fonctionnement.
- Internes sur GitHub : [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md),
  [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
