---
title: Facet vs Retool et les outils low-code
description: "Retool pose des écrans sur des bases que vous gérez déjà. Facet est la couche de données gouvernée : portail, règles par ligne, sans licence par utilisateur."
audience: [evaluator]
features: []
sidebar:
  order: 3
verified_at: bd4be053
---

**En une phrase :** Retool construit des écrans au-dessus de vos données. Facet *est* les données, avec les règles, l’historique et l’hébergement des applications inclus.

## À qui s’adresse cette page

Votre équipe a besoin de panneaux d’administration et d’outils internes. Un développeur a proposé Retool ; quelqu’un d’autre a demandé s’il ne fallait pas d’abord mettre les données en ordre. Cette page sépare les deux travaux, et vous aide à décider lequel est vraiment le vôtre.

## La différence de fond

Retool est une couche UI (interface utilisateur) mature. Vous connectez vos bases de données et vos API, et son éditeur visuel les transforme en panneaux d’administration, en tableaux de bord et en applications internes. Sa page tarifaire dit le modèle sans détour : vos requêtes interrogent vos propres sources de données, et Retool ne stocke pas vos données. Retool propose aussi une base PostgreSQL hébergée et un moteur de workflow, mais le produit central est la couche d’écrans.

Ce modèle suppose que vous avez déjà une base qui vaut la peine de construire dessus : avec un schéma clair, des sauvegardes, et quelqu’un qui en est responsable. Beaucoup d’entreprises de 20 à 200 personnes n’en ont pas. Leurs enregistrements vivent dans des tableurs, et la question de « l’outil interne » est en réalité une question de données.

Facet répond à celle-là. Il porte les données dans PostgreSQL, fait respecter qui peut lire et changer chaque enregistrement, garde l’historique, stocke les fichiers, et héberge les applications que votre équipe utilise. Il livre aussi son propre portail (vues liste, calendrier et kanban, plus une page d’édition par document), généré à partir de modèles que l’assistant écrit. Beaucoup de domaines n’ont besoin d’aucun écran personnalisé.

### L’IA a changé l’économie

L’éditeur de Retool est maintenant assisté par l’IA : décrivez l’application, et il génère un point de départ au format Retool. Avec Facet, n’importe quel outil de code IA construit l’application en JavaScript simple sur le SDK Facet, et la personne qui l’a construite la publie directement dans Facet, sans serveur ni pipeline. Quand les écrans se construisent en un après-midi, l’éditeur cesse d’être la partie qui a de la valeur. Les données du dessous, et les règles qui les protègent, sont ce qui vous reste.

### Qui protège les enregistrements ?

Les journaux d’audit de Retool (offre Business et plus) enregistrent les requêtes exécutées et les actions prises *dans Retool*. L’historique des enregistrements eux-mêmes (qui a changé ce client, quand, et ce qu’il était avant) est laissé à votre base. Il en va de même des règles par enregistrement : si deux applications Retool interrogent la même table, chacune doit les appliquer correctement.

Dans Facet, les deux vivent dans la couche de données. Chaque chemin d’accès (le portail, l’API, vos applications, l’assistant IA, une application Retool qui appelle l’API) passe par le même contrôle de permission et atterrit dans le même historique.

## Face à face

| Dimension | Retool et les outils low-code | Facet |
| --- | --- | --- |
| Objet premier | Un éditeur visuel d’outils internes au-dessus de vos bases et de vos API ; aussi une base PostgreSQL hébergée et des workflows | Un foyer gouverné pour vos données métier, plus les applications qui tournent dessus |
| Qui construit | Des développeurs et des analystes dans un éditeur visuel, sur des sièges builder payants ; un éditeur IA assiste sur chaque offre | Des personnes du métier avec l’assistant de création de domaines ; des applications via n’importe quel outil de code IA ou le SDK. Aucun siège builder |
| Propriété et portabilité des données | Vos bases et vos API gardent les données ; Retool les interroge. Les applications sont stockées au format Retool | Votre propre PostgreSQL ; export/import de domaine, API, webhooks. Les applications sont du JavaScript simple que vous gardez |
| Hébergement et résidence des données | Retool Cloud ; déploiements auto-hébergés et air-gapped sur l’offre Enterprise | Auto-hébergement où vous voulez sur chaque offre, ou hébergement géré à l’emplacement de votre choix |
| Déployer une application | Publiée à l’intérieur de Retool | La personne qui l’a construite la téléverse dans Facet ; chaque version antérieure peut être restaurée |
| Permissions | Des permissions riches à partir de l’offre Business ; des rôles fins sur Enterprise. Les règles par enregistrement vivent dans les requêtes de chaque application ou dans votre base | Des rôles avec périmètres de lignes et étiquettes de champs, appliqués dans la couche de données sur chaque chemin d’accès. Inclus, pas un palier d’offre |
| Audit et historique | Des journaux d’audit à partir de l’offre Business : l’activité de Retool, pas l’historique de vos enregistrements | Journal complet des changements par enregistrement par défaut : qui, quoi, quand ; retour arrière par document. Rétention fixée par vous, globalement ou par document |
| Stockage de fichiers | Par des services de stockage connectés que vous mettez en place | Intégré, sur un stockage compatible S3, sous les mêmes attributions que les enregistrements. Le volume ne dépend que de votre stockage |
| IA | Un éditeur d’applications IA sur toutes les offres ; des crédits IA mutualisés ; votre propre clé de fournisseur sur Enterprise seulement | Assistant intégré et builder sur votre propre clé d’API, tout fournisseur, dès le premier jour ; assistant embarquable pour vos applications ; MCP pour les agents de code. Chaque IA agit dans le rôle de l’utilisateur |
| Logique et automatisation | Des workflows avec quotas d’exécution mensuels, des planifications et des déclencheurs webhook | Hooks de cycle de vie Lua sur les événements de documents dans un domaine ; mises à jour en temps réel ; webhooks pour piloter des outils d’automatisation externes |
| Rapports et analytique | Des tableaux de bord que vous construisez | Aucun graphique intégré ; les lectures BI passent par l’export ou l’API, où les règles de rôles s’appliquent toujours. L’accès direct à la base est un privilège d’administration, en dehors du modèle de rôles |
| Modules métier prêts à l’emploi | Non ; une galerie de modèles | Aucun préconstruit ; l’assistant modélise votre domaine avec vous, ou notre équipe le conçoit |
| Modèle de tarification | Par builder et par mois, plus un tarif par utilisateur interne ; les utilisateurs externes sont facturés à part | Gratuit à l’usage et à l’auto-hébergement (à source disponible, BSL 1.1), pour un nombre d’utilisateurs quelconque ; des services payants seulement si vous le voulez |
| Maturité | Une plateforme mature, une large clientèle et une bibliothèque de connecteurs | Un jeune produit en bêta, un petit écosystème, sur des fondations éprouvées : PostgreSQL, Redis, un journal d’événements |

## Quand Retool est le meilleur choix

- Vous faites déjà tourner PostgreSQL, MySQL, MongoDB ou un ensemble d’API, et ils fonctionnent. Vous avez besoin de panneaux d’administration dessus ce trimestre, pas d’une nouvelle plateforme de données.
- Vous avez des développeurs qui veulent un contrôle au niveau du composant, du JavaScript personnalisé et du SQL direct.
- Vous avez besoin de nombreux connecteurs tiers (Stripe, Salesforce, API REST internes) issus d’une bibliothèque mature, aujourd’hui.
- Vous voulez des workflows et des automatisations planifiées dans le même outil.
- Votre équipe préfère un éditeur visuel au code écrit par l’IA.

## Quand Facet est le meilleur choix

- **Il n’y a pas encore de magasin de données gouverné.** Les enregistrements vivent dans des tableurs, et personne n’est responsable du schéma, des sauvegardes ni des règles au niveau des lignes. Un éditeur d’écrans ne peut pas corriger cela ; une couche de données, si.
- **Beaucoup de personnes utiliseront les outils.** La tarification par utilisateur grandit avec chaque collègue qui ouvre une application. Facet n’a pas de licence par utilisateur.
- **L’historique des enregistrements doit être prouvable** : qui a changé quoi, avec retour arrière, appliqué dans la couche de données plutôt que reconstitué depuis un journal d’activité d’outil.
- **Les données doivent rester sur votre infrastructure**, et l’auto-hébergement ne devrait pas exiger un contrat enterprise.
- **Les personnes qui ont besoin des outils doivent pouvoir les construire et les livrer**, avec un outil IA, sans siège développeur ni pipeline de déploiement.
- **D’autres outils suivront.** Chaque nouvelle application atterrit sur le même magasin gouverné, avec la même connexion, les mêmes rôles et le même audit, donc le deuxième outil coûte moins que le premier.

## Utiliser les deux

Les outils peuvent coopérer : Retool se connecte à des API, et Facet expose une API HTTP.

- **Une application Retool peut lire et écrire dans Facet par l’API.** Chaque appel passe les contrôles de permission de Facet et atterrit dans son historique, donc les règles par enregistrement tiennent quel que soit l’outil à l’origine de la requête. <!-- TODO(link): REST API reference when it is published -->
- **Gardez Retool pour les écrans que vos développeurs maintiennent déjà.** Mettez les nouvelles données gouvernées dans Facet et pointez les requêtes Retool vers son API.
- **Le flux inverse marche aussi.** Les webhooks de Facet préviennent les autres systèmes quand des enregistrements changent.

## Ce que Facet ne fait pas (encore)

Nous préférons vous le dire nous-mêmes :

- **Le portail n’est pas un éditeur d’applications.** Il couvre les vues liste, calendrier, kanban et édition. Un écran taillé pour un workflow précis demande une application personnalisée, construite avec un outil IA ou avec du code.
- **Il n’y a pas d’éditeur visuel.** Les applications personnalisées sont écrites par un outil IA ou par un développeur. Si votre équipe n’utilisera ni l’un ni l’autre, le portail est ce que vous aurez.
- **Il n’y a pas de moteur de workflow inter-domaines.** Les hooks Lua s’exécutent dans un seul domaine. Les workflows qui traversent les domaines, ou les chaînes de validation, s’exécutent dans un outil d’automatisation comme n8n, piloté par les webhooks ou l’API de Facet.
- **Facet est en bêta.** La bibliothèque de connecteurs, l’ensemble de composants et la communauté de Retool sont bien plus vastes aujourd’hui.

## FAQ

**Nous avons déjà PostgreSQL. Facet remplace-t-il Retool ?**
Non, ce sont des couches différentes. Retool construit des écrans au-dessus de votre base existante ; Facet stocke les données elles-mêmes, avec permissions, historique, fichiers et hébergement. Si votre base fonctionne, que vos développeurs en sont responsables et que les règles par enregistrement sont déjà gérées, Retool par-dessus est un choix solide. S’il manque un seul de ces points, commencez par les données.

**Facet peut-il se connecter à nos bases existantes ?**
Pas comme couche vivante : Facet est le magasin, pas une vue sur celui d’un autre. Les données entrent par l’import ou l’API, et à partir de là elles vivent dans le PostgreSQL de Facet, sous ses permissions et son historique. Pendant une transition, un script de synchronisation ou un outil d’automatisation peut alimenter Facet depuis l’ancien système.

**Qui héberge quoi dans chaque configuration ?**
Avec Retool, vous hébergez (ou louez) la base, et Retool Cloud ou votre Retool auto-hébergé sert les applications. Avec Facet, un seul déploiement porte les données, les règles, les fichiers et les applications.

**La tarification par utilisateur est-elle un problème ?**
Cela dépend du nombre de personnes qui utilisent les outils. Retool facture par builder plus un tarif par utilisateur interne. Les journaux d’audit exigent l’offre Business, affichée à $50 par builder et $15 par utilisateur interne et par mois, facturés annuellement. Trois builders et 60 collègues qui utilisent les applications font environ $1 à 050 par mois, avant les utilisateurs externes. Pour une équipe de cinq développeurs, c’est modeste ; pour une entreprise où la plupart du personnel ouvre un outil interne chaque semaine, comptez la ligne utilisateurs avant de vous engager. La licence de Facet ne coûte rien à tout effectif ; vous payez les serveurs, votre propre usage IA et, si vous le voulez, nos services.

**Où l’IA se place-t-elle ?**
Les deux produits ont avancé ici. L’éditeur de Retool génère une application de départ dans son propre format. Avec Facet, l’assistant conçoit le domaine, n’importe quel outil IA construit l’application sur le SDK, et Facet l’héberge. Voir [Facet vs « laisser l’IA tout coder »](/fr/discover/compare/vs-ai-built-apps/).

## Voir aussi

- [Comparer](/fr/discover/compare/) : toutes les pages de comparaison.
- [Facet vs « laisser l’IA tout coder »](/fr/discover/compare/vs-ai-built-apps/)
- [Facet vs Supabase et Firebase](/fr/discover/compare/vs-supabase-firebase/) : quand l’alternative est un backend plutôt qu’un éditeur.
- [Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/) : la façon dont Facet organise les données.
- [Webhooks](/fr/build/model/automation/webhooks/) : la livraison d’événements sortants de Facet.

## Sources

- Retool, page tarifaire : tarification par builder et par utilisateur interne (Team $10/$5, Business $50/$15 en annuel ; Free jusqu’à 5 utilisateurs) ; journaux d’audit et permissions riches à partir de Business ; rôles fins, SSO, SCIM, déploiements auto-hébergés et air-gapped sur Enterprise ; l’éditeur IA et les crédits IA mutualisés sur toutes les offres ; workflows avec quotas d’exécution ; « Your queries run against your own data sources. Retool doesn't store your data. » — https://retool.com/pricing — vérifié le 2026-11-13
- Retool, documentation : le déploiement auto-hébergé géré par Retool est réservé à Enterprise — https://docs.retool.com/self-hosted/retool-managed/concepts — vérifié le 2026-11-13
- Les affirmations sur Facet lui-même viennent de ce site : [Qu’est-ce que Facet](/fr/discover/why-facet/).
