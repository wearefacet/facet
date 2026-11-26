---
type: reference
title: Keyboard shortcuts
description: Every key combination in the workspace — move through lists, open and save records, and reach the palette, assistant and shortcut sheet.
audience: [user]
features: [FE-08]
sidebar:
  order: 3
verified_at: eee55a2
---

The workspace answers to the keyboard as well as the mouse. These tables
list every shortcut and where it works. In the tables, `Ctrl` means `Ctrl`
on Windows and Linux, and `Cmd` on a Mac.

Press `?` — outside a text field — to see the shortcuts that work right
now. The sheet lists only the shortcuts for the page you are on, so it is
shorter than this reference.

## Anywhere in the workspace

| Shortcut | Action |
|---|---|
| `Ctrl+K` | Open or close the command palette |
| `Ctrl+I` | Open or close the assistant |
| `Ctrl+\` | Collapse or expand the sidebar |
| `?` | Show the keyboard shortcut sheet |
| `Esc` | Minimize the assistant window, when you are typing in it |

## On a list

| Shortcut | Action |
|---|---|
| `C` | Start a new record of this record type |
| `j` or `↓` | Highlight the next row |
| `k` or `↑` | Highlight the previous row |
| `Enter` | Open the highlighted record in the preview |
| `Enter` | With the preview open, open the record's full page |
| `Esc` | Clear the row highlight |
| `/` | Jump to the list search box, when the list has one |

## In a record

| Shortcut | Action |
|---|---|
| `E` | Edit the record |
| `Ctrl+S` | Save the form |
| `Ctrl+Enter` | Save the form |

## The rules behind the tables

Letter shortcuts follow the same rights as the buttons: `C` appears only
where your role may create records, `E` only where it may change them.
Nothing hidden, nothing extra.

Letters and `?` do not fire while you type — only combinations with `Ctrl`
do. That is why `Ctrl+K` works from a search box but `j` does not. Inside
an open dialog, the dialog owns the keyboard and the workspace shortcuts
stand down.

Combinations the browser already owns — `Ctrl+C` to copy, `Ctrl+T` for a
new tab — stay with the browser. Facet does not take them.

## Troubleshooting

### A letter shortcut does nothing

The focus sits in a text field. Select outside the field first — letters
never fire while you type.

### A shortcut does nothing while a dialog is open

An open dialog owns the keyboard. Close the dialog first.

### `C` or `E` does nothing

Your role does not allow create or change on this record type. The
shortcut follows the same rights as the buttons — if the button is absent,
the key is silent. Ask your administrator; see
[Roles: who sees and does what](/discover/how-it-works/roles/).

### A browser combination stays native

`Ctrl+C`, `Ctrl+T`, and their neighbours belong to the browser or the
operating system. Facet does not use them, and leaves them alone.

## Related

- [Search and the command palette](/use/finding/search/) — what `Ctrl+K`
  opens.
- [Lists, boards and calendars](/use/finding/lists-and-views/) — the lists
  these row shortcuts work on.
- [Open and edit a document](/use/documents/view-and-edit/) — editing with
  `E`, saving with `Ctrl+S`.
- [Ask the assistant](/use/assistant/) — the window `Ctrl+I` opens.
