---
title: La vue schématique
description: Lisez et agencez les doctypes d’un domaine en schéma à boîtes et flèches.
audience: [author]
features: [DOM-20]
sidebar:
  order: 17
verified_at: fd345fe3
---

La vue schématique dessine un domaine en boîtes et en flèches. Chaque boîte est un doctype. Chaque flèche est une relation entre deux doctypes. Vous lisez la forme du domaine d’un coup d’œil, et vous faites glisser les boîtes afin d’arranger l’image pour votre équipe.

## Quand l’utiliser

- Vous arrivez sur un domaine et voulez sa structure en une seule image.
- Vous prévoyez un nouveau doctype et vérifiez où il se rattache.
- Vous présentez le modèle à un client ou à un nouveau collègue.

## Avant de commencer

- **Où la trouver.** Ouvrez **Configure**, choisissez le domaine, puis ouvrez l’onglet **Doctypes**. Le Builder affiche la même image pour un brouillon.
- **Structure en lecture seule.** L’image reste en lecture seule pour la structure. Vous modifiez les relations en éditant les doctypes, pas en éditant l’image.

## Étapes

### 1. Lisez les boîtes

Chaque boîte porte le nom du doctype et sa couleur. Un doctype avec une couleur déclarée la garde. Un doctype sans couleur en reçoit une, générée et stable, pour que le même doctype ait toujours le même aspect.

### 2. Lisez les flèches

| Flèche | Signification |
| --- | --- |
| Ligne pleine avec un losange plein | Composition : le losange se trouve sur le parent, et l’enfant ne peut exister sans lui. |
| Ligne pointillée avec une flèche ouverte | Référenceà : un doctype pointe vers un autre et reste indépendant. |

Les boîtes se placent d’abord sur deux colonnesà : les racines d’agrégat à gauche, leurs enfants regroupés à droite. Une racine avec beaucoup d’enfants tire son groupe vers le bas.

### 3. Déplacez les boîtes

Faites glisser une boîte où vous voulez. Les flèches suivent. Au moment où vous la déposez, Facet enregistre la position pour tout le domaineà : toute personne qui consulte ce domaine voit votre disposition.

:::caution
La disposition est partagée, pas personnelle. Deux personnes qui rangent les boîtes en même temps s’écrasent l’une l’autreà ; le dernier enregistrement gagne.
:::

### 4. Ouvrez un doctype

Sélectionnez une boîte. Facet la met en surbrillance et ouvre la page du doctype, où vous modifiez ses champs et ses relations. Ajoutez un doctype via l’éditeur de doctypesà ; l’image l’intègre dès le prochain affichage.

## Exemple

Un domaine `helpdesk` porte deux racines d’agrégat. `Ticket` a un enfant `Comment` et une référence vers `Account`. `Account` n’a aucune relation. L’image se présente ainsià :

<!-- d2
ticket: Ticket
comment: Comment
account: Account

ticket -> comment: child
ticket -> account: reference {style: {stroke-dash: 3}}
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/bcce1090-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/bcce1090-dark.svg" alt="Diagram" loading="lazy" />
</div>

La flèche pleine vers `Comment` porte le losange plein côté `Ticket` : le commentaire fait partie du ticket, et supprimer le ticket supprime ses commentaires. La flèche pointillée vers `Account` porte la flèche ouverteà : le ticket pointe vers le compte, et les deux fonctionnent l’un sans l’autre.

## Dépannage

**Une boîte manque.**

Seuls les doctypes de ce domaine apparaissent. Un doctype d’un autre domaine se montre comme cible de référence, pas comme une boîte.

**Ma disposition a disparu.**

Un collègue a enregistré une nouvelle disposition, ou le domaine a été republié. Rangez de nouveauà ; l’enregistrement est rapide.

**Une relation n’a pas de flèche.**

Seules la composition et les références dans le même domaine se dessinent. Une référence vers un doctype d’un autre domaine, ou vers une cible non enregistrée, ne dessine rien.

**L’image ne correspond pas à mes définitions.**

Rechargez l’onglet. L’image lit les définitions enregistréesà ; vos modifications non enregistrées dans l’éditeur restent invisibles.

## Voir aussi

- [Doc du concern schématique](https://github.com/wearefacet/facet/blob/main/doc/frontend/schematic.md) — le moteur de rendu et le stockage des dispositions.
- [Domaines et isolement](/fr/concepts/domains-and-isolation/) — ce que regroupe un domaine.
- [Concevoir des doctypes](/fr/build/designing-doctypes/) — ajoutez le doctype qui manque à l’image.
