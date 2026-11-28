---
type: how-to
title: Brouillons, éditeurs et publication
description: Ouvrez un domaine de brouillon, construisez avec d’autres éditeurs, puis publiez la structure vers un domaine réel.
audience: [author]
features: [DOM-01, DOM-02, DOM-13, DOM-31, FE-13, FE-10]
sidebar:
  order: 1
verified_at: c34885a
---

<!-- screenshot: builder-new-domain-dialog -->
Un domaine est un secteur métier avec ses propres doctypes et ses propres
données. Vous le construisez dans un **brouillon** : une zone de travail
privée dont le nom commence par `_`. Quand le modèle est prêt, vous le
publiez sous son nom réel, et Facet crée le domaine réel.

## Quand l’utiliser

Ouvrez un brouillon quand vous concevez un nouveau domaine, ou quand vous
modifiez un domaine réel et voulez d’abord tester. D’autres éditeurs
travaillent avec vous dans le même brouillon, et toute personne qui édite
le brouillon garde le droit d’éditer le domaine publié.

:::note
Un brouillon ne contient aucune donnée de production. Les documents que
vous créez pendant vos tests sont jetables. La publication ne copie que la
structure — la seule exception est décrite dans
[Le fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/).
:::

## Avant de commencer

- **Le rôle éditeur.** Tout compte doté du
  [rôle `editor`](/fr/admin/people/roles-and-permissions/) peut ouvrir un
  brouillon ; vous en devenez le premier éditeur.
- **Votre nom dans l’onglet Éditeurs du domaine** pour dériver un domaine
  réel avec **Modifier un existant**. Un domaine réel ne liste d’abord
  aucun éditeur — pas même l’administrateur. Ouvrez
  **Configurer → Domaines**, ouvrez le domaine, ouvrez **Éditeurs**, et
  ajoutez votre compte.
- **Un administrateur pour les co-éditeurs.** Seul un administrateur peut
  changer la liste des éditeurs d’un domaine.

## Étapes

### 1. Ouvrir un brouillon

Dans le **Builder**, utilisez **Nouveau domaine** pour partir de zéro, ou
**Modifier un existant** pour dériver un domaine réel. La fenêtre comporte
deux champs de nom :

| Champ | Règle | Objet |
| --- | --- | --- |
| Libellé | Texte libre, jusqu’à 64 caractères. | Le nom que les gens voient dans l’interface. |
| ID du domaine | Lettres minuscules, chiffres et tirets ; commence par une lettre. | Le nom du domaine réel que vous comptez publier. Le brouillon lui-même garde un ID temporaire autogénéré commençant par `_`. |

:::tip
Renseignez l’**ID du domaine** tôt. Facet vérifie le format à
l’enregistrement du brouillon : une faute de frappe échoue aussitôt, et non
au moment de la publication.
:::

### 2. Ajouter et modifier des doctypes

Créez les doctypes de votre modèle (voir
[Concevoir des doctypes](/fr/build/model/data/design-doctypes/)). Dans un
brouillon, Facet assouplit les règles de version : vous pouvez retirer un
champ, changer un type, ou sauter une version. Toutes les autres
vérifications de schéma restent en vigueur, et chaque script doit compiler.

Le cache de définitions se met à jour une à deux secondes après la
sauvegarde. Retestez un changement après une courte attente avant de le
juger.

### 3. Ajouter des co-éditeurs

Un administrateur ouvre l’onglet **Éditeurs** du domaine et y liste les
comptes qui éditent le brouillon avec vous. Un éditeur ne peut pas changer
cette liste — la règle garde la chaîne d’attribution du côté des
administrateurs. Les co-éditeurs du brouillon gardent leurs droits sur le
domaine publié.

<!-- screenshot: editors-tab -->

### 4. Tester en aperçu

Ouvrez l’onglet **Aperçu**. Facet montre alors le brouillon dans
l’application réelle : vous ouvrez des pages, lancez des actions, et créez
des documents, le tout dans le brouillon. Les références inter-domaines
vers des domaines réels n’affichent aucune donnée pendant l’aperçu, et une
modification de schéma vous ramène au Builder.

<!-- screenshot: builder-preview -->

### 5. Lancer les vérifications

Ouvrez l’onglet **Vérification**. Facet liste les anomalies et les
remarques de chaque doctype du brouillon. Un brouillon vide rapporte qu’il
n’y a rien à publier. Corrigez les anomalies avant de publier — voir
[Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/).

### 6. Publier

Sélectionnez **Publier**. Dans la fenêtre, vous choisissez le nom cible et
le mode :

<!-- screenshot: publish-dialog -->

- **Publication à neuf** — le nom cible doit être libre. Facet crée le
  domaine et y copie vos doctypes.
- **Publication en écrasement** — le domaine cible existe. Facet demande
  une confirmation (**Publier par-dessus {name}**), et chaque doctype que
  vous avez modifié doit augmenter sa version de schéma d’exactement un
  cran, avec une migration pour cette étape (voir
  [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/)).

La fenêtre propose aussi **Importer les documents existants** — transporter
les documents de certains doctypes de test vers le domaine publié. Laissez
l’option désactivée, sauf si vous savez que vous voulez ces données de
test.

Facet copie les co-éditeurs vers le domaine publié, dépose les demandes
d’accès inter-domaines, et supprime le brouillon. Le rapport nomme chaque
demande et indique si les données peuvent déjà circuler.

<!-- d2
open: "Open a draft" {class: external}
edit: "Add and change doctypes"
check: "Check"
publish: "Publish"
live: "Live domain" {class: ok}

open -> edit
edit -> check
check -> edit: fix
check -> publish: ready
publish -> live
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/d7c475df-light.svg" alt="Open a draft" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/d7c475df-dark.svg" alt="Open a draft" loading="lazy" />
</div>

## Exemple

La commande ci-dessous publie un brouillon vers un domaine à neuf nommé
`orders`. L’en-tête `Authorization` porte la clé enregistrée par
`facet-cli connect` :

```sh
curl -k -X POST "$(facet-cli host)/Api/core/Domain/_3fjqk2m8p1xz/publish" \
  -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"target_name": "orders", "overwrite": false}'
```

La réponse nomme le domaine publié et rapporte les demandes d’accès et les
avertissements. `-k` saute la vérification du certificat de l’adresse
locale de développement.

## Dépannage

### La publication refuse le nom cible

Le nom doit être en lettres minuscules, chiffres et tirets, et commencer
par une lettre. Un nom qui commence par `_` est un nom de brouillon.
Corrigez le champ **ID du domaine** ou le nom cible, puis republiez.

### La publication en écrasement refuse un doctype

La version réelle et la version de votre brouillon diffèrent de plus d’un
cran, ou une entrée de migration manque. Augmentez la version un cran à la
fois, ou publiez vers un domaine à neuf.

### Je ne peux pas dériver un domaine réel

Un domaine qui a un brouillon ouvert ne dérive pas de second brouillon —
Facet répond `409`. Abandonnez ou publiez le premier brouillon, puis
dérivez à nouveau.

Si Facet répond `403` avec *« You must be an editor of domain … »*, la
liste des éditeurs du domaine ne vous nomme pas. Facet ne dérive un domaine
réel que pour un compte que le domaine liste comme éditeur, et
l’administrateur n’y fait pas exception — un domaine créé par
l’initialisation commence avec une liste vide. Ouvrez
**Configurer → Domaines**, ouvrez l’onglet **Éditeurs** du domaine, ajoutez
votre compte, puis dérivez à nouveau.

### Mon changement n’apparaît pas aussitôt

Le cache de définitions se met à jour une à deux secondes après une
sauvegarde. Attendez un instant et testez à nouveau.

### Je ne peux pas supprimer le domaine réel

La suppression d’un domaine est une action d’administrateur, et Facet
refuse tant que l’un de ses brouillons est ouvert. Abandonnez d’abord le
brouillon.

## Voir aussi

- [Le fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/)
  — le cycle de vie et les vérifications de publication, en entier.
- [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/)
  — traitez les anomalies avant de publier.
- [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/)
  — laissez le chat écrire les premiers doctypes.
- [Faire évoluer un schéma](/fr/build/model/change-a-live-domain/) — la
  barrière de version, expliquée.
- [Comment les domaines restent isolés](/fr/build/deeper/domain-isolation/)
