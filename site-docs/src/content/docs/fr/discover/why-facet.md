---
title: Qu’est-ce que Facet
description: "Découvrez Facet : la plateforme gouvernée qui héberge vos données métier et les applications que vous construisez dessus."
audience: [evaluator]
features: []
sidebar:
  order: 1
verified_at: 7a6cb462
---

Facet est une plateforme applicative gouvernée pour les organisations de
petite et moyenne taille. Il héberge les applications internes que vous
construisez. Il porte les données, les droits et l’historique sur lesquels ces
applications reposent.

## Le problème qu’il résout

Une personne du métier peut décrire l’application qu’elle veut à Claude Code
ou à un autre agent de code, et l’agent l’écrit en quelques heures. Faire
tourner cette application en sécurité, voil à ce qui prenait du temps :

- il faut bien l’héberger,
- il faut décider qui peut lire et modifier chaque enregistrement,
- il faut garder l’historique de chaque changement.

Facet prend tout cela en charge.

**Une application est jetable ; vos données ne le sont pas.**
L’application que votre agent a écrite le trimestre dernier peut être
remplacée. Les enregistrements, les règles et l’historique restent.

## Le socle et l’application

Facet sépare deux éléments que les piles sur mesure mélangent d’habitude :

| Couche            | Ce qu’elle porte                                                               | Durée de vie                              |
| ----------------- | ------------------------------------------------------------------------------ | ----------------------------------------- |
| Le socle          | Documents, rôles, permissions, journal d’audit, fichiers, secrets, identité    | Des années — il survit à toutes les applications |
| L’application     | Un frontend ou un agent qui lit et écrit via l’API                             | Des semaines ou des mois — à remplacer librement |

**L’application reste à l’extérieur.** Une application ne s’exécute jamais
dans Facet et ne touche jamais à la base de données. Elle se connecte via
OAuth (un protocole d’autorisation ouvert) et appelle l’API HTTP avec les
droits que vous lui avez donnés. Supprimez l’application : les données, les
règles et l’historique demeurent.

## Ce que vous obtenez d’office

Chaque application sur Facet hérite des mêmes services. Vous ne les
reconstruisez pas :

| Service    | Ce que cela signifie                                                                                                                |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Identité   | Comptes, mots de passe, MFA (authentification multifacteur), SSO (authentification unique) via OIDC, et clés d’API                   |
| Droits     | Les rôles décident qui lit et qui écrit — par type d’enregistrement, jusqu’aux champs et aux lignes. Le contrôle s’exerce dans la couche de données, pas dans l’application |
| Audit      | Chaque modification atterrit dans un journal en ajout seul : qui a changé quoi, quand, et pourquoi. Ramenez n’importe quel document à un état antérieur |
| Hébergement | Facet sert le frontend de l’application, connecte les utilisateurs et relaie les appels d’API                                      |

## Construire avec un agent, pas en projet IT

Vous n’avez pas besoin de la pile de développement classique pour livrer un
outil interne :

- **Avec un agent de code.** Connectez Claude Code ou n’importe quel client
  MCP (Model Context Protocol) à Facet. L’agent reçoit des outils pour lire et
  écrire les données sous un rôle que vous épinglez. La plateforme vérifie
  chaque appel, exactement comme pour un humain.
- **Dans l’espace de travail.** L’assistant de construction de domaines rédige
  des brouillons de doctypes et de vues à partir de vos prompts.
- **À la main.** Pour un frontend écrit à la main, le SDK TypeScript et la CLI
  couvrent la construction, et Facet héberge le résultat et connecte ses
  utilisateurs.

  L’agent ne touche jamais à la base de données. Droits, audit et historique
  viennent de la plateforme : l’application que le métier a décrite est sûre
  dès le départ.

## Sur quoi il tourne

- **Backend :** Crystal, PostgreSQL, Redis. Les documents sont des lignes JSONB.
- **Espace de travail :** une application web avec des vues tableau, kanban,
  grille, calendrier, formulaire et détail. Votre équipe travaille sans
  frontend supplémentaire.
- **Applications et agents :** une API REST, un SDK TypeScript, une CLI, et
  des outils MCP (Model Context Protocol).

## Voyez-le tourner

```sh
git clone https://github.com/wearefacet/facet.git
cd facet
cp docker/.env.example docker/.env   # fill in hostname, SMTP, secrets
docker compose -f docker/compose.prod.yml up -d --build
```

Le point d’entrée applique les migrations et initialise le schéma de base au
démarrage. Créez ensuite le premier administrateur :

```sh
docker compose -f docker/compose.prod.yml exec backend facet seed:admin ops@your-company.tld
```

La commande affiche un mot de passe à usage unique. Connectez-vous sur
`https://<your-hostname>` et définissez un vrai mot de passe quand c’est
demandé. Les étapes complètes sont dans
[Déployer en production](/fr/admin/install/production/).

:::tip
Chargez les domaines d’exemple avec `scripts/import-fixtures` depuis une copie
des sources. Vous obtenez un modèle clients, RH et production avec des
données, avant de construire le vôtre.
:::

## Voir aussi

- [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) — les bons cas, les mauvais, et les enjeux métier auxquels Facet répond.
- [Architecture en un coup d’œil](/fr/discover/how-it-works/) — comment une requête traverse le système.
- [Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/) — comment Facet organise les données.
