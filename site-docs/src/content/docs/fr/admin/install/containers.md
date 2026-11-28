---
title: Exécuter avec des conteneurs
description: Exécutez les images de version derrière un frontal Caddy avec TLS automatique.
type: how-to
audience: [operator]
features: [PLT-16, APP-06]
sidebar:
  order: 1
verified_at: eee55a2
---

Vous déployez Facet avec Docker ou Compose. Vous devez savoir ce que porte chaque image, comment la configuration atteint le backend, et qui termine le TLS. Facet publie deux images de version sur GHCR : une pour le backend, une pour le frontend. Vous les tirez — vous ne les construisez pas et vous ne clonez pas le dépôt. La pile de version y ajoute PostgreSQL, Redis, et un frontal Caddy qui termine le TLS et aiguille vers les hôtes d’app. Le pas-à-pas complet reste dans [Passer en production](/fr/admin/install/production/).

## Quand l’utiliser

Lisez cette page quand :

- Vous déployez avec Docker ou Compose.
- Vous choisissez l’étiquette d’image à épingler.
- Vous montez un fichier de configuration ou servez des hôtes d’app supplémentaires en TLS.

## Avant de commencer

- Docker avec Compose est présent sur l’hôte.
- Vous connaissez le nom d’hôte public et les valeurs du relais SMTP.
- Les exigences de l’hôte sont réunies — voir [Prérequis système](/fr/admin/install/requirements/).

## Étapes

### 1. Choisir les images et une étiquette

| Image | Contenu | Sonde de santé |
| --- | --- | --- |
| `ghcr.io/wearefacet/facet` | Le binaire du backend, `src/` (corpus de skills de l’assistant), l’exemple de configuration, l’entrypoint | `curl` sur `/Healthcheck` |
| `ghcr.io/wearefacet/facet-frontend` | La sortie de build adapter-node avec les `node_modules` de production | Une sonde `fetch` via `node` |

Les étiquettes suivent le pipeline de publication :

| Étiquette | Quand elle bouge |
| --- | --- |
| `X.Y.Z`, `X.Y` | Une étiquette de version `v*` est publiée. Réservées aux versions. |
| `latest` | Une étiquette de version `v*` est publiée. Ne bouge jamais sur un push de branche. |
| `master`, `nightly` | Chaque push vert sur `master`. |
| `sha-<sha>` | Chaque build. Une étiquette par commit. |

Épinglez une étiquette de version en production (définissez `FACET_VERSION` dans `.env`). Prenez `sha-<sha>` quand vous devez reproduire un build à l’identique.

### 2. Récupérer les trois fichiers de la pile

Un déploiement demande trois fichiers dans un dossier. Aucun ne réclame le dépôt — téléchargez-les depuis la version :

| Fichier | Rôle |
| --- | --- |
| `compose.yml` | La pile : PostgreSQL, Redis, les deux images GHCR, le frontal Caddy. Il tire, il ne construit jamais. |
| `Caddyfile.prod` | La configuration du frontal que le service Caddy monte. |
| `.env` | Vos valeurs — copiez depuis `.env.example` et remplissez-le. |

```sh
mkdir facet && cd facet
curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/compose.yml
curl -fsSLO https://github.com/wearefacet/facet/releases/latest/download/Caddyfile.prod
curl -fsSL  https://github.com/wearefacet/facet/releases/latest/download/.env.example -o .env.example
cp .env.example .env
```

Dans un checkout, les mêmes fichiers sont dans `docker/` sous les noms `compose.ghcr.yml`, `Caddyfile.prod` et `.env.ghcr.example` ; copiez-les dans un dossier propre pour suivre la voie images seules.

### 3. Fournir la configuration

Le backend résout exactement un fichier de configuration, dans cet ordre :

1. `FACET_CONFIG_FILE` — un chemin explicite, n’importe quel point de montage.
2. `/app/config.{APP_ENV}.yml` — votre montage, ou la copie de l’exemple livré faite par l’entrypoint, écrite seulement quand le fichier est absent.
3. Rien — le démarrage échoue et nomme le chemin manquant.

Par défaut, l’entrypoint écrit l’exemple livré, donc aucun montage de configuration n’est requis pour démarrer. Pour le remplacer, montez votre propre fichier sous le nom par défaut avec un override Compose :

```yaml
services:
  backend:
    volumes:
      - ./facet.yml:/app/config.production.yml:ro
```

Chaque `!env NAME` de la configuration doit exister dans l’environnement. Une variable manquante fait échouer le démarrage au chargement de la configuration. Compose s’arrête aussi sur les mêmes clés, de façon explicite : une valeur manquante arrête la pile avant que le backend ne démarre. La pile livrée exige ces variables :

| Variable | Rôle |
| --- | --- |
| `POSTGRES_PASSWORD` | Le mot de passe de la base. Compose construit `DATABASE_URL` à partir de lui — une seule source de mot de passe. |
| `FACET_HOST` / `FACET_BASE_URL` | L’URL publique principale. Doit être l’origine exacte que voient les navigateurs. |
| `FACET_ARTIFACT_BASE_URL` | L’origine qui diffuse les octets des artefacts. |
| `FACET_ARTIFACT_GRANT_SECRET` | Secret HMAC pour les URL de capacité des artefacts. |
| `FACET_REDIS_URL` | Le Redis du bus d’événements. Compose le pointe vers le service `redis`. |
| `FACET_MAIL_FROM_ADDRESS` / `FACET_MAIL_FROM_NAME` | Identité du courrier sortant. |
| `FACET_SMTP_HOST` / `FACET_SMTP_USERNAME` / `FACET_SMTP_PASSWORD` | Le relais SMTP. |
| `FACET_SECRETS_MASTER_KEY` | Protège chaque secret stocké. En dessous de 32 octets, le magasin refuse de démarrer. |
| `JWT_SIGNING_KEY` | La clé de signature des jetons d’accès, une clé privée P-256 au format PEM. Ce n’est pas une clé de configuration — le backend la lit directement dans l’environnement. Sans elle, chaque démarrage frappe une clé temporaire, et chaque redémarrage déconnecte les clients API à bearer token. |

`DATABASE_URL` et `APP_ENV` restent propres à l’environnement. Le backend les lit en dehors du YAML.

:::caution
Un fichier de configuration monté doit être lisible par l’uid 10001. Un montage `600` possédé par root fait échouer le démarrage avec `File::AccessDeniedError`.
:::

### 4. Laisser l’entrypoint amorcer la base de données

L’entrypoint du backend exécute une chaîne à chaque démarrage du serveur :

```text
render config (when absent) → migrate (3 attempts) → seed:core → exec facet server
```

Chaque étape est idempotente et non destructive. La chaîne ne détruit rien — elle ne lance jamais `db_reset`. Un conteneur ponctuel exécute directement toute autre commande : l’entrypoint saute la branche serveur et exécute la commande, donc `run --rm backend seed:admin …` fonctionne sans option supplémentaire.

### 5. Servir le TLS par le frontal Caddy

La configuration du frontal compte trois blocs de site :

| Bloc de site | Routes | TLS |
| --- | --- | --- |
| Le nom d’hôte principal | `/Api`, `/OAuth`, `/A`, `/Ws`, `/Healthcheck`, `/auth` et `/.well-known` vont au backend. Tout le reste va au frontend. | CA interne sur les noms locaux, ACME sur les noms publics. |
| Catch-all sur le même port | Tout autre SNI va au backend, où l’hébergement d’app résout l’hôte. | On-Demand TLS, contrôlé par un endpoint ask. |
| Port 80 | Redirection HTTP vers HTTPS. | — |

Le nom d’hôte principal reçoit un certificat de la CA interne pour un nom local (le `facet.localhost` par défaut), et de Let’s Encrypt pour un nom public. Les certificats publics via le défi ACME HTTP-01 exigent la publication du port 80.

Deux garde-fous du frontal méritent d’être connus :

- Une requête vers le jumeau en minuscules d’un namespace backend — `/api/Deal` par exemple — reçoit un JSON 404 qui nomme la règle de casse. La correspondance des chemins de Caddy est insensible à la casse, et les jumeaux en minuscules sont des identifiants de domaine légaux, donc le frontal les aiguille par la casse, pas par le nom.
- Les noms de sonde sont réservés. `GET /healthcheck` (en minuscules) répond 404 pour chaque méthode, donc une supervision qui tape le nom de travers échoue de façon visible au lieu de lire la page de connexion comme état de santé. `/metrics` n’est pas acheminé par le frontal du tout — scrapez l’origine du backend.

Le frontal envoie `Strict-Transport-Security` (max-age 3600) et `X-Content-Type-Options: nosniff` sur chaque réponse du nom principal. La surface frontend porte aussi une Content-Security-Policy et `X-Frame-Options: SAMEORIGIN`.

Le bloc catch-all sert les hôtes d’app enregistrés — voir [Contrôler ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) et [Déployer votre app sur Facet](/fr/build/apps/host/deploy/). Avant d’émettre un certificat, Caddy interroge le backend sur `/Edge/HostAsk`. Le backend répond `200` pour un hôte d’app enregistré et actif, et `404` pour tout le reste. Un hôte qui n’est pas un hôte d’app enregistré ne reçoit aucun certificat.

### 6. Vérifier la pile

Le pipeline de version fait passer un test de fumée à chaque image. Le test démarre la pile, vérifie `status: ok` sur `/Healthcheck`, charge la page de connexion à travers le frontend, et confirme que les doctypes `core` existent. Après `docker compose up -d`, exécutez la même vérification contre la pile en place :

```sh
curl -fsS https://facet.localhost:3443/Healthcheck
```

La réponse porte `"status":"ok"` quand le backend, son pool PostgreSQL et Redis sont tous joignables. Dans un checkout du dépôt, le test de fumée local est `make docker_images && make docker_smoke` ; il construit les images au lieu de les tirer, donc il vise les contributeurs, pas une installation.

## Exemple

Montez une configuration personnalisée sur la pile images seules. Ajoutez un fichier d’override Compose `compose.override.yml` dans le même dossier, puis lancez Compose avec les deux fichiers :

```yaml
services:
  backend:
    environment:
      FACET_CONFIG_FILE: /etc/facet/facet.yml
    volumes:
      - ./facet.yml:/etc/facet/facet.yml:ro
```

```sh
docker compose -f compose.yml -f compose.override.yml up -d
```

Le fichier monté peut porter lui-même des références `!env`. La même expansion tourne sur chaque fichier de configuration, donc les secrets restent hors du fichier monté aussi.

## Dépannage

**Le démarrage échoue et nomme une variable d’environnement manquante.**

Un `!env NAME` de la configuration n’a pas de valeur. Définissez-la dans l’environnement ou dans `.env`.

**Le démarrage échoue avec `File::AccessDeniedError`.**

La configuration montée n’est pas lisible par l’uid 10001. Corrigez le mode du fichier, ou montez-le en lecture seule depuis un chemin lisible.

**Un nom d’hôte local répond avec une erreur de certificat.**

Les noms locaux utilisent la CA interne. Faites confiance au certificat racine Caddy sur le client, ou prenez un nom public pour ACME.

**Un hôte d’app ne reçoit pas de certificat.**

L’endpoint ask a répondu `404`. L’hôte n’est pas un hôte d’app enregistré et actif. Enregistrez l’app et posez son hôte — voir [Enregistrer une app](/fr/build/apps/connect/register/).

**`/Healthcheck` échoue après une montée de version d’image.**

Cherchez dans les logs du backend une migration en échec. L’entrypoint réessaie l’étape migrate trois fois, puis le démarrage s’arrête.

## Voir aussi

- [Passer en production](/fr/admin/install/production/) — le pas-à-pas Compose à copier-coller.
- [Prérequis système](/fr/admin/install/requirements/) — ce dont la pile a besoin.
- [Fichiers de configuration](/fr/admin/configure/configuration-files/) — les clés du fichier monté.
- [Migrations de la base de données](/fr/admin/keep-running/migrations/) — ce que l’entrypoint exécute au démarrage.
- [Déployer votre app sur Facet](/fr/build/apps/host/deploy/) — la surface des apps hébergées.
- Internes sur GitHub : [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
- [Apps : construites vite, remplacées librement](/fr/discover/how-it-works/apps/)
