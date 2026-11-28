---
type: how-to
title: Register an app
description: Register an app through the dashboard or the REST API and pick the client type that fits.
audience: [developer]
features: [APP-01, FE-12]
sidebar:
  order: 0
verified_at: eee55a2
---

Every app starts as a registration: an `app.App` document. The registration
names the client type, the redirect addresses, and the grant ceiling. You
register through the dashboard wizard, or through the REST API when you
script the setup. Either way, the app becomes usable when its status turns
`active`.

> **For agents:** Create the app with `POST /Api/app/App`. The JSON body
> carries `slug`, `name`, `client_type`, `redirect_uris`, `allowed_origins`,
> and `grants`; send an API key in `Authorization: Bearer`, or a session
> cookie plus `X-Requested-With: XMLHttpRequest`.
> The create answers `201` with the stored document and a hook-written
> `client_id`. Publish with `PATCH /Api/app/App/{id}` and
> `{"status": "active"}`. Each grant entry looks like
> `{"target": "rentals.Booking", "actions": [{"name": "read", "required": true}]}`;
> a wildcard target answers `422 wildcard_target`.

## When to use this

Use this page when:

- You add a new app to Facet.
- You must choose between a public, a confidential, or a headless
  registration.
- You script app setup and need the API path.

## Before you start

- You need `update` rights on `app.App` documents. The seeded `admin` and
  `editor` roles hold them.
- List the doctypes the app will reach, the sign-in return addresses, and
  the browser origins. Each [grant](/admin/apps-access/app-grants/) names one concrete doctype.

## Steps

### 1. Choose the client type

- **Public** — a browser-only single-page application (SPA). It signs in
  through the consent screen with Proof Key for Code Exchange (PKCE) and
  holds no secret.
- **Confidential** — signs in through the same consent screen and adds a
  backend. The backend acts through a service account and an app-owned API
  key — see [Backend apps and service
  accounts](/build/apps/connect/backend-apps/).
- **Headless** — sets `no_launcher: true`. It never appears in the
  dashboard; people reach it through its client. A command-line tool that
  never deploys builds also sets `no_asset: true`.

  Both types appear in the dashboard launcher unless `no_launcher` is set. A
  `no_asset` app cannot carry a `host`.

### 2. Register in the dashboard

Open **Configure → Apps** and start the wizard. Pick a preset: a web app you
host signs in through the browser; a backend app signs in with an API key.
The setup step collects the name, the sign-in origins, and the redirect
addresses.

The permissions step lists every doctype by domain. Set one access level per
doctype, and pick the single service role for a backend app. Named actions
that a doctype declares appear as extra toggles.

Publish sets the status to `active`. A web app receives its `client_id`. A
confidential app issues one API key; the raw key shows once.

### 3. Or register through the REST API

Sign in as an operator and store an API key for your role — the full
sequence appears under [Backend apps and service
accounts](/build/apps/connect/backend-apps/). The CLI writes it, so keep it
in a variable:

```sh
pnpx @facetapp/cli connect
RAVI_KEY=$(pnpx @facetapp/cli apikey)
```

Then create the app document:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/app/App \
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

The create answers `201` with the stored document. The create hook has
already written `client_id`:

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
  },
  "meta": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "uri": "urn:facet:app:App:06H1FQF7NGDJJKSNHXPYT6627M",
    "mid": "06H1FQF7N81797JT8AMSFRDGQX",
    "domain": "app",
    "doc_type": "App",
    "version": 1,
    "schema_version": 1,
    "display_name": "Brightwater Check-out",
    "created_at": "2026-11-26T12:39:08Z",
    "updated_at": "2026-11-26T12:39:08Z"
  }
}
```

Publish when the app is ready. An app needs `status: active` before sign-ins
work:

```sh
curl -sk -X PATCH \
  https://facet.localhost:3443/Api/app/App/06H1FQF7NGDJJKSNHXPYT6627M \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"status": "active"}'
```

The patch answers `200` with the stored document, `status` now `"active"`
and `updated_at` advanced.

### 4. Check how sign-in sees the app

Before you wire up the browser side, ask the server what a sign-in form
reads. The client-info endpoint takes the slug:

```sh
curl -sk 'https://facet.localhost:3443/OAuth/client-info?slug=brw-checkout'
```

```json
{"slug": "brw-checkout", "client_id": "06H1FQF7NG357EQ0P348Z2BEV5", "name": "Brightwater Check-out", "client_type": "public"}
```

An unknown or inactive slug answers `404`:

```json
{"error": "unknown_client"}
```

:::note[Redirect URI rules]
Every entry is an absolute `http(s)` URI with no fragment, no query, and no
userinfo. `https` is valid on any host. `http` is valid on loopback hosts
only: `localhost`, any `*.localhost` subdomain, `127.0.0.1`, and `::1`. A `*`
port is valid only on an `http` loopback entry. Request time matches the
presented URI exactly, except that a `*`-port entry matches any port.
:::

## Example

The seed runner ships one first-party registration: `facet-cli`, the dev
CLI. It is a worked headless example:

```json
{
  "slug": "facet-cli",
  "name": "Facet CLI",
  "client_type": "public",
  "status": "active",
  "no_launcher": true,
  "no_asset": true,
  "redirect_uris": [
    "http://localhost:*",
    "http://127.0.0.1:*",
    "http://[::1]:*"
  ],
  "grants": [
    {
      "target": "app.App",
      "actions": [
        { "name": "read", "required": true }, { "name": "write", "required": true },
        { "name": "delete", "required": true }, { "name": "deploy", "required": true }
      ]
    },
    {
      "target": "app.Deployment",
      "actions": [{ "name": "read", "required": true }]
    }
  ]
}
```

The CLI binds an ephemeral local port, so each redirect entry pins a `*`
port on a loopback host. The grants carry `deploy` on `app.App` because the
CLI deploys builds. No service role exists: the elected role comes from the
consent screen. The endpoint confirms it is live:

```sh
curl -sk 'https://facet.localhost:3443/OAuth/client-info?slug=facet-cli'
```

```json
{"slug": "facet-cli", "client_id": "06H1FKW4N4RVZWCQ2FR392QMW0", "name": "Facet CLI", "client_type": "public"}
```

## Troubleshooting

**The create answers `422` with `wildcard_target`.**

```json
{"error": "Grant validation failed", "details": [{"field": "grants[0].target", "message": "Wildcard grant target 'rentals.*' is not allowed — name the concrete doctype the app uses", "code": "wildcard_target"}]}
```

A grant names `rentals.*` or `*.*`. Name each concrete doctype instead — one
entry per doctype.

**A redirect entry fails validation with `422`.**

```json
{"error": "Script validation failed", "details": [{"message": "redirect_uris entries must use https on any host or http on a loopback host (localhost, *.localhost, 127.0.0.1, ::1), without fragment, userinfo, or query; the only permitted wildcard is a '*' port on an http loopback host", "code": "script"}]}
```

Check the note above: `https` anywhere, `http` on loopback only, `*` only
as a port on an `http` loopback entry, no fragment or query.

**A PATCH that changes `slug` is refused.**

```json
{"error": "Script validation failed", "details": [{"message": "slug is immutable after creation", "code": "script"}]}
```

The slug is immutable after create. The update hook refuses any patch that
carries the key. Create a new app if you need a different slug.

**Supplying `client_id` answers `422 read_only`.**

```json
{"error": "Document validation failed", "details": [{"field": "client_id", "message": "is read-only and should not be set", "code": "read_only"}]}
```

The create hook is the only writer. Do not send the field.

**An empty `grants` array reads back as `{}`.**

A round-trip quirk of the Lua create hook. The behaviour is equivalent:
both forms iterate as empty.

## Related

- [How apps work on Facet](/build/apps/how-apps-work/) — the model behind the
  registration.
- [Allowed origins and CORS](/build/apps/connect/cors/) — register the browser
  origins.
- [Sign users in](/build/apps/connect/user-login/) — the sign-in the
  registration enables.
- [Control what apps can reach](/admin/apps-access/app-grants/) — the grants editor.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
