---
title: Composition parent/enfant
description: Modélisez des enfants possédés, créés, verrouillés et supprimés avec leur document parent.
audience: [author]
features: [DOM-05, DOC-07]
sidebar:
  order: 6
verified_at: fd345fe3
---

Certains enregistrements sont des parties d’un tout. Une commande porte ses lignes, un projet porte ses tâches, un employé porte ses événements de carrière. Facet modélise cela par la composition : le parent possède ses enfants, et l’enfant ne peut pas exister hors du parent. Une déclaration sur le parent et une sur l’enfant mettent la paire en place.

## Quand l’utiliser

Utilisez la composition quand l’enfant appartient à un seul parent et disparaît avec lui. Utilisez un champ référence quand la cible existe par elle-même (voir [Références et liens entrants](/fr/build/model/relations/references-links/)).

## Avant de commencer

- **Les deux moitiés.** Le parent déclare une entrée `children`, et l’enfant déclare `member_of` en retour. Facet refuse une paire à sens unique.
- **Même domaine, nom court.** Un doctype enfant vit dans le même domaine que son parent, et son nom s’écrit sans le préfixe du domaine.

## Étapes

### 1. Déclarer le parent comme racine d’agrégat

La racine est l’enregistrement que les utilisateurs créent et suppriment. Déclarez-le avec `aggregate_root: true`.

### 2. Ajouter l’entrée `children`

Chaque entrée porte le nom de la relation, par exemple `tasks`. Ce nom devient le segment de route pour les créations imbriquées.

```json
"children": {
  "tasks": { "doctype": "Task", "collection": true }
}
```

`collection: true` porte plusieurs enfants. Une relation à enfant unique l’omet.

### 3. Déclarer l’enfant avec `member_of`

```json
"member_of": "Project",
"aggregate_root": false
```

N’ajoutez pas sur l’enfant un champ référence qui pointerait vers le parent. Facet gère lui-même le lien vers le parent.

### 4. Créer le parent avec ses enfants en un appel

Envoyez un corps en deux blocs : `$content` pour les champs du parent et `$children` pour les enfants imbriqués. Facet crée tout dans une seule transaction. Si un enfant échoue à la validation, rien n’est écrit.

### 5. S’appuyer sur les règles de composition

| Règle | Effet |
| --- | --- |
| Suppression en cascade | Supprimer le parent supprime ses enfants. |
| Verrouillage couplé | Une écriture sur un enfant verrouille le parent, pour que l’agrégat reste cohérent. |
| Création directe refusée | Un enfant créé hors de son parent répond `422`. Passez par la route imbriquée. |
| Accès hérité | Une permission sur le parent couvre l’enfant, car le chemin de l’enfant prolonge celui du parent. |
| Propagation des événements | Un changement d’enfant notifie le parent, et les champs calculés du parent se mettent à jour. |

## Exemple

Les deux définitions ci-dessous déclarent une racine `projects.Project` et son enfant `projects.Task`.

```json
{
  "domain": "projects",
  "doctype": "Project",
  "aggregate_root": true,
  "schema_version": 1,
  "display_name": "{{ name }}",
  "fields": {
    "name": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "status": { "type": "enum", "default": "planned", "filters": ["equality"],
      "values": [ { "key": "planned", "label": "Planned" }, { "key": "active", "label": "Active" } ] }
  },
  "children": {
    "tasks": { "doctype": "Task", "collection": true }
  }
}
```

```json
{
  "domain": "projects",
  "doctype": "Task",
  "aggregate_root": false,
  "member_of": "Project",
  "schema_version": 1,
  "display_name": "{{ title }}",
  "fields": {
    "title": { "type": "string", "required": true, "filters": ["equality", "text_search"] },
    "done": { "type": "boolean", "default": false }
  }
}
```

Un appel crée le projet et sa première tâche :

```sh
curl -k -X POST "https://facet.localhost:3443/Api/projects/Project" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "$content": { "name": "Apollo", "status": "active" },
    "$children": {
      "tasks": [ { "title": "Cut the keyway" } ]
    }
  }'
```

`-k` ignore la vérification du certificat de l’adresse de développement locale. La réponse porte le parent et les enfants créés. La tâche reçoit `done: false` de sa valeur par défaut.

## Dépannage

### La publication refuse la paire

Une moitié de la composition manque. Ajoutez le `member_of` sur l’enfant ou l’entrée `children` sur le parent, puis publiez à nouveau.

### Une création directe de l’enfant répond `422`

Les enfants se créent via le parent. Utilisez la route imbriquée sur le document parent, ou le corps en deux blocs montré plus haut.

### L’enfant apparaît sous un autre parent après une copie

C’est impossible. Une copie rattache l’enfant au parent copié, jamais à l’original.

### Supprimer un enfant ne supprime pas le parent

Exact. La cascade ne va que vers le bas : supprimer le parent retire ses enfants.

## Voir aussi

- [Schéma de doctype (référence)](/fr/reference/doctype-schema/) — les clés `children` et `member_of` en détail.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — comment le lien vers le parent est stocké.
- [Sidecars (commentaires, pièces jointes)](/fr/build/model/relations/comments-attachments/) — attacher un panneau de discussion au parent.
