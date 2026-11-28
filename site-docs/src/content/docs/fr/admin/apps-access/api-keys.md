---
title: Clés d’API
description: Créez des clés d’API pour vos machines, épinglez chacune à un compte et à un rôle, et sachez exactement quand une clé cesse de fonctionner.
type: how-to
audience: [admin, developer]
features: [IAM-09]
verified_at: eee55a2
sidebar:
  order: 1
---

Le rapport des réservations de Brightwater tourne chaque nuit sur un
exécuteur de jobs. Cet exécuteur est une machine : il ne peut ni taper un
mot de passe ni répondre à une invite MFA. Ravi lui donne une **clé d’API** :
un token bearer statique, épinglé à un compte et à un rôle, fixés à la
création. Chaque requête revérifie toute la chaîne, si bien qu’une clé meurt
à son prochain usage dès qu’une de ses conditions change.

## Quand l’utiliser

- Un script, un exécuteur de jobs ou une intégration doit appeler l’API.
- Vous devez révoquer un accès machine vite et de façon vérifiable.
- Vous voulez identifier en audit quelle clé a écrit ce changement.

## Avant de commencer

- **Le rôle.** Le rôle que vous épinglez doit vous être affecté, et sa
  `connectivity` doit porter le canal `api`. Voir
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).
- **Le compte.** Facet destine les comptes de service à porter des clés. Un
  compte de service ne peut pas se connecter par mot de passe ; une clé est
  donc sa seule porte. Voir [Gérer les comptes](/fr/admin/people/accounts/).

## Étapes

### 1. Créer la clé

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-pipeline", "role": "iam.Roles.editor"}' \
  "$(facet-cli host)/Api/iam/keys"
```

Le corps porte :

| Champ | Règle |
| --- | --- |
| `name` | Obligatoire, 100 caractères au plus. |
| `role` | Obligatoire, l’id de rôle qualifié, par exemple `iam.Roles.editor`. |
| `expires_at` | Facultatif, une date ISO-8601 future. Facet la normalise en UTC. |

La réponse montre la clé brute exactement une fois :

```json
{
  "id": "06H1G3VT6CC3J5WVRTEBGGWYQ5",
  "key": "fct_6VBSG6PYWQDNFV3P7HQKXST2E9R",
  "display_prefix": "fct_6VBSG6",
  "expires_at": null
}
```

`key` est le token brut : `fct_` suivi de 26 caractères, 30 avec le
préfixe. Copiez-le maintenant. Le stockage ne garde que son hachage SHA-256
et un préfixe d’affichage ; aucun chemin de lecture ne peut le renvoyer.

Un exécuteur qui détient cette clé exacte l’envoie directement dans
l’en-tête. Un shell dans votre dossier de projet lit la clé depuis
`.facet.local.json` avec `facet-cli apikey` — `facet-cli connect` écrit ce
fichier et émet la clé qu’il contient.

La création répond `422` quand le rôle ne vous est pas affecté, ou quand la
`connectivity` du rôle exclut `api` :

```json
{"error": "The role's connectivity excludes the 'api' channel — enable it on the role first"}
```

### 2. Appeler l’API avec la clé

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/hr/Employee?items=5"
```

Les requêtes tournent avec le compte épinglé et le rôle épinglé. Les lignes
de permission de ce rôle décident de ce que le client peut atteindre. Facet
les revérifie à chaque requête.

### 3. Lister vos clés

```sh
curl -k -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/iam/keys"
```

La liste montre `id`, `name`, `display_prefix`, `role_id`, `created_at`,
`expires_at`, `last_used_at` et `revoked_at`. Elle ne montre jamais le
secret :

```json
{
  "id": "06H1G3VT6CC3J5WVRTEBGGWYQ5",
  "name": "wp18a probe key",
  "display_prefix": "fct_6VBSG6",
  "role_id": "iam.Roles.wp18a_tester",
  "created_at": "2026-11-26T13:33:17Z",
  "expires_at": null,
  "last_used_at": "2026-11-26T13:33:21Z",
  "revoked_at": null
}
```

### 4. Révoquer une clé

```sh
curl -k -X DELETE -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "X-Requested-With: XMLHttpRequest" \
  "$(facet-cli host)/Api/iam/keys/06H1G3VT6CC3J5WVRTEBGGWYQ5"
```

La révocation répond `{"ok": true}` ; c’est une suppression logique,
idempotente. Un delete répété répond toujours `200`. Un id de clé inconnu
ou qui n’est pas le vôtre répond un `404` nu qui ne dit pas lequel. L’appel
suivant avec la clé révoquée répond `401 {"error": "Authentication required"}`.

## Explication

### Ce que Facet vérifie à chaque requête

| Vérification | Échec quand |
| --- | --- |
| Pas révoquée | Vous avez révoqué la clé. |
| Pas expirée | L’heure `expires_at` est passée. |
| Compte vivant et `active` | Le compte est supprimé, `suspended` ou `disabled`. |
| Rôle toujours affecté | Le rôle a été retiré du compte. |
| Projection du rôle présente | Le document du rôle a disparu. |
| La `connectivity` du rôle porte `api` | Le canal a été retiré du rôle. |

Chaque échec répond le même `401` nu, sans dire quelle vérification a
échoué. L’effet : révoquer une clé, désaffecter son rôle, désactiver son
compte ou retirer le canal `api` tue la clé à son prochain usage.

`last_used_at` se met à jour au plus une fois par minute et par clé. Un
client automatisé ne transforme pas chaque requête en écriture en base.

### L’attribution dans la piste d’audit

Chaque changement écrit par une clé porte l’id de ligne de la clé dans la
colonne `api_key` du journal des mutations. Une vue d’audit peut le joindre
au nom de la clé et à son préfixe d’affichage, et dire quelle clé a écrit
ce changement. Le cycle de vie écrit aussi deux événements dans le journal
des connexions : `api_key_created` et `api_key_revoked`. Voir
[Voir qui a fait quoi](/fr/admin/history/audit/).

### Les clés possédées par une app

Une ligne de clé peut porter un `app_id`. Facet émet de telles clés pour
les apps backend. La vérification ajoute un garde-fou — l’app doit être
vivante et active — et la requête tourne en même temps avec l’attribution
de l’app et le rôle épinglé ; la portée effective est donc l’intersection.
Voir [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/)
pour le modèle d’attribution.

## Dépannage

### La clé répond `401`

Parcourez le tableau de vérifications ci-dessus. Le `401` nu ne nomme pas
la cause, par conception.

1. Vérifiez d’abord la route de liste : `revoked_at` et `expires_at` sont
   les cas courants.
2. Vérifiez ensuite le statut du compte et l’affectation du rôle.

### La création répond `422` à propos du canal `api`

Le message le nomme directement :

```json
{"error": "The role's connectivity excludes the 'api' channel — enable it on the role first"}
```

Activez le canal `api` sur l’onglet Détails du rôle, ou épinglez un rôle
qui le porte déjà. Le rôle doit aussi vous être affecté.

### La clé fonctionne, mais le client voit moins que prévu

Le rôle épinglé décide. Vérifiez ses lignes de permission, et vérifiez si
des périmètres de lignes resserrent les listes. Voir
[Les périmètres de lignes](/fr/admin/people/row-scopes/).

### `last_used_at` n’a pas changé après un appel

L’horodatage se met à jour au plus une fois par minute. Attendez, puis
revérifiez.

## Voir aussi

- [Paramètres, sessions et clés API](/fr/use/account/) — la surface des
  clés en libre-service.
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) —
  les canaux de `connectivity`.
- [Gérer les comptes](/fr/admin/people/accounts/) — les comptes de service,
  les porteurs prévus.
- [Ce que les apps peuvent atteindre](/fr/admin/apps-access/app-grants/) —
  le côté attribution des clés possédées par une app.
- [Voir qui a fait quoi](/fr/admin/history/audit/) — l’attribution des clés
  dans les journaux.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) —
  comment une clé se résout à un rôle.
- Internes sur GitHub :
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
- [Sécurité et gouvernance](/fr/discover/security/)
