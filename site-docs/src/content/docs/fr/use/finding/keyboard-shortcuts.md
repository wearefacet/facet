---
type: reference
title: Raccourcis clavier
description: "Toutes les combinaisons de touches : naviguer dans les listes, ouvrir et enregistrer, ouvrir la palette, l’assistant et la feuille de raccourcis."
audience: [user]
features: [FE-08]
sidebar:
  order: 3
verified_at: eee55a2
---

L’espace de travail répond au clavier aussi bien qu’à la souris. Les tables
suivantes listent chaque raccourci et l’endroit où il agit. Dans les tables,
`Ctrl` désigne `Ctrl` sur Windows et Linux, et `Cmd` sur un Mac.

Appuyez sur `?` — hors d’un champ de texte — pour voir les raccourcis qui
fonctionnent en ce moment. La feuille ne liste que les raccourcis de la page
où vous êtes. Elle est donc plus courte que cette référence.

## Partout dans l’espace de travail

| Raccourci | Action |
|---|---|
| `Ctrl+K` | Ouvrir ou fermer la palette de commandes |
| `Ctrl+I` | Ouvrir ou fermer l’assistant |
| `Ctrl+\` | Replier ou déplier la barre latérale |
| `?` | Afficher la feuille des raccourcis clavier |
| `Esc` | Réduire la fenêtre de l’assistant, quand vous y tapez |

## Sur une liste

| Raccourci | Action |
|---|---|
| `C` | Démarrer un nouvel enregistrement de ce type d’enregistrement |
| `j` ou `↓` | Surligner la ligne suivante |
| `k` ou `↑` | Surligner la ligne précédente |
| `Enter` | Ouvrir l’enregistrement surligné dans l’aperçu |
| `Enter` | Avec l’aperçu ouvert, ouvrir la page complète de l’enregistrement |
| `Esc` | Effacer le surlignage de la ligne |
| `/` | Aller à la zone de recherche de la liste, quand la liste en a une |

## Dans un enregistrement

| Raccourci | Action |
|---|---|
| `E` | Modifier l’enregistrement |
| `Ctrl+S` | Enregistrer le formulaire |
| `Ctrl+Enter` | Enregistrer le formulaire |

## Les règles qui régissent ces raccourcis

Les raccourcis de lettres suivent les mêmes droits que les boutons : `C`
n’apparaît que là où votre rôle peut créer des enregistrements, `E` que là où
il peut les modifier. Rien de caché, rien en plus.

Les lettres et `?` ne se déclenchent pas pendant la saisie — seules les
combinaisons avec `Ctrl` le font. Voilà pourquoi `Ctrl+K` fonctionne depuis
une zone de recherche, mais pas `j`. Dans une boîte de dialogue ouverte, la
boîte de dialogue possède le clavier, et les raccourcis de l’espace de
travail s’effacent.

Les combinaisons que le navigateur possède déjà — `Ctrl+C` pour copier,
`Ctrl+T` pour un nouvel onglet — restent au navigateur. Facet ne les prend
pas.

## Dépannage

### Un raccourci lettre ne fait rien

Le focus se trouve dans un champ de texte. Sélectionnez d’abord hors du
champ — les lettres ne se déclenchent jamais pendant la saisie.

### Un raccourci ne fait rien quand une boîte de dialogue est ouverte

Une boîte de dialogue ouverte possède le clavier. Fermez d’abord la boîte de
dialogue.

### `C` ou `E` ne fait rien

Votre rôle n’autorise ni création ni modification sur ce type
d’enregistrement. Le raccourci suit les mêmes droits que les boutons — si le
bouton est absent, la touche reste silencieuse. Demandez à votre
administrateur ; voir
[Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

### Une combinaison du navigateur reste native

`Ctrl+C`, `Ctrl+T` et leurs voisines appartiennent au navigateur ou au
système d’exploitation. Facet ne les utilise pas et les laisse tranquilles.

## Voir aussi

- [Recherche et palette de commandes](/fr/use/finding/search/) — ce qu’ouvre
  `Ctrl+K`.
- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  les listes sur lesquelles ces raccourcis de ligne fonctionnent.
- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) —
  modifier avec `E`, enregistrer avec `Ctrl+S`.
- [Utiliser l’assistant](/fr/use/assistant/) — la fenêtre qu’ouvre `Ctrl+I`.
