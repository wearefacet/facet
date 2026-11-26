---
title: Modèles de vue
description: Composez la page document, le formulaire et le tiroir d’aperçu avec des modèles de vue.
audience: [author]
features: [DOM-22, FE-04]
sidebar:
  order: 14
verified_at: fd345fe3
---

Un doctype décide de l’allure de ses pages document. Un modèle de vue est un petit arbre de mise en page stocké sur le doctype. Facet le rend sur la page détail, le formulaire et le tiroir d’aperçu. Sans modèle, chaque surface retombe sur une mise en page générique : une ligne par champ.

## Quand l’utiliser

- La liste de champs par défaut cache la structure de vos documents.
- Vous voulez un en-tête avec une pastille de statut, des sections groupées, ou une table de lignes enfants.
- Le formulaire doit placer les champs côte à côte au lieu d’une longue colonne.

## Avant de commencer

- **Droits d’écriture** (`update`) sur la définition du doctype.
- **Les champs.** Connaissez les noms et les types des champs à afficher.
- **L’onglet Vues.** Ouvrez le doctype dans **Configurer**, puis l’onglet **Vues**. L’onglet liste les modèles du doctype et en montre un aperçu.

## Étapes

### 1. Choisissez le `kind`

Chaque modèle porte un `kind`. Un modèle par `kind` :

| Kind | Surface |
| --- | --- |
| `view` | La page détail du document. |
| `form` | Les formulaires de création et de modification. |
| `quickView` | Le tiroir d’aperçu à côté d’une liste. |
| `card` | La carte sur un tableau kanban. |
| `inline` | Une ligne dans une table de relations éditable. |

Un nouveau doctype démarre sans modèle. Chaque surface utilise alors la mise en page générique ; un modèle reste facultatif pour chaque `kind`.

### 2. Construisez la mise en page avec des nœuds

Un modèle est un arbre de nœuds. Chaque nœud porte un `type` et quelques propriétés. Les nœuds les plus utilisés :

| Nœud | Rôle |
| --- | --- |
| `section` | Un groupe de lignes avec libellé. |
| `header` | L’en-tête de page : pastille de statut, pastilles, sous-titre, logo. |
| `field` | Une ligne de valeur avec libellé. Écrivez la valeur sous la forme `$field_name`. |
| `markdown` | Un champ texte long, rendu en markdown. |
| `grid`, `row`, `col` | Conteneurs de mise en page. Un `grid` prend des fractions comme `3 1`. |
| `tabs` | Des zones à onglets ; chaque `tab` porte des enfants. |
| `sidebar` | La colonne de droite d’une page détail ; placez-y `record-meta` pour la provenance. |
| `relation` | Une table de documents enfants ou liés, avec des `columns`. |
| `input` | Un contrôle de formulaire ; il choisit le contrôle d’après le type déclaré du champ. |

D’autres nœuds existent pour les conditions (`if`), les données imbriquées (`object`, `array`, `dict`), les liens (`link`, `email`), les images (`image-artifact`) et les contrôles forcés (`input-text`, `input-money`).

### 3. Enregistrez et vérifiez

Enregistrez le modèle. Facet le valide contre le doctype : un `input` lié à un champ inconnu ou à un champ en lecture seule est une erreur ; un `kind` `view`, `form` ou `quickView` manquant ne donne qu’une remarque, car la mise en page générique le couvre. Lancez la vérification pour voir le rapport. Voir [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/).

## Exemple

Un doctype `helpdesk.Ticket` porte les champs `title` (string), `status` (enum : open, closed), `priority` (enum), `due_date` (date), `description` (longtext) et `owner_id` (reference). Ce modèle complet est celui du `kind` `view` du doctype :

```yaml
content:
  kind: view
  parent_doctype: helpdesk.Ticket
  template:
    type: col
    children:
      - type: header
        statusField: status
        chips:
          - priority
        subtitle: "Owned by $owner_id"
      - type: grid
        layout: 3 1
        children:
          - type: col
            children:
              - type: section
                label: Details
                children:
                  - type: markdown
                    field: description
                  - type: field
                    label: Due date
                    value: $due_date
          - type: sidebar
            children:
              - type: section
                label: Owner
                children:
                  - type: field
                    value: $owner_id
              - type: record-meta
                history: true
meta:
  parent_id: helpdesk.Ticket
```

Un document stocke :

```json
{
  "title": "Printer stops mid job",
  "status": "open",
  "priority": "high",
  "due_date": "2026-12-01",
  "description": "The queue stops after page two.",
  "owner_id": "iam.Account.01JCATPMKP4N82GVG2J7K4MHZZ"
}
```

La page détail rend alors : un en-tête avec la pastille de statut dans la couleur de l’enum, la priorité à côté, et le sous-titre **Owned by** avec le libellé du compte référencé ; la description en markdown rendu sous **Details**, avec **Due date** à côté ; et une colonne **Owner** avec le libellé du compte et un lien vers l’historique. Les valeurs de référence ne s’affichent jamais comme des ids bruts.

## Dépannage

**Une ligne de champ n’affiche rien.**

Le `$field_name` du modèle ne correspond pas à un champ stocké. Vérifiez l’orthographe contre la définition du doctype.

**Un contrôle de formulaire manque pour un champ.**

Le type du champ n’a pas de contrôle éditable dans ce nœud, ou le champ est en lecture seule. Utilisez le nœud `input` simple, qui choisit le contrôle d’après le type déclaré.

**La vérification liste des problèmes de modèle avec des chemins comme `template.children.2`.**

Chaque problème nomme sa place dans l’arbre. Ouvrez l’onglet Vues, allez jusqu’à ce nœud, et corrigez la liaison ou la propriété.

## Voir aussi

- [Référence du schéma de doctype](/fr/reference/doctype-schema/) — les champs qu’un modèle lie.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — ce que rend une page document.
- [Vues de collection](/fr/build/model/views/lists-boards-calendars/) — configurez les pages de liste à côté des pages document.
