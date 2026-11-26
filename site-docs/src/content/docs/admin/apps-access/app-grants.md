---
type: how-to
title: Controlling app reach (grants)
description: Set what an app may attempt with grants, and see how the grant and the role bound every request.
audience: [admin]
features: [RBC-08, FE-12]
sidebar:
  order: 0
verified_at: fd345fe3
---

An external app gets access through a registration document. A grant on that
document bounds what the app may attempt at all. The role it signs in with —
elected on the consent screen, or pinned for a backend app — bounds what it
may see and change. The two bounds apply together on every request.

## When to use this

- You register an app and must keep its reach narrow.
- An app needs more or less access than it has.
- You must switch an app off quickly.

## Before you start

- **The right.** You need `update` rights on `app.App` documents. The seeded
  `admin` and `editor` roles hold them.
- **The model.** Read [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/)
  for the model behind this page.

## Steps

### 1. Create the app

Open **Configure → Apps** and start the wizard. Pick a preset: a web app you
host signs in through the browser; a backend app signs in with an API key. The
setup step collects the name, the sign-in origins, and the redirect addresses.

### 2. Set the grants

The permissions step — or the Grants tab on an existing app — lists every
doctype by domain. Set one access level per doctype:

| Level | Grant actions |
| --- | --- |
| None | no entry |
| Read | `read` |
| Write | `read` + `write` — `write` covers create and update |
| Full | `read` + `write` + `delete` |

Named actions that the doctype declares appear as extra toggles once the
level is above None. A child doctype inherits its parent's level in the
editor; the save writes an explicit entry for it.

:::note[Targets are concrete]
A grant names one doctype, for example `crm.Contact`. Wildcard targets are
refused. An app that renders labels or definitions needs an explicit read
grant on `core.DocType`, or it hardcodes the values.
:::

### 3. Pin the service role (backend apps)

A backend app acts through a machine identity. Pick its single role on the
permissions step. The editor warns when the role misses a required grant
action, for example `missing: update on fin.Invoice`. The warning does not
block the save; the real check runs on every request. The role must list
`api` in its connectivity channels, or key issuance refuses.

### 4. Publish and issue credentials

Publish sets the app status to `active`. A web app gets its client id and
signs in through the consent screen. A backend app issues one API key; the
raw key shows once.

### 5. Change or revoke

Edit the grants on the Grants tab, or set the app to disabled. Facet re-reads
the app document on every request, so a change applies on the next request.
Nothing needs re-issuing.

## Explanation

### Two bounds, not one

The grant is the ceiling: it names the doctype paths and actions the app may
attempt. The role decides what exists to grant: Facet keeps only the actions
that the role also gives. Row scopes on the role still apply unchanged inside
the granted paths. A grant never widens a row filter.

### The grant pre-check

Every read, write, and action entry point runs the grant pre-check first. A
combination of domain, path, and action that no grant names is refused. An
app with an empty grant set is refused everywhere — this fails closed.

### The effective scope is re-resolved per request

The token never carries the grant. Facet reloads the app document and
re-resolves the intersection on every request. Tighten a grant, and the next
request runs under the tighter bound.

### What the app cannot reach

The effective scope lists concrete doctype paths only. A wildcard role line
collapses onto each granted doctype. A doctype that no grant names answers
the same denials that a role without read gives. For example, an app token
cannot read `core.DocType` unless a grant names it.

### Tokens, keys, and consent

- An app token (`typ: "app"`) rides the OAuth authorization code flow with
  PKCE and DPoP. The consent screen is always shown, and the signing account
  elects exactly one role for the app.
- An app-owned API key (the `app_api_key` channel) authenticates the app's
  service account. Verification also checks the app: a key for a draft or
  disabled app answers the uniform `401`. The effective right is grant ∩ pinned
  role, computed per request.

### Attribution

Every app-channel mutation records the app id, and the audit list filters by
it. Login events carry the app id for app sessions. Denials at the pre-check
land in the login-event log — see [Auditing activity](/admin/history/audit/).

## Example

This grant set on an app document lets the app read and write contacts,
and read deals:

```json
{
  "grants": [
    {
      "target": "crm.Contact",
      "actions": [
        { "name": "read", "required": true },
        { "name": "write", "required": true }
      ]
    },
    {
      "target": "crm.Deal",
      "actions": [
        { "name": "read", "required": true },
        { "name": "write", "required": false }
      ]
    }
  ]
}
```

`required: true` means the role must grant the action, or the role is unusable
for the app. `required: false` means Facet includes the action only when the
role grants it. Its absence never rejects the role.

## Troubleshooting

### Every route answers `401` with a valid key

The service role no longer covers every required action. The server log names
the missing actions, for example `update on fin.Invoice`. Widen the role or
lower the requirement.

### A call answers `403` for a doctype the app used to reach

The grant was narrowed or removed. The next request applies the change.

### The app cannot read labels or definitions

Grant `read` on `core.DocType`, or hardcode the values in the app.

### Sign-in fails after a role edit

A required grant action is missing on the elected role. Check the warning on
the app's Grants tab.

## Related

- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the concept.
- [Roles and permission lines](/admin/people/roles-and-permissions/) — the role side of the intersection.
- [Machine access: API keys](/admin/apps-access/api-keys/) — the key channel.
- [Auditing activity](/admin/history/audit/) — app attribution in the log.
- Internals on GitHub: [app-system.md](https://github.com/wearefacet/facet/blob/main/doc/backend/app-system.md).
