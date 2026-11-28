---
type: how-to
title: Lists, boards and calendars
description: Give a doctype's list page saved table, kanban, calendar, and grid views.
audience: [author]
features: [DOM-21, DOM-29, DOM-32, FE-23]
sidebar:
  order: 2
verified_at: f3decbf
---

The Brightwater warehouse tracks forty rental items, and the maintenance
team works through tickets as cards, not rows. A doctype's list page shows
one tab per saved view, and each view carries a name and a surface: a table
with chosen columns, a kanban board with lanes, a calendar placed on
dates, or a grid that edits like a spreadsheet. Views are documents on the
doctype, so you decide which tabs every user sees.

## When to use this

- The default column set does not fit the work of a team.
- A team works on documents as cards, moved over a status or a value.
- A schedule matters more than a row order, for example planned visits.
- A team enters or cleans data fastest in a spreadsheet grid.

## Before you start

- **Create rights.** You need the right to create views on the doctype.
  Without it, the plus control on the tab strip is hidden and the starter
  screen shows a note instead of cards.
- **Good candidates.** Know which fields make good columns, lanes, or
  calendar dates.

## Create a view

Open the doctype's list page. The tab strip above the table lists the saved
views. Select the plus control at the end of the strip (**Create a new
view**) to open the view editor. A doctype with no views shows a starter
screen instead: one card per surface — table, kanban, calendar, grid. Pick a
card and the editor opens with that surface preselected.

### Choose the surface

| Surface | You configure |
| --- | --- |
| `table` | An ordered column list. Each column has a `key`, an optional `label`, and an optional `width`. |
| `kanban` | A `group_by` field with `mode: values`, or fixed lanes with a filter each (`mode: custom`). |
| `calendar` | A `discriminator` date field, an optional `end_field`, a `color_by` field, a `week_start`, and a `title_template` for the chips. |
| `grid` | The table's column list, plus per-column `summary` and `editable`, and a `grid` object: `frozen` leading columns, a `filters` object, a `sort` entry, and `allow_create`. |

Facet validates the config against the doctype when you save. A kanban
group-by field must be a writable enum or boolean field that serves equality
filters; a calendar discriminator must be a period field, or a date or
datetime field that serves comparison filters. A grid column with a `summary`
other than `count` needs an `integer`, `duration`, or `money` field;
`editable` needs a field the grid can write. A `grid.filters` key must serve
its operator, a `grid.sort` entry must name a sortable field, and
`grid.frozen` is an integer from 0 to the column count. A config that cannot
render answers `422` with the field path instead of landing an empty surface.
The calendar is offered for every doctype: the system timestamps `created_at`
and `updated_at` work as the discriminator when the doctype has no date
field of its own.

:::tip
The title of a calendar chip can carry field values. Write a Jinja2 template
in `title_template`, for example `{{ name }}`. Only the doctype's own
fields, the reserved `content` variable, and the system timestamps are
allowed there.
:::

### Shape the lanes

A values-mode board derives one lane per value of the group-by field, in
the field's declared order. The view editor changes that presentation per
view: move lanes up and down, and hide lanes with the visibility toggle —
at least one lane must stay visible. Hidden lanes neither render nor
fetch; the remaining lanes follow the stored order. Set **Allow card
moves** to turn on drag-and-drop between lanes. A move writes through the
normal document update, so the history records it and the usual update
rights apply.

### Choose who sees the view

A view is **general** (every reader of the doctype sees it) or **personal**
(only you see it). The editor shows the choice when your role may create
general views; a role limited to its own rows always creates personal views.
The choice is part of the view at creation.

:::caution
A view cannot change between personal and general later. To change it,
create a new view with the right audience and delete the old one.
:::

### Save and pin

Save the view. Its tab appears above the table, and the address bar carries
a deep link to it. You can pin a tab so it stays at hand; a pin is a
personal preference and works for general and personal views alike.

### In files

In the files mode the same views are YAML files inside the domain folder,
under `views/<domain>.<Doctype>/collection_views/`. This is the Brightwater
maintenance board:

```yaml
# equipment/views/equipment.MaintenanceTicket/collection_views/
#   equipment.MaintenanceTicket.collection_view.board.yml
content:
  name: Board
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
  surface: kanban
meta:
  parent_id: equipment.MaintenanceTicket
```

The watcher applies the file on save — see [The domain
watcher](/build/model/in-files/domain-watcher/).

## Example

The Brightwater example carries four saved views you can compare against.

**A table.** The item list ships one general view, **All items**, with five
columns in display order:

```yaml
content:
  name: All items
  config:
    columns:
      - key: name
      - key: category
        width: 140px
      - key: status
        width: 120px
      - key: serial_number
        width: 160px
      - key: purchase_price
        width: 140px
  surface: table
meta:
  parent_id: equipment.Item
```

A column bound to a boolean field can carry `editable: true`. Readers with
update rights then flip it in place; the backend re-checks every flip.

**A kanban board.** The maintenance tickets group by their status enum, one
lane per value:

```yaml
content:
  name: Board
  config:
    kanban:
      mode: values
      group_by: status
      page_size: 25
  surface: kanban
meta:
  parent_id: equipment.MaintenanceTicket
```

Each card renders through the doctype's `card` view template — see [Design
document pages](/build/model/views/document-pages/). With
`mode: custom` you write your own lanes, each with a label, an optional
color, and a filter.

**A calendar.** The bookings place on their date period:

```yaml
content:
  name: Calendar
  config:
    calendar:
      color_by: status
      week_start: monday
      discriminator: dates
  surface: calendar
meta:
  parent_id: rentals.Booking
```

**A grid.** The item list also ships a sheet view. The name column stays
frozen at the left while you scroll, and the price column shows its sum
under the rows. A computed or read-only field renders as a read-only cell:

```yaml
content:
  name: Sheet
  config:
    columns:
      - key: name
        width: 240px
      - key: category
        width: 140px
      - key: status
        width: 120px
      - key: purchase_price
        width: 140px
        summary: sum
    grid:
      frozen: 1
  surface: grid
meta:
  parent_id: equipment.Item
```

## The empty state

A doctype ships with **no** views. Facet never creates one on its own — not
at doctype creation, not at boot. Until the first view exists, the list page
shows the starter screen, and the `/check` report carries an info notice
that asks for one. The notice is not an error: nothing is broken, the
doctype has no listing surface yet.

You can edit or delete a view like any other document. Deleting the last
view brings the starter screen back, and Facet does not recreate the view. A
publish never touches saved collection views, and a bundle merge updates
general views by name but never deletes one that exists only on the target.

## Troubleshooting

**A column shows no values.**

The column key does not match a stored field. Check the spelling and the
nesting: an object field needs a path such as `address.city`.

**The calendar shows no entries.**

The discriminator field does not serve the window filter, or the stored
values are empty. Pick a date or period field, or use the system timestamps
`created_at` and `updated_at`.

**A kanban lane stays empty.**

The lane filter matches no rows. Compare the filter values with the stored
ones; a money filter needs the currency, for example `"EUR 25000"`.

**The editor hides the general choice.**

Your role may create only personal views. An administrator widens the
create permission on views — see [Show each role only its
rows](/admin/people/row-scopes/).

## Related

- [Design document pages](/build/model/views/document-pages/) — the surfaces users open from a list row.
- [Display names and search text](/build/model/views/names-and-search/) — the label every row shows.
- [Show each role only its rows](/admin/people/row-scopes/) — limit which rows each role sees in the views.
- Internals on GitHub: [collection-view.md](https://github.com/wearefacet/facet/blob/main/doc/backend/collection-view.md).
