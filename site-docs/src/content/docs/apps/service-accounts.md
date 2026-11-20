---
title: Service accounts for backend apps
description: Give a backend app a machine identity and call the API with an app-owned key.
audience: [developer, admin]
features: [APP-07]
sidebar:
  order: 7
verified_at: a77c6171
---

A backend app needs a machine identity. Facet provisions a service account
for a `confidential` app and issues one API key to it. The key calls the
same REST surface as any other caller, under the same bounds: grant ∩ pinned
role, re-resolved on every request.

> **For agents:** Pin a service role that lists the `api` connectivity
> channel, then issue with `POST /Api/app/{id}/api-key` (operator session
> cookie plus `X-Requested-With: XMLHttpRequest`). Store the raw `key` — it
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

- A `confidential` app registration exists — see [Registering an
  app](/apps/registering-app/).
- You need `update` rights on `app.App` for the key routes.
- You hold an operator browser session; the key routes refuse a key caller.
- The service role lists `api` in its connectivity channels. Issuance refuses
  with `422` otherwise.

## Steps

### 1. Pin the service role

Pick the single role on the wizard's permissions step, or on the app's
Settings tab. The role decides what exists to grant; the app's grants decide
what may be attempted. Facet keeps only the actions the role also gives, on
every request. Row scopes on the role still apply.

### 2. Issue the key

Call the issue route from an operator session. The route provisions the
service account, re-pins its role, and revokes any active key first — one
active key per app, so issuing again is a rotation:

```sh
curl -s -b cookies.txt -X POST \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
```

The answer carries the raw key:

```json
{
  "id": "01JHQ8XC4M7T2WY9PB5K3NR6QD",
  "key": "fct_7QW2N8XC4M5T3WY9PB6K1RD4EN",
  "display_prefix": "fct_7QW2N8XC",
  "service_account_id": "iam.Account.01JHQ9D8N2W5XK7PB3T6YR9M4C",
  "role_id": "iam.Roles.integration"
}
```

Store the `key` now. It shows exactly once, and no route returns it again.

The service account appears at the first issuance. Facet provisions it as
an `iam.Account` with `service_account: true` and the email
`svc.<slug>@apps.facet.invalid`. It holds exactly the pinned role and cannot
log in with email and password.

| Route | Verb | Behaviour |
| --- | --- | --- |
| `/Api/app/:id/api-key` | `POST` | Provisions the service account and issues a key. Revokes any active key first. Returns `{id, key, display_prefix, service_account_id, role_id}`. |
| `/Api/app/:id/api-key` | `GET` | Returns the key status — active flag, display prefix, role, timestamps. Never secret material. |
| `/Api/app/:id/api-key` | `DELETE` | Soft-revokes the active key. Idempotent. Returns `{revoked}`. |

All three routes need an operator session and the Cross-Site Request
Forgery (CSRF) header. The two mutations also need `update` on `app.App`;
the status route needs `read`. A key caller answers `403`: a key can never
mint or revoke itself.

### 3. Call the API

Send the key as a bearer credential. No CSRF header is needed, because the
request carries no ambient cookie:

```sh
curl -s -H "Authorization: Bearer fct_7QW2N8XC4M5T3WY9PB6K1RD4EN" \
  "https://facet.company.tld/Api/crm/Company?per_page=5"
```

The response uses the same shapes and error codes as any other caller. The
effective permission is grant ∩ pinned role, and the mutation records the
app id and the key id.

### 4. Rotate and revoke

Issue a new key to rotate: the route revokes the old key in the same
transaction. Revoke with the delete route when the key is no longer needed:

```sh
curl -s -b cookies.txt -X DELETE \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
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

## Example

A complete sequence, from operator sign-in to revocation:

```sh
# 1. Sign in as an operator and keep the session cookies.
curl -s -c cookies.txt -X POST https://facet.company.tld/Api/iam/login \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "admin@company.tld", "password": "op-secret"}'

# 2. Issue the app key and store the raw value. It shows exactly once.
curl -s -b cookies.txt -X POST \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest" \
  | jq -r .key > deal-bot.key
chmod 600 deal-bot.key

# 3. Call the API with the key. No CSRF header, no cookie.
curl -s -H "Authorization: Bearer $(cat deal-bot.key)" \
  "https://facet.company.tld/Api/crm/Company?per_page=5"

# 4. Revoke when done. Idempotent.
curl -s -b cookies.txt -X DELETE \
  https://facet.company.tld/Api/app/01JHQ7K2N6B1WJ8PC4T9XYR3M5/api-key \
  -H "X-Requested-With: XMLHttpRequest"
```

## Troubleshooting

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

- [How apps work on Facet](/apps/how-apps-work/) — the bounds behind the
  key.
- [Registering an app](/apps/registering-app/) — create the confidential
  registration.
- [Use the REST API](/apps/rest-api/) — the surface the key calls.
- [Machine access: API keys](/govern/api-keys/) — self-service keys for
  people.
- [Controlling app reach (grants)](/govern/app-grants/) — the grant ceiling.
- Internals on GitHub:
  [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
