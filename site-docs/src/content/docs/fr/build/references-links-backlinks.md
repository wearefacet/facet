---
title: Références et liens entrants
description: Reliez des documents par des champs référence et des liens dans le texte, et montrez qui pointe vers un document.
audience: [author]
features: [DOC-05, DOC-10]
sidebar:
  order: 4
verified_at: fd345fe3
---

Les documents pointent vers d’autres documents. Un champ `reference` porte un lien typé, une référence de collection en porte plusieurs, et un champ `longtext` peut contenir des liens dans du markdown. Facet indexe chaque lien. Chaque page de document peut donc montrer aussi l’inverseà : quels documents pointent vers lui.

## Quand l’utiliser

Utilisez des champs référence quand un enregistrement en désigne un autre sans le posséder — un employé désigne son responsable, une tâche désigne la personne qui lui est assignée. Quand la partie appartient au tout, modélisez plutôt une composition (voir [Composition parent/enfant](/fr/build/parent-child-composition/)).

## Avant de commencer

- **Une cible qualifiée.** La cible d’une référence est toujours un identifiant de doctype qualifiéà : `domain.Doctype`, par exemple `iam.Account`. Un nom seul est refusé, et toutes les valeurs d’un tel champ échouent.
- **Un droit de lecture sur la cible.** Les utilisateurs ont besoin d’un accès en lecture au doctype cible pour résoudre ses références.

## Étapes

### 1. Déclarer un champ référence

```json
"owner": {
  "type": "reference",
  "doctype": "iam.Account",
  "filters": ["equality"]
}
```

Les utilisateurs envoient un id simple, un id qualifié, ou un token `urn:facet:`. Facet stocke la forme qualifiée `iam.Account.01HQ2F5WX8K4M3PZC6NRB9TJVA` dans tous les cas.

### 2. Restreindre le sélecteur avec un filtre

Le `filter` facultatif limite les documents qu’une référence accepte. Facet vérifie le filtre à chaque écriture.

```json
"company": {
  "type": "reference",
  "doctype": "identity.Company",
  "filter": { "status__eq": "active" }
}
```

### 3. Autoriser les références anticipées

Une référence doit normalement pointer vers un document qui existe. Ajoutez `dangling: true` quand la cible peut ne pas exister encore, par exemple un successeur que vous renseignez dans une étape ultérieure.

### 4. Pointer vers plusieurs documents

Ajoutez `collection: true` pour porter un tableau de références. Facet vérifie chaque élément l’un après l’autre.

```json
"watchers": {
  "type": "reference",
  "doctype": "iam.Account",
  "collection": true
}
```

### 5. Insérer des liens dans le texte long

Un champ `longtext` accepte des liens markdown vers des documents. Les deux formes ci-dessous produisent un lien sur la page et comptent comme un lien dans l’indexà :

```markdown
Checked with [Marie Dubois](urn:facet:iam:Account:01JCATPMKP4N82GVG2J7K4MHZZ).

Follow-up for [Acme Corp](crm.Company.01HQ2F5WX8K4M3PZC6NRB9TJVA).
```

Les deux formes comptentà : un token `urn:facet:` n’importe où dans le texte, et un lien markdown dont l’adresse est un document. Une adresse à points tapée comme du texte, sans être un lien, ne compte pas.

## Exemple

La définition ci-dessous relie un employé à un compte et à un responsable dans le même doctype.

```json
{
  "fields": {
    "person": { "type": "reference", "doctype": "identity.Person", "required": true, "unique": true },
    "manager": { "type": "reference", "doctype": "hr.Employee", "filters": ["equality"] },
    "notes": { "type": "longtext" }
  }
}
```

Sur chaque page de document, la section **Référencé par** liste les documents qui pointent vers lui, avec le doctype en étiquette. Avant une suppression, Facet prévientà : `N document(s) reference it — deleting it leaves those links dangling`. La suppression n’est jamais bloquée.

## Dépannage

### Toutes les valeurs du champ sont refusées

Le `doctype` déclaré doit être la forme qualifiée `domain.Doctype`. Un nom seul comme `"Employee"` échoue, et Facet refuse toutes les valeurs au moment de l’écriture.

### Une référence s’affiche vide ou introuvable

Le document cible a été supprimé, ou votre rôle ne peut pas lire son doctype. Facet garde la valeur stockée mais ne résout rien pour vous.

### La référence vers un domaine de brouillon est refusée

Un domaine réel ne peut pas référencer un doctype encore en brouillon. Publiez d’abord le brouillon.

## Voir aussi

- [Liens et références inverses (doc d’ingénierie)](https://github.com/wearefacet/facet/blob/main/doc/backend/links.md) — le fonctionnement de l’index des liens.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) — où se trouve l’index des liens.
- [Composition parent/enfant](/fr/build/parent-child-composition/) — modéliser des enfants possédés plutôt que des références libres.
