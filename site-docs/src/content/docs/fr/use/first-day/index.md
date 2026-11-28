---
type: tutorial
title: Visite de l’espace de travail
description: "Parcourez l’écran de haut en bas : barre latérale, listes, document, recherche, assistant, notifications et menu du compte."
audience: [user]
features: [FE-19, FE-02, FE-07]
sidebar:
  order: 1
verified_at: eee55a2
---

Vous avez un compte Facet et l’adresse de l’espace de travail de votre
organisation. Cette page parcourt l’écran une fois, de haut en bas. Chaque
étape reçoit une capture d’écran, pour que vous puissiez comparer ce que
vous voyez à ce que la page montre. Après la visite, vous savez où vivent
vos enregistrements et où se trouve chaque action quotidienne.

Les exemples utilisent Brightwater Rentals, une entreprise fictive de
location d’équipements événementiels que la documentation suit partout.
Nadia gère l’entreprise, Tom vend, et Lucía dirige l’entrepôt.

## Si la visite de bienvenue s’ouvre

Quand une organisation démarre Facet, le tout premier compte administrateur
voit une courte présentation à sa première connexion. Elle compte sept
cartes : à quoi sert Facet, ce qu’est un **domaine**, comment les
enregistrements prennent forme sans code, qui peut lire et changer quoi,
comment chaque changement reste enregistré, comment Facet se connecte à
d’autres outils, et une dernière carte qui pointe vers le premier domaine.

![The welcome tour's first card, titled "A governance layer", with the Next button.](/screens/build/run-facet-2.png)

Les utilisateurs ordinaires ne voient pas cette fenêtre. Si elle s’ouvre
pour vous, c’est que votre compte détient le rôle administrateur. Cliquez
sur **Suivant** pour lire les cartes, ou sur **Terminé** pour fermer la
visite. La case **Ne plus afficher** la garde fermée ensuite. Vous pouvez la
rouvrir dans **Mes paramètres**, sous **Visite de bienvenue**.

## La page d’accueil

Connectez-vous, et Facet ouvre la page d’accueil. Elle vous salue par votre
prénom et nomme le rôle sous lequel vous travaillez. Tout ce qui suit répond
à une question : que puis-je atteindre ?

![Nadia's home page: the greeting "Hello Nadia, connected as Manager", links to key surfaces, and cards for applications, drafts and domains.](/screens/use/first-day-tour-1.png)

De haut en bas :

| Élément | Ce que vous voyez |
| --- | --- |
| Salutation | Votre prénom, et le rôle sous lequel vous travaillez, par exemple *Manager*. |
| Surfaces clés | Des raccourcis vers les zones que votre rôle permet, telles que **Builder**. Un lien que votre rôle ne permet pas ne s’affiche pas. |
| Applications | Une carte par application exploitée par votre organisation. La section se cache quand il n’y en a aucune. |
| Brouillons en cours | Les domaines que votre équipe construit encore, avec une coche quand ils sont prêts à publier. |
| Domaines | Une carte par domaine que vous pouvez lire. Sélectionnez une carte pour ouvrir le tableau de bord de ce domaine. |

Un domaine couvre un secteur d’activité — pour Brightwater, *Equipment*,
*Clients* et *Rentals*. Votre rôle décide des domaines affichés. Si votre
compte ne peut en lire aucun, la page affiche une carte **Aucun domaine
disponible** et vous demande de contacter votre administrateur.

## La barre latérale

La bande sombre à gauche reste en place sur chaque page. Elle liste le
domaine dans lequel vous travaillez actuellement et les types
d’enregistrements qu’il contient.

![Lucía's workspace: the sidebar shows the Equipment domain, the Item, Category and MaintenanceTicket types with record counts, and her account at the bottom.](/screens/use/first-day-tour-2.png)

De haut en bas :

- **Le logo.** Sélectionnez-le pour revenir à la page d’accueil depuis
  n’importe où.
- **Le sélecteur de domaine.** Affiche le domaine actif avec sa pastille de
  couleur. Sélectionnez-le pour choisir un autre domaine — la page affiche
  alors le tableau de bord de ce domaine.
- **Les types d’enregistrements.** Chaque ligne porte une icône, le nom du
  type, et le nombre de ses enregistrements. Sélectionnez une ligne pour
  ouvrir sa liste. La commande d’épinglage garde vos types les plus utilisés
  en haut.
- **Configurer**, pour les rôles qui gèrent l’espace de travail. La plupart
  des utilisateurs ne voient pas cette ligne.
- **Votre compte**, en bas — la dernière étape de cette visite.

Une petite commande de recherche se trouve au-dessus de la liste. Elle
trouve les types d’enregistrements par nom dans le domaine actif.

## Une liste

Sélectionnez un type d’enregistrement, et sa liste s’ouvre. Une liste est un
tableau d’enregistrements ; l’auteur du domaine en décide la forme — un
tableau, un kanban de cartes, ou un calendrier.

![Tom's Booking list: the toolbar on top, the table of bookings, and the sidebar on the left.](/screens/use/first-day-tour-3.png)

La barre d’outils en haut porte les actions quotidiennes : un bouton
**Nouveau** pour un nouvel enregistrement, la recherche sur cette liste, et
**Exporter** ou **Importer** là où votre rôle le permet. Sélectionnez une
ligne pour prévisualiser l’enregistrement sans quitter la liste.

Les listes, les filtres et les vues enregistrées ont leur propre page :
[Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/).

## Un document

Sélectionnez une ligne, et l’enregistrement s’ouvre sur sa propre page. Un
enregistrement est un **document** — une réservation, un article, un
client.

![Tom's booking BK-2026-0001: the header with the version pill and the action buttons, the fields below, and the comments panel on the right.](/screens/use/first-day-tour-4.png)

L’en-tête porte les actions dont vous avez le plus besoin :

- **Partager** copie l’adresse de la page pour l’envoyer à un collègue.
- **Historique** montre chaque changement enregistré de ce document.
- **Modifier** ouvre le formulaire de changement des champs. Il n’apparaît
  que si votre rôle peut modifier ce type d’enregistrement.
- **Actions** regroupe les étapes en un clic du type d’enregistrement, comme
  confirmer une réservation, et l’étape **Supprimer**, derrière une
  confirmation.

La page affiche les champs disposés par l’auteur du domaine. Un type
d’enregistrement sans page conçue affiche à la place une liste simple : un
champ par ligne, libellé et valeur.

## La recherche

La commande de recherche se trouve en haut à droite de chaque page.
Sélectionnez-la, ou appuyez sur `Ctrl+K` (`⌘K` sur Mac), et la **palette de
commandes** s’ouvre. Elle cherche des enregistrements dans tous vos domaines
et propose des sauts vers des pages et des actions.

![The top bar with the search control highlighted.](/screens/use/first-day-tour-5.png)

La palette ne propose jamais une page que votre rôle ne peut pas ouvrir.
Tapez une partie d’un nom, sélectionnez l’enregistrement, et sa page
s’ouvre. Voir
[Recherche et palette de commandes](/fr/use/finding/search/).

## L’assistant

La commande à étincelles à côté de la recherche ouvre l’assistant, une
fenêtre de discussion qui répond à des questions sur vos données et fait
des changements quand vous le demandez.

![The top bar with the assistant control highlighted.](/screens/use/first-day-tour-6.png)

Trois faits comptent le premier jour :

- L’assistant travaille sous **votre** rôle. Il voit ce que vous voyez et
  change ce que vous pouvez changer — rien de plus.
- Votre organisation décide si l’assistant est actif. Si votre rôle ne
  l’inclut pas, la commande ne s’affiche pas.
- Si la fenêtre dit « Ce projet n’a pas d’assistant IA configuré », un
  administrateur n’a pas encore connecté de modèle de langage.

L’assistant garde chaque conversation, pour que vous puissiez rouvrir les
questions d’hier. Adressez-lui vos demandes dans vos propres mots —
« Quelles réservations arrivent la semaine prochaine ? », « Marque la
réservation BK-2026-0003 comme retournée ».

## Les notifications

La cloche en haut à droite rassemble vos notifications : une mention dans un
commentaire, un export terminé, un événement que votre organisation vous
envoie.

![The top bar with the notifications bell highlighted, showing its unread badge.](/screens/use/first-day-tour-7.png)

Un nombre sur la cloche compte ce que vous n’avez pas lu. Sélectionnez la
cloche pour ouvrir le panneau ; sélectionnez une entrée pour aller à
l’enregistrement derrière elle. Quand tout est lu, le panneau dit
« Vous êtes à jour ».

## Le menu du compte

En bas de la barre latérale se trouve votre compte : vos initiales, votre
nom, et votre rôle actif.

![The bottom of the sidebar with Lucía's account highlighted: her name and the Warehouse role.](/screens/use/first-day-tour-8.png)

Sélectionnez votre nom pour ouvrir le menu :

- **Mes paramètres** — votre langue, votre fuseau horaire, et vos
  préférences de notification.
- **Clés API** et **Webhooks**, quand votre rôle le permet.
- **Changer de rôle**, quand votre compte détient deux rôles ou plus.
- **Déconnexion**.

Votre rôle décide de ce que le menu liste. Voir
[Vos réglages et clés API](/fr/use/account/).

## Dépannage

### Mon collègue voit un domaine ou un type que je ne vois pas

Votre rôle décide de ce que vous atteignez. Facet cache ce que le rôle ne
permet pas, partout — listes, recherche, assistant. Demandez à votre
administrateur de vérifier votre rôle. Voir
[Les rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

### La commande de l’assistant est absente

Votre rôle n’inclut pas l’assistant. Un administrateur peut l’ajouter à
votre rôle.

### L’assistant indique qu’aucun assistant IA n’est configuré

Votre organisation n’a pas connecté de modèle de langage. Un administrateur
en ajoute un dans **Paramètres système**. Votre compte n’a aucun problème.

### Un compteur d’enregistrements affiche un tiret au lieu d’un nombre

Le compteur n’est pas encore chargé, ou votre rôle ne peut pas compter ce
type d’enregistrement. Le tiret se remplit quand les données arrivent. S’il
reste en l’état, demandez à votre administrateur.

### L’enregistrement ouvert hier a disparu du tableau de bord

Les pastilles **Consultés récemment** vivent dans votre navigateur : elles
suivent le navigateur utilisé, et un historique de navigateur effacé les
vide. L’enregistrement lui-même n’est pas perdu : retrouvez-le par la
recherche ou sa liste.

## Voir aussi

- [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) — mots de
  passe, MFA, et déconnexion.
- [Le tableau de bord](/fr/use/first-day/dashboard/) — les pages d’accueil et
  de domaine en profondeur.
- [Listes, filtres et vues enregistrées](/fr/use/finding/lists-and-views/) —
  la surface de liste et ses vues.
- [Consulter et modifier un document](/fr/use/documents/view-and-edit/) — la
  page d’enregistrement et le formulaire de modification.
- [Vos réglages et clés API](/fr/use/account/) — ce que le menu du compte
  ouvre.
