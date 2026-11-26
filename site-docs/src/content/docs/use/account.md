---
type: how-to
title: Your settings, sessions and API keys
description: Set your timezone and language, review your sessions, and manage API keys for machine clients.
audience: [user]
features: [FE-17, PLT-17, IAM-09, IAM-11]
sidebar:
  order: 6
verified_at: 49d7c7e5
---

The Settings pages hold your personal preferences, your application
programming interface (API) keys, and your active sessions. Everything here
belongs to your account only. Other accounts keep their own settings.

## Before you start

- **An account.** You need a signed-in account. Sign-in help lives in
  [Sign in, MFA, reset your password](/use/first-day/sign-in/).
- **Your own settings only.** Your administrator manages roles and account
  data. This page covers only your personal settings.

## Steps

### 1. Open your settings

1. Select your account name at the bottom of the sidebar.
2. Select **My settings**.

The page shows chapters on the left: **General**, **Notifications**, **MCP
endpoints**, and **Active sessions**. Accounts with the built-in
administrator role also see **Welcome tour**. Each change saves at once; the
field flashes **Saved**.

The same menu opens **API keys** (below) and **Webhooks**. It holds **Switch
Role** when you hold two or more roles, and **Logout**.

### 2. Set your timezone

In **General**, open **Timezone** and pick one option:

- **Automatic** — Facet uses the timezone of the device you sign in from.
- **Server default** — Facet uses the default of this Facet instance.
- A named zone from the list, for example `Europe/Paris`.

The **Current time** line under the selects previews your choice. Facet shows
dates and times across the app in this timezone. Your choice applies to you
only.

### 3. Set your language

In **General**, open **Language**. Pick **English**, **Français**, or **Server
default**. The page reloads with the new language.

### 4. Control in-app notifications

In **Notifications**, use the **In-app notifications** toggle. It shows or
hides notifications in the top bar bell. When you turn notifications on
again, you see the notifications that arrived while they were off.

:::note
Facet delivers notifications in the app only. There is no email delivery.
:::

### 5. Replay the welcome tour

Accounts with the built-in administrator role see the **Welcome tour**
chapter. Turn on **Show the welcome tour**. The tour opens at your next app
load.

### 6. Copy an MCP endpoint

In **MCP endpoints**, Facet lists one URL for each role you hold. A Model
Context Protocol (MCP) agent connects to Facet through this URL. The agent
acts as that role. On first connect, the agent signs in through a browser
flow. Select **Copy** to copy the URL.

### 7. Manage your API keys

An API key lets a machine client call the Facet API. The key acts as you,
through one of your roles. Open the account menu at the bottom of the sidebar
and select **API keys**.

**Create a key**

1. Select **Create key**.
2. In **Name**, type a label. Only you see it. Up to 100 characters.
3. In **Role**, pick one of your assigned roles. The key can do only what
   this role allows.
4. In **Expires**, pick a date. Leave it empty for a key that never expires.
5. Select **Create key**.
6. Facet shows the raw key once. Select **Copy** and store it in a safe
   place.

:::caution
Facet shows the raw key once. You cannot retrieve it later. If you lose it,
create a new key.
:::

**Use a key**

The client sends the key in the `Authorization: Bearer` header. A real key
starts with `fct_`. This example calls the Facet API with a key:

```sh
export FACET_API_KEY="fct_paste-the-key-you-copied"
curl -k https://facet.localhost:3443/Api/iam/me \
  -H "Authorization: Bearer $FACET_API_KEY"
```

Facet answers with your account profile as JSON. The `-k` flag skips the TLS
certificate check of the development address.

**Revoke a key**

1. In the key list, select **Revoke** on the key row.
2. Confirm with **Revoke key**.

Clients that use the key stop working at once. The row stays in the list
with the **Revoked** badge. The list shows each key's name, prefix, role,
**Last used** time, **Expires** time, and status: **Active**, **Expired**, or
**Revoked**. A key with no expiry date shows **Never**.

:::note
A key also stops working when it expires, when you lose the role, or when
your account is disabled.
:::

### 8. Review your active sessions

In **Active sessions**, Facet lists your current sessions, one row per device
or app. Each row shows the device or app, the IP address, the role the
session runs, and the **Created** and **Last used** times. A row without
device details shows **Unknown device**.

**Sign out one device**

1. Select **Revoke** on the session row.
2. Confirm with **Revoke session**.

The device signs out at its next refresh.

**Sign out every other device**

1. Select **Revoke other sessions**.
2. Confirm with **Revoke others**.

Your current session stays signed in. Facet reports how many sessions it
revoked. An empty list shows "No active sessions."

:::note
An access token already issued keeps working until it expires, for minutes
by default. After that, the device must sign in again.
:::

## Troubleshooting

### The API keys entry is missing from the account menu

Your active role does not allow API access. Open the account menu and try
**Switch Role**, or ask your administrator.

### You cannot create a key

Check these fields and try again:

1. The role must be one of your assigned roles.
2. The role must allow API access.
3. The expiry date must be in the future.

### The key does not work

1. Check that the client sends the full key in the `Authorization: Bearer`
   header.
2. Open **API keys** and check the status. **Revoked** and **Expired** keys
   never work again. Create a new key.

### A device still works for a short time after you revoke it

An access token already issued stays valid until it expires, for minutes by
default. After that, the device must sign in again.

## Related

- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — sign-in, two-factor setup, and password reset.
- [Notifications](/use/notifications/) — what the in-app notification preference controls.
- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — how a session or an API key resolves to one role.
- [Roles, levels and the authority guard](/admin/people/who-can-change-roles/) — what a role can allow for you and for your keys.
- [Reference](/reference/) — the API endpoints that a key can call.
