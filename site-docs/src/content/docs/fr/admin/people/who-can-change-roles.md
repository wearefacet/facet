---
title: Rôles, niveaux et garde-fou
description: Un seul garde-fou borne chaque écriture sur les comptes et les rôles. Voyez ce qu’il vérifie, ce qu’il refuse, et ce qu’il coûte.
type: explanation
audience: [admin, author]
features: [RBC-01, RBC-07]
verified_at: eee55a2
sidebar:
  order: 6
---

Nadia pilote le travail client de Brightwater comme *Manager*, niveau 60.
Ravi gère toute l’instance comme *Administrator*, niveau 100. Quand Nadia
doit placer un collègue sur un rôle plus large, Facet décide si elle en a
le droit. Une règle décide : personne ne déplace l’autorité vers le haut.
Cette page montre cette règle — le **garde-fou d’autorité** — ce qu’elle
vérifie, et où elle refuse.

## Où siège le garde-fou

Un rôle est un document, et un compte est un document. Vous modifiez les
deux comme n’importe quel autre enregistrement. Un seul garde-fou borne
cette liberté sur ces deux doctypes.

Le garde-fou vérifie chaque écriture pilotée par l’appelant sur
`iam.Account` et `iam.Roles` : créations, mises à jour, suppressions,
actions nommées, et transitions de retour arrière. Il s’exécute après la
vérification ordinaire des permissions. Un appelant dont le rôle ne porte
aucune ligne d’écriture sur le doctype cible n’atteint jamais le garde-fou
— son écriture s’arrête plus tôt, avec un simple `403 Forbidden`. Un
appelant qui passe cette vérification rencontre le garde-fou. Un refus
répond `403` avec le message `Role authority refused this write`, et sa
liste `details` nomme la vérification échouée.

Une écriture refusée ne change rien. Aucune ligne n’entre dans
l’historique, et aucun événement ne part. Le garde-fou exécute ses
vérifications avant tout changement en base, et les omissions de permission
au niveau des routes ne le contournent pas. Seuls les appels système
internes de Facet le sautent.

*Une vérification se tient entre l’appelant et chaque écriture sur un
compte ou un rôle.*

<!-- d2
direction: down
caller: Caller with one elected role {class: external}
write: Write to iam.Account or iam.Roles {class: node}
gate: Authority guard {class: decision}
applied: Write applies {class: ok}
denied: 403, nothing lands {class: danger}

caller -> write: update line on iam.Account or iam.Roles
write -> gate
gate -> applied: all four checks pass
gate -> denied: any check fails
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/6c20204e-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/6c20204e-dark.svg" alt="Diagram" loading="lazy" />
</div>

Le niveau que lit le garde-fou vient de l’unique rôle élu de l’appelant —
jamais du rôle le plus élevé que l’appelant porte. Les rôles ne fusionnent
jamais ; voir
[Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/)
pour savoir pourquoi Facet élit un seul rôle par requête.

## Les quatre vérifications

Chez Brightwater, *Sales* et *Warehouse* siègent au niveau 40, *Manager* à
60, et *Administrator* à 100. Le niveau vient du document du rôle ; il est
obligatoire, et il court de 0 à 100. Le garde-fou le lit et pose quatre
questions :

| Vérification | La question posée |
| --- | --- |
| Niveau de l’appelant | Le rôle élu porte-t-il un niveau utilisable ? Un rôle sans niveau refuse toute écriture IAM. |
| Affectation | Chaque rôle du tableau `roles` final existe-t-il, est-il vivant, et se situe-t-il au niveau de l’appelant ou en dessous ? |
| Protection de la cible | Le compte ou le rôle cible se situe-t-il au niveau de l’appelant ou en dessous ? |
| Écriture du rôle | Le rôle modifié reste-t-il dans ce que le rôle précédent et le rôle de l’appelant impliquent ? |

Les trois premières empêchent l’autorité de monter. La dernière empêche un
éditeur de rôles d’élargir un rôle vers ce que personne n’a accordé. Chaque
ligne de permission doit découler des lignes du rôle précédent ou de celles
de l’appelant. Les nouvelles étiquettes de champs doivent rester dans
l’union des deux, et les canaux de connectivité et le budget de
l’assistant suivent la même inclusion. Une écriture qui ajoute un champ de
pouvoir de rôle inconnu est refusée.

## Où le garde-fou refuse

Les refus ci-dessous ont tourné sur l’instance Brightwater avec un rôle de
test de niveau 60 qui portait la ligne d’écriture des comptes — le même
niveau que le *Manager* de Nadia.

**Le compte de Ravi est hors de portée, même pour l’abaisser.** Une
écriture sur tout compte dont le plus haut rôle attribué siège au-dessus de
l’appelant est refusée :

```json
{"error": "Role authority refused this write", "details": [{"message": "account's current role ceiling (100) is above the caller level (60)", "code": "forbidden"}]}
```

:::caution
Un changement qui ne fait que restreindre reste une écriture. Un appelant
de niveau 60 ne peut pas retirer des rôles du compte de Ravi, pas même par
gentillesse. Seul Ravi, ou un autre administrateur, modifie ce compte.
:::

**Le rôle Administrator ne peut pas être distribué.** Ajouter
`iam.Roles.admin` au tableau `roles` de n’importe qui échoue à la
vérification d’affectation :

```json
{"error": "Role authority refused this write", "details": [{"message": "role 'iam.Roles.admin' (level 100) is above the caller level (60)", "code": "forbidden"}]}
```

**Le document du rôle Administrator est lui aussi hors de portée.** Un
patch sur le document du rôle lui-même heurte la protection de la cible
avant toute vérification de contenu :

```json
{"error": "Role authority refused this write", "details": [{"message": "existing role level (100) is above the caller level (60)", "code": "forbidden"}]}
```

**Le même niveau suffit pour affecter.** Un appelant peut affecter un rôle
existant à son propre niveau, même quand ce rôle porte des permissions qui
lui manquent. Nadia peut poser *Manager* sur un compte ; un responsable de
niveau 40 peut y poser *Warehouse*. La délégation demande cela — un
responsable d’équipe dote son équipe sans porter chaque pouvoir d’équipe.
Créer un rôle au-dessus du niveau de l’appelant reste refusé. Élargir un
rôle au-delà de ce que le rôle précédent ou le rôle de l’appelant implique
est refusé avec une ligne nommée :

```json
{"error": "Role authority refused this write", "details": [{"message": "permissions[2] (read on clients.Company) is not implied by the previous role or the caller's role", "code": "forbidden"}]}
```

## Ce que le garde-fou coûte

**La réparation demande un administrateur plus haut placé.** Un compte dont
le plafond siège au-dessus d’un appelant est en lecture seule pour lui ;
une erreur dessus attend un administrateur. C’est le prix de la fermeture
de l’attaque « abaisser puis élargir » : personne en dessous d’une cible ne
peut la toucher, pas même pour la réduire.

**Les rôles ne s’imbriquent pas.** Le niveau classe les rôles ; il ne
propage pas les droits. Chaque rôle liste la totalité de ses lignes de
permission, et un rôle plus large n’accorde jamais ses lignes à un rôle
plus étroit. La portée d’un rôle reste lisible en un seul endroit : le
document du rôle.

Le garde-fou ne remplace pas les autres vérifications. Les lignes de
permission ordinaires, les périmètres de lignes et les étiquettes de champs
s’appliquent toujours à chaque écriture — le garde-fou ajoute la borne
d’autorité par-dessus. Voir
[Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/)
pour savoir où s’exécute chaque vérification.

## Voir aussi

- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) —
  les quatre vérifications en tableau d’opérateur.
- [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) — le
  flux d’affectation que le garde-fou borne.
- [Imposer le MFA](/fr/admin/people/mfa/) — la page suivante du volet
  personnes.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) —
  pourquoi le rôle élu fixe votre autorité.
- [Application des autorisations](/fr/admin/under-the-hood/how-access-is-enforced/) —
  les vérifications à côté desquelles siège le garde-fou.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
