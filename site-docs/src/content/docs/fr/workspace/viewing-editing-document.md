---
title: Consulter et modifier un document
description: Ouvrir un document, lire sa page, modifier et enregistrer ses champs, puis le supprimer au besoin.
audience: [user]
features: [FE-04, FE-05, DOC-13]
sidebar:
  order: 4
verified_at: 49d7c7e5
---

Un document est un enregistrement, par exemple une affaire ou un employé. Cette
page présente la page du document et le formulaire d’édition. Elle explique
aussi ce qui se passe quand deux personnes modifient en même temps, et comment
supprimer un enregistrement.

## Avant de commencer

- **Les droits de lecture et de mise à jour.** Il vous faut l’accès en lecture
  pour voir un document, et l’accès en mise à jour pour le modifier. Un champ
  caché reste caché même sur une page ouverte. Voir
  [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).
- **Les sauvegardes passent en direct.** Vos changements passent en direct
  quand vous enregistrez. Les autres pages les répercutent sans rechargement
  manuel.

## Étapes

### 1. Ouvrez un document

Trois chemins s’offrent à vousà :

- **Depuis une liste** — sélectionnez une ligne, une carte kanban ou une puce
  de calendrier. Le tiroir d’aperçu s’ouvre avec un aperçu.
- **Depuis le tableau de bord du domaine** — sélectionnez une puce sous
  « Consultés récemment ».
- **Depuis la recherche** — appuyez sur `Ctrl+K`, tapez une partie du nom, et
  sélectionnez l’enregistrement.

  Le tiroir d’aperçu montre l’aperçu rapide. Utilisez l’icône crayon pour
  ouvrir le formulaire d’édition. Utilisez l’icône flèche
  (« Ouvrir en pleine page ») pour la pleine page. Vous pouvez aussi envoyer
  l’adresse de la page à un collègueà ; elle ouvre le même document.

  La pleine page montreà :

| Partie | Ce qu’elle montre |
| --- | --- |
| En-tête | Le nom de l’enregistrement, un repère de couleur, et le libellé du doctype. |
| Boutons | « Partager » (copie le lien), « Imprimer », « Historique », « Modifier » et « Actions ». |
| Contenu | Les champs et les sections que le doctype définit, disposés par son auteur. |
| Panneau latéral | Commentaires et pièces jointes, quand le doctype en porte. |
| Référencé par | Les enregistrements qui pointent vers celui-ci. |

Un doctype sans disposition conçue montre à la place une simple liste de
champsà : un libellé et une valeur par ligne.

:::tip
Appuyez sur `E` sur la page du document pour ouvrir l’éditeur.
Enregistrez avec `Ctrl+S` ou `Ctrl+Entrée`.
:::

### 2. Modifiez les champs

Sélectionnez « Modifier ». Le formulaire s’ouvre avec les champs de
l’enregistrementà :

- **Texte** — les champs texte prennent du texte. Un champ texte long prend du
  markdown.
- **Liste de choix** — le champ offre ses valeurs fixes dans un menu déroulant.
- **Date ou heure** — le champ ouvre un sélecteur. Vous saisissez l’heure
  civile dans votre propre fuseau horaireà ; Facet stocke la valeur en
  UTC (temps universel coordonné).
- **Montant** — le champ prend un montant et une devise.
- **Référence** — le champ ouvre une recherche sur le doctype lié.
- **Vrai/faux** — le champ montre un interrupteur.

Les champs que l’auteur a marqués en lecture seule apparaissent dans la page
mais pas dans le formulaire. Un nouvel enregistrement démarre avec les valeurs
par défaut que l’auteur a posées, par exemple un statut qui commence à `new`.

  Sélectionnez « Enregistrer ». Le bouton affiche « Enregistrement… » pendant
  que la sauvegarde tourne. Facet vous ramène à la page du document.

### 3. Lisez le résultat de la sauvegarde

Une sauvegarde sans erreur vous ramène à la page du document, et le contenu
montre les nouvelles valeurs.

Quand Facet refuse une valeur, le formulaire reste ouvert. Une bande rouge en
haut nomme le problème, et chaque champ en faute affiche son propre message
sous la saisie. Corrigez les champs marqués et enregistrez à nouveau.

:::note[Une sauvegarde, une version]
Chaque sauvegarde écrit une version dans l’historique du document, avec votre
nom et l’heure. Une sauvegarde qui réécrit les mêmes valeurs à quelques
minutes d’intervalle se replie en une seule entrée. Voir
[Le journal des mutations](/fr/concepts/mutation-log/).
:::

### 4. Travaillez sur un document que quelqu’un d’autre modifie

Facet ne verrouille pas un document. Deux personnes peuvent ouvrir et modifier
le même enregistrement. Chaque sauvegarde se fond dans le document stocké,
champ par champà :

- **Des champs différents** — vous changez un champ et un collègue en change
  un autreà : les deux changements passent.
- **Le même champ** — vous le changez tous les deuxà : la sauvegarde qui
  arrive en dernier gagne. La page se rafraîchit d’elle-même et montre la
  valeur la plus récente.

  La page suit le document en direct. Quand une automatisation ou une autre
  personne le change, votre vue se met à jour sans rechargement. Le bouton
  « Historique » montre qui a changé quoi, et
  [Historique et retour arrière](/fr/workspace/history-undo/) explique comment
  remettre une version antérieure.

### 5. Lancez une action ou supprimez le document

Le bouton « Actions » liste les actions que le doctype définit, par exemple un
changement d’étape. Sélectionnez-en uneà ; si elle demande des entrées,
remplissez la boîte de dialogue et confirmez.

Pour supprimer, ouvrez « Actions » et sélectionnez « Supprimer ». Facet demande
d’abordà :

> Supprimer {name} ? Cette action est irréversible.

Quand d’autres enregistrements référencent celui-ci, la boîte de dialogue nomme
aussi le décompte. La suppression laisse ces liens pointer vers un
enregistrement supprimé.

:::caution[La boîte de dialogue dit que c’est définitif]
La boîte de dialogue de suppression prévient que la suppression est
définitive. Facet garde l’enregistrement supprimé un certain temps. Deux
endroits peuvent le ramener, si votre rôle le permet. L’un est le côté
« Supprimé » de la liste. L’autre est la page d’historique du document. Les
liens et les listes perdent l’enregistrement aussitôt, alors ne prenez pas la
suppression pour une pause. Voir
[Historique et retour arrière](/fr/workspace/history-undo/).
:::

Après la suppression, Facet vous ramène à la liste. Les enregistrements
supprimés restent visibles sur le côté « Supprimé » de la bascule de la liste,
avec un bouton « Restaurer ».

## Exemple

Une édition courte depuis le tiroir d’aperçuà :

```
/crm/Deal            sélectionnez une ligne       le tiroir s’ouvre
                     sélectionnez Modifier        /crm/Deal/crm.Deal.1/edit
                     changez Montant, sélectionnez Enregistrer   retour à la page du document
```

L’adresse du formulaire d’édition est l’adresse de l’enregistrement plus
`/edit`.

## Dépannage

### La page dit que le document a été supprimé

Quelqu’un l’a supprimé après votre ouverture. Le message indique à quel
moment. Une personne avec le droit peut le restaurer. Voir
[Historique et retour arrière](/fr/workspace/history-undo/).

### Le bouton Modifier manque

Votre rôle ne peut pas mettre à jour ce doctype. Vous pouvez encore lire,
commenter et suivre les liens. Demandez le droit de mise à jour à votre
administrateur.

### Une sauvegarde échoue avec un message de champ

Lisez le message sous le champ. Cas courantsà :

- un champ requis est vide
- le texte est trop long
- un nombre ou une date a la mauvaise forme
- il manque une devise sur un champ montant

Corrigez les champs marqués et enregistrez à nouveau.

### Votre changement a disparu

Quelqu’un a enregistré le même champ après vousà ; la sauvegarde la
plus récente gagne. Ouvrez « Historique », trouvez votre changement, et ramenez
le document à ce changement au besoin. Voir
[Historique et retour arrière](/fr/workspace/history-undo/).

### Un champ montre un code brut au lieu d’un nom

L’enregistrement lié est peut-être supprimé, ou votre rôle ne peut pas le
lire. Demandez à l’auteur du doctype, ou à votre administrateur.

## Voir aussi

- [Listes, filtres et vues enregistrées](/fr/workspace/lists-filters-views/) —
  les listes d’où vous ouvrez des enregistrements.
- [Commentaires et pièces jointes](/fr/workspace/comments-attachments/) — le
  panneau latéral de la page du document.
- [Historique et retour arrière](/fr/workspace/history-undo/) — lisez les
  versions et remettez-en une.
- [Recherche et palette de commandes](/fr/workspace/search-command-palette/) —
  le troisième chemin vers un enregistrement.
- [Le journal des mutations](/fr/concepts/mutation-log/) — ce que chaque
  sauvegarde écrit.
- [Documents, doctypes et projections](/fr/concepts/documents-doctypes-projections/) —
  comment un enregistrement se stocke et se sert.
