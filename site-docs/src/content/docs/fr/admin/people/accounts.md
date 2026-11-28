---
title: Gérer les comptes
description: "Créez un compte, envoyez le premier mot de passe ou le lien d’invitation, pilotez le cycle des statuts, supprimez ou restaurez."
type: how-to
audience: [admin]
features: [IAM-06, IAM-07, FE-11]
verified_at: eee55a2
sidebar:
  order: 1
---

Une nouvelle commerciale arrive lundi. Avant de pouvoir se connecter, elle a
besoin d’un compte, d’un premier identifiant et du bon rôle. Cette page
couvre le compte et l’identifiant. Le rôle est l’affaire de deux autres
pages : [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)
en définit un, et
[Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) le pose
sur le compte.

## Quand l’utiliser

- Vous ajoutez un nouveau membre ou une identité machine.
- Un membre n’a pas de mot de passe, ou l’a oublié avant sa première
  connexion.
- Vous devez empêcher un compte de se connecter, ou ramener un compte
  supprimé.

## Avant de commencer

- **La bonne page.** Ouvrez **Configurer → Accès → Comptes**. Il vous faut un
  rôle qui donne `update` sur `iam.Account` pour créer ou modifier des
  comptes.
- **Le droit sur les identifiants.** Pour envoyer des identifiants, il vous
  faut aussi l’action nommée `provision_credentials` sur `iam.Account`. Le
  rôle `iam.Roles.admin`, créé par l’initialisation, la détient par sa ligne
  `*` sur `*.*`.
- **Le modèle.** Lisez
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/)
  pour comprendre le fonctionnement des actions nommées.

## Le document compte

| Champ                  | Contenu                                                                                     |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| `email`                | L’identifiant de connexion. Unique parmi les comptes vivants.                               |
| `name`                 | Le nom d’affichage.                                                                         |
| `status`               | `pending`, `active`, `suspended` ou `disabled`.                                             |
| `roles`                | Les rôles affectés, sous forme d’ids qualifiés comme `iam.Roles.editor`.                    |
| `default_role`         | Le rôle utilisé à la connexion quand le compte n’en élit aucun.                             |
| `organizational_unit`  | Un chemin en arborescence, par exemple `/engineering/`. Les périmètres de lignes peuvent s’y appuyer. |
| `service_account`      | `true` marque une identité machine qui se connecte par clés d’API, pas par mot de passe.    |
| `mfa_enabled`          | `true` une fois que le compte a terminé la configuration du MFA (authentification multifacteur). |
| `must_change_pw`       | `true` impose un changement de mot de passe à la prochaine connexion.                       |
| `federated_identities` | Les liens SSO, un par fournisseur. Voir [Le SSO avec OIDC](/fr/admin/people/sso/).           |

## Le cycle des statuts

<!-- d2
direction: down
create: "Create human account" {class: external}
pending: pending
active: active {class: ok}
suspended: suspended {class: warn}
disabled: disabled {class: danger}

create -> pending
pending -> active: first sign-in
active -> suspended
active -> disabled
suspended -> disabled
suspended -> active: edit status
disabled -> active: edit status
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c557983b-light.svg" alt="Create human account" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c557983b-dark.svg" alt="Create human account" loading="lazy" />
</div>

Un compte humain que vous créez est stocké en `pending`, même quand vous
soumettez `active`. Le compte achève son amorçage avec son premier
identifiant, et cette première connexion le fait passer en `active`. Deux
exceptions existent : un compte de service est créé `active`, et un compte
provisionné par SSO garde `active`. Un statut `suspended` ou `disabled`
explicite est conservé tel quel.

Un compte `pending` peut se connecter avec son premier identifiant. Un compte
`suspended` ou `disabled` ne peut pas se connecter du tout ; la connexion
répond `403 Account is suspended` (ou `disabled`).

## Étapes

### 1. Créer le compte

1. Ouvrez **Configurer → Accès → Comptes** et sélectionnez **Nouveau
   compte**.
2. Renseignez `email`, `name` et au moins un rôle dans `roles`.
3. Sélectionnez **Enregistrer**.

Facet ouvre la route du formulaire de document standard et enregistre le
compte.

<!-- screenshot: configure-accounts-new -->

### 2. Envoyer le premier identifiant

Ouvrez la page du compte et trouvez les actions d’identifiant sous la vue du
document. Deux routes d’opérateur existent. Toutes deux exigent la permission
`provision_credentials` ; le backend la revérifie à chaque appel.

**Option A — mot de passe temporaire**
(`POST /Api/iam/accounts/:id/temporary-password`) :

- Sélectionnez **Générer un mot de passe**. Facet renvoie un mot de passe de
  16 caractères en quatre groupes séparés par des tirets, par exemple
  `K7M4-9XQ2-WBTD-H3PN`.
- Facet affiche le mot de passe une seule fois. Copiez-le et remettez-le à la
  personne par un canal auquel vous faites déjà confiance, par exemple un
  appel téléphonique. Rien ne stocke ni n’envoie le texte en clair.
- La route positionne `must_change_pw` : la première connexion demande un
  nouveau mot de passe avant toute session.
- La route refuse un compte de service et un compte `suspended` ou `disabled`
  avec `422`. Un compte `pending` est accepté.
- La route invalide aussi tout lien d’invitation en attente. Le mot de passe
  remplace le lien ; l’ancien courriel cesse de fonctionner immédiatement.

**Option B — lien d’invitation** (`POST /Api/iam/accounts/:id/invite`) :

- Sélectionnez **Envoyer l’invitation**. Facet fabrique un lien à usage
  unique et l’envoie par courriel à l’adresse du compte.
- Le lien reste valable pendant la fenêtre des liens d’identifiant. La valeur
  par défaut est de 24 heures (`iam.change_password_expiration`).
- La personne ouvre le lien et définit un mot de passe. Facet la connecte.
- Une seconde invitation remplace le premier lien. L’ancien courriel cesse de
  fonctionner immédiatement.
- La route refuse un compte de service avec `422`. Elle accepte tous les
  autres statuts, `suspended` et `disabled` compris, pour qu’un opérateur
  puisse redonner l’accès par l’invitation.
- La différence entre les deux routes est voulue. Un mot de passe temporaire
  est refusé pour un compte `suspended` ou `disabled`, car la personne ne
  peut pas se connecter pour l’utiliser. Une invitation est permise, car la
  personne peut d’abord accepter le lien et définir un mot de passe. Le
  compte doit quand même être `active` pour que la connexion elle-même
  fonctionne.

:::caution
Le mot de passe temporaire et le lien d’invitation sont des identifiants.
Envoyez le mot de passe vous-même ; ne transmettez jamais le corps de la
réponse sur un canal partagé.
:::

### 3. Lire les états des identifiants

Le panneau des identifiants de la page du compte appelle
`GET /Api/iam/accounts/credential-states?id=…` au chargement. La route prend
un ou plusieurs paramètres de requête `id` et répond une entrée par compte,
dans un tableau `states`. C’est une lecture par lots pour les tableaux de
comptes : donnez la liste des ids voulus, et recevez un état pour chacun. La
route exige `provision_credentials` sur `iam.Account`.

Chaque entrée indique :

| Champ            | Signification                                              |
| ---------------- | ---------------------------------------------------------- |
| `has_password`   | Un mot de passe existe.                                    |
| `must_change_pw` | La prochaine connexion impose un changement de mot de passe. |
| `mfa_enabled`    | Le MFA est actif.                                          |
| `invite_pending` | Un lien d’invitation est en cours.                         |
| `federated`      | Le compte porte un lien SSO.                               |

Les libellés d’action suivent cet état : **Envoyer l’invitation** ou
**Renvoyer l’invitation**, **Générer un mot de passe** ou **Régénérer le mot
de passe**.

<!-- screenshot: configure-accounts-credentials -->

### 4. Suspendre ou désactiver un compte

Modifiez le document du compte et mettez `status` à `suspended` ou
`disabled`. La prochaine tentative de connexion répond `403`. Les sessions
existantes continuent de fonctionner jusqu’à l’expiration de leur token
d’accès ; voir
[Sessions, tokens et verrouillages](/fr/admin/people/sessions-lockouts/).

Un compte de service n’a pas de connexion du tout. Il ne peut pas se
connecter par mot de passe, et les demandes de réinitialisation le
concernant sont des no-ops silencieux. Sa raison d’être est de porter des
clés d’API — voir [Clés d’API](/fr/admin/apps-access/api-keys/).

### 5. Supprimer un compte

Supprimer un compte est une suppression de document ordinaire. Sélectionnez
le compte et confirmez la suppression. La ligne devient un tombstone (une
trace de suppression) ; l’historique reste.

Le garde-fou d’autorité des rôles ajoute une règle : vous ne pouvez pas
supprimer un compte dont le niveau de rôle le plus élevé dépasse votre
propre niveau. La suppression répond `403` dans ce cas. Voir
[Qui peut changer les rôles](/fr/admin/people/who-can-change-roles/) pour ce
garde-fou.

### 6. Restaurer un compte supprimé

Ouvrez **Configurer → Accès → Comptes**, basculez vers la liste des
supprimés, et sélectionnez **Restaurer**. La route d’API est :

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" -d '{}' \
  "$(facet-cli host)/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D/restore"
```

Remplacez `01J8Z0A7G3Q5M2X9K4T6VBNR8D` par l’id du compte. L’appel n’a pas
besoin de corps. Les réponses :

| Réponse | Signification                                                     |
| ------- | ----------------------------------------------------------------- |
| `200`   | Le compte est de nouveau vivant, avec son contenu d’avant la suppression. |
| `409`   | Le compte n’est pas supprimé.                                     |
| `404`   | Aucun historique de mutations n’existe pour cet id.               |
| `403`   | Votre rôle n’a pas `update` sur `iam.Account`.                    |
| `422`   | Historique dégénéré : une suppression sans changement avant elle. |

Une restauration ramène aussi les enregistrements enfants que la suppression
avait retirés, quand elle a cascadé. Voir
[Revenir en arrière](/fr/admin/history/roll-back/) pour le mécanisme.

## Le premier administrateur

Un déploiement neuf n’a aucun compte pour se connecter. Créez le premier sur
le serveur :

```sh
facet seed:admin ops@your-company.tld
```

La commande affiche un mot de passe à usage unique, une seule fois.
Connectez-vous avec, et Facet demande un nouveau mot de passe. La commande
refuse de s’exécuter si un compte avec ce courriel existe déjà ; récupérez un
mot de passe perdu par le flux de réinitialisation.

## Dépannage

### Les boutons d’identifiant n’apparaissent pas

Votre rôle n’a pas `provision_credentials` sur `iam.Account`. Demandez à un
administrateur, ou ajoutez la ligne
`{"action": "provision_credentials", "on": "iam.Account"}` à votre rôle.

### Le courriel d’invitation n’arrive jamais

1. Vérifiez le dossier des courriers indésirables.
2. Vérifiez les réglages de courrier de l’instance.
3. Renvoyez l’invitation ; le nouveau lien remplace l’ancien.

### Une connexion par mot de passe répond `403 Account is suspended`

Un administrateur a positionné le statut. Demandez-lui de le ramener à
`active`.

### La restauration répond `409`

Le compte n’est pas supprimé. Une restauration ne fonctionne que sur un
tombstone.

## Voir aussi

- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — les
  actions nommées que cette page utilise.
- [Affecter les rôles et l’élection](/fr/admin/people/assign-roles/) —
  le tableau `roles` et `default_role`.
- [Imposer le MFA](/fr/admin/people/mfa/) — le champ `mfa_enabled` et
  l’action de réinitialisation du MFA.
- [Clés d’API](/fr/admin/apps-access/api-keys/) — comment les comptes de
  service s’authentifient.
- [Le SSO avec OIDC](/fr/admin/people/sso/) — le champ `federated_identities`
  et le provisionnement JIT.
- [Se connecter, MFA, réinitialiser votre mot de passe](/fr/use/first-day/sign-in/) —
  le côté titulaire du compte pour ces flux.
- Internes sur GitHub :
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md),
  [access-accounts.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/access-accounts.md).
- [Personnes et accès](/fr/admin/people/)
