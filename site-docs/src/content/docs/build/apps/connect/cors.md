---
type: how-to
title: CORS and allowed origins
description: Register the origins a browser app may call from, and see how Facet mirrors them.
audience: [developer]
features: [APP-08]
sidebar:
  order: 3
verified_at: a77c6171
---

A browser app calls Facet from its own origin. The browser blocks the call
unless Facet names that origin in its Cross-Origin Resource Sharing (CORS)
headers. You register the origins on the app document, and Facet mirrors
them on the token endpoint and the whole `/Api/*` surface. The allowlist is
live: an origin edit applies on the next request.

> **For agents:** Put bare origins in `allowed_origins` on `app.App` — for
> example `https://app.company.tld` and dev origins such as
> `http://localhost:5173`. Edit with `PATCH /Api/app/App/{id}` (session
> cookie plus `X-Requested-With: XMLHttpRequest`). Verify with
> `curl -X OPTIONS` sending `Origin`, `Access-Control-Request-Method`, and
> `Access-Control-Request-Headers: Authorization, DPoP`; a registered origin
> gets `Access-Control-Allow-Origin` echoed back. The change is live on the
> next request — no restart.

## When to use this

Come here when:

- A browser `fetch` fails because the response carries no CORS header.
- You deploy the app on a new host and must add its origin.
- You add a dev origin, or a WebSocket refuses to open.

## Before you start

- An app registration exists — see [Registering an
  app](/build/apps/connect/register/).
- You need `update` rights on `app.App` to edit the origins.
- List every origin the browser app is served from, including dev origins.

## Steps

### 1. List the origins

Each entry is a bare origin: scheme, host, and optional port. Register every
origin the browser app is served from. Include the production hosts and the
dev hosts, for example `http://localhost:5173`.

### 2. Set them on the app

The wizard setup step collects the origins at registration. To change them
later, PATCH the app document. Sign in as an operator and keep the session
cookies:

```sh
curl -s -c cookies.txt -X POST https://facet.company.tld/Api/iam/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "admin@company.tld", "password": "op-secret"}'
```

Then set the origin list:

```sh
curl -s -b cookies.txt -X PATCH \
  https://facet.company.tld/Api/app/App/01JHQ9M4T8C3XK2PB5WY6RD7QF \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"allowed_origins": ["https://deal-board.company.tld", "http://localhost:5173"]}'
```

### 3. Verify with a preflight

Send a preflight request and check the echoed header:

```sh
curl -s -i -X OPTIONS https://facet.company.tld/Api/crm/Company \
  -H "Origin: https://deal-board.company.tld" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization, DPoP" \
  | grep -i access-control-allow-origin
```

A registered origin answers with its own address:

```sh
Access-Control-Allow-Origin: https://deal-board.company.tld
```

An unregistered origin answers without the header. The same check works on
the token endpoint at `/OAuth/token`.

## Explanation

### Where Facet mirrors origins

The CORS handler mirrors registered origins on `/OAuth/*` and `/Api/*`, for
preflight and actual responses. It runs before the auth check in the handler
chain, so a preflight needs no credentials. Facet echoes the request
`Origin` only when it appears in `allowed_origins` of at least one `active`
app.

### Exact match, never a wildcard

Facet never sends `Access-Control-Allow-Origin: *`. Browsers ignore the `*`
form when `Authorization` sits in `Access-Control-Allow-Headers`, so a
wildcard would protect nothing. Register each exact origin instead.

### The allowlist is live

The origin cache marks itself stale on every `app.App` mutation and rebuilds
on the next read. An origin edit applies on the next request. No restart and
no backend config change.

### WebSockets use the same set

The `/Ws` upgrade checks the same registered origins, plus Facet's own host.
A deployed app's origin can open a socket with no backend config. An origin
that is registered nowhere closes with `4403` — see [Realtime with
WebSockets](/build/apps/data/realtime/).

### What CORS does not cover

Facet serves an app build at the app's own host. That is host dispatch, not
CORS — see [Deploy your frontend](/build/apps/host/deploy/). Non-browser
clients send no `Origin` header, so CORS never involves them.

## Example

With the origin registered, a browser app on `https://deal-board.company.tld`
reads companies after the sign-in:

```ts
// The app holds an access token from the OAuth sign-in (see /build/apps/connect/user-login/).
const res = await fetch("https://facet.company.tld/Api/crm/Company?per_page=5", {
  headers: { Authorization: `Bearer ${accessToken}` },
});
if (!res.ok) throw new Error(`List failed: ${res.status}`);
const page = await res.json();
```

A DPoP-bound token (Demonstrating Proof of Possession) adds the `DPoP`
scheme and a proof header — see [DPoP
token binding](/build/apps/connect/dpop/). The browser runs the call only because the
origin is registered.

## Troubleshooting

**The fetch answers without `Access-Control-Allow-Origin`.**

The origin is not registered, or the only app that holds it is not
`active`. Register the origin on an active app and resend.

**The client asks Facet for the `*` header.**

Facet never sends `*`. Register the exact origin the app runs on.

**The WebSocket closes with `4403`.**

The origin is not in the allowlist. Register it on an active app — see
[Realtime with WebSockets](/build/apps/data/realtime/).

## Related

- [Registering an app](/build/apps/connect/register/) — where the origins live.
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the flow the origins
  unlock.
- [Realtime with WebSockets](/build/apps/data/realtime/) — the `/Ws` origin check.
- Internals on GitHub:
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
