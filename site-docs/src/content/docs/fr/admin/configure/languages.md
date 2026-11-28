---
title: Langues
description: Réglez le fuseau horaire et la langue par défaut de l’instance, et orientez chaque compte vers ses propres réglages.
type: how-to
audience: [operator, user]
features: [FE-20]
sidebar:
  order: 6
verified_at: eee55a2
---

Deux personnes ont ouvert la même réservation et lu des heures différentes.
Facet affiche les dates et heures et les textes de l’interface compte par
compte. Chaque compte règle son propre fuseau horaire et sa propre langue
sur la page Paramètres de l’application. La valeur par défaut de l’instance
comble le cas des comptes qui suivent le serveur. Vous fixez cette valeur
par défaut dans le fichier de configuration ou sur la page des paramètres
de la plateforme.

## Quand l’utiliser

Réglez la localisation quand :

- Vous fixez le fuseau horaire ou la langue par défaut de toute
  l’installation.
- Vous expliquez pourquoi deux comptes voient des heures différentes pour
  un même document.
- Vous orientez les utilisateurs vers leurs propres préférences.

## Avant de commencer

- Les langues autorisées sont `en` et `fr`.
- Le fuseau horaire par défaut doit être `auto` (chaque compte suit son
  navigateur) ou un nom IANA chargeable, par exemple `Europe/Paris`.
- Les deux clés sont chaudes : un épinglage à l’exécution s’applique sans
  redémarrage, alors qu’une modification du fichier de configuration en
  exige un.

## Étapes

### 1. Fixez les valeurs par défaut dans le fichier de configuration

```yaml
localization:
  default_timezone: UTC
  default_language: en
```

La section est facultative. Les valeurs par défaut intégrées sont `auto` et
`en` — sans section, chaque compte qui suit le serveur voit les heures dans
le fuseau de son propre navigateur. Les exemples de configuration dev et
production livrés fixent plutôt `UTC`, donc une installation en conteneur
neuve affiche l’UTC jusqu’à ce qu’un compte choisisse son propre fuseau. Le
chargement valide les deux : un fuseau horaire que le runtime ne peut pas
charger, ou une langue hors de la liste autorisée, fait échouer le
démarrage.

### 2. Épinglez les valeurs par défaut à l’exécution

Ouvrez **Configurer → Plateforme → Paramètres** et réglez
`localization.default_timezone` ou `localization.default_language`.
L’enregistrement atteint chaque processus en cours, donc aucun redémarrage
n’est nécessaire. Effacez l’épinglage pour suivre à nouveau le fichier.

Le même enregistrement passe par l’API. Le corps imbrique un niveau
d’objet par segment de chemin :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

### 3. Comprenez la chaîne

Chaque clé de compte se résout dans cet ordre :

1. La ligne propre du compte, réglée sur la page Paramètres de
   l’application.
2. La valeur par défaut du serveur : l’épinglage des paramètres, puis le
   fichier de configuration, puis la valeur par défaut intégrée.
3. La valeur statique : `auto` pour le fuseau horaire, `en` pour la
   langue.

La correspondance va de `core.timezone` vers `localization.default_timezone`,
et de `core.language` vers `localization.default_language`. Une ligne de
compte l’emporte toujours. Une ligne de compte effacée suit le serveur.

### 4. Orientez les utilisateurs vers leurs propres réglages

Les utilisateurs ouvrent la page **Paramètres** de l’application :

- **Fuseau horaire** propose `Automatique ({zone})`, qui suit le
  navigateur, et `Valeur par défaut du serveur ({value})`, qui efface la
  ligne du compte et suit la valeur par défaut de votre instance.
- **Langue** propose English et Français, avec la même option
  `Valeur par défaut du serveur`.

Les enregistrements sont immédiats, un champ à la fois. Voir
[Vos paramètres et clés API](/fr/use/account/) pour la vue utilisateur.

### 5. Sachez ce qui suit ces réglages

- Les dates et heures se rendent dans le fuseau horaire d’affichage du
  compte, dans les tables, les vues d’audit, les sélecteurs de date-heure
  et les exports CSV.
- Les valeurs `date` et `dateperiod` sont des dates de calendrier. Elles se
  rendent telles qu’écrites et ne passent jamais par une conversion de
  fuseau horaire.
- Le cookie de langue d’interface reflète la langue du compte ; le choix
  survit aux rechargements et aux connexions.

## Exemple

Fixez les valeurs par défaut de l’instance pour un bureau à Paris, puis
vérifiez les valeurs effectives :

```yaml
localization:
  default_timezone: Europe/Paris
  default_language: en
```

Ou épinglez les mêmes valeurs à l’exécution, sans redémarrage :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris", "default_language": "fr"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

Les comptes qui ont choisi leurs propres valeurs les conservent. Les
comptes sur `Valeur par défaut du serveur` basculent aussitôt.

## Dépannage

**Le démarrage échoue et nomme `localization.default_timezone`.**

La valeur n’est ni `auto` ni un nom IANA chargeable. Utilisez `auto`, ou un
nom que le runtime peut charger, par exemple `Europe/Paris`.

**Un enregistrement répond `422` sur la langue.**

La valeur est hors de la liste autorisée. Utilisez `en` ou `fr`.

**Un utilisateur voit des heures dans le mauvais fuseau.**

La ligne du compte l’emporte sur la valeur par défaut du serveur.
L’utilisateur choisit le bon fuseau sur la page Paramètres, ou sélectionne
`Valeur par défaut du serveur` pour suivre l’instance. `Automatique` suit
le navigateur, pas le serveur.

**Un changement d’épinglage n’a pas atteint un utilisateur.**

Cet utilisateur détient une ligne de compte pour la clé. La valeur par
défaut du serveur ne remplit qu’une ligne vide.

## Voir aussi

- [Vos paramètres et clés API](/fr/use/account/) — les préférences au
  niveau du compte que les utilisateurs changent.
- [Paramètres système](/fr/admin/configure/system-settings/) — l’étage
  d’exécution et le fonctionnement des épinglages.
- [Fichiers de configuration](/fr/admin/configure/configuration-files/) —
  le fichier où vivent les valeurs par défaut.
- Internes sur GitHub : [settings.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/settings.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
