---
title: Vues de collection
description: "Ajoutez à la page de liste d’un doctype des vues enregistréesà : tableau, kanban et calendrier."
audience: [author]
features: [DOM-21]
sidebar:
  order: 15
verified_at: f1409cdc
---

Une page de liste affiche un onglet par vue enregistrée. Chaque vue porte un nom et une surfaceà : un tableau avec des colonnes choisies, un kanban avec des couloirs, ou un calendrier posé sur des dates. Les vues sont des documents du doctype, donc vous décidez quels onglets chaque utilisateur voit.

## Quand l’utiliser

- Les colonnes par défaut ne conviennent pas au travail d’une équipe.
- Une équipe travaille sur les documents en cartes, déplacées selon un statut ou une valeur.
- Un planning compte plus que l’ordre des lignes, par exemple des visites planifiées.

## Avant de commencer

- **Droit de création.** Il faut le droit de créer des vues sur le doctype. Sans lui, le bouton plus de la barre d’onglets reste caché.
- **De bons candidats.** Sachez quels champs font de bonnes colonnes, de bons couloirs ou de bonnes dates de calendrier.

## Étapes

### 1. Ouvrez l’éditeur de vues

Ouvrez la page de liste du doctype. La barre d’onglets au-dessus du tableau liste les vues enregistrées. Sélectionnez le bouton plus, au bout de la barre d’onglets (**Créer une nouvelle vue**), pour ouvrir l’éditeur de vues.

### 2. Choisissez la surface

| Surface | Ce que vous configurez |
| --- | --- |
| `table` | Une liste ordonnée de colonnes. Chaque colonne porte une clé, un libellé et une largeur facultative. |
| `kanban` | Un champ `group_by` avec `mode: values`, ou des couloirs fixes avec un filtre chacun (`mode: custom`). |
| `calendar` | Un champ date `discriminator`, un `end_field` facultatif, un champ `color_by`, et un `title_template` pour les pastilles. |

### 3. Définissez les colonnes ou les couloirs

Pour un tableau, ajoutez une entrée par colonne, dans l’ordre d’affichage. Pour un kanban, groupez par un champ enum pour que Facet construise un couloir par valeur, ou écrivez vos propres couloirs avec un filtre chacun. Pour un calendrier, choisissez le champ date qui positionne une entrée, et facultativement une seconde date comme fin de plage.

:::tip
Le titre d’une entrée de calendrier peut porter des valeurs de champs. Écrivez un template Jinja2 dans `title_template`, par exemple `{{ title }}`. Seuls les champs du doctype y sont admis.
:::

### 4. Choisissez qui voit la vue

Une vue est **générale** (tout lecteur du doctype la voit) ou **personnelle** (vous seul la voyez). L’éditeur affiche l’interrupteur quand votre rôle peut créer des vues générales. Le choix est figé après l’enregistrement.

:::caution
Une vue ne peut plus basculer ensuite entre personnelle et générale. Créez une nouvelle vue et supprimez l’ancienne.
:::

### 5. Enregistrez, partagez, épinglez

Enregistrez la vue. Son onglet apparaît au-dessus du tableau, et le lien de la barre d’adresse ouvre directement cette vue. Vous pouvez épingler un onglet pour l’avoir sous la mainà ; l’épinglage reste une préférence personnelle et fonctionne aussi pour les vues générales.

## Exemple

Un doctype `crm.Deal` porte une vue tableau générale nommée **All Deals**. Voici sa configuration complèteà :

```yaml
content:
  name: All Deals
  surface: table
  config:
    columns:
      - key: title
        label: Deal
      - key: value
        label: Value
        width: 120px
      - key: status
        label: Status
        width: 110px
      - key: probability
        label: Prob.
        width: 90px
      - key: expected_close_date
        label: Expected Close
        width: 150px
meta:
  parent_id: crm.Deal
```

La page de liste affiche alors un onglet **All Deals**. Le tableau rend les cinq colonnes dans cet ordre, avec les largeurs indiquées. Une colonne booléenne peut porter `editable: true` ; les lecteurs qui détiennent `update` la basculent alors sur place.

Une seconde vue du même doctype affiche les mêmes affaires en kanban :

```yaml
content:
  name: Pipeline
  surface: kanban
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
meta:
  parent_id: crm.Deal
```

## Ce que vous obtenez d’office

Chaque doctype est livré avec une vue tableau générale nommée **All Records**. Facet la crée avec le doctype et la remplit avec les huit premiers champs scalaires. Les colonnes booléennes sont créées éditables en ligne, sauf celles en `read_only` et `write_only`. Ce réglage de départ est un indice, pas une permission : le tableau n’affiche l’interrupteur que pour un lecteur qui détient `update` sur le doctype. Sans ce droit, la même cellule affiche simplement vrai ou faux. Vous pouvez modifier ou supprimer cette vue comme une autreà ; Facet ne la reconstruit pas après un changement de la liste des champs. Une publication ne touche jamais les vues de collection, et une fusion de bundle met à jour les vues générales par nom, mais ne supprime jamais une vue qui n’existe que sur la cible.

## Dépannage

**Une colonne n’affiche aucune valeur.**

La clé de colonne ne correspond pas à un champ stocké. Vérifiez l’orthographe et l’imbrication : un champ object demande un chemin comme `address.city`.

**Le calendrier n’affiche aucune entrée.**

Le champ discriminateur n’est ni un champ date, ni un datetime, ni un period, ou les valeurs stockées sont vides. Choisissez un champ date, ou utilisez les timestamps système `created_at` et `updated_at`.

**Un couloir de kanban reste vide.**

Le filtre du couloir ne correspond à aucune ligne. Comparez les valeurs du filtre avec celles stockéesà ; un filtre money exige la devise, par exemple `"USD 25000"`.

## Voir aussi

- [Référence des vues de collection](https://github.com/wearefacet/facet/blob/main/doc/backend/collection-view.md) — toutes les clés de configuration par surface.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) — ce que lit une liste.
- [Périmètres nommés](/fr/build/named-scopes/) — limitez les lignes que chaque rôle voit dans les vues.
