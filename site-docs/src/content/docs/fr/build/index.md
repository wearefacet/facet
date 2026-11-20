---
title: Construire des domaines
description: "Modélisez vos données métier dans Facetà : doctypes, champs, actions, vues et automatisation."
audience: [author]
features: []
sidebar:
  order: 0
verified_at: fd345fe3
---

Vous êtes auteur de domaine et vous voulez héberger vos données métier dans
Facet. Cette section vous montre comment faire. Commencez par un domaine de
brouillon et un seul doctype. Puis étoffez le modèle à mesure que vous
découvrez ce que le produit peut contenir.

Vous allez mener quatre chantiersà : **modéliser** les données, **façonner les
vues** que les gens utilisent, **publier et faire évoluer** le domaine, et
**automatiser** ce qui s’ensuit.

## Modélisation

- [Domaines, brouillons et éditeurs de domaines](/fr/build/domains-drafts-editors/) — ouvrez un domaine de brouillon, invitez des co-éditeurs et publiez vers le domaine réel.
- [Concevoir des doctypes](/fr/build/designing-doctypes/) — déclarez les champs, les actions et les modèles d’un type d’enregistrement.
- [Types de champs (guide)](/fr/build/field-types/) — choisissez le bon type pour chaque champà ; valeurs par défaut et normalisation.
- [Références, liens et liens entrants](/fr/build/references-links-backlinks/) — reliez les documents entre eux et parcourez les connexions.
- [Identifiants et contraintes d’unicité](/fr/build/identifiers-unique-constraints/) — des numéros de référence lisibles par l’humain et des règles d’unicité.
- [Composition parent/enfant](/fr/build/parent-child-composition/) — modélisez des enfants possédés qui vivent et meurent avec leur parent.
- [Sidecars (commentaires, pièces jointes)](/fr/build/sidecars/) — ajoutez un panneau de discussion et des fichiers à un doctype.
- [Fichiers et artefacts dans les champs](/fr/build/files-artifacts/) — stockez des fichiers dans le magasin d’artefacts et liez-les depuis des champs.
- [Champs secrets et en écriture seule](/fr/build/secret-write-only-fields/) — stockez des identifiants en toute sécurité et acceptez des valeurs que vous ne pourrez jamais relire.
- [Actions nommées](/fr/build/named-actions/) — donnez aux utilisateurs des opérations typées au-del à des simples modifications.
- [Scripts de cycle de vie et garde-fous](/fr/build/lifecycle-scripts-guards/) — exécutez du Lua à la création, à la mise à jour et à la suppression, et bloquez les écritures invalides.
- [Champs calculés](/fr/build/computed-fields/) — dérivez des valeurs de champs à partir d’un modèle.

## Vues

- [Noms d’affichage et texte de recherche (Jinja2)](/fr/build/display-names-search-text/) — contrôlez comment les documents se nomment et comment la recherche les voit.
- [Modèles de vue de document (pages détail et formulaire)](/fr/build/view-templates/) — concevez la page qu’un utilisateur voit en ouvrant un document.
- [Vues de collection](/fr/build/collection-views/) — configurez le tableau, le kanban ou la grille qui liste un doctype.
- [Périmètres nommés](/fr/build/named-scopes/) — des filtres de lignes réutilisables que les rôles peuvent référencer.
- [La vue schématique](/fr/build/schematic-view/) — voyez tout le domaine sous forme de diagramme pendant que vous le concevez.

## Publier et faire évoluer

- [Vérifier un domaine avant publication](/fr/build/checking-before-publish/) — lancez les contrôles de publication et lisez le rapport.
- [Faire évoluer un schéma (migrations, reprojection)](/fr/build/evolving-schema/) — changez les champs sans risque et mappez les anciennes valeurs vers les nouvelles.
- [Partager des données entre domaines (attributions, réplication)](/fr/build/sharing-across-domains/) — accordez un accès à un autre domaine et copiez des données de référence.
- [Déplacer des domaines entre instances (bundles)](/fr/build/bundles/) — exportez un domaine et importez-le ailleurs.

## Automatiser

- [Hooks d’événement et de planification](/fr/build/event-hooks/) — réagissez aux changements et exécutez des tâches planifiées.
- [Webhooks sortants](/fr/build/webhooks/) — appelez des systèmes externes quand des documents changent.
- [Notifications et mentions](/fr/build/notifications-mentions/) — notifiez des personnes depuis des scripts et des commentaires.
- [Utiliser l’assistant de construction de domaines](/fr/build/domain-builder-assistant/) — ébauchez un domaine en le décrivant dans le chat.
- [Le watcher des domaines en dev](/fr/build/dev-domain-watcher/) — synchronisez les définitions de domaine depuis votre éditeur pendant que vous développez.
