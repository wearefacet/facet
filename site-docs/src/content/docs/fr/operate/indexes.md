---
title: Index gérés
description: Suivez l’état des index gérés que Facet crée pour les champs des doctypes, et relancez les constructions en échec.
audience: [operator]
features: [PLT-05]
sidebar:
  order: 11
verified_at: 008dd880
---

Facet gère ses propres index PostgreSQL. Quand un auteur déclare qu’un
champ est filtrable ou triable, Facet calcule les index qui servent cette
déclaration, les construit à chaud, et les supprime quand le champ change.
Votre travail d’opérateur se résume à surveiller la page d’état et à

relancer les rares échecs.

## Quand l’utiliser

Consultez la page des index quand :

- vous vérifiez la santé des index après un changement de schéma ou un
  import de domaine,
- une construction d’index a échoué et vous voulez la récupérer,
- vous cherchez pourquoi un index existe, ou pourquoi il n’existe pas.

## Avant de commencer

- La route d’état exige une permission `read` en joker sur `*.*` — la même
  règle que pour le journal d’audit global.
- La commande de relance s’exécute depuis une machine qui a accès à la
  base.
- Le DDL des index peut s’exécuter pendant que le serveur tourne. Il ne
  bloque jamais les lectures ni les écritures sur les documents.

## Étapes

### 1. Lire l’état des index

Ouvrez la page d’état des index sous **Configurer → Plateforme**, ou
appelez la route :

```sh
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/Indexes?filters[status__eq]=error&filters[domain__eq]=hr"
```

Chaque ligne décrit un index géré : `id`, `domain`, `doc_type`,
`field_name`, `index_type`, `index_name`, `status`, `error_message`,
`created_at` et `updated_at`. Cycle de vie des états :

<!-- d2
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
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/46455962-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/46455962-dark.svg" alt="Diagram" loading="lazy" />
</div>

- `pending` — la construction attend ou s’exécute.
- `active` — l’index est construit et sert les requêtes.
- `error` — la construction a échoué. `error_message` porte la raison.
- `dropped` — le champ ne demande plus l’index.

Champs filtrables : `domain`, `doc_type`, `status`, `field_name`.
Triables : le même ensemble plus `index_type`, `created_at`,
`updated_at`.

### 2. Relancer les constructions en échec

```sh
facet index:retry --domain hr --dry-run   # affiche le plan, n’exécute rien
facet index:retry --domain hr             # exécute les relances
```

La commande relance deux familles de lignes :

- les lignes en état `error`, et
- les lignes `pending` sans mise à jour depuis plus de 10 minutes — la
  trace qu’un processus de construction mort laisse derrière lui.

  Une ligne `pending` récente appartient à une construction en cours dans
  le serveur actif@NBSP;; la commande ne la touche jamais. Chaque ligne est
  revérifiée par rapport à la définition actuelle du doctype : un
  index toujours demandé est reconstruit@NBSP;; un champ qui n’existe plus
  voit sa ligne supprimée. Les lignes sont indépendantes — un échec
  n’arrête pas les autres. La commande sort avec `0` quand chaque
  tentative a réussi et avec `1` dès qu’au moins une a échoué.

## Explication

### D’où viennent les index

Le planificateur lit les capacités `filters` déclarées sur chaque champ —
`equality`, `comparison`, `text_search`, `interval`, `membership`,
`currency`. Une capacité correspond à une famille d’index :

| Capacité déclarée | Index créé |
| --- | --- |
| `equality` ou `comparison` sur un champ scalaire | Un B-tree |
| `text_search` seul | Un GIN trigram |
| `equality` / `comparison` plus `text_search` | Deux index : un B-tree et un GIN trigram |
| `membership` sur un champ `array` | Un GIN JSONB |
| `interval` sur `period` / `dateperiod` | Un index d’intervalle GiST |

Un champ avec `unique: true` reçoit un B-tree unique, sans capacité
requise. Un champ `reference` reçoit toujours un B-tree, quelles que soient
ses capacités déclarées. Les champs calculés, en écriture seule, en lecture
seule et objets libres ne prennent aucun index.

Chaque index géré est partiel. Sa clause `WHERE` le borne à un domaine, un
doctype et les lignes vivantes, si bien que chaque index reste petit :

```sql
WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL
```

### Pourquoi les échecs sont rares

Les constructions tournent en `CREATE INDEX CONCURRENTLY` dans des fibres
en arrière-plan, si bien que l’enregistrement du doctype réussit toujours.
Un verrou consultatif global sérialise tout le DDL géré entre fibres et
entre processus, ce qui évite l’interblocage que deux constructions
simultanées rencontreraient sinon. Les interblocages résiduels sont
réessayés avec un délai croissant : 3 tentatives à l’exécution, 5
dans `index:retry`.

## Exemple

Après un import de domaine volumineux, un index a échoué.
Rétablissez-le :

```sh
# Qu’est-ce qui a échoué ?
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/Indexes?filters[status__eq]=error"

# Lisez error_message sur la ligne, puis planifiez la relance :
facet index:retry --domain crm --dry-run

# Exécutez, puis vérifiez que la ligne est active :
facet index:retry --domain crm
```

La ligne repasse de `pending` à `active`, et les filtres de liste du
doctype utilisent de nouveau l’index.

## Dépannage

**Une ligne reste `pending` longtemps.**

Une grosse table prend du temps à construire@NBSP;; `CONCURRENTLY` parcourt
la table entière. Au-del à de 10 minutes d’inactivité, `index:retry`
considère la ligne comme morte et la reconstruit.

**Une ligne `error` nomme un interblocage.**

La construction a réessayé puis abandonné. Lancez `facet index:retry` pour
le domaine. La commande supprime d’abord tout reste de construction
inachevée, puis reconstruit.

**Un champ déclare `filters` mais n’a aucune ligne d’index.**

Le type du champ ne prend aucun index pour cette capacité — par exemple
`membership` n’est valable que sur les tableaux, et `color` ne prend aucun
index. Consultez [Types de champs (guide)](/fr/build/field-types/) pour les
règles de capacités.

**L’enregistrement d’un doctype a réussi mais un nouvel index manque.**

La construction tourne en arrière-plan après l’enregistrement. Revérifiez
la route d’état avant de chercher ailleurs.

**Une ligne `dropped` réapparaît.**

Le champ est revenu dans la définition du doctype, ou la définition a été
réimportée. Le planificateur redemande l’index, et une nouvelle
construction démarre.

## Voir aussi

- [Types de champs (guide)](/fr/build/field-types/) — d’où viennent les
  capacités `filters`.
- [Identifiants et contraintes d’unicité](/fr/build/identifiers-unique-constraints/) —
  le chemin du B-tree unique.
- [Faire évoluer un schéma](/fr/build/evolving-schema/) — les changements
  de schéma qui déclenchent des constructions.
- [Amorçage et tâches CLI](/fr/operate/bootstrap-cli/) — la surface CLI
  autour de `index:retry`.
- Internes sur GitHub :
  [index-management.md](https://github.com/wearefacet/facet/blob/main/doc/backend/index-management.md),
  [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
