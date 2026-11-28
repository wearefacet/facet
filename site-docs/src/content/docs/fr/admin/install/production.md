---
title: Passer en production
description: Faites tourner la pile Facet en production avec Docker Compose, de l’hôte vierge à la première connexion.
type: how-to
audience: [operator]
features: [PLT-16, APP-06, PLT-11, IAM-12]
sidebar:
  order: 2
verified_at: eee55a2
---

La direction a donné son accord, et lundi c’est la mise en service. La voie de production est Docker Compose qui tire les images de version depuis GHCR : PostgreSQL, Redis, le backend, le frontend, et un frontal Caddy avec TLS. Aucune chaîne d’outils locale n’est nécessaire — l’hôte demande Docker avec Compose, et rien d’autre. Vous ne clonez pas le dépôt ; vous téléchargez trois fichiers et vous lancez Compose.

## Avant de commencer

- Docker avec Compose est présent sur l’hôte.
- Vous connaissez le nom d’hôte public et les valeurs du relais SMTP.
- Les clés de configuration sont familières — voir [Fichiers de configuration](/fr/admin/configure/configuration-files/).

## Étapes

1. Créez un dossier et téléchargez les trois fichiers de la pile :

   ```sh
   mkdir facet && cd facet
   curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/compose.yml
   curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/Caddyfile.prod
   curl -fsSL  https://github.com/wearefacet/facet/releases/latest/download/.env.example -o .env.example
   cp .env.example .env
   ```

   `compose.yml` tire `ghcr.io/wearefacet/facet` et `ghcr.io/wearefacet/facet-frontend` ; il ne construit jamais. Épinglez une étiquette de version dans `.env` avec `FACET_VERSION` (défaut `latest`).

2. Remplissez `.env` — nom d’hôte public, relais SMTP, secrets. Le fichier documente chaque clé. Définissez aussi `JWT_SIGNING_KEY` : c’est la clé de signature des jetons d’accès. Gardez une valeur stable — sans elle, chaque redémarrage déconnecte les clients API à bearer token. Compose s’arrête de façon explicite sur toute clé obligatoire manquante, en la nommant.

3. Démarrez la pile :

   ```sh
   docker compose up -d
   ```

   L’entrypoint du backend applique les migrations et initialise le schéma `core` à chaque démarrage. Aucune étape de schéma manuelle.

4. Créez le premier administrateur :

   ```sh
   docker compose run --rm backend seed:admin ops@your-company.tld
   ```

   La commande affiche un mot de passe à usage unique. Il ne s’affiche qu’une seule fois — notez-le dans un gestionnaire de mots de passe.

5. Ouvrez `https://<your-hostname>` (défaut : `https://facet.localhost:3443`), connectez-vous avec le mot de passe à usage unique, puis définissez un vrai mot de passe quand c’est demandé.

   Cette adresse est le port du frontal Caddy. `HTTPS_PORT` dans `.env` le définit (défaut `3443`). Le backend écoute sur le port `3000` à l’intérieur du réseau Docker, et le frontal lui relaie les requêtes. Le port `3000` n’est pas publié sur l’hôte.

6. Vérifiez que la pile est saine :

   ```sh
   curl -fsS https://<your-hostname>/Healthcheck
   ```

   La réponse porte `"status":"ok"` quand le backend, son pool PostgreSQL et Redis sont tous joignables.

## Ce qu’il faut savoir en production

- **Les migrations sont embarquées dans le binaire.** Un binaire déployé n’a pas besoin de l’arborescence `db/` sur disque. Après la première version, le répertoire des migrations n’accepte que les ajouts — ne modifiez jamais un fichier de migration appliqué.
- **Les images sont tirées, pas construites.** `docker compose pull` récupère les étiquettes `FACET_VERSION` épinglées ; `up -d` les démarre. Pour passer à une version plus récente, changez `FACET_VERSION` dans `.env`, puis `docker compose pull && docker compose up -d`.
- **Les timestamps sont stockés en UTC.** Le schéma garde des valeurs UTC sans fuseau horaire. L’application épingle sa session PostgreSQL sur UTC. Un client qui se connecte avec un autre rôle (psql, outils BI) doit définir `TimeZone=UTC` lui-même, sinon ses écritures se décalent du fuseau de sa session.
- **Redis est obligatoire.** Le bus d’événements, les sessions, les codes OAuth et les rate limits l’utilisent. PostgreSQL porte l’état durable ; Redis est le bus de réaction.
- **Une seule source de mot de passe.** Compose interpole les deux côtés de `DATABASE_URL` depuis les mêmes clés `POSTGRES_*`, donc le mot de passe Postgres existe en un seul endroit — `.env`.
- **La clé maîtresse protège les secrets stockés.** `FACET_SECRETS_MASTER_KEY` chiffre au repos les hachages de mots de passe, les identifiants API et les graines TOTP. Le magasin refuse de démarrer avec une clé de moins de 32 octets. La perdre rend les secrets stockés illisibles — gardez-la avec le reste de vos secrets.

## Avant la mise en service

Chaque point renvoie vers la page qui le couvre. Parcourez la liste avant que le premier utilisateur réel ne se connecte.

- **TLS** — [Exécuter avec des conteneurs](/fr/admin/install/containers/). Le frontal émet les certificats des noms locaux depuis sa CA interne et ceux des noms publics via Let’s Encrypt ; un nom d’hôte public demande la publication du port 80.
- **Email** — [Email](/fr/admin/configure/email/). Les réinitialisations de mot de passe et les invitations voyagent par courriel ; une installation incapable de livrer bloque les connexions.
- **Stockage des fichiers** — [Stockage des fichiers](/fr/admin/configure/file-storage/). Choisissez le backend filesystem ou S3 avant le premier téléversement ; l’adaptateur se câble une fois par processus.
- **Sauvegardes** — [Sauvegarder et restaurer](/fr/admin/keep-running/backup-restore/). La sauvegarde est le métier de l’opérateur ; décidez quoi sauvegarder et testez une restauration avant la mise en service.
- **Supervision** — [Santé, métriques et journaux](/fr/admin/keep-running/monitoring/). Pointez vos vérifications vers `/Healthcheck` (H majuscule) et scrapez les métriques depuis l’origine du backend.
- **Mises à niveau** — [Mettre Facet à niveau](/fr/admin/keep-running/upgrades/). Connaissez la procédure de mise à niveau avant d’en avoir besoin sous pression.
- **Politique MFA** — [Exiger le MFA](/fr/admin/people/mfa/). Décidez si la connexion exige un second facteur, et réglez-le avant que les comptes ne s’accumulent.

## Voir aussi

- [Exécuter avec des conteneurs](/fr/admin/install/containers/) — images, étiquettes, montage de la configuration, et le frontal TLS.
- [Premier démarrage et amorçage](/fr/admin/install/bootstrap/) — les commandes derrière l’étape 4.
- [Fichiers de configuration](/fr/admin/configure/configuration-files/) — chaque clé que prend le fichier de configuration.
- [Migrations de la base de données](/fr/admin/keep-running/migrations/) — ce que l’entrypoint exécute au démarrage.
- Internes sur GitHub : [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md), [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md).
- [Sécurité et gouvernance](/fr/discover/security/)
- [Prérequis système](/fr/admin/install/requirements/)
