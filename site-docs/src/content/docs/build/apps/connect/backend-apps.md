---
type: how-to
title: Backend apps and service accounts
description: Give a backend app a service account and call the API with an app-owned key.
audience: [developer, admin]
features: [APP-07]
sidebar:
  order: 4
verified_at: eee55a2
---

A backend app needs a machine identity. Facet provisions a service account
for a `confidential` app and issues one API key to it. The key calls the
same REST surface as any other caller, under the same bounds: grant ∩ pinned
role, re-resolved on every request.

> **For agents:** Pin a service role that lists the `api` connectivity
> channel, then issue with `POST /Api/app/{id}/api-key` (an operator API key
> in `Authorization: Bearer`, or a session cookie plus
> `X-Requested-With: XMLHttpRequest`). Store the raw `key` — it
> shows once. Call `GET /Api/{domain}/{doctype}` with
> `Authorization: Bearer fct_…`; no CSRF header and no cookie. Rotate by
> issuing again; revoke with `DELETE /Api/app/{id}/api-key`. Every key
> failure answers a bare `401`; the server log names the missing grant
> actions.

## When to use this

Use a service account and key when:

- A server-to-server integration reads or writes Facet data.
- A continuous integration (CI) job or a scheduled job needs access.
- A `confidential` app has a backend component that acts as itself.

Use the OAuth sign-in instead when a person drives the app. Use the key when
no person sits at the keyboard.

## Before you start

- A `confidential` app registration exists — see [Register an
  app](/build/apps/connect/register/).
- You need `update` rights on `app.App` for the key routes.
- You hold an operator browser session; the key routes refuse a key caller.
- The service role lists `api` in its connectivity channels, and its
  permission lines reach the app's grant targets. Issuance refuses with
  `422` otherwise.

## Steps

### 1. Pin the service role

Pick the single role on the wizard's permissions step, or on the app's
Settings tab. The role decides what exists to grant; the app's grants decide
what may be attempted. Facet keeps only the actions the role also gives, on
every request. Row scopes on the role still apply.

The stock-sync backend at Brightwater gets its own least-privilege role —
one concrete permission line, the `api` channel, nothing else. Every API
call presents its own credential; sign in once and store a key from the CLI:

```sh
pnpx @facetapp/cli connect   # sign in, elect the admin role, store the key
RAVI_KEY=$(pnpx @facetapp/cli apikey)
```

```sh
curl -sk -X POST https://facet.localhost:3443/Api/iam/Roles \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "stock_sync",
    "level": 30,
    "description": "Machine role for the Brightwater stock-sync backend. Reads and writes equipment items over the API.",
    "permissions": [{ "on": "equipment.Item", "action": "*" }],
    "connectivity": ["api"],
    "visible_tags": ["default"]
  }'
```

The create answers `201`; the role lives at `iam.Roles.stock_sync`.

### 2. Register the app as confidential

A backend app is a `confidential` registration with the service role pinned.
No redirect addresses are needed — there is no browser round trip:

```sh
curl -sk -X POST https://facet.localhost:3443/Api/app/App \
  -H "Authorization: Bearer $RAVI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "brw-stock-sync",
    "name": "Brightwater stock sync",
    "client_type": "confidential",
    "no_launcher": true,
    "service_role_id": "iam.Roles.stock_sync",
    "redirect_uris": [],
    "allowed_origins": [],
    "grants": [
      {
        "target": "equipment.Item",
        "actions": [{ "name": "read", "required": true }, { "name": "write", "required": true }]
      }
    ]
  }'
```

The create answers `201` with `client_type: "confidential"`,
`service_role_id: "iam.Roles.stock_sync"`, and the hook-written
`client_id`. Activate it the same way as any app —
`PATCH /Api/app/App/{id}` with `{"status": "active"}`.

### 3. Issue the key

Call the issue route with an operator key. The route provisions the
service account, re-pins its role, and revokes any active key first. One
active key per app exists, so issuing again is a rotation:

```sh
curl -sk -X POST \
  https://facet.localhost:3443/Api/app/06H1G4RS1CQFAC128KPASQFX7H/api-key \
  -H "Authorization: Bearer $RAVI_KEY"
```

The answer carries the raw key:

```json
{
  "id": "06H1G4YA6WSM1T1H58V6M3YBQE",
  "key": "fct_9AHD08J0GWCCVWZ064KX2SY7G1",
  "display_prefix": "fct_9AHD08",
  "service_account_id": "06H1G4YA3MM0CESP8SQ6K2GG58",
  "role_id": "iam.Roles.stock_sync"
}
```

Store the `key` now. It shows exactly once, and no route returns it again.

The service account appears at the first issuance. Facet provisions it as
an `iam.Account` with `service_account: true` and the email
`svc.brw-stock-sync@apps.facet.invalid`. It holds exactly the pinned role
and cannot log in with email and password.

| Route | Verb | Behaviour |
| --- | --- | --- |
| `/Api/app/:id/api-key` | `POST` | Provisions the service account and issues a key. Revokes any active key first. Returns `{id, key, display_prefix, service_account_id, role_id}`. |
| `/Api/app/:id/api-key` | `GET` | Returns the key status — active flag, display prefix, role, timestamps. Never secret material. |
| `/Api/app/:id/api-key` | `DELETE` | Soft-revokes the active key. Idempotent. Returns `{revoked}`. |

All three routes need an operator session and the Cross-Site Request
Forgery (CSRF) header. The two mutations also need `update` on `app.App`;
the status route needs `read`. A key caller answers `403`: a key can never
mint or revoke itself.

The status route answers:

```json
{
  "active": true,
  "id": "06H1G4YA6WSM1T1H58V6M3YBQE",
  "display_prefix": "fct_9AHD08",
  "role_id": "iam.Roles.stock_sync",
  "created_at": "2026-11-26T13:37:59Z",
  "last_used_at": null
}
```

### 4. Call the API

Send the key as a bearer credential. No CSRF header is needed, because the
request carries no ambient cookie:

```sh
curl -sk -H "Authorization: Bearer fct_9AHD08J0GWCCVWZ064KX2SY7G1" \
  "https://facet.localhost:3443/Api/equipment/Item?items=1"
```

```json
{
  "data": [
    {
      "data": {
        "name": "Main tent 10x15",
        "status": "out",
        "category": "equipment.Category.06H1FM176GDKRM4EKNBQAVC94X",
        "serial_number": "TN-10015-A"
      },
      "meta": {
        "id": "EQ-2026-0001",
        "uri": "urn:facet:equipment:Item:EQ-2026-0001",
        "display_name": "Main tent 10x15"
      }
    }
  ],
  "meta": { "count": 40, "more": false }
}
```

The response uses the same shapes and error codes as any other caller.
Note what is missing. `purchase_price` carries the `finance` tag, and the
pinned role does not list that tag — the key sees the item, not its cost.
The effective permission is grant ∩ pinned role, and the mutation records
the app id and the key id.

The key can also read its own bounds. The manifest on `GET /Api/iam/me`
shows the effective intersection, the key's identity, and its channels:

```json
{
  "account": {
    "display_name": "Brightwater stock sync",
    "email": "svc.brw-stock-sync@apps.facet.invalid"
  },
  "active_role": "iam.Roles.stock_sync",
  "expires_at": null,
  "connectivity": ["api"],
  "channel": "api",
  "permissions": {
    "equipment.Item": ["read", "create", "update"]
  }
}
```

`expires_at` is `null`: a key does not expire on its own. The `write` grant
arrived as `create` plus `update`. See
[Show only what the user can do](/build/apps/connect/permission-manifest/).

### 5. Rotate and revoke

Issue a new key to rotate: the route revokes the old key in the same
transaction. Revoke with the delete route when the key is no longer needed:

```sh
curl -sk -X DELETE \
  https://facet.localhost:3443/Api/app/06H1G4RS1CQFAC128KPASQFX7H/api-key \
  -H "Authorization: Bearer $RAVI_KEY"
```

```json
{"revoked": true}
```

## Explanation

### What the server checks on every request

The checks run on every request:

- the key is not revoked and not expired
- the service account is live and `active`
- the account still holds the pinned role
- the role still lists the `api` channel
- the app is live and `status` is `active`

Any failure answers a bare `401`. The body names nothing, so a leaked key
learns nothing.

### One active key per app

The key row carries the app id. Issuing while an active key exists revokes
that key first, so rotation is a re-issue. The status route shows the active
key's display prefix and its last use, never the secret.

:::caution[The raw key shows once]
The issue response is the only place the full key appears. Store it in the
backend's secret store at once. A lost key is replaced by issuing a new one,
which revokes the old key.
:::

## Troubleshooting

**Issuance answers `422`: "The app's grants do not intersect the service role's permissions".**

```json
{"error": "The app's grants do not intersect the service role iam.Roles.stock_sync's permissions — the key would be refused at every request. Add a role permission line whose reach covers each grant target (for each grant: {\"on\": \"fin\", \"action\": \"*\"} or {\"on\": \"fin.Invoice\", \"action\": \"*\"}) or widen the role."}
```

The pinned role's lines do not reach any grant target. A domain-wide line —
`{"on": "fin", "action": "*"}` — and a concrete line both qualify, so this
failure means the role's lines sit in other domains, or every line that
reaches a grant target carves it out with `except`. Write the line the
message suggests and issue again.

**Every route answers `401` with a valid key.**

The pinned role no longer covers every required grant action. A grant
`write` needs role lines `create` and `update`. The body stays silent by
design; the server log carries one WARN line that names the missing actions,
for example `update on fin.Invoice`. Widen the role or narrow the grants.

**The key routes answer `403`.**

You called them with the key. A key can never mint or revoke itself. Use an
operator session.

**Issuance answers `422` with "App is not a backend app".**

The app's `client_type` is `public`. Flip it to `confidential` on the app's
Settings tab, then issue.

**The key was issued while the app was still in `draft`.**

It authenticates only after the app becomes `active`. Until then every
request answers `401`, and the server log carries the reason.

## Related

- [How apps work on Facet](/build/apps/how-apps-work/) — the bounds behind the
  key.
- [Register an app](/build/apps/connect/register/) — create the confidential
  registration.
- [Use the REST API](/build/apps/data/rest-api/) — the surface the key calls.
- [API keys](/admin/apps-access/api-keys/) — self-service keys for

  people.
- [Control what apps can reach](/admin/apps-access/app-grants/) — the grant ceiling.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
