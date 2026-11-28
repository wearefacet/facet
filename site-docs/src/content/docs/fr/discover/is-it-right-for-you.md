---
title: Facet est-il fait pour vous ?
description: Voyez où Facet convient, où il ne convient pas, et ce qu’il faut pour l’exécuter.
type: explanation
audience: [evaluator]
features: []
verified_at: eee55a2
sidebar:
  order: 4
---

Facet applique un modèle unique de domaines, de rôles et d’historique à chaque écriture. Ce modèle rend Facet sûr pour un usage de longue durée, et c’est aussi pourquoi il est le mauvais outil pour certains travaux. Cette page présente les deux côtés, pour que vous décidiez avant d’installer.

## Quand Facet convient

Si la plupart de ces lignes vous décrivent, Facet est conçu pour vous.

| Quand | Ce que Facet vous apporte | À la place de |
| --- | --- | --- |
| **Le métier construit ses outils lui-même** | Une personne qui connaît le travail décrit l’outil à un agent de code, et le livre. Facet porte les comptes, les permissions, l’historique et l’hébergement, donc l’app reste petite. | Un backend sur mesure derrière chaque app |
| **Les enregistrements doivent survivre aux apps** | Un client reste un client, quel que soit l’outil qui le modifie ensuite. Supprimez une app : les données, les règles et l’historique restent. | Des données enfermées dans chaque app |
| **Chacun doit voir des lignes et des champs différents** | Un commercial voit ses propres clients ; l’entrepôt ne voit pas les prix d’achat. Les mêmes règles s’appliquent dans chaque app et dans l’API. | Des contrôles de permission codés à la main dans chaque app |
| **La traçabilité fait partie du métier** | Chaque changement est enregistré : qui l’a fait, quand, et par quelle app. Quand un auditeur demande, vous avez la réponse. Vous fixez la durée de conservation de l’historique. | Des scripts d’audit et une journalisation improvisée |
| **Le temps des développeurs est rare** | Connexion, droits et audit sont construits une fois, sur la plateforme, pour toutes les apps. Une petite équipe peut livrer de nombreux outils. | Une plomberie d’authentification reconstruite pour chaque outil |
| **Vos processus sont les vôtres** | Vous décrivez un domaine (ses types d’enregistrements, ses champs et ses règles) dans un brouillon, vous le vérifiez, et vous le publiez. | Un module empaqueté dans lequel il faut couler votre travail |
| **Les données doivent rester sur votre infrastructure** | Facet s’auto-héberge. Vos données vivent dans votre PostgreSQL et votre stockage de fichiers, où que vous l’exécutiez. | Un fournisseur qui détient vos données |

Facet remplace la pile sous l’app, pas l’app elle-même. Il la rend assez petite pour être jetable.

## Quand Facet ne convient pas

D’abord, une précision sur le volume : les données métier d’une organisation ne constituent pas une charge lourde. Des millions d’enregistrements, et des dizaines de milliers de nouveaux par jour, sont un travail ordinaire pour Facet sur une configuration standard. Son stockage est PostgreSQL, donc il se dimensionne comme PostgreSQL.

La limite concerne les données écrites par des machines plutôt que par le travail des personnes. Facet vérifie chaque écriture et en conserve l’historique. Ce coût est négligeable pour une fiche client ou une commande. Pour un flux de clics ou de mesures de capteurs, c’est du gaspillage. Exécutez ces charges sur un magasin conçu pour elles, à côté de Facet, et gardez Facet comme système de référence.

| Quand | Pourquoi Facet ne convient pas | À utiliser à la place |
| --- | --- | --- |
| **Vous ingérez des événements au rythme des machines** | Flux de clics, capteurs, journaux et pixels de suivi arrivent à des milliers d’écritures par seconde. Ils demandent un stockage en ajout seul avec purge de rétention, pas un enregistrement vérifié et versionné par événement. | Une base de séries temporelles ou un magasin d’événements |
| **Vous menez des statistiques et de l’analytique** | Les listes et les filtres servent les opérations quotidiennes, pas les scans d’agrégats sur tout l’historique. | Un moteur d’analytique, alimenté par des exports |
| **Vous construisez un produit grand public** | Facet sert les personnes d’une organisation : le personnel, les partenaires, un ensemble connu de clients. Les comptes viennent d’invitations et du SSO. Il n’y a pas d’inscription publique, et le produit n’est pas conçu pour des millions d’utilisateurs anonymes. | Une pile grand public construite sur mesure |
| **Vous servez plusieurs sociétés clientes** | Un déploiement sert une organisation. Facet n’a pas de cloisons entre des locataires distincts. | Une conception multi-tenant dédiée |
| **Vous devez suivre une architecture informatique maison** | Facet applique son modèle tel quel : domaines, types d’enregistrements, rôles et journal des changements. Il ne se replie pas autour de votre architecture. | Des services sur mesure autour de votre architecture |
| **Vous voulez un service hébergé** | Facet est un logiciel à auto-héberger ; ce sont vos serveurs. | Une plateforme hébergée |

## Ce qui n’est pas encore intégré

Vous pouvez vérifier chaque point ci-dessous dans le code source. Chacun a une solution de contournement. La plupart sont prévus.

| Non intégré | À faire à la place |
| --- | --- |
| **Rapports et graphiques** | Exportez les données ou lisez-les via l’API. Un outil BI s’y connecte, sous les mêmes règles de rôle. |
| **Un moteur de workflow** | Les hooks d’événement et les webhooks réagissent à des événements isolés. Les flux en plusieurs étapes et les chaînes d’approbation entre domaines demandent un outil externe. |
| **Modules métier préconstruits** (CRM, comptabilité, stocks, RH) | Modélisez vos propres domaines dans le Builder ; l’assistant aide. |
| **Modèles de rôles** | Définissez vous-même les permissions de chaque rôle. |
| **Passkeys** | Connectez-vous avec un mot de passe et la MFA, le SSO, ou des clés API. |
| **Une app mobile** | Utilisez l’espace de travail web, ou construisez un client sur l’API. |

## Ce qu’il faut pour l’exécuter

- **Un serveur que vous contrôlez.** PostgreSQL 14 ou plus récent, et Redis. Un exemplaire de chacun suffit pour la plupart des installations. La liste complète est sur [Prérequis système](/fr/admin/install/requirements/).
- **Docker avec Compose** pour la voie conteneurs. La pile publiée compte cinq services derrière une terminaison TLS. Vous pouvez aussi construire depuis le code source.
- **Un fichier de configuration par environnement.** Les valeurs secrètes peuvent venir de variables d’environnement plutôt que du fichier.
- **Un compte administrateur**, créé au premier démarrage.
- **Quelqu’un pour modéliser le premier domaine.** Aucun code n’est nécessaire : vous travaillez dans le **Builder**, avec l’assistant.
- **Environ une heure** pour l’essayer : [Votre première heure](/fr/build/first-hour/).

### Un produit jeune, avec une sortie assurée

Les versions publiées de Facet restent en 0.x, et l’écosystème autour du produit est petit. En échange, vous détenez le code source, et chaque version passe sous Apache 2.0 au bout de quatre ans. Voir [Licence et services](/fr/discover/licensing-and-services/).

## Décider en un après-midi

Exécutez la pile, parcourez-la, et construisez un petit domaine à vous. [Exécuter Facet](/fr/build/first-hour/run-facet/) est le parcours complet ; en forme courte :

1. Lancez la pile d’une seule commande, dans un dossier vide. Elle écrit les fichiers de la pile, démarre les cinq conteneurs, et crée l’administrateur :

   ```sh
   pnpx @facetapp/cli setup-dev
   ```

2. Connectez-vous sur `https://facet.localhost:3443` avec `admin@example.tld` / `admin`, et suivez la visite de bienvenue.
3. Parcourez l’espace de travail : listes, filtres, historique des documents.
4. Construisez un petit domaine à vous. Voir [Modéliser votre premier domaine](/fr/build/first-hour/first-domain/) pour le parcours guidé, ou [Domaines, brouillons et éditeurs](/fr/build/model/in-app/drafts-and-publishing/) pour la référence.

Si l’étape 4 a pris environ une heure, et si la plupart des lignes de [Quand Facet convient](#quand-facet-convient) vous décrivent, Facet convient.

## Voir aussi

- [Pourquoi Facet](/fr/discover/why-facet/) : les problèmes derrière le modèle.
- [Une journée chez Brightwater](/fr/discover/a-day-at-brightwater/) : le produit en une histoire.
- [Sécurité et gouvernance](/fr/discover/security/) : le modèle qu’une revue de sécurité va interroger.
- [Licence et services](/fr/discover/licensing-and-services/) : ce que la licence vous permet.
- [Déployer en production](/fr/admin/install/production/) : le parcours d’installation complet.
