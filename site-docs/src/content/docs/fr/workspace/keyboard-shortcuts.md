---
title: Raccourcis clavier
description: Se déplacer dans l’espace de travail, les listes et les documents au clavier.
audience: [user]
features: [FE-08]
sidebar:
  order: 8
verified_at: 49d7c7e5
---

Ces tables listent les raccourcis clavier de l’espace de travail. Dans les
tables, une combinaison `Ctrl` signifie `Ctrl` sur Windows et Linux, et `Cmd`
sur macOS.

:::tip
Appuyez sur `?` pour voir les raccourcis qui marchent maintenant. La boîte de
dialogue liste les raccourcis de la page où vous êtes.
:::

## N’importe où dans l’espace de travail

| Raccourci | Contexte | Action |
| --- | --- | --- |
| `Ctrl+K` | Espace de travail | Ouvrir ou fermer la palette de commandes |
| `Ctrl+I` | Pages avec l’assistant | Ouvrir ou fermer la fenêtre de l’assistant |
| `Ctrl+\` | Espace de travail | Replier ou déplier la barre latérale |
| `?` | Espace de travail, hors d’un champ de texte | Afficher la boîte de dialogue des raccourcis clavier |
| `Échap` | Fenêtre de l’assistant, focus à l’intérieur | Réduire la fenêtre de l’assistant |

## Sur une liste

| Raccourci | Contexte | Action |
| --- | --- | --- |
| `C` | Page de liste, votre rôle autorise la création | Démarrer un nouvel enregistrement de ce doctype |
| `j` ou `↓` | Page de liste | Surligner la ligne suivante |
| `k` ou `↑` | Page de liste | Surligner la ligne précédente |
| `Entrée` | Page de liste | Ouvrir l’enregistrement surligné |
| `Entrée` | Tiroir d’aperçu ouvert | Ouvrir la pleine page de l’enregistrement |
| `Échap` | Page de liste | Effacer le surlignage de ligne |
| `/` | Page de liste avec une zone de recherche | Aller à la zone de recherche de la liste |

Les raccourcis de ligne apparaissent sur les listes qui ouvrent les
enregistrements dans le tiroir d’aperçu. Le tiroir d’aperçu est l’aperçu de
l’enregistrement sur le côté de la page. Le raccourci `/` apparaît quand le
doctype a une zone de recherche.

## Dans un document

| Raccourci | Contexte | Action |
| --- | --- | --- |
| `E` | Page du document, votre rôle autorise la mise à jour | Modifier l’enregistrement |
| `Ctrl+S` | Éditeur | Enregistrer le formulaire |
| `Ctrl+Entrée` | Éditeur | Enregistrer le formulaire |

## Dépannage

### Un raccourci lettre ne fait rien

Le focus se tient dans un champ de texte. Les raccourcis lettre ne se
déclenchent pas pendant que vous tapez. Sélectionnez d’abord hors du champ.

### Un raccourci ne fait rien quand une boîte de dialogue est ouverte

Une boîte de dialogue ouverte possède le clavier. Fermez d’abord la boîte de
dialogue.

### `C` ou `E` ne fait rien

Votre rôle ne permet peut-être pas la création ou la mise à jour. Le raccourci
suit les mêmes droits que les boutons.

### Une combinaison du navigateur reste native

`Ctrl+C`, `Ctrl+T` et les combinaisons semblables appartiennent au navigateur
ou au système d’exploitation. Facet ne les utilise pas.

## Voir aussi

- [Recherche et palette de commandes](/fr/workspace/search-command-palette/) —
  ce qu’ouvre `Ctrl+K`.
- [Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/) —
  les listes sur lesquelles ces raccourcis de ligne marchent.
- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  modifier avec `E`, enregistrer avec `Ctrl+S`.
- [Utiliser l’assistant](/fr/workspace/assistant/) — la fenêtre qu’ouvre
  `Ctrl+I`.
