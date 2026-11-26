---
title: Mises à niveau et arrêt propre
description: Passez à une nouvelle version et arrêtez le backend sans couper les traitements en cours.
audience: [operator]
features: [PLT-15, PLT-11]
sidebar:
  order: 16
verified_at: 008dd880
---

Une version est une nouvelle image de conteneur. L’entrypoint migre le schéma
au démarrage, donc une mise à niveau tient en un pull, un redémarrage, et un
contrôle de santé. Un arrêt est un signal : le backend ferme ses ports
d’écoute, envoie des trames de fermeture à chaque WebSocket, attend les
requêtes en cours, puis démonte ses sous-systèmes dans un ordre fixe.

## Quand l’utiliser

Utilisez ce runbook quand :

- vous passez une installation à une nouvelle étiquette de version,
- vous arrêtez ou redémarrez une instance du backend,
- vous vérifiez qu’un arrêt a été propre.

## Avant de commencer

- Épinglez une étiquette de version, par exemple `1.4.2`. Ne suivez pas
  `latest` en production — voir
  [Déployer avec des conteneurs](/fr/admin/install/containers/).
- Prenez un instantané de la base de données avant de revenir en arrière sur
  une migration. Un retour arrière exécute du DDL que seul un instantané peut
  annuler.
- Retenez la règle append-only : les fichiers de migration appliqués ne
  sont jamais édités, renumérotés, ni fusionnés.

## Étapes

### 1. Montez en version

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

La nouvelle image du backend démarre et son entrypoint exécute une
chaîne :

```text
render config (when absent) → migrate → seed:core → server
```

Chaque étape est idempotente. L’étape migrate réessaie trois fois, puis le
démarrage s’arrête. Après le démarrage, vérifiez que le backend est
prêt :

```sh
curl -sf https://facet.example.tld/Healthcheck
```

### 2. Respectez les deux contraintes de schéma

- Le binaire embarque ses migrations à la compilation. Une image déployée
  n’a besoin d’aucune arborescence `db/` sur le disque, et un fichier de
  migration modifié exige une reconstruction.
- Après la première version, `db/migrations/` est append-only. N’éditez, ne
  renumérotez, ni ne fusionnez jamais un fichier qu’une base installée a
  appliqué. Un fichier édité désynchronise chaque déploiement de la liste
  appliquée dans `_migrations`.

  Pour annuler une mise à niveau, revenez sur le schéma avec
  `facet migrate:down` depuis un conteneur ponctuel de la nouvelle image,
  après l’instantané. Les règles complètes d’application et de retour
  arrière sont dans [Migrations de la base de données](/fr/admin/keep-running/migrations/).

### 3. Épinglez UTC pour le travail manuel en base

Chaque colonne d’horodatage stocke l’UTC sans marque de fuseau. Deux couches
épinglent la zone de la session : l’application ajoute `TimeZone=UTC` à

chaque connexion du pool, et la migration du schéma a posé la valeur par
défaut du rôle applicatif à UTC. Un client qui se connecte avec un autre rôle
reçoit la valeur par défaut du serveur et doit poser la zone lui-même.

:::caution
Une session non UTC ne corrompt pas les lectures, mais elle fausse les
écritures. Les valeurs par défaut de `now()` et les casts d’horodatage
stockent l’heure de la machine locale, et PostgreSQL supprime le décalage
sans avertissement. Épinglez `TimeZone=UTC` sur `psql`, les outils BI, et les
scripts de mise à niveau.
:::

### 4. Retenez la séquence d’arrêt

Le gestionnaire attrape `SIGTERM`, `SIGINT` et `SIGHUP` dès le premier
instant du démarrage. Un signal lance cette séquence :

<!-- d2
direction: down
signal: "Signal received"
listeners: "Listeners close"
websockets: "WebSockets get close frames"
inflight: "In-flight requests finish, max 30 s"
teardown: "Subsystem teardown in fixed order"
exit: "Exit 0" {class: ok}

signal -> listeners
listeners -> websockets
websockets -> inflight
inflight -> teardown
teardown -> exit
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/77baab5f-light.svg" alt="Signal received" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/77baab5f-dark.svg" alt="Signal received" loading="lazy" />
</div>

Le teardown arrête les sous-systèmes du plus récent au plus ancien :
cron, jobs, hooks, livraison des webhooks, passages sidecar, réplication,
abonnés du cache, fanout WebSocket, et le gestionnaire d’événements en
dernier. Il draine le DDL d’index en arrière-plan avec une borne de
5 secondes, puis ferme les pools de la base de données. Chaque étape
s’exécute même si une étape antérieure a levé une erreur. Un second signal
sort immédiatement : le teardown tourne toujours, mais l’attente du
drain non.

Sur un déploiement multi-instances, un arrêt propre libère aussitôt les
verrous de shard Redis, si bien qu’une instance voisine prend le relais des
flux sans attendre l’expiration du verrou.

### 5. Donnez au drain une grâce suffisante

L’application borne son propre drain à 30 secondes. Le runtime de conteneurs
tue le processus plus tôt si sa période de grâce est plus courte. Docker
Compose en donne 10 par défaut. Montez-la au-dessus de la borne du
drain :

```yaml
services:
  backend:
    stop_grace_period: 45s
```

## Exemple

Un runbook de mise à niveau complet pour une installation Compose :

```sh
# 1. Récupérez les nouvelles images de version.
docker compose -f docker/compose.prod.yml pull

# 2. Recréez la pile. L’entrypoint migre et réensemence les doctypes core.
docker compose -f docker/compose.prod.yml up -d

# 3. Vérifiez que le backend est prêt.
curl -sf https://facet.example.tld/Healthcheck

# 4. Plus tard, à l’arrêt du backend, confirmez l’arrêt propre dans les logs :
#    la ligne "graceful shutdown complete" termine la séquence.
```

L’image Docker fait aussi tourner son propre healthcheck sur
`http://127.0.0.1:3000/Healthcheck` toutes les 10 secondes, donc `docker ps`
affiche l’état sans outil supplémentaire.

## Dépannage

**Le runtime tue le backend avant la fin du teardown.**

La période de grâce est plus courte que le drain. Posez `stop_grace_period`
au-dessus de 30 secondes, comme dans le fragment ci-dessus.

**Le démarrage s’arrête après trois tentatives de migrate.**

Lisez les logs du backend : une base injoignable ou un problème de
permissions en est la cause habituelle. Corrigez la cause, puis relancez
`docker compose up -d`.

**Vous devez annuler la partie schéma d’une mise à niveau.**

Prenez un instantané, puis lancez `facet migrate:down` depuis un conteneur
ponctuel de la nouvelle image. Voir
[Migrations de la base de données](/fr/admin/keep-running/migrations/) pour la syntaxe
de cible et les garde-fous.

**`/Healthcheck` répond `503` après la mise à niveau.**

Lisez `database`, `redis` et `events` dans le corps — voir
[Contrôles de santé, métriques, tracing, logs](/fr/admin/keep-running/monitoring/).
Une migration en échec se nomme elle-même dans les logs du backend.

## Voir aussi

- [Migrations de la base de données](/fr/admin/keep-running/migrations/) — application
  et retour arrière en détail, et la règle UTC.
- [Déployer avec des conteneurs](/fr/admin/install/containers/) — les images,
  les étiquettes, et la chaîne de l’entrypoint.
- [Déployer en production](/fr/admin/install/production/) — le pas-à-pas complet du
  déploiement.
- [Contrôles de santé, métriques, tracing, logs](/fr/admin/keep-running/monitoring/) —
  les sondes que ce runbook vérifie.
- Internes sur GitHub : [shutdown.md](https://github.com/wearefacet/facet/blob/main/doc/backend/shutdown.md), [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md).
