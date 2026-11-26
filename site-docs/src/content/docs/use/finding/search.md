---
type: how-to
title: Search and the command palette
description: Jump to any page or record with the command palette, and search records across one domain or every domain you may read.
audience: [user]
features: [FE-07, DOC-06]
sidebar:
  order: 2
verified_at: eee55a2
---

You remember part of a name — a client, a tent, a booking — and you want the
record, not the path to it. The **command palette** does that: one box that
opens pages, finds records, and runs commands. Press `Ctrl+K` and start
typing.

## Before you start

- [A tour of the workspace](/use/first-day/) — the layout this page navigates from.

![The search box in the top bar — the same box the Ctrl+K shortcut opens.](/assets/screens/use/finding-search-1.png)

## The command palette

Press `Ctrl+K` (`Cmd+K` on a Mac), or select the search box in the top bar.
The palette opens with up to four groups:

| Group | What it holds |
|---|---|
| **Navigate** | Domains and record types — select one to open its list |
| **Recent** | The records you opened recently in this domain |
| **Records** | Records that match what you type |
| **Actions** | Commands, such as opening the assistant or collapsing the sidebar |

A group with nothing to show stays hidden. Move with `↑` and `↓`, run with
`Enter`, close with `Esc` — pressing `Ctrl+K` again closes it too.

In **Configure**, the palette lists the Configure pages and a way back to
the workspace. The Builder has no search box in the top bar, but `Ctrl+K`
still opens the palette there.

## Search for records

Type at least two characters. The **Records** group lists the matches,
grouped by record type, closest first:

- Search matches part of a word: `vire` finds *Château de Vireloup*.
- Letter case and accents do not matter: `chateau` finds the same record.
- Results show record names, not field values.
- Search returns at most 25 records, and at most 5 of one record type. A
  common term needs a longer word to narrow it.

Some records are parts of a parent — a booking line inside a booking, a
contact inside a company. When the match is on the part, the result shows
the parent's name with the part that matched below it. Selecting it opens
the parent record.

## Widen the search to all domains

Search starts inside your current domain. To look everywhere, select
**Search all domains for …** at the bottom of the results. The palette then
marks the wider scope with an **All domains** chip; select the chip to come
back to your domain.

The option is always there, even when your domain has no matches — it is
the way to reach a record that lives in another domain.

## Run a command

The **Actions** group lists the commands your role allows: the same pages
and controls the sidebar shows. A command your role does not allow does not
appear. Select one to run it.

## What search finds — and what it does not

Search reads the names of records and the searchable text the domain author
defined for each record type. That text holds the name and the key fields —
and for comments, the comment text. You search this text, not the record's
fields one by one.

Search does **not** find:

- Files and their contents — attachments stay out of search.
- Records your role cannot read. Search follows the same rules as your
  lists: what you cannot open does not appear. See
  [Roles: who sees and does what](/discover/how-it-works/roles/).
- Deleted records, not even in the trash.

The search box on a list page is a different thing: it filters the one list
you are on. See [Lists, boards and calendars](/use/finding/lists-and-views/).

## Troubleshooting

### Search returns no records

Work down this list:

1. Type at least two characters.
2. Try a longer piece of the name. A short term can hit the 25-record
   limit before your record appears.
3. Check the scope. The record may live in another domain — select
   **Search all domains for …**.
4. Check the record type. If its author defined no searchable text, it
   never appears here.
5. Still nothing? The record may be deleted, or your role may not reach
   it. Ask your administrator.

The palette shows **No results for …** when nothing matches.

### The Records group is missing

Type at least two characters first. If the search request fails, the palette
hides the Records group and keeps the other groups usable — reload the page
if it stays away.

### A command is missing from Actions

Commands follow your role, the same as the sidebar. If the sidebar does not
show the page, the palette does not offer it either.

### The top bar has no search box

That is the Builder. Press `Ctrl+K` instead.

## Related

- [Keyboard shortcuts](/use/finding/keyboard-shortcuts/) — every key
  combination, including `Ctrl+K`.
- [Lists, boards and calendars](/use/finding/lists-and-views/) — the search
  box that filters one list.
- [Open and edit a document](/use/documents/view-and-edit/) — what opens
  when you select a result.
- [The dashboard](/use/first-day/dashboard/) — shows the same recently
  opened records.
- [Display names and search text](/build/model/views/names-and-search/) —
  how the domain author chooses what search reads.
