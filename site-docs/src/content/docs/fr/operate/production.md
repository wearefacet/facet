---
title: Déployer en production
description: Faites tourner la pile Facet en production avec Docker Compose.
audience: [operator]
features: [PLT-16, APP-06, PLT-11, IAM-12]
sidebar:
  order: 3
verified_at: f1409cdc
---

En production, tout passe par Docker Composeà : PostgreSQL, Redis, le
backend, le frontend, et une terminaison TLS Caddy. Aucune chaîne d’outils
locale n’est nécessaire.

## Prérequis

Docker avec Compose. Rien d’autre.

## Étapes

1. Clonez ce dépôt et créez le fichier d’environnementà :

   ```sh
   cp docker/.env.example docker/.env
   ```

   Remplissez les valeurs — nom d’hôte public, relais SMTP, secrets. Le
   fichier documente chaque clé.

2. Construisez et démarrez la pileà :

   ```sh
   docker compose -f docker/compose.prod.yml up -d --build
   ```

   Le point d’entrée du backend applique les migrations et initialise le
   schéma de base à chaque démarrage. Aucune étape manuelle pour le schéma.

3. Créez le premier administrateurà :

   ```sh
   docker compose -f docker/compose.prod.yml exec backend facet seed:admin ops@your-company.tld
   ```

   La commande affiche un mot de passe à usage unique. Il ne s’affiche
   qu’une seule fois — notez-le dans un gestionnaire de mots de passe.

4. Ouvrez `https://<your-hostname>` (par défautà :
   `https://facet.localhost:3443`), connectez-vous avec le mot de passe à

   usage unique, puis définissez un vrai mot de passe quand c’est demandé.

   Cette adresse est le port de la terminaison Caddy. `HTTPS_PORT` dans
   `docker/.env` le définit (par défaut `3443`). Le backend écoute sur le
   port `3000` à l’intérieur du réseau Docker, et la terminaison lui
   relaie les requêtes. Le port `3000` n’est pas publié sur l’hôte.

## À savoir en production

- **Les migrations sont embarquées dans le binaire.** Un binaire déployé
  n’a pas besoin de l’arborescence `db/` sur disque. Après la première mise
  en production, le répertoire des migrations n’accepte que les ajouts — ne
  modifiez jamais un fichier de migration appliqué.
- **Les timestamps sont stockés en UTC.** Le schéma garde des valeurs UTC
  sans fuseau horaire. L’application épingle sa session PostgreSQL sur
  UTC. Un client qui se connecte avec un autre rôle (psql, outils BI) doit
  définir `TimeZone=UTC` lui-même, sinon ses écritures se décalent du
  fuseau de sa session.
- **Redis est obligatoire.** Le bus d’événements, les sessions, les codes
  OAuth, et les rate limits l’utilisent. PostgreSQL porte l’état
  durableà ; Redis est le bus de réaction.

## Références

- [Déploiement en conteneurs](/fr/operate/containers-tls/) — images, tags,
  montage de la configuration, et la terminaison TLS.
- [Fichiers de configuration](/fr/operate/configuration-files/) — chaque
  clé que prend le fichier de configuration.
- [Amorçage et tâches CLI](/fr/operate/bootstrap-cli/) — les commandes de
  l’étape 3.
- [Migrations de base de données](/fr/operate/migrations/) — ce que le
  point d’entrée exécute au démarrage.
- Guides opératoires dans le dépôtà : [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md).
