---
title: Facet vs Odoo et les suites ERP
description: Odoo livre des processus métier tout faits, auxquels vous vous adaptez. Facet part de vos processus, gouvernance incluse. Souvent, les deux se complètent.
audience: [evaluator]
features: []
sidebar:
  order: 4
verified_at: bd4be053
---

**En une phrase :** un ERP fait tourner les processus que toutes les entreprises partagent : comptabilité, facturation, paie. Facet fait tourner ceux qui rendent votre entreprise différente. Beaucoup d’entreprises ont besoin des deux.

## À qui s’adresse cette page

Votre entreprise a dépassé les tableurs, et quelqu’un a proposé une suite ERP (un logiciel de gestion intégré) comme Odoo. Vous vous demandez si un seul système intégré doit tout porter, y compris les processus qui rendent votre entreprise différente. Cette page trace la ligne, et montre de quel côté chaque chose se place.

## La différence de fond

Un ERP vous donne des processus tout faits, et vous adaptez votre métier à eux. Le catalogue d’Odoo est large et bien intégré : comptabilité, facturation, stocks, fabrication, CRM, RH, paie, site web, point de vente. L’édition Community est open source et gratuite à auto-héberger ; l’édition Enterprise ajoute des applications, des fonctions et des services sous un abonnement par utilisateur.

Facet part de l’autre bout : votre processus, pas un modèle de processus. Vous modélisez vos propres domaines (les types de documents, les champs, les rôles et les vues que votre opération utilise vraiment) avec l’assistant IA ou avec notre équipe. La gouvernance est incluse : des permissions jusqu’aux lignes et aux champs, un historique complet des changements, le retour arrière, et un stockage de fichiers sous les mêmes règles.

### Là où le coût se cache : la personnalisation

Les deux approches se rejoignent là où votre métier cesse de ressembler au modèle.

Dans Odoo, l’offre Custom débloque Studio (personnalisation sans code), l’API externe, le multi-sociétés et les modules personnalisés ; l’offre Standard n’exécute aucun code personnalisé. Chaque écart que vous construisez devient du code que vous portez à chaque montée de version. Les partenaires d’Odoo estiment les coûts de mise à niveau en milliers, poussés par les personnalisations plutôt que par le volume de données.

Dans Facet, votre modèle est des données, pas du code. Les domaines sont versionnés et publiés depuis des brouillons, et le modèle lui-même n’a pas de tapis roulant de mises à niveau. Changer un champ ou ajouter un type de document est ce que l’assistant fait avec vous dans le produit, pas un module qu’un partenaire écrit et maintient.

### Là où le coût grandit : l’effectif

Odoo est facturé par utilisateur et par mois, avec un tarif promotionnel la première année qui se renouvelle plus haut, et des prix qui varient selon le pays. Studio et l’API se trouvent sur l’offre Custom, et ce tarif supérieur s’applique à chaque utilisateur, pas seulement à ceux qui ont besoin de personnalisation. Facet n’a pas de licence par utilisateur : vous payez les serveurs, votre propre usage IA, et nos services si vous le voulez.

## Face à face

| Dimension | Odoo et les suites ERP | Facet |
| --- | --- | --- |
| Objet premier | Une suite métier intégrée : comptabilité, stocks, CRM, RH, fabrication, site web, point de vente | Un foyer gouverné pour vos données opérationnelles, plus les applications qui tournent dessus |
| Qui construit | L’éditeur livre les processus ; le personnel et les partenaires configurent ; Studio (offre Custom) et des modules Python personnalisent | Vous modélisez vos domaines avec l’assistant IA, ou notre équipe le fait avec vous |
| Propriété et portabilité des données | Odoo Online (hébergé, avec téléchargement de sauvegarde de la base) ; Community en auto-hébergement ; offre Custom : sur site ou Odoo.sh | Votre propre PostgreSQL ; export/import de domaine, API, webhooks |
| Hébergement et résidence des données | Odoo Online, Odoo.sh, ou auto-hébergé (Community, ou offre Custom) | Auto-hébergement où vous voulez, ou hébergement géré à l’emplacement de votre choix |
| Permissions | Des droits d’accès par application et des règles d’enregistrement, configurés par modèle | Des rôles avec périmètres de lignes et étiquettes de champs, appliqués dans la couche de données sur chaque chemin d’accès |
| Audit et historique | Un suivi des changements sur les champs que chaque module choisit de suivre ; une piste d’audit complète demande un module additionnel | Journal complet des changements sur chaque enregistrement par défaut : qui, quoi, quand ; retour arrière par document. Rétention fixée par vous, globalement ou par document |
| Stockage de fichiers | Des pièces jointes sur les enregistrements ; l’application Documents sur les offres payantes | Intégré, sur un stockage compatible S3, sous les mêmes attributions que les enregistrements. Le volume ne dépend que de votre stockage |
| Changer le modèle | Studio sur l’offre Custom, ou des modules Python personnalisés portés à chaque mise à niveau | Des domaines versionnés, édités en brouillons avec l’assistant puis publiés ; aucun code à migrer |
| Applications personnalisées par-dessus | Le créateur de site web et le portail ; tout le reste est un module personnalisé | Toute application que votre outil IA construit, sur le SDK, connectée par OAuth. Facet l’héberge ; la personne qui l’a construite peut la publier et revenir en arrière |
| IA | Une IA agentique sur l’offre Custom | Assistant intégré et builder sur votre propre clé d’API, tout fournisseur ; assistant embarquable pour vos applications ; MCP pour les agents de code. Chaque IA agit dans le rôle de l’utilisateur |
| Logique et automatisation | Des règles d’automatisation ; des modules personnalisés | Hooks de cycle de vie Lua sur les événements de documents dans un domaine ; mises à jour en temps réel ; webhooks pour piloter des outils d’automatisation externes |
| Rapports et analytique | Des rapports dans chaque application, la comptabilité en particulier | Aucun graphique intégré ; les lectures BI passent par l’export ou l’API, où les règles de rôles s’appliquent toujours. L’accès direct à la base est un privilège d’administration, en dehors du modèle de rôles |
| Modules métier prêts à l’emploi | Oui : c’est le cœur du produit | Aucun préconstruit pour l’instant ; vous modélisez ce qui vous est propre. Une place de marché de domaines en un clic, avec leurs applications et leurs rôles, est prévue |
| Modèle de tarification | Par utilisateur et par mois ; One App Free, Standard, Custom ; première année promotionnelle ; prix selon le pays | Gratuit à l’usage et à l’auto-hébergement (à source disponible, BSL 1.1), pour un nombre d’utilisateurs quelconque ; des services payants seulement si vous le voulez |
| Maturité | Une suite mature, un large réseau de partenaires | Un jeune produit en bêta, un petit écosystème, sur des fondations éprouvées : PostgreSQL, Redis, un journal d’événements |

## Quand Odoo est le meilleur choix

- Vous avez besoin de comptabilité, de facturation ou de paie avec les règles fiscales locales. C’est le terrain naturel d’un ERP ; Facet n’en a aucun.
- Vos processus sont standards (du devis à la commande à la facture, entrées et sorties de stock) et un flux prêt à l’emploi colle sans chirurgie.
- Vous voulez une suite intégrée, un seul éditeur à appeler, et un réseau de partenaires pour le déploiement (Odoo confie les déploiements de taille moyenne à ses partenaires).
- Votre équipe veut des applications mobiles prêtes, du e-commerce et du point de vente, pas une plateforme à façonner.
- L’édition Community plus un partenaire couvre une installation standard avec un petit budget.

## Quand Facet est le meilleur choix

- **Votre processus central est inhabituel** : une opération de maintenance, un catalogue avec ses propres règles, un workflow terrain qu’aucun module ne couvre. L’intégrer à un ERP signifie un module personnalisé que vous portez à chaque mise à niveau.
- **L’ERP gère déjà la finance, mais les données opérationnelles autour ne rentrent pas.** Les enregistrements qualité, le matériel, les dossiers clients et la planification vivent dans des tableurs, sans permissions ni historique.
- **Des personnes différentes doivent voir des enregistrements et des champs différents**, et un auditeur peut demander qui a changé quoi.
- **Vous voulez que la partie sur mesure soit des données** (versionnées, publiables, portables) plutôt que du code sur un tapis roulant de mises à niveau.
- **Votre équipe veut des écrans taillés pour son travail.** Elle les construit avec un outil IA et les publie sur Facet, sans projet partenaire ni module à maintenir.
- **L’effectif grandit**, et l’outil ne devrait pas coûter plus cher à chaque embauche.

## Utiliser les deux

C’est la configuration la plus courante pour les entreprises qui font déjà tourner un ERP :

- **Gardez l’ERP pour la finance** et les processus standards qu’il réussit bien.
- **Mettez les domaines opérationnels spécifiques dans Facet** : le catalogue, les opérations terrain, les enregistrements qualité, les dossiers clients.
- **Connectez les deux** par l’API externe d’Odoo, l’API de Facet, des webhooks, ou un export planifié. Un export Odoo peut amorce un domaine Facet ; un webhook Facet peut prévenir l’ERP quand un enregistrement change.
- **Donnez à chaque fait un seul foyer.** Évitez de garder le même enregistrement dans les deux systèmes ; laissez l’un référencer l’autre.

Déplacez un domaine à la fois. Chacun reprend les mêmes comptes, rôles, historique et fichiers que le précédent, donc chaque déplacement coûte moins que le précédent.

## Ce que Facet ne fait pas (encore)

Nous préférons vous le dire nous-mêmes :

- **Aucun module métier préconstruit pour l’instant** : ni CRM, ni comptabilité, ni stocks, ni RH. Aujourd’hui, vos domaines sont modélisés pour vous, ce qui prend du temps de conception au départ. L’assistant le raccourcit ; notre équipe peut le prendre en charge. Une place de marché est prévue : des domaines prêts à l’emploi (CRM B2B et B2C, RH et plus) qui s’installent en un clic, avec leurs applications et leurs rôles, et que vous adaptez ensuite comme n’importe quel domaine à vous.
- **Il n’y a pas de moteur de workflow inter-domaines.** Les hooks Lua s’exécutent dans un seul domaine. Les workflows qui traversent les domaines, ou les chaînes de validation, s’exécutent dans un outil d’automatisation comme n8n, piloté par les webhooks ou l’API de Facet.
- **Aucun rapport intégré.** Les rapports par application d’Odoo existent aujourd’hui ; avec Facet, vous exportez ou branchez un outil BI par l’API.
- **Facet est en bêta.** La maturité d’Odoo, son réseau de partenaires et sa comptabilité localisée sont de vrais avantages que Facet n’égale pas.

## FAQ

**Facet fait-il la comptabilité ?**
Pas aujourd’hui. Facet n’a ni comptabilité, ni facturation, ni paie, ni localisation fiscale ; pour cela, utilisez un ERP. Facet est fait pour les domaines opérationnels autour. Des domaines prêts à l’emploi sont sur la feuille de route (voir plus bas), mais si vous avez besoin d’une comptabilité maintenant, un ERP est la bonne réponse.

**Facet deviendra-t-il un ERP ?**
À sa façon. Le plan est une place de marché de domaines prêts à l’emploi (CRM B2B ou B2C, RH et plus), chacun installé en un clic avec ses applications et ses rôles. La différence avec un ERP classique est ce qui vient ensuite : un domaine installé est des données, donc vous l’adaptez avec l’assistant comme tout ce que vous construisez vous-même, sans module personnalisé à porter de version en version. En attendant qu’un module dont vous avez besoin sorte, jugez Facet sur ce qu’il fait aujourd’hui.

**Nous faisons déjà tourner Odoo. Où Facet se place-t-il ?**
Autour. Les entreprises gardent typiquement Odoo pour la finance et les flux standards, et déplacent les données opérationnelles spécifiques (celles qui deviendraient sinon des modules Odoo personnalisés) dans des domaines Facet, connectés par l’API ou des webhooks.

**Faut-il personnaliser Odoo ou modéliser le processus dans Facet ?**
Comptez le coût de la personnalisation sur toute sa vie, pas seulement son coût de construction. Un module Odoo personnalisé doit être revalidé à chaque montée de version, et le coût de mise à niveau grandit avec la personnalisation. Il exige en plus l’offre Custom pour chaque utilisateur. Un domaine Facet est des données : il survit aux changements de version, vous pouvez l’exporter, et l’assistant peut le changer avec vous.

**Lequel adopter en premier ?**
Si la comptabilité et les processus standards font mal, l’ERP vient en premier. Si la douleur est des données opérationnelles spécifiques qui demandent permissions et historique, Facet peut venir en premier, et l’ERP rejoindre plus tard par l’API.

**Facet importe-t-il les données d’Odoo ?**
Oui, par l’export ou l’API externe d’Odoo. L’import se mappe sur votre modèle de domaine Facet ; il n’y a pas de connecteur Odoo prêt à l’emploi aujourd’hui, donc prévoyez la correspondance, ou laissez notre équipe la mener.

## Voir aussi

- [Comparer](/fr/compare/) : toutes les pages de comparaison.
- [Facet vs « laisser l’IA tout coder »](/fr/compare/vs-ai-built-apps/)
- [Facet vs les bases Airtable et Notion](/fr/compare/vs-airtable-notion/) : le bout le plus léger de la même question.
- [Domaines, brouillons et éditeurs de domaines](/fr/build/domains-drafts-editors/) : la façon dont Facet modélise vos processus.
- [Partager entre domaines](/fr/build/sharing-across-domains/) : la réplication contrôlée de champs entre domaines.

## Sources

- Odoo, éditions : deux versions, Community (open source) et Enterprise (sous licence), avec la comparaison fonction par fonction — https://www.odoo.com/page/editions — vérifié le 2026-11-13
- Odoo, page tarifaire : offres One App Free, Standard et Custom ; prix US ($24.90 la première année, puis $31.10 par utilisateur et par mois sur Standard, facturation annuelle) ; l’offre Custom porte Studio, l’API externe, les modules personnalisés, le multi-sociétés, Odoo.sh et l’hébergement sur site ; conditions de la remise de première année ; les déploiements des grandes entreprises passent par les partenaires ; les prix varient selon le pays depuis lequel on visite le site, pas selon l’adresse de facturation — https://www.odoo.com/pricing — vérifié le 2026-11-20
- Les chiffres de coût de mise à niveau d’Odoo sont des estimations de partenaires, pas des chiffres de l’éditeur : Ventor, sur un coût de mise à niveau poussé par les personnalisations — https://ventor.tech/services/odoo-upgrade/ — et Ecosire, sur les fourchettes de coût de migration de version — https://ecosire.com/blog/odoo-migration-v17-to-v18-guide — vérifié le 2026-11-13
- Activepieces, sur Studio et l’API externe qui exigent l’offre Custom ; la comparaison des offres elle-même se trouve sur https://www.odoo.com/pricing — https://www.activepieces.com/blog/odoo-pricing-2026-plans-hosting-and-implementation — vérifié le 2026-11-13
- Les affirmations sur Facet lui-même viennent de ce site : [Domaines, brouillons et éditeurs de domaines](/fr/build/domains-drafts-editors/).
