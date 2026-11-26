---
title: "Accès machine : clés d’API"
description: "Créez des clés d’API statiques, épinglez-les à un compte et un rôle, et sachez exactement quand une clé cesse de fonctionner."
audience: [admin, developer]
features: [IAM-09]
sidebar:
  order: 9
verified_at: fd345fe3
---

Une clé d’API (interface de programmation applicative) est un token bearer
statique pour des clients machines. Elle épingle un compte et un rôle,
fixés à la création. Chaque requête revérifie toute la chaîne, si bien
qu’une clé meurt à son prochain usage dès que ses conditions changent.

## Quand l’utiliser

- Un script, un exécuteur de jobs, ou une intégration doit appeler l’API.
- Vous devez révoquer un accès machine vite et de façon vérifiable.
- Vous voulez une réponse d’audit à « quelle clé a écrit ce changement ».

## Avant de commencer

- **Le rôle.** Le rôle que vous épinglez doit vous être affecté, et sa
  `connectivity` doit porter le canal `api`. Voir
  [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/).
- **Le compte.** Facet destine les comptes de service à porter des clés. Un
  compte de service ne peut pas se connecter par mot de passe ; une clé est
  donc sa seule porte. Voir
  [Gérer les comptes](/fr/admin/people/accounts/).

## Étapes

### 1. Créer la clé

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-pipeline", "role": "iam.Roles.editor"}' \
  "https://facet.localhost:3443/Api/iam/keys"
```

Le corps porte :

| Champ         | Règle                                                                    |
| ------------- | -------------------------------------------------------------------------- |
| `name`        | Obligatoire, 100 caractères au plus.                                        |
| `role`        | Obligatoire, l’id de rôle qualifié, par exemple `iam.Roles.editor`.         |
| `expires_at`  | Facultatif, un datetime ISO-8601 futur. Facet le normalise en UTC.          |

La réponse montre la clé brute exactement une fois :

```json
{
  "id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D",
  "key": "fct_PASTE-THIS-VALUE-NOW-IT-WILL-NOT-SHOW-AGAIN",
  "display_prefix": "fct_PASTE6",
  "expires_at": null
}
```

`key` est le token brut : `fct_` suivi de 26 caractères. Copiez-le
maintenant. Le stockage ne garde que son hachage SHA-256 et un préfixe
d’affichage ; aucun chemin de lecture ne peut le renvoyer.

La création répond `422` quand le rôle ne vous est pas affecté ou quand la
`connectivity` du rôle exclut `api`.

### 2. Appeler l’API avec la clé

```sh
export FACET_API_KEY="fct_the-value-from-step-1"
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee?items=5"
```

Les requêtes tournent avec le compte épinglé et le rôle épinglé. Les lignes
de permission de ce rôle décident de ce que le client peut atteindre. Facet
les revérifie à chaque requête.

### 3. Lister vos clés

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/keys"
```

La liste montre `id`, `name`, `display_prefix`, `role_id`, `created_at`,
`expires_at`, `last_used_at` et `revoked_at`. Elle ne montre jamais le
secret.

### 4. Révoquer une clé

```sh
curl -k -X DELETE -H "Authorization: Bearer $FACET_API_KEY" \
  -H "X-Requested-With: XMLHttpRequest" \
  "https://facet.localhost:3443/Api/iam/keys/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

La révocation est un soft delete, idempotente. Une suppression répétée
répond toujours `200`. Un id de clé inconnu ou qui n’est pas le vôtre répond
un `404` nu qui ne dit pas lequel.

## Explication

### Ce que Facet vérifie à chaque requête

| Vérification                            | Échec quand                                        |
| ---------------------------------------- | ---------------------------------------------------- |
| Pas révoquée                             | Vous avez révoqué la clé.                             |
| Pas expirée                              | L’heure `expires_at` est passée.                      |
| Compte vivant et `active`                | Le compte est supprimé, `suspended` ou `disabled`.    |
| Rôle toujours affecté                    | Le rôle a été retiré du compte.                       |
| Projection du rôle présente              | Le document du rôle a disparu.                        |
| La `connectivity` du rôle porte `api`    | Le canal a été retiré du rôle.                        |

Chaque échec répond le même `401` nu. Il ne dit pas quelle vérification a
échoué. L’effet : révoquer une clé, désaffecter son rôle, désactiver son
compte, ou retirer le canal `api` tue la clé à son prochain usage.

`last_used_at` se met à jour au plus une fois par minute par clé. Un client
automatisé ne transforme pas chaque requête en écriture de base de données.

### L’attribution dans la piste d’audit

Chaque mutation écrite par une clé porte l’id de ligne de la clé dans la
colonne `api_key` du journal des mutations. Une vue d’audit peut la joindre
au nom de la clé et à son préfixe d’affichage, et répondre à « quelle clé a
écrit ce changement ». Le cycle de vie écrit aussi deux événements dans le
journal des connexions : `api_key_created` et `api_key_revoked`. Voir
[Auditer l’activité](/fr/admin/history/audit/).

### Les clés possédées par une app

Une ligne de clé peut porter un `app_id`. Facet émet de telles clés pour des
apps backend. La vérification ajoute une barrière — l’app doit être vivante
et active — et la requête tourne avec l’attribution de l’app et le rôle
épinglé en même temps, si bien que la portée effective est l’intersection.
Voir [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/) pour le
modèle d’attribution.

## Dépannage

### La clé répond `401`

Parcourez le tableau de vérifications ci-dessus. Le `401` nu ne nomme pas
la cause, par conception.

1. Vérifiez d’abord la route de liste : `revoked_at` et `expires_at` sont
   les cas courants.
2. Puis vérifiez le statut du compte et l’affectation du rôle.

### La création répond `422` à propos du canal `api`

Par exemple : `422 The role's connectivity excludes the 'api' channel.`

Activez le canal `api` sur l’onglet Détails du rôle, ou épinglez un rôle
qui le porte déjà. Le rôle doit aussi vous être affecté.

### La clé fonctionne, mais le client voit moins que prévu

Le rôle épinglé décide. Vérifiez ses lignes de permission, et vérifiez si
des périmètres de lignes resserrent les listes. Voir
[Les périmètres de lignes](/fr/admin/people/row-scopes/).

### `last_used_at` n’a pas changé après un appel

L’horodatage se met à jour au plus une fois par minute. Attendez puis
revérifiez.

## Voir aussi

- [Vos paramètres, sessions et clés d’API](/fr/use/account/) —
  la surface des clés en libre-service.
- [Rôles et lignes de permission](/fr/admin/people/roles-and-permissions/) — les
  canaux de `connectivity`.
- [Gérer les comptes](/fr/admin/people/accounts/) — les comptes de
  service, les porteurs prévus.
- [La portée des apps (attributions)](/fr/admin/apps-access/app-grants/) — le côté
  attribution des clés possédées par une app.
- [Auditer l’activité](/fr/admin/history/audit/) — l’attribution des
  clés dans les journaux.
- [Contextes d’authentification](/fr/admin/under-the-hood/one-role-at-a-time/) — comment une
  clé se résout à un rôle.
- Internes sur GitHub :
  [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
