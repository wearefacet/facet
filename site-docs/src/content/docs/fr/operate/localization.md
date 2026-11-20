---
title: Localisation
description: Réglez le fuseau horaire et la langue par défaut de l’instance, et orientez chaque compte vers ses propres réglages.
audience: [operator, user]
features: [FE-20]
sidebar:
  order: 17
verified_at: 008dd880
---

Facet affiche les dates et les heures ainsi que les textes de l’interface
compte par compte. Chaque compte règle son fuseau horaire et sa langue sur la
page Paramètres de l’application. La valeur par défaut de l’instance comble le
cas des comptes qui suivent le serveur. Vous fixez cette valeur par défaut
dans le fichier de configuration ou sur la page des paramètres de la
plateforme.

## Quand l’utiliser

Réglez la localisation quand :

- Vous fixez le fuseau horaire ou la langue par défaut de toute l’installation.
- Vous expliquez pourquoi deux comptes voient des heures différentes pour un
  même document.
- Vous orientez les utilisateurs vers leurs propres préférences.

## Avant de commencer

- Les langues autorisées sont `en` et `fr`.
- Le fuseau horaire par défaut doit être un nom IANA chargeable, par exemple
  `Europe/Paris`.
- Les deux clés sont à chaudà : une surcharge à l’exécution s’applique
  sans redémarrage, alors qu’un changement dans le fichier de configuration en
  demande un.

## Étapes

### 1. Fixer les valeurs par défaut dans le fichier de configuration

```yaml
localization:
  default_timezone: UTC
  default_language: en
```

La section est facultative. Les valeurs par défaut sont `UTC` et `en`. Le
chargement valide les deuxà : un fuseau horaire que le runtime ne peut pas
charger, ou une langue hors de la liste autorisée, fait échouer le démarrage.

### 2. Surcharger les valeurs par défaut à l’exécution

Ouvrez **Configurer → Plateforme → Paramètres** et réglez
`localization.default_timezone` ou `localization.default_language`.
L’enregistrement atteint tous les processus en cours, donc aucun redémarrage
n’est nécessaire. Retirez la surcharge pour suivre à nouveau le fichier.

Le même enregistrement passe par l’API. Le corps imbrique un niveau d’objet
par segment de chemin :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris"}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

### 3. Comprendre la chaîne

Chaque clé de compte se résout dans cet ordreà :

1. La valeur propre du compte, réglée sur la page Paramètres de l’application.
2. La valeur par défaut du serveurà : la surcharge des paramètres, puis le
   fichier de configuration, puis la valeur par défaut intégrée.
3. La valeur statiqueà : `UTC` pour le fuseau horaire, `en` pour la langue.

La correspondance est `core.timezone` → `localization.default_timezone`, et
`core.language` → `localization.default_language`. La valeur propre d’un
compte l’emporte toujours. Une valeur de compte effacée suit le serveur.

### 4. Orienter les utilisateurs vers leurs propres réglages

Les utilisateurs ouvrent la page **Paramètres** de l’application :

- **Fuseau horaire** propose « Automatique », qui suit le navigateur,
  et « Valeur par défaut du serveur », qui efface la valeur du compte
  et suit la valeur par défaut de votre instance.
- **Langue** propose `en` et `fr`, avec la même option « Valeur par
  défaut du serveur ».

  L’enregistrement est immédiat, un champ à la fois. Voir
  [Paramètres, sessions et clés API](/fr/workspace/settings-sessions-api-keys/)
  pour le point de vue de l’utilisateur.

### 5. Savoir ce qui en dépend

- Les dates et heures s’affichent dans le fuseau horaire d’affichage du
  compteà : tableaux, vues d’audit, sélecteurs de date et heure, et exports
  CSV.
- Les valeurs `date` et `dateperiod` sont des dates de calendrier. Elles
  s’affichent telles qu’écrites et ne passent jamais par une conversion de
  fuseau horaire.
- Le cookie de langue d’interface reflète la langue du compteà : le choix
  survit aux rechargements et aux connexions.

## Exemple

Réglez les valeurs par défaut de l’instance pour un bureau à Paris, puis
vérifiez les valeurs effectivesà :

```yaml
localization:
  default_timezone: Europe/Paris
  default_language: en
```

Ou surchargez les mêmes valeurs à l’exécution, sans redémarrageà :

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris", "default_language": "fr"}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

Les comptes qui ont choisi leurs propres valeurs les conservent. Les comptes
sur « Valeur par défaut du serveur » basculent immédiatement.

## Dépannage

**Le démarrage échoue et nomme `localization.default_timezone`.**

La valeur n’est pas un nom IANA chargeable. Utilisez un nom que le runtime
peut charger, par exemple `Europe/Paris`.

**Un enregistrement répond `422` sur la langue.**

La valeur est hors de la liste autorisée. Utilisez `en` ou `fr`.

**Un utilisateur voit des heures dans le mauvais fuseau.**

La valeur du compte l’emporte sur la valeur par défaut du serveur.
L’utilisateur choisit le bon fuseau sur la page Paramètres, ou sélectionne
« Valeur par défaut du serveur » pour suivre l’instance.
« Automatique » suit le navigateur, pas le serveur.

**Un changement de surcharge n’a pas atteint un utilisateur.**

Cet utilisateur porte une valeur de compte pour cette clé. La valeur par
défaut du serveur ne comble qu’une valeur vide.

## Voir aussi

- [Paramètres, sessions et clés API](/fr/workspace/settings-sessions-api-keys/)
  — les préférences au niveau du compte que les utilisateurs changent.
- [Paramètres système](/fr/operate/system-settings/) — le palier à l’exécution
  et le fonctionnement des surcharges.
- [Fichiers de configuration](/fr/operate/configuration-files/) — le fichier
  qui porte les valeurs par défaut.
- Internes sur GitHubà :
  [settings.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/settings.md),
  [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
