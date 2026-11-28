---
type: how-to
title: Listes, kanban et calendriers
description: "Offrez à la page de liste d’un doctype des vues enregistrées : tableau, kanban et calendrier."
audience: [author]
features: [DOM-21, DOM-29, DOM-32]
sidebar:
  order: 2
verified_at: c34885a
---

L’entrepôt de Brightwater suit quarante objets en location, et l’équipe de maintenance traite les tickets en cartes, pas en lignes. La page de liste d’un doctype affiche un onglet par vue enregistrée, et chaque vue porte un nom et une surface : un tableau avec des colonnes choisies, un tableau kanban avec ses colonnes, ou un calendrier posé sur des dates. Les vues sont des documents du doctype, donc vous décidez quels onglets chaque utilisateur voit.

## Quand l’utiliser

- Le jeu de colonnes par défaut ne convient pas au travail d’une équipe.
- Une équipe travaille sur les documents en cartes, déplacées selon un statut ou une valeur.
- Un planning compte plus que l’ordre des lignes, par exemple des visites planifiées.

## Avant de commencer

- **Droit de création.** Vous avez besoin du droit de créer des vues sur le doctype. Sans lui, le bouton plus de la barre d’onglets reste masqué et l’écran d’accueil affiche une note au lieu de cartes.
- **De bons candidats.** Sachez quels champs font de bonnes colonnes de tableau, de bons regroupements de kanban ou de bonnes dates de calendrier.

## Créer une vue

Ouvrez la page de liste du doctype. La barre d’onglets au-dessus du tableau liste les vues enregistrées. Sélectionnez le bouton plus, au bout de la barre (**Créer une nouvelle vue**), pour ouvrir l’éditeur de vues. Un doctype sans vue affiche à la place l’écran d’accueil : une carte par surface — tableau, kanban, calendrier. Choisissez une carte et l’éditeur s’ouvre avec cette surface présélectionnée.

### Choisir la surface

| Surface | Ce que vous configurez |
| --- | --- |
| `table` | Une liste de colonnes ordonnée. Chaque colonne porte une `key`, un `label` facultatif et une `width` facultative. |
| `kanban` | Un champ `group_by` avec `mode: values`, ou des colonnes fixes avec un filtre chacune (`mode: custom`). |
| `calendar` | Un champ date `discriminator`, un `end_field` facultatif, un champ `color_by`, un `week_start` et un `title_template` pour les pastilles. |

À l’enregistrement, Facet valide la configuration contre le doctype. Un champ de regroupement kanban doit être un champ enum ou booléen inscriptible qui sert les filtres d’égalité ; un discriminateur de calendrier doit être un champ period, ou un champ date ou datetime qui sert les filtres de comparaison. Une configuration qui ne peut pas se rendre répond `422` avec le chemin du champ, au lieu de produire une surface vide. Le calendrier est proposé pour tout doctype : les timestamps système `created_at` et `updated_at` servent de discriminateur quand le doctype n’a aucun champ date propre.

:::tip
Le titre d’une pastille de calendrier peut porter des valeurs de champs. Écrivez un template Jinja2 dans `title_template`, par exemple `{{ name }}`. Seuls les champs du doctype, la variable réservée `content` et les timestamps système y sont admis.
:::

### Définir les colonnes

En mode valeurs, un kanban dérive une colonne par valeur du champ de regroupement, dans l’ordre déclaré du champ. L’éditeur de vues adapte cette présentation pour chaque vue : montez et descendez les colonnes, et masquez-en avec l’interrupteur de visibilité — au moins une colonne doit rester visible. Les colonnes masquées ne se rendent pas et ne chargent pas de données ; les autres suivent l’ordre enregistré. Activez **Autoriser le déplacement des cartes** pour activer le glisser-déposer entre les colonnes. Un déplacement passe par la mise à jour normale du document, donc l’historique le note et les droits de mise à jour habituels s’appliquent.

### Choisir qui voit la vue

Une vue est **générale** (tout lecteur du doctype la voit) ou **personnelle** (vous seul la voyez). L’éditeur affiche le choix quand votre rôle peut créer des vues générales ; un rôle limité à ses propres lignes ne crée que des vues personnelles. Le choix fait partie de la vue dès sa création.

:::caution
Une vue ne peut plus basculer ensuite entre personnelle et générale. Pour la changer, créez une nouvelle vue avec le bon public et supprimez l’ancienne.
:::

### Enregistrer et épingler

Enregistrez la vue. Son onglet apparaît au-dessus du tableau, et la barre d’adresse porte un lien profond vers elle. Vous pouvez épingler un onglet pour l’avoir sous la main ; l’épinglage reste une préférence personnelle et vaut pour les vues générales comme pour les vues personnelles.

### En fichiers

En mode fichiers, les mêmes vues sont des fichiers YAML dans le dossier du domaine, sous `views/<domain>.<Doctype>/collection_views/`. Voici le tableau de maintenance de Brightwater :

```yaml
# equipment/views/equipment.MaintenanceTicket/collection_views/
#   equipment.MaintenanceTicket.collection_view.board.yml
content:
  name: Board
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
  surface: kanban
meta:
  parent_id: equipment.MaintenanceTicket
```

Le watcher applique le fichier à l’enregistrement — voir [Le watcher de domaines en dev](/fr/build/model/in-files/domain-watcher/).

## Exemple

L’exemple Brightwater porte trois vues enregistrées à titre de comparaison.

**Un tableau.** La liste des objets est livrée avec une vue générale, **All items**, avec cinq colonnes dans l’ordre d’affichage :

```yaml
content:
  name: All items
  config:
    columns:
      - key: name
      - key: category
        width: 140px
      - key: status
        width: 120px
      - key: serial_number
        width: 160px
      - key: purchase_price
        width: 140px
  surface: table
meta:
  parent_id: equipment.Item
```

Une colonne liée à un champ booléen peut porter `editable: true`. Les lecteurs qui détiennent le droit de mise à jour la basculent alors sur place ; le backend revérifie chaque bascule.

**Un tableau kanban.** Les tickets de maintenance se regroupent par leur enum de statut, une colonne par valeur :

```yaml
content:
  name: Board
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
  surface: kanban
meta:
  parent_id: equipment.MaintenanceTicket
```

Chaque carte se rend par le modèle de vue `card` du doctype — voir [Concevoir les pages document](/fr/build/model/views/document-pages/). Avec `mode: custom`, vous écrivez vos propres colonnes, chacune avec un libellé, une couleur facultative et un filtre.

**Un calendrier.** Les réservations se placent sur leur période de dates :

```yaml
content:
  name: Calendar
  config:
    calendar:
      color_by: status
      week_start: monday
      discriminator: dates
  surface: calendar
meta:
  parent_id: rentals.Booking
```

## L’état vide

Un doctype est livré **sans** vue. Facet n’en crée jamais de son propre chef — ni à la création du doctype, ni au démarrage. Tant que la première vue n’existe pas, la page de liste affiche l’écran d’accueil, et le rapport `/check` porte une remarque d’information qui en demande une. Cette remarque n’est pas une erreur : rien n’est cassé, le doctype n’a simplement pas encore de surface de liste.

Vous pouvez modifier ou supprimer une vue comme n’importe quel document. Supprimer la dernière vue ramène l’écran d’accueil, et Facet ne recrée pas la vue. Une publication ne touche jamais les vues de collection enregistrées, et une fusion de bundle met à jour les vues générales par nom, mais ne supprime jamais une vue qui n’existe que sur la cible.

## Dépannage

**Une colonne n’affiche aucune valeur.**

La clé de colonne ne correspond pas à un champ stocké. Vérifiez l’orthographe et l’imbrication : un champ objet demande un chemin comme `address.city`.

**Le calendrier n’affiche aucune entrée.**

Le champ discriminateur ne sert pas le filtre de fenêtre, ou les valeurs stockées sont vides. Choisissez un champ date ou period, ou utilisez les timestamps système `created_at` et `updated_at`.

**Une colonne de kanban reste vide.**

Le filtre de la colonne ne correspond à aucune ligne. Comparez les valeurs du filtre avec celles stockées ; un filtre monétaire exige la devise, par exemple `"EUR 25000"`.

**L’éditeur masque le choix général.**

Votre rôle ne peut créer que des vues personnelles. Un administrateur élargit la permission de création sur les vues — voir [Les périmètres de lignes](/fr/admin/people/row-scopes/).

## Voir aussi

- [Concevoir les pages document](/fr/build/model/views/document-pages/) — les surfaces qu’un utilisateur ouvre depuis une ligne de liste.
- [Libellés et texte de recherche](/fr/build/model/views/names-and-search/) — le libellé que chaque ligne affiche.
- [Les périmètres de lignes](/fr/admin/people/row-scopes/) — limitez les lignes que chaque rôle voit dans les vues.
- Fonctionnement interne sur GitHub : [collection-view.md](https://github.com/wearefacet/facet/blob/main/doc/backend/collection-view.md).
