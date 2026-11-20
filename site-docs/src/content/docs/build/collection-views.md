---
title: Collection views
description: Give a doctype's list page saved table, kanban, and calendar views.
audience: [author]
features: [DOM-21]
sidebar:
  order: 15
verified_at: f1409cdc
---

A list page shows one tab per saved view. Each view carries a name and a surface: a table with chosen columns, a kanban board with lanes, or a calendar placed on dates. Views are documents on the doctype, so you decide which tabs every user sees.

## When to use this

- The default column set does not fit the work of a team.
- A team works on documents as cards, moved over a status or a value.
- A schedule matters more than a row order, for example planned visits.

## Before you start

- **Create rights.** You need the right to create views on the doctype. The plus control on the tab strip is hidden without it.
- **Good candidates.** Know which fields make good columns, lanes, or calendar dates.

## Steps

### 1. Open the view editor

Open the doctype's list page. The tab strip above the table lists the saved views. Select the plus control at the end of the tab strip (**Create a new view**) to open the view editor.

### 2. Choose the surface

| Surface | You configure |
| --- | --- |
| `table` | An ordered column list. Each column has a key, a label, and an optional width. |
| `kanban` | A `group_by` field with `mode: values`, or fixed lanes with a filter each (`mode: custom`). |
| `calendar` | A `discriminator` date field, an optional `end_field`, a `color_by` field, and a `title_template` for the chips. |

### 3. Set columns or lanes

For a table, add one entry per column in display order. For a kanban, either group by an enum field so Facet builds a lane per value, or write your own lanes with a filter each. For a calendar, pick the date field that places an entry, and optionally a second date as the end of a range.

:::tip
The title of a calendar entry can carry field values. Write a Jinja2 template in `title_template`, for example `{{ title }}`. Only fields of the doctype are allowed there.
:::

### 4. Choose who sees the view

A view is **general** (every reader of the doctype sees it) or **personal** (only you see it). The editor shows the toggle when your role may create general views. The choice is fixed after you save.

:::caution
A view cannot change between personal and general later. Create a new view
and delete the old one.
:::

### 5. Save, share, and pin

Save the view. Its tab appears above the table, and the link in the address bar deep-links to it. You can pin a tab so it stays at hand; a pin is a personal preference and works for general views too.

## Example

A `crm.Deal` doctype carries a general table view named **All Deals**. This is its complete configuration:

```yaml
content:
  name: All Deals
  surface: table
  config:
    columns:
      - key: title
        label: Deal
      - key: value
        label: Value
        width: 120px
      - key: status
        label: Status
        width: 110px
      - key: probability
        label: Prob.
        width: 90px
      - key: expected_close_date
        label: Expected Close
        width: 150px
meta:
  parent_id: crm.Deal
```

The list page then shows an **All Deals** tab. The table renders the five columns in this order, with the given widths. A boolean column can carry `editable: true`; readers with update rights then flip it in place.

A second view on the same doctype shows the same deals as a kanban:

```yaml
content:
  name: Pipeline
  surface: kanban
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
meta:
  parent_id: crm.Deal
```

## What you get without work

Every doctype ships one general table view named **All Records**. Facet creates it with the doctype and fills it with the first eight scalar fields. Boolean columns seed as inline-editable, except `read_only` and `write_only` ones. The seed is a flag, not a permission: the table draws the toggle only for a reader who holds `update` on the doctype. Without that right, the same cell shows the plain true/false mark. You can edit or delete that view like any other; Facet does not rebuild it after you change the field list. A publish never touches collection views, and a bundle merge updates general views by name but never deletes one that exists only on the target.

## Troubleshooting

**A column shows no values.**

The column key does not match a stored field. Check the spelling and the nesting: an object field needs a path such as `address.city`.

**The calendar shows no entries.**

The discriminator field is not a date, datetime, or period field, or the stored values are empty. Pick a date field, or use the system timestamps `created_at` and `updated_at`.

**A kanban lane stays empty.**

The lane filter matches no rows. Compare the filter values with the stored ones; a money filter needs the currency, for example `"USD 25000"`.

## Related

- [Collection view reference](https://github.com/wearefacet/facet/blob/main/doc/backend/collection-view.md) — the full config keys per surface.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — what a list reads.
- [Named scopes](/build/named-scopes/) — limit which rows each role sees in the views.
