---
title: Sous le capot
description: "Cinq pages de fond : le journal des mutations, les contextes d’authentification, le contrôle des accès, les événements et les droits de l’assistant."
type: overview
audience: [admin, developer]
features: []
verified_at: eee55a2
sidebar:
  order: 0
---

Les pages d’administration disent quoi cliquer. Celles-ci disent ce que
Facet fait réellement quand vous cliquez. Chacune démonte un mécanisme :
le journal des mutations, le contexte d’authentification, les
vérifications d’accès, le bus d’événements, et les règles de l’assistant.

Lisez-en une quand une page pas-à-pas y renvoie. Ou quand vous devez
répondre à une question « pourquoi » avec précision : un audit, une revue
de sécurité, une discussion de conception.

## Les cinq pages

| Page | La question à laquelle elle répond |
| --- | --- |
| [Le journal des mutations](/fr/admin/under-the-hood/change-log/) | Où va chaque changement, et que note une ligne ? |
| [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/) | Comment chaque canal aboutit-il à une identité et un rôle ? |
| [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) | Quelles vérifications se dressent entre une requête et les données ? |
| [Événements et garanties de livraison](/fr/admin/under-the-hood/events-and-delivery/) | Que se passe-t-il quand une réaction se perd, et pourquoi est-ce sûr ? |
| [Assistant et permissions](/fr/admin/under-the-hood/ai-and-permissions/) | Sous quels droits s’exécute un appel d’outil de l’assistant ? |

## Comment les lire

Chaque page se lit seule, mais elles partagent une même colonne
vertébrale. Une requête arrive avec un
[contexte d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/).
Les [contrôleurs](/fr/admin/under-the-hood/how-access-is-enforced/)
décident de ce qu’elle peut toucher. Une écriture acceptée ajoute une ligne
au [journal des mutations](/fr/admin/under-the-hood/change-log/) et publie
un [événement](/fr/admin/under-the-hood/events-and-delivery/) auquel
d’autres parties du système réagissent. Quand l’appelant est l’assistant,
les mêmes contrôleurs s’appliquent — voyez
[Assistant et permissions](/fr/admin/under-the-hood/ai-and-permissions/).

## Voir aussi

- [Administrer](/fr/admin/) — la section d’administration complète, un
  niveau au-dessus.
- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — la même
  histoire en mots simples.
- [Santé, métriques et logs](/fr/admin/keep-running/monitoring/) — observer
  ces mécanismes en fonctionnement.
