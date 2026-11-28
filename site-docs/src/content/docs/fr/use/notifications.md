---
type: how-to
title: Notifications
description: Lisez vos notifications depuis la cloche de la barre supérieure, agissez dessus, téléchargez les exports terminés, et coupez la cloche au besoin.
audience: [user]
features: [FE-09, AUT-06]
sidebar:
  order: 4
verified_at: eee55a2
---

Une personne vous mentionne sur un ticket, un export se termine, une
automatisation signale un enregistrement. Facet vous prévient dans
l’application, sur la cloche de la barre supérieure. La cloche affiche le
nombre de notifications que vous n’avez pas lues, et le panneau derrière
elle contient la liste.

![The bell in the top bar — selecting it opens the notification panel.](/screens/use/notifications-1.png)

## Lire vos notifications

Sélectionnez la cloche. Le panneau s’ouvre en dessous, du plus récent au
plus ancien. Une notification non lue porte un point et un titre en gras ;
la cloche conserve son compteur tant qu’une ligne non lue subsiste.

Sélectionnez une ligne. Le panneau se ferme, marque la notification comme
lue, et ouvre l’enregistrement concerné.

Le panneau affiche une page de notifications. Sélectionnez **Charger plus**
en bas pour la page suivante, et **Tout marquer comme lu** en haut quand
vous voulez repartir de zéro.

## Lancer une action depuis une notification

Une notification peut porter des boutons — par exemple **Approuver** ou
**Réouvrir**. Le bouton exécute une action nommée sur l’enregistrement, sous
votre propre rôle : les mêmes contrôles s’appliquent que sur la page de
l’enregistrement elle-même. Certaines actions demandent d’abord une
confirmation.

:::caution
La première action que vous exécutez désactive tous les boutons d’action de
cette ligne. La ligne affiche alors **Action effectuée**.
:::

Une notification d’export porte plutôt un bouton **Télécharger**.
Sélectionnez-le pour enregistrer le fichier — sur ces lignes, sélectionner
la ligne elle-même télécharge aussi, au lieu d’ouvrir un enregistrement.

## Couper la cloche

1. Ouvrez **Mes paramètres** depuis le menu du compte, en bas de la barre
   latérale.
2. Dans le chapitre **Notifications**, désactivez **Notifications dans
   l’application**.

La cloche disparaît et le badge cesse de compter. Rien ne se perd : les
notifications envoyées pendant que la cloche est coupée apparaissent quand
vous la rallumez. Facet livre les notifications dans l’application seulement
— il n’y a pas d’e-mails de notification.

## Ce qui envoie une notification

| Ce qui arrive | Ce que vous recevez |
|---|---|
| Une personne vous mentionne dans un commentaire | Une notification qui ouvre l’enregistrement portant le commentaire. Une modification qui vous ajoute vous notifie aussi ; conserver une mention au fil d’une modification reste silencieux |
| Un export ou un import se termine | Une notification avec le fichier, prêt au téléchargement |
| Une automatisation en envoie une | Ce que l’automatisation envoie, au sujet de l’enregistrement qui a changé |

Les automatisations sont de petits scripts que l’auteur du domaine attache à
un type d’enregistrement. Elles s’exécutent quand des enregistrements
changent ou selon un calendrier, et l’une des choses qu’elles peuvent faire
est d’envoyer une notification. Ce qui arrive, et quand, relève de la
décision de l’auteur — adressez-vous à lui, ou à votre administrateur, quand
une automatisation fait trop de bruit.

## Dépannage

### Aucune notification n’arrive

Vérifiez d’abord votre propre interrupteur : **Mes paramètres** →
**Notifications** → **Notifications dans l’application**. Quand il est
coupé, la cloche est cachée. Vérifiez ensuite la source. Vous recevez une
mention seulement quand une personne vous mentionne dans un commentaire, et
une notification d’export seulement quand vous avez lancé cet export. Si un
collègue dit vous avoir mentionné et que rien n’est arrivé, demandez à votre
administrateur de vérifier l’automatisation.

### Le compteur de non-lues semble faux

L’espace de travail rafraîchit le compteur environ une fois par minute, et
les mises à jour en direct vous parviennent pendant que la page est ouverte.
Si le compteur paraît faux, attendez une minute ou rechargez la page.

### Tous les boutons d’action sont désactivés

Une action a déjà été exécutée sur cette notification — la ligne affiche
**Action effectuée**. Une notification exécute une seule action. Si vous
avez besoin de l’action à nouveau, ouvrez l’enregistrement et exécutez-la
là.

### Une action échoue

Votre rôle ne permet pas cette action sur cet enregistrement. Les
notifications ne sont pas un moyen de contourner vos droits — demandez le
droit à votre administrateur, ou demandez à un collègue qui le détient
d’exécuter l’action.

## Voir aussi

- [Commentaires et pièces jointes](/fr/use/documents/comments-attachments/) —
  d’où viennent les mentions dans les commentaires.
- [Importer et exporter des données](/fr/use/documents/import-export/) — les
  exports qui arrivent en notifications de téléchargement.
- [Vos réglages et clés API](/fr/use/account/) — l’interrupteur des
  notifications dans l’application.
- [Notifications et mentions (pour les auteurs)](/fr/build/model/automation/notifications/) —
  comment l’auteur du domaine envoie des notifications.
