---
type: how-to
title: Your settings and API keys
description: Set your timezone and language, connect an AI agent, manage the API keys that act as you, and sign devices out.
audience: [user]
features: [FE-17, PLT-17, IAM-09, IAM-11]
sidebar:
  order: 6
verified_at: eee55a2
---

The dates on your bookings show in the wrong timezone, or a report tool
needs its own way into Facet. The settings pages fix the first and enable
the second. They hold your personal preferences, the keys that let a
machine act as you, and the list of devices signed in as you. Everything
here belongs to your account only — other people keep their own settings.

## Before you start

- [Sign in and secure your account](/use/first-day/sign-in/) — you need a signed-in session to reach the settings.

![The settings page: chapters for General, Notifications, MCP endpoints and Active sessions on the left.](/screens/use/account-1.png)

## Open your settings

Select your name at the bottom of the sidebar. The menu opens:

- **My settings** — the page this article walks through.
- **API keys** — for machine access, covered below.
- **Webhooks** — send a message to another system when records change.
- **Switch Role** — appears when you hold two or more roles.
- **Logout**.

On the settings page, the chapters sit on the left: **General**,
**Notifications**, **MCP endpoints**, and **Active sessions**. Accounts
with the built-in administrator role also see **Welcome tour**. Each change
saves at once — the field flashes **Saved**.

Your administrator manages your name and email — they are not on this
page. The same goes for your password: you change it only when an
administrator issues you a temporary password and Facet asks at sign-in.
See [Sign in and secure your account](/use/first-day/sign-in/).

## Set your timezone

In **General**, open **Timezone** and pick one:

- **Automatic** — Facet uses the timezone of the device you sign in from.
- **Server default** — Facet uses the default of this Facet installation.
- A named zone from the list, for example `Europe/Paris`.

The **Current time** line previews your choice right below. Facet shows
dates and times everywhere in the app in this timezone. The choice applies
to you only — a colleague in another office sees their own.

## Set your language

In **General**, open **Language** and pick **English**, **Français**, or
**Server default**. The page reloads with the new language.

## Copy an MCP endpoint

In **MCP endpoints**, Facet lists one address for each role you hold. An AI
agent — a helper program such as Claude Desktop — connects to Facet through
this address. It then works as that role, under the same rules as you. On
first connect, the agent signs in through a browser window. Select **Copy**
to copy the address. When no role of yours exposes an endpoint, the page
says so.

## Your API keys

An API key lets a program — a script, a report tool, an integration — call
Facet's interface as you, through one role you pick. The program can then
do everything that role allows, no more. That is the point and the risk:
whoever holds the key acts as you. Treat a key like a password. Paste it
straight where the program needs it, never send it by chat or email, and
revoke it when the work is done. Your administrator sets what roles may do;
see [Roles: who sees and does what](/discover/how-it-works/roles/).

![The API keys page: the list of keys with name, role, last used and status.](/screens/use/account-2.png)

**Create a key**

1. Open the account menu and select **API keys**.
2. Select **Create key**.
3. In **Name**, type a label. Only you see it — up to 100 characters.
4. In **Role**, pick one of your assigned roles. The key can do only what
   this role allows.
5. In **Expires**, pick a date, or leave it empty for a key that never
   expires.
6. Select **Create key**. Facet shows the full key once — select **Copy**
   and store it in a safe place.

:::caution
The full key is shown once and cannot be retrieved again. If you lose it,
create a new key.
:::

**Revoke a key**

1. In the key list, select **Revoke** on the key's row.
2. Confirm with **Revoke key**. Programs using the key stop working at
   once, and this cannot be undone.

The row stays in the list with the **Revoked** badge. Each row shows the
key's name, its short prefix, the role, **Last used**, **Expires**, and a
status: **Active**, **Expired**, or **Revoked**. A key with no expiry shows
**Never**.

A key also stops working when it expires, when you lose the role it acts
as, or when your account is disabled. The full key always starts with
`fct_` — the detail pages cover how a program sends it:

- [API keys (admin)](/admin/apps-access/api-keys/) — how keys work, for the
  person who manages access.
- [Backend apps and service accounts](/build/apps/connect/backend-apps/) —
  the machine-identity route developers take.

## Sign a device out

In **Active sessions**, Facet lists every device or app signed in as you.
Each row shows the device or app, the network address, the role the session
runs, and the **Created** and **Last used** times. A row without device
details shows **Unknown device**.

**Sign out one device.** Select **Revoke** on its row and confirm with
**Revoke session**. The device signs out at its next refresh.

**Sign out every other device.** Select **Revoke other sessions** and
confirm with **Revoke others**. Your current session stays signed in, and
Facet reports how many sessions it revoked.

Facet does not cut a device off mid-action: a connection already open keeps
working for a few minutes, then the device must sign in again.

## Troubleshooting

### The API keys entry is missing from the account menu

Your active role does not allow API access. Open the account menu and try
**Switch Role**, or ask your administrator to allow API access on one of
your roles.

### You cannot create a key

Check the form. The role must be one of your assigned roles, and it must
allow API access. The expiry date must be in the future.

### A key stopped working

Open **API keys** and check the status. **Revoked** and **Expired** keys
never work again — create a new key. If the status is **Active**, check
with your administrator whether the role still allows API access.

### A device still works for a short time after you revoke it

An already-open connection keeps working until it ends — a few minutes by
default. After that, the device must sign in again.

## Related

- [Sign in and secure your account](/use/first-day/sign-in/) — sign-in,
  two-factor setup, and the password change flow.
- [Notifications](/use/notifications/) — what the in-app notifications
  toggle controls.
- [Connect an AI agent](/build/first-hour/connect-an-agent/) — put an MCP
  endpoint to work.
- [Roles: who sees and does what](/discover/how-it-works/roles/) — what a
  role allows, for you and for your keys.
- [Security and governance](/discover/security/)
- [Account settings keys](/reference/account-settings-keys/)
