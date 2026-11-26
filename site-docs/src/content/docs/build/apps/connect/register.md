---
type: how-to
title: Register an app
description: Register an app through the dashboard or the REST API and pick the client type that fits.
audience: [developer]
features: [APP-01, FE-12]
sidebar:
  order: 0
verified_at: a77c6171
---

Every app starts as a registration: an `app.App` document. The registration
names the client type, the redirect addresses, and the grant ceiling. You
register through the dashboard wizard, or through the REST API when you
script the setup. Either way, the app becomes usable when its status turns
`active`.

> **For agents:** Create the app with `POST /Api/app/App`. The JSON body
> carries `slug`, `name`, `client_type`, `redirect_uris`, `allowed_origins`,
> and `grants`; send a session cookie and `X-Requested-With: XMLHttpRequest`.
> The create answers `201` with the stored document and a hook-written
> `client_id`. Publish with `PATCH /Api/app/App/{id}` and
> `{"status": "active"}`. Each grant entry looks like
> `{"target": "crm.Contact", "actions": [{"name": "read", "required": true}]}`;
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
  the browser origins. Each grant names one concrete doctype.

## Steps

### 1. Choose the client type

- **Public** — a browser-only single-page application (SPA). It signs in
  through the consent screen with Proof Key for Code Exchange (PKCE) and
  holds no secret.
- **Confidential** — signs in through the same consent screen and adds a
  backend. The backend acts through a service account and an app-owned API
  key — see [Backend apps](/build/apps/connect/backend-apps/).
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

Sign in as an operator and keep the session cookies in `cookies.txt` — the
full sequence appears under [Backend apps](/build/apps/connect/backend-apps/). Then
create the app document:

```sh
curl -s -b cookies.txt -X POST https://facet.company.tld/Api/app/App \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{
    "slug": "deal-board",
    "name": "Deal Board",
    "client_type": "public",
    "redirect_uris": ["https://deal-board.company.tld/auth/callback"],
    "allowed_origins": ["https://deal-board.company.tld"],
    "grants": [
      {
        "target": "crm.Deal",
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
    "slug": "deal-board",
    "name": "Deal Board",
    "client_type": "public",
    "status": "draft",
    "client_id": "01JHQ8ZV3M7Q2XK9PB4T5WY6RD",
    "redirect_uris": ["https://deal-board.company.tld/auth/callback"],
    "allowed_origins": ["https://deal-board.company.tld"],
    "grants": [
      {
        "target": "crm.Deal",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  },
  "meta": {
    "id": "app.App.01JHQ9M4T8C3XK2PB5WY6RD7QF",
    "uri": "urn:facet:app:App:01JHQ9M4T8C3XK2PB5WY6RD7QF",
    "mid": "01JHQ9M5T8D4XK2PB5WY6RD8QG",
    "domain": "app",
    "doc_type": "App",
    "version": 1,
    "schema_version": 1,
    "created_at": "2026-11-13T09:00:00Z",
    "updated_at": "2026-11-13T09:00:00Z"
  }
}
```

Publish when the app is ready. An app needs `status: active` before sign-ins
work:

```sh
curl -s -b cookies.txt -X PATCH \
  https://facet.company.tld/Api/app/App/01JHQ9M4T8C3XK2PB5WY6RD7QF \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"status": "active"}'
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
consent screen.

## Troubleshooting

**The create answers `422 wildcard_target`.**

A grant names `crm.*` or `*.*`. Name each concrete doctype instead — one
entry per doctype.

**A redirect entry fails validation with `422`.**

Check the note above: `https` anywhere, `http` on loopback only, `*` only
as a port on an `http` loopback entry, no fragment or query.

**A PATCH that changes `slug` is refused.**

The slug is immutable after create. The update hook refuses any patch that
carries the key. Create a new app if you need a different slug.

**Supplying `client_id` answers `422 read_only`.**

The create hook is the only writer. Do not send the field.

**An empty `grants` array reads back as `{}`.**

A round-trip quirk of the Lua create hook. The behaviour is equivalent:
both forms iterate as empty.

## Related

- [How apps work on Facet](/build/apps/how-apps-work/) — the model behind the
  registration.
- [CORS and allowed origins](/build/apps/connect/cors/) — register the browser
  origins.
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the sign-in the
  registration enables.
- [Controlling app reach (grants)](/admin/apps-access/app-grants/) — the grants editor.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
