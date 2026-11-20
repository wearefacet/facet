---
title: Listes, filtres et vues enregistrées
description: Travailler une liste en tableau, kanban ou calendrier, la filtrer, puis enregistrer le résultat comme vue.
audience: [user]
features: [FE-03, DOC-02, DOM-21]
sidebar:
  order: 3
verified_at: 49d7c7e5
---

Vos enregistrements vivent dans des listes. Chaque doctype en ouvre une, et
vous choisissez la disposition qui convient au travailà :

- **Tableau** — quand vous avez besoin de détail, de colonnes et de tri.
- **Kanban** — quand le travail passe par des étapes.
- **Calendrier** — quand les dates comptent.

Resserrez la liste avec des filtres, triez-la, puis enregistrez le réglage
comme **vue enregistrée** : un onglet nommé que vous rouvrez en un clic,
ou que vous partagez avec votre équipe.

## Avant de commencer

- **L’accès en lecture.** Il vous faut l’accès en lecture au doctype. Sans
  lui, Facet n’affiche pas la liste. Voir
  [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).
- **Les droits sur les vues.** Pour créer ou changer des vues enregistrées,
  votre rôle a besoin des droits create ou update sur les vues. Sans eux, vous
  pouvez encore utiliser les vues que votre équipe partage.

## Étapes

### 1. Ouvrez une liste

Ouvrez un domaine, puis sélectionnez un doctype. La liste s’ouvre sur la
première vue enregistrée. Vous pouvez aussi ouvrir une vue directement depuis
le tableau de bord du domaine.

Chaque doctype livre une vue tableau générale nommée « All Records ». Une
liste peut porter d’autres vues. Les onglets au-dessus du tableau les
montrent, chacun avec une icône pour sa disposition : tableau, kanban ou
calendrier.

<!-- d2
tab: "Select a tab" {class: external}
layout: "Which layout?" {class: decision}
table: "Rows and sortable columns"
kanban: "Cards in lanes"
calendar: "Chips on a date grid"

tab -> layout
layout -> table: Table
layout -> kanban: Kanban
layout -> calendar: Calendar
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/22678345-light.svg" alt="Select a tab" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/22678345-dark.svg" alt="Select a tab" loading="lazy" />
</div>

### 2. Choisissez la disposition

Chaque disposition convient à un travail différentà :

- **Tableau** — une ligne par enregistrement, une colonne par champ.
  Utilisez-la quand vous avez besoin de détail. La barre d’outils en haut
  porte la zone de recherche, le menu « + Ajouter un filtre », et les
  commandes d’export et d’import.
- **Kanban** — des cartes en colonnes. Une colonne regroupe les
  enregistrements par un champ, par exemple le statut. Utilisez-le quand le
  travail passe par des étapes. Chaque carte montre le nom de l’enregistrement
  et son heure de mise à jour. Les colonnes se chargent
  indépendammentà : une colonne lente ou vide ne bloque jamais le
  tableau. Une colonne avec plus d’enregistrements que la première page
  affiche « Afficher plus ».
- **Calendrier** — des enregistrements posés sur une grille de mois ou de
  semaine, selon le champ de date de la vue. Utilisez-le quand les dates
  comptent. Basculez entre « Mois » et « Semaine », déplacez-vous avec
  « Précédent », « Suivant » et « Aujourd’hui ». Un jour chargé replie ses
  puces en une seule puce de groupe, par exemple `4 documents`. Sélectionnez
  le groupe pour lister les enregistrements.

  Dans chaque disposition, sélectionnez une ligne, une carte ou une puce pour
  ouvrir l’enregistrement dans le tiroir d’aperçu. Le tiroir porte un aperçu
  plus les commandes « Modifier » et « Ouvrir en pleine page ».

### 3. Resserez la liste avec des filtres

Les filtres ne gardent que les enregistrements dont vous avez besoin.
Utilisez la barre d’outilsà :

1. Sélectionnez « + Ajouter un filtre ». Un menu liste les champs filtrables.
2. Sélectionnez un champ. Une puce apparaît, avec l’opérateur et une commande
   de valeur.
3. Choisissez l’opérateur et saisissez une valeur. La liste se met à jour
   pendant la saisie.

Le menu des opérateurs n’offre que les comparaisons que le champ
supporteà :

| Opérateur | Libellé | Pour |
| --- | --- | --- |
| égalité | `is` ou `=` | Texte, listes de choix, références, nombres, dates |
| différence | `is not` ou `à` | Les mêmes champs |
| comparaison | `>`, `≥`, `<`, `≤` | Nombres, dates, montants |
| intervalle | `between` | Deux bornes, par exemple une plage de dates |
| ensemble | `is any of` | Plusieurs valeurs d’une liste de choix à la fois |
| texte | `contains` | Une partie de mot, sans sensibilité à la casse |

Une puce `between` ou `is any of` ne filtre rien tant que vous n’avez pas
saisi ses bornes ou choisi ses valeurs.

:::tip
La zone de recherche à gauche de la barre d’outils est un filtre de plus. Elle
correspond à une partie du nom de l’enregistrement et à son texte de
recherche, sans sensibilité à la casse. Appuyez sur `/` pour y sauter.
:::

### 4. Triez et paginez

**Trier.** Dans le tableau, sélectionnez un en-tête de colonne pour trier
dessus. Sélectionnez à nouveau pour inverser l’ordre. La petite flèche montre
le sens. Les cartes kanban et calendrier suivent l’ordre enregistré dans la
vue.

**Paginer.** Sous le tableau, le pagineur parcourt les pages. Le libellé, par
exemple `1–25 sur 340`, dit où vous en êtes. Le décompte plafonne à

1000 ; au-delàà, la liste affiche `1000+`, et vous la resserrez avec des
filtres.

### 5. Enregistrez le réglage comme vue

Une vue enregistrée stocke la disposition, les filtres, et (pour un tableau)
les colonnes et leur ordre. Construisez-la une fois, puis rouvrez-la en un
clic.

1. Sélectionnez la commande « Créer une nouvelle vue » à côté des onglets.
   Vos filtres actuels restent actifs pendant l’édition.
2. Choisissez le type de vueà : Tableau, Calendrier ou Kanban.
3. Nommez la vue, par exemple `Affaires ouvertes`.
4. Réglez la portée. « Personnelle » signifie que vous seul la voyez.
   « Générale » signifie que toute l’équipe la partage. Vous ne pouvez plus
   changer cela après l’enregistrement.
5. Réglez les détails selon le typeà : les colonnes pour un tableau, les
   colonnes pour un kanban, le champ de date pour un calendrier. Ajoutez des
   filtres à l’étape « Filtres ».
6. Sélectionnez « Créer la vue ».

**Changer une vue.** Sélectionnez « Modifier la vue actuelle » à côté des
onglets.

**Effacez vos filtres.** Retirez chaque puce avec sa commande « Supprimer le
filtre », sans enregistrer.

:::caution[Personnelle et générale ne basculent pas]
Une vue garde sa portée à vie. Pour passer une vue personnelle à l’équipe,
créez une copie générale avec les mêmes réglages. Puis supprimez la vue
personnelle. Ne supprimez une vue générale que quand l’équipe est d’accord.
:::

### 6. Épinglez une vue

Sélectionnez « Épingler la vue actuelle » à côté des onglets pour épingler la
vue courante. Une vue épinglée apparaît sur le tableau de bord du domaine, si
bien que votre liste quotidienne est à un clic. Sélectionnez à nouveau la
commande pour désépingler.

## Exemple

Partagez une liste filtrée avec un collègue par le lien de la vueà :

```
https://facet.localhost:3443/crm/Deal?view=affaires_ouvertes
```

La partie après `view=` est le nom de la vue, en petites lettres avec des
tirets bas. Quiconque a le lien et les droits voit la même liste avec les
mêmes filtres.

## Dépannage

### La liste est vide

Commencez par les filtres.

1. Retirez les puces de filtre une par une. Une puce sans valeur filtre
   tout.
2. Vérifiez la vue. Les filtres enregistrés de la vue s’appliquent avant les
   vôtres.
3. Basculez « En direct » / « Supprimé » sur « Supprimé ». Les
   enregistrements sont peut-être à la corbeille.

### Un champ manque dans le menu Ajouter un filtre

Seuls les champs que l’auteur a rendus filtrables apparaissent. Les champs que
votre rôle ne peut pas lire restent dehors aussi. Demandez à l’auteur du
doctype, ou à votre administrateur.

### Le filtre ne renvoie rien

1. Vérifiez l’orthographe de la valeur. `contains` correspond à une partie de
   mot, mais un filtre `is` exige la valeur exacte, par exemple `open` et non
   `Open`.
2. Remplissez les deux bornes d’un filtre `between`, « De » d’abord. Une puce
   `between` avec une borne vide ne filtre rien.

### Vous ne pouvez ni créer ni modifier une vue

Votre rôle manque du droit sur les vues. Utilisez les vues partagées, ou
demandez à votre administrateur. Voir
[Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/).

### Une colonne kanban montre plus d’enregistrements qu’elle n’en liste

Le badge de décompte compte toute la colonne, plafonné à 1000. Le tableau
affiche la première page par colonne. Sélectionnez « Afficher plus » dans
cette colonne pour charger la page suivante.

### Le calendrier est vide

La vue s’ancre sur un champ de date. Les enregistrements sans valeur dans ce
champ n’apparaissent pas.

1. Ouvrez « Modifier la vue actuelle » et vérifiez le champ de date.
2. Déplacez-vous vers le mois cherché, avec « Aujourd’hui » et les flèches.

## Voir aussi

- [Le tableau de bord](/fr/workspace/dashboard/) — où vos vues épinglées
  apparaissent.
- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  ce qui s’ouvre depuis une ligne ou une carte.
- [Recherche et palette de commandes](/fr/workspace/search-command-palette/) —
  trouvez des enregistrements dans tout le domaine.
- [Importer et exporter des données](/fr/workspace/import-export/) — exportez
  exactement ce que le tableau montre.
- [Concevoir des doctypes](/fr/build/designing-doctypes/) — comment les
  doctypes et leurs champs se définissent.
- [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/) —
  pourquoi certains enregistrements restent cachés.
