---
title: Temps réel avec WebSockets
description: Abonnez-vous aux changements de documents et de collections sur un seul WebSocket.
audience: [developer]
features: [DOC-12]
sidebar:
  order: 12
verified_at: a77c6171
---

Un seul WebSocket porte chaque changement que votre app observe. Vous vous
abonnez à un document ou à une collection entière, et Facet pousse une petite
trame à chaque mutation. Les trames sont des indications, pas un état :
rechargez via l’API REST ce à quoi vous vous abonnez — voir
[Utiliser l’API REST](/fr/build/apps/data/rest-api/).

> **Pour les agents :** Ouvrez `wss://<host>/Ws` avec les sous-protocoles
> `["facet-ws-v1", <app JWT>]`. Abonnez-vous avec
> `{"action": "subscribe", "args": ["/crm/Company/<id>"]}` ; un chemin à deux
> segments vise la collection entière. Les trames portent
> `{channel, event, payload.id, headers}` ; reconnaissez le `channel` par
> préfixe (le nom de l’événement est ajouté) et rechargez à chaque trame — il
> n’y a pas de rejeu. Codes de fermeture : `4401` token invalide, `4403`
> origine non enregistrée.

## Quand l’utiliser

Utilisez le socket quand :

- Vous affichez un document ou une liste que d’autres personnes modifient en
  même temps.
- Vous voulez un flux de changements à peu de frais : les trames portent des
  ids, jamais le contenu.
- Vous devez réagir à une action nommée, par exemple `closed` sur un deal.

## Avant de commencer

- Une origine autorisée. Facet autorise son propre hôte plus toute origine
  enregistrée sur une app active — voir
  [CORS et origines autorisées](/fr/build/apps/connect/cors/). Si l’origine n’est
  enregistrée nulle part, le socket se ferme avec `4403`.
- Un identifiant que le handshake peut porter : un JWT d’app dans la liste des
  sous-protocoles, ou une clé statique `fct_` sur l’en-tête `Authorization`
  seulement.
- Les chemins à observer : un document, un enfant imbriqué, ou une collection
  entière.

## Étapes

### 1. Ouvrez le socket avec l’identifiant

L’endpoint est `wss://<host>/Ws`. Un navigateur ne peut pas poser d’en-tête
`Authorization` sur une requête d’upgrade, donc le token voyage dans la liste
des sous-protocoles :

```js
const ws = new WebSocket("wss://facet.company.tld/Ws", ["facet-ws-v1", accessToken]);
```

Facet répond `101` et renvoie `facet-ws-v1` en écho. Trois transports
existent :

| Transport               | Identifiant                | Notes |
| ----------------------- | -------------------------- | ----- |
| Liste de sous-protocoles | JWT d’app (`typ: "app"`)   | La route navigateur. Les clés statiques `fct_` répondent `4401` ici. |
| En-tête `Authorization` | Schéma Bearer ou DPoP      | Pour les clients capables de poser un en-tête. Le SDK accepte pour cela un constructeur WebSocket injecté. |
| Cookie de session       | Session navigateur         | Le frontend de Facet lui-même. Le cookie ne circule pas entre sites. |

Un token lié à DPoP ne peut pas présenter sa preuve sur le transport par
sous-protocoles ; ce handshake se solde par un refus avec `4401`. Voir
[Liaison des tokens par DPoP](/fr/build/apps/connect/dpop/). Deux codes de fermeture mettent
fin au socket : `4401` pour un token absent ou invalide, et `4403` pour une
`Origin` refusée.

### 2. Abonnez-vous à un chemin

Envoyez une trame JSON :

```json
{"action": "subscribe", "args": ["/crm/Company/crm.Company.abc", "/crm/Company"]}
```

| Chemin                                                         | Abonnement |
| -------------------------------------------------------------- | ---------- |
| `/crm/Company`                                                  | La collection entière. |
| `/crm/Company/crm.Company.abc`                                  | Un document. |
| `/crm/Company/crm.Company.abc/contacts/crm.Contact.def`         | Un document enfant imbriqué. |
| `/notifications`                                                | Le flux de notifications de l’appelant lui-même. Refusé aux appelants de portée app. |

Un chemin qui se termine sur un nom de relation, par exemple
`/crm/Company/crm.Company.abc/contacts`, désigne une liste d’enfants. Le
serveur le refuse.

Le serveur n’envoie aucun accusé de réception d’abonnement. Un refus répond
par une trame d’erreur dans le flux, avec un message qui ne divulgue rien ;
le socket reste ouvert.

### 3. Recevez les trames

Une trame ressemble à ceci :

```json
{
  "channel": "fanout:crm.Company:crm.Company.abc:updated",
  "event": "updated",
  "payload": { "id": "crm.Company.abc" },
  "headers": { "mutation_id": "01JARQ5G7X9K2M3N4P5Q6R7S8T", "actioner_id": "account_1", "domain": "crm", "doc_type": "Company" }
}
```

`payload` porte l’id du document seulement, jamais le contenu. `headers` nomme
la mutation, l’acteur et le doctype. Sur un abonnement de collection, le canal
ne porte pas d’id de document : `fanout:crm.Company:created`.

Rattachez les trames aux abonnements par **préfixe** de canal, jamais par
égalité. Le serveur ajoute le nom de l’événement à la fin du canal.

| Événement                              | Signification |
| -------------------------------------- | ------------- |
| `created`, `updated`, `deleted`        | Une mutation du document nommé. |
| Une action nommée, par exemple `closed` | L’action du doctype a été exécutée. |
| `child_changed`                        | Un enfant du parent nommé a changé. `payload.id` désigne le parent, jamais l’enfant. Le pointeur vers l’enfant se trouve dans `payload.child`. |

### 4. Rafraîchissez à chaque trame

Sur `created`, `updated` ou `deleted`, rechargez le document ou la liste. Sur
`child_changed`, rechargez le parent. Après une reconnexion, rechargez la
liste complète : le serveur ne délivre aucun rejeu.

:::caution[Les trames sont des indications]
Le serveur ne conserve rien en cas de coupure. Ne stockez aucun état issu des
trames. Rechargez ce à quoi vous vous abonnez avant d’agir dessus.
:::

### 5. Désabonnez-vous

Envoyez le chemin, ou `*` pour lever tous les abonnements du socket :

```json
{"action": "unsubscribe", "args": ["/crm/Company/crm.Company.abc"]}
{"action": "unsubscribe", "args": ["*"]}
```

Fermer le socket retire aussi tous les abonnements.

## Exemple

Ce script navigateur ouvre le socket, s’abonne à un document et à sa
collection, et recharge à chaque trame :

```js
// À exécuter sur une origine enregistrée. accessToken vient de votre connexion
// OAuth — voir /build/apps/connect/user-login/.
const HOST = "facet.company.tld";
const DOC_ID = "crm.Company.abc";

async function refetch(path) {
  const response = await fetch(`https://${HOST}/Api${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  return response.json();
}

const ws = new WebSocket(`wss://${HOST}/Ws`, ["facet-ws-v1", accessToken]);

ws.addEventListener("open", () => {
  ws.send(JSON.stringify({
    action: "subscribe",
    args: [`/crm/Company/${DOC_ID}`, "/crm/Company"],
  }));
});

ws.addEventListener("message", (event) => {
  const frame = JSON.parse(event.data);
  // Reconnaissez par préfixe de canal : le nom de l’événement est ajouté au canal.
  if (frame.channel.startsWith(`fanout:crm.Company:${DOC_ID}:`)) {
    // child_changed circule sur le canal du parent ; payload.id désigne le parent.
    refetch(`/crm/Company/${frame.payload.id}`);
  } else if (frame.channel.startsWith("fanout:crm.Company:")) {
    refetch("/crm/Company");
  }
});

ws.addEventListener("close", (event) => {
  if (event.code === 4401) console.log("The token is invalid. Sign in again.");
  else if (event.code === 4403) console.log("This origin is not registered.");
  else console.log("Socket dropped. Reconnect, then re-fetch the list.");
});
```

## Notes de comportement

- **Un refus est une trame d’erreur, pas une fermeture.** Un `subscribe` que
  votre identifiant ne peut pas lire répond par une trame d’erreur dans le
  flux. Le socket reste ouvert.
- **Les abonnements de collection revérifient à chaque émission.** Une
  révocation de rôle s’applique à la mutation suivante. Une nouvelle
  attribution exige une reconnexion.
- **L’identifiant capturé vit aussi longtemps que le socket.** Un changement
  d’attribution s’applique à la reconnexion, pas en cours de socket.
- **`/notifications` est le flux propre du compte.** Le serveur le refuse aux
  appelants de portée app par une trame d’erreur.
- **Plafonds.** Une connexion est coupée et se ferme quand sa boîte aux
  lettres de 64 messages déborde. Une collection accepte 32 abonnés par
  doctype par défaut (`websocket.collection.max_subscribers_per_doctype`) ;
  un abonnement au-del à du plafond répond par une trame d’erreur, et le socket
  reste ouvert.

  **La route SDK.** `facet.realtime()` ouvre le même transport et ajoute la
  reconnexion avec backoff et le réabonnement — voir
  [Le SDK TypeScript](/fr/build/apps/data/sdk/).

## Dépannage

**Le socket se ferme avec `4403` à la connexion.**

L’origine n’est pas enregistrée sur une app active. Enregistrez-la — voir
[CORS et origines autorisées](/fr/build/apps/connect/cors/).

**Le socket se ferme avec `4401`.**

Le token est absent, expiré, ou d’un type que le transport refuse.
Reconnectez-vous avec un JWT d’app neuf.

**Les trames s’arrêtent après un changement d’attribution.**

L’attribution capturée vit aussi longtemps que le socket. Reconnectez-vous
pour prendre la nouvelle attribution.

**Plus rien n’arrive après une coupure.**

Le serveur ne délivre aucun rejeu. Reconnectez-vous, puis rechargez la liste
complète.

**La promesse `subscribe()` du SDK ne se conclut jamais.**

Elle se conclut au premier message attribuable : une trame de données la
résout, une trame d’erreur la rejette. Sur un canal silencieux, elle reste en
attente. Ne l’attendez pas quand cela compte.

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — le côté rechargement du contrat.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — `facet.realtime()` ajoute
  reconnexion et réabonnement.
- [CORS et origines autorisées](/fr/build/apps/connect/cors/) — la liste
  d’origines autorisées que le handshake vérifie.
- [Liaison des tokens par DPoP](/fr/build/apps/connect/dpop/) — pourquoi un token lié a
  besoin du transport par en-tête.
- Internes sur GitHub :
  [websocket.md](https://github.com/wearefacet/facet/blob/main/doc/backend/websocket.md).
