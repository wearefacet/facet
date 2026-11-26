---
title: Assign roles
description: Put roles on accounts through the assignments editor, and learn why one role is elected per sign-in.
type: how-to
audience: [admin]
features: [RBC-02]
verified_at: eee55a2
sidebar:
  order: 3
---

Nadia at Brightwater needs a second hat: she approves bookings as *Manager*
and answers the assistant as a plain *Viewer* when she tests. You give her
account both roles. When she signs in, she picks one — and Facet runs every
request under exactly that one until she switches.

An account holds roles in its `roles` array. A request never merges them: it
runs under exactly one elected role. This page shows how an administrator
assigns and removes roles, and how the election works at sign-in and at
refresh.

## When to use this

- You hire a member and must give them their working roles.
- You move a member to another team with different rights.
- You must answer why a member acts under one role when they hold three.

## Before you start

- **The right page.** Open **Configure → Access → Assignments**. You need
  `update` rights on `iam.Account`.
- **The guard.** The role authority guard applies: you can only assign roles
  at or below your own elected level. See
  [Roles and permissions](/admin/people/roles-and-permissions/).

## Steps

### 1. Open the assignments editor

Open **Configure → Access → Assignments**. The editor has two modes:

| Mode | What it shows | What it writes |
| --- | --- | --- |
| Role | Pick a role, see its members. | The `roles` array of each account you add or remove. |
| Account | Pick an account, see its roles. | The `roles` array of that account. |

Both modes share one write path. The page URL is deep-linkable, for example
`/Configure/access/assignments?mode=account&account=<id>`; the state survives
a reload.

<!-- screenshot: configure-assignments -->

### 2. Assign a role

In the account mode, search the account by email, then add one or more roles.
Each save issues one update on the account document, the same as a manual
PATCH:

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"roles": ["iam.Roles.editor", "iam.Roles.comment_author"], "default_role": "iam.Roles.editor"}' \
  "https://facet.localhost:3443/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

Replace the role ids and the account id with your values. The answer is the
updated account document.

The rules the write enforces:

- Every role in the final array must exist and be live.
- Every role must sit at or below your level.
- `default_role`, when set, must be a member of `roles`.
- The hook deduplicates the array and keeps first-occurrence order.

:::tip
When the removed role was the account's `default_role`, the editor re-points
it to the first remaining role. When you grant a first-ever role to an account
with no default, that role becomes the default.
:::

### 3. Remove a role

Select **Remove** on the role row, or remove it from the array. The write
follows the same rules. You cannot remove yourself from a role above your
level — the target-protection rule blocks the write.

### 4. Check the result

Re-read the account:

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D"
```

The `roles` array shows the assigned ids. The member sees the new role at
their next sign-in or token refresh.

## How election works

### One role per request

Roles never merge. An account with `editor` and `viewer` acts under one of
them per request. The effective permission set is exactly one role's lines.
Cross-role scope reconciliation has no non-surprising answer, so Facet does
not attempt it. See [One role at a time](/admin/under-the-hood/one-role-at-a-time/) for the model.

### Election at sign-in

The sign-in request may carry the election in its `role` field, as a qualified
id:

```sh
curl -k -X POST -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"email": "ana@example.tld", "password": "PASTE-THE-PASSWORD", "role": "iam.Roles.editor"}' \
  "https://facet.localhost:3443/Api/iam/login"
```

The resolution order: the explicit election, then `default_role`, then the
first assigned role. An election of a role the account does not hold answers
`403`:

```json
{"error": "Role 'iam.Roles.manager' is not assigned to this account"}
```

The sign-in, refresh, and `me` responses all carry the pair:

- `active_role` — the elected role id.
- `available_roles` — the assigned role ids, the list a member can switch
  between.

A roleless account runs under the seeded `iam.Roles.anonymous` role. The
response shows `available_roles: []` with the anonymous role as `active_role`;
the workspace renders a no-role screen from that pair. See
[Roles and permissions](/admin/people/roles-and-permissions/) for what the
anonymous role controls.

### Switching during a session

A member switches role without signing in again. The refresh route accepts
the new election:

```sh
curl -k -X POST -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"role": "iam.Roles.viewer"}' \
  "https://facet.localhost:3443/Api/iam/refresh"
```

Two refusals exist, and they mean different things:

- `403 Role not assigned` — the account does not hold the role in its
  `roles` array. This is also the answer for a role name that exists but was
  never assigned, and for a name that does not exist at all.
- `403 Role not found or disabled` — the role is still in the account's
  array, but its document is gone. Fix the data, not the sign-in.

The workspace sidebar exposes the same switch in its **Switch Role**
menu. The new role's permission manifest rides the response, so the interface
narrows at once.

## Troubleshooting

### The assignment write answers `403`

Check the level: you can only assign roles at or below your elected level, and
you cannot edit an account whose role ceiling is above your own.

### The member sees nothing new after the assignment

Roles apply at the next sign-in or refresh. Ask the member to refresh, or
switch role once.

### Sign-in answers `403 Role not assigned`

The election names a role outside the account's `roles` array. Assign the role
first, or sign in without the `role` field.

### A member acts with unexpected rights

Ask which role they elected. One role applies per request; the rights may come
from a wider role than you expect. The audit log names the acting role on
every write — see [See who did what](/admin/history/audit/).

## Related

- [Roles and permissions](/admin/people/roles-and-permissions/) — what one role carries.
- [Manage accounts](/admin/people/accounts/) — create the account first.
- [One role at a time](/admin/under-the-hood/one-role-at-a-time/) — the one-role-per-request model.
- [See who did what](/admin/history/audit/) — the `acting_role` on every write.
- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — the member's sign-in steps.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [access-assignments.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/access-assignments.md).
- [Roles: who sees and does what](/discover/how-it-works/roles/)
