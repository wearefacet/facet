---
title: Événements et garanties de livraison
description: Comment Facet publie les événements après un commit, pourquoi la livraison a lieu au plus une fois, et comment les webhooks rattrapent les envois manqués.
audience: [developer, operator]
features: [AUT-01, AUT-05]
sidebar:
  order: 9
verified_at: 7a6cb462
---

Dans Facet, les événements sont des réactions, pas des enregistrements. Une
fois l’écriture validée, Facet publie des événements sur Redis Streams, et des
consommateurs réagissent. PostgreSQL porte l’état durable. Lisez cette page
pour comprendre ce qui se passe quand une réaction se perd, et pourquoi c’est
voulu.

## Explication

<!-- d2
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
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/8cbdbef3-light.svg" alt="Document write commits" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/8cbdbef3-dark.svg" alt="Document write commits" loading="lazy" />
</div>

Chaque écriture acceptée ajoute une ligne au journal des mutations. Une fois
la transaction validée, le chemin d’écriture pousse sa file d’événements vers
Redis Streams. Une transaction annulée abandonne la file.

Les consommateurs tournent en groupes. Les hooks de domaine exécutent des
scripts Lua. Les webhooks livrent des enveloppes signées à des URL externes.
La réplication copie des champs entre domaines. Le pont WebSocket pousse des
mises à jour en direct vers les navigateurs.

**La livraison est au plus une fois, par conception.** Les consommateurs
lisent avec `no_ack`, et aucun code n’acquitte un message. Une publication ou
une distribution en échec est abandonnée avec une seule ligne de log.
PostgreSQL porte l’état durableà ; Redis est un bus de réactions, pas un
registre.

**La perte reste visible.** Les compteurs `event_loss` sur `GET /Healthcheck`
comptent les échecs de publication et les distributions abandonnées. Tant
qu’un consommateur rapporte des échecs consécutifs, le même endpoint répond
`503`.

**Les webhooks sont le seul consommateur réparé.** Un job planifié,
`Cron::WebhookReconcile`, rejoue la décision de mise en file depuis le journal
des `mutations`. Il rattrape les envois manqués dans une fenêtre fixée par
`webhook.reconcile_window_hours`, 24 heures par défaut. La fenêtre doit rester
en dessous de la durée de rétention des jobs. Une fenêtre plus large
renverrait des événements dont les enregistrements de livraison sont déjà
purgés.

**Un nouveau groupe de consommateurs choisit son point de départ.** Les
groupes de réplication partent de `0` et rejouent tout le flux conservé. Un
rejeu converge, car chaque handler recalcule les lignes à partir de la
projection courante. Les hooks et les webhooks gardent `$`, la fin du flux.
Là, un rejeu déclencherait des automatisations une seconde fois et livrerait
à nouveau vers des systèmes externes.

**Un contrôle du retard vous prévient tôt.** Il tourne toutes les dix minutes
par défaut. Il lit le retard de chaque groupe et avertit avant qu’un groupe
lent n’atteigne le point de troncature. Le retard maximal apparaît comme une
jauge sur `/Healthcheck`, à côté de `event_loss`.

**Une boucle, un bail.** Facet fait tourner ces jobs sur son ordonnanceur
cron. Une expression cron dit quand une tâche se déclenche. L’ordonnanceur
exécute une seule boucle. Un bail unique à l’échelle du cluster garantit que
chaque tick ne se déclenche qu’une fois, toutes instances backend confondues.
Une tâche en échec écrit une erreur dans les logs, et l’ordonnanceur continue
de tourner.

:::note
Les compteurs `event_loss` se remettent à zéro au redémarrage. Lisez-les
comme un signal, pas comme un registre. L’état durable reste dans PostgreSQL.
:::

**Ce que coûte la livraison au plus une fois.** L’approche achète la
simplicité et le débit. Elle renonce à la livraison garantie. Un consommateur
doit tolérer la perte, ou prévoir un chemin de réparation, comme le
réconciliateur des webhooks. La réplication tolère la perteà : ses handlers
recalculent à partir de l’état durable, et un rejeu converge.

## Voir aussi

- [Architecture en un coup d’œil](/fr/start/architecture/) — la place du bus
  d’événements dans le chemin d’une requête.
- [Le journal des mutations](/fr/concepts/mutation-log/) — l’enregistrement
  durable que lit le réconciliateur.
- [Exploitation](/fr/operate/) — healthcheck, Redis et jobs au quotidien.
- [Déployer en production](/fr/operate/production/) — les sondes et le
  dimensionnement de Redis pour un déploiement réel.
- Internes sur GitHubà : [event.md](https://github.com/wearefacet/facet/blob/main/doc/backend/event.md),
  [cron.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cron.md).
