---
title: "Stockage de fichiersà : local ou S3"
description: Stockez les fichiers téléversés dans un répertoire local ou un bucket S3, et exécutez les tâches d’entretien du stockage.
audience: [operator]
features: [PLT-04]
sidebar:
  order: 8
verified_at: 008dd880
---

Chaque fichier téléversé se trouve dans un seul magasin d’objets. PostgreSQL
détient les métadonnées et les règles d’accèsà ; le magasin stocke les
octets. Vous choisissez le backend au démarrageà : un répertoire local ou
un bucket S3. Les services compatibles S3, comme MinIO, R2 et Backblaze,
fonctionnent via le réglage `endpoint`.

## Quand l’utiliser

Installez ou entretenez le stockage dans ces casà :

- vous configurez le stockage de fichiers pour une nouvelle installationà ;
- vous opérez la rotation du secret de signature des artefactsà ;
- vous nettoyez les fichiers sans propriétaire ou les objets orphelins.

## Avant de commencer

- Deux clés de premier niveau sont requisesà : `artifact_base_url` et
  `artifact_grant_secret`. Sans elles, le démarrage échoue.
- `artifact_base_url` est l’origine qui sert les octets en flux. Les
  navigateurs y reçoivent des URL signées qui portent le droit d’accès. En
  production, utilisez une origine dédiée, jamais l’hôte principal.
- L’adaptateur de stockage se câble une fois par processus, depuis le fichier
  de configuration. Choisissez le backend avant le premier téléversement.

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
| `directory` | `tmp/uploads/dev` | En `filesystem` : la racine du stockage. En `s3` : le préfixe de clé dans le bucket. |
| `bucket` | aucune | S3 uniquement. Requis pour `s3`. |
| `region` | aucune | S3 uniquement. Requis pour `s3`. |
| `access_key_id` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_ACCESS_KEY_ID`. |
| `secret_access_key` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_SECRET_ACCESS_KEY`. |
| `endpoint` | aucune | S3 uniquement. Repli sur la variable d’environnement `S3_ENDPOINT`. À définir pour les backends compatibles S3. |
| `public` | `false` | Réservé. Le service passe toujours par des octrois signés. |

L’entrée est validée au démarrage. Une entrée `s3` exige le bucket, la région
et les deux identifiants, sinon le démarrage s’arrête avec un message qui nomme
les champs manquants.

:::caution
Le backend se définit uniquement dans le fichier. La page des paramètres
affiche le type effectif en lecture seule, et un basculement à chaud est
refusé. Un basculement laisserait les octets existants piégés dans l’ancien
backend. Pour changer de backend, copiez les objets et modifiez le fichier
pendant une fenêtre de redémarrage.
:::

### 2. Dimensionnez les réglages

| Clé | Valeur par défaut | Signification |
| --- | --- | --- |
| `artifact.max_upload_bytes` | `52428800` (50 MiB) | Plafond strict d’un téléversement. Un téléversement trop gros répond `413` avant toute écriture disque. |
| `artifact.grant_ttl_seconds` | `3600` | TTL des URL signées pour documents et images. |
| `artifact.grant_ttl_media_seconds` | `21600` | TTL des URL signées pour l’audio et la vidéo. |
| `artifact.upload_grant_ttl_seconds` | `300` | TTL d’une URL de téléversement signée à usage unique pour les surfaces d’agent. |
| `artifact.prune_after_days` | `30` | Les fichiers sans propriétaire deviennent éligibles au nettoyage après cette fenêtre. `0` conserve chaque fichier pour toujours. |

Tous les réglages sauf `storage` sont des clés à chaud. Un enregistrement des
paramètres les change à partir de la prochaine émission ou du prochain
nettoyage — voir [Paramètres système](/fr/operate/system-settings/).

### 3. Opérez la rotation du secret de signature

Quiconque détient `artifact_grant_secret` peut émettre des liens de
téléchargement valides pour chaque artefact. Opérez la rotation avec la clé du
secret précédentà :

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
artifact_grant_secret_previous: !env ARTIFACT_GRANT_SECRET_PREVIOUS
```

Définissez la nouvelle valeur dans `artifact_grant_secret` et déplacez
l’ancienne valeur vers `artifact_grant_secret_previous`. Les liens signés avec
l’ancien secret continuent de fonctionner jusqu’à leur expiration. Retirez la
clé précédente une fenêtre TTL après la rotation.

### 4. Lancez les tâches d’entretien

```sh
facet artifacts:prune                 # suppression logique des fichiers sans propriétaire
facet artifacts:prune --hard          # suppression des lignes et des octets
facet artifacts:reconcile --dry-run   # liste des objets sans ligne d’artefact
facet artifacts:reconcile             # les supprime (de plus d’une heure)
facet artifacts:revoke <artifact-id>  # invalide chaque URL signée d’un fichier
```

Le nettoyage épargne tout fichier nommé par une ligne propriétaire vivante ou
une référence récente. La page d’administration
**Configurer → Plateforme → Artefacts** liste le magasin avec des compteurs par
ligne. Voir [Bootstrap et tâches CLI](/fr/operate/bootstrap-cli/) pour le
détail des commandes.

## Exemple

Une configuration S3 complète pour un environnement. Les identifiants viennent
de l’environnement, pas du fichierà :

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

Avec `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` et `S3_ENDPOINT` définis dans
l’environnement.

## Dépannage

**Le démarrage échoue et nomme des champs de stockage manquants.**

Une entrée `s3` manque du bucket, de la région ou d’un identifiant. Renseignez
la clé YAML ou définissez la variable d’environnement de repli.

**Un téléversement répond `413`.**

Le corps dépasse `artifact.max_upload_bytes`. Montez le plafond, ou découpez le
fichier.

**Un lien de téléchargement a cessé de fonctionner.**

L’URL signée a expiré. Les TTL des octrois sont d’une heure par défaut, de six
heures pour les médias. La passerelle émet un lien neuf à chaque clic depuis
l’application.

**Des téléversements sans propriétaire disparaissent.**

Un téléversement autonome n’a pas de document propriétaire avant d’être
rattaché à l’un d’eux. Le nettoyage le balaie après `prune_after_days`, sauf si
une référence le retient. Montez la fenêtre, ou épinglez cette valeur sur la
page des paramètres.

**Un appelant ne peut pas télécharger un fichier qu’il sait nommer.**

L’accès suit la provenance, pas la connaissance de l’id. Un appelant lit un
fichier à travers une ligne propriétaire qu’il peut lire, ou à travers une
action d’opérateur `download *.*` — voir
[Étiquettes de visibilité des champs](/fr/govern/field-visibility-tags/) pour
la couche d’étiquettes.

## Voir aussi

- [Fichiers de configuration](/fr/operate/configuration-files/) — où se trouve
  la section `artifact:`.
- [Paramètres système](/fr/operate/system-settings/) — les réglages à chaud du
  service de fichiers.
- [Fichiers dans les doctypes](/fr/build/files-artifacts/) — la vue côté
  auteur des champs de fichier.
- [Fichiers dans les applications](/fr/apps/files/) — les téléversements
  depuis la surface applicative.
- [Rétention : ce qui est conservé, et pour combien de temps](/fr/govern/retention/) —
  la fenêtre de nettoyage parmi les autres fenêtres.
- Internes sur GitHubà :
  [artifact.md](https://github.com/wearefacet/facet/blob/main/doc/backend/artifact.md),
  [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
