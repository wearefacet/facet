---
type: how-to
title: Realtime with WebSockets
description: Subscribe to document and collection changes over one WebSocket.
audience: [developer]
features: [DOC-12]
sidebar:
  order: 3
verified_at: a77c6171
---

One WebSocket carries every change your app watches. You subscribe to one
document or to a whole collection, and Facet pushes a small frame for each
mutation. Frames are hints, not state: re-fetch what you subscribe to over
the REST API — see [Use the REST API](/build/apps/data/rest-api/).

> **For agents:** Dial `wss://<host>/Ws` with subprotocols
> `["facet-ws-v1", <app JWT>]`. Subscribe with `{"action": "subscribe",
> "args": ["/crm/Company/<id>"]}`; a two-segment path is the whole
> collection. Frames carry `{channel, event, payload.id, headers}`; match
> `channel` by prefix (the event name is appended) and re-fetch on every
> frame — there is no replay. Close codes: `4401` invalid token, `4403`
> origin not registered.

## When to use this

Use the socket when:

- You render a document or a list that other people change at the same time.
- You want a cheap change feed: frames carry ids, never content.
- You must react to a named action, for example `closed` on a deal.

## Before you start

- An allowed origin. Facet allows its own host plus every origin registered
  on an active app — see [CORS and allowed origins](/build/apps/connect/cors/).
  An origin registered nowhere closes with `4403`.
- A credential the handshake can carry: an app JWT on the subprotocol list,
  or a static `fct_` key on the `Authorization` header only.
- The paths to watch: one document, a nested child, or a whole collection.

## Steps

### 1. Open the socket with the credential

The endpoint is `wss://<host>/Ws`. A browser cannot set an `Authorization`
header on an upgrade, so the token rides the subprotocol list:

```js
const ws = new WebSocket("wss://facet.company.tld/Ws", ["facet-ws-v1", accessToken]);
```

Facet answers `101` and echoes `facet-ws-v1`. Three transports exist:

| Transport | Credential | Notes |
| --- | --- | --- |
| Subprotocol list | App JWT (`typ: "app"`) | The browser route. Static `fct_` keys answer `4401` here. |
| `Authorization` header | Bearer or DPoP scheme | For header-capable clients. The SDK takes an injected WebSocket constructor for it. |
| Session cookie | Browser session | Facet's own frontend. The cookie does not travel cross-site. |

A DPoP-bound token cannot present its proof on the subprotocol transport;
that handshake fails closed with `4401`. See [DPoP token
binding](/build/apps/connect/dpop/). Two close codes end the socket: `4401` for a missing
or invalid token, and `4403` for a disallowed `Origin`.

### 2. Subscribe to a path

Send a JSON frame:

```json
{"action": "subscribe", "args": ["/crm/Company/crm.Company.abc", "/crm/Company"]}
```

| Path | Subscription |
| --- | --- |
| `/crm/Company` | The whole collection. |
| `/crm/Company/crm.Company.abc` | One document. |
| `/crm/Company/crm.Company.abc/contacts/crm.Contact.def` | One nested child document. |
| `/notifications` | The caller's own notification feed. Refused to app-scoped principals. |

A path that ends on a relationship name, for example
`/crm/Company/crm.Company.abc/contacts`, names a list of children. The server rejects it.

The server sends no subscribe acknowledgement. A denial answers an in-band
error frame with a non-disclosing message; the socket stays open.

### 3. Receive frames

A frame looks like this:

```json
{
  "channel": "fanout:crm.Company:crm.Company.abc:updated",
  "event": "updated",
  "payload": { "id": "crm.Company.abc" },
  "headers": { "mutation_id": "01JARQ5G7X9K2M3N4P5Q6R7S8T", "actioner_id": "account_1", "domain": "crm", "doc_type": "Company" }
}
```

`payload` carries the document id only, never content. `headers` names the
mutation, the actor, and the doctype. On a collection subscription the
channel carries no document id: `fanout:crm.Company:created`.

Match frames to subscriptions by channel **prefix**, never by equality.
The server appends the event name to the channel.

| Event | Meaning |
| --- | --- |
| `created`, `updated`, `deleted` | A mutation of the named document. |
| A named action, for example `closed` | The doctype's action ran. |
| `child_changed` | A child of the named parent changed. `payload.id` names the parent, never the child. The child pointer sits in `payload.child`. |

### 4. Refresh on frames

On `created`, `updated`, or `deleted`, re-fetch the document or the list.
On `child_changed`, re-fetch the parent. After a reconnect, re-fetch the
full list: the server delivers no replay.

:::caution[Frames are hints]
The server keeps nothing across a drop. Store no state from frames.
Re-fetch what you subscribe to before you act on it.
:::

### 5. Unsubscribe

Send the path, or `*` to drop every subscription on the socket:

```json
{"action": "unsubscribe", "args": ["/crm/Company/crm.Company.abc"]}
{"action": "unsubscribe", "args": ["*"]}
```

Closing the socket also removes every subscription.

## Example

This browser script opens the socket, subscribes to one document and its
collection, and re-fetches on each frame:

```js
// Run on a registered origin. accessToken comes from your OAuth sign-in —
// see /build/apps/connect/user-login/.
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
  // Match by channel prefix: the event name is appended to the channel.
  if (frame.channel.startsWith(`fanout:crm.Company:${DOC_ID}:`)) {
    // child_changed rides the parent's channel; payload.id names the parent.
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

## Behaviour notes

- **A denial is an error frame, not a close.** A `subscribe` your credential
  cannot read answers an in-band error frame. The socket stays open.
- **Collection subscriptions re-check per emit.** A role revocation applies
  on the next mutation. A new grant needs a reconnect.
- **The captured credential lives as long as the socket.** A grant change
  applies on reconnect, not mid-socket.
- **`/notifications` is the account's own feed.** The server refuses it to
  app-scoped principals with an error frame.
- **Caps.** A connection drops and closes when its 64-message mailbox
  overflows. A collection takes 32 subscribers per doctype by default
  (`websocket.collection.max_subscribers_per_doctype`); an over-cap
  subscribe answers an error frame, and the socket stays open.

  **The SDK route.** `facet.realtime()` opens the same transport and adds
  reconnect with backoff and resubscribe — see [The TypeScript
  SDK](/build/apps/data/sdk/).

## Troubleshooting

**The socket closes with `4403` on connect.**

The origin is not registered on an active app. Register it — see [CORS and
allowed origins](/build/apps/connect/cors/).

**The socket closes with `4401`.**

The token is missing, expired, or of a type the transport refuses. Reconnect
with a fresh app JWT.

**Frames stop after a grant change.**

The captured grant lives as long as the socket. Reconnect to pick up the new grant.

**Nothing arrives after a drop.**

The server delivers no replay. Reconnect, then re-fetch the full list.

**The SDK `subscribe()` promise never settles.**

It settles on the first attributable message: a data frame resolves it, an
error frame rejects it. On a quiet channel it stays pending. Do not await
it when that matters.

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the re-fetch side of the contract.
- [The TypeScript SDK](/build/apps/data/sdk/) — `facet.realtime()` adds reconnect and resubscribe.
- [CORS and allowed origins](/build/apps/connect/cors/) — the origin allowlist the handshake checks.
- [DPoP token binding](/build/apps/connect/dpop/) — why a bound token needs the header transport.
- Internals on GitHub:
  [websocket.md](https://github.com/wearefacet/facet/blob/main/doc/backend/websocket.md).
