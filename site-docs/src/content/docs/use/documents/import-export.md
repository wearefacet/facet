---
type: how-to
title: Import and export data
description: Import documents from CSV or JSON files, and export what a list shows.
audience: [user]
features: [FE-18, DOC-11]
sidebar:
  order: 4
verified_at: eee55a2
---

Every list page carries **Export** and **Import** in its toolbar.

![A clients list with the Export and Import controls in the toolbar.](/assets/screens/use/documents-4.png)

- **Export** writes the documents of the list to a CSV (comma-separated
  values) or JSON (JavaScript Object Notation) file.
- **Import** reads such a file and creates or updates documents.

Both run in the background. Facet reports the result when the job finishes.

## Before you start

- **Export** needs read access to the list.
- **Import** needs create and update access together. Facet refuses the
  whole file when one is missing.
- **The safest file** is a file you exported from the same list.

:::caution
Import writes real documents. Facet applies the whole file or nothing. The
first bad row stops the import, and no row of the file is written.
:::

## Steps

### 1. Export all documents of a list

1. Open the list page.
2. Select **Export** in the toolbar.
3. Select **Export as CSV** for a spreadsheet, or **Export as JSON** for a
   complete structured copy.
4. Facet starts a background job and confirms: *"Export started — the file
   link lands here when ready."*
5. When the file is ready, select **Download** in the message. The same
   link arrives in your notifications.

The file holds:

- every document of the list that your account may see
- an `id` column first, with the identifier of each document
- no field that your role hides
- the data as it was at one moment. Facet reads the list in one snapshot.

### 2. Export the current table view

The menu item **CSV — current view** exports what the table shows now:

- the columns the table shows, in their order
- the filters and the sort you applied
- date and time cells in your display timezone

1. Set the columns, filters, and sort on the list.
2. Select **Export**, then **CSV — current view**.
3. Download the file as in step 1.

:::note
A view file is for reading, not for importing back. Facet writes its date
and time cells without a zone, so an import of that file fails validation.
Use **Export as CSV** for a file you plan to import.
:::

### 3. Import documents from a file

1. Open the list page.
2. Select **Import** in the toolbar.
3. Select **Choose a .csv or .json file**, and pick your file.
4. Facet shows the row count. Check it.
5. Select **Import**. The dialog confirms: *"Importing 12 rows — the result
   lands in your notifications."*
6. You can close the dialog and keep working. The result also arrives in
   your notifications.

A successful import reports, for example: **3 created · 2 updated · 1
skipped**.

Facet matches each row by its `id`:

- A row with an `id` updates the matching document.
- A row without an `id` creates a new document. Facet generates the
  identifier.
- A row whose `id` matches a deleted document is skipped. Import does not
  restore deleted documents.

:::tip
To update a few documents, export the list first. Change the cells in the
file, keep the `id` column unchanged, and import the file again.
:::

### 4. Move a whole domain (authors)

Domain authors can move a domain's structure between instances. In the
**Configure** area, open the domain list: **Export bundle** sits in the row
menu of a published domain, and **Import bundle** sits in the page header.
An import can create the domain under a new name or merge into an existing
one. A bundle carries definitions only — documents do not move with it. See
[Move domains with bundles](/build/model/bundles/).

## Good files and bad files

Two cell rules matter when you edit an exported file in a spreadsheet:

- **Money cells carry their currency**, for example `EUR 1200`. Keep the
  currency when you edit.
- **Text that starts with a symbol may carry a guard.** Facet writes one
  leading `'` before text that starts with `=`, `+`, `-`, or `@`, so a
  spreadsheet shows the text and does not treat it as a formula. Import
  removes one leading `'`. Keep it as it is.

More rules for the file:

- An empty cell clears the field on update. A column you omit leaves the
  field unchanged.
- A file field exports as its identifier only. The file content does not
  move.
- Comments, attachments, child documents, and other panel data do not move
  this way.
- A document written before the last change to the list's definition
  exports in its stored older shape.

| Limit | Rule |
| --- | --- |
| File size | A file over 50 MB is refused. 50 MB is the default; your instance may differ. |
| Download window | Facet keeps export files for 30 days by default. After that, the link stops working. |
| Match key | The `id` column is the only match key. Facet cannot match by name or another field. |

## Example

At Brightwater, the old equipment spreadsheet becomes Items. Lucía exports
the Item list with **Export as CSV**, pastes the rows from the old
spreadsheet into the file, removes the `id` cells (each row without an `id`
creates a new record), and imports the file on the Item list. The report
says **40 created · 0 updated · 0 skipped**, and the serial-number column
stays unique — a duplicate serial would stop the whole file.

Every imported row appears in the documents' histories under the *import*
name, so you can always trace what a file changed.

## Troubleshooting

### Nothing was imported, and a row message names a field

For example: *"Nothing was imported."* with *"Row 3, field amount: …"*.

One row failed validation. Nothing was written. Fix that row and submit the
file again.

### The file shape does not match the header

For example: *"row 2: has 3 cells but the header declares 2 columns"*.

Facet checks the file shape before the job starts. The message names the
faulty row. Fix the row, then import again. The same pre-check refuses
columns the list does not know.

### The export failed

For example: *"Export failed — check the notifications for the error."*

The job failed after it started.

1. Open **Notifications** and read the error there.
2. Fix the cause and export again.

### The Download link no longer works

The file expired. Facet keeps export files for a limited window. Export
again.

### The report counts skipped rows

Those `id` values match deleted documents. Import does not restore deleted
documents.

1. Restore them from the trash first.
2. Import again.

## Related

- [Lists, boards and calendars](/use/finding/lists-and-views/) — the current
  view decides what **CSV — current view** exports.
- [Notifications](/use/notifications/) — finished jobs deliver the download
  link here.
- [History and undo](/use/documents/history-undo/) — every imported row
  appears in the document history.
- [Bulk import and export](/build/apps/data/bulk-import-export/) — the same
  moves through the API, for apps and scripts.
- [Move domains with bundles](/build/model/bundles/) — for authors: the
  bundle import and export in depth.
