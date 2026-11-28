---
type: reference
title: La disposition des fichiers d’un domaine
description: Les fichiers que le watcher lit, un par un — le même format qu’une exportation de bundle écrit.
audience: [developer]
features: [DOM-19, DOM-15]
sidebar:
  order: 1
verified_at: eee55a2
---

Un domaine en fichiers tient dans un arbre de répertoires. Le watcher le
lit, une exportation de bundle l’écrit, et un import de bundle le consomme
— un format, trois usages. Cette page liste chaque fichier que porte le
format, avec l’exemple complet de Brightwater Rentals.

## L’arbre

```
{domain}.facet-domain/
├── bundle.yml                       # identité : version du format, domaine source, horodatages
├── domain.yml                       # le document du domaine : libellé, description, couleur, hooks
├── hooks/
│   └── {i}-{hook_id}.lua            # un fichier de script par hook du domaine
├── doctypes/
│   ├── {domain}.{Doctype}.yml       # un fichier par définition de doctype
│   └── {domain}.{Doctype}.lua       # le script de cycle de vie du doctype, à côté de sa définition
├── views/
│   └── {domain}.{Doctype}/
│       ├── document_views/
│       │   └── {kind}.yml           # view, form, quickView, inline, card
│       └── collection_views/
│           └── {slug}.yml           # vues de liste partagées
└── documents/                       # seulement quand l’exportation a utilisé --with-documents
    └── {domain}.{Doctype}/
        └── {doc_id}.yml             # un fichier par document
```

Le watcher lit exactement cet arbre. `facet domain:export` écrit
exactement cet arbre — sous forme de répertoire, de `.zip` ou de
`.tar.gz`. C’est la clé du aller-retour : construisez en fichiers,
exportez ce que vous avez construit, importez-le ailleurs.

## Chaque fichier, dans l’ordre

### `bundle.yml`

Quatre champs fixes. `source_domain` est l’identité — le watcher et
l’import ciblent tous deux ce nom de domaine.

```yml
format_version: 2
source_domain: equipment
exported_at: "2026-11-26T12:00:00Z"
facet_version: 0.2.2
```

| Champ | Signification |
| --- | --- |
| `format_version` | La version de la disposition. Actuelle : `2`. Le lecteur charge encore les bundles en version `1`. |
| `source_domain` | Le nom du domaine sur l’instance qui exporte — la cible de l’import. |
| `exported_at` | L’horodatage RFC-3339 UTC de l’exportation. |
| `facet_version` | La version de Facet qui a produit le bundle. Comparez-la avec celle de la cible. |

### `domain.yml`

Le document du domaine : un bloc `content` et un bloc `meta`. Le libellé,
la description et la couleur sont ce que l’interface affiche. Les hooks du
domaine voyagent ici aussi, leur Lua externalisé dans `hooks/`.

```yml
content:
  color: "#0F766E"
  description: Rental equipment — items, categories, and maintenance tickets.
meta: {}
```

### `doctypes/{domain}.{Doctype}.yml`

Une définition de doctype par fichier, nommée par l’id qualifié. Voici le
doctype `Category` complet du domaine `equipment` de Brightwater — une
définition petite mais réelle :

```yml
content:
  icon: tags
  color: "#0d9488"
  domain: equipment
  fields:
    name:
      type: string
      title: Name
      required: true
      unique: true
      filters:
        - equality
        - text_search
      description: "Category name, e.g. 'Tents', 'Sound', 'Lighting'."
  doctype: Category
  description: "A family of rental equipment."
  display_name: "{{ name }}"
  search: "{{ name }}"
  aggregate_root: true
  schema_version: 1
meta:
  parent_id: equipment
```

| Clé | Signification |
| --- | --- |
| `domain` / `doctype` | L’identité. L’id qualifié `{domain}.{doctype}` est aussi le nom du fichier. |
| `schema_version` | Commence à `1`. En mode fichiers vous pouvez le réécrire librement — le watcher applique la définition telle quelle. |
| `fields` | La table des champs. Chaque cible `reference` prend la forme qualifiée `domain.Doctype`. |
| `display_name` / `search` | Les modèles Jinja2 pour le libellé et le corpus de recherche. |
| `aggregate_root` | `true` pour un doctype autonome ; un enfant déclare `member_of` à la place. |
| `meta.parent_id` | Le domaine auquel le doctype appartient. |

Un doctype qui déclare des `actions`, des champs calculés ou des scripts
de cycle de vie porte son Lua à côté de la définition, référencé avec une
balise `!read_file` :

```yml
  script: !read_file equipment.Item.lua
  actions:
    send_to_repair:
      args: {}
```

Le lecteur développe `!read_file` en le contenu du fichier à l’import : le
aller-retour est sans perte.

### `views/{domain}.{Doctype}/document_views/{kind}.yml`

Un fichier par type de page d’un doctype : `view` (la page détail),
`form` (le formulaire de création/modification), `quickView` (le tiroir
d’aperçu), `inline` (les lignes dans une page parente), `card`. L’arbre de
modèles relie les nœuds d’entrée aux noms de champs.

### `views/{domain}.{Doctype}/collection_views/{slug}.yml`

Un fichier par vue de liste partagée : une configuration de table, de
kanban ou de calendrier. Le nom du fichier est opaque pour l’import — une
exportation écrit un slug généré, et un nom écrit à la main fait pareil.

### `documents/{domain}.{Doctype}/{doc_id}.yml`

Présent seulement quand le bundle a été exporté avec `--with-documents`.
Un fichier par document, avec son contenu et son meta. L’import les rejoue
de façon idempotente : une ligne qui existe déjà est ignorée. Le watcher
les rejoue à neuf à chaque enregistrement en mode `discard`, et ne remplit
que les lignes manquantes en mode `preserve`.

## Ce qui ne voyage pas ici

Un bundle porte des définitions, pas l’instance autour :

- **Les rôles et les comptes.** Ils appartiennent au domaine `iam` et ne
  voyagent pas dans les fichiers de domaines. Créez-les sur l’instance
  cible via l’API ou la CLI — voir
  [Du dev à la production](/fr/build/model/dev-to-production/).
- **Les attributions.** Les attributions inter-domaines sont des documents
  de consentement sous le domaine producteur. Un import dépose des
  *tickets* pour les liens qu’il trouve ; le producteur les accepte
  là-bas.
- **Les vues de liste personnelles.** Une vue de liste que vous avez
  enregistrée pour vous est une donnée d’utilisateur.
- **L’historique.** Le journal des changements d’un domaine reste sur son
  instance.

## Partir d’une exportation, pas de tête

Le plus rapide pour démarrer un domaine en mode fichiers est de construire
le premier doctype dans l’app et de l’exporter :

```sh
facet domain:export equipment --output equipment.facet-domain
```

Modifiez l’arbre exporté, faites pointer le watcher sur le dossier parent,
et continuez en fichiers. Chaque détail structurel — les blocs `meta`, les
balises `!read_file`, les formes de vues — est déjà correct.

## Voir aussi

- [Le watcher de domaines](/fr/build/model/in-files/domain-watcher/) — appliquez ce dossier à un serveur de dev.
- [Déplacer des domaines avec des bundles](/fr/build/model/bundles/) — les commandes d’exportation et d’import.
- [Du dev à la production](/fr/build/model/dev-to-production/) — ce qui voyage et ce qui ne voyage pas.
- Doc interne sur GitHub : [portable-domains.md](https://github.com/wearefacet/facet/blob/main/doc/backend/portable-domains.md).
