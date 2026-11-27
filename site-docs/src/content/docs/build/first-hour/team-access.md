---
type: tutorial
title: Give your team access
description: Invite a colleague, hand the warehouse role to them, and see what the finance tag and a row scope hide.
audience: [admin]
features: [IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11]
sidebar:
  order: 5
prev: /build/first-hour/first-app/
next: /build/first-hour/connect-an-agent/
verified_at: eee55a2
---

A new hire joins the Brightwater warehouse: Pat Mardell. He needs the
equipment domain — items, categories, maintenance tickets — and he must
never see what the equipment cost. Tom, the salesperson, already works in
Facet: he sees only the clients he manages, never the others. This
tutorial invites Pat, hands him the warehouse role, and finishes by
looking at the data through the team's eyes.

Two rules do the work, both set once and enforced everywhere — lists, the
workspace, the API, the assistant:

- A **role** collects permissions: which doctypes a person may read and
  change. Pat gets the `warehouse` role.
- A **field tag** marks a sensitive field. A role that does not hold the
  tag cannot see the field. `purchase_price` carries the `finance` tag;
  only `manager` holds it.
- A **row scope** filters which rows a role reaches. Tom's `sales` role
  reads companies only through the `my_clients` scope — the companies where
  he is the account manager.

**You will build:** one account with the `warehouse` role, verified against
the field tag; Tom's scoped list, verified against the row scope.
**Time:** about 15 minutes.
**You need:**

- [tutorial 1](/build/first-hour/run-facet/) — a running
  instance with an admin account (`admin@example.tld` / `admin` on a
  `setup-dev` instance). The Brightwater example is loaded
  ([tutorial 2](/build/first-hour/first-domain/) does this; the example's
  `load.sh` does it too).
- `curl` and `pnpx @facetapp/cli` for the API step, which pins two API keys
  to two roles.

## 1. Create Pat's account

Sign in as the admin and open **Configure → Access → Accounts**. Click
**New account** and fill the form — **Email** and **Display Name** are
the only required fields:

- **Email**: `pat@brightwater.example`
- **Display Name**: `Pat Mardell`

![The New Account form with the email and display name filled in. Status starts at Active and the organizational unit at /.](/screens/build/team-access-3.png)

Click **Create**. The account page opens with the status *pending* — the
account exists, but holds no credential yet.

Find the **Credentials** panel and click **Generate password**. Facet
shows the temporary password once:

![The Temporary password generated dialog: a one-time password with a Copy button, and a note that it is shown only now.](/screens/build/team-access-4.png)

:::caution
Pass the password to Pat over a safe channel — a password manager, not
email. It is shown once. If it is lost, click **Regenerate password** and
hand over the new one. If your instance has working SMTP, **Send
invite** is the alternative: Pat gets a single-use link instead.
:::

Pat changes the password at his first sign-in — the same **Set a new
password** screen you saw in tutorial 1.

## 2. Assign the warehouse role

Open **Configure → Access → Assignments** and switch to **By account**.
Pick Pat in **Pick an account…** — the *Roles assigned to account* panel
starts empty. Open the **Add a role to this account…** picker, choose
**Warehouse**, and click **Assign role**:

![The Assignments page in By account mode: the Warehouse role assigned to Pat Mardell, with the default badge.](/screens/build/team-access-5.png)

The row carries a *default* badge — the first role on an account becomes
its default role. Pat signs in as `warehouse` without picking anything.

The role already exists in the Brightwater example (tutorial 2 or
`load.sh` created it). Its permissions:

| On | Actions |
|---|---|
| `equipment` (all doctypes) | read, create, update, delete |
| `rentals.Booking`, `rentals.BookingLine` | read |
| `clients.Company`, `clients.Contact` | read |
| `core.Comment`, `core.Attachment` | read, create, update, delete |

And one absence that carries the tutorial: `visible_tags` lists `default`
but not `finance`.

## 3. See the field tag work

Pat opens an item — say **Main tent 10x15** — and the page shows Name,
Status, Category, Serial number:

![An item page as the warehouse user: name, status, category and serial number, with no purchase price.](/screens/build/team-access-2.png)

There is no purchase price on the page. The field does not exist for this
role — not hidden with a blank, absent.

The same request from the API shows the same filter. Every API call presents its own credential, and the CLI issues one pinned to
a role you hold. Keep the admin key from `setup-dev` under a name of its own,
then pin a `warehouse` key for Pat — the CLI asks Nadia nothing, because the
credential is per role, not per person:

```sh
cd /path/to/your/setup-dev/folder
AP_ADMIN_KEY=$(pnpx @facetapp/cli apikey)
PAT_KEY=$(pnpx @facetapp/cli connect --role warehouse >/dev/null && pnpx @facetapp/cli apikey)
HOST=$(pnpx @facetapp/cli host)
```

`connect` signs in as the admin in your browser — choose the admin role on the
consent screen — and stores a key pinned to `iam.Roles.warehouse`. A bearer
request carries no cookie, so it needs no `X-Requested-With` header. As Pat:

```sh
curl -skg -H "Authorization: Bearer $PAT_KEY" \
  "$HOST/Api/equipment/Item/EQ-2026-0001"
```

```json
{"data":{"name":"Main tent 10x15","status":"out","category":"equipment.Category.…","serial_number":"TN-10015-A"}}
```

As Nadia (the `manager` role, which holds the `finance` tag) — pin a
`manager` key the same way:

```sh
NADIA_KEY=$(pnpx @facetapp/cli connect --role manager >/dev/null && pnpx @facetapp/cli apikey)

curl -skg -H "Authorization: Bearer $NADIA_KEY" \
  "$HOST/Api/equipment/Item/EQ-2026-0001"
```

```json
{"data":{"name":"Main tent 10x15","status":"out","category":"equipment.Category.…","serial_number":"TN-10015-A","purchase_price":{"value":"4800.00","currency":"EUR"}}}
```

One field, two answers. The check runs on every read path — list, single
read, search, export — so a role that lacks the tag cannot reach the value
anywhere.

## 4. See the row scope work

Tom signs in and opens **Clients → Company**. The list shows five rows:

![Tom's clients list shows exactly five companies, the ones he manages.](/screens/build/team-access-1.png)

Brightwater's ten companies are in the database; Tom reaches the five where
he is the account manager. The rule lives on his `sales` role: the read
permission on `clients.Company` carries the `my_clients` scope, which the
example defines on the Company doctype as "the companies whose account
manager is me" (`account_manager = $self`).

A direct open of another company's URL answers *not found* — Facet does
not confirm that the row exists.

## 5. Check the record

Open **Configure → Audit** and find the day's entries: Pat's account
created, the Warehouse role assigned, his first sign-in and password
change. Every
access decision in this tutorial left a trace — that is the point of doing
access work in Facet rather than in a spreadsheet of who-may-what.

## What you learned

- A role is a set of permissions; an account holds at least one, and the
  first becomes the default.
- A field tag hides a field from every role that does not hold the tag —
  in the UI and in the API.
- A row scope limits which rows a permission reaches; a direct open of a
  row outside the scope answers not found.
- The audit trail records the account and role changes you made.

## Related

- [Roles and permissions](/admin/people/roles-and-permissions/) —
  the full permission model.
- [Hide a field from some roles](/admin/people/hidden-fields/) — field
  tags in depth, including the fail-closed rule.
- [Show each role only its own rows](/admin/people/row-scopes/) — the
  scope grammar: `$self`, context sets, operators.
- [Assigning roles](/admin/people/assign-roles/) — multi-role accounts and
  how the acting role is chosen.
- [People and access](/admin/people/)
- [Permission line syntax](/reference/permission-syntax/)
## Next

Your team works in Facet and your data is governed. In
[Connect an AI agent](/build/first-hour/connect-an-agent/) you attach an
MCP client to the same roles, so an assistant answers questions under the
same rules — and leaves the same audit trail.
