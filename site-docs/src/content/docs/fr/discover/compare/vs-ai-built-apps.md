---
title: 'Facet vs « laisser l’IA tout coder »'
description: L’IA peut construire l’outil de votre équipe en un après-midi. Continuez. Voici sur quoi il doit reposer avant que vos données et vos collègues n’en dépendent.
audience: [evaluator, developer]
features: []
sidebar:
  order: 1
verified_at: bd4be053
---

**En une phrase :** gardez le vibe coding. L’IA seule construit l’application *et* tout ce qui se trouve dessous, et le même chantier se repose pour chaque application. L’IA sur Facet ne construit que les écrans, sur des données qui restent protégées et qui survivent à l’application.

## À qui s’adresse cette page

Vous dirigez une organisation de 20 à 200 personnes, ou vous y travaillez. Quelqu’un de votre équipe, parfois sans aucune expérience de la programmation, vient de vous montrer un outil qui fonctionne, construit par une IA en un après-midi : un suivi de devis, un journal de maintenance, un pipeline de recrutement. Il marche, et des collègues veulent déjà l’utiliser.

Cette page vous aide à décider sur quoi cet outil doit reposer avant que des données réelles et de vrais collègues n’en dépendent.

## La différence de fond

Commençons par ce qui est vrai : l’IA peut construire un outil métier fonctionnel en quelques heures. Construire l’application n’est plus la partie difficile, et Facet ne vous demande pas d’arrêter.

Cette page ne compare pas l’IA à une plateforme. Dans les deux colonnes, c’est l’IA qui construit. La question est de savoir sur quoi l’application repose : sur son seul code généré, ou sur une couche gouvernée en dessous.

Un outil que plusieurs personnes utilisent chaque semaine exige plus que des écrans :

- une connexion pour chaque personne, avec une réinitialisation de mot de passe qui fonctionne ;
- des rôles, pour qu’un stagiaire ne voie pas les salaires ;
- un contrôle par enregistrement, pour qu’une liste de clients ne devienne pas publique parce qu’un lien a été partagé ;
- un historique de qui a changé quoi, et un moyen de l’annuler ;
- des sauvegardes ;
- un emplacement pour les fichiers, avec les mêmes règles d’accès que les enregistrements ;
- l’hébergement, TLS (le cadenas dans le navigateur), les mises à jour et les correctifs de sécurité ;
- quelqu’un qui comprend encore tout cela quand l’auteur d’origine est parti.

Une application générée par l’IA reconstruit cette liste pour son propre compte à chaque projet, le plus souvent en partie, et personne ne vérifie quelle partie elle a sautée. Chaque application nouvelle est un élément de plus à déployer, héberger, corriger et expliquer, et la personne qui l’a demandée ne peut généralement rien faire de tout cela seule. La dixième application coûte autant de plomberie que la première.

### Ce que dit la recherche

Le code écrit par l’IA fonctionne, mais il doit être vérifié. Une étude Veracode de 2025, portant sur plus de 100 modèles de langage, a montré que, face à une façon sécurisée et une façon non sécurisée d’écrire le même code, les modèles choisissaient la façon non sécurisée dans 45 % des tâches, et les modèles plus grands ou plus récents ne faisaient pas mieux. D’autres travaux ont montré que des instructions de sécurité explicites dans le prompt améliorent les résultats. Un utilisateur métier ne sait pas quelles instructions donner.

Le schéma se retrouve à grande échelle. En octobre 2026, UpGuard a analysé environ 300 à 000 domaines et trouvé 16 à 326 bases de données Supabase dont les tables étaient lisibles par tous ; plus de la moitié présentaient des indices de données personnelles. Conclusion des chercheurs : ces applications sont construites par des agents de code, et les personnes qui les portent ignorent comment la base est configurée. Dans une base exposée, un service de coaching à l’immigration stockait des noms de clients à côté de mots de passe en clair. En février 2026, le backend Supabase derrière un réseau social d’agents IA a laissé fuir 35 à 000 adresses e-mail et 1,5 million de tokens d’API (découvert par Wiz).

Rien de tout cela ne dit que l’IA a construit une mauvaise application. Cela dit qu’une application générée ne doit pas être celle qui décide qui peut lire quel enregistrement. Ce travail revient à la couche du dessous : construite une fois, testée une fois, et partagée par chaque application que vous créez.

<!-- d2
prompt: "You describe the tool" {class: external}
build: "The AI writes the app"
choice: "What does it stand on?" {class: decision}
justAI: "Login, roles, audit, files, hosting rebuilt per app" {class: warn}
facet: "OAuth sign-in, rights subset of your role"
enforce: "Facet enforces permissions, history, files"
records: "Records outlive the app" {class: ok}

prompt -> build
build -> choice
choice -> justAI: Just AI
choice -> facet: AI on Facet
facet -> enforce
enforce -> records
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9ba49688-light.svg" alt="You describe the tool" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9ba49688-dark.svg" alt="You describe the tool" loading="lazy" />
</div>

## Face à face

| Dimension | IA seule | Frontend IA + Facet |
| --- | --- | --- |
| Objet premier | Ce que le prompt demandait | La même application, posée sur des données gouvernées |
| Qui construit quoi | Vous et l’IA, à chaque couche : données, permissions, écrans, hébergement | L’IA écrit les écrans ; Facet fournit déjà les données, les droits, l’historique et l’hébergement |
| Propriété et portabilité des données | Là où l’IA l’a posée : base générée, tableur, fichiers sur un ordinateur portable | Votre propre PostgreSQL ; export/import de domaine, API, webhooks |
| Hébergement et résidence des données | Vous l’hébergez, ou elle vit sur un forfait gratuit quelque part | Auto-hébergé (un petit déploiement tient sur 2 vCPU et 2–4 Go de RAM), ou hébergement géré à l’emplacement de votre choix |
| Déploiement de l’application | Un serveur, un pipeline, un domaine, un certificat, et quelqu’un qui sait comment tout s’assemble | Téléversez les fichiers construits dans Facet. Ni serveur, ni pipeline ; chaque version antérieure peut être restaurée |
| Permissions | Ce qui a été généré, s’il y en a, et rarement relu | Des rôles avec des attributions par ligne et par champ, appliqués dans la couche de données sur chaque chemin d’accès |
| Audit et historique | Seulement si quelqu’un l’a demandé, et différent dans chaque application | Chaque changement enregistré par défaut : qui, quoi, quand ; retour arrière sur n’importe quel document |
| Stockage de fichiers | Au cas par cas : disque local, ou bucket cloud avec ses propres règles | Intégré, sur un stockage compatible S3, sous les mêmes attributions que les enregistrements |
| Applications personnalisées | C’est l’application elle-même | Votre application vibe-codée sur le SDK, connectée par OAuth ; Facet héberge ses fichiers |
| IA | Un seul constructeur ; l’IA dans l’application est votre problème | Le même constructeur, plus un assistant intégré, un assistant embarquable pour vos applications, et MCP pour les agents de code — le tout lié au rôle de l’utilisateur |
| Logique et automatisation | Ce qui a été généré, pour chaque application | Des scripts Lua dans un domaine ; des mises à jour en temps réel ; des webhooks |
| Rapports et analytique | Seulement si cela a été prévu | Aucun tableau de bord intégré ; les lectures BI passent par l’export ou l’API, où les règles de rôles s’appliquent toujours. L’accès direct à la base est un privilège d’administration, en dehors du modèle de rôles |
| Modules métier prêts à l’emploi | Non | Aucun préconstruit ; l’assistant intégré modélise votre domaine avec vous, ou notre équipe le conçoit |
| Coût | Tokens de modèle, puis hébergement, TLS, maintenance et votre temps, pour chaque application | Gratuit à l’usage et à l’auto-hébergement (à source disponible, BSL 1.1) ; vous apportez votre propre clé IA ; des services payants seulement si vous le voulez |
| Maturité | Chaque application part de zéro | Un produit en bêta sur des fondations éprouvées : PostgreSQL, Redis, un journal d’événements |

## Quand l’IA seule est le meilleur choix

Utilisez l’IA seule, sans rien en dessous, quand :

- l’outil est jetable : une démo pour vendredi, une expérience pour apprendre ce dont vous avez vraiment besoin ;
- une seule personne l’utilise, donc aucun rôle à modéliser ;
- rien de sensible n’y entre, et perdre les données coûte une reconstruction, pas une fuite ;
- personne ne comptera dessus dans six mois.

Le jour où l’un de ces points cesse d’être vrai, l’outil a gagné le droit à des fondations.

## Quand l’IA sur Facet est le meilleur choix

- **Plusieurs personnes comptent sur l’outil chaque semaine**, et les enregistrements doivent survivre à l’application. Un client reste un client, quel que soit l’outil qui modifie l’enregistrement.
- **Des personnes différentes doivent voir des enregistrements différents** : salaires, listes de clients, clauses de contrat.
- **Quelqu’un demandera qui a changé quoi, et quand** : un auditeur, un client, un responsable ou un régulateur. Si l’outil détient des données personnelles sur des clients ou du personnel dans l’UE, le RGPD s’y applique, quel que soit l’auteur du code.
- **Les fichiers vont avec les enregistrements** : contrats, photos, pièces d’identité.
- **Vous voulez continuer à construire avec l’IA** sans reconstruire la plomberie à chaque fois.
- **La personne qui construit l’outil doit pouvoir le livrer.** Ni serveur, ni pipeline, ni ticket à l’informatique : l’utilisateur métier qui a décrit l’application peut la déployer, puis revenir en arrière.
- **Vous prévoyez plus d’un outil.** La première application met en place les comptes, les rôles, l’audit, les fichiers et l’hébergement. Chaque application suivante part de ce qui existe, donc chacune est plus rapide et moins coûteuse que la précédente.

## Utiliser les deux : prototyper avec l’IA, livrer sur Facet

Les deux colonnes ne sont pas rivales ; l’une grandit vers l’autre.

Continuez à prototyper avec votre outil IA. Quand un prototype gagne le droit à des données réelles, pointez-le vers Facet :

1. Un administrateur enregistre l’application dans Facet. L’application connecte ses utilisateurs par OAuth (un standard ouvert d’autorisation) : elle ne voit ni ne stocke jamais un mot de passe, et vous ne construisez jamais d’écran de connexion.
2. L’application reçoit un token lié par DPoP : un token attaché à la clé propre de l’application, si bien qu’un token copié échoue partout ailleurs. Ses droits restent toujours un sous-ensemble du rôle de l’utilisateur connecté.
3. Votre outil IA construit les écrans sur le SDK Facet (kit de développement logiciel). Facet héberge les fichiers finis : pas d’hébergement séparé, pas de pipeline de déploiement. Celui qui a construit l’application peut la publier, et restaurer une version antérieure si une nouvelle casse. <!-- TODO(link): custom-apps and SDK pages when the apps section ships -->
4. Un appel ajoute l’assistant embarquable à l’application. Il hérite du rôle de l’utilisateur connecté et n’agit qu’à l’intérieur de ce rôle.

Des agents de code peuvent aussi se connecter à Facet par MCP (Model Context Protocol, un standard qui permet aux outils IA d’appeler les fonctions d’un produit) et travailler sous un rôle unique que vous épinglez. Facet vérifie chaque appel, quel que soit l’auteur du code. Voir [Qu’est-ce que Facet](/fr/discover/why-facet/).

Gardez les prototypes jetables à l’écart de l’espace gouverné. Facet entre en jeu quand les données méritent d’être gouvernées.

De làà, grandissez domaine par domaine. Un domaine est une tranche du métier : les clients, le matériel, le recrutement. La gouvernance que vous mettez en place une fois (comptes, rôles, historique, fichiers) est celle qu’utilise chaque domaine suivant. Un seul foyer gouverné pour vos données, un facet par tranche du métier.

## Ce que Facet ne fait pas (encore)

Nous préférons vous le dire nous-mêmes :

- **Facet est en bêta.** L’écosystème, la communauté et les intégrations tierces restent petits.
- **La logique reste bornée à un domaine.** Les scripts Lua s’exécutent dans un domaine. Les workflows qui traversent les domaines, ou les chaînes de validation, s’exécutent dans un outil d’automatisation comme n8n, piloté par les webhooks ou l’API de Facet.
- **Aucun rapport intégré.** Exportez les données, ou connectez un outil BI (business intelligence) par l’API.
- **Facet n’est pas un backend applicatif complet.** Une logique serveur sur mesure et complexe demande toujours vos propres services.
- **Facet gouverne les données, pas les écrans.** Il ne relit pas le code écrit par l’IA, donc une interface générée peut rester maladroite ou fausse. Ce qu’il garantit : un écran maladroit ne peut ni lire ni modifier des données que l’utilisateur n’a pas le droit de toucher.

## FAQ

**L’IA sait aussi écrire la connexion et les permissions. Pourquoi une plateforme ?**
Elle le peut, et parfois elle le fait bien. Mais chaque application les réimplémente, chaque implémentation porte son propre risque, et vous maintenez tout cela pour toujours. Dans Facet, les règles appartiennent aux données, pas à une application en particulier. Supprimez l’application : les règles, l’historique et les enregistrements restent.

**Que reste-t-il à l’IA dans cette configuration ?**
Les écrans. Facet détient l’identité, les permissions, l’audit, les fichiers et l’hébergement. L’IA écrit sur le SDK, et elle ne peut pas s’attribuer des droits.

**L’assistant voit-il tout ?**
Non. L’assistant intégré et l’assistant embarquable agissent dans les permissions de l’utilisateur courant ; les agents de code se connectent par MCP sous un rôle unique que vous épinglez. Vous apportez votre propre clé d’API de modèle, donc vous choisissez aussi le fournisseur.

**Et si l’application générée s’avère mauvaise ?**
Jetez-la. Les données, les rôles et l’historique demeurent. Construisez la version deux sur la même fondation. C’est là tout l’enjeu : les apps sont jetables désormais, vos données ne le sont pas.

**Une personne qui n’est pas développeuse peut-elle déployer et mettre à jour l’application ?**
Oui, et c’est sûr par conception. Facet sert lui-même les fichiers de l’application, donc publier une nouvelle version ne demande ni serveur ni pipeline. L’application peut changer autant que son propriétaire le veut ; le modèle de données, les permissions et l’historique ne sont pas touchables depuis l’application. Si une version s’avère cassée, restaurez la précédente. Le pire cas est un mauvais écran pendant quelques minutes, jamais une fuite de données ni un enregistrement perdu.

**Qui maintient tout cela après la mise en service ?**
Pour l’application : personne, au-del à des écrans eux-mêmes. L’hébergement, TLS, la connexion, les permissions, les sauvegardes et les correctifs de sécurité vivent dans Facet et sont maintenus une seule fois pour toutes les applications qui s’y posent — par vous si vous vous auto-hébergez, ou par nous avec l’hébergement géré.

**Nous enfermons-nous ?**
Moins qu’avec une application générée. Vos enregistrements vivent dans un PostgreSQL standard, sur votre propre serveur si vous le choisissez. Vous pouvez exporter n’importe quel domaine, tout lire par l’API, et le code source vous est accessible.

**Pouvons-nous commencer sans développeur ?**
Oui. Le portail vous donne des vues liste, calendrier et kanban, plus une page d’édition par document, générées à partir de modèles que l’assistant écrit pour vous. Le travail quotidien sur les données ne demande aucun code. Pour un écran de workflow spécifique, utilisez un outil IA sur le SDK.

**Faut-il tout déplacer d’un coup ?**
Non. Commencez par un domaine : les enregistrements qui font le plus mal dans les tableurs. Il met en place les comptes, les rôles, l’historique et l’hébergement, et chaque domaine suivant les réutilise. La valeur démarre petite et s’accumule.

## Voir aussi

- [Comparer](/fr/discover/compare/) : toutes les pages de comparaison.
- [Facet vs Supabase et Firebase](/fr/discover/compare/vs-supabase-firebase/) : la version backend développeur de cette question.
- [Facet vs les bases Airtable et Notion](/fr/discover/compare/vs-airtable-notion/) : la version tableur.
- [Qu’est-ce que Facet](/fr/discover/why-facet/)
- [Sécurité et gouvernance](/fr/discover/security/)

## Sources

- Veracode, rapport « GenAI Code Security Report » 2025 : les modèles ont choisi l’implémentation non sécurisée dans 45 % des 80 types de tâches, sur plus de 100 modèles ; les modèles plus grands et plus récents n’ont pas fait mieux — https://www.veracode.com/press-release/ai-generated-code-poses-major-security-risks-in-nearly-half-of-all-development-tasks-veracode-research-reveals/ — vérifié le 2026-11-13
- UpGuard, « Everything Everywhere: Systemic Data Exposure in Supabase Apps » (octobre 2026) : 16 à 326 bases avec tables lisibles sur environ 300 à 000 domaines ; plus de la moitié avec des indicateurs de données personnelles ; la fuite Moltbook de février 2026 ; l’exemple du coaching à l’immigration — https://www.upguard.com/blog/everything-everywhere-systemic-data-exposure-in-supabase-apps — vérifié le 2026-11-13
- SC World, au sujet des travaux de Backslash : des instructions de sécurité explicites dans les prompts améliorent la sortie des modèles — https://www.scworld.com/news/llms-make-insecure-coding-choices-for-45-of-tasks-study-finds — vérifié le 2026-11-13
- Les affirmations sur Facet lui-même viennent de ce site : [Qu’est-ce que Facet](/fr/discover/why-facet/) et la [vue d’ensemble Sécurité et gouvernance](/fr/discover/security/).
