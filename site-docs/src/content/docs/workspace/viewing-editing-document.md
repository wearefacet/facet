---
title: Viewing and editing a document
description: Open a document, read its page, edit and save its fields, and delete it when needed.
audience: [user]
features: [FE-04, FE-05, DOC-13]
sidebar:
  order: 4
verified_at: 49d7c7e5
---

A document is one record, for example one deal or one employee. This page
covers the record page and the edit form. It also explains what happens when
two people edit at once, and how to delete a record.

## Before you start

- **Read and update rights.** You need read access to see a document, and
  update access to edit it. A hidden field stays hidden even on an open page.
  See [How Facet checks permissions](/concepts/authorization-enforcement/).
- **Saves go live.** Your changes go live when you save. Other pages reflect
  them without a manual reload.

## Steps

### 1. Open a document

You have three paths:

- **From a list** — select a row, a kanban card, or a calendar chip. The peek
  drawer opens with a preview.
- **From the domain dashboard** — select a chip under **Recently viewed**.
- **From search** — press `Ctrl+K`, type part of the name, and select the
  record.

  The peek drawer shows the quick preview. Use the pencil icon to open the edit
  form. Use the arrow icon (**Open full page**) for the full page. You can also
  send the page address to a colleague; it opens the same document.

  The full page shows:

| Part | What it shows |
| --- | --- |
| Header | The record name, a colour mark, and the doctype label. |
| Buttons | **Share** (copies the link), **Print**, **History**, **Edit**, and **Actions**. |
| Content | The fields and sections the doctype defines, laid out by its author. |
| Side panel | Comments and attachments, when the doctype carries them. |
| Referenced by | The records that link to this one. |

A doctype without a designed layout shows a simple field list instead:
one label and one value per line.

:::tip
Press `E` on a record page to open the editor. Save with `Ctrl+S` or
`Ctrl+Enter`.
:::

### 2. Edit the fields

Select **Edit**. The form opens with the fields of the record:

- **Text** — text fields take text. A long-text field takes markdown.
- **Pick list** — the field offers its fixed values in a dropdown.
- **Date or time** — the field opens a picker. You enter wall time in your
  own timezone; Facet stores the value in UTC (Coordinated Universal Time).
- **Money** — the field takes an amount and a currency.
- **Reference** — the field opens a search over the linked doctype.
- **True/false** — the field shows a toggle.

Fields the author marked read-only show in the page but not in the form. A
new record starts with the default values the author set, for example a
status that begins at `new`.

  Select **Save**. The button shows **Saving…** while the save runs. Facet
  returns you to the record page.

### 3. Read the save result

A clean save takes you back to the record page, and the content shows the
new values.

When Facet rejects a value, the form stays open. A red banner on top names
the problem, and each failing field shows its own message under the input.
Fix the marked fields and save again.

:::note[One save, one version]
Every save records one version in the document history, with your name and
the time. A save that only re-saves the same values within a few minutes
folds into one entry. See [The mutation log](/concepts/mutation-log/).
:::

### 4. Work on a document someone else edits

Facet does not lock a document. Two people can open and edit the same
record. Each save merges into the stored document field by field:

- **Different fields** — you change one field and a colleague changes
  another: both changes land.
- **The same field** — you both change it: the save that lands last wins. The
  page refreshes by itself and shows the newer value.

  The page follows the document live. When an automation or another person
  changes it, your view updates without a reload. The **History** button shows
  who changed what, and [History and undo](/workspace/history-undo/) explains
  how to put an earlier version back.

### 5. Run an action or delete the document

The **Actions** button lists the actions the doctype defines, for example a
stage change. Select one; if it asks for input, fill the dialog and confirm.

To delete, open **Actions** and select **Delete**. Facet asks first:

> Delete {name}? This cannot be undone.

When other records reference this one, the dialog also names the count.
Deleting leaves those links pointing at a deleted record.

:::caution[The dialog says final]
The delete dialog warns that the delete is final. Facet keeps the deleted
record for a while. Two places can bring it back, if your role allows it.
One is the **Deleted** side of the list. The other is the document's history
page. Links and lists lose the record at once, so do not treat the delete as
a soft pause. See [History and undo](/workspace/history-undo/).
:::

After the delete, Facet returns you to the list. Deleted records stay
visible on the **Deleted** side of the list toggle, with a **Restore**
button.

## Example

A short edit from the peek drawer:

```
/crm/Deal            select a row            the drawer opens
                     select Edit             /crm/Deal/crm.Deal.1/edit
                     change Amount, select Save   back on the record page
```

The address of the edit form is the record address plus `/edit`.

## Troubleshooting

### The page says the document was deleted

Someone deleted it after you opened it. The message shows when. A person
with the right can restore it. See [History and undo](/workspace/history-undo/).

### The Edit button is missing

Your role cannot update this doctype. You can still read, comment, and
follow links. Ask your administrator for the update right.

### A save fails with a field message

Read the message under the field. Common cases:

- a required field is empty
- text is too long
- a number or date has the wrong shape
- a currency is missing on a money field

Fix the marked fields and save again.

### Your change disappeared

Someone saved the same field after you; the later save wins. Open
**History**, find your change, and revert to it if needed. See
[History and undo](/workspace/history-undo/).

### A field shows a raw code instead of a name

The linked record may be deleted, or your role cannot read it. Ask the
author of the doctype, or your administrator.

## Related

- [Lists, filters and saved views](/workspace/lists-filters-views/) — the lists you open records from.
- [Comments and attachments](/workspace/comments-attachments/) — the side panel of a record page.
- [History and undo](/workspace/history-undo/) — read the versions and put one back.
- [Search and the command palette](/workspace/search-command-palette/) — the third way to open a record.
- [The mutation log](/concepts/mutation-log/) — what each save records.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — how a record is stored and served.
