---
title: Stockage des fichiers
description: Stockez les fichiers téléversés dans un répertoire local ou un bucket S3, et exécutez les tâches d’entretien du stockage.
type: how-to
audience: [operator]
features: [PLT-04]
sidebar:
  order: 4
verified_at: c34885a
---

L’équipe commence à téléverser des photos d’équipements endommagés, et vous
devez décider où vivent les octets. Chaque fichier téléversé vit dans un
seul magasin d’objets. PostgreSQL détient les métadonnées et les règles
d’accès ; le magasin détient les octets. Vous choisissez le backend au
démarrage : un répertoire local ou un bucket S3. Les services compatibles
S3 comme MinIO, R2 et Backblaze fonctionnent par le réglage `endpoint`.

## Quand l’utiliser

Installez ou entretenez le stockage quand :

- Vous configurez le stockage de fichiers pour une nouvelle installation.
- Vous faites tourner le secret de signature des artefacts.
- Vous nettoyez les fichiers sans propriétaire ou les objets orphelins.

## Avant de commencer

- Deux clés de premier niveau sont requises : `artifact_base_url` et
  `artifact_grant_secret`. Sans elles, le démarrage échoue.
- `artifact_base_url` est l’origine qui diffuse les octets. Les navigateurs
  y reçoivent des URL de capacité signées. Utilisez une origine dédiée en
  production, jamais l’hôte principal.
- L’adaptateur de stockage se câble une fois par processus depuis le
  fichier de configuration. Choisissez le backend avant le premier
  téléversement.

## Étapes

### 1. Choisissez le backend

```yaml
artifact:
  storage:
    type: filesystem
    directory: /data/store
```

```yaml
artifact:
  storage:
    type: s3
    bucket: facet-artifacts
    region: eu-west-1
    directory: artifacts
```

| Champ | Valeur par défaut | Signification |
| --- | --- | --- |
| `type` | `filesystem` | `filesystem` ou `s3`. Une autre valeur fait échouer le démarrage. |
| `directory` | `tmp/uploads/dev` | Filesystem : la racine de stockage. S3 : le préfixe de clé dans le bucket. |
| `bucket` | aucune | S3 uniquement. Requis pour `s3`. |
| `region` | aucune | S3 uniquement. Requis pour `s3`. |
| `access_key_id` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_ACCESS_KEY_ID`. |
| `secret_access_key` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_SECRET_ACCESS_KEY`. |
| `endpoint` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_ENDPOINT`. À définir pour les backends compatibles S3. |
| `public` | `false` | Réservé. Le service passe toujours par des octrois signés. |

L’entrée est validée au démarrage. Une entrée `s3` exige le bucket, la
région et les deux identifiants ; sinon le démarrage s’arrête avec un
message qui nomme les champs manquants.

:::caution
Le backend ne se règle que par le fichier. La page des paramètres affiche
le type effectif en lecture seule, et un basculement à l’exécution est
refusé. Un basculement abandonnerait les octets existants dans l’ancien
backend. Pour changer de backend, copiez les objets et modifiez le fichier
pendant une fenêtre de redémarrage.
:::

### 2. Dimensionnez les réglages

| Clé | Valeur par défaut | Signification |
| --- | --- | --- |
| `artifact.max_upload_bytes` | `52428800` (50 MiB) | Limite absolue d’un téléversement. Un téléversement trop lourd répond `413` avant toute écriture disque. Fichier uniquement : une modification exige un redémarrage. |
| `artifact.grant_ttl_seconds` | `3600` | TTL des URL signées pour les documents et les images. |
| `artifact.grant_ttl_media_seconds` | `21600` | TTL des URL signées pour l’audio et la vidéo. |
| `artifact.upload_grant_ttl_seconds` | `300` | TTL d’une URL de téléversement signée à usage unique pour les surfaces d’agent. Fichier uniquement : une modification exige un redémarrage. |
| `artifact.prune_after_days` | `30` | Les fichiers sans propriétaire deviennent éligibles à la purge après cette fenêtre. `0` conserve chaque fichier pour toujours. |
| `artifact.grant_prune_days` | `7` | Les lignes d’octrois éphémères expirées quittent la table après cette fenêtre. `0` conserve chaque ligne pour toujours. |

Quatre clés sont chaudes : `grant_ttl_seconds`, `grant_ttl_media_seconds`,
`prune_after_days` et `grant_prune_days`. Un enregistrement de paramètres
les modifie dès la prochaine émission ou passe de purge — voir
[Paramètres système](/fr/admin/configure/system-settings/).

`max_upload_bytes` et `upload_grant_ttl_seconds` restent propres au fichier
de configuration : le registre des paramètres ne détient aucune entrée pour
eux, donc une modification exige un redémarrage. `storage.type` est en
lecture seule sur la page des paramètres — l’adaptateur de stockage se
câble une fois par processus, et un basculement à l’exécution est refusé.

### 3. Faites tourner le secret de signature

Quiconque détient `artifact_grant_secret` peut forger des liens de
téléchargement valides pour chaque artefact. Faites-le tourner avec la clé
du secret précédent :

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
artifact_grant_secret_previous: !env ARTIFACT_GRANT_SECRET_PREVIOUS
```

Placez la nouvelle valeur dans `artifact_grant_secret` et déplacez
l’ancienne vers `artifact_grant_secret_previous`. Les liens signés avec
l’ancien secret continuent de fonctionner jusqu’à leur expiration. Retirez
la clé précédente une fenêtre de TTL après la rotation.

### 4. Exécutez les tâches d’entretien

```sh
facet artifacts:prune                 # supprime (soft) les fichiers sans propriétaire
facet artifacts:prune --hard          # supprime les lignes et les octets
facet artifacts:reconcile --dry-run   # liste les objets sans ligne d'artefact
facet artifacts:reconcile             # les supprime (plus vieux qu'une heure)
facet artifacts:revoke <artifact-id>  # invalide chaque URL signée d'un fichier
```

La purge conserve un fichier que toute ligne propriétaire réelle ou
référence récente nomme. La page d’administration
**Configurer → Plateforme → Artefacts** liste le magasin avec les comptages
par ligne. Voir
[Premier démarrage et initialisation](/fr/admin/install/bootstrap/) pour le
détail des commandes.

## Exemple

Une configuration S3 complète pour un environnement. Les identifiants
viennent de l’environnement, pas du fichier :

```yaml
artifact_base_url: "https://cdn.example.tld"
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET

artifact:
  prune_after_days: 30
  grant_ttl_seconds: 3600
  grant_ttl_media_seconds: 21600
  max_upload_bytes: 52428800
  upload_grant_ttl_seconds: 300
  storage:
    type: s3
    bucket: facet-artifacts
    region: eu-west-1
    directory: artifacts
```

Avec `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` et `S3_ENDPOINT` définis
dans l’environnement.

## Dépannage

**Le démarrage échoue et nomme des champs de stockage manquants.**

Une entrée `s3` manque du bucket, de la région ou d’un identifiant.
Remplissez la clé YAML ou définissez le repli d’environnement.

**Un téléversement répond `413`.**

Le corps a dépassé `artifact.max_upload_bytes`. Montez la limite, ou
scindez le fichier.

**Un lien de téléchargement a cessé de fonctionner.**

L’URL signée a expiré. Les TTL des octrois valent une heure par défaut, six
heures pour les médias. La passerelle forge un lien neuf à chaque clic
depuis l’application.

**Des téléversements sans propriétaire disparaissent.**

Un téléversement autonome n’a pas de document propriétaire tant qu’il n’en
rejoint pas un. La purge le balaye après `prune_after_days`, sauf si une
référence le conserve. Montez la fenêtre, ou épinglez-la sur la page des
paramètres.

**Un appelant ne peut pas télécharger un fichier qu’il sait nommer.**

L’accès suit la provenance, pas la connaissance de l’identifiant. Un
appelant lit un fichier par une ligne propriétaire qu’il peut lire, ou par
une action opérateur `download *.*`. Voir
[Cacher un champ à certains rôles](/fr/admin/people/hidden-fields/) pour la
couche d’étiquettes.

## Voir aussi

- [Fichiers de configuration](/fr/admin/configure/configuration-files/) —
  où vit la section `artifact:`.
- [Paramètres système](/fr/admin/configure/system-settings/) — les
  réglages chauds de service.
- [Fichiers dans les doctypes](/fr/build/model/data/files/) — la vue auteur
  des champs de fichier.
- [Fichiers dans les applications](/fr/build/apps/data/files/) — les
  téléversements depuis la surface d’application.
- [Rétention](/fr/admin/history/retention/) — la fenêtre de purge parmi les
  autres fenêtres.
- Internes sur GitHub : [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
