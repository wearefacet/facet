---
title: "Mettre à niveau Facet"
description: "Passez Facet à une nouvelle version, annulez une version sans risque, et arrêtez le backend sans couper le travail en cours."
type: how-to
audience: [operator]
features: [PLT-15, PLT-11]
verified_at: eee55a2
sidebar:
  order: 4
---

Une nouvelle version est sortie et l’installation a deux versions de
retard. Mettre Facet à niveau est délibérément ennuyeux. Une version
est une nouvelle image de conteneur, et le point d’entrée migre le
schéma au démarrage. Une mise à niveau est un pull, un redémarrage et
un contrôle de santé. Un arrêt est aussi un signal. Sur un signal, le
backend ferme ses listeners et envoie une trame de fermeture à chaque
WebSocket. Il attend les requêtes en cours, puis démonte ses
sous-systèmes dans un ordre fixe.

## Ce qu’est une version

Les versions à ce jour — 0.2.0-beta (2026-11-20), 0.2.1 (2026-11-24),
0.2.2 (2026-11-26), 0.2.3 (2026-11-28) — suivent `MAJOR.MINOR.PATCH`,
avec `0.x` traité comme beta. Le projet est avant 1.0 : une version
peut contenir des changements de rupture. Chaque version porte une
section **Deployment notes** dans `CHANGELOG.md` ; lisez-la avant de
récupérer les images. Elle nomme les étapes que cette page ne peut pas
connaître à l’avance — une variable d’environnement requise, une valeur
par défaut changée, un re-téléchargement d’image imposé.

Les migrations de base de données sont en append-only et portent des
sections `-- DOWN` testées, si bien qu’un changement de schéma peut
être annulé via `facet migrate:down`. C’est toute la politique engagée
aujourd’hui ; cette page ne promet pas plus que le changelog et le code
ne le tiennent.

## Quand l’utiliser

- Vous passez une installation à un nouveau tag de version.
- Vous arrêtez ou redémarrez une instance backend.
- Vous vérifiez qu’un arrêt était propre.

## Avant de commencer

- Épinglez un tag de version, par exemple `0.2.2`. Ne suivez pas `latest` en production — voir [Exécuter avec des conteneurs](/fr/admin/install/containers/).
- Lisez les **Deployment notes** de la version dans `CHANGELOG.md`.
- Prenez un instantané de la base avant d’annuler une migration. Une annulation exécute du DDL que seul un instantané peut défaire.
- Connaissez la règle d’append-only : les fichiers de migration appliqués ne sont jamais édités, renumérotés ni fusionnés.

## Étapes

### 1. Passer à la nouvelle version

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

La nouvelle image backend démarre et son point d’entrée exécute une
chaîne :

```text
render config (when absent) → migrate → seed:core → server
```

Chaque étape est idempotente. L’étape migrate réessaie trois fois, puis
le démarrage s’arrête. Après le démarrage, contrôlez la disponibilité :

```sh
curl -sf https://facet.example.tld/Healthcheck
```

### 2. Respecter les deux contraintes de schéma

- Le binaire embarque ses migrations à la compilation. Une image
  déployée n’a pas besoin de l’arbre `db/` sur disque, et un fichier de
  migration changé exige une reconstruction.
- Après la première version, `db/migrations/` est en append-only.
  N’éditez, ne renumérotez, ne fusionnez jamais un fichier qu’une base
  installée a appliqué.

Pour annuler une mise à niveau, annulez le schéma avec
`facet migrate:down` depuis un conteneur à usage unique de la nouvelle
image, après l’instantané. Les règles complètes d’application et
d’annulation sont dans
[Migrations de base de données](/fr/admin/keep-running/migrations/).

### 3. Connaître la séquence d’arrêt

Le handler piège `SIGTERM`, `SIGINT` et `SIGHUP` dès le premier moment
du démarrage. Un signal exécute cette séquence :

*Un signal, cinq étapes, exit 0.*

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
cron, jobs, hooks, livraison de webhooks, passes sidecar, réplication,
abonnés au cache, fanout WebSocket, et le gestionnaire d’événements en
dernier. Il draine le DDL d’index en arrière-plan avec une borne de
5 secondes, puis ferme les pools de base de données. Chaque étape
s’exécute même quand une étape précédente lève une exception. Un second
signal sort à l’instant : le teardown tourne toujours, mais l’attente
de drain non.

Sur un déploiement multi-instances, un arrêt propre libère les verrous
de shard Redis à l’instant. Une instance pair prend les streams sans
attendre la fin de vie des verrous.

### 4. Donner assez de délai de grâce au drain

L’application borne son propre drain à 30 secondes. Le runtime de
conteneur tue le processus plus tôt si sa période de grâce est plus
courte. Docker Compose donne 10 secondes par défaut, et le fichier
compose livré ne l’élève pas. Posez-le au-dessus de la borne de drain :

```yaml
services:
  backend:
    stop_grace_period: 45s
```

## Exemple

Un runbook complet de mise à niveau pour une installation Compose :

```sh
# 1. Lisez les Deployment notes de la version dans CHANGELOG.md.

# 2. Récupérez les images de la nouvelle version.
docker compose -f docker/compose.prod.yml pull

# 3. Recréez la pile. Le point d’entrée migre et relance la seed des doctypes core.
docker compose -f docker/compose.prod.yml up -d

# 4. Contrôlez la disponibilité.
curl -sf https://facet.example.tld/Healthcheck

# 5. Plus tard, quand vous arrêtez le backend, confirmez l’arrêt propre dans les journaux :
#    la ligne "graceful shutdown complete" termine la séquence.
```

L’image exécute aussi son propre healthcheck sur
`http://127.0.0.1:3000/Healthcheck` toutes les 10 secondes. `docker ps`
montre l’état sans outillage supplémentaire.

## Dépannage

**Le runtime tue le backend avant la fin du teardown.**

La période de grâce est plus courte que le drain. Posez
`stop_grace_period` au-dessus de 30 secondes, comme dans le fragment
ci-dessus.

**Le démarrage s’arrête après trois tentatives de migrate.**

Lisez les journaux backend : une base injoignable ou un problème de
permissions est la cause habituelle. Corrigez la cause, puis lancez
`docker compose up -d` de nouveau.

**Vous devez annuler la partie schéma d’une mise à niveau.**

Prenez un instantané, puis lancez `facet migrate:down` depuis un
conteneur à usage unique de la nouvelle image. Voir
[Migrations de base de données](/fr/admin/keep-running/migrations/)
pour la syntaxe de cible et les garde-fous.

**`/Healthcheck` répond `503` après la mise à niveau.**

Lisez `database`, `redis` et `events` dans le corps — voir
[Santé, métriques et journaux](/fr/admin/keep-running/monitoring/).
Une migration en échec se nomme dans les journaux backend.

## Voir aussi

- [Migrations de base de données](/fr/admin/keep-running/migrations/) — appliquer et annuler en entier, et la règle UTC.
- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — images, tags, et la chaîne de point d’entrée.
- [Passer en production](/fr/admin/install/production/) — le parcours de déploiement complet.
- [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/) — les sondes que ce runbook contrôle.
- [Versions](/fr/reference/changelog/) — le changelog d’où cette page lit ses notes.
- Documentation interne sur GitHub : [shutdown.md](https://github.com/wearefacet/facet/blob/main/doc/backend/shutdown.md), [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md).
- [CLI facet](/fr/reference/cli-facet/)
