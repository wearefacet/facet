---
title: Le tableau de bord
description: Ouvrir le tableau de bord, lire ses cartes et rejoindre vos enregistrements en quelques clics.
audience: [user]
features: [FE-02]
sidebar:
  order: 2
verified_at: 49d7c7e5
---

Le tableau de bord est la page que Facet ouvre après la connexion. Il vous
salue, montre votre rôle actif, et vous donne des cartes pour accéder à chaque
domaine que vous pouvez lire. Chaque domaine a son propre tableau de bord, avec
vos vues épinglées et vos enregistrements récemment ouverts. Commencez ici
votre travail quotidien.

## Avant de commencer

- **Un compte.** Il vous faut un compte Facet. Voir
  [Connexion, MFA et mot de passe](/fr/workspace/sign-in-mfa/).
- **Les bonnes cartes.** Votre rôle décide des cartes que vous voyez. Un
  domaine hors de vos droits n’apparaît pas. Voir
  [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).

## La page d’accueil

Ouvrez `https://facet.localhost:3443/` (ou l’adresse de votre instance) et
connectez-vous. La page d’accueil montre, de haut en bas :

| Partie | Ce qu’elle montre |
| --- | --- |
| Salutation | Votre prénom, et le rôle sous lequel vous travaillez, par exemple Administrateur. |
| Surfaces clés | Des liens vers Builder, Domaines, Paramètres et Applications. Un lien que votre rôle n’autorise pas reste caché. |
| Applications | Une carte par application que votre organisation fait tourner ; la section se cache quand il n’y en a pas. Une carte que votre rôle ne peut pas ouvrir affiche une mention de verrou. |
| Brouillons en cours | Les brouillons de domaines sur lesquels vous ou votre équipe travaillez, avec une coche quand ils sont prêts à publier. |
| Domaines | Une carte par domaine que vous pouvez lire, par exemple crm ou hr. |

Sélectionnez une carte de domaine pour ouvrir son tableau de bord.

:::note
Quand votre rôle peut créer des doctypes, la section Domaines affiche un petit
bouton plus sur chaque carte de domaine. Il ouvre la boîte de dialogue
« Nouveau doctype ». Brouillons et réglages de domaine vivent dans le
Builder ; voir [Construire des domaines](/fr/build/).
:::

Quand votre compte ne peut lire aucun domaine, la section Domaines affiche
plutôt une carte de premier démarrage. Elle propose « Nouveau domaine » et
« Importer un bundle ».

## Le tableau de bord du domaine

Le tableau de bord du domaine à `/{domaine}` (par exemple `/crm`) affiche :

| Section | Ce qu’elle montre |
| --- | --- |
| En-tête | Le nom du domaine, et le décompte de ses doctypes et de ses enregistrements. |
| Vues épinglées | Une carte par vue que vous avez épinglée, avec le type de vue (tableau, kanban ou calendrier) et le nombre d’enregistrements. Sélectionnez une carte pour ouvrir la liste. |
| Consultés récemment | Des puces pour les enregistrements que vous avez ouverts en dernier dans ce domaine, du plus récent au plus ancien. |
| Doctypes | Chaque doctype avec son nombre d’enregistrements, et des liens vers ses vues enregistrées. |

:::tip
Épinglez les vues que vous utilisez chaque jour. Ouvrez une vue sur une page de
liste et sélectionnez « Épingler la vue actuelle » à côté des onglets. La vue
apparaît alors sur ce tableau de bord. Voir
[Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/).
:::

## Étapes

### 1. Ouvrez votre liste quotidienne

Connectez-vous, sélectionnez une carte de domaine, puis une vue épinglée. La
liste s’ouvre avec cette vue active. C’est le chemin le plus court vers votre
travail quotidien.

### 2. Revenez à un enregistrement déjà travaillé

Ouvrez le tableau de bord du domaine et sélectionnez une puce sous
« Consultés récemment ». L’enregistrement s’ouvre. Chaque puce montre le nom de
l’enregistrement et l’ancienneté de votre dernière ouverture, par exemple
`il y a 10m` ou `hier`.

### 3. Trouvez un doctype

Ouvrez le tableau de bord du domaine et lisez la liste des doctypes. Elle
montre chaque doctype avec son nombre d’enregistrements. Un doctype de plus de
1000 enregistrements affiche `1000+`.

1. Sélectionnez le nom du type pour ouvrir sa liste.
2. Ou sélectionnez une vue enregistrée en dessous.

Au-del à de six doctypes, la liste montre les six premiers et un bouton
« Afficher … de plus ». Sélectionnez-le pour voir le reste.

## Exemple

Un chemin quotidien dans un domaine commercial :

```
/                     sélectionnez la carte crm
/crm                  sélectionnez la vue épinglée Pipeline
/crm/Deal?view=pipeline   la liste kanban s’ouvre
```

## Dépannage

### Une carte de domaine manque

Votre rôle ne lit pas ce domaine. Demandez à votre administrateur. Un brouillon
sur lequel un collègue travaille encore reste dehors aussi ; un domaine
publié s’affiche toujours.

### La section Vues épinglées est vide

Vous n’avez encore épinglé aucune vue. La section dit : « Épinglez une
vue et elle apparaîtra ici. »

1. Ouvrez une liste.
2. Sélectionnez une vue.
3. Sélectionnez « Épingler la vue actuelle ».

### La section Consultés récemment est vide

Vous n’avez encore ouvert aucun enregistrement dans ce domaine, ou votre
navigateur a effacé son stockage. La section dit : « Les documents que
vous ouvrez apparaîtront ici. »

### Un décompte affiche un tiret au lieu d’un nombre

Le décompte n’est pas encore chargé, ou votre rôle ne peut pas compter ce
doctype. Le nombre se remplit quand les données arrivent.

## Voir aussi

- [Connexion, MFA et mot de passe](/fr/workspace/sign-in-mfa/) — comment
  rejoindre le tableau de bord.
- [Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/) —
  ce qu’ouvre une vue épinglée.
- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  ce qu’ouvre une puce récente.
- [Domaines et isolation](/fr/concepts/domains-and-isolation/) — pourquoi
  chaque domaine a son tableau de bord.
- [Brouillon → publication](/fr/concepts/draft-publish/) — ce que montre la
  section des brouillons.
- [Raccourcis clavier](/fr/workspace/keyboard-shortcuts/) — vous déplacer sans
  la souris.
