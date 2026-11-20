---
title: Recherche et palette de commandes
description: Trouver des enregistrements avec la recherche, et rejoindre n’importe quelle page ou commande depuis la palette.
audience: [user]
features: [FE-07, DOC-06]
sidebar:
  order: 7
verified_at: 49d7c7e5
---

La palette de commandes ouvre des pages, des enregistrements et des commandes
depuis une seule zone. Appuyez sur `Ctrl+K`, ou sélectionnez la zone de
recherche dans la barre supérieure. La palette cherche aussi dans vos
enregistrements. Cette page montre les deux usages.

## La palette de commandes

### 1. Ouvrez la palette

Appuyez sur `Ctrl+K`. Sur macOS, appuyez sur `Cmd+K`. Vous pouvez aussi
sélectionner la zone de recherche dans la barre supérieure.

La palette montre jusqu’à quatre groupesà : **Naviguer**, **Récents**,
**Enregistrements** et **Actions**. Un groupe sans entrée reste caché.

:::tip
Appuyez à nouveau sur `Ctrl+K` pour fermer la palette. `Échap` la ferme aussi.
:::

:::note
Dans Configurer, la palette liste les sections de Configurer et un chemin de
retour vers l’espace de travail. Le mode Builder n’a pas de zone de recherche
dans la barre supérieure, mais `Ctrl+K` y ouvre quand même la palette.
:::

### 2. Sautez à une page

Tapez le nom d’un domaine ou d’un doctype. Le groupe **Naviguer** liste les
correspondances. Sélectionnez-en une pour ouvrir la page.

Le groupe **Récents** liste les enregistrements que vous avez ouverts
récemment dans le domaine courant.

### 3. Cherchez des enregistrements

Tapez au moins deux caractères, par exemple `inv`. Le groupe
**Enregistrements** liste les enregistrements correspondants. Chaque résultat
montre le nom de l’enregistrement. Sélectionnez un résultat pour ouvrir
l’enregistrement.

Certains enregistrements sont des parties d’un enregistrement parent. Une
correspondance sur une partie montre le nom du parent, avec la partie qui a
correspondu en dessous. La sélection ouvre l’enregistrement parent.

:::tip
Sélectionnez **Rechercher « … » dans tous les domaines** pour
élargir la recherche. La palette marque alors le périmètre élargi avec une
pastille **Tous les domaines**. Sélectionnez la pastille pour chercher à

nouveau dans le domaine courant.
:::

### 4. Lancez une commande

Le groupe **Actions** liste des commandes. Exemplesà : ouvrir le Builder,
ouvrir Configurer, afficher les raccourcis clavier, replier la barre latérale.
Les commandes suivent les mêmes droits que la barre latérale. Une commande que
votre rôle n’autorise pas n’apparaît pas.

Déplacez-vous avec `↑` et `↓`. Appuyez sur `Entrée` pour lancer l’élément
sélectionné.

## La recherche de documents

### 1. Tapez votre terme

La recherche démarre à deux caractères. Tapez deux lettres ou plus, par
exemple `ada`.

### 2. Lisez les résultats

La recherche correspond à une partie de mot. Le terme `ada` correspond à

« Ada Lovelace ». La recherche ignore la casse et les accents.

Les correspondances les plus proches arrivent en premier. La palette groupe
les résultats par doctype. La recherche renvoie au plus 25 enregistrements, et
au plus 5 enregistrements par doctype.

Les résultats montrent des noms d’enregistrements. Ils ne montrent pas de
valeurs de champs.

### 3. Élargissez ou resserrez le périmètre

La recherche couvre le domaine courant. Utilisez **Rechercher « … »
dans tous les domaines** pour chercher dans chaque domaine que vous pouvez
lire. Cette option est toujours présente, même quand le domaine courant n’a
aucune correspondance — c’est le chemin pour trouver un enregistrement qui
se trouve dans un autre domaine.

### Ce que la recherche lit

- Un doctype n’apparaît dans la recherche que si sa définition définit un texte
  de recherche. Le texte porte d’habitude le nom de l’enregistrement et des
  champs clés. Les auteurs de doctypes posent ce texte dans la définition du
  doctype.
- Vous ne voyez que les enregistrements que votre rôle peut lire.
- Les enregistrements supprimés n’apparaissent jamais.

La zone de recherche d’une page de liste est un filtre, pas cette recherche.
Elle resserre la liste courante. Elle correspond au texte de recherche, au nom
de l’enregistrement et à son identifiant. Voir
[Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/).

## Dépannage

### La recherche ne renvoie aucun enregistrement

1. Vérifiez le terme. La recherche demande deux caractères ou plus.
2. Vérifiez le doctype. Il ne définit peut-être aucun texte de recherche, et
   n’apparaît donc jamais ici.
3. Vérifiez vos droits. Votre rôle ne lit peut-être pas le doctype.
4. Vérifiez l’enregistrement. Il vit peut-être dans un autre domaine, ou il
   est peut-être supprimé.

La palette affiche **Aucun résultat pour « … »** quand rien ne
correspond.

### Le groupe Enregistrements manque

Tapez au moins deux caractères. Si la requête de recherche échoue, la palette
cache le groupe Enregistrements. Les autres groupes restent utilisables.

### Une commande manque dans Actions

Les commandes suivent vos droits. Dans Configurer, la palette liste les
sections de Configurer à la place des commandes de l’espace de travail.

### La barre supérieure n’a pas de zone de recherche

Le mode Builder n’en a pas. Appuyez sur `Ctrl+K`.

## Voir aussi

- [Raccourcis clavier](/fr/workspace/keyboard-shortcuts/) — chaque combinaison
  de touches, y compris `Ctrl+K`.
- [Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/) —
  la zone de recherche qui filtre une liste.
- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  ce qui s’ouvre quand vous sélectionnez un résultat.
- [Le tableau de bord](/fr/workspace/dashboard/) — montre les mêmes
  enregistrements récemment ouverts.
- [Domaines et isolation](/fr/concepts/domains-and-isolation/) — pourquoi la
  recherche démarre dans votre domaine courant.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) —
  d’où viennent les noms d’enregistrements et le texte de recherche.
