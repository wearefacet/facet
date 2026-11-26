---
title: Lists, filters and saved views
description: Work a list in table, kanban, or calendar layout, filter it, and save the result as a view.
audience: [user]
features: [FE-03, DOC-02, DOM-21]
sidebar:
  order: 3
verified_at: 49d7c7e5
---

Your records live in lists. Every doctype opens one, and you pick the layout
that fits the job:

- **Table** — when you need detail, columns, and sorting.
- **Kanban** — when work moves through stages.
- **Calendar** — when dates matter.

Narrow the list with filters, sort it, then save the setup as a **saved
view**: a named tab you can reopen in one click, or share with your team.

## Before you start

- **Read access.** You need read access to the doctype. Without it, Facet
  does not show the list. See
  [How Facet checks permissions](/concepts/authorization-enforcement/).
- **Rights on views.** To create or change saved views, your role needs
  create or update rights on views. Without them, you can still use the views
  your team shares.

## Steps

### 1. Open a list

Open a domain, then select a doctype. The list opens on the first saved
view. You can also open a view straight from the domain dashboard.

A new doctype has no views yet: the page shows a starter screen with one
card per layout. Pick a card to create the first view. After that, the tabs
above the table show the views, each with an icon for its layout: table,
kanban, or calendar.

<!-- d2
tab: "Select a tab" {class: external}
layout: "Which layout?" {class: decision}
table: "Rows and sortable columns"
kanban: "Cards in lanes"
calendar: "Chips on a date grid"

tab -> layout
layout -> table: Table
layout -> kanban: Kanban
layout -> calendar: Calendar
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/22678345-light.svg" alt="Select a tab" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/22678345-dark.svg" alt="Select a tab" loading="lazy" />
</div>

### 2. Pick the layout

Each layout fits a different job:

- **Table** — one row per record, one column per field. Use it when you need
  detail. The toolbar on top holds the search box, the **+ Add filter** menu,
  and the export and import controls.
- **Kanban** — cards in lanes. A lane groups records by one field, for
  example the status. Use it when work moves through stages. Each card shows
  the record name and its update time. Lanes load independently: one slow or
  empty lane never blocks the board. A lane with more records than the first
  page shows **Show more**.
- **Calendar** — records placed on a month or week grid, by the view's date
  field. Use it when dates matter. Switch between **Month** and **Week**, move
  with **Previous**, **Next**, and **Today**. A busy day collapses its chips
  into one group chip, for example `4 documents`. Select the group to list the
  records.

  In every layout, select a row, card, or chip to open the record in the peek
  drawer. The drawer holds a preview plus **Edit** and **Open full page**
  controls.

### 3.   Narrow the list with filters

Filters keep only the records you need. Use the toolbar:

1. Select **+ Add filter**. A menu lists the fields you can filter.
2. Select a field. A chip appears, with the operator and a value control.
3. Pick the operator and enter a value. The list updates as you type.

The operator menu offers only the comparisons the field supports:

| Operator | Label | Use for |
| --- | --- | --- |
| equals | `is` or `=` | Text, pick lists, references, numbers, dates |
| not equals | `is not` or `≠` | The same fields |
| compares | `>`, `≥`, `<`, `≤` | Numbers, dates, amounts |
| range | `between` | Two bounds, for example a date range |
| set | `is any of` | Several values of a pick list at once |
| text | `contains` | Part of a word, not case-sensitive |

A `between` or `is any of` chip filters nothing until you enter its bounds
or pick its values.

:::tip
The search box on the left of the toolbar is one more filter. It matches
part of the record name and its searchable text, not case-sensitive. Press
`/` to jump to it.
:::

### 4. Sort and page

**Sort.** In the table, select a column heading to sort by it. Select again
to reverse the order. The small arrow shows the direction. Kanban and
calendar cards follow the order saved in the view.

**Page.** Below the table, the pager moves through the pages. The label, for
example `1–25 of 340`, shows where you are. The count caps at 1000; beyond
that the list shows `1000+`, and you narrow it with filters.

### 5. Save the setup as a view

A saved view stores the layout, the filters, and (for a table) the columns
and their order. Build it once, then reopen it in one click.

1. Select the **Create a new view** control beside the tabs. Your current
   filters stay active while you edit.
2. Choose the view type: Table, Calendar, or Kanban.
3. Name the view, for example `My open deals`.
4. Set the scope. **Personal** means only you see it. **General** means the
   whole team shares it. You cannot change this after you save.
5. Set the details per type: columns for a table, lanes for a kanban, the
   date field for a calendar. Add filters in the Filters step.
6. Select **Create view**.

**Change a view.** Select **Edit current view** beside the tabs.

**Clear your filters.** Remove each chip with its **Remove filter** control,
without saving.

:::caution[Personal and general do not switch]
A view keeps its scope for life. To move a personal view to the team, create
a general copy with the same settings. Then delete the personal one. Delete
a general view only when the team agrees.
:::

### 6. Pin a view

Select the pin control beside the tabs to pin the current view. A pinned
view appears on the domain dashboard, so your daily list is one click away.
Select the control again to unpin.

## Example

Share a filtered list with a colleague through the view link:

```
https://facet.localhost:3443/crm/Deal?view=my_open_deals
```

The part after `view=` is the view name, in small letters with underscores.
Anyone with the link and the rights sees the same list with the same
filters.

## Troubleshooting

### The list is empty

Start with the filters.

1. Switch the filter chips off one by one. A chip with an empty value filters
  everything out.
2. Check the view. The saved filters of the view apply before yours.
3. Switch the **Live** / **Deleted** toggle to **Deleted**. The records may
  sit in the trash.

### A field is missing in the Add filter menu

Only fields the author made filterable appear. Fields that your role cannot
read stay out too. Ask the author of the doctype, or your administrator.

### The filter returns nothing

1. Check the value spelling. `contains` matches part of a word, but an
  equals filter needs the exact value, for example `open`, not `Open`.
2. Fill both bounds of a `between` filter, From first. A `between` chip with
  a blank bound filters nothing.

### You cannot create or edit a view

Your role lacks the right on views. Use the shared views, or ask your
administrator. See [Roles, levels, and authority](/concepts/roles-levels-authority/).

### A kanban lane shows more records than it lists

The count badge reads the full lane, capped at 1000. The board shows the
first page per lane. Select **Show more** in that lane to load the next
page.

### The calendar is empty

The view anchors on one date field. Records without a value in that field
do not appear.

1. Open **Edit current view** and check the date field.
2. Move to the month you look for, with **Today** and the arrows.

## Related

- [The dashboard](/workspace/dashboard/) — where your pinned views appear.
- [Viewing and editing a document](/workspace/viewing-editing-document/) — what opens from a row or card.
- [Search and the command palette](/workspace/search-command-palette/) — find records across the domain.
- [Import and export data](/workspace/import-export/) — export exactly what the table shows.
- [Designing doctypes](/build/designing-doctypes/) — how doctypes and their fields are defined.
- [How Facet checks permissions](/concepts/authorization-enforcement/) — why some records stay hidden.
