---
type: overview
title: Choisir sa façon de construire
description: Deux façons de construire un domaine, dans l’application avec des brouillons ou dans des fichiers sur un serveur de dev.
audience: [author, developer]
features: [DOM-02, DOM-19]
sidebar:
  order: 0
verified_at: c34885a
---

Facet offre deux façons de construire un domaine. Les deux produisent la
même chose : un domaine réel avec ses doctypes, ses vues et ses scripts.
Choisissez selon l’endroit où vous travaillez et selon votre profil. Si
vous modélisez des données dans l’application aujourd’hui — des bases
Airtable, par exemple — construisez dans l’application. Si vous vivez
dans un éditeur de code, ou si vous travaillez avec un agent de code IA,
construisez dans des fichiers.

## Les deux modes en bref

| | Dans l’application : brouillon → publication | Dans des fichiers : mode dev |
| --- | --- | --- |
| Où | Toute instance, préproduction et production incluses | Un serveur de dev qui vous appartient ; le watcher refuse de démarrer en production |
| Qui | Auteurs, souvent non développeurs | Développeurs et agents de code IA |
| Comment vous modifiez | L’interface du **Builder** ou l’assistant de construction de domaines, dans un brouillon (`_…`) | Des fichiers YAML et Lua dans votre éditeur ; le watcher applique chaque enregistrement |
| Filet de sécurité | Le brouillon est isolé ; la **Vérification** lance les diagnostics ; la publication est une seule transaction | Le contrôle de version ; le brouillon est court-circuité |
| Données d’essai | Des documents jetables dans le brouillon ; la publication copie la structure seule | `documents: preserve` ou `discard` dans la configuration du watcher |
| Le chemin vers la production | **Publier** | Exportez un bundle, importez-le sur la cible, puis ajustez-y éventuellement dans un brouillon |

Chaque case est un choix, pas un classement. Un auteur et un développeur
peuvent travailler sur le même produit : l’auteur modélise dans
l’application, le développeur construit le domaine dans des fichiers sur
la dev et le leur livre en bundle.

## Construire dans l’application

Vous ne modifiez jamais un domaine réel directement. Vous ouvrez un
**brouillon** — une copie privée dont le nom commence par `_` — vous y
changez les définitions, vous lancez la **Vérification**, puis vous
**Publiez** en une seule étape quand le brouillon est prêt. La
publication copie la structure seule : les documents d’essai créés
pendant vos essais n’atteignent jamais les données de production.

Une barrière précède le brouillon : Facet ne dérive un domaine réel que
pour un compte que le domaine liste comme éditeur, et un domaine neuf ne
liste personne — pas même l’administrateur. Ajoutez-vous dans l’onglet
**Éditeurs** du domaine (**Configurer → Domaines**) avant d’utiliser
**Modifier un existant** ; les détails se trouvent dans
[Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/).

- [Fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/) — le cycle de vie, et ce que vérifie la publication.
- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) — ouvrez un brouillon, ajoutez des co-éditeurs, publiez.
- [Construire avec l’assistant](/fr/build/model/in-app/build-with-assistant/) — décrivez le domaine en discussion ; l’assistant écrit le brouillon.
- [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/) — lisez les diagnostics et levez-les.

## Construire dans des fichiers

Sur un serveur de dev, vous pouvez sauter la boucle du brouillon. Vous
modifiez un dossier de fichiers YAML et Lua ; le **watcher de domaines**
applique chaque enregistrement au serveur en cours d’exécution. Le
contrôle de version est votre filet de sécurité. Ce mode convient aux
développeurs et aux agents de code IA, parce que tout est texte avec un
diff vérifiable.

- [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/) — reliez un dossier à un serveur de dev.
- [L’organisation des fichiers du domaine](/fr/build/model/in-files/domain-files/) — les fichiers que le watcher lit, un par un.
- [Construire des domaines avec un agent de code](/fr/build/model/in-files/with-a-coding-agent/) — mettez en place la boucle de l’agent.

## Passer en production

Le pont entre les modes est le **bundle** : un dossier (ou une archive)
qui transporte les définitions d’un domaine. Vous construisez dans des
fichiers sur la dev, vous exportez le bundle, et vous l’importez sur la
préproduction ou la production. Là, vous pouvez l’ajuster dans un
brouillon et publier, comme le feraient les auteurs sur place.

- [De la dev à la production](/fr/build/model/dev-to-production/) — l’aller-retour, et ce qui voyage.
- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — les commandes d’export et d’import.
- [Modifier un domaine réel sans risque](/fr/build/model/change-a-live-domain/) — ce qu’un changement de schéma coûte sur des données réelles.

## Peut-on mélanger les deux modes ?

Oui — c’est la route normale vers la production. Construisez dans des
fichiers sur la dev, exportez le bundle, importez-le sur la cible, puis
laissez les auteurs sur place l’ajuster dans un brouillon.
[De la dev à la production](/fr/build/model/dev-to-production/) parcourt
l’aller-retour avec l’exemple Brightwater.

Une précaution : un domaine peut recevoir des modifications des deux
côtés. Sur une instance de dev, le watcher remplace les définitions à sa
prochaine synchronisation, donc il l’emporte. Sur la préproduction ou la
production, aucun watcher ne tourne : une publication de brouillon
l’emporte, et les fichiers ne l’apprennent jamais. La règle de travail :
traitez les fichiers comme la source de vérité, et réexportez après
toute modification faite dans un brouillon.

## Le reste de cette section

Les pages ci-dessous couvrent la modélisation elle-même. Elles
fonctionnent de la même façon dans les deux modes : un champ, une
relation, une vue ou une automatisation se définit de la même manière
dans un brouillon et dans un fichier.

| Groupe | Contenu |
| --- | --- |
| [Données](/fr/build/model/data/design-doctypes/) | Doctypes, types de champs, identifiants, champs calculés, secrets, fichiers |
| [Relations](/fr/build/model/relations/references-links/) | Références, composition parent/enfant, partage inter-domaines, commentaires et pièces jointes |
| [Vues](/fr/build/model/views/names-and-search/) | Noms d’affichage, pages document, listes et tableaux, la vue schématique |
| [Comportement](/fr/build/model/behaviour/named-actions/) | Actions nommées, scripts de cycle de vie et garde-fous |
| [Automatisation](/fr/build/model/automation/event-hooks/) | Hooks d’événement et planifiés, webhooks, notifications |
| [Accès](/fr/build/model/access/named-scopes/) | Règles de lignes pour les rôles |

## Voir aussi

- [Construire des domaines](/fr/build/) — la section où se trouve ce groupe.
- [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/) — le mode fichiers, en entier.
- [Fonctionnement des brouillons](/fr/build/model/in-app/how-drafts-work/) — le mode application, en entier.
- [Comment les domaines restent isolés](/fr/build/deeper/domain-isolation/) — ce que borne un domaine, une couche plus bas.
