---
type: how-to
title: Allowed origins and CORS
description: Register the origins a browser app may call from, and see how Facet mirrors them.
audience: [developer]
features: [APP-08]
sidebar:
  order: 3
verified_at: eee55a2
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

- An app registration exists — see [Register an
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
curl -sk -c cookies.txt -X POST https://facet.localhost:3443/Api/iam/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "ravi@brightwater.example", "password": "brightwater-ravi"}'
```

Then set the origin list:

```sh
curl -sk -b cookies.txt -X PATCH \
  https://facet.localhost:3443/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"allowed_origins": ["https://checkout.brightwater.example", "http://localhost:5173"]}'
```

The patch answers `200` with the stored document; `allowed_origins` reads
back the new list, live on the next request.

### 3. Verify with a preflight

Send a preflight request and check the echoed header. The check-out app is
registered with the dev origin `http://localhost:5173`:

```sh
curl -sk -i -X OPTIONS https://facet.localhost:3443/Api/rentals/Booking \
  -H "Origin: http://localhost:5173" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: Authorization, DPoP"
```

A registered origin answers `204` with its own address echoed back:

```text
HTTP/2 204
access-control-allow-credentials: true
access-control-allow-headers: Authorization, Content-Type, X-Requested-With, DPoP
access-control-allow-methods: GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS
access-control-allow-origin: http://localhost:5173
access-control-max-age: 600
vary: Origin
```

An unregistered origin answers the same `204` — but with no
`access-control-allow-origin` line:

```text
HTTP/2 204
access-control-allow-headers: Authorization, Content-Type, X-Requested-With, DPoP
access-control-allow-methods: GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS
access-control-max-age: 600
vary: Origin
```

The preflight "succeeds", and the browser still blocks the real call:
without the echoed origin there is no permission to send it. The same check
works on the token endpoint at `/OAuth/token`.

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
that is registered nowhere closes with `4403` — see
[Live updates](/build/apps/data/realtime/).

### What CORS does not cover

Facet serves an app build at the app's own host. That is host dispatch, not
CORS — see [Deploy your app on Facet](/build/apps/host/deploy/). Non-browser
clients send no `Origin` header, so CORS never involves them.

## Example

With the origin registered, a browser app on `http://localhost:5173` reads
bookings after the sign-in:

```ts
// The app holds an access token from the OAuth sign-in (see /build/apps/connect/user-login/).
const res = await fetch("https://facet.localhost:3443/Api/rentals/Booking?items=5", {
  headers: { Authorization: `Bearer ${accessToken}` },
});
if (!res.ok) throw new Error(`List failed: ${res.status}`);
const page = await res.json();
```

The browser runs the call only because the origin is registered. A
DPoP-bound token (Demonstrating Proof of Possession) adds the `DPoP`
scheme and a proof header — see
[Bind tokens to your app (DPoP)](/build/apps/connect/dpop/).

## Troubleshooting

**The fetch answers without `Access-Control-Allow-Origin`.**

The origin is not registered, or the only app that holds it is not
`active`. Register the origin on an active app and resend.

**The client asks Facet for the `*` header.**

Facet never sends `*`. Register the exact origin the app runs on.

**The WebSocket closes with `4403`.**

The origin is not in the allowlist. Register it on an active app — see
[Live updates](/build/apps/data/realtime/).

## Related

- [Register an app](/build/apps/connect/register/) — where the origins live.
- [Sign users in](/build/apps/connect/user-login/) — the flow the origins
  allow.
- [Live updates](/build/apps/data/realtime/) — the `/Ws` origin check.
- Internals on GitHub:
  [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
