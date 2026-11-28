---
type: how-to
title: Historique et retour arrière
description: Lisez l’historique d’un document, remettez-le à une version antérieure et restaurez un document supprimé.
audience: [user]
features: [FE-06, AUD-02, AUD-04]
sidebar:
  order: 3
verified_at: eee55a2
---

Facet enregistre chaque changement de chaque document. La page d’historique
montre qui a changé quoi, et quand. Vous pouvez remettre un document à une
version antérieure. Vous pouvez aussi faire revenir un document que quelqu’un
a supprimé.

## Avant de commencer

- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) —
  comment ouvrir le document dont vous lirez l’historique.

![The history page of a booking: the Audit trail timeline on the left and the detail pane for the selected change on the right.](/screens/use/documents-3.png)

## Étapes

### 1. Ouvrez la page d’historique

Ouvrez le document et sélectionnez **Historique** dans l’en-tête de page. La
page d’historique s’ouvre. Son titre montre le nom de l’enregistrement et le
nombre de changements enregistrés, par exemple *15 mutations*. Sélectionnez
**Retour au document** pour revenir.

Vous pouvez aussi transmettre l’adresse de la page à un collègue — elle ouvre
la même page d’historique.

### 2. Lisez une entrée de changement

La frise chronologique liste chaque changement, du plus récent au plus
ancien. Chaque ligne montre :

| Partie | Ce qu’elle montre |
| --- | --- |
| Action | Création, mise à jour, suppression ou instantané. |
| Document | Le document changé. Un changement d’un document enfant porte sa propre pastille. |
| Résumé | Un texte court qui décrit le changement. |
| Acteur | Le compte ou le système qui a fait le changement. |
| Quand | L’heure, relative à maintenant. |

Sélectionnez une ligne. Le panneau de détail montre quatre lignes :

- **Quoi** — l’action, le document, et sa version à ce changement, par exemple
  v3.
- **Qui** — l’acteur, avec une pastille qui nomme la cause. Exemples : *via
  Assistant*, *via Rollback*. Une édition simple montre le canal ; une session
  de navigateur s’affiche comme *facet*.
- **Quand** — la date et l’heure complètes dans votre fuseau horaire, plus
  l’heure relative.
- **Réf** — l’identifiant du changement avec un bouton de copie, et le nombre
  de changements de champs.

Sous l’en-tête, Facet liste les champs qui ont changé. La plupart des lignes
montrent la nouvelle valeur. Un champ retiré porte la mention *supprimé*. Une
valeur que votre rôle ne peut pas voir porte la pastille **Valeur masquée**.

### 3. Remettez le document à une version antérieure

1. Sélectionnez le changement qui porte le contenu que vous voulez.
2. Sélectionnez **Revenir à cette version**. La boîte de dialogue nomme le
   document et le changement.
3. Sélectionnez **Restaurer**.

Facet remet le document au contenu et aux détails de ce changement. Une
nouvelle entrée d’instantané apparaît en haut de la frise.

:::caution[Le retour arrière écrase le contenu]
Le document prend tout le contenu du changement sélectionné. Les changements
faits après lui disparaissent du document. Ils restent dans l’historique.
Sélectionnez un changement plus récent et faites un nouveau retour arrière
pour y revenir.
:::

:::note[Jusqu’où remonter]
Facet garde l’historique de chaque document pendant une fenêtre réglée. Par
défaut, 180 jours. Votre administrateur règle cette fenêtre. Un retour vers
un changement plus ancien échoue, et l’erreur nomme la fenêtre.
:::

### 4. Restaurez un document supprimé

Si vous avez un lien vers la page d’historique du document supprimé,
ouvrez-le.

1. Sélectionnez l’entrée de suppression. L’indication *La restauration
   rétablit le document.* s’affiche.
2. Sélectionnez **Revenir à cette version**, puis **Restaurer**.

Facet remet le document avec le contenu qu’il avait avant la suppression.
Facet ramène aussi les documents enfants que la suppression avait retirés.

:::note[La restauration marche à tout âge]
Facet garde toujours l’entrée de suppression et l’état d’avant. La fenêtre de
rétention ne bloque pas une restauration.
:::

### 5. Annulez une action entière (administrateurs)

Un administrateur peut annuler une action qui a touché plusieurs documents —
un import, une exécution de l’assistant, une automatisation. Ouvrez le
journal d’audit global dans l’espace **Configurer**, sélectionnez la ligne de
l’action, puis sélectionnez **Restaurer l’action entière**. Chaque document
de l’action revient à son état d’avant l’action ; les documents que l’action
a créés sont supprimés. L’annulation est indivisible : si un document échoue
à la vérification, rien ne change.

Les détails et les droits nécessaires figurent sur les pages
administrateur : [Voir qui a fait quoi](/fr/admin/history/audit/) et
[Revenir en arrière](/fr/admin/history/roll-back/).

## Exemple

Tom modifie par erreur la date d’une réservation : il décale BK-2026-0002
d’une semaine de trop. Le client appelle. Tom ouvre **Historique** sur la
réservation, sélectionne son changement erroné, sélectionne **Revenir à cette
version**, et confirme. La réservation reprend le contenu qu’elle avait avant
l’erreur, et la frise montre une nouvelle entrée d’instantané au nom de Tom.
Aucun administrateur nécessaire.

Sélectionnez un changement, et l’adresse de la page se met à jour. Envoyez
l’adresse à un collègue. Le collègue ouvre le même changement :

```
/rentals/Booking/BK-2026-0002/history?mutation=01HRR7X9QK3V5T2W8Y4Z6A0BCD
```

## Dépannage

### La commande de retour manque

Le changement sélectionné est le plus récent. Un retour ne changerait rien.
Sélectionnez un changement plus ancien.

Votre rôle manque peut-être de la permission de mise à jour sur le type
d’enregistrement. Facet affiche la raison sous la commande.

### Facet refuse le retour arrière

Le changement sélectionné est plus ancien que la fenêtre de rétention.
L’erreur nomme la fenêtre. Demandez à votre administrateur d’élargir la
fenêtre, ou travaillez avec le contenu courant.

### Une entrée affiche Valeur masquée

Votre rôle ne peut pas voir ce champ. Le journal liste quand même le
changement, mais pas la valeur. Voir
[Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

### Un lien partagé n’ouvre pas le changement

La page charge elle-même les pages plus anciennes. Si elle ne trouve pas le
changement, elle le dit. Le changement est peut-être plus ancien que la
fenêtre de rétention, ou le lien est faux.

## Voir aussi

- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) — là
  où vous ouvrez un document.
- [Le journal des mutations](/fr/admin/under-the-hood/change-log/) — ce que
  Facet enregistre pour chaque changement, une couche plus bas.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — la vue administrateur de
  chaque changement.
- [Revenir en arrière](/fr/admin/history/roll-back/) — le retour arrière en
  détail, avec ses limites.
- [Documents : des enregistrements avec une mémoire](/fr/discover/how-it-works/documents/)
