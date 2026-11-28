---
title: Manage accounts
description: Create an account, send the first password or invite link, control the status lifecycle, and delete or restore.
type: how-to
audience: [admin]
features: [IAM-06, IAM-07, FE-11]
verified_at: eee55a2
sidebar:
  order: 1
---

A new salesperson starts on Monday. Before she can sign in, she needs an
account, a first credential, and the right role. This page covers the account
and the credential. The role is a job for two other pages:
[Roles and permissions](/admin/people/roles-and-permissions/) defines one, and
[Assign roles](/admin/people/assign-roles/) puts it on the account.

## When to use this

- You add a new member or a machine identity.
- A member has no password, or forgot it before signing in once.
- You must stop an account from signing in, or bring a deleted account back.

## Before you start

- **The right page.** Open **Configure → Access → Accounts**. You need a role
  that grants `update` on `iam.Account` to create or edit accounts.
- **The credential right.** To send credentials you also need the named action
  `provision_credentials` on `iam.Account`. The seeded `iam.Roles.admin` role
  holds it through its `*` on `*.*` line.
- **The model.** Read [Roles and permissions](/admin/people/roles-and-permissions/)
  to learn how named actions work.

## The account document

| Field | Holds |
| --- | --- |
| `email` | The sign-in identifier. Unique among live accounts. |
| `name` | The display name. |
| `status` | `pending`, `active`, `suspended`, or `disabled`. |
| `roles` | The assigned roles, as qualified ids such as `iam.Roles.editor`. |
| `default_role` | The role used at sign-in when the account elects none. |
| `organizational_unit` | A folder-like path, for example `/engineering/`. Row scopes can match on it. |
| `service_account` | `true` marks a machine identity that signs in with API keys, not with a password. |
| `mfa_enabled` | `true` after the account finished MFA (multi-factor authentication) setup. |
| `must_change_pw` | `true` forces a password change at the next sign-in. |
| `federated_identities` | The single sign-on links, one per provider. See [Single sign-on (OIDC)](/admin/people/sso/). |

## The status lifecycle

<!-- d2
direction: down
create: "Create human account" {class: external}
pending: pending
active: active {class: ok}
suspended: suspended {class: warn}
disabled: disabled {class: danger}

create -> pending
pending -> active: first sign-in
active -> suspended
active -> disabled
suspended -> disabled
suspended -> active: edit status
disabled -> active: edit status
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c557983b-light.svg" alt="Create human account" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c557983b-dark.svg" alt="Create human account" loading="lazy" />
</div>

A human account you create stores `pending`, even when you submit `active`.
The account completes its bootstrap with its first credential, and that first
sign-in flips it to `active`. Two exemptions exist: a service account is
created `active`, and an account provisioned by single sign-on keeps
`active`. An explicit `suspended` or `disabled` status is kept as submitted.

A `pending` account may sign in with its first credential. A `suspended` or
`disabled` account may not sign in at all; sign-in answers `403 Account is
suspended` (or `disabled`).

## Steps

### 1. Create the account

1. Open **Configure → Access → Accounts** and select **New**.
2. Fill in `email`, `name`, and at least one role in `roles`.
3. Select **Save**.

Facet opens the standard document form route and stores the account.

<!-- screenshot: configure-accounts-new -->

### 2. Send the first credential

Open the account page and find the credential actions below the document
view. Two operator routes exist. Both require the `provision_credentials`
permission; the backend re-checks it on every call.

**Option A — temporary password**
(`POST /Api/iam/accounts/:id/temporary-password`):

- Select **Generate password**. Facet returns a 16-character password in four
  dashed groups, for example `K7M4-9XQ2-WBTD-H3PN`.
- Facet shows the password exactly once. Copy it and hand it to the person
  over a channel you already trust, such as a phone call. Nothing stores or
  emails the plaintext.
- The route sets `must_change_pw`, so the first sign-in asks for a new
  password before any session starts.
- The route refuses a service account and a `suspended` or `disabled` account
  with `422`. A `pending` account is accepted.
- The route also clears any pending invite link. The password replaces the
  link, so the older email stops working at once.

**Option B — invite link** (`POST /Api/iam/accounts/:id/invite`):

- Select **Send invite**. Facet mints a single-use link and emails it to the
  account address.
- The link stays valid for the credential-link window. The default is 24 hours
  (`iam.change_password_expiration`).
- The person opens the link and sets a password. Facet signs them in.
- A second invite replaces the first link. The older email stops working at
  once.
- The route refuses a service account with `422`. It accepts every other
  status, `suspended` and `disabled` included, so an operator can hand back
  access through the invite.
- The two routes differ on purpose. A temporary password is refused for a
  `suspended` or `disabled` account, because the person cannot sign in to use
  it. An invite is allowed, because the person can accept the link and set a
  password first. The account still needs `active` before the sign-in itself
  works.

:::caution
The temporary password and the invite link are credentials. Send the
password yourself; never forward the response body to a shared channel.
:::

### 3. Read the credential states

The credential panel on the account page reads
`GET /Api/iam/accounts/credential-states?id=…` when it loads. The route takes
one or more `id` query parameters and answers one entry per account, in a
`states` array. It is a batch read for the account tables: list the ids you
need, and get one state for each. The route needs `provision_credentials` on
`iam.Account`.

Each entry states:

| Field | Meaning |
| --- | --- |
| `has_password` | A password exists. |
| `must_change_pw` | The next sign-in forces a password change. |
| `mfa_enabled` | MFA is on. |
| `invite_pending` | An invite link is live. |
| `federated` | The account holds a single sign-on link. |

The action labels follow this state: **Send invite** or **Resend
invite**, **Generate password** or **Regenerate password**.

<!-- screenshot: configure-accounts-credentials -->

### 4. Suspend or disable an account

Edit the account document and set `status` to `suspended` or `disabled`. The
next sign-in attempt answers `403`. Existing sessions keep working until their
access token expires; see
[Sessions and lockouts](/admin/people/sessions-lockouts/).

A service account has no sign-in at all. It cannot log in with a password,
and password-reset requests for it are silent no-ops. Its purpose is to hold
API keys — see [API keys](/admin/apps-access/api-keys/).

### 5. Delete an account

Deleting an account is a normal document delete. Select the account, and
confirm the delete. The row becomes a tombstone; the history stays.

The role-authority guard adds one rule: you cannot delete an account whose
highest role level is above your own level. The delete answers `403` in that
case. See [Who can change roles](/admin/people/who-can-change-roles/) for
the guard.

### 6. Restore a deleted account

Open **Configure → Access → Accounts**, switch to the deleted list, and select
**Restore**. The API route is:

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" -d '{}' \
  "$(facet-cli host)/Api/iam/Account/01J8Z0A7G3Q5M2X9K4T6VBNR8D/restore"
```

Replace `01J8Z0A7G3Q5M2X9K4T6VBNR8D` with the account id. The call needs no
body. The answers:

| Answer | Meaning |
| --- | --- |
| `200` | The account is live again, with its pre-delete content. |
| `409` | The account is not deleted. |
| `404` | No mutation history exists for this id. |
| `403` | Your role lacks `update` on `iam.Account`. |
| `422` | Degenerate history: a delete with no change before it. |

A restore also brings back the child records the delete removed, when the
delete cascaded. See [Roll back a change](/admin/history/roll-back/) for the
mechanism.

## The first administrator

A fresh deployment has no account to sign in with. Create the first one on
the server:

```sh
facet seed:admin ops@your-company.tld
```

The command prints a one-time password once. Sign in with it, and Facet asks
for a new password. The command refuses to run when an account with that email
already exists; recover a lost password through the reset flow instead.

## Troubleshooting

### The credential buttons do not show

Your role lacks `provision_credentials` on `iam.Account`. Ask an
administrator, or add the line
`{"action": "provision_credentials", "on": "iam.Account"}` to your role.

### The invite email never arrives

1. Check the spam folder.
2. Check the mail settings of the instance.
3. Send the invite again; the new link replaces the old one.

### A password sign-in answers `403 Account is suspended`

An administrator set the status. Ask them to return it to `active`.

### The restore answers `409`

The account is not deleted. A restore only works on a tombstone.

## Related

- [Roles and permissions](/admin/people/roles-and-permissions/) — the named actions this page uses.
- [Assign roles](/admin/people/assign-roles/) — the `roles` array and `default_role`.
- [Require MFA](/admin/people/mfa/) — the `mfa_enabled` flag and the MFA reset action.
- [API keys](/admin/apps-access/api-keys/) — how service accounts authenticate.
- [Single sign-on (OIDC)](/admin/people/sso/) — the `federated_identities` field and JIT provisioning.
- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — the account holder's side of the flows.
- Internals on GitHub: [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md), [access-accounts.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/access-accounts.md).
- [People and access](/admin/people/)
