---
title: Prérequis système et topologie
description: Vérifiez ce qu’un hôte exige pour faire tourner Facet, et comment backend, frontend, PostgreSQL et Redis se connectent.
audience: [operator, evaluator]
features: [PLT-10, PLT-16]
sidebar:
  order: 1
verified_at: f1409cdc
---

Facet tient en un binaire backend, un serveur frontend et deux magasins
d’état. Le backend garde chaque fait durable dans PostgreSQL. Redis est le bus
de réaction. Cette page liste ce qu’un hôte exige et comment les pièces se
connectent, pour dimensionner un déploiement avant de le lancer.

## Quand l’utiliser

Utilisez cette page quand :

- Vous planifiez un hôte ou une pile de conteneurs pour Facet.
- Vous choisissez entre une base unique et un cluster routé.
- Vous vérifiez une machine face aux prérequis.

## Prérequis

| Composant | Exigence | Notes |
| --- | --- | --- |
| PostgreSQL | 14 ou plus récent | La fonction `ulid()` exige PostgreSQL 14. Une instance suffit pour la plupart des installations. |
| Redis | Requis | Le bus d’événements, les sessions, les codes OAuth et les limites de débit l’utilisent. La pile de release fait tourner l’image `redis:7`. |
| Fichier de configuration | `config.{APP_ENV}.yml` | Le démarrage échoue sans lui. Voir [Fichiers de configuration](/fr/admin/configure/configuration-files/). |
| Binaire backend | Image de release, ou `make build_release` | Migrations, scripts d’événements Lua et corpus d’initialisation voyagent dans le binaire. |
| Docker avec Compose | Pour la voie conteneurs | La pile de release compte cinq services. Voir [Déployer avec des conteneurs](/fr/admin/install/containers/). |

:::note
La pile de release livre l’image `pgvector/pgvector:0.8.0-pg17`. Une image
PostgreSQL standard fonctionne aussi. Les fonctions d’assistant à récupération
augmentée restent désactivées tant que l’extension `vector` n’existe pas sur
le serveur.
:::

## Topologie

<!-- d2
direction: down
browser: Browser {class: external}
caddy: Caddy edge
frontend: Frontend server
backend: Backend API
postgres: PostgreSQL {class: store}
redis: Redis {class: store}

browser -> caddy
caddy -> frontend
caddy -> backend
frontend -> backend
backend -> postgres
backend -> redis
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/5a512ccc-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/5a512ccc-dark.svg" alt="Diagram" loading="lazy" />
</div>

La pile de conteneurs fait tourner cinq services :

| Service | Image | Exposé au réseau ? |
| --- | --- | --- |
| `postgres` | `pgvector/pgvector:0.8.0-pg17` | Non |
| `redis` | `redis:7` | Non |
| `backend` | `ghcr.io/wearefacet/facet` | Non — l’entrée achemine vers lui |
| `frontend` | `ghcr.io/wearefacet/facet-frontend` | Non — l’entrée achemine vers lui |
| `caddy` | `caddy:2` | Oui — il publie le port TLS |

L’image backend tourne sous l’uid 10001. L’image frontend tourne sous `node`.
Un déploiement depuis les sources remplace les deux images d’application par
`make build_release` et le serveur SvelteKit de dev ou de build — voir
[Installer pour le développement](/fr/build/dev-environment/).

## Topologie de la base de données

Par défaut, le backend ouvre un pool depuis `DATABASE_URL`. Chaque lecture et
chaque écriture partagent ce pool. La plupart des installations s’arrêtent là.

Une installation plus grande peut répartir la charge avec la table de routage
facultative `database.cluster`. Chaque entrée nomme une base physique et les
ressources qu’elle sert :

- Une ressource est un id de domaine, une étiquette de sous-système préfixée
  par `$`, ou `*`.
- Exactement une entrée porte `*`. Elle sert le plan de contrôle et tout ce
  qui n’est pas routé.
- Une ressource précise n’apparaît que dans une seule entrée.
- Une entrée peut porter un pool `replica` en lecture seule, facultatif.
  Chaque pool en lecture seule exécute `SET default_transaction_read_only = on`,
  si bien qu’une écriture mal étiquetée échoue bruyamment.
- Des entrées qui partagent une même URL gardent des pools séparés. Cela donne
  une isolation de pool sans seconde base.

  `database.statement_timeout_ms` s’applique à chaque connexion poolée du
  processus serveur. Les points d’entrée CLI n’ont pas de timeout : un
  DDL long ne peut pas être annulé.

## Étapes

1. Provisionnez les magasins d’état. Installez PostgreSQL 14 ou plus récent,
   et Redis. Créez une base vide pour le premier déploiement.
2. Mettez le fichier de configuration en place. Réglez `event.url` sur
   l’adresse Redis et `DATABASE_URL` dans l’environnement. Voir
   [Fichiers de configuration](/fr/admin/configure/configuration-files/).
3. Choisissez la topologie de la base. Commencez avec l’unique pool
   `DATABASE_URL`. Ajoutez la table de routage quand un pool ne suffit plus à

   la charge.
4. Lancez la pile. Prenez la voie conteneurs pour la production —
   [Déployer avec des conteneurs](/fr/admin/install/containers/) — ou
   construisez depuis les sources. Le pas-à-pas à copier-coller est
   [Déployer en production](/fr/admin/install/production/).

## Exemple

Une table de routage de cluster avec une base principale et un petit pool de
masse. Les deux entrées partagent la même URL, donc le pool de masse n’est
qu’une isolation de pool :

```yaml
database:
  statement_timeout_ms: 5000
  cluster:
    databases:
      main:
        url: !env DATABASE_URL
        max_pool_size: 20
        resources: ["*"]
      bulk_pool:
        url: !env DATABASE_URL
        max_pool_size: 8
        resources: ["$bulk"]
```

## Dépannage

**Le démarrage échoue et nomme le chemin de configuration.**

Le fichier n’existe pas à l’emplacement résolu. Le démarrage ne retombe jamais
sur le fichier d’un autre environnement.

**Le démarrage échoue avec `Missing required config key 'artifact_base_url'`.**

Ajoutez les clés de premier niveau requises. Voir
[Fichiers de configuration](/fr/admin/configure/configuration-files/).

**PostgreSQL lève une erreur dans `ulid()`.**

Le serveur est plus ancien que PostgreSQL 14. Mettez le serveur à niveau.

**Le démarrage échoue avec `Missing 'event' key in config`.**

Ajoutez la section `event:` avec l’URL Redis. Redis est une dépendance
requise.

**Les emprunts de connexion attendent sous charge.**

Surveillez la métrique `facet_db_checkout_total{database, role}` et ajustez
`max_pool_size` par entrée. Une écriture imbriquée dans un périmètre de
lecture garde deux connexions pendant toute sa durée.

## Voir aussi

- [Déployer avec des conteneurs](/fr/admin/install/containers/) — les images et
  l’entrée TLS.
- [Déployer en production](/fr/admin/install/production/) — le pas-à-pas à

  copier-coller.
- [Fichiers de configuration](/fr/admin/configure/configuration-files/) — chaque clé
  que prend le fichier de configuration.
- [Migrations de base de données](/fr/admin/keep-running/migrations/) — comment le schéma
  atteint la base.
- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — les concepts
  derrière les services.
- Internes sur GitHub :
  [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md),
  [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md),
  [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
