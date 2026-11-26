---
title: Concevoir des doctypes
description: Déclarez un doctype avec ses champs, son identifiant, son libellé, son icône, ses actions, ses enfants et ses modèles.
audience: [author]
features: [DOM-03]
sidebar:
  order: 2
verified_at: fd345fe3
---

Un doctype est un type d’enregistrement dans un domaine, comme `crm.Company`
ou `hr.Employee`. Vous le déclarez une seule fois, et Facet y confronte chaque
écriture. La définition porte les champs, les actions que les utilisateurs
peuvent lancer, les enfants possédés, et les règles qui nomment chaque
document et définissent son texte de recherche.

## Quand l’utiliser

Vous ajoutez un doctype à un domaine de brouillon, ou vous retravaillez un
doctype existant. Concevez dans un domaine de brouillon ; publiez une fois le
modèle au point (voir
[Domaines, brouillons et éditeurs de domaines](/fr/build/model/in-app/drafts-and-publishing/)).

## Avant de commencer

- **Des droits d’édition.** Il vous faut le droit de modifier les doctypes
  dans le domaine cible. Le rôle éditeur le donne pour les domaines que le
  compte édite.
- **Un domaine d’accueil.** Le domaine doit exister avant que Facet n’y
  accepte un doctype.
- **Un nom d’action libre.** Les noms d’action réservés (`validate`, `create`,
  `update`) ne sont pas disponibles ; ils désignent les hooks de cycle de vie.

## Étapes

### 1. Déclarer les champs

Donnez à chaque champ un nom et un type, puis ajoutez les contraintes que vos
données exigent. Les noms de champs suivent lower_snake_case ou camelCase.
Voir [Types de champs (guide)](/fr/build/model/data/field-types/) pour les types
courants, et [Types de champs (référence)](/fr/reference/field-types/) pour la
table complète.

### 2. Définir le libellé, l’icône et les modèles

| Élément | Objectif |
| --- | --- |
| `label` | Le nom que l’interface affiche, par exemple `Company`. À défaut, il reprend le nom du doctype. |
| `icon` | Un nom d’icône Lucide en kebab-case, par exemple `building-2`. |
| `display_name` | Un modèle Jinja2 qui nomme chaque document, par exemple `{{ name }}`. |
| `search` | Un modèle Jinja2 pour le texte de recherche. Un doctype qui en est dépourvu reste hors de la recherche inter-doctypes. |

### 3. Choisir racine ou enfant

Un doctype est exactement l’une de ces deux choses :

| Type | Déclaration | Signification |
| --- | --- | --- |
| Racine d’agrégat | `aggregate_root: true` | L’enregistrement que les utilisateurs créent et suppriment. C’est l’unité de verrouillage et de contrôle d’accès. |
| Enfant possédé | `aggregate_root: false` plus `member_of` | Une partie d’un document parent. Voir [Composition parent/enfant](/fr/build/model/relations/parent-child/). |

### 4. Ajouter des actions, des enfants et un identifiant

Ajoutez `actions` quand les utilisateurs ont besoin d’opérations typées
au-del à des simples modifications (voir
[Actions nommées](/fr/build/model/behaviour/named-actions/)). Ajoutez `children` pour les
parties possédées. Ajoutez un bloc `identifier` quand les documents ont
besoin de numéros lisibles (voir
[Identifiants et contraintes d’unicité](/fr/build/model/data/identifiers-uniqueness/)).

### 5. Enregistrer le doctype et itérer

Soumettez la définition pendant que votre domaine de brouillon est ouvert.
Facet valide le schéma, compile le script et renvoie les problèmes. Sur un
domaine réel, tout changement ultérieur de la structure des données exige une
montée de version (voir
[Faire évoluer un schéma](/fr/build/model/change-a-live-domain/)).

Chaque écriture suit ensuite le même chemin : Facet valide le document, ajoute
une ligne au journal, met à jour une projection et publie un événement.

<!-- d2
writer: "App or user" {class: external}
mutations: "mutations log" {class: store}
projections: "projections row" {class: store}
bus: "Redis event bus"
consumers: "Hooks, webhooks, live updates"

writer -> mutations: validated write
mutations -> projections
mutations -> bus
bus -> consumers
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/d2a28d26-light.svg" alt="App or user" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/d2a28d26-dark.svg" alt="App or user" loading="lazy" />
</div>

## Exemple

La définition ci-dessous déclare une racine `crm.Company` avec quatre champs.
Envoyez-la à l’endpoint des doctypes de votre instance.

```json
{
  "domain": "crm",
  "doctype": "Company",
  "label": "Company",
  "icon": "building-2",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ name }}",
  "search": "{{ name }} {{ industry }}",
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "industry": { "type": "string", "filters": ["equality"] },
    "status": {
      "type": "enum",
      "default": "lead",
      "filters": ["equality"],
      "values": [
        { "key": "lead", "label": "Lead" },
        { "key": "active", "label": "Active" }
      ]
    },
    "website": { "type": "url" }
  }
}
```

```sh
curl -k -X POST "https://facet.localhost:3443/Api/core/DocType" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d @company.json
```

`-k` ignore la vérification du certificat de l’adresse de développement
locale. Une seconde soumission de la même définition répond `409` ; les mises
à jour passent par l’éditeur de doctypes.

## Dépannage

### La création répond `422 Domain 'crm' does not exist`

Créez d’abord le domaine. Un doctype doit se trouver dans un domaine, réel ou
de brouillon.

### La création répond `422` avec un nom de clé

Une définition n’accepte que des clés connues, et chaque entrée de champ
vérifie ses propres clés. Le message nomme la clé et son emplacement. Le plus
souvent, une contrainte est mal orthographiée, par exemple `reqired` au lieu
de `required`.

### L’icône ne s’affiche pas

La valeur de l’icône doit correspondre à un nom d’icône Lucide en kebab-case.
Facet retombe sur un symbole simple quand le nom est inconnu.

## Voir aussi

- [Schéma de doctype (référence)](/fr/reference/doctype-schema/) — chaque clé de définition et sa forme.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — comment une définition façonne les documents stockés.
- [Types de champs (guide)](/fr/build/model/data/field-types/) — choisissez le type de chaque champ.
