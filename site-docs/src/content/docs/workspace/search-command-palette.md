---
title: Search and the command palette
description: Find records with search, and jump to any page or command from the palette.
audience: [user]
features: [FE-07, DOC-06]
sidebar:
  order: 7
verified_at: 49d7c7e5
---

The command palette opens pages, records, and commands from one box. Press
`Ctrl+K`, or select the search box in the top bar. The palette also searches
your records. This page shows both uses.

## The command palette

### 1. Open the palette

Press `Ctrl+K`. On macOS, press `Cmd+K`. You can also select the search box in
the top bar.

The palette shows up to four groups: **Navigate**, **Recent**, **Records**,
and **Actions**. A group with no items stays hidden.

:::tip
Press `Ctrl+K` again to close the palette. `Esc` also closes it.
:::

:::note
In Configure, the palette lists the Configure sections and a way back to the
workspace. Builder mode has no search box in the top bar, but `Ctrl+K` still
opens the palette there.
:::

### 2. Jump to a page

Type the name of a domain or a doctype. The **Navigate** group lists the
matches. Select one to open the page.

The **Recent** group lists the records you opened recently in the current
domain.

### 3. Search for records

Type at least two characters, for example `inv`. The **Records** group lists
the matching records. Each result shows the record name. Select a result to
open the record.

Some records are parts of a parent record. A match on a part shows the parent
name, with the part that matched below it. Selecting it opens the parent
record.

:::tip
Select **Search all domains for …** to widen the search. The palette then
marks the wider scope with an **All domains** chip. Select the chip to search
the current domain again.
:::

### 4. Run a command

The **Actions** group lists commands. Examples: open Builder, open Configure,
show the keyboard shortcuts, collapse the sidebar. Commands follow the same
rights as the sidebar. A command your role does not allow does not appear.

Move with `↑` and `↓`. Press `Enter` to run the selected item.

## Document search

### 1. Type your term

Search starts at two characters. Type two or more letters, for example `ada`.

### 2. Read the results

Search matches part of a word. The term `ada` matches "Ada Lovelace". Search
ignores letter case and accents.

The closest matches come first. The palette groups the results by doctype.
Search returns at most 25 records, and at most 5 records per doctype.

Results show record names. They do not show field values.

### 3. Widen or narrow the scope

Search covers the current domain. Use **Search all domains for …** to search
every domain you may read. This option is always present, also when the current
domain has no match — it is the way to find a record that lives in another
domain.

### What search reads

- A doctype appears in search only when its definition defines searchable
  text. The text usually holds the record name and key fields. Doctype authors
  set this text in the doctype definition.
- You see only records your role may read.
- Deleted records never appear.

The search box on a list page is a filter, not this search. It narrows the
current list. It matches the searchable text, the record name, and the record
id. See [Lists, filters and views](/workspace/lists-filters-views/).

## Troubleshooting

### Search returns no records

1. Check the term. Search needs two characters or more.
2. Check the doctype. It may define no searchable text, so it never appears
   here.
3. Check your rights. Your role may not read the doctype.
4. Check the record. It may live in another domain, or it may be deleted.

The palette shows **No results for …** when nothing matches.

### The Records group is missing

Type at least two characters. If the search request fails, the palette hides
the Records group. The other groups stay usable.

### A command is missing from Actions

Commands follow your rights. In Configure, the palette lists Configure
sections instead of workspace commands.

### The top bar has no search box

Builder mode has none. Press `Ctrl+K`.

## Related

- [Keyboard shortcuts](/workspace/keyboard-shortcuts/) — every key combination, including `Ctrl+K`.
- [Lists, filters and views](/workspace/lists-filters-views/) — the search box that filters one list.
- [Viewing and editing a document](/workspace/viewing-editing-document/) — what opens when you select a result.
- [The dashboard](/workspace/dashboard/) — shows the same recently opened records.
- [Domains and isolation](/concepts/domains-and-isolation/) — why search starts inside your current domain.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — where record names and searchable text come from.
