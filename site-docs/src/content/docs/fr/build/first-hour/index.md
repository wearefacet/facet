---
type: overview
title: Votre première heure
description: Un parcours guidé, de la machine vide à un Facet en marche avec un domaine, une app, une équipe et un agent.
audience: [evaluator, author, admin, developer]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Vous découvrez Facet et vous voulez le voir fonctionner, pas lire des
descriptions. Ce parcours vous y conduit en une heure environ. Chaque
tutoriel est une liste d’étapes qui aboutit à un résultat fonctionnel,
écrite pour quelqu’un qui n’a jamais ouvert le produit. Suivez-les dans
l’ordre ; chacun reprend là où le précédent s’arrête.

**Avant de commencer**, il vous faut deux choses :

- [Docker avec Compose](https://docs.docker.com/compose/) pour le tutoriel 1.
  Aucun clonage du dépôt : `pnpx @facetapp/cli setup-dev` récupère les images.
- Node.js 20+ pour les tutoriels 1 et 4 (la CLI et l’agent de code). Les autres
  ne demandent rien de plus qu’un navigateur.

Tous les tutoriels utilisent le même exemple fil rouge : **Brightwater
Rentals**, une entreprise fictive de location de matériel événementiel près de
Lyon. Vous modélisez son matériel, invitez son personnel, et livrez son
application de sortie de matériel. Un lecteur qui suit deux pages retrouve les
mêmes domaines et les mêmes personnes.

## Le parcours

| # | Tutoriel | Durée | Ce que vous obtenez |
|---|---|---|---|
| 1 | [Lancer Facet](/fr/build/first-hour/run-facet/) | 10 min | La pile de conteneurs lancée, l’administrateur connecté, la visite de bienvenue terminée. |
| 2 | [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/) | 20 min | Le domaine `equipment` de Brightwater construit dans un brouillon avec l’assistant, vérifié, publié, avec un tableau kanban des tickets de maintenance. |
| 3 | [Le même domaine en fichiers](/fr/build/first-hour/first-domain-in-files/) | 15 min | Le même domaine sous forme de fichiers surveillés par le watcher de dev — un changement vu en direct, un bundle exporté. Réservé aux développeurs. |
| 4 | [Livrer votre première app](/fr/build/first-hour/first-app/) | 30 min | L’application de sortie de matériel de Brightwater, construite avec un agent de code et dont les utilisateurs se connectent à travers Facet. |
| 5 | [Donner accès à votre équipe](/fr/build/first-hour/team-access/) | 15 min | Un collègue invité ; un rôle qui masque les prix d’achat ; un commercial qui ne voit que ses propres clients. |
| 6 | [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/) | 15 min | Un client MCP qui répond aux questions sur les réservations de Brightwater sous un rôle réel, avec une trace dans le journal d’audit. |

## Si vous n’avez que dix minutes

Lancez le tutoriel 1 et ouvrez l’espace de travail. Voir le produit devant
vous change la lecture de chaque page.

## Après la première heure

La [section Build](/fr/build/) approfondit tout ce que le parcours aborde :
brouillons et publication, types de champs, actions, vues et automatisation.
Les [pages de l’espace de travail](/fr/use/) couvrent les surfaces du
quotidien de votre équipe.

## Voir aussi

- [Pourquoi Facet](/fr/discover/why-facet/) — l’idée derrière le produit, si
  vous la voulez avant la pratique.
- [Monter un environnement de dev](/fr/build/dev-environment/) — faire tourner
  Facet depuis les sources au lieu des conteneurs.
