---
type: how-to
title: Recherche et palette de commandes
description: Rejoignez toute page ou tout enregistrement avec la palette de commandes, et cherchez dans un domaine ou dans tous ceux que vous pouvez lire.
audience: [user]
features: [FE-07, DOC-06]
sidebar:
  order: 2
verified_at: eee55a2
---

Vous vous souvenez d’un bout de nom — un client, une tente, une réservation —
et vous voulez l’enregistrement, pas le chemin pour y arriver. La **palette
de commandes** sert à cela : une seule zone qui ouvre des pages, trouve des
enregistrements et lance des commandes. Appuyez sur `Ctrl+K` et tapez.

## Avant de commencer

- [Visite de l’espace de travail](/fr/use/first-day/) — la disposition depuis
  laquelle cette page navigue.

![The search box in the top bar — the same box the Ctrl+K shortcut opens.](/screens/use/finding-search-1.png)

## La palette de commandes

Appuyez sur `Ctrl+K` (`Cmd+K` sur un Mac), ou sélectionnez la zone de
recherche dans la barre supérieure. La palette s’ouvre avec au plus quatre
groupes :

| Groupe | Ce qu’il contient |
|---|---|
| **Naviguer** | Domaines et types d’enregistrements — sélectionnez-en un pour ouvrir sa liste |
| **Récents** | Les enregistrements que vous avez ouverts récemment dans ce domaine |
| **Enregistrements** | Les enregistrements qui correspondent à ce que vous tapez |
| **Actions** | Des commandes, comme ouvrir l’assistant ou replier la barre latérale |

Un groupe sans rien à afficher reste caché. Déplacez-vous avec `↑` et `↓`,
exécutez avec `Enter`, fermez avec `Esc` — appuyer à nouveau sur `Ctrl+K`
ferme aussi la palette.

Dans **Configurer**, la palette liste les pages de Configurer et un chemin de
retour vers l’espace de travail. Le Builder n’a pas de zone de recherche dans
la barre supérieure, mais `Ctrl+K` y ouvre quand même la palette.

## Chercher des enregistrements

Tapez au moins deux caractères. Le groupe **Enregistrements** liste les
correspondances, groupées par type d’enregistrement, les plus proches
d’abord :

- La recherche porte sur une partie de mot : `vire` trouve *Château de
  Vireloup*.
- La casse et les accents ne comptent pas : `chateau` trouve le même
  enregistrement.
- Les résultats montrent des noms d’enregistrements, pas des valeurs de
  champs.
- La recherche renvoie au plus 25 enregistrements, dont au plus 5 d’un même
  type d’enregistrement. Un terme trop courant réclame un mot plus long pour
  resserrer les résultats.

Certains enregistrements sont des parties d’un parent — une ligne de
réservation dans une réservation, un contact dans une société. Quand la
correspondance porte sur la partie, le résultat montre le nom du parent,
avec la partie concernée en dessous. Sa sélection ouvre l’enregistrement
parent.

## Élargir la recherche à tous les domaines

La recherche démarre dans votre domaine courant. Pour chercher partout,
sélectionnez **Rechercher « … » dans tous les domaines** au bas des
résultats. La palette marque alors le périmètre élargi avec une pastille
**Tous les domaines** ; sélectionnez la pastille pour revenir à votre
domaine.

L’option est toujours là, même quand votre domaine n’a aucune correspondance
— c’est le moyen d’atteindre un enregistrement qui se trouve dans un autre
domaine.

## Lancer une commande

Le groupe **Actions** liste les commandes que votre rôle autorise : les
mêmes pages et commandes que la barre latérale affiche. Une commande que
votre rôle n’autorise pas n’apparaît pas. Sélectionnez-en une pour
l’exécuter.

## Ce que la recherche trouve — et ce qu’elle ignore

La recherche lit les noms des enregistrements et le texte de recherche que
l’auteur du domaine a défini pour chaque type d’enregistrement. Ce texte
porte le nom et les champs clés — et, pour les commentaires, le texte du
commentaire. Vous cherchez dans ce texte, pas dans les champs de
l’enregistrement un par un.

La recherche ne trouve **pas** :

- Les fichiers et leur contenu — les pièces jointes restent hors de la
  recherche.
- Les enregistrements que votre rôle ne peut pas lire. La recherche suit les
  mêmes règles que vos listes : ce que vous ne pouvez pas ouvrir
  n’apparaît pas. Voir
  [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).
- Les enregistrements supprimés, pas même dans la corbeille.

La zone de recherche d’une page de liste est autre chose : elle filtre la
seule liste où vous êtes. Voir
[Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/).

## Dépannage

### La recherche ne renvoie aucun enregistrement

Parcourez cette liste :

1. Tapez au moins deux caractères.
2. Essayez un morceau plus long du nom. Un terme court peut atteindre la
   limite de 25 enregistrements avant que le vôtre n’apparaisse.
3. Vérifiez le périmètre. L’enregistrement se trouve peut-être dans un autre
   domaine — sélectionnez **Rechercher « … » dans tous les domaines**.
4. Vérifiez le type d’enregistrement. Si son auteur n’a défini aucun texte
   de recherche, il n’apparaît jamais ici.
5. Toujours rien ? L’enregistrement est peut-être supprimé, ou votre rôle ne
   l’atteint peut-être pas. Demandez à votre administrateur.

La palette affiche **Aucun résultat pour « … »** quand rien ne correspond.

### Le groupe Enregistrements manque

Tapez d’abord au moins deux caractères. Si la requête de recherche échoue,
la palette cache le groupe Enregistrements et garde les autres groupes
utilisables — rechargez la page s’il reste absent.

### Une commande manque dans Actions

Les commandes suivent votre rôle, comme la barre latérale. Si la barre
latérale n’affiche pas la page, la palette ne la propose pas non plus.

### La barre supérieure n’a pas de zone de recherche

C’est le Builder. Appuyez plutôt sur `Ctrl+K`.

## Voir aussi

- [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/) — chaque
  combinaison de touches, y compris `Ctrl+K`.
- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  la zone de recherche qui filtre une liste.
- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) —
  ce qui s’ouvre quand vous sélectionnez un résultat.
- [Le tableau de bord](/fr/use/first-day/dashboard/) — montre les mêmes
  enregistrements récemment ouverts.
- [Libellés et texte de recherche](/fr/build/model/views/names-and-search/) —
  comment l’auteur du domaine choisit ce que la recherche lit.
