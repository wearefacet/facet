---
title: Bulk import and export
description: Move a doctype's documents in and out as CSV or JSON through the export and import job routes.
type: how-to
audience: [developer]
features: [DOC-11]
verified_at: eee55a2
sidebar:
  order: 5
---

These routes move one doctype's documents out of Facet and back in as CSV or
JSON. An export runs in a snapshot: it reads one point in time. An import
runs in one transaction: every row lands, or none does.

> **For agents:** Export: `POST /Api/<domain>/<doctype>/export?format=csv` answers `202
> {job_id, status_url}` (wait=true returns the file directly). Import: `POST
> /Api/<domain>/<doctype>/import` with the CSV or JSON body answers `202 {job_id, row_count,
> status_url}`; poll `GET /Api/<domain>/<doctype>/import_export/<job_id>` for
> `{id, status, error, result}`. One transaction: the first failing row aborts all. Upsert keys on
> the `id` column. POSTs need `X-Requested-With: XMLHttpRequest` for cookie sessions.

## When to use this

Use the import/export routes when:

- You move a doctype into or out of a Facet instance.
- You hand a spreadsheet view of a doctype to someone who does not use Facet.
- You load an initial data set from another system.

## Before you start

- Exports need `read` rights on the doctype. An import needs `create` and
  `update` rights, because an upsert can do either.
- The routes refuse child doctypes (`member_of`) and [sidecar doctypes](/build/model/relations/comments-attachments/) in
  both directions.
- Cookie sessions must send `X-Requested-With: XMLHttpRequest` on the POSTs.
  A bearer credential without a cookie is exempt.

The live calls on this page ran against a dev instance at
`https://facet.localhost:3443` with the Brightwater Rentals data loaded.

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

A `wait=true` call blocks until the job ends and returns the file itself.
This session exported the Brightwater companies:

```sh
curl -sk -b facet-cookies.txt -H 'X-Requested-With: XMLHttpRequest' \
  -X POST 'https://facet.localhost:3443/Api/clients/Company/export?format=csv&wait=true' \
  -o companies.csv
```

`companies.csv` holds:

```csv
id,city,name,account_manager
06H1FM1B3MXBPS0JYVM3BDD154,Lyon,Maison Lumière,iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE
06H1FM1B68KB1PJVVAM92B38YS,Annecy,Festival des Collines,iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE
```

Without `wait=true`, the call answers `202`:

```json
{
  "job_id": "01JBK2M4N6P8R0T2V4X6Z8B2D4",
  "status_url": "/Api/clients/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
}
```

Poll the status route until `status` is `succeeded` or `failed`, then
download the file from the download route. On a failed job the download
route is not the file: read `error` from the status answer.

`format=csv|json` picks the output. An unknown format answers `422`:

```json
{ "error": "Unknown or missing format: xlsx (supported: csv, json)" }
```

Filters ride the list grammar, for example
`filters[status__eq]=confirmed`. `sort`, `page`, `per_page`, and `items`
answer `422`: the export is fixed to id order.

### 2. Export the current table view

```sh
curl -sk -b facet-cookies.txt -X POST \
  'https://facet.localhost:3443/Api/clients/Company/export_view' \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  -d '{"columns": ["name", "city"], "sort": ["-created_at", "id"], "filters": {"city__eq": "Lyon"}, "timezone": "Europe/Paris"}'
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
`Content-Type`, else from the body shape: a leading `[` reads as JSON. This
session imported one Brightwater-shaped row:

```sh
cat > probe.json <<'EOF'
[{"content":{"name":"Import Probe Co","city":"Bastia"}}]
EOF

curl -sk -b facet-cookies.txt -X POST \
  'https://facet.localhost:3443/Api/clients/Company/import' \
  -H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest' \
  --data-binary @probe.json
```

The answer is `202`:

```json
{
  "job_id": "06H1FSDH1016A18QYX19T1YB79",
  "row_count": 1,
  "status_url": "/Api/clients/Company/import_export/06H1FSDH1016A18QYX19T1YB79"
}
```

Poll the status route:

```json
{
  "id": "06H1FSDH1016A18QYX19T1YB79",
  "status": "succeeded",
  "error": null,
  "result": { "created": 1, "skipped": 0, "updated": 0, "row_count": 1 }
}
```

The structural parse runs before the job. A malformed file answers `422`
and names the row:

```json
{ "error": "row 2: has 3 cells but the header declares 2 columns" }
```

Bad quoting, an unknown header column, and a cell count that does not match
the header all fail here. A cell-level problem, for example a bad money
value in row 900, surfaces in the job result instead.

## Example

An end-to-end round trip: export with `wait=true`, import the file back,
poll the job:

```sh
BASE=https://facet.localhost:3443
X='X-Requested-With: XMLHttpRequest'

# 1. Export and wait: the call returns the CSV file directly.
curl -sk -b facet-cookies.txt -H "$X" \
  -X POST "$BASE/Api/clients/Company/export?format=csv&wait=true" -o companies.csv

# 2. Import the file back.
curl -sk -b facet-cookies.txt -H "$X" -H 'Content-Type: text/csv' \
  -X POST "$BASE/Api/clients/Company/import" --data-binary @companies.csv

# 3. Poll the job status (the job_id from the import answer).
curl -sk -b facet-cookies.txt \
  "$BASE/Api/clients/Company/import_export/01JBK2M4N6P8R0T2V4X6Z8B2D4"
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
- **Attribution.** Every row records the import as its cause in the audit.

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
| Money | `EUR 4800.00` — the currency prefix is required on import. |
| Boolean | `true` / `false`. |
| Reference | Qualified id, for example `clients.Company.<id>`. |
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

A money cell needs the currency prefix: `EUR 4800.00`, not `4800.00`.

**Some rows are `skipped`.**

Their ids point at deleted documents. An import never resurrects a
document. Remove the ids to create new documents.

**The download answers `404`.**

The result file was pruned after the retention window — see
[Retention](/admin/history/retention/). Export again.

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the list filter grammar the export filters reuse.
- [Upload and serve files](/build/apps/data/files/) — how the result file is stored and read back.
- [Retention](/admin/history/retention/) — the window that bounds a download link.
- Internals on GitHub:
  [import-export.md](https://github.com/wearefacet/facet/blob/main/doc/backend/import-export.md).
