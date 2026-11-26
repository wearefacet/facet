---
title: Identifiants et contraintes d’unicité
description: Générez des numéros de référence lisibles et gardez les valeurs de champ uniques d’un document à l’autre.
audience: [author]
features: [DOM-10, DOM-11]
sidebar:
  order: 5
verified_at: fd345fe3
---

Par défaut, Facet nomme chaque document avec un ULID : un identifiant long,
triable et opaque. Beaucoup d’enregistrements se lisent mieux avec un numéro
que l’on peut prononcer à voix haute, comme `INV-2026-0001`. Un bloc
`identifier` sur le doctype génère de tels numéros. Les règles d’unicité sur
les champs servent un second but : deux documents ne peuvent pas porter la
même valeur.

## Quand l’utiliser

Ajoutez un identifiant quand les utilisateurs citent des numéros de document
de vive voix, dans un courriel ou sur un document imprimé. Ajoutez `unique`
quand une valeur dupliquée serait une erreur de données, comme deux employés
avec la même adresse de courriel.

## Avant de commencer

- **L’identifiant devient l’id du document.** Il est généré à la création et
  ne change jamais.
- **Un compteur par doctype.** Facet tient un compteur par doctype, partagé
  entre tous les écrivains.

## Étapes

### 1. Façonner le numéro avec un modèle

| Jeton | Signification |
| --- | --- |
| `#` | Un chiffre du compteur, complété par des zéros. Quatre chiffres comptent à partir de `0001`. |
| `{year}` | L’année en cours, par exemple `2026`. |
| `{month}` | Le mois en cours, par exemple `06`. |
| `{day}` | Le jour en cours, par exemple `15`. |
| autre texte | Texte littéral, copié tel quel : `INV-`, `-`, `TKT-`. |

Le modèle exige au moins un groupe `#`, et un groupe compte au plus 18
chiffres. Quand l’année ou le mois change, le compteur repart à zéro et la
numérotation redémarre à 1.

### 2. Déclarer le bloc `identifier`

```json
"identifier": {
  "template": "INV-{year}-####",
  "genonly": true
}
```

`genonly: true` interdit aux appelants de fournir leur propre id à la
création. Sans lui, le modèle génère quand même l’id quand l’appelant n’en
fournit pas.

### 3. Ajouter des champs uniques

Mettez `unique: true` sur tout champ dont la valeur doit différer d’un
document à l’autre. Facet vérifie la règle à chaque create et update : une
valeur vide sur un document et une valeur absente sur un autre n’entrent pas
en collision.

```json
"email": {
  "type": "string",
  "required": true,
  "unique": true,
  "filters": ["equality", "text_search"]
}
```

## Exemple

```json
{
  "domain": "crm",
  "doctype": "Invoice",
  "aggregate_root": true,
  "schema_version": 1,
  "identifier": { "template": "INV-{year}-####", "genonly": true },
  "fields": {
    "customer": { "type": "reference", "doctype": "crm.Company", "required": true },
    "total": { "type": "money", "currency": "EUR", "filters": ["comparison"] }
  }
}
```

Les trois premières créations produisent les ids `INV-2026-0001`,
`INV-2026-0002` et `INV-2026-0003`. Le 1er janvier, la numérotation repart de
`INV-2027-0001`. Le numéro est l’id du document : les pages l’affichent et
les utilisateurs peuvent retrouver un document par son numéro (le filtre
`id__match`).

:::caution
Quand tous les groupes de chiffres atteignent leur maximum, Facet retombe sur
un ULID pour l’id suivant. Donnez à un doctype à forte cadence assez de
chiffres, par exemple `######`.
:::

## Dépannage

### Une écriture répond `422` avec une erreur d’unicité

Un autre document du même doctype porte déjà cette valeur. Trouvez-le en
filtrant la liste sur le champ, puis changez la valeur ou corrigez le
doublon.

### L’appelant ne peut pas choisir l’id

Le doctype déclare `genonly: true`. Les appelants omettent l’id et laissent
Facet le générer.

### Un document porte un ULID au lieu d’un numéro

Le compteur a débordé, ou le document a été créé avant l’ajout du bloc
`identifier`. Les identifiants s’appliquent aux documents créés une fois le
bloc en place.

### Deux doctypes remettent leur compteur à zéro à des moments différents

Chaque modèle porte ses propres variables de temps. Un modèle avec `{month}`
repart chaque mois ; un modèle avec seulement `{year}` repart chaque année.

## Voir aussi

- [Schéma de définition de doctype](/fr/reference/doctype-schema/) — le bloc `identifier` et les contraintes de champs en détail.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — où l’id généré est enregistré.
- [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/) — lancez les contrôles sur votre brouillon avant de publier.
