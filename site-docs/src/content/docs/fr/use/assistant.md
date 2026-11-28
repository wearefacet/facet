---
type: how-to
title: Interroger l’assistant
description: Ouvrez la fenêtre de l’assistant, interrogez vos enregistrements en langage courant, et laissez-le modifier des données sous votre rôle.
audience: [user]
features: [FE-22, AI-01, AI-10, AI-11]
sidebar:
  order: 5
verified_at: c34885a
---

Vous savez ce dont vous avez besoin — « quelles tentes sont libres en juin »
— et vous préférez demander plutôt que cliquer dans les listes.
L’**assistant** est une fenêtre de discussion qui travaille sur vos
enregistrements : il les trouve, les modifie, et vous emmène à la bonne
page. Il s’exécute à l’intérieur de votre rôle : il ne voit ni ne fait
jamais plus que ce que vous pourriez faire vous-même.

## Avant de commencer

- [Connexion, MFA et mot de passe](/fr/use/first-day/sign-in/) — une session
  connectée ouvre l’assistant avec vos droits.

![The Assistant button in the top bar — selecting it opens the chat window.](/screens/use/assistant-1.png)

## Ouvrir l’assistant

Employez l’un de ces moyens :

- Sélectionnez le bouton **Assistant** dans la barre supérieure.
- Appuyez sur `Ctrl+I` (`Cmd+I` sur Mac).
- Ouvrez la palette de commandes (`Ctrl+K`) et sélectionnez **Ouvrir ou
  fermer l’assistant**.

La discussion s’ouvre comme une fenêtre flottante. Déplacez-la,
redimensionnez-la, repliez-la ou agrandissez-la. Elle vous accompagne quand
vous naviguez dans l’espace de travail : gardez-la à côté de votre travail
et posez vos questions au fil de l’eau. Votre organisation affiche peut-être
un autre nom qu’« Assistant » ; le fonctionnement reste le même.

S’il n’y a pas de bouton Assistant, votre rôle n’inclut pas l’accès à
l’assistant. Demandez à votre administrateur de l’activer.

## Que demander

Tapez dans la zone de message — son texte d’attente est « Interrogez vos
documents… » — et appuyez sur `Enter` pour envoyer. Maintenez `Shift` et
appuyez sur `Enter` pour passer à la ligne.

Des questions qui fonctionnent bien :

- « Trouve les entreprises dont le statut est lead. »
- « Quelles tentes sont libres le 14 juin ? »
- « Fais la somme du chiffre d’affaires annuel de ces entreprises. »
- « Passe le statut de Maison Lumière à active. »
- « Ouvre la réservation BK-2026-0001. »

L’assistant répond dans la langue de votre espace de travail ; vous pouvez
lui demander de répondre dans une autre langue.

## Suivre la réponse

La réponse arrive pendant que l’assistant travaille. Un bloc **Réflexion**
montre ce qu’il vérifie, et se replie quand la réponse commence. Les
résultats apparaissent sous forme de cartes d’enregistrement, de lignes
compactes ou de tuiles chiffrées. Quand l’assistant vous ouvre une page,
l’espace de travail s’y rend aussitôt.

Pendant que la réponse s’exécute, le bouton d’envoi devient **Arrêter**.
Sélectionnez-le pour annuler — le texte écrit jusque-là reste affiché,
marqué *Annulé*. Si vous fermez la fenêtre pendant le travail, la réponse se
termine quand même ; rouvrez la discussion et elle rattrape son retard.

## Conserver vos conversations

Le rail à gauche liste vos conversations. Sélectionnez-en une pour la
continuer, sélectionnez **+ Nouvelle** pour en démarrer une autre, et
servez-vous de l’interrupteur dans l’en-tête du rail pour voir les
conversations archivées. Une réponse terminée porte un bouton de copie.

Chaque conversation porte un titre. L’assistant le tire de votre premier
message ; la commande de renommage du rail fixe un nom à vous, et un nom
vide rétablit le titre automatique au message suivant.

## Ce qu’il sait faire — sous votre rôle

L’assistant peut :

- trouver et lire des enregistrements, dans un domaine ou dans tous
- montrer des enregistrements sous forme de cartes dans la discussion
- créer, modifier et supprimer des enregistrements — une suppression envoie
  l’enregistrement à la corbeille
- exécuter les actions nommées que l’auteur de votre domaine a définies
- compter, additionner et calculer des moyennes — et donner la plus petite
  et la plus grande valeur
- ouvrir des pages dans l’espace de travail
- lire l’historique d’un enregistrement et dire ce qui a changé

Chacune de ces actions s’exécute comme **vous, sous le rôle auquel vous êtes
connecté** :

- L’assistant ne voit que ce que votre rôle peut voir. Un champ illisible
  pour votre rôle reste invisible pour lui ; un enregistrement hors de votre
  portée reste hors de portée.
- Changez de rôle, et le message suivant s’exécute sous le nouveau rôle.
- Chaque modification qu’il fait est enregistrée dans l’historique de
  l’enregistrement sous votre nom — le même historique que vos modifications
  manuelles, marquée comme effectuée via l’assistant.
- Un refus est définitif. Quand l’assistant ne fait pas quelque chose, c’est
  que votre rôle ne le permet pas ; redemander ne change pas la réponse.
  Demandez à votre administrateur, ou faites-le vous-même si vous le pouvez.

La règle est la même sur toutes les portes d’entrée de Facet — voir
[L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/)
pour la version en mots simples.

## Où s’affiche la limite d’usage

Quand votre compte dispose d’un budget d’usage, une barre au-dessus de la
zone de message montre la part consommée : « 62 % du budget sur 30 jours
utilisé ». Pas de budget, pas de barre. La fenêtre glisse : l’usage de plus
de 30 jours cesse de compter.

Quand le budget est épuisé, l’assistant cesse d’accepter de nouveaux
messages :

> Vous avez utilisé la totalité de votre budget de jetons d’assistant pour
> cette fenêtre de 30 jours. Demandez à un administrateur d’augmenter le
> budget, ou attendez que l’ancienne consommation sorte de la fenêtre.

## Dépannage

### Le bouton Assistant est absent

Votre rôle n’inclut pas l’accès à l’assistant. Demandez à votre
administrateur de l’activer. Il n’y a pas non plus de discussion sur les
écrans de configuration — c’est normal.

### L’assistant refuse une action

Le refus est définitif : votre rôle ne le permet pas. Demandez à votre
administrateur, ou faites l’action vous-même si vous le pouvez.

### Le message indique que le budget est épuisé

Attendez que l’ancienne consommation sorte de la fenêtre de 30 jours, ou
demandez à votre administrateur d’augmenter le budget.

### La réponse s’est arrêtée en chemin

La connexion a peut-être été coupée, mais le travail continue. Rouvrez la
discussion — elle rattrape son retard et affiche la réponse terminée. Vous
ne pouvez pas envoyer le message suivant tant que la réponse en cours n’est
pas terminée.

### Une ligne d’erreur apparaît

Par exemple : « Le tour a échoué. ». Lisez l’erreur et renvoyez la demande.
Si elle échoue à chaque fois, demandez à votre administrateur.

## Voir aussi

- [L’assistant : une IA avec vos droits](/fr/discover/how-it-works/assistant/) —
  les règles qui maintiennent l’assistant dans votre rôle.
- [Historique et retour arrière](/fr/use/documents/history-undo/) — où
  apparaissent les modifications de l’assistant.
- [Recherche et palette de commandes](/fr/use/finding/search/) — la palette
  ouvre aussi l’assistant.
- [Raccourcis clavier](/fr/use/finding/keyboard-shortcuts/) — le raccourci
  `Ctrl+I` et tous les autres.
- [Connecter un agent IA](/fr/build/first-hour/connect-an-agent/) — donner à
  un agent extérieur le même accès gardé.
