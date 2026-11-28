---
type: how-to
title: Concevoir les pages document
description: Agencez la page détail, le formulaire et le tiroir d’aperçu avec des modèles de vue.
audience: [author]
features: [DOM-22, FE-04]
sidebar:
  order: 1
verified_at: eee55a2
---

Vos utilisateurs ouvrent un document cent fois par jour, et la mise en page par défaut empile tous les champs dans une longue colonne. Un modèle de vue est un petit arbre de mise en page stocké sur le doctype. Facet le rend sur la page détail, le formulaire et le tiroir d’aperçu : une équipe d’entrepôt voit alors une pastille de statut et des sections groupées à la place d’une liste de champs. Aucun code n’est nécessaire — le modèle est un arbre JSON que vous modifiez dans le Builder ou dans un fichier YAML.

## Quand l’utiliser

- La liste de champs par défaut masque la structure de vos documents.
- Vous voulez un en-tête avec une pastille de statut, des sections groupées ou une table de lignes enfants.
- Le formulaire doit placer les champs côte à côte au lieu d’une longue colonne.

## Avant de commencer

- **Droits de mise à jour** sur la définition du doctype.
- **Les champs.** Connaissez les noms et les types des champs à afficher.
- **L’onglet Vues.** Ouvrez le doctype dans **Configurer** (ou le brouillon dans le **Builder**), puis l’onglet **Vues**. Il liste les cinq types avec un aperçu, et un mode **Modifier** avec un éditeur JSON.

## Les cinq types

Chaque modèle porte un type (kind). Un modèle par type :

| Type | Surface |
| --- | --- |
| `view` | La page détail du document. |
| `form` | Les formulaires de création et de modification. |
| `quickView` | Le tiroir d’aperçu à côté d’une liste. |
| `card` | La carte sur un tableau kanban. |
| `inline` | Une ligne dans une table de relations modifiable. |

Un nouveau doctype démarre sans modèle. Chaque surface utilise alors une mise en page générique que Facet construit à partir de la liste des champs, donc un modèle reste facultatif pour chaque type. Les types absents apparaissent comme des remarques d’information dans le rapport de vérification, pas comme des erreurs — la mise en page générique les couvre.

## Construire la mise en page à partir des nœuds

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

D’autres nœuds existent pour les conditions (`if`), les données imbriquées (`object`, `array`, `dict`), les liens (`link`, `email`), les images (`image-artifact`) et les contrôles forcés (`input-text`, `input-money`). La grammaire complète des nœuds, avec chaque propriété requise, se trouve dans le [Schéma du modèle DVT](/fr/reference/dvt-schema/).

## Enregistrer et vérifier

Enregistrez le modèle. Facet le valide contre le doctype et refuse toute écriture qui porte une erreur bloquante :

- un `input` lié à un champ inconnu, à un chemin pointé ou à un champ conteneur ou calculé est une erreur — le formulaire ne pourrait jamais enregistrer une telle valeur ,
- un `input` lié à un champ `read_only` est un avertissement — le nœud se rend, mais la valeur ne peut jamais être enregistrée ,
- un type de nœud inconnu, une liste d’options vide ou une colonne de relation dupliquée est un avertissement — le nœud se rend mais se dégrade.

Chaque problème nomme sa place dans l’arbre, par exemple `template.children.2.field`. Ouvrez l’onglet Vues, naviguez jusqu’à ce nœud et corrigez la liaison. Lancez **Vérification** pour voir le rapport complet — voir [Vérifier un domaine avant publication](/fr/build/model/in-app/check-before-publish/).

## Exemple

Le doctype `equipment.Item` de Brightwater porte un modèle `form`. Voici sa valeur `template` complète :

```json
{
  "type": "col",
  "children": [
    { "type": "section", "label": "Item", "children": [
      { "type": "row", "layout": "2fr 1fr", "children": [
        { "type": "input", "field": "name" },
        { "type": "input", "field": "category" }
      ]}
    ]},
    { "type": "section", "label": "Stock", "children": [
      { "type": "row", "layout": "repeat(3, minmax(140px, 1fr))", "children": [
        { "type": "input", "field": "status" },
        { "type": "input", "field": "serial_number" },
        { "type": "input", "field": "purchase_price" }
      ]}
    ]},
    { "type": "section", "label": "Notes", "children": [
      { "type": "input", "field": "notes" }
    ]}
  ]
}
```

Le formulaire de création rend trois groupes avec libellés. `name` et sa catégorie sont côte à côte, les trois champs de stock partagent une ligne, et les notes occupent toute la largeur. Chaque `input` choisit son contrôle d’après le type déclaré du champ : un sélecteur de référence pour `category`, une liste de statuts pour `status`, un champ monétaire pour `purchase_price`.

Le même doctype porte un modèle `card` pour le tableau kanban :

```json
{
  "type": "col",
  "children": [
    { "type": "field", "label": "Status", "value": "$status" },
    { "type": "field", "label": "Serial number", "value": "$serial_number" }
  ]
}
```

Chaque carte des listes d’objets liées du tableau de maintenance montre le statut et le numéro de série. Les valeurs de référence ne s’affichent jamais comme des ids bruts : un `$field` qui pointe vers un autre document rend le libellé du document référencé.

En mode fichiers, les deux modèles se trouvent dans `views/equipment.Item/document_views/form.yml` et `.../card.yml` dans le dossier du domaine — voir [La structure des fichiers de domaine](/fr/build/model/in-files/domain-files/).

## Dépannage

**Une ligne de champ n’affiche rien.**

Le `$field_name` du modèle ne correspond pas à un champ stocké. Vérifiez l’orthographe contre la définition du doctype.

**Un contrôle de formulaire manque pour un champ.**

Le champ est en lecture seule, ou son type n’a pas de contrôle dans ce nœud. Utilisez le nœud `input` simple, qui choisit le contrôle d’après le type déclaré.

**La vérification liste des problèmes de modèle avec des chemins comme `template.children.2`.**

Chaque problème nomme sa place dans l’arbre. Ouvrez l’onglet Vues, naviguez jusqu’à ce nœud et corrigez la liaison ou la propriété.

## Voir aussi

- [Schéma du modèle DVT](/fr/reference/dvt-schema/) — chaque type de nœud et chaque propriété requise.
- [Listes, kanban et calendriers](/fr/build/model/views/lists-boards-calendars/) — configurez les pages de liste à côté des pages document.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) — d’où une page document tire son contenu.
