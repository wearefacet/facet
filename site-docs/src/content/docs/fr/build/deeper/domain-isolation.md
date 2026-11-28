---
type: explanation
title: "L’isolation entre domaines"
description: "Ce qu’un domaine possède, ce qui franchit la frontière, et les deux consentements qui isolent les domaines."
audience: [author, developer]
features: [DOM-01, DOM-14]
sidebar:
  order: 4
verified_at: eee55a2
---

Un domaine est à la fois l’unité de propriété et l’unité d’isolation. Il
regroupe un seul secteur d’activité, et rien de son contenu n’en sort de
lui-même. Cette page décrit la mécanique complète : ce qu’un domaine
possède, ce qui franchit la frontière, et les deux consentements qui
l’ouvrent. La version en langage simple de cette histoire se trouve dans
[Les domaines : où vivent vos données](/fr/discover/how-it-works/domains/).

## Ce que possède un domaine

<!-- d2
direction: down
call: "A call reaches into a domain" {class: external}
same: "Same domain?" {class: decision}
free: "Runs under the caller's roles" {class: ok}
consent: "Explicit consent held?" {class: decision}
api: "Role permission for the foreign doctype" {class: ok}
grant: "Active grant covers the tags" {class: ok}
refused: "Refused" {class: danger}

call -> same
same -> free: "yes"
same -> consent: "no — foreign domain"
consent -> api: "document API"
consent -> grant: "replication, hooks, Lua"
consent -> refused: "neither"
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/7955fcf2-light.svg" alt="A call reaches into a domain" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/7955fcf2-dark.svg" alt="A call reaches into a domain" loading="lazy" />
</div>

Un domaine est un document `core.Domain`, et son id est le nom du domaine.
Cet id forme le premier segment d’une identité composée. Un document
s’adresse par son domaine, son doctype et son id ; un doctype s’adresse
comme `equipment.Item`. La projection indexe ses lignes par la paire
`(domain, doctype)` : deux domaines peuvent donc chacun porter un `Item`
sans collision.

Le domaine possède :

- **ses définitions de doctypes** — enregistrer un doctype dans un domaine
  qui n’existe pas répond `422`,
- **leurs modèles de vue** — les pages détail et les vues de liste
  partagées,
- **les hooks déclarés sur le document du domaine**,
- **les attributions qu’il émet** vers d’autres domaines,
- **son état de brouillon** — un domaine brouillon est une identité
  distincte préfixée par `_`.

Le domaine est aussi l’unité de portabilité : l’export et l’import
déplacent exactement un domaine.

## Deux consentements ouvrent la frontière

Par défaut, les données ne franchissent pas la frontière. Un appel
extérieur a besoin de l’un des deux consentements explicites, selon la
surface concernée :

| Surface | Consentement | Ce qu’il autorise |
| --- | --- | --- |
| L’API de documents | Une permission de rôle qui nomme le doctype étranger | La lecture, et l’écriture là où le rôle l’autorise, sous les rôles propres de l’appelant |
| Les surfaces d’automatisation — champs de réplication, hooks à source étrangère, `document.get` / `document.list` en Lua | Une attribution de domaine active | La lecture des champs couverts des documents du producteur |

Les connexions intra-domaine ignorent ces deux consentements. Un domaine
qui se lit lui-même ne prend aucune décision de partage.

## Ce que partage une attribution

Une attribution est un contrat de partage de données, stocké comme un
document **sous le domaine producteur** — le consentement appartient à la
partie qui fournit les données. Une attribution couvre un seul domaine
consommateur ; la paire est unique. Elle nomme des ressources : une entrée
par doctype producteur, et chaque entrée porte des étiquettes de champs.

- **Lecture seule.** Aucune attribution d’écriture n’existe. La porte reste
  fermée, par conception.
- **À la granularité de l’étiquette, pas du champ.** Les étiquettes sont
  des libellés libres posés sur les champs. Un champ sans étiquette compte
  comme portant l’étiquette `default` : une entrée qui nomme `default`
  atteint donc tous les champs sans étiquette. Un nouveau champ sans
  étiquette circule ainsi dans les attributions qui nomment déjà
  `default`.
- **Projection, pas divulgation.** Quand une valeur couverte franchit la
  frontière — dans le contenu d’un hook, une lecture Lua ou une réplique —,
  le serveur réduit d’abord le document aux champs couverts. Les champs
  hors contrat ne quittent jamais le producteur.
- **Attribution ≠ rôle.** Une attribution joue à la granularité de
  l’étiquette pour le *domaine*. Un script Lua du domaine consommateur lit
  les champs couverts même quand la personne qui a déclenché le script ne
  peut pas les lire via l’API. Gardez cela en tête avant d’attribuer une
  étiquette à un domaine.

## Les quatre points de contrôle

L’attribution est vérifiée à quatre moments de l’exécution. Les quatre
suivent le principe du refus par défaut :

| Point de contrôle | Moment de la vérification | Sans couverture |
| --- | --- | --- |
| Construction du registre | Au démarrage du serveur, après un changement d’attribution ou de doctype | La liaison inter-domaines est abandonnée ; les mises à jour s’arrêtent |
| Tirage à l’écriture | À la création du consommateur, ou quand le champ référence change | La réplique reste vide |
| Livraison aux hooks | Avant qu’un événement étranger n’atteigne un hook | Le hook ne se déclenche jamais |
| Lectures Lua | Sur `document.get` / `document.list` avec un doctype étranger | La lecture échoue — erreur interceptable avec `pcall` en Lua |

## Le producteur décide de l’activation

Une attribution arrive sous la forme d’un ticket avec `active: false`.
L’activation est un droit du producteur, tout ou rien par attribution —
il n’existe aucune acceptation par doctype ni par étiquette. La publication
et l’import déposent ces tickets. Une publication les dépose actifs
uniquement quand l’éditeur détient le droit d’acceptation. Un import les
dépose toujours inactifs, car l’import est un acteur système.

Une fusion qui élargit les ressources d’une attribution active repasse
l’attribution en inactif. Un contrat modifié exige une nouvelle
acceptation — un élargissement silencieux contournerait le consentement du
producteur. Une republication sans changement de ressource ne touche à
rien.

## Les brouillons restent dans le bac à sable

Les attributions ne concernent jamais les brouillons. Les deux parties de
chaque contrat doivent être des domaines réels ; un producteur en
brouillon apparaît comme diagnostic de vérification, pas comme ticket. Le
moteur de réplication exclut aussi les brouillons des deux côtés — un
domaine brouillon n’est jamais source ni consommateur de réplication.
Dans le brouillon, tout est répétition : la publication copie la
structure, relie les cibles des références intra-domaine au nom réel, puis
détruit le brouillon. Voir [Le fonctionnement des
brouillons](/fr/build/model/in-app/how-drafts-work/).

## Supprimer un domaine

Supprimer un domaine tient en une seule transaction. Les définitions, le
document du domaine, ses données, ses lignes de vues et d’index partent
ensemble. Le journal d’audit conserve un enregistrement `delete` indiquant
qui a supprimé le domaine. Deux refus protègent l’opération. Les domaines
système — `core`, `iam`, `app` — ne peuvent pas être supprimés. Un domaine
réel avec un brouillon ouvert ne peut pas être supprimé tant que le
brouillon n’est pas abandonné. La route générique de suppression de
document répond `422` pour un domaine ; la route de suppression de domaine
est la seule porte.

Les références d’autres domaines qui pointaient vers les documents du
domaine supprimé restent en place, sans cible. C’est le comportement
accepté, identique à la suppression de n’importe quel document référencé.

## Les compromis

**Les attributions couplent les domaines.** Le consommateur lit des
données réelles, donc il dépend du contrat du producteur. Désactivez
l’attribution, et les copies cessent de se mettre à jour. Réduisez les
étiquettes, et les valeurs déjà copiées restent où elles sont — aucune
tâche ne les balaie. Réactivez, et le prochain événement source repousse
la valeur.

**L’isolation stricte se paie en duplication.** Quand le couplage coûte
plus que la copie, dupliquez le champ et gardez les domaines totalement
indépendants. Les deux approches sont pleinement prises en charge.

## Voir aussi

- [Les domaines : où vivent vos données](/fr/discover/how-it-works/domains/) —
  la même histoire, sans le vocabulaire du moteur.
- [Comment les champs copiés restent synchronisés](/fr/build/deeper/cross-domain-replication/) —
  le mécanisme de copie que contrôle l’attribution.
- [Comment l’accès est contrôlé](/fr/admin/under-the-hood/how-access-is-enforced/) —
  les vérifications de rôle derrière l’API de documents.
- [Brouillons, éditeurs et publication](/fr/build/model/in-app/drafts-and-publishing/) —
  le cycle de vie du brouillon que protège le bac à sable.
- Internes sur GitHub : [domain-grants.md](https://github.com/wearefacet/facet/blob/main/doc/backend/domain-grants.md),
  [draft-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/draft-domains.md).
