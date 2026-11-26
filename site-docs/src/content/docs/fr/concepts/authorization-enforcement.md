---
title: Application des autorisations
description: Chaque requête passe par les contrôleurs, qui vérifient permissions, périmètres de lignes et étiquettes de champs avant que la moindre donnée ne circule.
audience: [evaluator, developer]
features: [RBC-03, RBC-06, RBC-09]
sidebar:
  order: 6
verified_at: 7a6cb462
---

Facet applique l’autorisation dans chaque opération sur les documents. Deux
composants font le travail : le contrôleur de lecture et le contrôleur
d’écriture. Chaque appelant passe les mêmes vérifications — une route, une
migration, un job en arrière-plan.

## Explication

<!-- d2
caller: Caller {class: external}
enforcer: Enforcers
permission: Permission
scopes: Row scopes
tags: Field tags
metadata: Metadata gate
denied: "Denied read: 404" {class: danger}

caller -> enforcer
enforcer -> permission
enforcer -> metadata
enforcer -> denied
permission -> scopes
scopes -> tags
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9a3dd412-light.svg" alt="Denied read: 404" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9a3dd412-dark.svg" alt="Denied read: 404" loading="lazy" />
</div>

Le modèle est un contrôle d’accès basé sur les rôles (RBAC). Chaque requête
porte une identité et un rôle élu. Les rôles ne fusionnent jamais.

Une ligne de permission nomme trois choses : une action, un chemin de
doctype, et un périmètre de lignes facultatif. L’action est `read`, `create`,
`update`, `delete`, ou une action nommée. Le chemin peut désigner un doctype,
un domaine entier, ou tous les doctypes à la fois.

**Périmètres de lignes.** Les périmètres de lignes sont des prédicats nommés
que le doctype déclare. Le contrôleur les compile en prédicats SQL. Sur une
liste, les prédicats rejoignent la requête, et la base ne renvoie que les
lignes que le rôle peut voir. Sur une lecture individuelle, le contrôleur
évalue le prédicat sur la ligne elle-même.

**Étiquettes de champs.** Les étiquettes de champs protègent le contenu. Un
rôle ne voit un champ que si ses `visible_tags` portent toutes les étiquettes
du champ. Les champs sans étiquette portent l’étiquette `default`. En
lecture, le serveur retire les champs invisibles à chaque niveau
d’imbrication. En écriture, toute modification d’un champ invisible est
refusée avec `403`, et l’erreur nomme le chemin du champ.

**Le refus ne divulgue rien.** Une lecture individuelle que le rôle ne peut
pas voir répond `404` — la même réponse qu’un document manquant. Une liste
répond `200` avec les seules lignes visibles. Sur une route d’enfant
imbriqué, une lecture de parent refusée et un parent manquant donnent le même
`404`.

**La barrière des métadonnées.** Elle couvre les métadonnées de rendu : les
lignes de définition `core.DocType` et les lignes `core.Domain`. Un rôle sans
ligne `read` sur ces doctypes reçoit quand même une ligne dès qu’il détient
une action quelconque sur ce qu’elle décrit. Sinon, la ligne est absente, pas
`403`. Les agrégats de champs suivent la même règle : un appelant sans droit
de lecture reçoit un résultat vide, `200` avec zéro ligne. Là où les
documents restent cachés, les décomptes et le schéma le restent aussi.

:::note
Les lectures masquent les champs invisibles en silence. Les écritures dans
ces champs échouent bruyamment : `403` avec le chemin du champ. Un appelant
dont le rôle ne voit pas un champ n’apprend jamais le type de ce champ par
une erreur de validation.
:::

### Le compromis

**Le débogage prend plus de temps.** Le masquage en `404` complique le
débogage. Impossible de distinguer un document manquant d’un document
refusé ; vérifiez les lignes de permission du rôle avant l’id.

**Les périmètres coûtent une requête.** Les prédicats de périmètres ajoutent
un coût de requête — la préparation du contexte exécute une requête en base à

chaque requête.

**Certaines listes restent vides.** La non-divulgation des métadonnées limite
les fonctions de liste : un rôle sans attributions ne voit aucun schéma pour
les doctypes cachés.

## Voir aussi

- [Sécurité et gouvernance](/fr/discover/security/) — le modèle d’accès en résumé.
- [Gouverner l’accès](/fr/admin/) — créez les rôles et les lignes de permission que lisent les contrôleurs.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) — comment l’identité et le rôle arrivent aux contrôleurs.
- [Rôles, niveaux et garde-fou](/fr/admin/people/who-can-change-roles/) — qui peut écrire les rôles et les comptes.
- [Domaines et isolement](/fr/discover/how-it-works/domains/) — la frontière que les permissions nomment.
- Internes sur GitHub : [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
