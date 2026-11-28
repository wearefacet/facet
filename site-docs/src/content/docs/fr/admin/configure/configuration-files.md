---
title: Fichiers de configuration
description: Écrivez le fichier de configuration qui démarre le backend, injectez les secrets avec la balise !env et sachez quelles clés sont chaudes.
type: how-to
audience: [operator]
features: [PLT-01, PLT-10]
sidebar:
  order: 1
verified_at: c34885a
---

Le serveur refuse de démarrer et nomme le fichier de configuration
manquant. Un seul fichier YAML configure tout le backend : `config.{env}.yml`.
Le fichier est la source unique de vérité du démarrage. Les adresses de la
base de données et de Redis n’existent que dans lui, donc le fichier doit se
charger avant la connexion à la base. Certaines clés sont chaudes : un
document de paramètres d’exécution peut les surpasser sans redémarrage, et le
fichier reste le repli.

## Quand l’utiliser

Utilisez cette page quand :

- Vous écrivez ou modifiez `config.production.yml`.
- Vous tenez les secrets hors du fichier YAML.
- Vous devez savoir quelles clés un redémarrage change et lesquelles il
  laisse inchangées.

## Avant de commencer

- Vous connaissez la valeur de `APP_ENV` pour le déploiement. Le nom de
  fichier la porte : `config.production.yml` pour `APP_ENV=production`.
- Trois valeurs restent dans l’environnement, jamais dans le YAML :
  `DATABASE_URL`, `APP_ENV` et `JWT_SIGNING_KEY`.
- La page générée
  [Clés du fichier de configuration](/fr/reference/config-keys/) liste
  chaque clé avec son type et sa valeur par défaut. Cette page explique
  comment le fichier se charge.

## Étapes

### 1. Placez le fichier là où le backend le cherche

Le backend résout un seul fichier, dans cet ordre :

1. `FACET_CONFIG_FILE` — un chemin explicite. Un chemin défini mais absent
   fait échouer le démarrage. Aucun repli vers un autre fichier.
2. `config.{APP_ENV}.yml` à côté du binaire — le cas par défaut.

Si aucun fichier ne se résout, le démarrage échoue bruyamment. Le serveur ne
s’exécute jamais avec les réglages d’un autre environnement — des clés de
dev, des cookies non sécurisés ou du courriel sur stdout ne doivent jamais
s’introduire dans un démarrage de production.

### 2. Injectez les secrets avec `!env`

Balisez n’importe quel scalaire avec `!env` pour développer une variable
d’environnement au chargement :

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
```

Règles :

- La valeur développée est toujours une chaîne.
- Une variable absente fait échouer le démarrage. L’erreur nomme la variable
  et le fichier de configuration. Aucun repli silencieux vers une valeur
  vide.
- La balise fonctionne partout dans le document : clés de premier niveau,
  sections imbriquées et listes.
- La balise est refusée dans les paquets de domaines et les définitions de
  doctypes. Le contenu d’auteur importé ne peut pas lire votre environnement.

Une seconde balise, `!env?`, constitue l’étage facultatif : une variable non
définie réduit la clé à null, et la section consommatrice applique sa propre
valeur par défaut. L’exemple de configuration livré l’utilise pour la
connexion de l’assistant ; une installation sans clé de modèle démarre quand
même — l’assistant est livré désactivé.

### 3. Connaissez les sections

Chaque section et chaque clé que les chargeurs lisent figure dans
[Clés du fichier de configuration](/fr/reference/config-keys/). Voici les
sections et leur rôle :

| Section | Contient | Expliqué dans |
| --- | --- | --- |
| `event` | URL Redis et réglage des streams | Obligatoire. Sans cette section, le démarrage échoue. |
| `artifact` | Backend de stockage de fichiers et réglages de service | [Stockage des fichiers](/fr/admin/configure/file-storage/) |
| `mail` | Adaptateur de courriel sortant et SMTP | [Courriel sortant](/fr/admin/configure/email/) |
| `iam` | TTL des tokens, MFA, mode d’authentification, cookies | [Paramètres système](/fr/admin/configure/system-settings/) |
| `assistant` | Connexion LLM et réglages des tours | [Connecter un modèle de langage](/fr/admin/assistant/connect-a-model/) |
| `database` | Délai d’expiration des instructions et table de routage du cluster | [Configuration requise](/fr/admin/install/requirements/) |
| `mutations` | Rétention de l’historique des modifications et fusion à l’écriture | [Rétention](/fr/admin/history/retention/) |
| `tombstone` | Rétention des contenus supprimés | [Rétention](/fr/admin/history/retention/) |
| `secrets` | Clé maître et réglages du magasin de secrets | — |
| `jobs` | Réglages de la file des tâches en arrière-plan | Pris en compte au démarrage. |
| `hooks` | Ordonnanceur des hooks d’événements et de planification | Pris en compte au démarrage. |
| `lua` | Limites du bac à sable pour les scripts de doctypes | — |
| `localization` | Fuseau horaire et langue par défaut de l’instance | [Langues](/fr/admin/configure/languages/) |
| `domains` | Filtre de domaines `included` / `excluded` | N’en réglez qu’un, jamais les deux. |
| `logs` | Format et niveau des journaux | — |
| `cache` | Limite de péremption du cache du processus | — |
| `websocket` | Réglages du pont WebSocket | — |
| `webhook`, `import_export`, `sidecar`, `mcp` | Réglages des sous-systèmes facultatifs | Valeurs par défaut appliquées en cas d’absence. |
| `dev` | Observateur réservé au développement | Pas pour la production. |

Les clés de premier niveau se trouvent hors des sections : `host`, `base_url`,
`artifact_base_url`, `artifact_grant_secret`, `artifact_grant_secret_previous`,
`snapshot_every`, `trusted_proxies`. `artifact_base_url` et
`artifact_grant_secret` sont requis. Sans eux, le démarrage échoue.

Deux règles transversales que les chargeurs appliquent :

- `domains.included` et `domains.excluded` s’excluent mutuellement. Les deux
  non vides font échouer le démarrage.
- `webhook.reconcile_window_hours` doit rester sous `jobs.retention_days`.
  Une fenêtre plus large remettrait en file des événements déjà livrés dont
  les lignes de jobs sont déjà purgées.

### 4. Sachez quelles clés sont chaudes

Une clé chaude se résout dans cet ordre au moment de l’usage : le document
`core.SystemSettings`, puis la valeur du fichier, puis la valeur par défaut
intégrée. Un administrateur peut épingler une clé chaude à l’exécution — voir
[Paramètres système](/fr/admin/configure/system-settings/).

Clés chaudes : la connexion de l’assistant, les valeurs `mail.*`, les
réglages de service des artefacts, les fenêtres de rétention, les valeurs par
défaut de localisation et les valeurs de la politique IAM.

Clés propres au fichier, prises en compte au démarrage : les plannings cron,
les réglages `jobs.*` et `hooks.*`, l’adaptateur de stockage,
`retention_overrides` et `mail.allow_dev_adapter_in_production`.

:::tip
`trusted_proxies` nomme les proxys inverses qui font face au serveur. Une
liste vide ignore `X-Forwarded-For` sur chaque requête. Les entrées sont des
hôtes nus, sans port. Gardez la liste exacte — chaque entrée peut choisir
l’adresse IP client que le serveur voit.
:::

### 5. Répartissez la charge de la base de données avec la table de routage du cluster

Par défaut, le backend ouvre un seul pool à partir de `DATABASE_URL`, et
chaque lecture et écriture le partage. Une installation plus vaste répartit
la charge avec la table de routage facultative `database.cluster`. Chaque
entrée nomme une base physique et les ressources qu’elle sert : un
identifiant de domaine, une étiquette de sous-système préfixée par `$`, ou
`*`. Une seule entrée porte `*` — elle sert le plan de contrôle et tout ce
qui n’est pas routé — et une entrée peut aussi nommer un pool `replica` en
lecture seule. Des entrées qui partagent une même URL gardent des pools
distincts, donc deux entrées sur une même base donnent l’isolation par pool
sans second serveur. [Configuration requise](/fr/admin/install/requirements/)
montre un exemple complet.

## Exemple

Une configuration de production minimale. Chaque clé est une clé que le
démarrage exige ou lit :

```yaml
host: !env FACET_HOST
base_url: !env FACET_BASE_URL
artifact_base_url: !env FACET_ARTIFACT_BASE_URL
artifact_grant_secret: !env FACET_ARTIFACT_GRANT_SECRET

event:
  url: !env FACET_REDIS_URL

artifact:
  storage:
    type: filesystem
    directory: /data/store

mail:
  adapter: smtp
  from_address: !env FACET_MAIL_FROM_ADDRESS
  from_name: !env FACET_MAIL_FROM_NAME
  smtp:
    host: !env FACET_SMTP_HOST
    port: 587
    username: !env FACET_SMTP_USERNAME
    password: !env FACET_SMTP_PASSWORD
    use_tls: true
```

Cette configuration correspond au fichier `docker/config.production.example.yml`
livré — le fichier que l’entrypoint du conteneur produit quand vous ne
montez rien.

## Dépannage

**Le démarrage échoue et nomme le chemin du fichier de configuration.**

Aucun fichier ne s’est résolu. Vérifiez `APP_ENV` et le nom du fichier, ou
définissez `FACET_CONFIG_FILE`.

**Le démarrage échoue avec une erreur `IncludeError` qui nomme une variable.**

Une balise `!env` nomme une variable que l’environnement ne définit pas.
Définissez-la, ou retirez la balise.

**`APP_ENV=production` refuse de démarrer avec une erreur de courriel.**

L’adaptateur de courriel `dev` imprime les messages sur stdout, donc la
production le refuse. Réglez `mail.adapter: smtp` — voir
[Courriel sortant](/fr/admin/configure/email/).

**Le démarrage échoue sur une erreur de domains.**

`domains.included` et `domains.excluded` s’excluent mutuellement. N’en
réglez qu’un, jamais les deux.

**Une modification du fichier ne fait rien.**

Une valeur épinglée à l’exécution l’emporte sur le fichier. Vérifiez les
épinglages — voir [Paramètres système](/fr/admin/configure/system-settings/).

## Voir aussi

- [Paramètres système](/fr/admin/configure/system-settings/) — l’étage
  d’exécution au-dessus du fichier.
- [Clés du fichier de configuration](/fr/reference/config-keys/) — chaque
  clé, type et valeur par défaut, générés depuis le code.
- [Configuration requise](/fr/admin/install/requirements/) — les adresses
  que le fichier doit porter.
- [Courriel sortant](/fr/admin/configure/email/) — la section `mail:` en
  détail.
- [Stockage des fichiers](/fr/admin/configure/file-storage/) — la section
  `artifact:` en détail.
- Internes sur GitHub : [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
