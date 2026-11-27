---
type: how-to
title: Quickstart
description: Register a small app, sign a user in with PKCE, and make the first API call — in about fifteen minutes.
audience: [developer]
features: [APP-01, APP-02, APP-09]
sidebar:
  order: 2
verified_at: eee55a2
---

Brightwater's warehouse wants a small web app: today's bookings, with a
button to mark items out and back in. This page takes that app from nothing
to its first successful API call. You register the app, activate it, sign a
user in, and read real data — every response below comes from a live
 Brightwater instance.

> **For agents:** the whole path is four calls: `POST /Api/app/App` (an API key
> in `Authorization: Bearer` — `facet-cli apikey` prints the stored one — or a
> session cookie plus `X-Requested-With: XMLHttpRequest`) → `PATCH …/App/{id}` with
> `{"status": "active"}` → `GET /OAuth/authorize` + `POST /OAuth/authorize`
> with `role`, then `POST /OAuth/token` with the PKCE `code_verifier` →
> `GET /Api/<domain>/<Doctype>` with `Authorization: Bearer <access_token>`.
> The create answers `201` and the hook-written `client_id`. A wildcard
> grant target answers `422 wildcard_target`.

## When to use this

Use this page when you want a working app in front of you fast, and the
details can wait. It is the browser-app path. A backend service starts at
[Backend apps and service accounts](/build/apps/connect/backend-apps/); an
AI agent at [Connect agents over MCP](/build/apps/agents/mcp/).

## Before you start

- A running Facet instance and an account that holds `update` on `app.App`.
  The seeded `admin` role holds it. On the Brightwater example, sign in as
  Ravi Menon (`ravi@brightwater.example`).
- `curl` (or any HTTP client) and `pnpx @facetapp/cli` for the walkthrough.
  The app itself makes the same calls from its own code — see the complete
  browser client in [Sign users in](/build/apps/connect/user-login/).

## Steps

### 1. Register the app

Every API call presents its own credential, and the CLI issues one pinned to a
role you hold. From your project folder, sign in once through the browser
(elect the admin role on the consent screen):

```sh
pnpx @facetapp/cli connect
```

The command signs you in (the same OAuth flow as `login`), asks whether to
store an API key, and writes the key to `.facet.local.json`. It needs a
`facet.config.json` for the target — `init` writes one, or `connect` asks for
the URL once. Keep the key and the URL in variables:

```sh
RAVI_KEY=$(pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

Then create the app document. The grants name concrete doctypes — a
wildcard target is refused:

```sh
curl -sk -X POST "$HOST/Api/app/App" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "brw-checkout",
    "name": "Brightwater Check-out",
    "client_type": "public",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "grants": [
      {
        "target": "rentals.Booking",
        "actions": [{ "name": "read", "required": true }]
      },
      {
        "target": "rentals.BookingLine",
        "actions": [{ "name": "read", "required": true }]
      },
      {
        "target": "equipment.Item",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  }'
```

The create answers `201`. The hook has already written the read-only
`client_id`:

```json
{
  "data": {
    "slug": "brw-checkout",
    "name": "Brightwater Check-out",
    "client_type": "public",
    "status": "draft",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "grants": [
      { "target": "rentals.Booking", "actions": [{ "name": "read", "required": true }] },
      { "target": "rentals.BookingLine", "actions": [{ "name": "read", "required": true }] },
      { "target": "equipment.Item", "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }] }
    ]
  },
  "meta": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "uri": "urn:facet:app:App:06H1FQF7NGDJJKSNHXPYT6627M",
    "domain": "app",
    "doc_type": "App",
    "created_at": "2026-11-26T12:39:08Z",
    "updated_at": "2026-11-26T12:39:08Z"
  }
}
```

### 2. Activate the app

A new app is a `draft`. Sign-ins and keys work only when the status is
`active`:

```sh
curl -sk -X PATCH \
  "$HOST/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}'
```

The patch answers `200` with the stored document; `status` reads back
`"active"`.

### 3. Sign a user in

The browser flow sends the user to the consent screen and returns a code.
Build a PKCE pair first:

```sh
openssl rand -base64 48 | tr '+/' '-_' | tr -d '='
# YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F  <- code_verifier

printf '%s' 'YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
# JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc  <- code_challenge
```

In the running app the browser does the next two hops. From a terminal,
ask the authorize endpoint what the consent screen would show:

```sh
curl -sk -H "Authorization: Bearer $RAVI_KEY" \
  "$HOST/OAuth/authorize?response_type=code&client_id=06H1FQF7NG357EQ0P348Z2BEV5&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback&code_challenge=JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc&code_challenge_method=S256&state=winter-fair-43' \
  -H 'Accept: application/json'
```

The answer describes the app and lists the roles the account may elect,
with the reach each role would leave the app:

```json
{
  "app": {
    "slug": "brw-checkout",
    "display_name": "Brightwater Check-out",
    "status": "active"
  },
  "roles": [
    {
      "role_id": "iam.Roles.admin",
      "display_name": "Full administrative access to all resources.",
      "effective_scope": [
        { "target": "rentals.Booking", "actions": ["read"] },
        { "target": "rentals.BookingLine", "actions": ["read"] },
        { "target": "equipment.Item", "actions": ["read", "create", "update"] }
      ]
    }
  ],
  "state": "winter-fair-43"
}
```

The user elects one role. Post the election with the same parameters plus
`role`; the answer carries the one-time code:

```sh
curl -sk -X POST "$HOST/OAuth/authorize?response_type=code&client_id=06H1FQF7NG357EQ0P348Z2BEV5&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback&code_challenge=JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc&code_challenge_method=S256&state=winter-fair-43" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "response_type": "code",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "redirect_uri": "http://localhost:5173/auth/callback",
    "code_challenge": "JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc",
    "code_challenge_method": "S256",
    "state": "winter-fair-43",
    "role": "iam.Roles.admin"
  }'
```

```json
{
  "redirect_uri": "http://localhost:5173/auth/callback",
  "code": "5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac",
  "state": "winter-fair-43",
  "app_id": "06H1FQF7NGDJJKSNHXPYT6627M",
  "role_id": "iam.Roles.admin",
  "iss": "https://facet.localhost:3443"
}
```

The code lives for 60 seconds and works once. Exchange it now:

```sh
curl -sk -X POST "$HOST/OAuth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode 'code=5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac' \
  --data-urlencode 'client_id=06H1FQF7NG357EQ0P348Z2BEV5' \
  --data-urlencode 'redirect_uri=http://localhost:5173/auth/callback' \
  --data-urlencode 'code_verifier=YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F'
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc0RlY5Q05RSDNLOThFTURTTUFBWjkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDAxNjEsImV4cCI6MTc5NTcwMTA2MSwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.AqrsiB6iDvRCasWYNdlauDPTOuXSBERFmV-baW1aAlgd-HUxXI7s81PiDBFEBcognYPtyDM5tGieS5-OvXafAw",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.a91913d305aac321675056fd92fb5cf4be2e3827209e79cdf140f548f4b1538d"
}
```

Keep the access token in a variable for the calls below:

```sh
export TOKEN=$(curl -sk -X POST "$HOST/OAuth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode 'grant_type=authorization_code' \
  --data-urlencode 'code=5mmwDDXn58mmruIfJ_4INhGxmYgMXYupVqhH_AqToac' \
  --data-urlencode 'client_id=06H1FQF7NG357EQ0P348Z2BEV5' \
  --data-urlencode 'redirect_uri=http://localhost:5173/auth/callback' \
  --data-urlencode 'code_verifier=YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | jq -r .access_token)
```

Keep the refresh token too: the access token dies after `expires_in`
seconds, and the refresh grant mints a new one — see
[Sign users in](/build/apps/connect/user-login/).

The full round trip, including the callback handling and the refresh floor,
is [Sign users in](/build/apps/connect/user-login/).

### 4. Read real data

Call the API with the access token. The app reads bookings:

```sh
curl -sk "$HOST/Api/rentals/Booking?items=2&sort=-created_at" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "data": [
    {
      "data": {
        "dates": { "end": "2026-11-29", "start": "2026-11-28" },
        "notes": "Press launch — done.",
        "total": 410,
        "client": "clients.Company.06H1FM1B68KB1PJVVAM92B38YS",
        "status": "returned",
        "client_name": "Festival des Collines"
      },
      "meta": { "id": "BK-2026-0015", "display_name": "Festival des Collines" }
    },
    {
      "data": {
        "dates": { "end": "2026-12-06", "start": "2026-12-05" },
        "notes": "Charity gala — done.",
        "total": 576,
        "client": "clients.Company.06H1FM1BNMKMN3PRSDK8B8FR7K",
        "status": "returned",
        "client_name": "Château de Vireloup"
      },
      "meta": { "id": "BK-2026-0014", "display_name": "Château de Vireloup" }
    }
  ],
  "meta": { "count": 15, "more": false }
}
```

The same token on a doctype outside the grant is refused:

```sh
curl -sk "$HOST/Api/clients/Company?items=1" \
  -H "Authorization: Bearer $TOKEN"
```

```
{"error": "Forbidden"}
```

That is the grant ceiling at work, even though the signing user is an
admin. The request path behind it:
[How apps work on Facet](/build/apps/how-apps-work/).

### 5. See what the app can reach

The token can also read its own bounds. `GET /Api/iam/me` answers with the
effective manifest — the exact rights this credential carries:

```sh
curl -sk "$HOST/Api/iam/me" \
  -H "Authorization: Bearer $TOKEN"
```

The `permissions` map lists what the app may attempt:

```json
{
  "active_role": "iam.Roles.admin",
  "permissions": {
    "rentals.Booking": ["read"],
    "rentals.BookingLine": ["read"],
    "equipment.Item": ["read", "create", "update"]
  }
}
```

Size your UI from it —
[Show only what the user can do](/build/apps/connect/permission-manifest/).

### 6. Deploy the app itself

The app you built is still code on your machine. The CLI turns a built
folder into a served app on the instance:

```sh
pnpx @facetapp/cli init
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

The full deploy model — releases, rollback, custom hosts — is
[Deploy your app on Facet](/build/apps/host/deploy/).

## Troubleshooting

**The create answers `422` with `wildcard_target`.**

```json
{"error": "Grant validation failed", "details": [{"field": "grants[0].target", "message": "Wildcard grant target 'rentals.*' is not allowed — name the concrete doctype the app uses", "code": "wildcard_target"}]}
```

A grant names `rentals.*` or `*.*`. Name each concrete doctype — one entry
per doctype.

**A redirect entry fails with `422` and `code: "script"`.**

```json
{"error": "Script validation failed", "details": [{"message": "redirect_uris entries must use https on any host or http on a loopback host (localhost, *.localhost, 127.0.0.1, ::1), without fragment, userinfo, or query; the only permitted wildcard is a '*' port on an http loopback host", "code": "script"}]}
```

Register the address by the rule in the message: `https` on any host,
`http` on loopback hosts only, no fragment, userinfo, or query, and a `*`
only as the port of an `http` loopback entry.

**The token exchange answers `400 invalid_grant`.**

The code is single-use and expires after 60 seconds. A retry with the same
code answers `{"error": "invalid_grant", "error_description": "Authorization code is invalid, expired, or already used"}`.
Start the sign-in again.

**A call the app used to make now answers `403 {"error": "Forbidden"}`.**

The grant was narrowed, or the token's role no longer covers a required
action. Check the app document, then sign in again if the role changed.

**Deploy answers `HTTP 422 from /Api/app/…/deploy`.**

A draft or disabled app cannot receive a build. Activate it first — step 2
above.

## Related

- [Sign users in](/build/apps/connect/user-login/) — the sign-in flow, in full.
- [Register an app](/build/apps/connect/register/) — every registration field.
- [Deploy your app on Facet](/build/apps/host/deploy/) — serving the built app.
- [How apps work on Facet](/build/apps/how-apps-work/) — why the bounds hold.
- [Facet app CLI](/reference/cli-npm/)
