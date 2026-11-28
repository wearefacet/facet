---
type: how-to
title: Lists, boards and calendars
description: Open a list, switch between table, kanban, calendar and grid layouts, filter it, and save the result as a view you can reopen in one click.
audience: [user]
features: [FE-03, FE-08, DOM-21, DOM-30, FE-23, FE-25]
sidebar:
  order: 1
verified_at: f3decbf
---

Your work lives in lists. Every record type opens one, and you pick the
layout that fits the job. A table when you need detail, a board when work
moves through stages, a calendar when dates matter, a grid when a
spreadsheet feels fastest. Narrow the list with filters, then save the whole
setup as a **view**. A view is a named tab you reopen in one click — keep it
to yourself, or share it with your team.

## Before you start

- [A tour of the workspace](/use/first-day/) — where the sidebar, the top bar, and your records sit.

## Open a list

Open a domain in the sidebar, then select a record type. The list opens on
the first saved view, shown as a tab above the table:

![Tom's clients list: a table of companies with the view tabs above it and the filter toolbar on top.](/screens/use/finding-lists-1.png)

A record type with no views yet shows a starter screen instead: one card per
layout. Pick a card to build the first view. After that, the tabs carry an
icon each — table, board, calendar, or grid — so you can see at a glance what
a tab opens.

## The four layouts

| Layout | What it shows | Use it for |
|---|---|---|
| **Table** | One row per record, one column per field | Detail, sorting, working through many records |
| **Kanban** | Cards grouped in lanes, one lane per status or stage | Work that moves: tickets, bookings |
| **Calendar** | Records placed on a month or week grid by a date field | Bookings, deadlines, schedules |
| **Grid** | The list as a spreadsheet: one row per record, one selectable cell per field | Fast entry and clean-up, copy to and from Excel or Sheets |

Each layout answers a different question. Lucía runs the maintenance board. Every ticket sits in the lane that
matches its state, and she drags a card when the work moves on. Dragging
needs the right to change records — the same right the Edit button
follows.

![Lucía's maintenance board: five ticket cards grouped in lanes by status.](/screens/use/finding-lists-2.png)

The calendar puts records on the days they happen. Switch between **Month**
and **Week**, and move with **Previous**, **Next**, and **Today**. A busy day
folds its entries into one chip — for example `4 documents` — and selecting
the chip lists them.

![Nadia's booking calendar for December: bookings placed on their date ranges.](/screens/use/finding-lists-3.png)

The grid works like a spreadsheet. Select a cell, type, and the change saves.
Select a range and copy it into Excel or Google Sheets, or paste a block from
them. A column the view author gave a summary shows its count, sum, or
average under the rows. Press `Enter` on a selected cell to open the record
in the preview; on a field you can change, typing starts the edit instead.

In every layout, selecting a row, card, or chip opens a preview beside the
list. The preview holds **Edit** and **Open full page**.

## Narrow the list

Filters keep only the records you need:

1. Select **+ Add filter** in the toolbar. A menu lists the fields you can
   filter.
2. Select a field. A chip appears in the toolbar, with the comparison and a
   value control.
3. Pick the comparison and enter a value. The list updates as you type.

The menu offers only the comparisons the field supports:

| You want | The chip shows | Fits |
|---|---|---|
| An exact match | `is` or `=` | Text, pick lists, references, numbers, dates |
| An exact mismatch | `is not` or `≠` | The same fields |
| A threshold | `>`, `≥`, `<`, `≤` | Numbers, dates, amounts |
| A range | `between` | Two bounds, for example a date range |
| Several values at once | `is any of` | Pick lists |
| Part of a word | `contains` | Text, not case-sensitive |

Two chips do nothing until you fill them: a `between` chip needs both bounds,
and `is any of` needs at least one value. That is deliberate — a half-filled
range would otherwise silently hide rows.

The search box at the left of the toolbar is one more filter. It matches
part of the record name, not case-sensitive. Press `/` to jump to it.

## Sort and page

In the table, select a column heading to sort by it, and select again to
reverse the order. The small arrow shows the direction. The grid headers sort
the same way. Board and calendar cards follow the order saved in the view.

Below the table, the pager moves through the pages. The label, for example
`1–25 of 340`, shows where you are. The count caps at 1000 — beyond that the
list shows `1000+`, and filters bring the number down.

## Work the list from the keyboard

The list answers to the keyboard as well as the mouse. `j` and `k` (or the
arrow keys) move the highlight through the rows, and `Enter` opens the
highlighted record — first in the preview, then as the full page. `Esc`
clears the highlight, and `/` jumps to the search box. `C` starts a new
record of this type. The letter keys rest while you type, so they never
fire from a text field. In the grid, the arrow keys move the selected cell
instead, and `Enter` opens the record — or starts the edit on a field you
can change.

## Save your setup as a view

A view stores the layout, the filters, and — for a table — the columns and
their order. Build it once, then reopen it in one click:

1. Select the **+** beside the tabs (**Create a new view**).
2. Choose the view type: Table, Kanban, Calendar, or Grid.
3. Name it, for example `My open deals`.
4. Choose the scope. **Personal** means only you see it. **General** means
   the whole team shares it.
5. Set the details: columns for a table, lanes for a kanban, the date field
   for a calendar, columns and their totals for a grid. Filters come in the
   Filters step.
6. Select **Create view**.

A new view starts personal: only you see it. Some roles may create personal
views only — if you cannot pick **General**, ask your administrator. Your
filters stay active while you edit, so what you see is what you save.

**Change a view.** Select **Edit current view** beside the tabs. Changes
apply to everyone who uses the view, so check with your team before you edit
a shared one.

**Remove a view.** Select **Delete current view**. A saved view disappears
for every account, so delete a general view only when the team agrees.

:::caution[Personal and general do not switch]
A view keeps its scope for life. To move a personal view to the team, create
a general copy with the same settings, then delete the personal one.
:::

## Pin a view

Select the pin control beside the tabs to pin the view you are on. A pinned
view appears as a card on the domain dashboard, so your daily list is one
click from the home screen. Select the control again to unpin.

## Share a view with a link

The address of a list carries the open view, so a link opens the same
filtered list for a colleague:

```
https://facet.localhost:3443/rentals/Booking?view=calendar
```

The part after `view=` is the view name in small letters with underscores.
Anyone with the link and the right to read the records sees the same list.
They still need read access — a link never opens records their role hides.

## Restore a deleted record

Switch the toggle at the top of the list from **Live** to **Deleted** to see
the records sent to the trash. Select **Restore** on a row to bring it back
— restoring needs the right to change records. Facet keeps deleted records
so a mistake is never final.

## Troubleshooting

### The list is empty

Start with the filters. Remove each chip one by one — a chip with an empty
value filters everything out. Then check the view itself: a saved view
applies its own filters before yours, so switch tabs to compare. Still
empty? Switch the toggle to **Deleted**; the records may sit in the trash.
If the records are missing from the **Live** and **Deleted** lists alike,
ask your administrator — your role may not reach them.

### A field is missing in the Add filter menu

Only fields the domain author made filterable appear, and only fields your
role can read. Ask the domain author or your administrator.

### The filter returns nothing

Check the spelling first. `contains` matches part of a word, but an `is`
filter needs the exact value — `open`, not `Open`. Then check a `between`
chip: a blank bound filters everything out, so fill From first.

### You cannot create or edit a view

Your role does not carry the right to change views. You can still use the
views your team shares. Ask your administrator — see
[Roles: who sees and does what](/discover/how-it-works/roles/) for how roles
decide this.

### A board lane shows more records than it lists

The count on a lane reads the full lane, and the board shows the first page.
Select **Show more** at the bottom of that lane to load the next page.

### The calendar is empty

The view anchors on one date field, and records without a value in that
field do not appear. Open **Edit current view** and check the date field.
Then move to the right month with **Today** and the arrows.

## Related

- [The dashboard](/use/first-day/dashboard/) — where your pinned views appear.
- [Open and edit a document](/use/documents/view-and-edit/) — what opens
  from a row or card.
- [Search and the command palette](/use/finding/search/) — find records
  across every domain.
- [Keyboard shortcuts](/use/finding/keyboard-shortcuts/) — the full map,
  list and workspace alike.
- [Import and export data](/use/documents/import-export/) — export exactly
  what the table shows.
- [Roles: who sees and does what](/discover/how-it-works/roles/) — why some
  records and fields stay out of your lists.
- [Lists, boards and calendars (for authors)](/build/model/views/lists-boards-calendars/) —
  how the domain author shapes these views.
