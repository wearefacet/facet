---
type: how-to
title: Import and export data
description: Move documents in and out of Facet as CSV or JSON files.
audience: [user, author]
features: [FE-18, DOC-11]
sidebar:
  order: 4
verified_at: 49d7c7e5
---

Every list page carries **Export** and **Import** in its toolbar.

- **Export** writes the documents of the list to a CSV (comma-separated
  values) or JSON (JavaScript Object Notation) file.
- **Import** reads such a file and creates or updates documents.

Both run in the background. Facet reports the result when the job finishes.

## Before you start

- **Export** needs read access to the list.
- **Import** needs create and update access together. Facet refuses the whole
  file when one is missing.
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
4. Facet starts a background job and confirms: "Export started — the file
   link lands here when ready."
5. When the file is ready, select **Download** in the message. The same link
   arrives in your notifications.

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
A view file is for reading, not for importing back. Facet writes its date and
time cells without a zone, so an import of that file fails validation. Use
**Export as CSV** for a file you plan to import.
:::

### 3. Import documents from a file

1. Open the list page.
2. Select **Import** in the toolbar.
3. Select **Choose a .csv or .json file**, and pick your file.
4. Facet shows the row count and the first column names. Check them.
5. Select **Import**. The dialog confirms: "Importing 12 rows — the result
   lands in your notifications."
6. You can close the dialog and keep working. The result also arrives in your
   notifications.

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

### 4. Move a domain definition (authors)

Authors can move a whole domain definition between instances. In the
**Configure** area, open the domain list. The row menu of a published domain
carries **Export bundle**. The **Import bundle** button in the page header
applies a downloaded bundle. You can import it under a new name, or merge it
into an existing domain. A bundle carries definitions only. Documents do not
move with it. See [Build domains](/build/).

## Example

You can also export through the API (application programming interface).
Create an API key in **Settings → API keys** first. Your role must allow API
access. The command below reads the key from the `FACET_API_KEY` environment
variable.

```sh
curl -k -X POST "https://facet.localhost:3443/Api/crm/Company/export?format=csv&wait=true" \
  -H "Authorization: Bearer $FACET_API_KEY" \
  -o companies.csv
```

`wait=true` makes Facet send the finished file as the response. The command
writes it to `companies.csv`. `-k` skips the certificate check of the local
development address. Without `wait=true`, Facet starts the job and answers
with the job id. The download link then arrives in your notifications.

An export of the sample CRM list starts like this:

```csv
id,logo,name,phone,status,address,website,industry,owner_id,domain_name,search_text,company_size,annual_revenue
crm.Company.1,,Acme Corp,'+1-555-0100,lead,"{""zip"":""94105"",""city"":""San Francisco"",""street"":""100 Innovation Drive"",""country"":""USA""}",https://acme.com,technology,iam.Account.account_recruiter_kim,acme.com,,201-1000,USD 50000000
```

Two cell rules are visible here. The `'` before the phone number is the
formula guard. Facet writes it before text that starts with `=`, `+`, `-`,
or `@`, so a spreadsheet shows the text and does not evaluate it. A money
cell carries its currency: `USD 50000000`.

## Limits

| Limit               | Rule                                                                                     |
| ------------------- | ---------------------------------------------------------------------------------------- |
| File size           | A file over 50 MB is refused. 50 MB is the default; your instance may differ.            |
| Download window     | Facet keeps export files for 30 days by default. After that, the link stops working.     |
| Match key           | The `id` column is the only match key. Facet cannot match by name or another field.      |
| File fields         | A file field exports as its identifier only. The file content does not move.             |
| Sidecars and children | Comments, attachments, child documents, and other sidecar data do not move this way.   |

Cell rules for the file:

- A money cell needs the currency: `USD 10`.
- An empty cell clears the field on update. A column you omit leaves the
  field unchanged.
- Facet writes a leading `'` before text that starts with `=`, `+`, `-`, or
  `@`. Import removes one leading `'`.
- A document written before the last change to the list's definition exports
  in its stored older shape.

## Troubleshooting

### Nothing was imported, and a row message names a field

For example: "Nothing was imported." with "Row 3, field amount: ...".

One row failed validation. Nothing was written. Fix that row and submit the
file again.

### The file shape does not match the header

For example: "Row 2: has 3 cells but the header declares 2 columns".

Facet checks the file shape before the job starts. The message names the
faulty row. Fix the row, then import again.

### The export failed

For example: "Export failed — check the notifications for the error."

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

- [Lists, filters and saved views](/use/finding/lists-and-views/) — the
  current view decides what **CSV — current view** exports.
- [Notifications](/use/notifications/) — finished jobs deliver the
  download link here.
- [History and undo](/use/documents/history-undo/) — every imported row appears
  in the document history.
- [Your settings, sessions and API keys](/use/account/) —
  create the API key for the command-line example.
- [Build domains](/build/) — for authors: where the bundle import and
  export live.
