---
title: L’assistant de construction de domaines
description: Rédigez un domaine entier en discutant avec l’assistant de construction.
audience: [author]
features: [AI-02, AI-06]
sidebar:
  order: 25
verified_at: fd345fe3
---

L’assistant de construction de domaines est un chat qui édite un domaine de
brouillon pour vous. Demandez un doctype, une mise en page ou des données
d’exempleà : l’assistant écrit les définitions et lance lui-même les
vérifications. Vous passez chaque étape en revue et gardez la maîtrise de la
publication.

## Quand l’utiliser

- Vous démarrez un domaine à partir d’une courte description plutôt que de formulaires vides.
- Vous voulez des modèles de vue rédigés pour un doctype existant.
- Vous voulez une boucle construire, vérifier, corriger qui ne vous oblige pas à cliquer dans les éditeurs.

## Avant de commencer

- **Droits de création.** Vous détenez les droits de créer des domaines et des
  doctypes. L’assistant agit sous votre nomà : chaque changement qu’il fait
  vous est attribué dans l’historique.
- **Un domaine de brouillon.** Le travail se fait dans un brouillon. Rien
  n’atteint les données réelles tant que vous n’avez pas publié.

## Étapes

### 1. Ouvrir l’assistant

1. Ouvrez **Builder** dans la barre latérale.
2. Créez un brouillon avec **Nouveau domaine**, ou ouvrez un brouillon existant.
3. Sélectionnez la commande de l’assistant dans la barre supérieure pour ouvrir
   la fenêtre de chat.

Le chat est lié à ce brouillon. Demandez directementà : « Modélise un client et
un contact, avec des sociétés qui portent plusieurs contacts. »

### 2. Demander le modèle

L’assistant crée et édite des doctypes dans le brouillon. Il choisit les types
de champs, pose les libellés et les couleurs, et câble les relations
parent/enfant. Il écrit aussi des modèles de vue et des vues de liste quand
vous demandez des pages.

:::tip
Décrivez le travail, pas le schéma. « Suis les tickets du support avec un état
et un ingénieur » donne de meilleurs résultats qu’une liste de champs.
:::

### 3. Suivre la trace

Chaque action de l’assistant s’affiche dans le chat comme un appel d’outilà :
vous voyez chaque création et chaque mise à jour au fil de l’eau. L’assistant
tourne en boucleà : il écrit une définition, lance la vérification, lit les
anomalies et les corrige. Vous pouvez l’interrompre à tout moment et prendre
la main dans les éditeurs.

### 4. Examiner avec des aperçus

Deux actions s’affichent dans le chat mêmeà : l’aperçu d’une mise en page avec
des données d’exemple, et un saut vers une page du Builder. Demandez
« montre-moi la page ticket » et jugez la mise en page avant de la garder.

### 5. Tester avec des documents d’exemple

Demandez à l’assistant de créer quelques documents. Il les écrit dans le
brouillon : vous ouvrez de vraies pages et de vrais formulaires, puis vous
effacez les exemples avant de publier.

### 6. Publier vous-même

L’assistant ne peut ni publier, ni modifier des attributions, ni toucher aux
domaines réels. Terminez dans le Builderà : lancez la vérification, lisez le
rapport et publiez. Voir
[Vérifier un domaine avant publication](/fr/build/checking-before-publish/).

## Exemple

Une courte session pour un domaine d’inventaireà :

> **Vousà :** Modélise un domaine d’entrepôt. Des articles en stock avec un
> nom, une unité et une quantité. Les livraisons portent plusieurs lignes,
> chacune pointant vers un article.
>
> **Assistantà :** crée `StockItem` et `Delivery` avec un enfant `DeliveryLine`,
> pose les modèles `display_name` et lance la vérification. Deux anomalies
> reviennentà : un lien parent à sens unique et une référence entrante
> manquante chez l’enfant. L’assistant corrige les deux et revérifie jusqu’à
> un rapport propre.
>
> **Vousà :** Montre la page livraison.
>
> **Assistantà :** rend une carte d’aperçu de la page livraison avec trois
> lignes d’exemple.

Le brouillon tient maintenant un modèle vérifié. Vous ouvrez l’onglet
Vérification, lisez le rapport propre et publiez vers `warehouse`.

## Comment l’assistant connaît Facet

L’assistant embarque un ensemble de guides de rédaction : l’anatomie d’un
doctype, les types de champs, les règles de périmètre, les agencements de vues
et le déroulé de la vérification. Quand il rencontre une règle qu’il ne
connaît pas, il lit d’abord le guide correspondant. Voil à pourquoi sa sortie
suit les mêmes conventions qu’un auteur soigneux.

## Dépannage

**L’assistant ne peut rien créer.**

Il manque à votre rôle le droit de créer un domaine ou un doctype. Demandez à

un administrateur.

**Le chat édite un autre domaine.**

Le chat se lie au brouillon depuis lequel vous l’avez ouvert. Rouvrez le chat
dans le bon brouillon.

**Un changement est faux.**

Dites-le dans le chat, ou annulez dans les éditeurs. L’historique montre
chaque écriture de l’assistant sous votre nomà ; un retour arrière fonctionne
comme pour n’importe quel changement.

**L’aperçu semble cassé.**

Le modèle est peut-être lié à un champ qui n’existe pas encore. Demandez à

l’assistant de lancer la vérificationà ; les erreurs de liaison nomment le
champ.

## Voir aussi

- [Référence des outils d’agent](/fr/reference/agent-tools/) — chaque outil que l’assistant peut appeler.
- [L’IA sous les droits de l’appelant](/fr/concepts/ai-under-callers-rights/) — pourquoi ses changements portent votre nom.
- [Vérifier un domaine avant publication](/fr/build/checking-before-publish/) — lisez le rapport que l’assistant a parcouru.
