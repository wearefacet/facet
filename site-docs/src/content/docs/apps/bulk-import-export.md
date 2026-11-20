---
title: Bulk import/export via API
description: Move a doctype's documents in and out as CSV or JSON through the import/export routes.
audience: [developer]
features: [DOC-11]
sidebar:
  order: 14
verified_at: a77c6171
---

These routes move one doctype's documents out of Facet and back in as CSV
or JSON. An export runs in a snapshot: it reads one point in time. An
import runs in one transaction: every row lands, or none does.

> **For agents:** Export: `POST /Api/<domain>/<doctype>/export?format=csv`
> answers `202 {job_id, status_url}`. Poll `GET
> /Api/<domain>/<doctype>/import_export/<job_id>`, then download from `GET
> /Api/<domain>/<doctype>/import_export/<job_id>/download`; `wait=true`
> returns the file directly. Import: `POST /Api/<domain>/<doctype>/import`
> with the CSV or JSON body; a `422` names the row and the problem. Upsert
> keys on the `id` column; one transaction; the first failing row aborts
> all. POSTs need `X-Requested-With` for cookie sessions.

## When to use this

Use the import/export routes when:

- You move a doctype into or out of a Facet instance.
- You hand a spreadsheet view of a doctype to someone who does not use Facet.
- You load an initial data set from another system.

## Before you start

- Exports need `read` rights on the doctype. An import needs `create` and
  `update` rights, because an upsert can do either.
- The routes refuse child doctypes (`member_of`) and sidecar doctypes in
  both directions.
- Cookie sessions must send `X-Requested-With: XMLHttpRequest` on the
  POSTs. A bearer credential without a cookie is exempt.

## Routes

| Method | Route | Purpose |
| --- | --- | --- |
| `POST` | `/Api/<domain>/<doctype>/export` | Export a whole doctype. `format=csv\|json` is required. `wait=true` and the list filters are optional. |
| `POST` | `/Api/<domain>/<doctype>/export_view` | Export the current table view. JSON body: `{columns, sort, filters, timezone}`. |
| `POST` | `/Api/<domain>/<doctype>/import` | Import a CSV or JSON file. The structural parse runs at enqueue. |
| `GET` | `/Api/<domain>/<doctype>/import_export/<job_id>` | Job status: `{id, status, error, result}`. |
| `GET` | `/Api/<domain>/<doctype>/import_export/<job_id>/download` | The result file. Succeeded exports only. |

## Steps

### 1. Export a doctype

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export?format=csv" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "X-Requested-With: XMLHttpRequest"
```

The answer is `202`:

```json
{
  "job_id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status_url": "/Api/crm/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
}
```

Poll the status route until `status` is `succeeded` or `failed`. Then
download the file from the download route. With `wait=true` the call
blocks until the job ends: on success the answer is the file itself, on
failure it is `500` with `{"job_id", "error"}`.

Filters ride the list grammar, for example `filters[status__eq]=active`.
`sort`, `page`, `per_page`, and `items` answer `422`: the export is fixed
to id order.

### 2. Export the current table view

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export_view" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Requested-With: XMLHttpRequest" \
  -d '{"columns": ["name", "status", "amount"], "sort": ["-created_at", "id"], "filters": {"status__eq": "active"}, "timezone": "Europe/Paris"}'
```

- `columns` is required. Each key must be a doctype field or a system
  column (`id`, `created_at`, `updated_at`). An unknown key answers `422`
  and names the key.
- `sort` uses the list grammar. A bad entry answers `422`.
- `datetime` cells render in the requested `timezone`. Without one they
  stay UTC.

:::note[This file is a view, not an import source]
A view export renders timestamps in the requested zone. A re-import of it
fails on the zone-less cells.
:::

### 3. Import a file

The route takes the format from a `format=` param, else from the
`Content-Type`, else from the body shape: a leading `[` reads as JSON.

```sh
curl -s -X POST "https://facet.company.tld/Api/crm/Company/import" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: text/csv" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-binary @companies.csv
```

The answer is `202` with `{"job_id", "row_count", "status_url"}`.

The structural parse runs before the job. A malformed file answers `422`
and names the row:

```json
{ "error": "row 2: has 3 cells but the header declares 2 columns" }
```

Bad quoting, an unknown header column, and a cell count that does not
match the header all fail here. A cell-level problem, for example a bad
money value in row 900, surfaces in the job result instead.

## Example

An end-to-end round trip: export with `wait=true`, import the file back,
poll the job:

```sh
# 1. Export and wait: the call returns the CSV file directly.
curl -s -X POST "https://facet.company.tld/Api/crm/Company/export?format=csv&wait=true" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "X-Requested-With: XMLHttpRequest" \
  -o companies.csv

# 2. Import the file back.
curl -s -X POST "https://facet.company.tld/Api/crm/Company/import" \
  -H "Authorization: Bearer $FACET_TOKEN" \
  -H "Content-Type: text/csv" \
  -H "X-Requested-With: XMLHttpRequest" \
  --data-binary @companies.csv

# 3. Poll the job status (the job_id from the import answer).
curl -s "https://facet.company.tld/Api/crm/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4" \
  -H "Authorization: Bearer $FACET_TOKEN"
```

A succeeded export job reports:

```json
{
  "id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status": "succeeded",
  "error": null,
  "result": { "artifact_id": "01JARQ5G7X9K2M3N4P5Q6R7S8T", "row_count": 128, "format": "csv" }
}
```

## The import contract

- **One transaction.** The first failing row aborts the import. Zero rows
  persist.
- **The failure names the row.** The report carries `{row, field, message}`.
- **Upsert by the `id` column.** A live id updates the document. A
  tombstoned id is skipped; an import never resurrects a deleted document.
  An absent id creates one.
- **Both rights are needed.** The first row your role may not write fails
  the file.
- **Attribution.** Every row records `actioner_id: "import"` in the audit.
- **`genonly` doctypes refuse supplied ids.** A doctype whose identifier is
  system-generated never creates a document from a supplied id.

  A wait-mode import answers `200` with `{row_count, created, updated,
  skipped}`. An expected row failure answers `422` with the failing row.

## Job model

- A job runs once. Fix the input and submit again.
- The status and download routes answer only the requesting account.
  Anyone else gets `404`, so job ids do not leak.
- Completion publishes an event on the doctype's stream and sends the
  requesting account a notification with a download link.

## CSV cell conventions

| Cell | Convention |
| --- | --- |
| Scalar text | As stored. |
| Structured types | JSON in the cell. |
| Money | `USD 1.0` — the currency prefix is required on import. |
| Boolean | `true` / `false`. |
| Reference | Qualified id, for example `crm.Company.abc`. |
| File | The artifact id only; bytes do not move. |
| Empty cell | Decodes to `null`; it clears the field on update. |
| Missing column | Leaves the field untouched. |
| Text starting `=`, `+`, `-`, `@`, or a tab | Exports with a leading `'` — the formula guard. Decode strips one leading `'`. |

## Troubleshooting

**The import POST answers `413`.**

The body is over the upload cap. Split the file and import the parts.

**The enqueue answers `422` and names a row.**

The structural parse failed: bad quoting, an unknown header column, or a
cell count that does not match the header. Fix that row and submit again.

**The job fails on a `money` field.**

A money cell needs the currency prefix: `USD 1.0`, not `1.0`.

**Some rows are `skipped`.**

Their ids point at deleted documents. An import never resurrects a
document. Remove the ids to create new documents.

**The download answers `404`.**

The result file was pruned after the retention window — see
[Retention](/govern/retention/). Export again.

## Related

- [Use the REST API](/apps/rest-api/) — the list filter grammar the export filters reuse.
- [Uploading and serving files](/apps/files/) — how the result file is stored and read back.
- [Retention](/govern/retention/) — the window that bounds a download link.
- Internals on GitHub:
  [import-export.md](https://github.com/wearefacet/facet/blob/main/doc/backend/import-export.md).
