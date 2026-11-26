---
title: Opérateurs de filtre
description: Chaque opérateur de filtre, avec les types de champs qui le servent et la forme de valeur attendue.
audience: [author, developer]
features: [DOC-02]
type: reference
sidebar:
  order: 4
verified_at: 008dd880
---

> Généré depuis `src/document/filter_compiler.cr` par `make gen-docs-filter-operators`. Ne modifiez pas ce fichier à la main.

Cette page sert à construire un filtre et à vérifier quels opérateurs un type de champ accepte.

Les routes de liste reçoivent les filtres comme paramètres de requête, par exemple `filters[status__eq]=active`. Une clé de filtre est un nom de champ avec un suffixe d'opérateur ; une clé nue vaut `eq`. Un tableau ci-dessous couvre chaque famille de types de champs.

Un filtre incorrect échoue avec l'un des deux codes :

- `unsupported_filter_operator` — le champ ne sert pas cet opérateur.
- `malformed_filter_value` — la valeur n'a pas la bonne forme.

Les deux répondent `422`.

## Comparaison — la plupart des types de champs

Sert : any, color, data, date, datetime, dictionary, duration, enum, file, integer, longtext, object, phone, secret, string, url.
Les valeurs integer et duration se comparent numériquement ; les autres types se comparent comme du texte.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `between` | array | Stored value is inside the inclusive range. The value is a two-element array `[start, end]`. |
| `eq` | scalar | Stored value equals the given value (text equality). |
| `gt` | scalar | Stored value is greater than the given value. |
| `gte` | scalar | Stored value is greater than or equal to the given value. |
| `in` | array | Stored value equals one of the array entries, at most 100. |
| `lt` | scalar | Stored value is less than the given value. |
| `lte` | scalar | Stored value is less than or equal to the given value. |
| `match` | scalar | Stored value contains the given substring, case-insensitive. `%` and `_` match literally. |
| `ne` | scalar | Stored value is not the given value. |
| `starts_with` | scalar | Stored value starts with the given prefix, case-insensitive. |

## Champs array

Sert : array.
Test d'appartenance sur le tableau JSON stocké.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `contains` | scalar or array | Same match as `eq`: the stored array contains all given elements. |
| `eq` | scalar or array | Stored array contains the given element, or every element of the given array. |
| `overlaps` | scalar or array | Stored array shares at least one element with the given array. |

## Champs boolean

Sert : boolean.
Un booléen est un champ à deux états : l'égalité seulement.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `eq` | scalar | Value equals the given boolean. |
| `ne` | scalar | Value is not the given boolean. |

## Champs money

Sert : money.
La valeur comparée est un montant en chaîne de caractères, préfixé au besoin par la devise : `USD 12.50`. Un montant sans devise se compare toutes devises confondues.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `between` | array | Amount is inside the inclusive range. The value is a two-element array; both bounds must carry the same currency. |
| `currency` | scalar | Stored currency ticker equals the given registered ticker. |
| `eq` | scalar | Amount equals the given value. |
| `gt` | scalar | Amount is greater than the given value. |
| `gte` | scalar | Amount is greater than or equal to the given value. |
| `lt` | scalar | Amount is less than the given value. |
| `lte` | scalar | Amount is less than or equal to the given value. |

## Champs plage (dateperiod, period)

Sert : dateperiod, period.
La valeur stockée est un intervalle `{start, end}`.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `contains` | ISO-8601 string or array | Stored interval contains the given point (an ISO-8601 string) or the given `[start, end]` interval. |
| `eq` | array | Stored interval equals the given `[start, end]` interval. |
| `overlaps` | array | Stored interval and the given interval share at least one point. |
| `within` | array | Stored interval lies inside the given `[start, end]` interval. |

## Champs reference

Sert : reference.
Une référence vise une cible à deux états : l’égalité seulement.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `eq` | scalar | Reference points at the given document. The bare id and the qualified `{domain}.{Doctype}.{id}` form both match. |
| `ne` | scalar | Reference does not point at the given document (same two forms). |

## La colonne système `id`

`id` est la colonne identifiant du document dans `projections` ; ce n’est pas un champ de doctype.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `between` | array | Document id is inside the inclusive range. The value is a two-element array. |
| `eq` | scalar | Document id equals the given id. |
| `gt` | scalar | Document id sorts after the given id. ULIDs sort by creation time, so the order is also chronological. |
| `gte` | scalar | Document id sorts after the given id or equals it. |
| `in` | array | Document id equals one of the array entries, at most 100. |
| `lt` | scalar | Document id sorts before the given id. |
| `lte` | scalar | Document id sorts before the given id or equals it. |
| `match` | scalar | Document id contains the given substring, case-insensitive. |
| `ne` | scalar | Document id differs from the given id. |

## Colonnes système d'horodatage

Sert : created_at, updated_at, deleted_at.
`deleted_at` filtre la liste de la corbeille (`include_deleted: true`) ; les lignes actives portent `NULL`.

| Opérateur | Forme de la valeur | Signification |
|---|---|---|
| `between` | array | Column is inside the inclusive range. The value is a two-element array of timestamps. |
| `eq` | scalar | Column equals the given timestamp. The value normalizes to UTC RFC 3339, so offsets are respected. |
| `gt` | scalar | Column is later than the given timestamp. |
| `gte` | scalar | Column is later than or at the given timestamp. |
| `lt` | scalar | Column is earlier than the given timestamp. |
| `lte` | scalar | Column is earlier than or at the given timestamp. |
| `ne` | scalar | Column differs from the given timestamp. |

## Recherche

`search` est un mot-clé de la grammaire, pas un champ.
Seule la clé nue est valide ; une forme suffixée (par exemple `search__match`) répond `422`.

| Clé | Forme de la valeur | Signification |
|---|---|---|
| `search` | scalar | The document search text contains the given term, case- and accent-insensitive. |

## Voir aussi

- [Périmètres nommés](/fr/build/model/access/named-scopes/)
- [Listes, filtres et vues enregistrées (tableau, kanban, calendrier)](/fr/use/finding/lists-and-views/)
- [Utiliser l'API REST](/fr/build/apps/data/rest-api/)
