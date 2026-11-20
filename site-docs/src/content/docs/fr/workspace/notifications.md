---
title: Notifications
description: Lire les notifications depuis la cloche de la barre supérieure, agir, et régler votre préférence dans l’application.
audience: [user]
features: [FE-09, AUT-06]
sidebar:
  order: 9
verified_at: 49d7c7e5
---

Facet livre les notifications dans l’espace de travail. Une cloche dans la
barre supérieure montre combien de notifications vous n’avez pas lues. Les
notifications vous parlent des mentions dans les commentaires, des exports
terminés, et des événements que les automatisations envoient.

## Étapes

### 1. Ouvrez le panneau de notifications

Sélectionnez la cloche dans la barre supérieure. Le panneau s’ouvre sous la
cloche. Il liste vos notifications, du plus récent au plus ancien. Une ligne
non lue montre un point et un titre en gras. La cloche affiche le nombre de
non lues tant que vous avez des notifications non lues.

### 2. Ouvrez une notification

Sélectionnez la ligne. Le panneau se ferme, marque la notification comme lue,
et ouvre l’enregistrement dont la notification parle.

### 3. Lancez une action

Une notification peut porter des boutons d’action, par exemple « Approuver »
ou « Réouvrir ». Une action tourne sur l’enregistrement, sous votre propre
rôle. Les mêmes vérifications s’appliquent que sur la page du document.
Certaines actions vous demandent de confirmer d’abord.

:::caution
La première action que vous lancez éteint tous les boutons d’action de la
ligne. La ligne affiche alors « Action effectuée ».
:::

### 4. Téléchargez un export

Une notification d’export porte un bouton « Télécharger ». Sélectionnez-le
pour enregistrer le fichier. Sur ces lignes, la sélection de la ligne elle-
même télécharge aussi le fichier, au lieu d’ouvrir un enregistrement.

### 5. Marquez tout comme lu

Sélectionnez « Tout marquer comme lu » en haut du panneau. Le bouton apparaît
quand vous avez des notifications non lues. Ouvrir une ligne marque cette
seule ligne comme lue.

### 6. Voyez les notifications plus anciennes

Le panneau montre une page de notifications. Sélectionnez « Charger plus » en
bas pour la page suivante.

### 7. Allumez ou éteignez les notifications

1. Ouvrez « Mes paramètres », et sélectionnez le chapitre « Notifications ».
2. Allumez ou éteignez « Notifications dans l’application ».

Quand il est éteint, la cloche se cache, et l’espace de travail cesse
d’afficher les notifications. Quand vous le rallumez, les notifications
envoyées entre-temps apparaissent.

:::note
Les notifications ne vivent que dans l’application. Facet n’envoie pas
d’e-mails de notification.
:::

## Ce qui envoie une notification

| Source | Ce que vous recevez |
| --- | --- |
| Une mention dans un commentaire | Une notification qui ouvre l’enregistrement portant le commentaire |
| Un export terminé | Une notification avec le fichier, prêt à télécharger |
| Une automatisation sur un doctype | Ce que l’automatisation envoie, à propos de l’enregistrement changé |

Les automatisations sont des scripts qui tournent quand un enregistrement
change. L’auteur du doctype décide du moment où une automatisation envoie une
notification.

## Dépannage

### Aucune notification n’arrive

1. Vérifiez d’abord la préférenceà : « Mes paramètres » →
   « Notifications » → « Notifications dans l’application ». Quand elle est
   éteinte, la cloche est cachée.
2. Vérifiez la source. Vous recevez une mention seulement quand quelqu’un vous
   mentionne dans un commentaire.

### Le nombre de non lues semble périmé

L’espace de travail rafraîchit le nombre tout seul. S’il semble faux, attendez
jusqu’à une minute, ou rechargez la page.

### Tous les boutons d’action sont éteints

Une action a déj à tourné sur cette notification. La ligne affiche
« Action effectuée ».

### Une action échoue

Votre rôle ne permet peut-être pas l’action sur cet enregistrement. Les
notifications ne sont pas un moyen de contourner les droits.

## Voir aussi

- [Commentaires et pièces jointes](/fr/workspace/comments-attachments/) —
  d’où viennent les mentions des commentaires.
- [Importer et exporter des données](/fr/workspace/import-export/) — les
  exports qui arrivent comme notifications de téléchargement.
- [Paramètres, sessions et clés API](/fr/workspace/settings-sessions-api-keys/) —
  l’interrupteur des notifications dans l’application.
- [Hooks d’événements et hooks planifiés](/fr/build/event-hooks/) — où vivent
  les automatisations qui envoient des notifications.
- [Événements et livraison](/fr/concepts/events-delivery/) — comment l’espace
  de travail reçoit les mises à jour en direct.
