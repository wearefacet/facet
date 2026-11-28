---
title: Licence et services
description: Ce que la licence BSL 1.1 vous permet, quand les versions passent sous Apache 2.0, et où trouver de l’aide.
type: explanation
audience: [evaluator, developer, operator]
features: []
verified_at: eee55a2
sidebar:
  order: 7
---

Avant de construire sur un produit, lisez sa licence. Celle de Facet est courte et souple à dessein : elle bloque un seul mouvement d’affaires et autorise presque tout le reste. Cette page la traduit en mots simples. Les fichiers de licence du dépôt font foi — cette page n’est qu’un résumé.

## La licence en un paragraphe

Facet est un logiciel à source disponible sous la Business Source License 1.1 (BSL 1.1), publiée par Amplitude Solutions Ltd. La BSL n’est pas une licence open source ; elle le dit elle-même. Vous pouvez utiliser, modifier, forker et redistribuer Facet, et l’exécuter en production. Chaque version passe sous Apache 2.0 quatre ans après sa publication, et le reste.

## Ce que vous pouvez faire

| Vous pouvez | Pourquoi |
| --- | --- |
| Exécuter Facet en production pour votre propre organisation | L’usage en production par l’utilisateur est permis. |
| Le modifier, le forker, en redistribuer des copies | La licence accorde à tous les droits de copie, de modification et de redistribution. |
| Construire des apps et des domaines sur Facet et les vendre, y compris des apps face au public | Votre application est votre produit ; la licence ne la restreint pas. |
| Vendre des services autour de Facet : conseil, développement, migration, support, formation | L’Additional Use Grant permet des services à des tiers. |
| Héberger et exploiter Facet pour un client dans le cadre d’un contrat de services | L’attribution couvre l’hébergement géré dans le cadre d’un contrat. |
| Vendre des modèles de domaines, des packs de doctypes ou des extensions que vous avez écrits | Votre travail original vous appartient ; la licence couvre le code de Facet, pas le vôtre. |

## Ce qu’elle bloque

Deux mouvements demandent une licence commerciale auprès de l’éditeur :

- **Une offre Facet en libre-service** : un service où des tiers s’inscrivent et provisionnent eux-mêmes des instances ou des locataires Facet. Cela couvre l’inscription SaaS, le provisionnement automatisé par un portail, une API ou un marketplace, et des offres standard publiées que n’importe qui peut acheter sans négociation.
- **Les déploiements publics en un clic** — proposer Facet au public sous forme d’images conteneur ou VM prépackagées, d’installateurs, ou de référencements sur un marketplace cloud.

Le test de la page questions-réponses de la licence : Facet est-il lui-même le produit, vendu en libre-service ? Alors il demande une licence commerciale. Facet est-il l’outil avec lequel vous servez un client précis dans le cadre d’un accord ? Alors c’est permis.

Certaines situations n’ont pas de réponse nette : un produit qui embarque Facet, un service de démonstration public et gratuit, un programme de partenariat. Écrivez à l’éditeur avant de lancer : [contact@amplitude-solutions.com](mailto:contact@amplitude-solutions.com), le contact nommé dans la licence. Les arrangements de licence alternatifs vont à la même adresse.

## Vos données et votre travail

La licence couvre le code de Facet seulement. Vos domaines, vos types d’enregistrements, vos apps, vos modèles et vos données sont les vôtres. Facet stocke vos documents ; la licence n’en revendique aucun.

## La conversion au bout de quatre ans

Chaque version est publiée sous BSL 1.1. Quatre ans après la publication, cette version passe sous la Apache License, Version 2.0. Les versions plus anciennes restent sous Apache 2.0 ; les plus récentes portent leur propre horloge de quatre ans. La conversion figure dans le texte de la licence lui-même, pas dans une promesse sur un site web.

## Contribuer

Les contributions demandent un Contributor License Agreement (CLA) signé. Il existe pour une seule raison : il permet à l’éditeur de garder une licence unique pour tout le code, pour que chaque version puisse passer sous Apache 2.0 à l’heure. Vous gardez la propriété de ce que vous contribuez ; vous accordez une licence, pas votre copyright. La signature passe par l’app CLA Assistant lors de votre première pull request, et une signature couvre vos contributions suivantes. Voir [CLA.md](https://github.com/wearefacet/facet/blob/main/CLA.md).

## Marques déposées

Le nom Facet, le logo, et les noms des distributions et services officiels appartiennent à Amplitude Solutions Ltd. La licence n’accorde aucun droit de marque, donc une page séparée dit ce que vous pouvez faire :

- **Les références fidèles conviennent** : « construit sur Facet », « fonctionne avec Facet », « compatible Facet », « conseil Facet », « modèles de domaines Facet ».
- **Ne nommez pas une distribution, une image, un installateur ou une offre hébergée « Facet »**, ni rien d’aussi proche qu’on puisse confondre. Si vous distribuez un fork, renommez-le.
- **Ne présentez pas votre offre comme officielle ou certifiée**, et n’utilisez pas le logo sans permission écrite.
- **Trois mots restent à l’éditeur** : « official », « certified », et « Facet Cloud ».

Voir [TRADEMARKS.md](https://github.com/wearefacet/facet/blob/main/TRADEMARKS.md).

## Où trouver de l’aide

La surface de support de Facet est son dépôt : [github.com/wearefacet/facet](https://github.com/wearefacet/facet). Lisez le code source, ouvrez une issue, et lisez les fichiers de licence — [LICENSE](https://github.com/wearefacet/facet/blob/main/LICENSE), [LICENSING.md](https://github.com/wearefacet/facet/blob/main/LICENSING.md), [TRADEMARKS.md](https://github.com/wearefacet/facet/blob/main/TRADEMARKS.md), et [CLA.md](https://github.com/wearefacet/facet/blob/main/CLA.md). La documentation que vous lisez couvre le produit ; le dépôt porte les contrats d’ingénierie derrière lui.

## Voir aussi

- [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) — ce qu’il faut pour l’exécuter.
- [Sécurité et gouvernance](/fr/discover/security/) — les affirmations qu’une revue va vérifier.
- [Déployer en production](/fr/admin/install/production/) — le parcours d’auto-hébergement.
