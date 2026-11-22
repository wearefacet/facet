---
title: Fichiers de configuration
description: Écrivez le fichier de configuration qui démarre le backend, et injectez les secrets avec la balise !env.
audience: [operator]
features: [PLT-01]
sidebar:
  order: 4
verified_at: 008dd880
---

Un fichier YAML configure tout le backend : `config.{env}.yml`. C’est la
source de vérité unique du démarrage. Les adresses de la base de données et
de Redis n’existent que dans ce fichier, qui doit donc se charger avant la
connexion à la base. Certaines clés sont à chaud : un document de
paramètres d’exécution peut les surpasser sans redémarrage, et le fichier
reste la valeur de secours.

## Quand l’utiliser

Consultez cette page quand :

- vous écrivez ou modifiez `config.production.yml` ;
- vous gardez les secrets hors du fichier YAML ;
- vous devez savoir quelles clés un redémarrage modifie, et lesquelles il
  ne touche pas.

## Avant de commencer

- vous connaissez la valeur de `APP_ENV` pour le déploiement. Elle se lit
  dans le nom du fichier : `config.production.yml` pour
  `APP_ENV=production` ;
- trois valeurs restent dans l’environnement, jamais dans le YAML :
  `DATABASE_URL`, `APP_ENV`, et `JWT_SIGNING_KEY`.

## Étapes

### 1. Placez le fichier là où le backend le cherche

Le backend ne résout qu’un seul fichier, dans cet ordre :

1. `FACET_CONFIG_FILE` — un chemin explicite. Un chemin défini mais absent
   fait échouer le démarrage. Aucun repli vers un autre fichier.
2. `config.{APP_ENV}.yml` à côté du binaire — le choix par défaut.

Si aucun fichier ne se résout, le démarrage échoue bruyamment. Le backend
ne démarre jamais avec les réglages d’un autre environnement.

### 2. Injectez les secrets avec `!env`

Marquez n’importe quel scalaire avec `!env` pour y développer une variable
d’environnement au chargement :

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
```

Règles :

- la valeur développée est toujours une chaîne de caractères ;
- une variable absente fait échouer le démarrage. L’erreur nomme la
  variable et le fichier de configuration. Aucun repli silencieux vers une
  valeur vide ;
- la balise marche partout dans le document : clés de premier niveau,
  sections imbriquées, et listes ;
- la balise est refusée dans les bundles de domaines et les définitions de
  doctypes. Le contenu importé ne peut pas lire votre environnement.

### 3. Connaissez les sections

| Section | Contenu | Remarques |
| --- | --- | --- |
| `event` | URL Redis et réglages du flux | Obligatoire. Sans elle, le démarrage échoue. |
| `artifact` | Backend de stockage des fichiers et réglages de service | Obligatoire. En son absence, `artifact.storage` fait échouer le démarrage. |
| `mail` | Adaptateur de mail sortant et SMTP | Voir [Envoi des mails](/fr/operate/email/). |
| `iam` | Durées de vie des tokens, MFA, mode d’authentification, cookies | |
| `assistant` | Connexion LLM et réglages des tours | Voir [Configurer l’assistant](/fr/operate/assistant-config/). |
| `database` | Timeout des requêtes et table de routage du cluster | Voir [Prérequis système et topologie](/fr/operate/system-requirements/). |
| `mutations` | Rétention de l’historique des modifications et fusion à l’écriture | |
| `tombstone` | Rétention du payload des documents supprimés | |
| `secrets` | Clé maîtresse et réglages du magasin de secrets | |
| `jobs` | Réglages de la file des tâches d’arrière-plan | Pris en compte au démarrage. |
| `hooks` | Ordonnanceur des hooks d’événements et de planification | Pris en compte au démarrage. |
| `lua` | Limites du bac à sable pour les scripts de doctypes | |
| `localization` | Fuseau horaire et langue par défaut de l’instance | |
| `domains` | Filtre de domaines `included` / `excluded` | N’en réglez qu’un, jamais les deux. |
| `logs` | Format et niveau des journaux | |
| `cache` | Limite d’obsolescence du cache du processus | |
| `websocket` | Réglages du pont WebSocket | |
| `webhook`, `import_export`, `sidecar`, `mcp` | Réglages des sous-systèmes facultatifs | Valeurs par défaut si absent. |
| `dev` | Observateur réservé au développement | Pas pour la production. |

Les clés de premier niveau se placent hors des sections : `host`,
`base_url`, `artifact_base_url`, `artifact_grant_secret`,
`artifact_grant_secret_previous`, `snapshot_every`, `trusted_proxies`.
`artifact_base_url` et `artifact_grant_secret` sont obligatoires. Le
démarrage échoue sans elles.

### 4. Sachez quelles clés sont à chaud

Une clé à chaud se résout, au moment de l’usage, dans cet ordre : le
document `core.SystemSettings`, puis la valeur du fichier, puis la valeur
par défaut intégrée. Un administrateur peut épingler une clé à chaud à

l’exécution — voir [Paramètres système](/fr/operate/system-settings/).

Clés à chaud : la connexion de l’assistant, les valeurs `mail.*`, les
réglages de service des artefacts, les fenêtres de rétention, les valeurs
par défaut de localisation, et les valeurs de la politique IAM.

Les clés réservées au fichier se fixent au démarrage : les planifications
cron, les réglages `jobs.*` et `hooks.*`, l’adaptateur de stockage,
`retention_overrides`, et `mail.allow_dev_adapter_in_production`.

:::tip
`trusted_proxies` nomme les proxys inverses qui font face au serveur. Une
liste vide ignore `X-Forwarded-For` sur chaque requête. Les entrées sont
des hôtes seuls, sans port. Gardez la liste exacte — chaque entrée peut
choisir l’adresse IP client que voit le serveur.
:::

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

## Dépannage

**Le démarrage échoue et nomme le chemin de configuration.**

Aucun fichier ne s’est résolu. Vérifiez `APP_ENV` et le nom du fichier, ou
définissez `FACET_CONFIG_FILE`.

**Le démarrage échoue avec une `IncludeError` qui nomme une variable.**

Une balise `!env` nomme une variable que l’environnement ne définit pas.
Définissez-la, ou retirez la balise.

**`APP_ENV=production` refuse de démarrer avec une erreur de mail.**

L’adaptateur `dev` imprime les mails sur la sortie standard, donc la
production le refuse. Réglez `mail.adapter: smtp` — voir
[Envoi des mails](/fr/operate/email/).

**Le démarrage échoue sur une erreur de domaines.**

`domains.included` et `domains.excluded` s’excluent mutuellement. N’en
réglez qu’un, jamais les deux.

**Un changement de fichier ne fait rien.**

Une valeur épinglée à l’exécution l’emporte sur le fichier. Vérifiez les
épinglages — voir [Paramètres système](/fr/operate/system-settings/).

## Voir aussi

- [Paramètres système](/fr/operate/system-settings/) — le niveau
  d’exécution au-dessus du fichier.
- [Prérequis système et topologie](/fr/operate/system-requirements/) — les
  adresses que le fichier doit porter.
- [Envoi des mails](/fr/operate/email/) — la section `mail:` en
  entier.
- [Stockage de fichiers : local ou S3](/fr/operate/file-storage/) —
  la section `artifact:` en entier.
- [Configurer l’assistant](/fr/operate/assistant-config/) — la section
  `assistant:` en entier.
- Internes sur GitHub : [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
