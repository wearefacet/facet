---
title: Application des autorisations
description: Permissions, périmètres de lignes et étiquettes de champs sont vérifiés à chaque requête, et chaque type de refus a un sens précis.
type: explanation
audience: [developer, admin]
features: [RBC-03, RBC-06, RBC-09]
verified_at: eee55a2
sidebar:
  order: 3
---

Facet applique l’autorisation dans chaque opération sur les documents.
Deux composants font le travail : le contrôleur de lecture et le
contrôleur d’écriture. Chaque appelant passe les mêmes vérifications — une
route, une migration, un job en arrière-plan. Les sections suivantes
nomment chaque vérification et la réponse de chaque refus.

*Quatre vérifications se dressent entre l’appelant et les données.*

<!-- d2
direction: down
caller: Caller {class: external}
enforcer: Enforcers
permission: Permission
scopes: Row scopes
tags: Field tags
metadata: Metadata gate
denied: "Denied" {class: danger}

caller -> enforcer
enforcer -> permission
enforcer -> metadata
enforcer -> denied
permission -> scopes
scopes -> tags
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/67706c52-light.svg" alt="Denied" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/67706c52-dark.svg" alt="Denied" loading="lazy" />
</div>

Le modèle est un contrôle d’accès basé sur les rôles (RBAC). Chaque
requête porte une identité et un rôle élu. Les rôles ne fusionnent jamais
— voyez [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/)
pour la façon dont chaque canal construit cette paire.

## La ligne de permission

Une ligne de permission nomme trois choses : une action, un chemin de
doctype, et un périmètre de lignes facultatif. L’action est `read`,
`create`, `update`, `delete`, ou une action nommée. Le chemin peut
désigner un doctype, un domaine entier, ou tous les doctypes à la fois.

## Les périmètres de lignes

Les périmètres de lignes sont des prédicats nommés que le doctype déclare.
Le contrôleur les compile en prédicats SQL. Sur une liste, les prédicats
rejoignent la requête, et la base ne renvoie que les lignes que le rôle
peut voir. Sur une lecture individuelle, le contrôleur évalue le prédicat
sur la ligne elle-même.

## Les étiquettes de champs

Les étiquettes de champs protègent le contenu. Un rôle ne voit un champ
que si ses `visible_tags` portent toutes les étiquettes du champ. Les
champs sans étiquette portent l’étiquette `default`. En lecture, le
serveur retire les champs invisibles à chaque niveau d’imbrication. En
écriture, toute modification d’un champ invisible est refusée avec `403`,
et l’erreur nomme le chemin du champ. Un filtre ou un tri sur un champ
invisible est refusé avec `403` lui aussi, avant l’exécution de la
requête.

## Ce que signifie chaque refus

Chaque refus appartient à l’une de deux classes, et la réponse suit la
classe :

- **Refus de classe.** L’appelant ne détient aucune permission pour
  l’opération sur le doctype — aucune ligne ne correspond, ou le plafond
  d’attribution de l’app refuse. Les surfaces de lecture et d’écriture
  répondent `403`. Savoir qu’un doctype existe est acceptable ; savoir
  qu’un document existe ne l’est pas.
- **Refus de ligne.** L’appelant détient une attribution, mais la ligne
  échappe au périmètre, ou la ligne n’existe pas. La réponse est le `404`
  sans divulgation : un document inaccessible est indiscernable d’un
  document manquant.

Une réponse de liste suit la même répartition. Un appelant sans ligne de
lecture sur le doctype reçoit `403`. Un appelant avec périmètre reçoit
`200` avec les lignes visibles, peut-être aucune — le périmètre de lignes
ne se transforme jamais en `403`. Sur une route d’enfant imbriqué, le
contrôle de lecture du parent tourne d’abord. Un refus de classe sur le
parent répond `403` ; un parent invisible pour l’appelant répond `404`.

## La barrière des métadonnées

La barrière des métadonnées couvre les métadonnées de rendu : les lignes
de définition `core.DocType` et les lignes `core.Domain`. Un rôle sans
ligne `read` sur ces doctypes reçoit quand même une ligne dès qu’il
détient une action quelconque sur ce qu’elle décrit. Sinon, la ligne est
absente, pas `403`. Les agrégats de champs suivent la même règle : un
appelant sans attribution de lecture reçoit un résultat vide, `200` avec
zéro ligne. Là où les documents restent cachés, les décomptes et le schéma
le restent aussi.

:::note
Les lectures masquent les champs invisibles en silence. Les écritures dans
ces champs échouent bruyamment : `403` avec le chemin du champ. Un
appelant dont le rôle ne voit pas un champ n’apprend jamais le type de ce
champ par une erreur de validation.
:::

## Les compromis

**Le débogage prend plus de temps.** Un refus de ligne répond `404`, comme
un document manquant, et cela complique le débogage. Impossible de
distinguer un document manquant d’un document refusé ; vérifiez les lignes
de permission du rôle avant l’id.

**Les périmètres coûtent une requête.** Les prédicats de périmètre
ajoutent un coût de requête — la préparation du contexte exécute une
requête en base à chaque requête.

**Certaines listes restent vides.** La non-divulgation des métadonnées
limite les fonctions de liste : un rôle sans attributions ne voit aucun
schéma pour les doctypes cachés.

## Voir aussi

- [Sécurité et gouvernance](/fr/discover/security/) — le modèle d’accès en
  résumé.
- [Rôles et permissions](/fr/admin/people/roles-and-permissions/) —
  créez les lignes que lisent les contrôleurs.
- [Ne montrer à chaque rôle que ses lignes](/fr/admin/people/row-scopes/) —
  les périmètres de lignes entre les mains de l’administrateur.
- [Cacher un champ à certains rôles](/fr/admin/people/hidden-fields/) —
  les étiquettes de champs entre les mains de l’administrateur.
- [Pourquoi un seul rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/) —
  comment l’identité et le rôle arrivent aux contrôleurs.
- [Qui peut changer les rôles](/fr/admin/people/who-can-change-roles/) —
  qui peut écrire les rôles et les comptes.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
  [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
