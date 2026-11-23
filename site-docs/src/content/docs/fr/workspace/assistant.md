---
title: Utiliser l’assistant
description: Ouvrir le chat, interroger vos documents, et laisser l’assistant faire des changements pour vous.
audience: [user]
features: [FE-22, AI-01]
sidebar:
  order: 11
verified_at: 49d7c7e5
---

L’assistant est une fenêtre de chat qui travaille avec vos données. Vous
demandez avec des mots de tous les jours. Il trouve des documents, fait des
changements, fait des calculs, et ouvre des pages. Les réponses arrivent
pendant qu’il travaille. Tout ce qu’il fait tourne dans les droits de votre
compte.

## Avant de commencer

Votre rôle doit porter l’accès à l’assistant. Votre administrateur l’accorde.
Si la barre supérieure ne montre pas de bouton d’assistant, votre rôle ne
porte pas l’accès à l’assistant. Demandez à votre administrateur de
l’activer.

## Étapes

### 1. Ouvrez le chat

Utilisez l’un de ces chemins :

- Sélectionnez le bouton « Assistant » dans la barre supérieure.
- Appuyez sur Ctrl+I, ou Cmd+I sur un Mac.
- Ouvrez la palette de commandes (Ctrl+K ou Cmd+K) et sélectionnez « Ouvrir ou
  fermer l’assistant ».

  Le chat s’ouvre comme une fenêtre flottante. Déplacez-la, redimensionnez-la,
  repliez-la ou agrandissez-la. Votre instance montre peut-être un autre nom
  que « Assistant ». Votre administrateur règle ce nom.

:::tip
La fenêtre reste ouverte pendant que vous vous déplacez dans l’espace de
travail. Gardez-la à côté de votre travail et posez vos questions au fil de
l’eau.
:::

### 2. Demandez ce dont vous avez besoin

Tapez dans la zone de message. Appuyez sur Entrée pour envoyer. Appuyez
sur Maj+Entrée pour ajouter une nouvelle ligne. Vous pouvez aussi
sélectionner le bouton d’envoi.

Exemples :

- « Trouve les sociétés avec le statut prospect. »
- « Montre les tâches dues cette semaine sous forme de cartes. »
- « Additionne le chiffre d’affaires annuel de ces sociétés. »
- « Passe le statut d’Acme Corp à actif. »
- « Crée une tâche pour la relance d’Acme. »
- « Ouvre la page d’Acme Corp. »

L’assistant écrit dans la langue de votre espace de travail. Vous pouvez lui
demander d’écrire dans une autre langue.

### 3. Suivez le travail

La réponse arrive en streaming pendant que l’assistant travaille. Un bloc
« Réflexion » montre son raisonnement. Il se replie quand la réponse démarre.
Les résultats apparaissent comme des cartes de documents, des lignes compactes
ou des tuiles de nombres. Quand l’assistant vous ouvre une page, l’espace de
travail s’y rend aussitôt.

Le bouton d’envoi devient « Arrêter » pendant que l’assistant travaille.
Sélectionnez-le pour annuler la réponse en cours. Le texte déjà écrit reste,
marqué « Annulé. ».

### 4. Gardez vos conversations

Le rail à gauche liste vos conversations. Sélectionnez-en une pour la
continuer. Sélectionnez « + Nouvelle » pour en démarrer une autre.
L’interrupteur dans l’en-tête du rail montre les conversations archivées. Une
réponse terminée porte un bouton de copie. Il copie le texte de la réponse.

## Ce que l’assistant peut faire

L’assistant peut :

- trouver et lire des documents, y compris dans les listes
- montrer des documents comme des cartes dans le chat
- créer, changer et supprimer des documents. Une suppression envoie le
  document à la corbeille.
- lancer les actions nommées d’une liste
- calculer des décomptes, des sommes, des moyennes, des minimums et des
  maximums
- ouvrir des pages dans l’espace de travail
- lire l’historique d’un document

Tout cela tourne dans les droits de votre compte :

- L’assistant ne voit que ce que votre compte peut voir. Un champ caché reste
  caché. Une ligne que vous ne pouvez pas lire reste dehors.
- Facet enregistre chaque changement sous votre compte, dans le même
  historique que vos modifications manuelles.
- Un refus est définitif. Quand l’assistant refuse une action, redemander ne
  change pas la réponse. Il vous manque le droit. Demandez à votre
  administrateur, ou faites l’action vous-même si vous le pouvez.

  Ces règles sont les mêmes sur chaque chemin vers Facet. Lisez
  [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/)
  pour le modèle derrière elles.

## Limites d’usage

Quand votre compte a un budget, une barre au-dessus de la zone de message
montre votre consommation : « 12 % du budget sur 30 jours utilisé ».
Sans budget, vous ne voyez pas de barre.

Quand le budget est dépensé, Facet arrête les nouveaux messages :

> Vous avez utilisé la totalité de votre budget de jetons d’assistant pour
> cette fenêtre de 30 jours. Demandez à un administrateur d’augmenter le
> budget, ou attendez que l’ancienne consommation sorte de la fenêtre.

La fenêtre glisse. Une consommation de plus de 30 jours cesse de compter.

## Dépannage

### Le bouton de l’assistant manque

Votre rôle ne porte pas l’accès à l’assistant. Demandez à votre administrateur
de l’activer. Le chat est aussi absent des écrans de Configurer. C’est normal.

### L’assistant refuse une action

Le refus est définitif. Votre compte manque du droit. Demandez-le à votre
administrateur, ou faites l’action vous-même si vous le pouvez.

### Le message dit que vous avez utilisé tout votre budget

Par exemple : « Vous avez utilisé la totalité de votre budget de jetons
d’assistant pour cette fenêtre de 30 jours. »

Attendez que la vieille consommation sorte de la fenêtre, ou demandez à votre
administrateur d’augmenter le budget.

### La réponse s’est arrêtée à mi-chemin

La connexion s’est peut-être rompue. Le travail continue sur le serveur.

1. Rouvrez le chat. Facet rattrape et montre la réponse terminée.
2. Attendez que la réponse courante se termine. Vous ne pouvez pas envoyer le
   message suivant avant.

### Une ligne d’erreur apparaît

Par exemple : « Le tour a échoué. ».

Lisez l’erreur. Envoyez la demande à nouveau. Si l’échec se répète à chaque
fois, demandez à votre administrateur.

## Voir aussi

- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) —
  le modèle qui garde l’assistant dans vos droits.
- [Recherche et palette de commandes](/fr/workspace/search-command-palette/) —
  la palette ouvre aussi l’assistant.
- [Historique et retour arrière](/fr/workspace/history-undo/) — où apparaissent
  les changements de l’assistant.
- [Raccourcis clavier](/fr/workspace/keyboard-shortcuts/) — le raccourci de
  l’assistant et tous les autres.
- [Rôles, niveaux et garde-fou d’autorité](/fr/concepts/roles-levels-authority/) —
  ce que contrôle un rôle.
