---
type: how-to
title: Consulter et modifier un document
description: Ouvrez un enregistrement depuis une liste ou la recherche, lisez sa page, modifiez ses champs, et supprimez-le au besoin.
audience: [user]
features: [FE-04, FE-05, FE-24, DOC-13]
sidebar:
  order: 1
verified_at: eee55a2
---

Un **document** est un enregistrement, par exemple une réservation ou un
article. Cette page couvre la page de l’enregistrement et le formulaire
d’édition. Elle explique aussi ce qui se passe quand deux personnes
modifient en même temps, et comment supprimer un enregistrement.

![A booking document open on its page: the header with the action buttons, the fields below, and the comments panel on the right.](/screens/use/first-day-tour-4.png)

## Avant de commencer

- **Les droits de lecture et de mise à jour.** Il vous faut l’accès en
  lecture pour voir un document, et l’accès en mise à jour pour le modifier.
  Un champ que votre rôle ne peut pas voir ne s’affiche pas du tout — pas
  même sur une page ouverte. Voir
  [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).
- **Les sauvegardes passent en direct.** Vos changements sont visibles dès
  que vous enregistrez. Les autres pages les affichent sans rechargement
  manuel.

## Étapes

### 1. Ouvrez un document

Trois chemins s’offrent à vous :

- **Depuis une liste** — sélectionnez une ligne, une carte kanban ou une
  puce de calendrier. Un aperçu s’ouvre à côté de la liste.
- **Depuis le tableau de bord du domaine** — sélectionnez une puce sous
  « Consultés récemment ».
- **Depuis la recherche** — appuyez sur `Ctrl+K`, tapez une partie du nom,
  et sélectionnez l’enregistrement.

L’aperçu montre la vue rapide. Sélectionnez « Modifier » pour ouvrir le
formulaire d’édition, ou la commande flèche (« Ouvrir en pleine page ») pour
la pleine page. Vous pouvez aussi envoyer l’adresse de la page à un
collègue ; elle ouvre le même document.

La pleine page montre :

| Partie | Ce qu’elle montre |
| --- | --- |
| En-tête | Le nom de l’enregistrement, un repère de couleur, le type d’enregistrement, et la version, par exemple v42. |
| Boutons | « Partager » (copie le lien), « Imprimer », « Historique », « Modifier » et « Actions ». |
| Contenu | Les champs et les sections que le type d’enregistrement définit, disposés par son auteur. |
| Panneau latéral | Commentaires et pièces jointes, quand le type d’enregistrement en porte. |
| Référencé par | Les enregistrements qui pointent vers celui-ci. La section se cache quand rien ne pointe ici. |

Un type d’enregistrement sans disposition conçue montre à la place une
simple liste de champs : un libellé et une valeur par ligne.

:::tip
Appuyez sur `E` sur la page d’un enregistrement pour ouvrir l’éditeur.
Enregistrez avec `Ctrl+S` ou `Ctrl+Entrée` (`⌘S` ou `⌘Entrée` sur un Mac).
Les deux font la même chose que le bouton « Enregistrer ».
:::

### 2. Modifiez les champs

Sélectionnez « Modifier ». Le formulaire s’ouvre avec les champs de
l’enregistrement :

![The booking edit form: the fields as inputs, with Save and Cancel at the bottom.](/screens/use/documents-1.png)

- **Texte** — les champs texte prennent du texte. Un champ texte long prend
  du markdown.
- **Liste de choix** — le champ offre ses valeurs fixes dans un menu
  déroulant.
- **Date ou période** — le champ ouvre un sélecteur. Vous saisissez l’heure
  civile dans votre propre fuseau horaire ; Facet stocke la valeur en
  UTC (temps universel coordonné).
- **Montant** — le champ prend un montant et une devise.
- **Référence** — le champ ouvre une recherche sur le type d’enregistrement
  lié.
- **Vrai/faux** — le champ montre un interrupteur.

Les champs que l’auteur a marqués en lecture seule apparaissent dans la page
mais pas dans le formulaire. Un nouvel enregistrement démarre avec les
valeurs par défaut que l’auteur a posées, par exemple un statut qui commence
à *brouillon*.

### 3. Enregistrez, et lisez le résultat

Sélectionnez « Enregistrer ». Le bouton affiche « Enregistrement… » pendant
que la sauvegarde tourne. Une sauvegarde sans erreur vous ramène à la page
de l’enregistrement, et le contenu montre les nouvelles valeurs.

Quand Facet refuse une valeur, le formulaire reste ouvert. Une bande rouge
en haut nomme le problème, et chaque champ en faute affiche son propre
message sous la saisie. Corrigez les champs marqués et enregistrez à
nouveau.

:::note[Une sauvegarde, une version]
Chaque sauvegarde écrit une version dans l’historique du document, avec votre
nom et l’heure. Une sauvegarde qui répète les mêmes valeurs à quelques
minutes d’intervalle se fond en une seule entrée. Voir
[Historique et retour arrière](/fr/use/documents/history-undo/).
:::

### 4. Travaillez sur un document que quelqu’un d’autre modifie

Facet ne verrouille pas un document. Deux personnes peuvent ouvrir et
modifier le même enregistrement. Chaque sauvegarde se fond dans le document
stocké, champ par champ :

- **Des champs différents** — vous changez un champ et un collègue en change
  un autre : les deux changements passent.
- **Le même champ** — vous le changez tous les deux : la sauvegarde qui
  arrive en dernier gagne. La page se rafraîchit d’elle-même et montre la
  valeur la plus récente.

La page suit le document en direct. Quand une automatisation ou une autre
personne le change, votre vue se met à jour sans rechargement. Le bouton
« Historique » montre qui a changé quoi, et
[Historique et retour arrière](/fr/use/documents/history-undo/) explique
comment remettre une version antérieure.

### 5. Lancez une action ou supprimez le document

Le bouton « Actions » liste les étapes en un clic que le type
d’enregistrement définit, par exemple un changement d’étape.
Sélectionnez-en une ; si elle demande des entrées, remplissez la boîte de
dialogue et confirmez.

Pour supprimer, ouvrez « Actions » et sélectionnez « Supprimer ». Facet
demande d’abord :

> Supprimer {name} ? Cette action est irréversible.

Quand d’autres enregistrements référencent celui-ci, la boîte de dialogue
nomme aussi le décompte. La suppression laisse ces liens pointer vers un
enregistrement supprimé.

:::caution[La boîte de dialogue dit que c’est définitif]
La boîte de dialogue de suppression prévient que la suppression est
définitive. Facet garde l’enregistrement supprimé un certain temps. Deux
endroits peuvent le ramener, si votre rôle le permet. L’un est le côté
« Supprimé » de la liste. L’autre est la page d’historique du document. Les
liens et les listes perdent l’enregistrement aussitôt, alors ne prenez pas
la suppression pour une pause. Voir
[Historique et retour arrière](/fr/use/documents/history-undo/).
:::

Après la suppression, Facet vous ramène à la liste. Basculez la liste sur
« Supprimé » pour voir les enregistrements retirés, chacun avec un bouton
« Restaurer ».

## Exemple

Une édition courte d’une réservation Brightwater :

```
/rentals/Booking                  sélectionnez la ligne de BK-2026-0002
                                  l’aperçu s’ouvre
                                  sélectionnez Modifier       le formulaire s’ouvre
                                  changez Notes, sélectionnez Enregistrer
                                  retour à la page de l’enregistrement
```

L’adresse du formulaire d’édition est l’adresse de l’enregistrement plus
`/edit`.

## Dépannage

### La page dit que le document a été supprimé

Quelqu’un l’a supprimé après votre ouverture. Le message indique à quel
moment. Une personne avec le droit peut le restaurer. Voir
[Historique et retour arrière](/fr/use/documents/history-undo/).

### Le bouton Modifier manque

Votre rôle ne peut pas mettre à jour ce type d’enregistrement. Vous pouvez
encore lire, commenter et suivre les liens. Demandez le droit de mise à
jour à votre administrateur.

### Une sauvegarde échoue avec un message de champ

Lisez le message sous le champ. Cas courants :

- un champ requis est vide
- le texte est trop long — le message nomme la longueur maximale
- un nombre ou une date a la mauvaise forme
- il manque une devise sur un champ montant

Corrigez les champs marqués et enregistrez à nouveau.

### Votre changement a disparu

Quelqu’un a enregistré le même champ après vous ; la sauvegarde la plus
récente gagne. Ouvrez « Historique », trouvez votre changement, et ramenez
le document à ce changement au besoin. Voir
[Historique et retour arrière](/fr/use/documents/history-undo/).

### Un champ montre un code brut au lieu d’un nom

L’enregistrement lié est peut-être supprimé, ou votre rôle ne peut pas le
lire. Demandez à l’auteur du type d’enregistrement, ou à votre
administrateur.

## Voir aussi

- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  les listes d’où vous ouvrez des enregistrements.
- [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) —
  le panneau latéral de la page d’un enregistrement.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — lisez
  les versions et remettez-en une.
- [Recherche et palette de commandes](/fr/use/finding/search/) —
  le troisième chemin vers un enregistrement.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — ce que
  chaque sauvegarde écrit, une couche plus bas.
- [Documents, doctypes et projections](/fr/build/deeper/documents-and-projections/) —
  l’image complète, pour les curieux.
- [Types de champs](/fr/reference/field-types/)
