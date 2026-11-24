---
title: Build your first domain
description: Model an Inventory domain in the Builder — doctypes, fields, publish, kanban.
audience: [author]
features: [DOM-01, DOM-02, DOM-03, DOM-04, DOM-16, DOM-21, FE-10, FE-03]
sidebar:
  order: 2
verified_at: e7c24a4
---

You model a small business area end to end: a domain named **Inventory** with
two doctypes, one reference between them, and a kanban board your team can
read at a glance. You do it all in the Builder — Facet's draft-and-publish
modeling surface. No code, no schema files.

This tutorial continues from [Run Facet in 15 minutes](/tutorials/t1-run-facet/).
Sign in as the admin you created there.

## What you need

- A running instance with the core schema seeded (T1 leaves you there).
- An admin session in the browser.

## Step 1 — Create the draft

Open **Builder** in the sidebar. Click **New domain** and fill the dialog:

- **Label**: `Inventory`
- **Domain id**: `inventory` (the dialog fills it from the label)

Click **Create draft**.

The draft gets a temporary id that starts with `_` (for example
`_06h041qm5r0b`). That id is scratch — the publish step asks for the final
name, and only lowercase letters, digits, and dashes are allowed there.

### Checkpoint

The Builder opens the draft's Overview. The header shows
**Inventory**, the `_`-prefixed id, and a **Draft** badge. The tab strip
reads Overview / Doctypes / Editors / Grants / Check.

## Step 2 — Add the Supplier doctype

Click **Add doctype** in the sidebar, enter `Supplier`, and click
**Create doctype**. The doctype editor opens on the Fields tab.

Click **Add field**. A field named `new_field` appears. Set it up in the
right pane:

- **Key**: `name`
- **Type**: String
- **Title**: `Name`
- **Required**: on

Click **Save** in the header. The flash message **Saved** confirms the
write.

### Checkpoint

The Fields tab lists one field: `name` (string, required).

## Step 3 — Add the Item doctype

Click **Add doctype** again, enter `Item`, and click **Create doctype**.
Add four fields, saving after each set of edits:

| Key          | Type     | Settings                                                |
| ------------ | -------- | ------------------------------------------------------- |
| `name`       | String   | Title `Name`, **Required** on                           |
| `quantity`   | Integer  | Title `Quantity`                                        |
| `status`     | Enum     | Title `Status`; values `in_stock` (In stock), `low` (Low), `ordered` (Ordered) |
| `supplier`   | Reference | Title `Supplier`; Target doctype `Supplier`            |

Two of these deserve a word:

- **Enum** holds a fixed value set. Type each value key and press the add
  control; `In stock` gets the label, and the first value is the default.
  The status field drives the kanban lanes later, so an enum is the right
  type — a plain string cannot group a board.
- **Reference** points at another doctype. The editor qualifies the bare
  target to `inventory.Supplier` (the publish-target domain, not the draft
  id) — that qualified form is what the publish step needs.

Add one more field for later: **Key** `cost_price`, **Type** Integer, Title
`Cost price`. Save.

### Checkpoint

The Fields tab lists five fields: `name`, `quantity`, `status`, `supplier`,
`cost_price`.

## Step 4 — Read the diagnostics

Open the **Check** tab. The Builder runs the definition diagnostics
automatically and shows one of two things:

- **"No problems detected — ready to publish."** — you are done here.
- An issue list grouped **By doctype**. Fix what it names and click
  **Refresh**.

:::note
Warnings do not block a publish. One class is worth fixing before you go
live anyway: a reference whose target is missing breaks every future write
to that field.
:::

### Checkpoint

The Check tab shows the clean state, or only notices you understand.

## Step 5 — Publish

Click **Publish** in the top bar. The dialog asks for the **Target domain
name** — it is prefilled with `inventory`. Confirm with **Publish**.

Publishing copies the structure into a fresh live domain named `inventory`
and drops the draft. The reference targets are rewritten from the draft id
to the real domain name as part of the copy.

### Checkpoint

The dialog closes and the Builder landing replaces the draft view. Open the
workspace sidebar: **Inventory** is there with its two doctypes.

## Step 6 — Create some records

Click **Inventory → Item** in the sidebar. The doctype has no view yet: the
starter screen shows one card per layout. Pick **Table** to create the
first view — name it `All items`, keep the suggested columns, and save.
The list opens on the new view. Use **New** (the list's create action)
three times:

| Name           | Quantity | Status    | Supplier    | Cost price |
| -------------- | -------- | --------- | ----------- | ---------- |
| Standing desk  | 12       | In stock  | Acme Corp   | 240        |
| Office chair   | 3        | Low       | Globex Ltd  | 95         |
| Whiteboard     | 0        | Ordered   | Acme Corp   | 40         |

Create the suppliers through **Inventory → Supplier** first (Acme Corp,
Globex Ltd), so the Item form can pick them in the supplier field.

### Checkpoint

The Item table shows three rows. Each row's label comes from the
`display_name` template — the document label is the item's name.

## Step 7 — Add a kanban view

Stay on the Item list. At the right end of the view tab strip, click the
**+** control (**Create a new view**). The wizard walks you through two
steps:

1. **Choose a view type** — pick **Kanban** ("Cards grouped into lanes"),
   then **Next**.
2. **Name and grouping** — Name: `Board`. **Board mode**: **By field
   values**. **Group by**: `status`. Then **Create view**.

### Checkpoint

A new **Board** tab opens next to **All items**. Three lanes — In stock, Low,
Ordered — each carrying the cards whose status matches. The lane filter is
live: the In stock lane lists exactly the Standing desk.

## Result

You built and shipped a domain:

- a live `inventory` domain with `Supplier` and `Item` doctypes;
- five typed fields on Item, including a reference and an enum;
- three records in a table view;
- a kanban board grouped by status.

Every step ran on a draft first — you can change the model the same way
any time: Builder → **Edit existing** → Inventory.

## Troubleshooting

### The publish dialog shows warnings

Open the **Check** tab, fix what the diagnostics name, and publish again.
The dialog lists the same warnings with their doctypes.

### The kanban Group by list has no status field

The picker offers only enum and boolean fields that carry an equality
filter. If you created `status` as a string, switch the field's type to
Enum in the Builder (Edit existing → Item → Fields), publish, and the
field appears.

### The reference field shows no suppliers in the form

The Item form lists only saved suppliers. Create them on the Supplier list
first.

### A field edit did not stick

Field edits are local until the header **Save**. The flash message
**Saved** is the confirmation — re-check the field and save again.

## Next steps

- [Give your team access](/tutorials/t4-team-access/) — scope this
  inventory for a sales colleague.
- [Draft and publish lifecycle](/build/domains-drafts-editors/) — the full
  model, including publishing over a live domain.
- [Field types](/build/field-types/) — every type and its settings.
