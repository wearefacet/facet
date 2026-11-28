---
type: how-to
title: Listes, filtres et vues enregistrées
description: Ouvrez une liste, passez du tableau au kanban et au calendrier, filtrez-la, puis enregistrez le réglage comme une vue à rouvrir en un clic.
audience: [user]
features: [FE-03, FE-08, DOM-21, DOM-30, FE-25]
sidebar:
  order: 1
verified_at: c34885a
---

Votre travail se passe dans des listes. Chaque type d’enregistrement en
ouvre une, et vous choisissez la disposition qui convient au travail. Un
tableau quand vous avez besoin de détail, un kanban quand le travail passe
par des étapes, un calendrier quand les dates comptent. Resserez la liste
avec des filtres, puis enregistrez l’ensemble comme **vue**. Une vue est un
onglet nommé que vous rouvrez en un clic — gardez-la pour vous, ou
partagez-la avec votre équipe.

## Avant de commencer

- [Visite de l’espace de travail](/fr/use/first-day/) — où se trouvent la
  barre latérale, la barre supérieure et vos enregistrements.

## Ouvrir une liste

Ouvrez un domaine dans la barre latérale, puis sélectionnez un type
d’enregistrement. La liste s’ouvre sur la première vue enregistrée,
présentée comme un onglet au-dessus du tableau :

![Tom's clients list: a table of companies with the view tabs above it and the filter toolbar on top.](/screens/use/finding-lists-1.png)

Un type d’enregistrement sans vue affiche à la place un écran de démarrage :
une carte par disposition. Choisissez une carte pour construire la première
vue. Ensuite, chaque onglet porte une icône — tableau, kanban ou calendrier
— et vous voyez d’un coup d’œil ce qu’il ouvre.

## Les trois dispositions

| Disposition | Ce qu’elle affiche | À quoi elle sert |
|---|---|---|
| **Tableau** | Une ligne par enregistrement, une colonne par champ | Le détail, le tri, le travail sur de nombreux enregistrements |
| **Kanban** | Des cartes regroupées en colonnes, une colonne par statut ou par étape | Le travail qui avance : tickets, réservations |
| **Calendrier** | Des enregistrements posés sur une grille de mois ou de semaine selon un champ de date | Réservations, échéances, plannings |

Chaque disposition répond à une question différente. Lucía tient le tableau
de maintenance. Chaque ticket se trouve dans la colonne qui correspond à son
état, et elle déplace une carte quand le travail avance. Le déplacement
demande le droit de modifier des enregistrements — le même droit que le
bouton Modifier.

![Lucía's maintenance board: five ticket cards grouped in lanes by status.](/screens/use/finding-lists-2.png)

Le calendrier pose les enregistrements sur les jours où ils ont lieu.
Basculez entre **Mois** et **Semaine**, et déplacez-vous avec **Précédent**,
**Suivant** et **Aujourd’hui**. Un jour chargé replie ses entrées en une
seule puce — par exemple `4 documents` — et la sélection de la puce les
liste.

![Nadia's booking calendar for December: bookings placed on their date ranges.](/screens/use/finding-lists-3.png)

Dans chaque disposition, la sélection d’une ligne, d’une carte ou d’une puce
ouvre un aperçu à côté de la liste. L’aperçu porte **Modifier** et
**Ouvrir en pleine page**.

## Resserrer la liste

Les filtres ne gardent que les enregistrements dont vous avez besoin :

1. Sélectionnez **+ Ajouter un filtre** dans la barre d’outils. Un menu
   liste les champs que vous pouvez filtrer.
2. Sélectionnez un champ. Une puce apparaît dans la barre d’outils, avec la
   comparaison et une commande de valeur.
3. Choisissez la comparaison et saisissez une valeur. La liste se met à jour
   pendant la saisie.

Le menu n’offre que les comparaisons que le champ prend en charge :

| Vous voulez | La puce affiche | Convient à |
|---|---|---|
| Une correspondance exacte | `is` ou `=` | Texte, listes de choix, références, nombres, dates |
| Une exclusion exacte | `is not` ou `≠` | Les mêmes champs |
| Un seuil | `>`, `≥`, `<`, `≤` | Nombres, dates, montants |
| Une plage | `between` | Deux bornes, par exemple une plage de dates |
| Plusieurs valeurs à la fois | `is any of` | Listes de choix |
| Une partie de mot | `contains` | Texte, sans distinction de casse |

Deux puces ne font rien tant que vous ne les remplissez pas : une puce
`between` demande les deux bornes, et `is any of` au moins une valeur. C’est
voulu — une plage à moitié remplie cacherait sinon des lignes en silence.

La zone de recherche à gauche de la barre d’outils est un filtre de plus.
Elle porte sur une partie du nom de l’enregistrement, sans distinction de
casse. Appuyez sur `/` pour y aller.

## Trier et paginer

Dans le tableau, sélectionnez un en-tête de colonne pour trier dessus, puis
sélectionnez à nouveau pour inverser l’ordre. La petite flèche montre le
sens. Les cartes du kanban et du calendrier suivent l’ordre enregistré dans
la vue.

Sous le tableau, le pagineur parcourt les pages. Le libellé, par exemple
`1–25 sur 340`, montre où vous en êtes. Le décompte plafonne à 1000 —
au-delà, la liste affiche `1000+`, et les filtres font baisser le nombre.

## Travailler la liste au clavier

La liste répond au clavier aussi bien qu’à la souris. `j` et `k` (ou les
touches fléchées) déplacent le surlignage dans les lignes, et `Enter` ouvre
l’enregistrement surligné — d’abord dans l’aperçu, puis en page complète.
`Esc` efface le surlignage, et `/` va à la zone de recherche. `C` démarre un
nouvel enregistrement de ce type. Les touches lettres se reposent pendant la
saisie, donc elles ne se déclenchent jamais depuis un champ de texte.

## Enregistrer votre réglage comme vue

Une vue stocke la disposition, les filtres et — pour un tableau — les
colonnes et leur ordre. Construisez-la une fois, puis rouvrez-la en un clic :

1. Sélectionnez le **+** à côté des onglets (**Créer une nouvelle vue**).
2. Choisissez le type de vue : Tableau, Kanban ou Calendrier.
3. Nommez-la, par exemple `Mes affaires ouvertes`.
4. Choisissez la portée. **Personnelle** signifie que vous seul la voyez.
   **Générale** signifie que toute l’équipe la partage.
5. Réglez les détails : les colonnes pour un tableau, les colonnes pour un
   kanban, le champ de date pour un calendrier. Les filtres viennent à
   l’étape Filtres.
6. Sélectionnez **Créer la vue**.

Une nouvelle vue démarre personnelle : vous seul la voyez. Certains rôles ne
peuvent créer que des vues personnelles — si vous ne pouvez pas choisir
**Générale**, demandez à votre administrateur. Vos filtres restent actifs
pendant l’édition, donc ce que vous voyez est ce que vous enregistrez.

**Modifier une vue.** Sélectionnez **Modifier la vue actuelle** à côté des
onglets. Les changements s’appliquent à tous ceux qui utilisent la vue,
alors accordez-vous avec votre équipe avant de modifier une vue partagée.

**Supprimer une vue.** Sélectionnez **Supprimer la vue actuelle**. Une vue
enregistrée disparaît pour tous les comptes, alors ne supprimez une vue
générale que quand l’équipe est d’accord.

:::caution[Personnelle et générale ne basculent pas]
Une vue garde sa portée à vie. Pour passer une vue personnelle à l’équipe,
créez une copie générale avec les mêmes réglages, puis supprimez la vue
personnelle.
:::

## Épingler une vue

Sélectionnez la commande d’épinglage à côté des onglets pour épingler la vue
où vous êtes. Une vue épinglée apparaît comme une carte sur le tableau de
bord du domaine, et votre liste quotidienne est à un clic de l’écran
d’accueil. Sélectionnez à nouveau la commande pour désépingler.

## Partager une vue par un lien

L’adresse d’une liste transporte la vue ouverte, si bien qu’un lien ouvre la
même liste filtrée pour un collègue :

```
https://facet.localhost:3443/rentals/Booking?view=calendar
```

La partie après `view=` est le nom de la vue en petites lettres avec des
tirets bas. Quiconque a le lien et le droit de lire les enregistrements voit
la même liste. Il faut toujours l’accès en lecture — un lien n’ouvre jamais
des enregistrements que le rôle cache.

## Restaurer un enregistrement supprimé

Basculez l’interrupteur en haut de la liste de **En direct** à **Supprimé**
pour voir les enregistrements envoyés à la corbeille. Sélectionnez
**Restaurer** sur une ligne pour le ramener — la restauration demande le
droit de modifier des enregistrements. Facet conserve les enregistrements
supprimés, si bien qu’une erreur n’est jamais définitive.

## Dépannage

### La liste est vide

Commencez par les filtres. Retirez chaque puce une par une — une puce à
valeur vide filtre tout. Vérifiez ensuite la vue elle-même : une vue
enregistrée applique ses propres filtres avant les vôtres, alors changez
d’onglet pour comparer. Toujours vide ? Basculez l’interrupteur sur
**Supprimé** ; les enregistrements sont peut-être à la corbeille. Si les
enregistrements manquent autant dans la liste **En direct** que dans
**Supprimé**, demandez à votre administrateur — votre rôle ne les atteint
peut-être pas.

### Un champ manque dans le menu Ajouter un filtre

Seuls les champs que l’auteur du domaine a rendus filtrables apparaissent,
et seuls les champs que votre rôle peut lire. Demandez à l’auteur du domaine
ou à votre administrateur.

### Le filtre ne renvoie rien

Vérifiez d’abord l’orthographe. `contains` porte sur une partie de mot, mais
un filtre `is` exige la valeur exacte — `open`, pas `Open`. Vérifiez ensuite
une puce `between` : une borne vide filtre tout, alors remplissez De
d’abord.

### Vous ne pouvez ni créer ni modifier une vue

Votre rôle ne porte pas le droit de modifier les vues. Vous pouvez encore
utiliser les vues que votre équipe partage. Demandez à votre administrateur
— voir [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/)
pour savoir comment les rôles décident de cela.

### Une colonne de kanban montre plus d’enregistrements qu’elle n’en liste

Le décompte d’une colonne lit toute la colonne, et le tableau n’affiche que
la première page. Sélectionnez **Afficher plus** au bas de la colonne pour
charger la page suivante.

### Le calendrier est vide

La vue s’ancre sur un champ de date, et les enregistrements sans valeur dans
ce champ n’apparaissent pas. Ouvrez **Modifier la vue actuelle** et
vérifiez le champ de date. Déplacez-vous ensuite vers le bon mois avec
**Aujourd’hui** et les flèches.

## Voir aussi

- [Le tableau de bord](/fr/use/first-day/dashboard/) — où vos vues épinglées
  apparaissent.
- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) —
  ce qui s’ouvre depuis une ligne ou une carte.
- [Recherche et palette de commandes](/fr/use/finding/search/) — trouver des
  enregistrements dans tous les domaines.
- [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/) — la carte
  complète, liste et espace de travail.
- [Importer et exporter des données](/fr/use/documents/import-export/) —
  exporter exactement ce que le tableau montre.
- [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/) —
  pourquoi certains enregistrements et champs restent hors de vos listes.
- [Listes, kanban et calendriers (pour les auteurs)](/fr/build/model/views/lists-boards-calendars/) —
  comment l’auteur du domaine façonne ces vues.
