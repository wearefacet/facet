---
title: Facet vs Supabase et Firebase
description: Supabase et Firebase donnent des briques à assembler. Facet livre le résultat gouverné, et votre équipe construit le métier, pas la plomberie.
audience: [evaluator, developer]
features: []
sidebar:
  order: 5
verified_at: bd4be053
---

**En une phrase :** Supabase et Firebase tendent les briques à vos développeurs. Facet livre le bâtiment gouverné et fini, si bien que votre équipe passe son temps sur le métier, pas sur la plomberie.

## À qui s’adresse cette page

Vous choisissez la fondation d’un outil interne ou d’un petit produit. Vos développeurs, ou les outils IA qui les suppléent, mentionnent Supabase ou Firebase. Vous voulez savoir ce que chaque plateforme donne dès le départ, et ce que vous devrez encore concevoir, construire et maintenir vous-même.

## La différence de fond

Supabase et Firebase sont des backends pour développeurs : une base de données, de l’authentification, du stockage de fichiers, des fonctions serveur, une synchronisation en temps réel. Les deux sont matures, avec de grandes communautés, et les deux excellent dans ce qu’ils font. Facet ne cherche pas à être un meilleur backend. Il prend une autre position : l’essentiel de ce qu’exige un outil métier interne (rôles, permissions par enregistrement, historique des changements, interface d’administration, hébergement d’app) arrive en valeurs par défaut gouvernées, pour que personne ne les conçoive de zéro à chaque projet.

Un backend vous donne la liberté de construire n’importe quoi, et l’obligation de tout construire. La différence se voit dans le travail que chaque configuration vous laisse :

- **Permissions.** Dans Supabase, vous écrivez des politiques de sécurité au niveau des lignes (RLS) en SQL ; dans Firebase, vous écrivez des règles de sécurité dans un langage dédié. La configuration sûre n’est pas toujours le chemin par défaut : Supabase active RLS par défaut pour les tables créées dans son éditeur de tableau de bord, mais une table créée dans l’éditeur SQL, par un outil de migration ou par l’API (la route que prennent les agents de code IA) ne l’a pas : il faut activer RLS soi-même. Depuis le 30 mai 2026, les nouveaux projets gardent en plus leur schéma public hors de la Data API par défaut : sans attribution explicite, l’API ne voit pas la table, quel qu’en soit le mode de création. Supabase a réagi avec des avertissements, des alertes et un conseiller de sécurité, et décrit la sécurité comme une responsabilité partagée. Un scan d’octobre 2026 par UpGuard a quand même trouvé 16 326 bases de données Supabase avec des tables lisibles par tous. Dans Facet, les rôles, les périmètres de lignes et les étiquettes de champs sont appliqués dans la couche de données sur chaque chemin d’accès ; il n’y a pas d’état « désactivé » à oublier.
- **Audit.** Un backend n’a pas d’historique des enregistrements tant que personne n’en construit un. Facet enregistre chaque changement (qui, quoi, quand) par défaut, avec retour arrière par document.
- **L’interface d’administration.** Supabase et Firebase vous donnent des consoles pour développeurs. Les personnes qui travaillent chaque jour avec les données ont besoin de vues et de formulaires d’édition ; dans Facet, le portail les fournit, générés à partir de modèles que l’assistant écrit.
- **Hébergement et déploiement des applications.** Dans une configuration Supabase, vous hébergez et déployez le frontend vous-même. Facet héberge les fichiers de vos applications et connecte leurs utilisateurs par OAuth. Celui qui a construit une application peut la publier, et revenir à une version antérieure, sans pipeline.

Firebase ajoute deux sujets à lui seul. Il ne tourne que sur Google Cloud, sans version pour vos propres serveurs. Et la facturation Blaze est par opération (lectures, écritures, invocations de fonctions), avec des alertes de budget qui vous préviennent mais n’arrêtent pas l’usage. Un scan d’internet en 2024 a trouvé 916 sites Firebase mal configurés exposant environ 19,9 millions de mots de passe en clair. La leçon rejoint celle de Supabase : la plateforme vous donne les outils, et la configuration sûre est votre travail.

Pour être juste avec les deux : Supabase est open source, gratuit à auto-héberger, et bâti sur un PostgreSQL standard que vous pouvez exporter. Et quand vous avez besoin d’une logique serveur arbitraire, d’une application grand public, ou des SDK mobiles de Firebase avec synchronisation hors ligne, ces plateformes sont le bon outil. Facet n’est pas un backend applicatif complet.

## Face à face

| Dimension | Supabase et Firebase | Facet |
| --- | --- | --- |
| Objet premier | Des backends pour développeurs : base de données, auth, stockage, fonctions, temps réel | Un foyer gouverné pour les données métier d’une organisation, plus les applications qui tournent dessus |
| Qui construit | Des développeurs, à chaque couche | Des personnes du métier avec l’assistant ; des développeurs par le SDK et MCP |
| Délai jusqu’à un outil gouverné | Des semaines de travail backend : schéma, politiques, audit, écrans d’administration, hébergement | La gouvernance existe dès le premier jour ; vous modélisez le domaine et construisez les écrans |
| Propriété et portabilité des données | Supabase : PostgreSQL standard, auto-hébergeable, exportable. Firebase : modèle de données et API propriétaires, pas d’auto-hébergement | Votre propre PostgreSQL ; export/import de domaine, API, webhooks |
| Hébergement et résidence des données | Supabase dans le cloud ou auto-hébergé (gratuit, via Docker ou CLI) ; Firebase sur Google Cloud seulement | Auto-hébergement où vous voulez, ou hébergement géré à l’emplacement de votre choix |
| Permissions | Vous les concevez et les maintenez : politiques RLS en SQL (Supabase), règles de sécurité (Firebase). Les tables créées hors de l’éditeur de tableau de bord manquent de RLS par défaut ; depuis mai 2026, les nouveaux projets gardent en plus les tables hors de la Data API tant que vous n’avez pas accordé l’accès | Des rôles avec périmètres de lignes et étiquettes de champs, appliqués dans la couche de données sur chaque chemin d’accès. Actifs par défaut, pour chaque enregistrement |
| Audit et historique | Journaux d’audit de l’auth (Supabase, 24 heures à 28 jours selon l’offre) ; l’historique des enregistrements est à construire | Journal complet des changements par enregistrement par défaut : qui, quoi, quand ; retour arrière par document. Rétention fixée par vous, globalement ou par document |
| Interface d’administration | Des consoles pour développeurs | Un portail pour les utilisateurs quotidiens : vues liste, calendrier et kanban, plus une page d’édition par document |
| Stockage de fichiers | Supabase Storage avec ses propres politiques d’accès ; Firebase Cloud Storage avec ses propres règles | Intégré, sur un stockage compatible S3, sous les mêmes attributions que les enregistrements. Le volume ne dépend que de votre stockage |
| Applications personnalisées par-dessus | Vous hébergez et déployez le frontend ; Firebase Hosting pour les applications Firebase | Des applications sur le SDK, connectées par OAuth avec des tokens liés par DPoP. Facet les héberge ; la personne qui a construit une application peut la publier et revenir en arrière |
| IA | Des outils IA côté développeur ; l’IA dans votre application pour vos utilisateurs est à votre charge (fonctions IA de Supabase, Firebase AI Logic) | Assistant intégré et builder sur votre propre clé d’API, tout fournisseur ; assistant embarquable pour vos applications en un appel ; MCP pour les agents de code sous un rôle que vous épinglez. Chaque IA agit dans le rôle de l’utilisateur |
| Logique et automatisation | Edge Functions (Supabase), Cloud Functions (Firebase) : du code serveur arbitraire | Hooks de cycle de vie Lua sur les événements de documents dans un domaine ; mises à jour en temps réel ; webhooks pour piloter des outils d’automatisation externes |
| Rapports et analytique | Rien d’intégré (SQL et les consoles) | Aucun graphique intégré ; les lectures BI passent par l’export ou l’API, où les règles de rôles s’appliquent toujours. L’accès direct à la base est un privilège d’administration, en dehors du modèle de rôles |
| Modules métier prêts à l’emploi | Aucun | Aucun préconstruit pour l’instant ; l’assistant modélise votre domaine avec vous, ou notre équipe le conçoit. Une place de marché de domaines en un clic est prévue |
| Modèle de tarification | Supabase : offre gratuite, Pro à partir de $25 par mois plus l’usage. Firebase : offre Spark gratuite, Blaze au paiement à l’usage facturé par opération. Plus le temps développeur pour construire la gouvernance | Gratuit à l’usage et à l’auto-hébergement (à source disponible, BSL 1.1), pour un nombre d’utilisateurs quelconque ; des services payants seulement si vous le voulez |
| Maturité | De grandes communautés, des outils matures, des années sur le marché | Un jeune produit en bêta, un petit écosystème, sur des fondations éprouvées : PostgreSQL, Redis, un journal d’événements |

## Quand Supabase ou Firebase est le meilleur choix

Ces plateformes brillent quand quatre choses sont vraies en même temps : vous avez une équipe de développement qui sait exactement ce qu’elle veut construire, les flux de données sont lourds, vous avez besoin d’un contrôle profond sur la façon dont les données sont stockées (pour des raisons de performance ou d’architecture), et vous avez le temps d’implémenter et de maintenir vous-même l’ensemble. En particulier :

- **Vos développeurs veulent le contrôle total** : SQL, fonctions, files d’attente, index personnalisés, tout.
- **Le produit sert le public.** Inscriptions grand public, applications mobiles à grande échelle, notifications push, synchronisation hors ligne : Firebase en particulier est construit pour cela, et Facet non. Les comptes Facet viennent d’invitations et du SSO, sans inscription publique en libre-service.
- **Vous avez besoin aujourd’hui d’une logique serveur arbitraire.** La logique de Facet tourne en hooks Lua dans un seul domaine ; tout ce qui dépasse va dans un outil d’automatisation comme n8n, ou dans vos propres services.
- **Vous voulez l’écosystème** : les bibliothèques, les guides et le vivier de recrutement bâtis autour de ces plateformes en dix ans.
- **Supabase précisément :** vous voulez un backend open source sur PostgreSQL standard, auto-hébergé ou dans le cloud, et vous prendrez en charge sa configuration de sécurité.

## Quand Facet est le meilleur choix

- **L’outil sert votre propre personnel**, et les enregistrements (clients, machines, dossiers, contrats) doivent survivre à l’application qui les modifie.
- **Il n’y a pas de développeur backend**, et l’alternative est une application générée par l’IA qui décide de ses propres permissions. Dans Facet, l’application reçoit un token dont les droits sont un sous-ensemble du rôle de l’utilisateur connecté, et la couche de données fait respecter les règles quel que soit le code de l’application.
- **Vous avez des développeurs, mais leur temps vaut plus sur le métier** que passé à reconstruire auth, permissions, audit, écrans d’administration et hébergement pour chaque outil.
- **Quelqu’un demandera qui a changé quoi.** L’historique est là dès le premier enregistrement, avec retour arrière, pas ajouté après le premier incident.
- **L’équipe a besoin d’une interface qui marche dès le premier jour.** Les vues et les pages d’édition du portail viennent avec le produit, pas du sprint d’un développeur.
- **Les personnes qui construisent une application doivent pouvoir la livrer**, sans compte d’hébergement ni pipeline de déploiement.
- **Vous voulez les données, et la possibilité de faire tourner toute la pile, sur votre propre infrastructure**, sans licence par utilisateur ni facture par opération.
- **Vous voulez un seul foyer gouverné qui grandit domaine par domaine**, où chaque nouvel outil réutilise les comptes, les rôles, l’historique et l’hébergement du précédent.

## Utiliser les deux

La séparation est nette, parce que les travaux diffèrent :

- **Gardez Supabase ou Firebase pour le produit grand public ou mobile**, si vous en avez un.
- **Mettez les enregistrements internes et gouvernés dans Facet** : clients, opérations, et les fichiers qui portent des permissions.
- **Connectez-les** par l’API, des webhooks ou des exports. Un webhook Facet peut déclencher vos fonctions Supabase.
- **Faites monter les prototypes.** Si un prototype Supabase a gagné le droit à de vraies données internes, déplacez la couche de données vers Facet et pointez le frontend vers le SDK. Connexion, permissions, historique et hébergement viennent avec le déplacement.

## Ce que Facet ne fait pas (encore)

Nous préférons vous le dire nous-mêmes :

- **Facet n’est pas un backend applicatif complet.** Une logique serveur arbitraire demande toujours vos propres services ; la logique de Facet est du Lua dans un seul domaine.
- **Il n’y a pas de moteur de workflow inter-domaines.** Les workflows inter-domaines et les chaînes de validation tournent dans un outil d’automatisation comme n8n, piloté par les webhooks ou l’API de Facet.
- **Facet sert une seule organisation.** Il n’y a pas d’inscription publique en libre-service, donc un produit B2C colle mal.
- **Facet est en bêta.** Les écosystèmes, la documentation et les communautés de Supabase et Firebase sont bien plus vastes aujourd’hui.

## FAQ

**Nous avons des développeurs. Pourquoi choisir Facet ?**
Pour la même raison que vous utilisez un framework plutôt que des sockets bruts : de bonnes valeurs par défaut. Facet livre l’identité, les permissions, l’audit, les fichiers et l’hébergement des applications, appliqués dans la couche de données, si bien que vos développeurs passent leur temps sur ce qui est propre à votre métier. Si votre équipe sait exactement ce dont elle a besoin, gère des flux de données lourds, a besoin d’un contrôle de bas niveau sur le stockage, et a le temps de construire et de maintenir le reste, Supabase colle très bien.

**Facet remplace-t-il Supabase ?**
Non. Supabase est un backend pour des applications que vous développez ; Facet est un foyer gouverné pour les données métier, avec des applications dessus. Ils cohabitent bien : le produit grand public sur Supabase, les enregistrements internes dans Facet, connectés par l’API.

**Mes données sont-elles enfermées ?**
Non. Les données de Facet vivent dans votre PostgreSQL, exportables par l’API et les exports de domaines, et vous pouvez faire tourner toute la pile vous-même. Sur Firebase, le modèle de données et les API sont propriétaires, et partir signifie réécrire la couche de données.

**Firebase est gratuit au départ. Et Facet ?**
Facet est gratuit à l’usage et à l’auto-hébergement, à toute échelle ; vous payez vos serveurs. L’offre gratuite de Firebase est généreuse, mais l’offre Blaze facture par opération, et une requête inefficace devient une facture récurrente sans plafond de dépense strict.

**Quelle plateforme est la plus sûre ?**
C’est la mauvaise question : les trois vous donnent les outils. La vraie question est ce qui arrive quand personne ne les configure correctement, et les scans ci-dessus montrent la réponse à l’échelle. Le pari de Facet est que les permissions et l’audit doivent être le plancher, pas une tâche de configuration.

## Voir aussi

- [Comparer](/fr/discover/compare/) : toutes les pages de comparaison.
- [Facet vs « laisser l’IA tout coder »](/fr/discover/compare/vs-ai-built-apps/) : là où l’histoire des Supabase mal configurés rencontre les applications construites par l’IA.
- [Sécurité et gouvernance](/fr/discover/security/)
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)
- [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) : y compris les charges de travail qui demandent un contrôle de plus bas niveau.

## Sources

- Supabase, page tarifaire : Free, Pro à partir de $25 par mois plus l’usage, Team $599 par mois ; auto-hébergement gratuit via Docker ou CLI ; fenêtres du journal d’audit d’auth selon l’offre ; SOC 2 et ISO 27001 à partir de Team — https://supabase.com/pricing — vérifié le 2026-11-13
- UpGuard, « Everything Everywhere: Systemic Data Exposure in Supabase Apps » (octobre 2026) : 16 à 326 bases avec tables lisibles sur environ 300 à 000 domaines ; RLS par défaut seulement pour les tables créées dans l’éditeur de tableau de bord, pas par l’API — https://www.upguard.com/blog/everything-everywhere-systemic-data-exposure-in-supabase-apps — vérifié le 2026-11-13
- Supabase, rétrospective sécurité 2025 : valeurs par défaut de RLS, avertissements et Security Advisor ; la sécurité décrite comme une responsabilité partagée — https://supabase.com/blog/supabase-security-2025-retro — vérifié le 2026-11-13
- Supabase, « Securing your API » (docs) : RLS par défaut pour les tables créées dans le tableau de bord, à activer soi-même pour l’éditeur SQL et les autres outils ; une table reste hors de la Data API tant qu’aucun privilège n’est accordé à un rôle dessus ; la valeur par défaut de la plateforme évolue vers une exposition sur accord explicite pour les nouveaux objets — https://supabase.com/docs/guides/api/securing-your-api — vérifié le 2026-11-20
- Open Source Alternatives, sur Supabase comme open source et auto-hébergeable sur PostgreSQL standard — https://www.opensourcealternatives.to/blog/supabase-vs-firebase — vérifié le 2026-11-13 (l’affirmation d’auto-hébergement figure aussi sur https://supabase.com/pricing)
- Firebase, page tarifaire : Spark (sans coût) et Blaze (paiement à l’usage, facturé par opération : lectures de documents, écritures, invocations de fonctions, egress) — https://firebase.google.com/pricing — vérifié le 2026-11-13
- Appwrite (un concurrent de Firebase, à prendre comme contexte), sur l’absence d’auto-hébergement de Firebase et le coût du départ — https://appwrite.io/blog/post/firebase-vs-open-source-tradeoffs — vérifié le 2026-11-13
- Verdent, sur les alertes de budget de Firebase qui n’arrêtent pas l’usage — https://www.verdent.ai/guides/devtools/firebase-pricing — vérifié le 2026-11-13
- Malwarebytes, sur le scan de 2024 : 916 sites Firebase mal configurés et 19,9 millions de mots de passe en clair — https://www.malwarebytes.com/pt/blog/personal/2024/03/19-million-plaintext-passwords-exposed-by-incorrectly-configured-firebase-instances — vérifié le 2026-11-13
- Les affirmations sur Facet lui-même viennent de ce site : [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) et la [vue d’ensemble Sécurité et gouvernance](/fr/discover/security/).
