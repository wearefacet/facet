---
title: Domaines, brouillons et éditeurs
description: Ouvrez un domaine de brouillon, construisez et vérifiez des doctypes avec des co-éditeurs, puis publiez la structure vers un domaine réel.
audience: [author]
features: [DOM-01, DOM-02, DOM-13, FE-13]
sidebar:
  order: 1
verified_at: fd345fe3
---

Un domaine est un secteur métier avec ses propres doctypes et ses propres
données. Vous construisez un domaine dans un **brouillon** : une zone de
travail privée dont le nom commence par `_`. Dans un brouillon, vous modifiez
les définitions librement. Quand le modèle est prêt, vous le publiez sous son
nom définitif. Facet crée alors le domaine réel et supprime le brouillon.

## Quand l’utiliser

Ouvrez un brouillon quand vous concevez un nouveau domaine, ou quand vous
modifiez un domaine réel et voulez d’abord tester. Le brouillon est aussi
l’endroit où les co-éditeurs travaillent avec vous : quiconque édite le
brouillon garde le droit d’éditer le domaine publié.

:::note
Un brouillon ne contient aucune donnée de production. Les documents que vous
créez pendant les tests sont des données que vous pouvez effacer à tout
moment. La publication ne copie que la structure — jamais les documents.
:::

## Avant de commencer

- **Le rôle éditeur.** Il vous permet d’ouvrir un brouillon. Facet vous
  enregistre comme premier éditeur de ce brouillon.
- **Des droits d’édition sur le domaine réel** pour en dériver un brouillon.
  Utilisez l’action **Modifier un existant** du Builder.
- **Un administrateur pour les co-éditeurs.** Un administrateur dresse la
  liste des co-éditeurs dans l’onglet **Éditeurs** d’un domaine. Vous ne
  pouvez pas ajouter des co-éditeurs vous-même.

## Étapes

### 1. Ouvrir un brouillon

Dans le Builder, créez un nouveau brouillon. Facet génère le nom ; il commence
toujours par `_`. Renseignez les deux champs de nom en une fois :

| Champ | Règle | Objectif |
| --- | --- | --- |
| Nom | Lettres minuscules, chiffres et tirets. Commence par une lettre. | Le nom du domaine réel que vous comptez publier. |
| Libellé | Texte libre, jusqu’à 64 caractères. | Le nom affiché dans toute l’interface. |

:::tip
Renseignez le champ **Nom** dès le départ. Facet vérifie le format à

l’enregistrement du brouillon : une faute de frappe échoue donc tout de suite,
et non au moment de la publication.
:::

### 2. Ajouter et modifier des doctypes

Créez les doctypes de votre modèle (voir
[Concevoir des doctypes](/fr/build/designing-doctypes/)). Dans un brouillon,
Facet assouplit les règles de version : vous pouvez retirer un champ, changer
un type ou sauter une version. Tous les autres contrôles de schéma restent en
vigueur, et chaque script doit compiler.

Le cache des définitions se met à jour une à deux secondes après
l’enregistrement. Retestez un changement après une courte attente, avant de le
juger.

### 3. Tester en aperçu

Ouvrez une session d’aperçu depuis le brouillon. Facet montre alors le
brouillon dans l’application réelle : vous ouvrez des pages, lancez des
actions et créez des documents, le tout dans le brouillon. Les références
inter-domaines vers des domaines réels n’affichent aucune donnée pendant
l’aperçu.

### 4. Lancer les contrôles

Ouvrez l’onglet **Vérification**. Facet liste les problèmes et les
avertissements de chaque doctype du brouillon. Un brouillon vide signale qu’il
n’y a rien à publier. Corrigez les problèmes avant de publier (voir
[Vérifier un domaine avant publication](/fr/build/checking-before-publish/)).

### 5. Publier

Ouvrez la confirmation de publication. Vous y choisissez le nom cible et le
mode :

- **Publication à neuf** — le nom cible doit être libre. Facet crée le domaine
  et copie vos doctypes.
- **Publication par-dessus** — le domaine cible existe. Pour chaque doctype
  modifié, la version de schéma doit dépasser la version réelle d’exactement
  une unité, avec une entrée de migration pour l’écart (voir
  [Faire évoluer un schéma](/fr/build/evolving-schema/)).

Facet recopie les co-éditeurs vers le domaine publié, dépose les demandes
d’attribution inter-domaines, puis supprime le brouillon. La publication
revalide le modèle : le graphe de composition doit être fermé, et le contrôle
de version de la publication par-dessus doit passer.

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

L’appel ci-dessous publie un brouillon vers un domaine neuf nommé `orders`.
Lisez la clé d’API dans la variable d’environnement `FACET_API_KEY`.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/core/Domain/_3fjqk2m8p1xz/publish" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"target_name": "orders", "overwrite": false}'
```

La réponse nomme le domaine publié et signale les demandes d’attribution et
les avertissements éventuels. `-k` ignore la vérification du certificat de
l’adresse de développement locale.

## Dépannage

### La publication refuse le nom cible

Le nom doit être en lettres minuscules, chiffres et tirets, et commencer par
une lettre. Un nom qui commence par `_` est un nom de brouillon. Corrigez le
champ **Nom** ou le nom cible, puis publiez de nouveau.

### La publication par-dessus refuse un doctype

La version réelle et votre version de brouillon diffèrent de plus d’une unité,
ou une entrée de migration manque. Augmentez la version d’un cran à la fois,
ou publiez plutôt vers un domaine neuf.

### Mon changement n’apparaît pas immédiatement

Le cache des définitions se met à jour une à deux secondes après un
enregistrement. Attendez un instant et retestez.

### Je ne peux pas supprimer le domaine réel

Supprimer un domaine est une action d’administrateur, et Facet refuse tant que
l’un de ses brouillons est ouvert. Abandonnez d’abord le brouillon.

## Voir aussi

- [Domaines de brouillon (doc d’ingénierie)](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md) — le contrat complet du brouillon et de la publication.
- [Brouillon → publication](/fr/concepts/draft-publish/) — pourquoi les brouillons existent et ce que copie la publication.
- [Concevoir des doctypes](/fr/build/designing-doctypes/) — déclarez votre premier doctype dans le brouillon.
