---
title: Glossaire
description: Une définition courte par terme employé dans la documentation Facet, par ordre alphabétique.
audience: [evaluator, user, author, admin, developer, operator]
features: []
sidebar:
  order: 5
verified_at: 7a6cb462
---

## Termes

Les entrées se classent d’après le terme anglais, celui que le code et l’API
emploient.

**Auth context (contexte d’authentification)** — l’ensemble identité et droits
pour une requête : qui appelle, l’unique rôle élu, et l’attribution de
l’application quand une app appelle.
→ [Architecture en un coup d’œil](/fr/discover/how-it-works/)

**Backlink (lien entrant)** — la trace d’un autre document qui référence
celui-ci. La page détail les liste sous « Référencé par ».
→ [backlinks doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/links.md)

**Domain (domaine)** — un espace de noms pour un secteur métier, comme `hr` ou
`sales`. Il regroupe des doctypes et borne les droits et la portabilité.
→ [Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/)

**Doctype** — un type d’enregistrement typé dans un domaine, comme
`hr.Employee`. Sa définition déclare les champs, les actions et les
périmètres de lignes.
→ [Concevoir des doctypes](/fr/build/model/data/design-doctypes/)

**Document** — un enregistrement : un document JSON avec un id unique, un état
courant, et l’historique complet des changements.
→ [Concevoir des doctypes](/fr/build/model/data/design-doctypes/)

**Draft (brouillon)** — un domaine de brouillon, dont l’id commence par `_`,
où vous itérez sur les doctypes avant de les publier dans le domaine réel.
→ [Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/)

**Elected role (rôle élu)** — l’unique rôle sous lequel un appelant agit pour
une requête. Les rôles ne fusionnent jamais.
→ [Sécurité et gouvernance](/fr/discover/security/)

**Grant (attribution)** — un consentement explicite. L’attribution d’une
application dit ce qu’une app externe peut faire. Une attribution de domaine
laisse un domaine lire des ressources nommées d’un autre domaine.
→ [Sécurité et gouvernance](/fr/discover/security/)

**Mutation** — une ligne ajoutée au journal : qui a changé quel document,
comment, quand, et pourquoi. Create, update, delete et instantané sont des
mutations.
→ [Architecture en un coup d’œil](/fr/discover/how-it-works/)

**Permission line (ligne de permission)** — une règle dans un rôle : une
action, un chemin de doctype, et des périmètres de lignes et des exceptions
facultatifs.
→ [Sécurité et gouvernance](/fr/discover/security/)

**Projection** — l’état courant d’un document : le contenu, le nom
d’affichage, le texte de recherche et les liens entrants. Les lectures
passent par les projections ; le journal garde l’historique.
→ [Architecture en un coup d’œil](/fr/discover/how-it-works/)

**Scope (périmètre)** — un prédicat de lignes nommé sur un doctype, comme
`$mine` ou `$global`. Une ligne de permission référence des périmètres pour
limiter les lignes qu’elle couvre.
→ [Sécurité et gouvernance](/fr/discover/security/)

**Sidecar** — un doctype qui s’attache à n’importe quel document par un champ
référence, comme un commentaire. Ce n’est pas un enfant en composition de
l’hôte.
→ [sidecar doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/sidecar.md)

**Tag (étiquette)** — une étiquette posée sur un champ. Un rôle doit porter
l’étiquette pour voir le champ, et une attribution de domaine fait circuler
un champ quand l’étiquette correspond.
→ [Sécurité et gouvernance](/fr/discover/security/)

**View template (modèle de vue)** — un modèle enregistré qui définit le rendu
de la page détail d’un doctype : l’en-tête, les onglets, les champs et les
tables de relations.
→ [document-view doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/frontend/document-view.md)

**Webhook** — un enregistrement sortant qui livre une enveloppe d’événement
signée à votre URL à chaque mutation d’un doctype.
→ [webhook doc on GitHub](https://github.com/wearefacet/facet/blob/main/doc/backend/webhook.md)

## Voir aussi

- [Qu’est-ce que Facet](/fr/discover/why-facet/)
- [Architecture en un coup d’œil](/fr/discover/how-it-works/)
- [Sécurité et gouvernance](/fr/discover/security/)
