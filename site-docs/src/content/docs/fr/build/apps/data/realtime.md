---
title: Mises à jour en direct
description: Suivez en direct les changements de documents et de collections sur un seul WebSocket.
type: how-to
audience: [developer]
features: [DOC-12, DOC-15]
verified_at: eee55a2
sidebar:
  order: 3
---

Un seul WebSocket porte chaque changement que votre app surveille. Vous vous
abonnez à un document ou à une collection entière, et Facet pousse une
petite trame pour chaque mutation. Les trames sont des indices, pas un
état : rechargez ce à quoi vous êtes abonné via l’API REST — voir
[Utiliser l’API REST](/fr/build/apps/data/rest-api/).

> **Pour les agents :** Ouvrez `wss://<host>/Ws` avec les sous-protocoles
> `["facet-ws-v1", <app JWT>]` (navigateur) ou un en-tête
> `Authorization: Bearer` (Node). Abonnez-vous avec
> `{"action": "subscribe", "args": ["/rentals/Booking"]}` ; un chemin à deux
> segments vise la collection entière. Les trames portent
> `{channel, event, payload.id, headers}` — par exemple
> `{"channel":"fanout:rentals.Booking:updated","event":"updated","payload":{"id":"BK-2026-0001"},…}`.
> Le suffixe du canal est le nom de l’événement, donc rapprochez par préfixe.
> Rechargez à chaque trame — il n’y a pas de rejeu. Codes de fermeture :
> `4401` token invalide, `4403` origine non enregistrée.

## Quand l’utiliser

Utilisez le socket quand :

- Vous affichez un document ou une liste que d’autres personnes modifient en
  même temps.
- Vous voulez un flux de changements léger : les trames portent des ids,
  jamais du contenu.
- Vous devez réagir à une action nommée, par exemple `confirmed` sur une
  réservation.

## Avant de commencer

- Une origine autorisée. Facet autorise son propre hôte plus chaque origine
  enregistrée sur une app active — voir
  [CORS et origines autorisées](/fr/build/apps/connect/cors/). Une origine
  enregistrée nulle part se ferme avec `4403`.
- Un identifiant que la poignée de main peut porter : un app JWT dans la
  liste de sous-protocoles, un token bearer dans l’en-tête `Authorization`,
  ou un cookie de session.
- Les chemins à surveiller : un document, un enfant imbriqué, ou une
  collection entière.

Les vérifications réelles de cette page ont été exécutées sur une instance
de dev à l’adresse `https://facet.localhost:3443` (la connexion au socket
était `ws://127.0.0.1:3000/Ws`) avec les données Brightwater Rentals
chargées.

## Étapes

### 1. Ouvrez le socket avec l’identifiant

Le endpoint est `wss://<host>/Ws`. Un navigateur ne peut pas poser un
en-tête `Authorization` sur une upgrade, donc le token voyage dans la liste
de sous-protocoles :

```js
const ws = new WebSocket("wss://facet.localhost:3443/Ws", ["facet-ws-v1", accessToken]);
```

Facet répond `101` et renvoie `facet-ws-v1`. Trois transports existent :

| Transport | Identifiant | Remarques |
| --- | --- | --- |
| Liste de sous-protocoles | App JWT (`typ: "app"`) | La voie navigateur. Les clés statiques `fct_` répondent `4401` ici. |
| En-tête `Authorization` | Bearer ou schéma DPoP | Pour les clients capables de poser des en-têtes. Le SDK prend un constructeur WebSocket injecté pour cela. |
| Cookie de session | Session navigateur | Le frontend de Facet lui-même. Le cookie ne voyage pas cross-site. |

Un token lié par DPoP ne peut pas présenter sa preuve sur le transport par
sous-protocole ; cette poignée de main échoue et l’accès est refusé avec
`4401`. Voir [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/). Deux
codes de fermeture mettent fin au socket : `4401` pour un token absent ou
invalide, et `4403` pour une `Origin` non autorisée.

### 2. Abonnez-vous à un chemin

Envoyez une trame texte JSON :

```json
{"action": "subscribe", "args": ["/rentals/Booking", "/rentals/Booking/BK-2026-0001"]}
```

| Chemin | Abonnement |
| --- | --- |
| `/rentals/Booking` | La collection entière. |
| `/rentals/Booking/BK-2026-0001` | Un document. |
| `/clients/Company/<id>/contacts/<child id>` | Un document enfant imbriqué. |
| `/notifications` | Le propre flux de notifications de l’appelant. Refusé aux principaux limités à une app. |

La grammaire de chemin porte des ids de document nus —
`/rentals/Booking/BK-2026-0001`, pas la forme qualifiée
`rentals.Booking.BK-2026-0001`. Un chemin qui se termine par un nom de
relation, par exemple `/clients/Company/<id>/contacts`, nomme une liste
d’enfants. Le serveur le refuse.

Le serveur n’envoie aucun accusé de réception d’abonnement. Un refus répond
par une trame d’erreur dans le flux, avec un message qui ne divulgue rien ;
le socket reste ouvert. Les textes d’erreur exacts, issus d’une session
réelle :

```json
{"error": "Path must include at least a domain and a doctype: bogus", "path": "bogus"}
```

```json
{"error": "Unknown action 'bogus_action'"}
```

```json
{"error": "Invalid JSON frame"}
```

### 3. Recevez des trames

Pendant qu’une session était abonnée à `/clients/Company`, cette création
est passée par l’API REST, sous la clé API de Nadia :

```sh
curl -sk -X POST https://facet.localhost:3443/Api/clients/Company \
  -H "Authorization: Bearer $NADIA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{ "name": "WS Test Co", "city": "Lyon" }'
```

Le socket a reçu cette trame :

```json
{
  "channel": "fanout:clients.Company:created",
  "event": "created",
  "payload": { "id": "06H1FRAJS87GCYJA5N8GA32733" },
  "headers": {
    "actioner_id": "06H1FKW9RRQX860BKXRBY3YT8V",
    "domain": "clients",
    "doc_type": "Company",
    "mutation_id": "06H1FRAJS86PJXQ0PAGASAM8QJ",
    "cause": { "kind": "request", "trace": "06H1FRAJS86PJXQ0PAGASAM8QJ" },
    "event": "created"
  }
}
```

`payload` porte l’id du document seulement, jamais le contenu. `headers`
nomme la mutation, l’acteur, et le doctype.

Le canal est la cible de l’abonnement plus le nom de l’événement. Un
abonnement de collection à `/clients/Company` livre des trames sur
`fanout:clients.Company:<event>` ; un abonnement de document à
`/rentals/Booking/BK-2026-0001` livre des trames sur
`fanout:rentals.Booking:BK-2026-0001:<event>`. Rapprochez les trames des
abonnements par **préfixe** de canal, jamais par égalité — le nom de
l’événement se trouve après le dernier deux-points.

| Événement | Signification |
| --- | --- |
| `created`, `updated`, `deleted` | Une mutation du document nommé. |
| Une action nommée, par exemple `confirmed` | L’action du doctype a tourné. |
| `child_changed` | Un enfant du parent nommé a changé. `payload.id` nomme le parent, jamais l’enfant. Le pointeur vers l’enfant se trouve dans `payload.child`. |

### 4. Rafraîchissez à chaque trame

Sur `created`, `updated` ou `deleted`, rechargez le document ou la liste.
Sur `child_changed`, rechargez le parent. Après une reconnexion, rechargez
la liste entière : le serveur ne livre aucun rejeu.

:::caution[Les trames sont des indices]
Le serveur ne garde rien après une coupure. Ne stockez aucun état issu des
trames. Rechargez ce à quoi vous êtes abonné avant d’agir dessus.
:::

### 5. Désabonnez-vous

Envoyez le chemin, ou `*` pour retirer chaque abonnement du socket :

```json
{"action": "unsubscribe", "args": ["/rentals/Booking/BK-2026-0001"]}
{"action": "unsubscribe", "args": ["*"]}
```

La fermeture du socket retire aussi chaque abonnement.

## Exemple

Ce script navigateur ouvre le socket, s’abonne à un document et à sa
collection, et recharge à chaque trame :

```js
// À exécuter sur une origine enregistrée. accessToken vient de votre
// connexion OAuth — voir /build/apps/connect/user-login/.
const HOST = "facet.localhost:3443";
const DOC_ID = "BK-2026-0001";

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
    args: [`/rentals/Booking/${DOC_ID}`, "/rentals/Booking"],
  }));
});

ws.addEventListener("message", (event) => {
  const frame = JSON.parse(event.data);
  // Rapprochez par préfixe de canal : le nom de l’événement est ajouté au canal.
  if (frame.channel.startsWith(`fanout:rentals.Booking:${DOC_ID}:`)) {
    // child_changed voyage sur le canal du parent ; payload.id nomme le parent.
    refetch(`/rentals/Booking/${frame.payload.id}`);
  } else if (frame.channel.startsWith("fanout:rentals.Booking:")) {
    refetch("/rentals/Booking");
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
- **Les abonnements de collection sont revérifiés à chaque émission.** La
  diffusion exécute une vérification de lecture par connexion contre l’état
  courant de la ligne, donc une révocation de rôle s’applique à la mutation
  suivante. Une nouvelle attribution exige une reconnexion.
- **L’identifiant capturé vit autant que le socket.** Un changement
  d’attribution s’applique à la reconnexion, pas en cours de socket.
- **`/notifications` est le propre flux du compte.** Le serveur le refuse
  aux principaux limités à une app par une trame d’erreur.
- **Plafonds.** Une connexion se ferme quand sa boîte de réception de
  64 messages déborde — un client trop lent à vider ses trames. Une
  collection accepte 32 abonnés par doctype par défaut
  (`websocket.collection.max_subscribers_per_doctype`) ; un abonnement
  au-delà du plafond répond une trame d’erreur, et le socket reste ouvert.

  **La voie SDK.** `facet.realtime()` ouvre le même transport et ajoute la
  reconnexion avec backoff et le réabonnement — voir
  [Le SDK TypeScript](/fr/build/apps/data/sdk/).

## Dépannage

**Le socket se ferme avec `4403` à la connexion.**

L’origine n’est pas enregistrée sur une app active. Enregistrez-la — voir
[CORS et origines autorisées](/fr/build/apps/connect/cors/).

**Le socket se ferme avec `4401`.**

Le token est absent, expiré, ou d’un type que le transport refuse.
Reconnectez-vous avec un app JWT frais.

**Les trames cessent après un changement d’attribution.**

L’attribution capturée vit autant que le socket. Reconnectez-vous pour
prendre la nouvelle attribution.

**Rien n’arrive après une coupure.**

Le serveur ne livre aucun rejeu. Reconnectez-vous, puis rechargez la liste
entière.

**La promesse `subscribe()` du SDK ne se résout jamais.**

Elle se résout au premier message attribuable : une trame de données la
résout, une trame d’erreur la rejette. Sur un canal silencieux elle reste en
attente. Ne l’attendez pas quand cela compte.

**Une trame répond `{"error": "Path must include at least a domain and a
doctype: …"}`.**

Le chemin ne porte qu’un segment. Un abonnement exige au moins
`/<domain>/<Doctype>`.

## Voir aussi

- [Utiliser l’API REST](/fr/build/apps/data/rest-api/) — le côté rechargement du
  contrat.
- [Le SDK TypeScript](/fr/build/apps/data/sdk/) — `facet.realtime()` ajoute la
  reconnexion et le réabonnement.
- [CORS et origines autorisées](/fr/build/apps/connect/cors/) — la liste d’origines
  autorisées que la poignée de main vérifie.
- [Liaison DPoP des tokens](/fr/build/apps/connect/dpop/) — pourquoi un token lié a
  besoin du transport par en-tête.
- Internes sur GitHub :
  [websocket.md](https://github.com/wearefacet/facet/blob/main/doc/backend/websocket.md).
