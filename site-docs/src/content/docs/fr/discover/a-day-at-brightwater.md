---
title: Une journée chez Brightwater
description: Suivez une journée fictive dans une entreprise de location d’équipement pour voir comment les pièces de Facet fonctionnent ensemble.
type: explanation
audience: [evaluator, user]
features: []
verified_at: eee55a2
sidebar:
  order: 3
---

Brightwater Rentals est l’entreprise fictive que nous utilisons dans tous les exemples. Elle loue tentes, podiums, sonorisation et éclairage pour des mariages, des festivals et des événements d’entreprise. Quarante-cinq personnes y travaillent, dans un bureau et un entrepôt. Cette page suit quatre d’entre elles au fil d’une journée de travail. Observez ce que chacune voit et fait — chaque scène renvoie à la page qui l’explique.

Brightwater range ses données dans trois **domaines** — un domaine est une zone du métier, avec ses propres types d’enregistrements, ses champs et ses règles :

| Domaine | Ce qu’il contient |
| --- | --- |
| `equipment` | Le stock : articles, catégories, tickets de réparation |
| `clients` | Les sociétés qui louent, et leurs contacts |
| `rentals` | Les réservations, avec leurs lignes de matériel |

| Personne | Métier | Ce qu’elle utilise |
| --- | --- | --- |
| Tom Aaland | Commercial | Les réservations et ses propres clients |
| Lucía Ferrer | Cheffe d’entrepôt | Le tableau de l’entrepôt et l’app de sortie |
| Nadia Bertrand | Directrice des opérations | Tout, y compris les coûts, et l’assistant |
| Ravi Menon | Administrateur informatique à temps partiel | Comptes, rôles, piste d’audit |

## Matin : Tom réserve un mariage

Tom vend aux wedding planners et aux organisateurs de festivals. Un client appelle : il faut six tentes, un podium et la sono pour le deuxième week-end de décembre.

Tom ouvre sa liste de clients et trouve la société du planner. Il crée une **réservation** pour les 12 et 13 décembre, avec une ligne par matériel. Il déclenche l’action **Confirmer** sur la réservation. Une règle d’automatisation du domaine `equipment` marque alors chaque article de ces lignes comme *sorti* sur le tableau de l’entrepôt, pour que personne ne réserve deux fois les tentes.

Deux règles ont travaillé en silence. Tom ne voit que les cinq sociétés dont il est gestionnaire de compte ; les clients des autres commerciaux restent invisibles pour lui. Et les articles de ses lignes sont maintenant marqués *sortis* pour tout le monde, pas seulement pour Tom.

<!-- screenshot: discover-a-day-booking-list -->

Comment les trois domaines se relient : [Domaines : où résident vos données](/fr/discover/how-it-works/domains/). Pourquoi Tom ne voit que ses clients : [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

## Midi : Lucía sort le matériel

Lucía dirige l’entrepôt. Ses outils sont le tableau de l’entrepôt dans l’espace de travail et une petite app de sortie qui liste les réservations du jour.

L’app de sortie est une petite app web qui se connecte par Facet. Lucía se connecte une seule fois, avec le compte qu’elle utilise partout. L’app peut lister les réservations et marquer les articles sortis ou rentrés — et rien d’autre. Une app ne peut jamais faire plus que ce que son utilisateur a le droit de faire.

Elle ouvre un article pour signaler une paroi de tente déchirée. Elle voit sa catégorie, son état et ses tickets de réparation. Elle ne voit pas ce que l’article a coûté : les prix d’achat sont cachés à son rôle. Elle ajoute une photo du dégât au ticket de réparation et mentionne Tom, qui doit le savoir avant la prochaine location.

<!-- screenshot: discover-a-day-warehouse-board -->

Pourquoi une app reste petite, et qui peut en construire : [Apps : construites vite, remplacées librement](/fr/discover/how-it-works/apps/). Champs cachés et règles de lignes : [Rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/).

## Après-midi : Nadia interroge l’assistant

Un client appelle Nadia, la directrice des opérations : Brightwater peut-il couvrir un événement d’entreprise le 12 décembre ? Nadia interroge l’assistant avec ses propres mots : *Quelles tentes sont libres le 12 décembre ?*

L’assistant répond à partir des données de Brightwater. Il agit sous le rôle de Nadia, donc il voit les coûts et toutes les réservations — la même vue qu’elle. Si elle lui demande de changer quelque chose, le changement atterrit dans l’historique sous son nom, jamais sous celui de l’assistant.

<!-- screenshot: discover-a-day-assistant -->

Comment l’assistant obtient ses droits : [L’assistant : l’IA avec vos droits](/fr/discover/how-it-works/assistant/).

## Soir : Ravi clôt la journée

Ravi s’occupe des comptes, des rôles et de la connexion. Il ne fait pas partie du métier de la location, et Facet lui montre encore une autre image.

Avant de partir, il ouvre la piste d’audit. Aujourd’hui, elle a enregistré la réservation de Tom et son **Confirmer**, les sorties de matériel de Lucía et sa photo sur le ticket de réparation, et chaque connexion entre-temps. Chaque entrée nomme la personne et l’app derrière elle. Quand un auditeur demandera au printemps prochain qui a changé une réservation et quand, la réponse est à une recherche de distance.

<!-- screenshot: discover-a-day-audit -->

Le modèle derrière la piste : [Sécurité et gouvernance](/fr/discover/security/). Le mode d’emploi au quotidien : [Voir qui a fait quoi](/fr/admin/history/audit/).

## Ce que cette journée montre

- Chaque zone du métier vit dans son propre domaine, avec ses types d’enregistrements et ses règles.
- Les rôles décident de ce que chaque personne voit — dans l’espace de travail, dans les apps, et dans ce que l’assistant peut atteindre.
- Les apps se connectent par Facet et héritent des limites de leur utilisateur.
- L’assistant travaille sous votre rôle, et ses changements portent votre nom.
- Chaque changement est enregistré, et l’historique survit à toutes les apps.

L’histoire est inventée. Vous pouvez charger les mêmes données d’exemple sur une instance de test et parcourir la journée vous-même — [Votre première heure](/fr/build/first-hour/) montre comment.

## Voir aussi

- [Pourquoi Facet](/fr/discover/why-facet/) — les problèmes auxquels Facet s’attaque.
- [Le tableau d’ensemble](/fr/discover/how-it-works/) — les cinq pièces, une page chacune.
- [Facet est-il fait pour vous ?](/fr/discover/is-it-right-for-you/) — les limites assumées.
- [Votre première heure](/fr/build/first-hour/) — chargez l’exemple Brightwater et parcourez la journée vous-même.
