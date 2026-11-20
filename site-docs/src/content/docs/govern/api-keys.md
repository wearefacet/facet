---
title: "Machine access: API keys"
description: Create static API keys, pin them to one account and role, and know exactly when a key stops working.
audience: [admin, developer]
features: [IAM-09]
sidebar:
  order: 9
verified_at: fd345fe3
---

An application programming interface (API) key is a static bearer token for
machine clients. It pins one account and one role, fixed at creation. Every
request re-checks the whole chain, so a key dies on its next use the moment
its conditions change.

## When to use this

- A script, a job runner, or an integration must call the API.
- You must revoke machine access quickly and verifiably.
- You need an audit answer to "which key wrote this change".

## Before you start

- **The role.** The role you pin must be assigned to you, and its
  `connectivity` must carry the `api` channel. See
  [Roles and permission lines](/govern/roles-permission-lines/).
- **The account.** Facet intends service accounts to hold keys. A service
  account cannot sign in with a password, so a key is its only door. See
  [Manage accounts](/govern/accounts-lifecycle/).

## Steps

### 1. Create the key

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-pipeline", "role": "iam.Roles.editor"}' \
  "https://facet.localhost:3443/Api/iam/keys"
```

The body carries:

| Field | Rule |
| --- | --- |
| `name` | Required, at most 100 characters. |
| `role` | Required, the qualified role id, for example `iam.Roles.editor`. |
| `expires_at` | Optional, a future ISO-8601 datetime. Facet normalizes it to UTC. |

The answer shows the raw key exactly once:

```json
{
  "id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D",
  "key": "fct_PASTE-THIS-VALUE-NOW-IT-WILL-NOT-SHOW-AGAIN",
  "display_prefix": "fct_PASTE6",
  "expires_at": null
}
```

`key` is the raw token: `fct_` followed by 26 characters. Copy it now.
Storage keeps only its SHA-256 hash and a display prefix; no read path can
return it.

The create answers `422` when the role is not assigned to you or when the
role's `connectivity` excludes `api`.

### 2. Call the API with the key

```sh
export FACET_API_KEY="fct_the-value-from-step-1"
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/hr/Employee?items=5"
```

The requests run with the pinned account and the pinned role. The permission
lines of that role decide what the client may reach. Facet re-checks them on
every request.

### 3. List your keys

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/keys"
```

The list shows `id`, `name`, `display_prefix`, `role_id`, `created_at`,
`expires_at`, `last_used_at`, and `revoked_at`. It never shows the secret.

### 4. Revoke a key

```sh
curl -k -X DELETE -H "Authorization: Bearer $FACET_API_KEY" \
  -H "X-Requested-With: XMLHttpRequest" \
  "https://facet.localhost:3443/Api/iam/keys/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

The revoke is soft and idempotent. A repeated delete still answers `200`. A
key id that is unknown or not yours answers a bare `404` that does not
disclose which.

## Explanation

### What Facet checks on every request

| Check | Failure when |
| --- | --- |
| Not revoked | You revoked the key. |
| Not expired | The `expires_at` time has passed. |
| Account live and `active` | The account is deleted, `suspended`, or `disabled`. |
| Role still assigned | The role was removed from the account. |
| Role projection present | The role document is gone. |
| Role `connectivity` carries `api` | The channel was removed from the role. |

Every failure answers the same bare `401`. It does not disclose which check
failed. The effect: revoking a key, unassigning its role, disabling its
account, or removing the `api` channel kills the key on its next use.

`last_used_at` updates at most once per minute per key. An automated client
does not turn every request into a database write.

### Attribution in the audit trail

Every mutation written through a key carries the key's row id in the
`api_key` column of the mutation log. An audit view can join it to the key's
name and display prefix and answer "which key wrote this change". The
lifecycle also writes two events to the login-event log: `api_key_created`
and `api_key_revoked`. See [Auditing activity](/govern/auditing-activity/).

### App-owned keys

A key row can carry an `app_id`. Facet issues such keys for backend apps.
Verification adds one gate — the app must be live and active — and the request
runs with the app's grant and the pinned role at the same time, so the
effective reach is the overlap. See [Controlling app reach](/govern/app-grants/)
for the grant model.

## Troubleshooting

### The key answers `401`

Run through the check table above. The bare `401` does not name the cause by
design.

1. Check the list route first: `revoked_at` and `expires_at` are the common
   ones.
2. Then check the account status and the role assignment.

### The create answers `422` about the `api` channel

For example: `422 The role's connectivity excludes the 'api' channel.`

Enable the `api` channel on the role's Details tab, or pin a role that
already carries it. The role must also be assigned to you.

### The key works, but the client sees less than expected

The pinned role decides. Check its permission lines, and check whether row
scopes narrow the lists. See [Row scopes](/govern/row-scopes/).

### `last_used_at` did not change after one call

The timestamp updates at most once per minute. Wait and re-check.

## Related

- [Your settings, sessions and API keys](/workspace/settings-sessions-api-keys/) — the self-service key surface.
- [Roles and permission lines](/govern/roles-permission-lines/) — the `connectivity` channels.
- [Manage accounts](/govern/accounts-lifecycle/) — service accounts, the intended holders.
- [Controlling app reach](/govern/app-grants/) — the grant side of app-owned keys.
- [Auditing activity](/govern/auditing-activity/) — key attribution in the logs.
- [Auth contexts](/concepts/auth-contexts/) — how a key resolves to one role.
- Internals on GitHub: [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
