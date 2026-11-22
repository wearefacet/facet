---
title: Give your team access
description: Invite a colleague, create a scoped Sales role, and hide a sensitive field.
audience: [admin]
features: [IAM-06, RBC-01, RBC-02, RBC-04, RBC-05, FE-11]
sidebar:
  order: 3
verified_at: e7c24a4
---

You hand a colleague access without handing them everything. Sam joins the
sales team: they may read the items that are in stock, never see what those
items cost, and touch nothing else. You set that up with an account, a
role, a row scope, and a field tag.

This tutorial continues from [Build your first domain](/tutorials/t2-first-domain/).
Sign in as the admin. The examples use the `inventory` domain from that
tutorial.

## What you need

- An admin session in the browser.
- The `inventory` domain with the `Item` doctype, its `status` enum field,
  and its `cost_price` field.
- One command-line step uses `curl` — nothing else leaves the browser.

## Step 1 — Create the account and hand over a password

Open **Configure → Access → Accounts**. Click **New account** and fill the
form:

- **Name**: `Sam Sales`
- **Email**: `sam@example.tld`

Save. The account starts with status `pending` — it holds no credential
yet.

Open the new account. Below the document view sits the **Credentials**
panel. Click **Generate password**. Facet shows the panel
**Temporary password generated** with the password and a copy button:

```text
JYJA-TXKN-94GS-DVDJ
```

:::caution
The password is shown only now. Pass it to Sam over a safe channel — a
password manager, not email. If it is lost, click **Regenerate password**
and hand over the new one.
:::

:::tip
**Send invite** is the alternative when your instance has working SMTP:
Facet emails Sam a single-use link instead. This tutorial uses the
generated password so it works on a machine without a mail relay.
:::

### Checkpoint

The account row shows Sam with a credential in place, and you hold the
temporary password.

## Step 2 — Declare the row scope on the doctype

A row scope is a named filter that lives on the doctype definition. The
Builder does not edit scopes yet, so this one step runs in the terminal:
you fetch the current definition, add a `scopes` block, and write it back.

Sign in on the API with your admin account (the same password you use in
the browser):

```sh
curl -sk -c facet-cookies.txt -X POST https://facet.localhost:3443/Api/iam/login \
  -H 'Content-Type: application/json' -H 'X-Requested-With: fetch' \
  -d '{"email": "ops@your-company.tld", "password": "<your-admin-password>", "cookie": true}'
```

Fetch the current Item definition to a file:

```sh
curl -sk -b facet-cookies.txt https://facet.localhost:3443/Api/core/DocType/inventory.Item \
  | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['data'], indent=2))" \
  > item.json
```

Open `item.json` and add the `scopes` block at the top level (next to
`fields`), then save:

```json
"scopes": {
  "sellable": {
    "description": "Items that are in stock and ready to sell",
    "where": { "status": "in_stock" }
  }
}
```

Write the definition back:

```sh
curl -sk -b facet-cookies.txt -X PUT https://facet.localhost:3443/Api/core/DocType/inventory.Item \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  --data @item.json
```

The response repeats the stored definition. Adding scopes changes no data
shape, so no schema step is needed.

:::note
The `where` value `"in_stock"` is a plain equality on the status field.
Scopes also understand `"$self"` (the acting account) and other tokens —
see [Row scopes](/govern/row-scopes/).
:::

### Checkpoint

Read the definition back and find the scope:

```sh
curl -sk -b facet-cookies.txt https://facet.localhost:3443/Api/core/DocType/inventory.Item \
  | grep -o '"scopes":.*' | head -c 160
```

```json
"scopes": {"sellable": {"where": {"status": "in_stock"}, "description": "Items that are in stock and ready to sell"}}
```

## Step 3 — Tag the cost field

Cost data must not reach Sam. Sensitivity tags mark a field; a role that
does not hold the tag cannot see the field.

Open **Builder → Edit existing** and pick **Inventory** — the Builder
copies the live domain into a fresh draft. Open the Item doctype, select
the `cost_price` field, and scroll to the **Access** section:

- **Sensitivity tags**: type `finance` and add it.

Save the doctype, then click **Publish**. The dialog shows the existing
domain name `inventory` — confirm with **Publish over inventory**. Adding a
tag changes no data shape, so the publish goes through without a schema
version bump.

### Checkpoint

The draft is gone. On the live domain, `cost_price` carries the `finance`
tag, and the `sellable` scope survived the copy — both ride along through
draft and publish.

## Step 4 — Create the Sales role

Open **Configure → Access → Roles**. Click **New role** and fill the
dialog:

- **Name**: `sales` (lowercase — role names allow letters, digits, and
  underscores)
- **Level**: `10`
- **Description**: `Sees sellable stock, no cost data`

Click **Create role**. The role starts with zero permissions — you grant
them next.

### Checkpoint

`sales` appears in the Role picker with **0 members**.

## Step 5 — Grant read, scoped to the sellable rows

With `sales` selected in the Role picker, find the **inventory** section
and expand it. On the **Item** row, open the scope picker next to
**Read**. The picker lists **None**, **All**, and **Custom scopes** — pick
**sellable**. Leave every other action on **None**.

Click **Save**.

### Checkpoint

The Item row shows an active-permission badge, and the inventory section
reads one doctype with permissions.

## Step 6 — Assign the role

Click **Manage members** in the role bar. On the Assignments page (the
**By role** view), find **Add an account to this role…**, enter
`sam@example.tld`, and click **Add to role**.

The first role on an account becomes its default role — Sam signs in as
`sales` without picking anything.

### Checkpoint

The role shows **1 member**.

## Step 7 — See Facet through Sam's eyes

Sign out (or open a private browser window) and sign in as
`sam@example.tld` with the temporary password. Facet asks Sam to set a real
password first — same flow as your own first login.

What Sam sees:

- The sidebar shows **Inventory → Item** and nothing else. The sales role
  grants no other surface.
- The Item list shows **one row**: Standing desk. The Office chair (Low)
  and Whiteboard (Ordered) are outside the `sellable` scope — a filtered
  list hides them, and a direct open answers not-found.
- The table, the form, and the document view have **no Cost price
  column**. The field does not exist for this role.

Sign back in as the admin and open the same list: three rows, cost prices
visible. That contrast is the whole access model working.

### Checkpoint

Sam's list differs from the admin's list exactly in the two dimensions you
configured — rows and fields.

## Result

You set up governed access end to end:

- an account handed over with a one-time password, changed at first login;
- a `sellable` row scope on Item, referenced by the role;
- a `finance` tag on `cost_price`, invisible to roles without it;
- a `sales` role with one scoped read grant, assigned to Sam;
- every step of the way recorded in the audit trail — Sam's login and
  password change are on record under Configure → Audit.

## Troubleshooting

### The scope picker shows no sellable entry

The scope name must exist on the doctype before the role can reference it.
Repeat step 2 and check the response of the final PUT — the scopes block
must come back in the stored definition.

### The publish of the tagged field demands a schema version

Something else changed in the draft. Publish accepts same-version
overwrites only when the data shape is unchanged — tags and scopes are
metadata and ride along freely, but a changed field type or a new required
flag needs the version gate. Discard the draft and redo step 3 alone.

### Sam sees an empty Item list

The role holds the read grant, but no row matches the scope yet. As the
admin, set an item's status to **In stock**, then have Sam reload.

### Sam logs in to a "No role assigned" screen

The role assignment did not land. Open Configure → Access → Accounts,
open Sam, and check the assigned roles on the account.

### A new field vanishes from Sam's view after tagging

That is the tag at work. Every role that should see the field needs the
tag in its **Visibility tags** (role → Details) — the check fails closed.

## Next steps

- [Row scopes](/govern/row-scopes/) — the full scope grammar: `$self`,
  context sets, operator suffixes.
- [Field visibility tags](/govern/field-visibility-tags/) — tag
  mechanics and the fail-closed rule.
- [Assigning roles and election](/govern/assigning-roles-election/) —
  multi-role accounts and level ceilings.
