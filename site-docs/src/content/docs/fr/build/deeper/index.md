---
type: overview
title: "Le moteur en profondeur"
description: "Quatre pages qui expliquent le moteur sous le Builder : domaines, stockage, évolution du schéma et copies entre domaines."
audience: [author, developer]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Les pages de ce groupe expliquent la mécanique sous le Builder. Elles
emploient le vocabulaire du moteur — projection, mutation, migration
paresseuse — et définissent chaque terme. Lisez-les quand une page pratique
renvoie à la page détaillée, ou quand un comportement vous surprend et que
vous en voulez la raison.

Chaque sujet a aussi une version en langage simple dans [Comment fonctionne
Facet](/fr/discover/how-it-works/) — les mêmes faits, sans le vocabulaire du
moteur.

## Les quatre pages

- [L’isolation entre domaines](/fr/build/deeper/domain-isolation/) — ce
  qu’un domaine possède, ce qui franchit la frontière, et ce qui la
  contrôle.
- [Comment un document est stocké](/fr/build/deeper/documents-and-projections/) —
  doctype, document, projection : les trois parties de chaque
  enregistrement, et l’ETag.
- [Comment les anciens documents suivent un nouveau schéma](/fr/build/deeper/schema-evolution/)
  — la migration paresseuse : pourquoi il n’y a aucune tâche de rattrapage,
  et ce qu’elle coûte.
- [Comment les champs copiés restent synchronisés](/fr/build/deeper/cross-domain-replication/)
  — la copie à un seul saut derrière un champ `replicate`, et l’attribution
  qui la contrôle.

## Voir aussi

- [Construire des domaines](/fr/build/) — la moitié pratique de cet onglet.
- [Choisir votre mode de construction](/fr/build/model/) — les deux modes
  de construction qui regroupent ces pages.
