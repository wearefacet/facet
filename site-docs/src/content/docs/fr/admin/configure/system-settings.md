---
title: Paramètres système
description: Modifiez les paramètres système à l’exécution depuis l’espace Configurer, avec le fichier de configuration en repli.
type: how-to
audience: [operator, admin]
features: [PLT-02, FE-14]
sidebar:
  order: 2
verified_at: eee55a2
---

Vous devez changer le relais de courriel ou la fenêtre de rétention, et le
serveur ne peut pas redémarrer pour l’instant. Certains réglages de la
plateforme changent sans redémarrage. Ils vivent sur un seul document
système, `core.SystemSettings`. Un administrateur l’édite dans la page
**Configurer → Plateforme → Paramètres**, et le changement atteint chaque
processus en cours. Le fichier de configuration reste le repli.

## Quand l’utiliser

Éditez les paramètres système quand :

- Vous changez un réglage et ne pouvez pas redémarrer le serveur.
- Vous épinglez une valeur au-dessus du fichier de configuration pour un
  environnement.
- Vous rendez une valeur au fichier après un épinglage.

## Avant de commencer

- Vous détenez un rôle qui peut mettre à jour `core.SystemSettings`. Le
  défaut est réservé aux administrateurs : les rôles editor et viewer
  retranchent le doctype de leurs attributions de lecture qui couvrent
  tout.
- La valeur effective d’un réglage se résout dans cet ordre : le document
  de paramètres, puis `config.{env}.yml`, puis la valeur par défaut
  intégrée. Un champ effacé suit le fichier.
- La page générée
  [Clés des paramètres système](/fr/reference/system-settings-keys/) liste
  chaque chemin enregistré avec son genre et sa valeur par défaut.

## Étapes

### 1. Lisez les valeurs effectives

Ouvrez **Configurer → Plateforme → Paramètres**, ou appelez la route de
lecture :

```sh
curl -s -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/SystemSettings"
```

La réponse porte deux listes :

- `values` — les valeurs effectives non secrètes, indexées par chemin
  pointé. Les deux chemins secrets (`assistant.api_key`,
  `mail.smtp.password`) ne montent jamais dans la réponse.
- `pinned` — les chemins que le document épingle actuellement.

La page affiche un badge de surcharge sur chaque champ épinglé, avec un
contrôle de retour au fichier. La réinitialisation envoie un `null`
explicite, et le champ suit à nouveau le fichier.

### 2. Épinglez une valeur

Éditez le champ sur la page des paramètres et enregistrez. La page envoie
une mise à jour creuse : seulement les champs que vous avez touchés. Les
épinglages intacts restent épinglés.

Le chemin d’écriture est la route de document standard, donc le même
enregistrement fonctionne depuis un appel API. Le corps imbrique un niveau
d’objet par segment de chemin :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"model": "gpt-4o"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

Une clé plate échoue à la validation de forme. Un corps de
`{"assistant.model": "gpt-4o"}` répond `422`.

Les secrets voyagent dans le même enregistrement. La page met d’abord de
côté chaque texte en clair tapé, et l’enregistrement porte un jeton à usage
unique, jamais le texte en clair. Effacer un emplacement de secret rend la
valeur au fichier.

### 3. Connaissez les chemins enregistrés

| Groupe | Chemins |
| --- | --- |
| Assistant | `assistant.name`, `assistant.api_endpoint`, `assistant.api_key` (secret), `assistant.model`, `assistant.system_prompt`, `assistant.max_tokens`, `assistant.temperature`, `assistant.max_history`, `assistant.auto_execute_tools` |
| Courriel | `mail.adapter`, `mail.from_address`, `mail.from_name`, `mail.smtp.host`, `mail.smtp.port`, `mail.smtp.username`, `mail.smtp.password` (secret), `mail.smtp.use_tls` |
| Artefacts | `artifact.grant_ttl_seconds`, `artifact.grant_ttl_media_seconds`, `artifact.grant_prune_days`, `artifact.prune_after_days`, `artifact.storage.type` (read-only) |
| Rétention | `mutations.retention_days`, `tombstone.content_retention_days` |
| Localisation | `localization.default_timezone`, `localization.default_language` |
| Politique IAM | `iam.mfa.type`, `iam.mfa.enforcement`, `iam.auth.mode`, `iam.change_password_expiration`, `iam.oidc.provision_roles` |

Deux chemins méritent une note :

- `iam.change_password_expiration` est la durée de vie de chaque lien
  d’identifiant : les réinitialisations de mot de passe, les liens
  d’invitation et le jeton de changement du premier identifiant. Une clé,
  trois liens.
- `iam.oidc.provision_roles` est le socle à l’échelle de l’instance pour
  les comptes que la connexion fédérée provisionne. Un document de
  fournisseur avec son propre `default_role` surpasse tout le socle pour
  ce fournisseur.

### 4. Connaissez les règles d’écriture

Un enregistrement passe trois contrôles. La forme vient de la définition du
doctype. Des gardes de singleton protègent l’unique document. Et un
contrôle d’écriture sémantique vérifie chaque valeur :

- `temperature` entre 0,0 et 2,0, `max_tokens` au-dessus de 0,
  `max_history` à 0 ou plus, `port` entre 1 et 65535.
- `assistant.name` ne doit pas être vide et a une limite de longueur — il
  se rend dans un espace restreint sur chaque surface de l’assistant.
- Les TTL des octrois et `iam.change_password_expiration` valent 1 seconde
  ou plus.
- Les fenêtres de rétention valent 0 ou plus. Une fenêtre de `0` signifie
  conserver pour toujours.
- `mail.adapter: smtp` exige un `mail.smtp.host` non null.
- `mail.adapter: dev` est refusé sous `APP_ENV=production`, sauf si le
  fichier définit `mail.allow_dev_adapter_in_production: true`.
- `localization.default_timezone` doit être `auto` ou un nom IANA
  chargeable ; `localization.default_language` doit être `en` ou `fr`.
- `iam.mfa.type` vaut `none` ou `totp` ; `iam.mfa.enforcement` vaut
  `preferred` ou `always` ; `iam.auth.mode` vaut `hybrid` ou `oidc_only`.
  `oidc_only` est refusé tant qu’aucun document de fournisseur OIDC activé
  n’existe — il verrouillerait chaque chemin de connexion d’un coup.
- Chaque entrée de `iam.oidc.provision_roles` doit nommer un document de
  rôle réel, et la liste ne doit pas répéter un rôle.
- Toute valeur sur `artifact.storage.type` est refusée. L’adaptateur de
  stockage se câble une fois par processus depuis le fichier. Un
  basculement à l’exécution abandonnerait les octets existants dans
  l’ancien backend.

Deux actions de test se trouvent à côté des groupes qu’elles testent. Les
deux exigent le même droit de mise à jour qu’un enregistrement :

- **Envoyer un courriel de test** livre une sonde par le connecteur
  enregistré — voir [Courriel sortant](/fr/admin/configure/email/).
- **Envoyer une requête de test** exécute une complétion bloquante et non
  en flux à travers les réglages de l’assistant enregistrés.

:::caution
Tous les réglages ne sont pas chauds. Les plannings cron, `jobs.*` et
`hooks.*` prennent effet au démarrage et restent propres au fichier. Un
enregistrement de paramètres ne peut pas les changer.
:::

## Exemple

Épinglez une courte fenêtre de contenu supprimé, constatez son application
à la prochaine passe quotidienne, puis rendez-la au fichier :

```sh
# Épingle la fenêtre à 7 jours.
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": 7}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"

# Montre l'épinglage.
curl -s -H "Authorization: Bearer $(facet-cli apikey)" \
  "https://facet.localhost:3443/Api/SystemSettings"
# "pinned" liste maintenant "tombstone.content_retention_days".

# Réinitialise l'épinglage — le champ suit à nouveau le fichier de configuration.
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": null}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

La passe quotidienne de purge lit la fenêtre au début de chaque exécution.
L’enregistrement n’exige aucun redémarrage.

## Dépannage

**Une modification du fichier de configuration ne fait rien.**

Le chemin est épinglé dans le document de paramètres. Effacez l’épinglage
sur la page des paramètres.

**Un enregistrement répond `422` avec `is not a defined field`.**

Le corps a utilisé une clé plate pointée. Imbriquez un niveau d’objet par
segment de chemin.

**Un enregistrement répond `422` sur `iam.auth.mode`.**

`oidc_only` exige un document de fournisseur OIDC activé. Enregistrez et
activez d’abord un fournisseur — voir
[Connexion fédérée (OIDC)](/fr/admin/people/sso/).

**Un enregistrement de `mail.adapter: dev` est refusé en production.**

Le contrôle d’écriture reflète le contrôle de démarrage. Définissez
l’échappatoire du fichier `mail.allow_dev_adapter_in_production: true` si
l’installation doit garder la livraison stdout.

**La fenêtre de rétention n’a pas encore réduit le journal.**

La passe s’exécute à son entrée cron, une fois par jour par défaut. Les
lignes plus jeunes que la fenêtre restent intactes.

## Voir aussi

- [Fichiers de configuration](/fr/admin/configure/configuration-files/) —
  l’étage du fichier sous les épinglages.
- [Clés des paramètres système](/fr/reference/system-settings-keys/) —
  chaque chemin, genre et valeur par défaut, générés depuis le registre.
- [Rétention](/fr/admin/history/retention/) — les fenêtres que les
  épinglages de rétention règlent.
- [Gouverner l’assistant](/fr/admin/assistant/govern/) — les budgets de
  rôle que les réglages de l’assistant alimentent.
- [Exiger le MFA](/fr/admin/people/mfa/) — ce que `iam.mfa.*` pilote.
- [Connexion fédérée (OIDC)](/fr/admin/people/sso/) — ce que
  `iam.auth.mode` pilote.
- Internes sur GitHub : [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
