---
title: Personnes et accès
description: "Donnez à chaque personne un compte, le bon rôle et les limites de ce rôle — en neuf étapes."
type: overview
audience: [admin]
features: [IAM-06, RBC-01]
verified_at: eee55a2
sidebar:
  order: 0
---

Lundi, une nouvelle commerciale rejoint Brightwater Rentals. Ravi,
l’administrateur à temps partiel, lui crée un compte, lui donne le rôle Sales,
et ajoute une règle qui ne lui montre que ses propres clients. Chacun de ses
clics se retrouve dans l’historique ; la prochaine question d’audit a déjà sa
réponse.

C’est toute l’histoire des personnes. Facet la découpe en neuf étapes, et
cette section les suit dans l’ordre. Chaque étape est une page, et chaque
page s’appuie sur la précédente.

## Le parcours dans l’ordre

| # | Page | Ce que vous y faites |
| --- | --- | --- |
| 1 | [Gérer les comptes](/fr/admin/people/accounts/) | Créez le compte, envoyez le premier mot de passe ou le lien d’invitation, gardez le statut juste. |
| 2 | [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) | Écrivez un rôle : lignes de permission, un niveau, des étiquettes de champ, et les canaux qu’il peut utiliser. |
| 3 | [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) | Mettez des rôles sur les comptes, et comprenez pourquoi un seul rôle agit à la fois. |
| 4 | [Les périmètres de lignes](/fr/admin/people/row-scopes/) | Attachez un périmètre de lignes pour que Sales ne voie que ses propres clients. |
| 5 | [Visibilité des champs par étiquettes](/fr/admin/people/hidden-fields/) | Étiquetez `purchase_price` en `finance` pour que l’entrepôt ne le voie jamais. |
| 6 | [Qui peut changer les rôles](/fr/admin/people/who-can-change-roles/) | Le garde-fou qui empêche un éditeur de se promouvoir au rang d’administrateur. |
| 7 | [Imposer le MFA](/fr/admin/people/mfa/) | Demandez un second facteur à la connexion, et récupérez un authentificateur perdu. |
| 8 | [Le SSO avec OIDC](/fr/admin/people/sso/) | Connectez les personnes via votre fournisseur d’identité, ou uniquement par lui. |
| 9 | [Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/) | Les tokens, les listes de sessions, et ce qui se passe après dix mots de passe faux. |

Deux autres pages se trouvent hors de cette section, mais répondent aussi aux
questions sur les personnes : les apps et leurs clés d’API. Quand un
programme — et non une personne — a besoin d’un accès, lisez
[Contrôler ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/)
et [Clés d’API](/fr/admin/apps-access/api-keys/).

## Une règle pratique

Donnez à une personne le rôle le plus étroit qui lui permette de travailler.
Un périmètre de lignes restreint *quels* documents elle atteint. Une
étiquette de champ restreint *quelles colonnes* elle voit. Les deux se
cumulent : Tom, commercial, voit cinq sociétés, et à l’intérieur d’un article
il ne voit aucun prix d’achat. Commencez étroit, observez la personne
travailler, puis élargissez.

## Voir aussi

- [Administrer](/fr/admin/) — toute la section admin, un niveau au-dessus.
- [Comment Facet vérifie les permissions](/fr/admin/under-the-hood/how-access-is-enforced/) —
  la vue détaillée de chaque contrôle que cette section configure.
- [Apps, attributions et rôles](/fr/build/apps/connect/what-an-app-can-do/) —
  le même modèle pour des programmes au lieu de personnes.
