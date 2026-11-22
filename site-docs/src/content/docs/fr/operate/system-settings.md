---
title: Paramètres système
description: Modifiez les réglages de la plateforme sans redémarrage depuis l’espace Configurer, le fichier de configuration restant le repli.
audience: [operator, admin]
features: [PLT-02, FE-14]
sidebar:
  order: 5
verified_at: 008dd880
---

Certains réglages de la plateforme changent sans redémarrage. Un seul document
système les porte : `core.SystemSettings`. Un administrateur l’édite
depuis la page **Configurer → Plateforme → Paramètres**, le changement atteint
tous les processus en cours, et le fichier de configuration reste le repli.

## Quand l’utiliser

Éditez les paramètres système quand :

- vous changez un réglage et ne pouvez pas redémarrer le serveur,
- vous épinglez une valeur qui doit primer sur le fichier de configuration
  pour un environnement,
- vous rendez une valeur au fichier de configuration après un épinglage.

## Avant de commencer

- Vous portez un rôle autorisé à modifier `core.SystemSettings`. Par défaut,
  ce droit est réservé aux administrateurs.
- La valeur effective d’un réglage se résout dans cet ordre : le document
  des paramètres, puis `config.{env}.yml`, puis la valeur par défaut intégrée.
  Un champ effacé suit le fichier.

## Étapes

### 1. Lisez les valeurs effectives

Ouvrez **Configurer → Plateforme → Paramètres**, ou appelez la route de
lecture :

```sh
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/SystemSettings"
```

La réponse porte deux listes :

- `values` — les valeurs effectives non secrètes, indexées par chemin en
  notation pointée.
- `pinned` — les chemins que le document épingle actuellement.

La page affiche un badge « surcharge » sur chaque champ épinglé, avec
un contrôle « Rétablir le fichier ». Le rétablissement envoie un
`null` explicite, et le champ suit de nouveau le fichier.

### 2. Épinglez une valeur

Modifiez le champ dans la page des paramètres et enregistrez. La page envoie
une mise à jour partielle : seuls les champs que vous avez touchés partent.
Les épinglages que vous ne touchez pas restent en place.

Le chemin d’écriture est la route de document standard, donc le même
enregistrement fonctionne depuis un appel d’API. Le corps imbrique un niveau
d’objet par segment de chemin :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"model": "gpt-4o"}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

Une clé à plat échoue à la validation de forme. Un corps de
`{"assistant.model": "gpt-4o"}` répond `422`.

Les secrets passent par le même enregistrement. La page prépare d’abord chaque
texte en clair saisi, et l’enregistrement transporte un identifiant à usage
unique, jamais le texte en clair. Effacer un emplacement de secret rend la
valeur au fichier.

### 3. Retenez les chemins enregistrés

| Groupe | Chemins |
| --- | --- |
| Assistant | `assistant.name`, `assistant.api_endpoint`, `assistant.api_key` (secret), `assistant.model`, `assistant.system_prompt`, `assistant.max_tokens`, `assistant.temperature`, `assistant.max_history`, `assistant.auto_execute_tools` |
| Courrier | `mail.adapter`, `mail.from_address`, `mail.from_name`, `mail.smtp.host`, `mail.smtp.port`, `mail.smtp.username`, `mail.smtp.password` (secret), `mail.smtp.use_tls` |
| Artefacts | `artifact.grant_ttl_seconds`, `artifact.grant_ttl_media_seconds`, `artifact.prune_after_days`, `artifact.storage.type` (lecture seule) |
| Rétention | `mutations.retention_days`, `tombstone.content_retention_days` |
| Localisation | `localization.default_timezone`, `localization.default_language` |
| Sécurité | `iam.mfa.type`, `iam.mfa.enforcement`, `iam.auth.mode`, `iam.change_password_expiration` |

### 4. Retenez les règles d’écriture

Un enregistrement franchit trois barrières. La forme vient de la définition du
doctype, une garde singleton protège l’unique document, et un contrôle
sémantique à l’écriture vérifie chaque valeur :

- `temperature` entre 0,0 et 2,0, `max_tokens` strictement positif,
  `max_history` à 0 ou plus, `port` entre 1 et 65535.
- Les TTL des octrois et `iam.change_password_expiration` valent 1 seconde ou
  plus.
- Les fenêtres de rétention valent 0 ou plus. Une fenêtre à `0` signifie
  conserver indéfiniment.
- `mail.adapter: smtp` exige un `mail.smtp.host` non nul.
- `mail.adapter: dev` est refusé sous `APP_ENV=production`, sauf si le fichier
  pose `mail.allow_dev_adapter_in_production: true`.
- `localization.default_timezone` doit être un nom IANA chargeable.
- `iam.mfa.type` vaut `none` ou `totp` ; `iam.mfa.enforcement` vaut
  `preferred` ou `always` ; `iam.auth.mode` vaut `hybrid` ou `oidc_only`.
  `oidc_only` est refusé tant qu’aucun document de fournisseur OIDC actif
  n’existe.
- Toute valeur sur `artifact.storage.type` est refusée. L’adaptateur de
  stockage se câble une fois par processus, depuis le fichier. Un changement à

  l’exécution laisserait les octets existants dans l’ancien backend.

:::caution
Tous les réglages ne sont pas à chaud. Les plannings cron, `jobs.*` et
`hooks.*` se lient au démarrage et restent réservés au fichier. Un
enregistrement des paramètres ne peut pas les changer.
:::

## Exemple

Épinglez une courte fenêtre de rétention du contenu supprimé, voyez-la
appliquée à la prochaine passe quotidienne, puis rendez-la au fichier :

```sh
# Épingle la fenêtre à 7 jours.
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": 7}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"

# Affiche l’épinglage.
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/SystemSettings"
# "pinned" liste désormais "tombstone.content_retention_days".

# Retire l’épinglage — le champ suit de nouveau le fichier de configuration.
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": null}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

La passe de purge quotidienne lit la fenêtre au début de chaque exécution.
L’enregistrement ne demande aucun redémarrage.

## Dépannage

**Un changement du fichier de configuration ne fait rien.**

Le chemin est épinglé dans le document des paramètres. Retirez l’épinglage
dans la page des paramètres.

**Un enregistrement répond `422` avec `is not a defined field`.**

Le corps utilisait une clé à plat avec des points. Imbriquez un niveau
d’objet par segment de chemin.

**Un enregistrement répond `422` sur `iam.auth.mode`.**

`oidc_only` demande un document de fournisseur OIDC actif. Inscrivez et
activez d’abord un fournisseur — voir [SSO avec OIDC](/fr/govern/sso-oidc/).

**Un enregistrement de `mail.adapter: dev` est refusé en production.**

La barrière d’écriture reflète la barrière de démarrage. Posez la soupape du
fichier, `mail.allow_dev_adapter_in_production: true`, si l’installation doit
garder la livraison sur stdout.

**La fenêtre de rétention n’a pas encore réduit le journal.**

La passe suit son entrée cron, une fois par jour par défaut. Les lignes plus
jeunes que la fenêtre restent intactes.

## Voir aussi

- [Fichiers de configuration](/fr/operate/configuration-files/) — le palier
  fichier, sous les épinglages.
- [Rétention : ce qui est gardé, et pour combien de temps](/fr/govern/retention/) — les fenêtres que posent les épinglages de rétention.
- [Gouverner l’assistant](/fr/govern/governing-assistant/) — le rôle borne le
  flux des réglages de l’assistant.
- [Appliquer le MFA](/fr/govern/enforcing-mfa/) — ce que pilotent les clés
  `iam.mfa.*`.
- [SSO avec OIDC](/fr/govern/sso-oidc/) — ce que pilote `iam.auth.mode`.
- Internes sur GitHub : [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
