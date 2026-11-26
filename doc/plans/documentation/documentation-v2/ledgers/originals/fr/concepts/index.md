---
title: Concepts
description: "Comment Facet pense : des pages courtes qui expliquent le modèle derrière le produit."
audience: [evaluator]
features: []
sidebar:
  order: 0
verified_at: 7a6cb462
---

Ces pages expliquent comment Facet fonctionne, et pourquoi. Chacune est
courte, commence par un schéma ou un tableau, et nomme ses compromis.
Lisez-les quand un guide pratique part du modèle sans le réexpliquer.

## Dans cette section

- [Domaines et isolement](/fr/concepts/domains-and-isolation/) — ce qu’un
  domaine borne, et ce qu’une attribution autorise à traverser.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) —
  les trois parties de chaque enregistrement.
- [Le journal des mutations](/fr/concepts/mutation-log/) — pourquoi chaque
  écriture ajoute une ligne, et pourquoi ce n’est pas de l’event sourcing
  de domaine.
- [Brouillon → publication](/fr/concepts/draft-publish/) — modifiez un
  brouillon, puis publiez-le en une seule transaction.
- [Contextes d’authentification](/fr/concepts/auth-contexts/) — un seul
  rôle élu sur chaque canal.
- [Application des autorisations](/fr/concepts/authorization-enforcement/) —
  périmètres de lignes, étiquettes de champ, et refus sans divulgation.
- [Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/) —
  qui peut modifier les rôles, et qui ne le peut pas.
- [Applications : attributions ∩ rôles](/fr/concepts/apps-grants-roles/) —
  l’intersection qui plafonne chaque appel d’application.
- [Événements et garanties de livraison](/fr/concepts/events-delivery/) —
  une livraison au plus une fois, et les crons qui la réparent.
- [Évolution du schéma et migration paresseuse](/fr/concepts/schema-evolution/) —
  les documents migrent à leur prochaine lecture.
- [Réplication inter-domaines](/fr/concepts/cross-domain-replication/) —
  des copies de champs en un seul saut, soumises à une attribution.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) —
  l’assistant ne détient aucune permission propre.
