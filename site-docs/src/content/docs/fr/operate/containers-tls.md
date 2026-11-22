---
title: Déployer avec des conteneurs
description: Exécutez les images de version derrière un frontal Caddy avec TLS automatique.
audience: [operator]
features: [PLT-16, APP-06]
sidebar:
  order: 2
verified_at: 008dd880
---

Facet publie deux images de version sur GHCR : une pour le backend, une
pour le frontend. La pile de version y ajoute PostgreSQL, Redis, et un frontal
Caddy qui termine le TLS et aiguille vers les hôtes d’applications. Cette page
couvre les images, le contrat de configuration, et le frontal. Le pas-à-pas
complet reste dans [Déployer en production](/fr/operate/production/).

## Quand l’utiliser

Lisez cette page quand :

- vous déployez avec Docker ou Compose,
- vous choisissez l’étiquette d’image à épingler,
- vous montez un fichier de configuration ou servez des hôtes d’application
  supplémentaires en TLS.

## Avant de commencer

- Docker avec Compose est présent sur l’hôte.
- Vous connaissez le nom d’hôte public et les valeurs du relais SMTP.
- Les exigences de l’hôte sont réunies — voir
  [Prérequis système et topologie](/fr/operate/system-requirements/).

## Étapes

### 1. Choisissez les images et une étiquette

| Image | Contenu | Sonde de santé |
| --- | --- | --- |
| `ghcr.io/wearefacet/facet` | Le binaire backend, `src/` (corpus de skills de l’assistant), l’exemple de configuration, l’entrypoint | `curl` sur `/Healthcheck` |
| `ghcr.io/wearefacet/facet-frontend` | La sortie de build adapter-node avec les `node_modules` de production | Une sonde `fetch` via `node` |

Les étiquettes suivent le pipeline de publication :

| Étiquette | Quand elle bouge |
| --- | --- |
| `X.Y.Z`, `X.Y` | Une étiquette de version `v*` est publiée. Réservées aux versions. |
| `latest` | Une étiquette de version `v*` est publiée. Ne bouge jamais sur un push de branche. |
| `master`, `nightly` | Chaque push vert sur `master`. |
| `sha-<sha>` | Chaque build. Une étiquette par commit. |

Épinglez une étiquette de version en production. Prenez `sha-<sha>` quand vous
devez reproduire un build à l’identique.

### 2. Fournissez la configuration

Le backend ne résout qu’un seul fichier de configuration, dans cet ordre :

1. `FACET_CONFIG_FILE` — un chemin explicite, n’importe quel point de montage.
2. `/app/config.{APP_ENV}.yml` — votre montage, ou la copie de l’exemple livré
   que fait l’entrypoint, écrite seulement quand le fichier est absent.
3. Rien — le démarrage échoue et nomme le chemin manquant.

Trois façons de remplacer l’exemple livré :

| Méthode | Comment |
| --- | --- |
| Monter par-dessus le nom par défaut | `-v ./facet.yml:/app/config.production.yml` |
| Utiliser un environnement personnalisé | `-e APP_ENV=staging -v ./config.staging.yml:/app/config.staging.yml` |
| Utiliser n’importe quel chemin | `-e FACET_CONFIG_FILE=/etc/facet/facet.yml -v ./facet.yml:/etc/facet/facet.yml:ro` |

Chaque `!env NAME` de la configuration doit exister dans l’environnement. Une
variable manquante fait échouer le démarrage au chargement de la
configuration. L’exemple livré exige ces variables :

| Variable | Rôle |
| --- | --- |
| `FACET_HOST` / `FACET_BASE_URL` | L’URL publique principale. Doit être l’origine exacte que voient les navigateurs. |
| `FACET_ARTIFACT_BASE_URL` | L’origine qui diffuse les octets des artefacts. |
| `FACET_ARTIFACT_GRANT_SECRET` | Secret HMAC pour les URL d’octroi des artefacts. |
| `FACET_REDIS_URL` | Le Redis du bus d’événements. |
| `FACET_MAIL_FROM_ADDRESS` / `FACET_MAIL_FROM_NAME` | Identité du courrier sortant. |
| `FACET_SMTP_HOST` / `FACET_SMTP_USERNAME` / `FACET_SMTP_PASSWORD` | Le relais SMTP. |
| `FACET_SECRETS_MASTER_KEY` | Protège chaque secret stocké. Refus par défaut en dessous de 32 octets. |

`DATABASE_URL` et `APP_ENV` restent propres à l’environnement. Le backend les
lit en dehors du YAML.

:::caution
Un fichier de configuration monté doit être lisible par l’uid 10001. Un
montage `600` possédé par root fait échouer le démarrage avec
`File::AccessDeniedError`.
:::

### 3. Laissez l’entrypoint amorcer la base de données

L’entrypoint du backend exécute une chaîne à chaque démarrage :

```text
render config (when absent) → migrate → seed:core → exec facet server
```

Chaque étape est idempotente et non destructive. La chaîne ne supprime rien.
Un conteneur ponctuel exécute directement toute autre commande, donc
`facet migrate` dans un conteneur ponctuel fonctionne tel quel.

### 4. Servez le TLS par le frontal Caddy

La configuration du frontal compte trois blocs de site :

| Bloc de site | Routes | TLS |
| --- | --- | --- |
| Le nom d’hôte principal | `/Healthcheck`, `/Api`, `/app`, `/.well-known`, `/a` et `/Ws` vont au backend. Tout le reste va au frontend. | CA interne sur les noms locaux, ACME sur les noms publics. |
| Catch-all sur le même port | Tout autre SNI va au backend, où l’hébergement d’applications résout l’hôte. | On-Demand TLS, contrôlé par un endpoint ask. |
| Port 80 | Redirection HTTP vers HTTPS. | — |

Le nom d’hôte principal reçoit un certificat de la CA interne quand le nom est
local (le `facet.localhost` par défaut), et de Let’s Encrypt quand il est
public. Les certificats publics via le défi ACME HTTP-01 exigent la
publication du port 80.

Le bloc catch-all sert les hôtes d’applications enregistrés — voir
[Maîtriser la portée des applications](/fr/govern/app-grants/) et
[Hébergement et déploiement des applications](/fr/apps/hosting-deploy/).
Avant d’émettre un certificat, Caddy interroge le backend sur
`/Edge/HostAsk`. Le backend répond `200` pour un hôte d’application
enregistré et actif, et `404` pour tout le reste. Un hôte qui n’est pas un
hôte d’application enregistré ne reçoit aucun certificat.

### 5. Vérifiez la pile

Le pipeline de version fait passer un test de fumée à chaque image : la
pile démarre, le backend répond `status: ok` sur `/Healthcheck`, la page de
connexion se charge à travers le frontend, et les doctypes core existent.
Faites passer le même test localement :

```sh
make docker_images   # construit les étiquettes locales : facet, facet-frontend
make docker_smoke    # lance la pile de test et ses vérifications
```

## Exemple

Montez une configuration personnalisée avec un fichier d’override Compose.
Enregistrez ceci dans `docker/compose.override.yml`, puis lancez Compose avec
les deux fichiers :

```yaml
services:
  backend:
    environment:
      FACET_CONFIG_FILE: /etc/facet/facet.yml
    volumes:
      - ./facet.yml:/etc/facet/facet.yml:ro
```

```sh
docker compose -f docker/compose.prod.yml -f docker/compose.override.yml up -d
```

Le fichier monté peut lui aussi porter des références `!env`. La même
expansion s’applique à chaque fichier de configuration, donc les secrets
restent hors du fichier monté lui aussi.

## Dépannage

**Le démarrage échoue et nomme une variable d’environnement manquante.**

Un `!env NAME` de la configuration n’a pas de valeur. Définissez-la dans
l’environnement ou dans `docker/.env`.

**Le démarrage échoue avec `File::AccessDeniedError`.**

La configuration montée n’est pas lisible par l’uid 10001. Corrigez le mode
du fichier, ou montez-le en lecture seule depuis un chemin lisible.

**Un nom d’hôte local répond avec une erreur de certificat.**

Les noms locaux utilisent la CA interne. Faites confiance au certificat
racine Caddy sur le client, ou prenez un nom public pour ACME.

**Un hôte d’application ne reçoit pas de certificat.**

L’endpoint ask a répondu `404`. L’hôte n’est pas un hôte d’application
enregistré et actif. Inscrivez l’application et posez son hôte — voir
[Inscrire une application](/fr/apps/registering-app/).

**`/Healthcheck` échoue après une montée de version d’image.**

Cherchez dans les logs du backend une migration en échec. L’entrypoint
réessaie l’étape migrate trois fois, puis le démarrage s’arrête.

## Voir aussi

- [Déployer en production](/fr/operate/production/) — le pas-à-pas Compose à

  copier-coller.
- [Prérequis système et topologie](/fr/operate/system-requirements/) — ce dont
  la pile a besoin.
- [Fichiers de configuration](/fr/operate/configuration-files/) — les clés du
  fichier monté.
- [Migrations de la base de données](/fr/operate/migrations/) — ce que
  l’entrypoint exécute au démarrage.
- [Hébergement et déploiement des applications](/fr/apps/hosting-deploy/) — la
  surface des applications hébergées.
- Internes sur GitHub : [container-images.md](https://github.com/wearefacet/facet/blob/main/doc/ops/container-images.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
