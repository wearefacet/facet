---
title: Prérequis système
description: Vérifiez les prérequis système avant de lancer Facet — PostgreSQL, Redis, le fichier de configuration et la topologie à cinq services.
type: reference
audience: [operator, evaluator]
features: [PLT-10, PLT-16]
sidebar:
  order: 0
verified_at: eee55a2
---

Vous dimensionnez un hôte pour Facet avant le premier déploiement. Facet tourne en deux processus applicatifs au-dessus de deux magasins d’état. Le backend garde chaque fait durable dans PostgreSQL, et Redis transporte les réactions entre événements et consommateurs. Cette page liste ce qu’un hôte demande et comment les pièces se connectent.

## Ce qu’il faut prévoir

- Vous provisionnez la machine ou l’hôte de conteneurs.
- Vous choisissez entre une base unique et un cluster routé.
- Vous vérifiez une machine face aux prérequis.

## Le tableau des prérequis

| Composant | Prérequis | Notes |
| --- | --- | --- |
| PostgreSQL | 14 ou plus récent | La fonction `ulid()` demande PostgreSQL 14. Une instance suffit pour la plupart des installations. |
| Redis | Requis | Le bus d’événements, les sessions, les codes OAuth et les rate limits l’utilisent. La pile de version fait tourner l’image `redis:7`. |
| Fichier de configuration | `config.{APP_ENV}.yml` | Le démarrage échoue sans lui. Voir [Fichiers de configuration](/fr/admin/configure/configuration-files/). |
| Binaire du backend | Image de version, ou `make build_release` | Migrations, scripts d’événements Lua et corpus d’initialisation voyagent dans le binaire. |
| Docker avec Compose | Pour la voie conteneurs | La pile de version compte cinq services. Voir [Exécuter avec des conteneurs](/fr/admin/install/containers/). |

:::note
La pile de version livre l’image `pgvector/pgvector:0.8.0-pg17`. Une image PostgreSQL standard fonctionne aussi. Les fonctions d’assistant à récupération augmentée restent désactivées tant que l’extension `vector` n’existe pas sur le serveur.
:::

Les processus applicatifs restent légers : les magasins d’état dominent. Les chiffres mesurés qui éclairent un dimensionnement — débit, latence, mémoire — sont sur la page [Performances et dimensionnement](/fr/admin/install/performance/).

## La topologie

La pile de version fait tourner cinq services. Seul le frontal Caddy publie des ports de l’hôte ; le trafic interne est du HTTP simple à l’intérieur du réseau Compose.

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
*Deux processus applicatifs sans état derrière un frontal ; l’état réside dans PostgreSQL et Redis.*

<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/5a512ccc-light.svg" alt="Request flow from the browser through the edge to the app processes and the state stores" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/5a512ccc-dark.svg" alt="Request flow from the browser through the edge to the app processes and the state stores" loading="lazy" />
</div>

| Service | Image | Exposé au réseau ? |
| --- | --- | --- |
| `postgres` | `pgvector/pgvector:0.8.0-pg17` | Non |
| `redis` | `redis:7` | Non |
| `backend` | `ghcr.io/wearefacet/facet` | Non — le frontal achemine vers lui |
| `frontend` | `ghcr.io/wearefacet/facet-frontend` | Non — le frontal achemine vers lui |
| `caddy` | `caddy:2` | Oui — il publie le port TLS |

L’image du backend tourne sous l’uid 10001. L’image du frontend tourne sous `node`. Un déploiement depuis les sources remplace les deux images applicatives par `make build_release` et le serveur de build SvelteKit. Construire depuis les sources demande Crystal 1.21, PostgreSQL 14+, Redis, Node.js 20+ avec pnpm, Caddy, et les en-têtes Lua 5.4 ou 5.5.

## Topologie de la base de données

Par défaut, le backend ouvre un pool depuis `DATABASE_URL`. Chaque lecture et chaque écriture partagent ce pool. La plupart des installations s’arrêtent là.

Une installation plus grande peut répartir la charge avec la table de routage facultative `database.cluster`. Chaque entrée nomme une base physique et les ressources qu’elle sert :

- Une ressource est un identifiant de domaine, une étiquette de sous-système préfixée par `$`, ou `*`.
- Exactement une entrée porte `*`. Elle sert le plan de contrôle et tout ce qui n’est pas routé.
- Une ressource précise n’apparaît que dans une seule entrée.
- Une entrée peut porter un pool `replica` en lecture seule, facultatif. Chaque pool en lecture seule exécute `SET default_transaction_read_only = on`, si bien qu’une écriture mal étiquetée échoue de façon visible.
- Des entrées qui partagent une même URL gardent des pools séparés. Cela donne une isolation de pool sans seconde base.

`database.statement_timeout_ms` s’applique à chaque connexion poolée du processus serveur. Les points d’entrée CLI ne gardent aucun timeout, donc un DDL long ne peut pas être annulé.

## Exemple

Une table de routage de cluster avec une base principale et un petit pool de masse. Les deux entrées partagent la même URL, donc le pool de masse n’est qu’une isolation de pool :

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

Le fichier n’existe pas à l’emplacement résolu. Le démarrage ne retombe jamais sur le fichier d’un autre environnement.

**Le démarrage échoue avec `Missing required config key 'artifact_base_url'`.**

Ajoutez les clés de premier niveau requises. Voir [Fichiers de configuration](/fr/admin/configure/configuration-files/).

**PostgreSQL lève une erreur dans `ulid()`.**

Le serveur est plus ancien que PostgreSQL 14. Mettez le serveur à niveau.

**Le démarrage échoue avec `Missing 'event' key in config`.**

Ajoutez la section `event:` avec l’URL Redis. Redis est une dépendance requise.

**Les emprunts de connexion attendent sous charge.**

Surveillez la métrique `facet_db_checkout_total{database, role}` et ajustez `max_pool_size` par entrée. Une écriture imbriquée dans un périmètre de lecture garde deux connexions pendant toute sa durée.

## Voir aussi

- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — les images et le frontal TLS.
- [Passer en production](/fr/admin/install/production/) — le pas-à-pas à copier-coller.
- [Fichiers de configuration](/fr/admin/configure/configuration-files/) — chaque clé que prend le fichier de configuration.
- [Migrations de la base de données](/fr/admin/keep-running/migrations/) — comment le schéma atteint la base.
- [Vue d’ensemble](/fr/discover/how-it-works/) — les concepts derrière les services.
- Internes sur GitHub : [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
