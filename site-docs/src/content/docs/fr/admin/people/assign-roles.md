---
title: Affecter les rôles et l’élection
description: "Affectez des rôles aux comptes depuis l’éditeur d’affectations, et voyez pourquoi un seul rôle est élu à chaque connexion."
type: how-to
audience: [admin]
features: [RBC-02]
verified_at: eee55a2
sidebar:
  order: 3
---

Nadia chez Brightwater porte une seconde casquette : elle approuve les
réservations comme *Manager* et répond à l’assistant comme simple *Viewer*
quand elle teste. Vous donnez les deux rôles à son compte. À la connexion,
elle en choisit un — et Facet fait tourner chaque requête sous exactement
celui-là jusqu’à ce qu’elle change.

Un compte porte des rôles dans son tableau `roles`. Une requête ne les
fusionne jamais : elle tourne sous exactement un rôle élu. Cette page montre
comment un administrateur affecte et retire des rôles, et comment l’élection
fonctionne à la connexion et au refresh.

## Quand l’utiliser

- Vous embauchez un membre et devez lui donner ses rôles de travail.
- Vous déplacez un membre vers une autre équipe, avec d’autres droits.
- Vous devez expliquer pourquoi un membre agit sous un rôle alors qu’il en
  porte trois.

## Avant de commencer

- **La bonne page.** Ouvrez **Configurer → Accès → Affectations**. Il vous
  faut le droit `update` sur `iam.Account`.
- **Le garde-fou.** Le garde-fou d’autorité des rôles s’applique : vous ne
  pouvez affecter que des rôles de votre niveau élu ou en dessous. Voir
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).

## Étapes

### 1. Ouvrir l’éditeur d’affectations

Ouvrez **Configurer → Accès → Affectations**. L’éditeur a deux modes :

| Mode       | Ce qu’il affiche                       | Ce qu’il écrit                                                  |
| ---------- | -------------------------------------- | --------------------------------------------------------------- |
| Par rôle   | Choisissez un rôle, voyez ses membres. | Le tableau `roles` de chaque compte que vous ajoutez ou retirez. |
| Par compte | Choisissez un compte, voyez ses rôles. | Le tableau `roles` de ce compte.                                |

Les deux modes partagent un seul chemin d’écriture. L’URL de la page accepte
les liens profonds, par exemple
`/Configure/access/assignments?mode=account&account=<id>` ; l’état survit à
un rechargement.

<!-- screenshot: configure-assignments -->

### 2. Affecter un rôle

Dans le mode Par compte, cherchez le compte par courriel, puis ajoutez un ou
plusieurs rôles. Chaque enregistrement émet une mise à jour du document
compte, comme un PATCH manuel :

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"roles": ["iam.Roles.editor", "iam.Roles.comment_author"], "default_role": "iam.Roles.editor"}' \
  "$(facet-cli host)/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

Remplacez les ids de rôles et l’id du compte par vos valeurs. La réponse est
le document compte mis à jour.

Les règles que l’écriture impose :

- Chaque rôle du tableau final doit exister et être vivant.
- Chaque rôle doit se situer à votre niveau ou en dessous.
- `default_role`, s’il est positionné, doit faire partie de `roles`.
- Le hook dédoublonne le tableau et garde l’ordre de première apparition.

:::tip
Quand le rôle retiré était le `default_role` du compte, l’éditeur le
repositionne sur le premier rôle restant. Quand vous accordez un premier
rôle à un compte sans défaut, ce rôle devient le défaut.
:::

### 3. Retirer un rôle

Sélectionnez **Retirer** sur la ligne du rôle, ou retirez-le du tableau.
L’écriture suit les mêmes règles. Vous ne pouvez pas vous retirer d’un rôle
au-dessus de votre niveau — la règle de protection de la cible bloque
l’écriture.

### 4. Vérifier le résultat

Relisez le compte :

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

Le tableau `roles` montre les ids affectés. Le membre voit le nouveau rôle à
sa prochaine connexion ou au refresh de son token.

## Comment fonctionne l’élection

### Un rôle par requête

Les rôles ne fusionnent jamais. Un compte qui porte `editor` et `viewer`
agit sous l’un d’eux par requête. L’ensemble effectif de permissions est
exactement celui d’un rôle. Rapprocher des périmètres entre deux rôles n’a
pas de réponse non surprenante ; Facet ne le tente pas. Voir
[Un rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/) pour le
modèle.

### L’élection à la connexion

La requête de connexion peut porter l’élection dans son champ `role`, comme
id qualifié :

```sh
curl -k -X POST -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "ana@example.tld", "password": "PASTE-THE-PASSWORD", "role": "iam.Roles.editor"}' \
  "$(facet-cli host)/Api/iam/login"
```

L’ordre de résolution : l’élection explicite, puis `default_role`, puis le
premier rôle affecté. Élire un rôle que le compte ne porte pas répond `403` :

```json
{"error": "Role 'iam.Roles.manager' is not assigned to this account"}
```

Les réponses de connexion, de refresh et de `me` portent toutes la paire :

- `active_role` — l’id du rôle élu.
- `available_roles` — les ids des rôles affectés, la liste entre laquelle un
  membre peut basculer.

Un compte sans rôle tourne sous le rôle `iam.Roles.anonymous` créé par
l’initialisation. La réponse montre `available_roles: []` avec le rôle
anonymous comme `active_role` ; l’espace de travail rend un écran sans rôle
à partir de cette paire. Voir
[Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)
pour ce que contrôle le rôle anonymous.

### Changer de rôle pendant une session

Un membre change de rôle sans se reconnecter. La route de refresh accepte la
nouvelle élection :

```sh
curl -k -X POST -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"role": "iam.Roles.viewer"}' \
  "$(facet-cli host)/Api/iam/refresh"
```

Deux refus existent, et ils veulent dire des choses différentes :

- `403 Role not assigned` — le compte ne porte pas le rôle dans son tableau
  `roles`. C’est aussi la réponse pour un nom de rôle qui existe mais n’a
  jamais été affecté, et pour un nom qui n’existe pas du tout.
- `403 Role not found or disabled` — le rôle est toujours dans le tableau du
  compte, mais son document a disparu. Corrigez les données, pas la
  connexion.

La barre latérale de l’espace de travail expose le même basculement dans son
menu **Changer de rôle**. Le manifeste de permissions du nouveau rôle voyage
dans la réponse, et l’interface se resserre aussitôt.

## Dépannage

### L’écriture d’affectation répond `403`

Vérifiez le niveau : vous ne pouvez affecter que des rôles de votre niveau
élu ou en dessous, et vous ne pouvez pas modifier un compte dont le plafond
de rôles dépasse le vôtre.

### Le membre ne voit rien de nouveau après l’affectation

Les rôles s’appliquent à la prochaine connexion ou au prochain refresh.
Demandez au membre de rafraîchir, ou de changer une fois de rôle.

### La connexion répond `403 Role not assigned`

L’élection nomme un rôle hors du tableau `roles` du compte. Affectez d’abord
le rôle, ou connectez-vous sans le champ `role`.

### Un membre agit avec des droits inattendus

Demandez-lui quel rôle il a élu. Un seul rôle s’applique par requête ; les
droits peuvent venir d’un rôle plus large que vous ne le pensez. Le journal
d’audit nomme le rôle agissant à chaque écriture — voir
[Voir qui a fait quoi](/fr/admin/history/audit/).

## Voir aussi

- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — ce
  que porte un rôle.
- [Gérer les comptes](/fr/admin/people/accounts/) — créez d’abord le compte.
- [Un rôle à la fois](/fr/admin/under-the-hood/one-role-at-a-time/) — le modèle
  un-rôle-par-requête.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — le `acting_role` à
  chaque écriture.
- [Se connecter, MFA, réinitialiser votre mot de passe](/fr/use/first-day/sign-in/) —
  les étapes de connexion du membre.
- Internes sur GitHub :
  [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
  [access-assignments.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/access-assignments.md).
- [Les rôles : qui voit et fait quoi](/fr/discover/how-it-works/roles/)
