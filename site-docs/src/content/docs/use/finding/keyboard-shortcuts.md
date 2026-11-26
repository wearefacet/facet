---
type: reference
title: Keyboard shortcuts
description: Move through the workspace, lists, and documents with keyboard shortcuts.
audience: [user]
features: [FE-08]
sidebar:
  order: 3
verified_at: 49d7c7e5
---

These tables list the keyboard shortcuts in the workspace. In the tables, a
`Ctrl` combination means `Ctrl` on Windows and Linux, and `Cmd` on macOS.

:::tip
Press `?` to see the shortcuts that work right now. The dialog lists the
shortcuts for the page you are on.
:::

## Anywhere in the workspace

| Shortcut | Context | Action |
| --- | --- | --- |
| `Ctrl+K` | Workspace | Open or close the command palette |
| `Ctrl+I` | Pages with the assistant | Open or close the assistant window |
| `Ctrl+\` | Workspace | Collapse or expand the sidebar |
| `?` | Workspace, outside a text field | Show the keyboard shortcuts dialog |
| `Esc` | Assistant window, focus inside it | Minimize the assistant window |

## On a list

| Shortcut | Context | Action |
| --- | --- | --- |
| `C` | List page, your role may create | Start a new record of this doctype |
| `j` or `↓` | List page | Highlight the next row |
| `k` or `↑` | List page | Highlight the previous row |
| `Enter` | List page | Open the highlighted record |
| `Enter` | Peek drawer open | Open the record's full page |
| `Esc` | List page | Clear the row highlight |
| `/` | List page with a search box | Go to the list search box |

Row shortcuts appear on lists that open records in the peek drawer. The peek
drawer is the record preview at the side of the page. The `/` shortcut
appears when the doctype has a search box.

## In a document

| Shortcut | Context | Action |
| --- | --- | --- |
| `E` | Record page, your role may update | Edit the record |
| `Ctrl+S` | Editor | Save the form |
| `Ctrl+Enter` | Editor | Save the form |

## Troubleshooting

### A letter shortcut does nothing

The focus sits in a text field. Letter shortcuts do not fire while you type.
Select outside the field first.

### A shortcut does nothing while a dialog is open

An open dialog owns the keyboard. Close the dialog first.

### `C` or `E` does nothing

Your role may not allow create or update. The shortcut follows the same
rights as the buttons.

### A browser combination stays native

`Ctrl+C`, `Ctrl+T`, and similar combinations belong to the browser or the
operating system. Facet does not use them.

## Related

- [Search and the command palette](/use/finding/search/) — what `Ctrl+K` opens.
- [Lists, filters and views](/use/finding/lists-and-views/) — the lists these row shortcuts work on.
- [Viewing and editing a document](/use/documents/view-and-edit/) — editing with `E`, saving with `Ctrl+S`.
- [Using the assistant](/use/assistant/) — the window `Ctrl+I` opens.
