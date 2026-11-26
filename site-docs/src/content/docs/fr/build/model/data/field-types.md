---
title: Types de champs (guide)
description: Choisissez le bon type pour chaque champ, définissez les défauts, et sachez comment Facet normalise les valeurs.
audience: [author]
features: [DOM-04, DOC-13]
sidebar:
  order: 3
verified_at: fd345fe3
---

Chaque champ d’un doctype porte un type. Le type décide de trois choses : ce que les utilisateurs peuvent saisir, comment Facet stocke la valeur, et quels filtres les pages de liste proposent. Ce guide couvre les types les plus utilisés. La table complète de tous les types, avec toutes leurs contraintes, se trouve dans la référence.

## Quand l’utiliser

Vous déclarez des champs et vous vous demandez : texte ou texte long ? nombre ou montant ? référence ou fichier ? L’exemple à la fin montre un bloc `fields` complet que vous pouvez copier.

## Avant de commencer

- **Modifiez dans un brouillon.** Vous éditez le doctype dans un domaine de brouillon. Voir [Concevoir des doctypes](/fr/build/model/data/design-doctypes/).
- **Choisissez les types avec soin avant de publier.** Changer un type sur un domaine réel exige une montée de version, car les valeurs stockées doivent rester lisibles.

## Étapes

### 1. Choisissez le type

| Type | Contenu | Exemple de valeur | Remarques |
| --- | --- | --- | --- |
| `string` | Texte court | `"Acme Corp"` | `min`/`max` bornent la longueur. |
| `longtext` | Texte long en markdown | `"See the notes.\n\nSecond line."` | Les retours à la ligne sont normalisés en `\n`. |
| `integer` | Nombre entier | `42` | `min`/`max` bornent la valeur. |
| `boolean` | Vrai ou faux | `true` | |
| `money` | Montant avec devise | `{"value": "1200.50", "currency": "USD"}` | Déclarez `currency: USD` pour remplir la devise par défaut. |
| `date` | Date calendaire | `"2026-03-01"` | Ni heure, ni fuseau. |
| `datetime` | Instant précis | `"2026-03-01T14:30:00Z"` | Tout décalage de fuseau est accepté ; Facet stocke en UTC. |
| `enum` | Une valeur d’une liste fixe | `"active"` | Déclarez la liste `values` ; chaque entrée porte une clé, un libellé et une couleur. |
| `url` | Adresse web | `"www.acme.tld"` | Facet stocke `https://www.acme.tld`. |
| `reference` | Lien vers un autre document | `"hr.Employee.01HQ2F5WX8K4M3PZC6NRB9TJVA"` | Voir [Références, liens et liens entrants](/fr/build/model/relations/references-links/). |
| `file` | Un fichier du magasin d’artefacts | `"01HQ2F5WX8K4M3PZC6NRB9TJVA"` (id d’artefact) | Voir [Fichiers et artefacts dans les champs](/fr/build/model/data/files/). |

Les types conteneurs portent plusieurs valeurs : `object` avec des `properties` nommées, `array` avec un seul schéma `items`, et `dictionary` avec un seul schéma `values` pour toutes les entrées. Deux types sont spéciaux : un champ `data` porte une valeur que Facet calcule (voir [Champs calculés](/fr/build/model/data/computed-fields/)), et un champ `secret` porte une donnée d’authentification (voir [Champs secrets et en écriture seule](/fr/build/model/data/secret-fields/)).

Les types restants couvrent les plages de temps (`period`, `dateperiod`), une durée (`duration`), une couleur (`color`), un numéro de téléphone (`phone`) et des sous-documents en ligne (`child`). La table de référence les liste tous.

### 2. Ajoutez des contraintes

Clés de champ courantes :

| Clé | Effet |
| --- | --- |
| `required: true` | L’écriture échoue quand le champ est absent. |
| `unique: true` | Deux documents du doctype ne portent jamais la même valeur. |
| `default` | Facet remplit la valeur quand l’écriture omet le champ. |
| `pattern` | La valeur doit correspondre à cette expression régulière. |
| `write_only: true` | La valeur est acceptée, lue par les scripts, et jamais stockée. |
| `read_only: true` | Seuls les scripts peuvent fixer la valeur ; la saisie utilisateur est refusée. |

### 3. Déclarez les filtres

Ajoutez `filters` à un champ pour que les pages de liste puissent filtrer dessus. Les capacités courantes sont `equality`, `comparison` et `text_search`. Un champ sans `filters` reste présent dans les formulaires et les tables ; il n’apparaît simplement pas dans la barre de filtres.

## Exemple

```json
{
  "fields": {
    "job_title": { "type": "string", "required": true, "max": 120 },
    "department": { "type": "string", "filters": ["equality", "text_search"] },
    "status": {
      "type": "enum",
      "default": "active",
      "filters": ["equality"],
      "values": [
        { "key": "active", "label": "Active" },
        { "key": "on_leave", "label": "On Leave" },
        { "key": "terminated", "label": "Terminated" }
      ]
    },
    "hire_date": { "type": "date", "required": true, "filters": ["comparison"] },
    "salary": { "type": "money", "currency": "USD", "filters": ["comparison"] },
    "remote": { "type": "boolean", "default": false }
  }
}
```

Avec la devise de `salary` déclarée, une écriture de `{"value": "54000"}` stocke `{"value": "54000", "currency": "USD"}`.

## Dépannage

### Une écriture répond `422` sur un champ money

Le montant doit être une chaîne décimale, et la devise un ticker enregistré. Envoyez `{"value": "54000", "currency": "USD"}`, pas un nombre brut.

### Un datetime est stocké sous une autre forme que celle envoyée

Facet normalise chaque datetime en UTC et le stocke avec un `Z` final. `2026-03-01T15:30:00+01:00` est stocké sous `2026-03-01T14:30:00Z`. La valeur marque le même instant.

### Une URL affiche un schéma que je n’ai pas saisi

Facet complète une adresse nue comme `www.acme.tld` en `https://www.acme.tld`. Une valeur sans nom d’hôte à points reste refusée.

### Ma couleur change de forme

Facet normalise les couleurs sous la forme `#RRGGBBAA`. `#1565C0` est stocké sous `#1565C0FF`.

## Voir aussi

- [Types de champs (référence)](/fr/reference/field-types/) — la table complète de tous les types.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — comment les valeurs de champs sont stockées et relues.
- [Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/) — ajoutez des numéros de référence lisibles et des règles d’unicité.
