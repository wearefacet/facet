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
verified_at: df99911
---

The Brightwater warehouse tracks its stock on a spreadsheet. You will replace
it with a small web app: the confirmed bookings, with a button that marks each
item out and back in. Facet registers the app, bounds what it may do, hosts
it, and signs its users in — the spreadsheet gets none of that.

The tutorial has three parts:

1. **Register the app on Facet** — two commands you copy and paste.
2. **Build it with your coding agent** — one prompt; the agent writes the code.
3. **Try it and ship it** — sign in, then deploy with the CLI.

**Time:** about 30 minutes.
**You need:**

- [Tutorial 1](/build/first-hour/run-facet/) — a running instance, with the
  Brightwater example loaded ([tutorial 2](/build/first-hour/first-domain/)
  does it, or the example's `load.sh`).
- Node.js 20+ with pnpm, plus `curl` and `jq`.
- A coding-agent harness — Claude Code, Codex, or OpenCode. Any agent that
  reads files and runs commands works.

:::note
The coding agent here is yours — Claude Code, Codex, OpenCode, or a similar
tool. Facet's built-in assistant is a different tool: it models domains in
the Builder and answers in the workspace. Using it needs a language model
connected by an administrator — see
[Connect a model](/admin/assistant/connect-a-model/).
:::

## Part 1 — Register the app on Facet

### 1. Describe the app

On Facet, an app is a document. It says who the app is, where sign-ins may
return to, and which data it may touch — its **grants**. The check-out app
reads bookings and their lines, and reads and updates equipment items.

Create the project folder and save the app's description in it as
`facet-app.json`:

```sh
mkdir brightwater-checkout && cd brightwater-checkout
```

```json title="facet-app.json"
{
  "slug": "brw-checkout",
  "name": "Brightwater Check-out",
  "client_type": "public",
  "host": "checkout.apps.localhost",
  "redirect_uris": [
    "http://localhost:5173/auth/callback",
    "https://checkout.apps.localhost:3443/auth/callback"
  ],
  "allowed_origins": [
    "http://localhost:5173",
    "https://checkout.apps.localhost:3443"
  ],
  "grants": [
    { "target": "rentals.Booking", "actions": [{ "name": "read", "required": true }] },
    { "target": "rentals.BookingLine", "actions": [{ "name": "read", "required": true }] },
    { "target": "equipment.Item", "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }] }
  ]
}
```

Each address appears twice: once for the dev server on your machine, once for
the hosted build at `checkout.apps.localhost`, where you deploy in Part 3.
The `host` is a bare hostname — no scheme, no port. `public` means the app
runs in the browser and carries no secret.

### 2. Register and activate it

Run these from the project folder. The CLI supplies the instance address and
an admin key — the one it stored for Ravi when you ran `setup-dev`:

```sh
HOST=$(pnpx @facetapp/cli host)
FACET_KEY=$(pnpx @facetapp/cli apikey)

# Register the app; keep its id.
APP_ID=$(curl -sk -X POST "$HOST/Api/app/App" \
  -H "Authorization: Bearer $FACET_KEY" \
  -H "Content-Type: application/json" \
  -d @facet-app.json | jq -r .meta.id)
echo "$APP_ID"

# A new app is a draft. Switch sign-ins on.
curl -sk -X PATCH "$HOST/Api/app/App/$APP_ID" \
  -H "Authorization: Bearer $FACET_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}' | jq '.data | {slug, status}'
```

```text
06H1FQF7NGDJJKSNHXPYT6627M
{"slug": "brw-checkout", "status": "active"}
```

Your ids differ — every instance mints its own.

### 3. Widen the warehouse role

Lucía Ferrer runs the warehouse; the app is for her. One rule governs what
she can hand the app: the app acts with the overlap of its grants and her
role — never more than either allows. The consent screen lists only the
roles that cover every required grant action.

The warehouse role reaches equipment through one domain-wide line,
`{"on": "equipment", "action": "*"}`. That line covers the whole domain for
a person in the workspace — but an app's grants name concrete doctypes, and
a domain-wide line never covers one. Add the concrete line now. The patch
replaces the whole permission list, so send the lines the example's
`load.sh` wrote plus the new one:

```sh
curl -sk -X PATCH \
  "$HOST/Api/iam/Roles/iam.Roles.warehouse" \
  -H "Authorization: Bearer $FACET_KEY" \
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

The consent screen in Part 3 now lists **Warehouse**. Why the overlap
behaves this way, and what an administrator sees on the dashboard, is
[Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).

That is every API call in this tutorial. Prefer clicking? The dashboard
wizard does the same — see
[Register an app](/build/apps/connect/register/).

## Part 2 — Build it with your coding agent

### 4. Scaffold the project

Install the SDK and the build tools, and write the deploy config:

```sh
pnpm init
pnpm add @facetapp/sdk
pnpm add -D typescript vite
HOST=$(pnpx @facetapp/cli host)
pnpx @facetapp/cli init --app brw-checkout --build dist --server "$HOST"
```

`init` writes `facet.config.json`, then looks the app up on the instance.
With no CLI sign-in yet it stops after the config:

```text
Wrote facet.config.json for app "brw-checkout".
No stored session for https://facet.localhost:3443. Run "pnpx @facetapp/cli login" to sign in.
```

You sign the CLI in when you deploy, in Part 3.

### 5. Hand the build to your agent

Open your coding-agent harness in the project folder and paste this prompt:

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

Agent output varies, so check the result rather than the wording:

- `pnpm build` passes with no type errors.
- `src/main.ts` creates the client with `oauthBrowser({ slug: 'brw-checkout' … })`
  and no secret.
- The sign-in button calls `auth.signIn()`; the callback path calls
  `auth.handleCallback(location.href)`.
- Data goes through `facet.domain('rentals')` and `facet.domain('equipment')`
  — no other routes.

If something is off, or you would rather skip the agent, copy the finished
source from
[`site-docs/examples/brightwater/checkout-app/`](https://github.com/wearefacet/facet/tree/main/site-docs/examples/brightwater/checkout-app)
— the rest of the tutorial works with either.

## Part 3 — Try it and ship it

### 6. Sign in as Lucía

Lucía Ferrer runs the warehouse; the app is for her. Start the dev server:

```sh
pnpm dev
```

Open `http://localhost:5173` and click **Sign in with Facet**. Sign in as
`lucia@brightwater.example`. Facet then shows the consent screen: it names
the app, lists the role Lucía can use it with, and what the app may do under
that role:

![The Facet consent screen for Brightwater Check-out: the Warehouse role with the reach the app keeps — Booking and BookingLine read, Item read, create, update.](/screens/build/first-app-1.png)

She picks **Warehouse** and clicks **Authorize**. The browser returns to the
app, and the board renders:

![The check-out board: one card per confirmed booking, with the items, their status and an out/back button.](/screens/build/first-app-2.png)

Mark an item out, then back in — the status changes on Facet too.

**What the app can reach.** The app acts with the overlap of its grants and
Lucía's role — never more than either allows. Her Warehouse role can also
read clients, but the app's grants don't name `clients.Company`, so the app
can't read it: any such call answers `403`. Why, and what an administrator
sees, is [How apps work on Facet](/build/apps/how-apps-work/).

:::tip[The consent screen lists no role?]
Facet only offers roles that cover every grant the app requires, doctype by
doctype. See [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).
To watch each sign-in call with `curl`, see
[Sign users in](/build/apps/connect/user-login/).
:::

### 7. Deploy on Facet

The app runs on your machine; now let Facet host it. The registration
already carries the hosted address, its redirect, and its CORS origin — you
only sign the CLI in and deploy:

```sh
pnpm build
pnpx @facetapp/cli login
pnpx @facetapp/cli deploy --note "first build"
```

`login` opens a consent screen in your browser for the CLI itself — sign in
as the admin. `deploy` packs `dist/`, uploads it, and activates it:

```text
Deploying "dist" to https://facet.localhost:3443 (target of app "brw-checkout")…
Packed 3 files.
Deployed revision 1 (3 files stored).
Active at https://checkout.apps.localhost:3443
```

(The capture above ran against a scratch copy of the app registered as
`brw-checkout-t3`; your run names `brw-checkout` and your host.) Open
`https://checkout.apps.localhost:3443` and sign in again — the board works
there too. Chromium finds `*.apps.localhost` on its own; for Firefox, add
`127.0.0.1 checkout.apps.localhost` to your hosts file.

Anyone who can reach the address gets the page; the data stays behind the
sign-in. Releases, rollback, and custom domains are
[Deploy your app on Facet](/build/apps/host/deploy/).

## What you learned

- An app is a document: it holds the app's identity, its grants, and where
  sign-ins may return. Setting it `active` switches sign-ins on.
- The consent screen lists only roles that cover every required grant
  action — a domain-wide role line needs a concrete line per doctype the
  app names.
- A coding agent can build a Facet app from the docs alone, as long as you
  point it at the pages and give it the project facts.
- The app's reach is the overlap of its grants and the user's role — a call
  outside the grants answers `403`, whatever the role allows.
- The CLI deploys a static build as a revision, and Facet serves it at the
  app's own host with no restart.

## Related

- [Register an app](/build/apps/connect/register/) — every registration
  field, and the dashboard wizard.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — which
  roles the consent screen offers, and why.
- [Sign users in](/build/apps/connect/user-login/) — the full sign-in flow,
  step by step with `curl`, including refresh and DPoP.
- [Allowed origins and CORS](/build/apps/connect/cors/) — why each address
  needed an entry.
- [Use the REST API](/build/apps/data/rest-api/) — the grammar behind every
  call the app makes.
- [Embed the assistant in your app](/build/apps/host/embed-assistant/) —
  the instance needs a model connected first.
- [Facet app CLI](/reference/cli-npm/)

## Next

The app works, and its users see only what their roles allow. In
[Give your team access](/build/first-hour/team-access/) you invite a
colleague and watch the role rules hide what they must not see.
