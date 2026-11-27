---
title: Facet est-il fait pour vous ?
description: Voyez où Facet aide, où il ne convient pas, et s’il colle à votre activité.
audience: [evaluator]
features: [PLT-12]
sidebar:
  order: 2
verified_at: 7a6cb462
---

Décidez avant d’installer. Cette page dresse les cas qui collent, ceux qui ne
collent pas, et les enjeux métier où Facet est la réponse.

## Les cas qui collent

Facet fonctionne bien quand la plupart de ces points sont vrais :

| Cas                                             | Ce qu’il vous donne                                                                                                                                                            |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Le métier construit ses applications lui-même** | Pas d’attente dans la file de développement. Une personne du métier décrit l’application à Claude Code, à Claude Opus ou à un autre agent de code, et la livre en quelques heures. |
| **Vous voulez la vitesse des agents sans perdre le contrôle** | Facet donne à l’agent un cadre gouverné : il agit sous un rôle que vous épinglez, et la plateforme vérifie chaque appel, quel que soit l’auteur du code.                      |
| **Les enregistrements doivent survivre aux applications** | Un client reste un client, quel que soit l’outil qui le modifie.                                                                                                            |
| **Chacun ne voit pas les mêmes lignes et les mêmes champs** | Un auditeur peut vouloir savoir qui a changé quoi.                                                                                                                          |
| **Vous êtes une organisation de petite ou moyenne taille et vous voulez auto-héberger** | Les données restent dans votre PostgreSQL, sur vos machines.                                                                                      |

Facet remplace la pile classique sous l’application — le backend sur mesure,
la plomberie d’authentification, les scripts d’audit. Il ne remplace pas
l’application ; il la rend assez petite pour être jetable.

## Côté métier, la réponse est oui

Ces cinq situations sont celles où Facet rapporte le plus :

| Situation                                        | Ce qu’elle vous donne                                                                                                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **La souveraineté de vos données**               | Les données restent dans votre PostgreSQL, sur vos machines. Rien n’en sort, sauf si vous l’y envoyez.                                                                          |
| **L’auditabilité et la traçabilité sont obligatoires** | Chaque écriture atterrit dans un journal d’événements en ajout seul, avec qui, quand et quoi. Cela couvre les secteurs réglementés comme la santé et l’agroalimentaire.   |
| **Du code libre que vous déployez ou adaptez**   | Le code vous appartient. Déployez-le, fourchez-le, ou modifiez-le aux couleurs de votre organisation.                                                                            |
| **Peu d’accès aux développeurs**                 | Le métier décrit l’application à un agent de code et la livre. La plateforme porte l’authentification, les droits et l’audit, l’application reste donc petite.                  |
| **Un besoin de domaines et d’applications sur mesure** | Décrivez le domaine dans un brouillon, et Facet vous en donne les enregistrements, les listes, les droits et l’historique.                                                  |

## Les mauvais cas

Facet assume ses choix : un modèle unique de domaines, de doctypes, de rôles
et d’historique, appliqué à chaque écriture. Ces charges de travail demandent
un contrôle de plus bas niveau. Servez-vous pour elles d’un logiciel moins
directif, taillé sur mesure — une base de données simple et des services
écrits à la main :

| Charge de travail                         | Pourquoi cela ne colle pas                                                                                        | À utiliser à la place                        |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| **Charge lourde en écriture**             | Chaque écriture est validée, journalisée et projetée. Ce coût se paie en temps et en stockage à chaque ligne.     | Un schéma PostgreSQL simple, ajusté pour la charge |
| **Statistiques et analytique**            | Les listes et les filtres servent les opérations quotidiennes, pas les scans d’agrégats sur de très grands volumes. | Un moteur d’analytique alimenté par des exports |
| **Produits B2C**                          | Facet sert les personnes d’une organisation. Les comptes viennent d’invitations et du SSO — pas d’inscription publique en libre-service. | Une pile consommateur écrite sur mesure |
| **Multi-tenant**                          | Un déploiement sert une organisation. Facet n’a pas de cloisons entre sociétés clientes distinctes.               | Une architecture multi-tenant conçue pour cela |
| **Séries temporelles**                    | Des lignes horodatées à haute fréquence appellent un stockage en ajout seul avec purge de rétention, pas un historique par ligne. | Une base de séries temporelles |
| **Une architecture IT maison**            | Facet impose son modèle tel quel : domaines, doctypes, rôles et journal d’événements. Il ne se replie pas autour d’une architecture maison. | Des services sur mesure autour de votre architecture |
| **Un service hébergé**                    | Facet est un logiciel à auto-héberger ; ce sont vos serveurs.                                                | Une plateforme hébergée                      |

## Trancher en un après-midi

Lancez la pile, cliquez partout, et construisez un petit domaine à vous.
[Les tutoriels](/fr/build/first-hour/) donnent le parcours complet ; forme
courte :

1. Lancez la pile d’une commande, dans un dossier vide. Elle écrit les
   fichiers de la pile, démarre les cinq conteneurs et crée l’administrateur :

   ```sh
   pnpx @facetapp/cli setup-dev
   ```

2. Connectez-vous sur `https://facet.localhost:3443` avec
   `admin@example.tld` / `admin`, et suivez la visite de bienvenue.
3. Parcourez l’espace de travail : listes, filtres, historique des documents.
4. Construisez un petit domaine à vous — [Domaines, brouillons et éditeurs de
   domaines](/fr/build/model/in-app/drafts-and-publishing/).

Si l’étape 4 a pris une heure et que la plupart des bons cas vous
correspondent, Facet est fait pour vous.

## Voir aussi

- [Qu’est-ce que Facet](/fr/discover/why-facet/) — le produit en une page.
- [Sécurité et gouvernance](/fr/discover/security/) — les détails du contrôle derrière ces promesses.
- [Déployer en production](/fr/admin/install/production/) — le guide d’installation complet.
