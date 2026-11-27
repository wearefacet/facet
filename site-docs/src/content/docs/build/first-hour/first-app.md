---
type: tutorial
title: Ship your first app
description: Register the Brightwater check-out app, build it with a coding agent, deploy it, and sign in through Facet.
audience: [developer]
features: [APP-01, APP-02, APP-05, APP-06, APP-09, APP-10]
sidebar:
  order: 4
prev: /build/first-hour/first-domain-in-files/
next: /build/first-hour/team-access/
verified_at: eee55a2
---

The Brightwater warehouse tracks its stock on a spreadsheet. You will replace
it with a small web app: the confirmed bookings, with a button that marks each
item out and back in. Facet registers the app, bounds what it may do, hosts
it, and signs its users in — the spreadsheet gets none of that.

**You will build:** the Brightwater check-out app — registered on Facet,
scaffolded with the CLI, built by a coding agent, deployed on Facet hosting,
signed in through Facet.
**Time:** about 30 minutes.
**You need:**

- [Tutorial 1](/build/first-hour/run-facet/) — a running instance, with the
  Brightwater example loaded ([tutorial 2](/build/first-hour/first-domain/)
  does it, or the example's `load.sh`).
- Node.js 20+ with pnpm, and `curl` for the API steps.
- A coding agent for step 5 — any agent that reads files and runs commands.

:::note
The coding agent in this tutorial is yours — Claude Code, Codex, or any
similar tool. Facet's built-in assistant is a different tool: it models
domains in the Builder and answers in the workspace. Using it needs a
language model connected by an administrator — see
[Connect a model](/admin/assistant/connect-a-model/).
:::

## 1. Register the app

An app is a document in the `app` domain. Every API call presents its own
credential, and the CLI stores one pinned to your role. From the folder where
you ran `setup-dev`:

```sh
RAVI_KEY=$(pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

The key is pinned to `iam.Roles.admin`, which holds `update` on `app.App`.
Create the app document. The grants name the doctypes the app touches — each
target concrete, each action marked `required`:

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
      { "target": "rentals.Booking", "actions": [{ "name": "read", "required": true }] },
      { "target": "rentals.BookingLine", "actions": [{ "name": "read", "required": true }] },
      { "target": "equipment.Item", "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }] }
    ]
  }'
```

The create answers `201`. The hook has already written the read-only
`client_id` — the identity the app presents at sign-in:

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
  "meta": { "id": "06H1FQF7NGDJJKSNHXPYT6627M", "created_at": "2026-11-26T12:39:08Z" }
}
```

Your ids differ — every instance mints its own. A public client carries no
secret: the sign-in uses Proof Key for Code Exchange (PKCE) instead.

## 2. Activate the app

A new app is a `draft`. Sign-ins work only when the status is `active`:

```sh
curl -sk -X PATCH \
  "$HOST/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}'
```

The patch answers `200`, and `status` reads back `"active"`.

## 3. Widen the warehouse role

Lucía Ferrer runs the warehouse, and the app is for her. One rule governs
what she can hand the app: the app acts with the **intersection of its grants
and her role**. The consent screen lists only the roles that cover every
required grant action — and coverage is checked line by line.

The warehouse role reaches equipment through one domain-wide line,
`{"on": "equipment", "action": "*"}`. That line covers the whole domain for a
person in the workspace — but an app's grants name concrete doctypes, and a
domain-wide line never covers one. So the consent screen lists no role for
Lucía yet:

```json
{ "app": { "slug": "brw-checkout", "status": "active" }, "roles": [], "state": "winter-fair-43" }
```

The fix is one concrete line on the role. Patch the role with its lines plus
`{"on": "equipment.Item", "action": "*"}`:

```sh
curl -sk -X PATCH \
  "$HOST/Api/iam/Roles/iam.Roles.warehouse" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "permissions": [
      { "on": "equipment", "action": "*" },
      { "on": "equipment.Item", "action": "*" },
      { "on": "rentals.Booking", "action": "read" },
      { "on": "rentals.BookingLine", "action": "read" },
      { "on": "clients.Company", "action": "read" },
      { "on": "clients.Contact", "action": "read" },
      { "on": "core.Comment", "action": "*" },
      { "on": "core.Attachment", "action": "*" }
    ]
  }'
```

The read lines came from the example's `load.sh` — keep them; the patch
replaces the whole list. Why the intersection behaves this way, and what an
administrator sees on the dashboard, is
[Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).

## 4. Scaffold the project

Create the project and install the two tools it uses — the TypeScript SDK for
the API calls, and the developer CLI for the deploy:

```sh
mkdir brightwater-checkout && cd brightwater-checkout
pnpm init
pnpm add @facetapp/sdk
pnpm add -D typescript vite
HOST=$(pnpx @facetapp/cli host)
pnpx @facetapp/cli init --app brw-checkout --build dist --server "$HOST"
```

`init` writes the deploy config, `facet.config.json`, and then looks the app
up on the instance. With no CLI sign-in yet it stops after the config:

```text
Wrote facet.config.json for app "brw-checkout".
No stored session for https://facet.localhost:3443. Run "pnpx @facetapp/cli login" to sign in.
```

The next step has your coding agent write the source files — `tsconfig.json`,
`index.html`, and `src/`. Working without an agent? Copy the finished source
instead:
[`site-docs/examples/brightwater/checkout-app/`](https://github.com/wearefacet/facet/tree/main/site-docs/examples/brightwater/checkout-app).

## 5. Build the app with a coding agent

Open your coding agent in the project folder and paste this prompt:

```text
Build a small single-page app in this folder, in TypeScript with Vite.

Goal: the Brightwater check-out board. The app signs its users in through
Facet and shows the confirmed bookings with their items. Each item row
carries a button that flips the item status between "out" and "available".

Facts you must not invent — fetch them first:
- Docs index: https://docs.facet.example/llms.txt — then read these pages as
  raw markdown by adding .md to the path:
  /build/apps/quickstart.md        (registration and the sign-in sequence)
  /build/apps/connect/user-login.md (the browser sign-in flow)
  /build/apps/data/sdk.md          (the TypeScript SDK)
  /build/apps/data/rest-api.md     (the API grammar)
- Copy the complete code blocks from those pages. Do not invent endpoints,
  parameters, or error bodies.

Project facts:
- Facet instance: https://facet.localhost:3443
- App slug: brw-checkout (already registered, client_type public)
- Sign-in: OAuth authorization code + PKCE through @facetapp/sdk's
  oauthBrowser({ slug, redirectUri }) — redirect path /auth/callback
- Data:
  rentals.Booking: client_name (copied from the client), dates {start, end},
    status (draft | confirmed | returned), total
  rentals.BookingLine (child of Booking): item (reference to equipment.Item),
    quantity, price
  equipment.Item: name, status (available | out | in_repair), serial_number

Build:
- index.html, src/main.ts, src/style.css, tsconfig.json — Vite vanilla
  TypeScript; add "dev" and "build" scripts (vite, and tsc && vite build)
  to package.json
- On the /auth/callback path, finish the sign-in and return to /
- Signed out: one "Sign in with Facet" button
- Signed in: one card per confirmed booking (client name, dates), with a
  table of its lines (item name, serial, quantity, status) and a button that
  updates the item status to "out" or "available", then re-renders
- An item whose status is "in_repair" shows no button
- Surface API errors as text; a 403 means the app's grant does not reach

When done, run `pnpm build` and make it pass with no type errors.
```

The agent fetches the pages, copies their code blocks, and writes the
source files. LLM output varies, so check the result instead of the wording:

- `pnpm build` passes with no type errors.
- `src/main.ts` creates the client with `oauthBrowser({ slug: 'brw-checkout' … })`
  and no secret.
- The sign-in button calls `auth.signIn()`; the callback path calls
  `auth.handleCallback(location.href)`.
- The board reads confirmed bookings and updates items through
  `facet.domain('rentals')` and `facet.domain('equipment')` — no other routes.

If the result differs, take the finished source from
[`site-docs/examples/brightwater/checkout-app/`](https://github.com/wearefacet/facet/tree/main/site-docs/examples/brightwater/checkout-app)
and continue from it — the next two steps work with either.

## 6. Sign in through Facet

Start the app:

```sh
pnpm dev
```

Open `http://localhost:5173` and click **Sign in with Facet**. The browser
goes to Facet's sign-in — use Lucía, `lucia@brightwater.example` — and then
to the consent screen. The screen names the app and lists the one role
Lucía may elect, with the reach the app would keep:

![The Facet consent screen for Brightwater Check-out: the Warehouse role with the reach the app keeps — Booking and BookingLine read, Item read, create, update.](/screens/build/first-app-1.png)

She elects **Warehouse** and clicks **Allow**. The browser returns to the
app, and the board renders:

![The check-out board: one card per confirmed booking, with the items, their status and an out/back button.](/screens/build/first-app-2.png)

The browser flow is four calls. The transcript below shows them with `curl`,
using a `warehouse` key the way the app holds Lucía's token — handy when a
step misbehaves. Pin it first (sign in as the admin in your browser):

```sh
LUCIA_KEY=$(pnpx @facetapp/cli connect --role warehouse >/dev/null && pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)

# A PKCE pair for this sign-in.
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary \
  | openssl base64 | tr '+/' '-_' | tr -d '=\n')

# The consent screen, as JSON: which roles may elect, and the reach each keeps.
curl -sk -H "Authorization: Bearer $LUCIA_KEY" -H "Accept: application/json" \
  "$HOST/OAuth/authorize?response_type=code&client_id=06H1FQF7NG357EQ0P348Z2BEV5&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fauth%2Fcallback&code_challenge=$CHALLENGE&code_challenge_method=S256&state=winter-fair-43"
```

```json
{
  "app": { "slug": "brw-checkout", "display_name": "Brightwater Check-out", "status": "active" },
  "roles": [
    {
      "role_id": "iam.Roles.warehouse",
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

```sh
# Lucía elects the role; the answer carries the one-time code.
CODE=$(curl -sk -X POST "$HOST/OAuth/authorize" \
  -H "Authorization: Bearer $LUCIA_KEY" \
  -H "Content-Type: application/json" \
  -d '{"response_type": "code", "client_id": "06H1FQF7NG357EQ0P348Z2BEV5", "redirect_uri": "http://localhost:5173/auth/callback", "code_challenge": "'"$CHALLENGE"'", "code_challenge_method": "S256", "state": "winter-fair-43", "role": "iam.Roles.warehouse"}' \
  | grep -o '"code":"[^"]*"' | cut -d'"' -f4)
echo "$CODE"

# The app exchanges the code for tokens (60 seconds to use the code).
TOKEN=$(curl -sk -X POST "$HOST/OAuth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "client_id=06H1FQF7NG357EQ0P348Z2BEV5" \
  --data-urlencode "redirect_uri=http://localhost:5173/auth/callback" \
  --data-urlencode "code_verifier=$VERIFIER" \
  | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
echo "${TOKEN:0:24}…"
```

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.…",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "79eb44cd18ab1ff86b66b346…"
}
```

With that token, the app reads exactly what the consent screen promised — the
confirmed bookings, six of them on the example data:

```sh
curl -sk "$HOST/Api/rentals/Booking?filters%5Bstatus__eq%5D=confirmed&items=3" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{
  "data": [
    { "data": { "client_name": "Maison Lumière", "status": "confirmed", "dates": { "start": "2026-12-11", "end": "2026-12-13" }, "total": 1970 }, "meta": { "id": "BK-2026-0001", "display_name": "Maison Lumière" } },
    { "data": { "client_name": "Harbour Events Ltd", "status": "confirmed", "dates": { "start": "2026-12-19", "end": "2026-12-20" }, "total": 1160 }, "meta": { "id": "BK-2026-0003", "display_name": "Harbour Events Ltd" } },
    { "data": { "client_name": "Vineyard Wedges", "status": "confirmed", "dates": { "start": "2026-12-12", "end": "2026-12-14" }, "total": 600 }, "meta": { "id": "BK-2026-0005", "display_name": "Vineyard Wedges" } }
  ],
  "meta": { "count": 6, "more": false }
}
```

And nothing more. The same token on a doctype outside the grant is refused:

```sh
curl -sk "$HOST/Api/clients/Company?items=1" \
  -H "Authorization: Bearer $TOKEN"
```

```json
{ "error": "Forbidden" }
```

The grant ceiling holds even though Lucía's own role reads clients. That is
the whole model: the app never gets more than both sides allow —
[How apps work on Facet](/build/apps/how-apps-work/).

## 7. Deploy on Facet

The app runs on your machine; Facet can host it. The deployed build answers
at the app's own host, so the registration needs that origin's redirect and
CORS entries first:

```sh
curl -sk -X PATCH \
  "$HOST/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M" \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "redirect_uris": [
      "http://localhost:5173/auth/callback",
      "https://checkout.apps.localhost:3443/auth/callback"
    ],
    "allowed_origins": [
      "http://localhost:5173",
      "https://checkout.apps.localhost:3443"
    ],
    "host": "checkout.apps.localhost"
  }'
```

The host is a bare hostname — no scheme, no port. Facet serves the active
build there with no restart. Now sign the CLI in and deploy:

```sh
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

`login` opens the consent screen in your browser for the CLI's own
registration. `deploy` packs `dist/`, uploads it, and activates it:

```text
Deploying "dist" to https://facet.localhost:3443 (target of app "brw-checkout")…
Packed 3 files.
Deployed revision 1 (3 files stored).
Active at https://checkout.apps.localhost:3443
```

(The capture above ran against a scratch copy of the app registered as
`brw-checkout-t3`; your run names `brw-checkout` and your host.) Open the
hosted address — Chromium resolves `*.apps.localhost` by itself; Firefox and
`curl` need one hosts entry, `127.0.0.1 checkout.apps.localhost`. Sign in
again at the hosted address — the registration already carries its redirect
and origin — and the board works there too. Releases, rollback, and custom
domains are [Deploy your app on Facet](/build/apps/host/deploy/).

:::note
Hosting serves the build to anyone who can resolve the host; the data stays
behind the sign-in. To embed Facet's assistant in the app later, the
instance needs a model connected — see
[Embed the assistant in your app](/build/apps/host/embed-assistant/).
:::

## What you learned

- An app is a document: registration writes its identity, grants, and
  redirect rules; `active` switches sign-ins on.
- The consent screen lists only roles that cover every required grant
  action — a domain-wide role line needs a concrete line per doctype the
  app names.
- The app token's reach is the intersection of the grants and the elected
  role; a call outside the grant answers `403` even for a powerful role.
- The CLI deploys a static build as a revision and activates it with no
  restart; Facet serves it at the app's own host.

## Related

- [Register an app](/build/apps/connect/register/) — every registration
  field, and the dashboard wizard.
- [Sign users in](/build/apps/connect/user-login/) — the full sign-in flow,
  including refresh and DPoP.
- [Allowed origins and CORS](/build/apps/connect/cors/) — why the hosted
  origin needed an entry.
- [Use the REST API](/build/apps/data/rest-api/) — the grammar behind every
  call the app makes.
- [Facet app CLI](/reference/cli-npm/)
## Next

The app works, and its users see only what their roles allow. In
[Give your team access](/build/first-hour/team-access/) you invite a
colleague and watch the role rules hide what they must not see.
