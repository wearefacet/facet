---
type: how-to
title: Construire avec l’assistant
description: Rédigez un domaine entier en dialoguant avec l’assistant du Builder, qui écrit les définitions et lance les vérifications.
audience: [author]
features: [AI-02, AI-06]
sidebar:
  order: 2
verified_at: eee55a2
---

L’assistant du Builder est un chat qui modifie un domaine de brouillon à
votre place. Vous demandez un doctype, une mise en page ou des données
d’exemple, et l’assistant écrit les définitions et lance lui-même les
vérifications. Vous passez chaque étape en revue et gardez la maîtrise de
la publication.

## Quand l’utiliser

- Vous démarrez un domaine à partir d’une courte description plutôt que de
  formulaires vides.
- Vous voulez des modèles de vue rédigés pour un doctype existant.
- Vous voulez une boucle construire, vérifier, corriger sans devoir cliquer
  dans les éditeurs.

## Avant de commencer

- **Droits de création.** Vous détenez les droits de créer des domaines et
  des doctypes. La conversation vérifie les deux avant de s’ouvrir.
- **Un assistant configuré.** Un administrateur [connecte un modèle de
  langage](/fr/admin/assistant/connect-a-model/) dans les paramètres
  système, ou par l’environnement du serveur. Sans modèle, le chat vous le
  signale.
- **Un domaine de brouillon.** Le travail se fait dans un brouillon. Rien
  n’atteint les données réelles avant votre publication.

## Étapes

### 1. Ouvrir l’assistant

1. Ouvrez **Builder** dans la barre latérale.
2. Créez un brouillon avec **Nouveau domaine**, ou ouvrez un brouillon
   existant.
3. Sélectionnez la commande de l’assistant dans la barre supérieure pour
   ouvrir la fenêtre de chat.

Le chat est lié à ce brouillon. Demandez directement : « Modélise un
client et un contact, avec des sociétés qui portent plusieurs contacts. »

### 2. Demander le modèle

L’assistant crée et modifie des doctypes dans le brouillon. Il choisit les
types de champs, pose les libellés et les couleurs, et relie les relations
parent/enfant. Il écrit aussi des modèles de vue et des vues de liste quand
vous demandez des pages.

:::tip
Décrivez le travail, pas le schéma. « Suis les tickets du support avec un
état et un ingénieur » donne de meilleurs résultats qu’une liste de champs.
:::

### 3. Suivre la trace

Chaque action de l’assistant s’affiche dans le chat comme un appel
d’outil : vous voyez chaque création et chaque mise à jour au fil de
l’eau. L’assistant tourne en boucle : il écrit une définition, lance la
vérification, lit les anomalies et les corrige. Vous pouvez l’interrompre
à tout moment et prendre la main dans les éditeurs.

<!-- screenshot: assistant-chat-trace -->

### 4. Examiner avec des aperçus

Deux actions s’affichent dans le chat même : un aperçu d’une mise en page
avec des données d’exemple, et un saut vers une page du Builder. Demandez
« montre-moi la page ticket » et jugez la mise en page avant de la garder.

### 5. Tester avec des documents d’exemple

Demandez à l’assistant de créer quelques documents. Il les écrit dans le
brouillon : vous ouvrez de vraies pages et de vrais formulaires, puis vous
effacez les exemples avant de publier.

### 6. Publier vous-même

L’assistant ne peut ni publier, ni modifier des attributions de
consentement, ni toucher aux domaines réels. Terminez dans le Builder :
lancez la vérification, lisez le rapport et publiez. Voir
[Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/).

## Des prompts qui fonctionnent

Commencez petit, et demandez la vérification avant les extras. Ce prompt a
produit la trace ci-dessous sur l’instance en service :

```text
Create one doctype named Crate with a single string field name (required).
Give it a display_name template. Run the check and stop when it is clean.
Do not create views or documents.
```

Ce que vous voyez dans le chat : trois appels d’outil qui lisent les guides
de rédaction intégrés à l’assistant, puis la création, puis la
vérification. Le résultat de la création arrive sous la forme d’une courte
réponse JSON :

```json
{"ok":true,"data":{"doctype_id":"_06h1fr93h499.Crate","schema_version":1}}
```

L’identifiant porte le préfixe `_` du brouillon : le doctype existe dans le
brouillon, pas dans un domaine réel. La vérification revient propre, avec
des remarques d’information sur les vues que vous avez demandé à
l’assistant d’omettre.

Les erreurs dans la boucle sont normales et visibles. Dans la même session,
un premier `create_doctype` a répondu
`{"ok":false,"error":"Invalid doctype definition: Missing required field 'doctype'"}`
— l’assistant a corrigé sa propre définition et rappelé l’outil. C’est la
boucle qui fonctionne : créer, vérifier, corriger, revérifier.

Pour l’exemple Brightwater Rentals, une deuxième session construit le fil
utilisé dans la documentation :

```text
Add a MaintenanceTicket doctype linked to Item: a problem text, a status
(open / in_progress / done), and a reference to the item it is about.
Run the check until it is clean.
```

## Comment l’assistant connaît Facet

L’assistant embarque un ensemble de guides de rédaction : l’anatomie d’un
doctype, les types de champs, les règles de périmètre, les agencements de
vues et le déroulé de la vérification. Quand il rencontre une règle qu’il
ne connaît pas, il lit d’abord le guide correspondant. C’est pourquoi ses
sorties suivent les mêmes conventions qu’un auteur soigneux.

## Ce qu’il ne peut pas faire

Les limites sont appliquées dans chaque outil d’écriture, et pas seulement
par le prompt :

- **Pas de publication.** Aucun outil ne publie le brouillon ; c’est vous
  qui appuyez sur **Publier**.
- **Pas d’attributions ni d’ensembles de contexte.** Les outils qui les
  modifient ne sont pas montés ; l’assistant vous renvoie à l’onglet
  **Octrois**.
- **Rien hors du brouillon.** Chaque outil d’écriture vérifie que le
  domaine cible est celui du brouillon.
- **Pas de doctypes `core`.** La modification d’un doctype `core` (tel que
  `core.Comment`) est refusée, sauf si vous le demandez explicitement et
  confirmez le risque.

Chaque changement de l’assistant vous est attribué : l’historique montre
votre compte avec la cause *Assistant · domain-builder*, et non
« system ». Un changement erroné se corrige par un retour arrière, comme
n’importe quel autre.

## Dépannage

**L’assistant ne peut rien créer.**

Il manque à votre rôle le droit de créer un domaine ou un doctype.
Demandez à un administrateur.

**Le chat modifie un autre domaine.**

Le chat se lie au brouillon depuis lequel vous l’avez ouvert. Rouvrez le
chat dans le bon brouillon.

**Un changement est erroné.**

Dites-le dans le chat, ou annulez dans les éditeurs. L’historique montre
chaque écriture de l’assistant sous votre nom ; un retour arrière
fonctionne comme pour n’importe quel changement.

**L’aperçu semble cassé.**

Le modèle est peut-être lié à un champ qui n’existe pas encore. Demandez à
l’assistant de lancer la vérification ; les erreurs de liaison nomment le
champ.

## Voir aussi

- [Référence des outils d’agent](/fr/reference/agent-tools/) — chaque outil
  que l’assistant peut appeler.
- [L’assistant : une IA sous vos droits](/fr/discover/how-it-works/assistant/)
  — pourquoi ses changements portent votre nom.
- [Vérifier avant de publier](/fr/build/model/in-app/check-before-publish/)
  — lisez le rapport que l’assistant a parcouru.
