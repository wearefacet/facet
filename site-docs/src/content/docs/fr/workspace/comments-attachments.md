---
title: Commentaires et pièces jointes
description: Commenter un document et joindre des fichiers dans le panneau à côté de la page document.
audience: [user]
features: [DOM-06, FE-04]
sidebar:
  order: 5
verified_at: 49d7c7e5
---

Le panneau latéral se place à côté d’une page document. Servez-vous en pour
discuter du document en commentaires et pour garder ses fichiers en pièces
jointes. Les commentaires prennent le markdown, alors vous pouvez mettre en
forme du texte, mentionner des personnes, et lier d’autres documents.

## Avant de commencer

- **L’accès en lecture.** Il vous faut l’accès en lecture au document. Sans
  lui, Facet n’affiche ni le document ni le panneau.
- **Les droits de création.** Il vous faut le droit de création sur le doctype
  pour commenter ou joindre. Un droit manquant cache les commandes de cette
  page.
- **Les listes du panneau.** Un doctype décide des listes que le panneau
  porte. Un type sans listes n’en montre qu’une seule colonne.

## Étapes

### 1. Ouvrez le panneau latéral

Ouvrez un document. Le panneau se dresse à droite de la page et reste en place
pendant que vous faites défiler le document.

Un doctype peut porter plus d’une liste, par exemple Commentaires et Fichiers.
Chaque liste s’affiche alors comme un onglet avec un décompte. Le décompte se
met à jour quand vous ajoutez ou retirez une entrée.

Dans une fenêtre de 1100 pixels ou moins, le panneau passe sous le document.

### 2. Écrivez un commentaire

Ouvrez l’onglet Commentaires. La zone de saisie se tient en bas et reste
visible pendant que vous faites défiler le fil.

Tapez en mode « Écrire ». L’éditeur vous donne titres, tableaux, code et
liens. Sélectionnez « Aperçu » pour lire le résultat. Sélectionnez
« Markdown » pour éditer le texte brut.

Pour placer un fichier dans un commentaire, déposez-le ou collez-le dans
l’éditeur. Une image s’affiche dans le commentaire. Un autre fichier
s’affiche comme un lien de fichier. Facet téléverse le fichier quand vous
envoyez.

Sélectionnez « Commenter » pour envoyer. Pendant que Facet enregistre, le
bouton affiche « Publication… ». Votre commentaire rejoint alors la fin du fil
avec votre nom, votre image et l’heure.

:::tip[Envoi rapide]
Appuyez sur `Entrée` pour envoyer un commentaire. Appuyez sur
`Maj+Entrée` pour commencer une nouvelle ligne.
:::

### 3. Mentionnez une personne ou liez un document

Tapez `@` et commencez à taper un nom. Une liste s’ouvre avec des personnes et
des documents. Vous pouvez aussi taper `[[` pour ouvrir la même liste.

Choisissez une entrée. L’éditeur insère une pastille qui montre le nom actuel
de la personne ou du document. La personne que vous mentionnez reçoit une
notification.

La liste démarre avec le domaine du document. Utilisez la ligne « Tous les
domaines » pour chercher partout. Appuyez sur `Échap` pour fermer la
liste ; le texte que vous avez tapé reste.

La liste ne s’ouvre pas quand `@` se trouve dans un mot, par exemple dans une
adresse.

### 4. Répondez, modifiez ou supprimez un commentaire

**Répondre.** Sélectionnez « Répondre » sur le commentaire. Une pastille au-
dessus de la saisie affiche « Réponse à » et le nom. Tapez votre réponse et
sélectionnez « Commenter ». Pour arrêter, sélectionnez le bouton d’annulation
sur la pastille.

Facet imbrique les réponses sous le commentaire auquel elles répondent.
L’imbrication se voit sur trois niveaux. Une réponse plus profonde remonte et
porte une mention « en réponse à ». Un fil avec des réponses affiche
« Développer les réponses » ou « Réduire les réponses », avec le nombre de
réponses.

**Modifier.** Sélectionnez « Modifier » sur votre commentaire. Changez le
texte et sélectionnez « Enregistrer ».

**Supprimer.** Sélectionnez « Supprimer » et confirmez. Facet vous demande de
confirmer, parce qu’il ne peut pas annuler la suppression. Quand quelqu’un
supprime un commentaire qui a des réponses, Facet garde les réponses et
affiche un espace réservé à la place du commentaire supprimé.

Ces commandes n’apparaissent que sur vos propres commentaires. Votre rôle en
décide. Facet revérifie vos droits quand vous enregistrez.

### 5. Joignez un fichier

Ouvrez l’onglet Fichiers et sélectionnez « Choisir un fichier ». Le champ du
nom se remplit avec le nom du fichier. Changez-le si vous voulez.

Sélectionnez « Joindre ». Pendant que Facet téléverse, le bouton affiche
« Ajout en cours… ». Le fichier se liste alors avec son type, sa taille,
l’heure, et le compte qui l’a téléversé.

| Règle | Détail |
| --- | --- |
| Plus grand fichier | 50 mégaoctets par défaut. Votre administrateur règle la limite. |
| Types de fichiers | Tous |
| Même contenu | Facet stocke un contenu identique une seule fois et le réutilise. |
| Stockage | Facet garde les octets du fichier dans son magasin de fichiers, hors du document. |

### 6. Téléchargez, renommez ou retirez une pièce jointe

**Télécharger.** Sélectionnez la commande de téléchargement sur la ligne. Le
fichier s’ouvre dans un nouvel onglet. Facet vérifie votre accès à chaque
téléchargement.

**Renommer.** Sélectionnez la commande de renommage, changez le champ
« Nom de la pièce jointe », et enregistrez.

**Retirer.** Sélectionnez la commande de suppression et confirmez.

:::caution[La suppression est définitive]
Quand vous confirmez la suppression, la pièce jointe disparaît du document.
Facet demande : « Supprimer cette pièce jointe ? Cette action est
irréversible. »
:::

## Exemple

En mode « Écrire », vous tapez `@` et vous choisissez dans la liste. En mode
« Markdown », le même commentaire ressemble à ceci :

```markdown
Vérification des totaux avec [@Marie Dubois](urn:facet:iam:Account:01JCATPMKP4N82GVG2J7K4MHZZ).

| Élément | Montant |
| ------- | ------- |
| Licence | 480 |
```

## Dépannage

### Le panneau ne s’affiche pas

Le doctype ne porte aucune liste de panneau. Demandez à l’auteur du domaine
d’ajouter des commentaires au type. Voir
[Sidecars (commentaires, pièces jointes)](/fr/build/sidecars/).

Dans une fenêtre étroite, regardez sous le document. Le panneau se tient là.

### La zone de saisie manque

Votre rôle ne peut pas commenter ce doctype. Facet affiche : « Vous ne
pouvez pas commenter ce document. » Demandez le droit de commentaire à votre
administrateur.

### Facet refuse mon téléversement

1. Vérifiez la taille du fichier. Il dépasse peut-être la limite de taille. La
   limite par défaut est de 50 mégaoctets. Prenez un fichier plus petit, ou
   demandez à votre administrateur de relever la limite.
2. Vérifiez vos droits. Votre rôle manque peut-être aussi du droit de
   connexion de fichier. Facet affiche alors : « Vous ne pouvez pas
   joindre de fichiers à ce document. »

### Je ne vois pas Modifier sur un commentaire

Vous ne pouvez changer que vos propres commentaires. Un rôle de modérateur
peut agir sur n’importe quel commentaire. Demandez ce droit à votre
administrateur si vous en avez besoin.

## Voir aussi

- [Consulter et modifier un document](/fr/workspace/viewing-editing-document/) —
  ouvrez et modifiez le document qui héberge le panneau.
- [Notifications](/fr/workspace/notifications/) — ce que reçoit une personne
  quand vous la mentionnez.
- [Comment Facet vérifie les permissions](/fr/concepts/authorization-enforcement/) —
  les vérifications derrière chaque commentaire, téléversement et
  téléchargement.
- [Sécurité et gouvernance](/fr/start/security-governance/) — qui peut lire et
  changer des documents.
- [Sidecars (commentaires, pièces jointes)](/fr/build/sidecars/) — comment un
  auteur de domaine ajoute une liste de panneau à un doctype.
