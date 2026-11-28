---
title: "Index"
description: "Surveillez les index gérés que Facet construit pour les champs des doctypes, et relancez une construction en échec."
type: how-to
audience: [operator]
features: [PLT-05]
verified_at: eee55a2
sidebar:
  order: 5
---

Une vue de liste est devenue plus lente après un import de domaine, et
vous devez savoir pourquoi. Facet gère ses propres index PostgreSQL.
Quand un auteur déclare un champ filtrable ou triable, Facet calcule
les index qui servent la déclaration. Il les construit en ligne et les
détruit quand le champ change. Votre travail d’opérateur est de
surveiller la surface d’état et de relancer la rare défaillance.

## Quand l’utiliser

- Vous contrôlez la santé des index après un changement de schéma ou un import de domaine.
- Une construction d’index a échoué et vous la voulez de retour.
- Vous voulez savoir pourquoi un index existe, ou pourquoi il n’existe pas.

## Avant de commencer

- La route d’état demande une permission `read` générique sur `*.*` — la même règle que pour le [journal d’audit global](/fr/admin/history/audit/).
- La commande de relance s’exécute depuis une machine qui rejoint la base.
- Le DDL d’index peut s’exécuter pendant que le serveur est en marche. Il ne bloque jamais les lectures ni les écritures des documents.

## Deux niveaux d’index

Facet porte deux familles d’index, et la surface d’état en couvre une.

**Les index gérés des doctypes** sont ceux que cette page surveille.
Chacun sert un champ d’un doctype, suivi dans la table
`doctype_indexes`, construit et détruit par Facet lui-même.

**Les index système** viennent avec le schéma et personne ne les gère
par doctype. Deux d’entre eux façonnent le comportement quotidien :

- La colonne de recherche porte un index GIN trigramme, partiel sur
  `deleted_at IS NULL`. La recherche plein-texte des listes l’utilise.
- La colonne de liens porte un index GIN, partiel de la même façon,
  pour les requêtes « quels documents pointent vers celui-ci ? ».

Le prédicat partiel compte au-delà de la vitesse : un document supprimé
est une pierre tombale qui garde son contenu jusqu’à ce que la purge de
rétention l’efface. La clause `deleted_at IS NULL` tient ces lignes hors
des index, si bien que leurs charges conservées ne remontent jamais dans
la recherche ni dans les requêtes de liens.

## Étapes

### 1. Lire l’état des index

Ouvrez la page d’état des index sous **Configurer → Plateforme**, ou
appelez la route :

```sh
curl -s -g -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/Indexes?filters[status__eq]=error&filters[domain__eq]=hr"
```

Une ligne par index géré porte : `id`, `domain`, `doc_type`,
`field_name`, `index_type`, `index_name`, `status`, `error_message`,
`created_at` et `updated_at`. Le cycle de vie de l’état :

*Un index géré, de la construction à la retraite.*

<!-- d2
direction: down
pending: pending
active: active {class: ok}
error: error {class: danger}
dropped: dropped

pending -> active
pending -> error
active -> dropped
error -> dropped
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/dcad920b-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/dcad920b-dark.svg" alt="Diagram" loading="lazy" />
</div>

- `pending` — la construction est en file ou en cours.
- `active` — l’index est construit et sert les requêtes.
- `error` — la construction a échoué. `error_message` porte la raison.
- `dropped` — le champ ne veut plus l’index.

Champs filtrables : `domain`, `doc_type`, `status`, `field_name`.
Triables : le même ensemble plus `index_type`, `created_at` et
`updated_at`. Une liste en direct de l’instance en marche, filtrée sur
les index actifs :

```text
count: 99
domain: equipment  doc_type: MaintenanceTicket  field: reported_by  btree  active
domain: equipment  doc_type: MaintenanceTicket  field: assignee     btree  active
domain: equipment  doc_type: MaintenanceTicket  field: status       btree  active
```

### 2. Relancer les constructions en échec

```sh
facet index:retry --domain hr --dry-run   # affiche le plan, n’exécute rien
facet index:retry --domain hr             # exécute les relances
```

La commande relance deux sortes de lignes :

- les lignes en état `error`, et
- les lignes `pending` périmées depuis plus de 10 minutes — la forme
  qu’un processus de construction mort laisse derrière lui.

Une ligne `pending` fraîche appartient à une construction vivante dans
le serveur en marche, donc la commande ne la touche jamais. Chaque
ligne est revérifiée contre la définition actuelle du doctype : un
index encore voulu est reconstruit ; un champ qui n’existe plus détruit
la ligne. Les lignes sont indépendantes — une défaillance n’arrête pas
les autres. La commande sort avec `0` quand chaque tentative a réussi
et `1` quand au moins une a échoué.

## Comment Facet décide des index

Le planificateur lit les capacités `filters` déclarées de chaque champ —
`equality`, `comparison`, `text_search`, `interval`, `membership`,
`currency`. Une capacité correspond à une famille d’index :

| Capacité déclarée | Index créé |
| --- | --- |
| `equality` ou `comparison` sur un champ scalaire | Un B-tree |
| `text_search` seul | Un GIN trigramme |
| `equality` / `comparison` plus `text_search` | Deux index : B-tree et GIN trigramme |
| `membership` sur un champ `array` | Un GIN JSONB |
| `interval` sur `period` / `dateperiod` | Un index d’intervalle GiST |

Trois règles s’ajoutent autour de la table :

- Un champ avec `unique: true` obtient un B-tree unique, sans capacité
  requise.
- Un champ `reference` obtient toujours un B-tree, quoi que ses
  capacités déclarent.
- Les champs calculés, en écriture seule, en lecture seule et objet
  libre ne prennent aucun index.

Chaque index géré est partiel. La clause `WHERE` en limite le périmètre
à un domaine, un doctype et les lignes vivantes, si bien que chaque
index reste petit :

```sql
WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL
```

### Pourquoi les défaillances sont rares

Les constructions s’exécutent en `CREATE INDEX CONCURRENTLY` dans des
fibres en arrière-plan, si bien que l’enregistrement du doctype réussit
toujours. Un verrou consultatif global sérialise tout le DDL géré entre
fibres et processus, ce qui empêche l’interblocage que deux
constructions concurrentes rencontreraient sinon. Les interblocages qui
surviennent quand même réessaient avec recul : 3 tentatives à
l’exécution, 5 dans `index:retry`.

## Exemple

Après un import de domaine important, un index a échoué. Le récupérer :

```sh
# Qu’est-ce qui a échoué ?
curl -s -g -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/Indexes?filters[status__eq]=error"

# Lire error_message sur la ligne, puis planifier la relance :
facet index:retry --domain crm --dry-run

# Exécuter la relance, puis confirmer que la ligne est active :
facet index:retry --domain crm
```

La ligne passe de `pending` à `active`, et les filtres de liste du
doctype utilisent l’index à nouveau.

## Dépannage

**Une ligne reste `pending` longtemps.**

Une grande table met du temps ; `CONCURRENTLY` parcourt toute la table.
Passé 10 minutes de péremption, `index:retry` traite la ligne comme
morte et la reconstruit.

**Une ligne `error` nomme un interblocage.**

La construction a réessayé puis a renoncé. Lancez `facet index:retry`
pour le domaine. Il détruit d’abord tout reste à demi construit, puis
reconstruit.

**Un champ déclare `filters` mais n’a aucune ligne d’index.**

Le type du champ ne prend aucun index pour cette capacité — par exemple
`membership` n’est valide que sur les tableaux, et `color` ne prend
aucun index. Consultez [Types de champs](/fr/build/model/data/field-types/)
pour les règles de capacités.

**Un enregistrement de doctype a réussi mais un nouvel index manque.**

La construction tourne en arrière-plan après l’enregistrement.
Revérifiez la route d’état avant d’investiguer.

**Une ligne `dropped` réapparaît.**

Le champ est de retour dans la définition du doctype, ou la définition
a été réimportée. Le planificateur veut l’index à nouveau, donc une
nouvelle construction démarre.

## Voir aussi

- [Types de champs](/fr/build/model/data/field-types/) — d’où viennent les capacités `filters`.
- [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) — le chemin du B-tree unique.
- [Modifier un domaine en direct sans risque](/fr/build/model/change-a-live-domain/) — les changements de schéma qui déclenchent des constructions.
- [Premier démarrage et initialisation](/fr/admin/install/bootstrap/) — la surface CLI autour de `index:retry`.
- Documentation interne sur GitHub : [index-management.md](https://github.com/wearefacet/facet/blob/main/doc/backend/index-management.md), [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
