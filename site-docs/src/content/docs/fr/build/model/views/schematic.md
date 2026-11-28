---
type: how-to
title: Votre domaine en schéma
description: Lisez et agencez les doctypes d’un domaine en schéma à boîtes et flèches.
audience: [author]
features: [DOM-20]
sidebar:
  order: 3
verified_at: eee55a2
---

Vous héritez d’un domaine de neuf doctypes, et un nouveau collègue demande comment ils s’articulent. La vue schématique dessine le domaine en boîtes et en flèches : chaque boîte est un doctype, chaque flèche une relation entre deux doctypes. Vous lisez la forme du modèle d’un coup d’œil, et vous faites glisser les boîtes pour arranger l’image pour votre équipe.

## Quand l’utiliser

- Vous rejoignez un domaine et voulez sa structure en une seule image.
- Vous prévoyez un nouveau doctype et vérifiez où il se rattache.
- Vous présentez le modèle à un client ou à un nouveau collègue.

## Avant de commencer

- **Où la trouver.** Ouvrez **Configurer**, choisissez le domaine, puis ouvrez l’onglet **Doctypes**. Le Builder affiche la même image pour un brouillon.
- **Structure en lecture seule.** L’image reste en lecture seule pour la structure. Vous modifiez les relations en éditant les doctypes, pas en éditant l’image.

## Lire l’image

Chaque boîte montre le nom du doctype et sa couleur. Un doctype avec une couleur déclarée la garde. Un doctype sans couleur en reçoit une, générée et stable, pour que le même doctype ait toujours le même aspect.

| Flèche | Signification |
| --- | --- |
| Ligne pleine avec un losange plein | Composition : le losange se trouve sur le parent, et l’enfant ne peut vivre sans lui. |
| Ligne pointillée avec une flèche ouverte | Référence : un doctype pointe vers un autre et reste indépendant. |

Les boîtes démarrent sur deux colonnes : les racines d’agrégat à gauche, leurs enfants regroupés à droite. Une racine avec beaucoup d’enfants tire son groupe vers le bas.

## Agencer l’image

Faites glisser une boîte où vous voulez. Les flèches suivent. Au dépôt, Facet enregistre la position pour tout le domaine : tout lecteur de ce domaine voit votre disposition.

:::caution
La disposition est partagée, pas personnelle. Deux personnes qui arrangent en même temps s’écrasent mutuellement ; le dernier enregistrement gagne.
:::

Sélectionnez une boîte. Facet la met en surbrillance et ouvre la page du doctype, où vous modifiez ses champs et ses relations. Ajoutez un doctype par l’éditeur de doctypes ; l’image l’intègre au prochain affichage.

## Exemple

Le domaine `equipment` de Brightwater a trois racines d’agrégat, liées par deux références entre doctypes du même domaine. Voici l’image :

*Le domaine equipment : trois racines d’agrégat, liées par deux références.*

<!-- d2
item: equipment.Item
ticket: equipment.MaintenanceTicket
category: equipment.Category

item -> category: reference {style: {stroke-dash: 3}}
ticket -> item: reference {style: {stroke-dash: 3}}
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/b6b44e05-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/b6b44e05-dark.svg" alt="Diagram" loading="lazy" />
</div>

Les trois doctypes sont des racines d’agrégat, donc chaque flèche est pointillée et porte la flèche ouverte : une référence pointe vers un autre doctype, et les deux survivent seuls. Si le domaine possédait un enfant — par exemple un doctype de rapports de réparation déclaré avec `member_of: MaintenanceTicket` — la flèche vers lui serait pleine et porterait le losange plein sur le parent.

## Dépannage

**Une boîte manque.**

Seuls les doctypes de ce domaine apparaissent. Un doctype d’un autre domaine se montre comme cible de référence, pas comme une boîte.

**Ma disposition a disparu.**

Un collègue a enregistré une nouvelle disposition, ou le domaine a été republié. Arrangez de nouveau ; l’enregistrement est rapide.

**Une relation n’a pas de flèche.**

Seules la composition et les références dans le même domaine se dessinent. Une référence vers un doctype d’un autre domaine, ou vers une cible non enregistrée, ne dessine rien.

**L’image ne correspond pas à mes définitions.**

Rechargez l’onglet. L’image lit les définitions enregistrées, donc vos modifications non enregistrées dans l’éditeur restent invisibles.

## Voir aussi

- [Concevoir un doctype](/fr/build/model/data/design-doctypes/) — ajoutez le doctype qui manque à l’image.
- [L’isolation entre domaines](/fr/build/deeper/domain-isolation/) — ce qu’un domaine regroupe et possède.
- Fonctionnement interne sur GitHub : [schematic.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/schematic.md).
