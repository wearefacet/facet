---
title: Historique et retour arrière
description: Lire l’historique d’un document, le ramener à une version antérieure et restaurer un document supprimé.
audience: [user]
features: [FE-06, AUD-02, AUD-04]
sidebar:
  order: 6
verified_at: 49d7c7e5
---

Facet enregistre chaque changement de chaque document. La page d’historique
montre qui a changé quoi, et quand. Vous pouvez ramener un document à une
version antérieure. Vous pouvez aussi faire revenir un document que quelqu’un
a supprimé.

## Étapes

### 1. Ouvrez la page d’historique

Ouvrez le document. Le bloc de détails liste les heures de création et de mise à jour. Sélectionnez dans ce bloc le lien « Historique ». Le lien montre la
version courante, par exemple v42.

La page d’historique s’ouvre. Son titre montre le nom du document et le nombre
de changements enregistrés. Sélectionnez « Retour au document » pour revenir.

### 2. Lisez une entrée de changement

La frise chronologique liste chaque changement, du plus récent au plus
ancien. Chaque ligne montre :

| Partie | Ce qu’elle montre |
| --- | --- |
| Action | Créé, Mis à jour, Supprimé ou Instantané |
| Document | Le document changé. Un changement d’un document enfant porte sa propre pastille. |
| Résumé | Un texte court qui décrit le changement. |
| Acteur | Le compte ou le système qui a fait le changement. |
| Quand | L’heure, relative à maintenant. |

Sélectionnez une ligne. Le panneau de détail montre quatre lignes :

- **Quoi** — l’action, le document, et sa version à ce changement, par exemple
  v3.
- **Qui** — l’acteur, avec une pastille qui nomme la cause. Exemples :
  « via Assistant », « via Rollback ». Une édition simple montre le
  canal ; une session de navigateur s’affiche comme `facet`.
- **Quand** — la date et l’heure complètes dans votre fuseau horaire, plus
  l’heure relative.
- **Réf** — l’identifiant du changement avec un bouton de copie, et le nombre
  de changements de champs.

  Sous l’en-tête, Facet liste les champs qui ont changé. La plupart des lignes
  montrent la nouvelle valeur. Un champ retiré porte la mention
  « supprimé ». Une valeur que votre rôle ne peut pas voir porte la pastille
  « Valeur masquée ».

### 3. Ramenez le document à une version antérieure

1. Sélectionnez le changement qui porte le contenu que vous voulez.
2. Sélectionnez « Revenir à cette version ». La boîte de dialogue nomme le
   document et le changement.
3. Sélectionnez « Restaurer ».

Facet remet le document au contenu et aux détails de ce changement. Une
nouvelle entrée d’instantané apparaît en haut de la frise.

:::caution[Le retour arrière écrase le contenu]
Le document prend tout le contenu du changement sélectionné. Les changements
faits après lui sortent du document. Ils restent dans l’historique.
Sélectionnez un changement plus récent et ramenez à nouveau pour y revenir.
:::

:::note[Jusqu’où vous pouvez remonter]
Facet garde l’historique de chaque document pendant une fenêtre réglée. Par
défaut, 180 jours. Votre administrateur règle la fenêtre. Un retour à un
changement plus ancien échoue, et l’erreur nomme la fenêtre.
:::

### 4. Restaurez un document supprimé

Si vous avez un lien vers la page d’historique du document supprimé, ouvrez-le.

1. Sélectionnez l’entrée de suppression. L’indication « La restauration
   rétablit le document. » s’affiche.
2. Sélectionnez « Revenir à cette version », puis « Restaurer ».

Sur le journal d’audit global, un administrateur sélectionne la ligne de
suppression et sélectionne « Restaurer le document ».

Facet remet le document avec le contenu qu’il avait avant la suppression.
Facet ramène aussi les documents enfants que la suppression avait retirés.

:::note[La restauration marche à tout âge]
Facet garde toujours l’entrée de suppression et l’état d’avant. La fenêtre de
rétention ne bloque pas une restauration.
:::

### 5. Annulez une action entière (administrateurs)

Ouvrez le journal d’audit global dans l’espace Configurer. Il liste chaque
changement de chaque domaine. Chaque ligne montre l’action, le document,
l’acteur, le canal et l’heure.

Sélectionnez une ligne. Quand une action a changé plusieurs documents, le
panneau affiche « Une action — N modifications sur M documents », avec la
commande « Restaurer l’action entière (… modifications sur … documents) ».

Sélectionnez-la, puis confirmez avec « Restaurer l’action ». Chaque document
de l’action revient à son état d’avant l’action. Les documents que l’action a
créés sont supprimés.

:::caution[L’annulation couvre chaque document de l’action]
L’annulation écrase les changements ultérieurs de chaque document de l’action.
L’historique garde ces changements.
:::

Le journal d’audit global demande la permission de lire chaque domaine.
L’annulation demande aussi les droits de mise à jour sur chaque document de
l’action. Si un document échoue à la vérification, Facet ne change rien.

## Exemple

Sélectionnez un changement, et l’adresse de la page se met à jour. Envoyez
l’adresse à un collègue. Le collègue ouvre le même changement :

```
/crm/Company/01JCATPMKP4N82GVG2J7K4MHZZ/history?mutation=01HRR7X9QK3V5T2W8Y4Z6A0BCD
```

## Dépannage

### La commande de retour manque

Le changement sélectionné est le plus récent. Un retour ne changerait rien.
Sélectionnez un changement plus ancien.

Votre rôle manque peut-être de la permission de mise à jour sur le doctype.
Facet affiche la raison sous la commande.

### Facet refuse le retour arrière

Le changement sélectionné est plus ancien que la fenêtre de rétention.
L’erreur nomme la fenêtre. Demandez à votre administrateur d’élargir la
fenêtre, ou travaillez avec le contenu courant.

### Une entrée affiche Valeur masquée

Votre rôle ne peut pas voir ce champ. Le journal liste quand même le
changement, mais pas la valeur. Voir
[Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/).

### Un lien partagé n’ouvre pas le changement

La page charge elle-même les pages plus anciennes. Si elle ne trouve pas le
changement, elle le dit. Le changement est peut-être plus ancien que la
fenêtre de rétention, ou le lien est faux.

## Voir aussi

- [Le journal des mutations](/fr/concepts/mutation-log/) — ce que Facet
  enregistre pour chaque changement.
- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  où vous ouvrez un document.
- [Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/) —
  les droits derrière la commande de retour.
- [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/) —
  pourquoi certaines valeurs s’affichent comme masquées.
- [Gouverner l’accès](/fr/govern/) — réglez les rôles et les fenêtres de
  rétention comme administrateur.
