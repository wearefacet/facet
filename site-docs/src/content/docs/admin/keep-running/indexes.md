---
title: Indexes
description: Watch the managed indexes Facet builds for doctype fields, and retry a failed index build.
type: how-to
audience: [operator]
features: [PLT-05]
verified_at: eee55a2
sidebar:
  order: 5
---

A list view got slower after a domain import, and you need to know why. Facet
manages its own PostgreSQL indexes. When an author declares a field
filterable or sortable, Facet computes the indexes that serve the
declaration. It builds them online and drops them when the field changes.
Your job as the operator is to watch the status surface and retry the rare
failure.

## When to use this

- You check index health after a schema change or a domain import.
- An index build failed and you need it back.
- You want to know why an index exists, or why one does not.

## Before you start

- The status route needs a wildcard `read` permission on `*.*` — the same
  rule as the [global audit log](/admin/history/audit/).
- The retry command runs from a host that reaches the database.
- Index DDL is safe to run while the server is live. It never blocks reads or
  writes on the documents.

## Two layers of indexes

Facet keeps two index families, and the status surface covers one of them.

**Managed doctype indexes** are the ones this page watches. Each serves one
field of one doctype, tracked in the `doctype_indexes` table, built and
dropped by Facet itself.

**System-level indexes** come with the schema and nobody manages them per
doctype. Two of them shape everyday behaviour:

- The search column carries a GIN trigram index, partial on
  `deleted_at IS NULL`. Full-text list search uses it.
- The links column carries a GIN index, partial the same way, for
  "which documents link to this one?" queries.

The partial predicate matters beyond speed: a deleted document is a
tombstone that keeps its content until the retention prune clears it. The
`deleted_at IS NULL` clause keeps tombstoned rows out of the indexes, so
their retained payloads never surface in search or link lookups.

## Steps

### 1. Read the index status

Open the index status page under **Configure → Platform**, or call the route:

```sh
curl -s -g -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/Indexes?filters[status__eq]=error&filters[domain__eq]=hr"
```

One row per managed index carries: `id`, `domain`, `doc_type`, `field_name`,
`index_type`, `index_name`, `status`, `error_message`, `created_at`, and
`updated_at`. The status lifecycle:

*One managed index from build to retirement.*

<!-- d2
direction: down
pending: pending
active: active {class: ok}
error: error {class: danger}
dropped: dropped

pending -> active
pending -> error
active -> dropped
error -> dropped
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/dcad920b-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/dcad920b-dark.svg" alt="Diagram" loading="lazy" />
</div>

- `pending` — the build is queued or running.
- `active` — the index is built and serving queries.
- `error` — the build failed. `error_message` holds the reason.
- `dropped` — the field no longer wants the index.

Filterable fields: `domain`, `doc_type`, `status`, `field_name`. Sortable:
the same set plus `index_type`, `created_at`, and `updated_at`. A live list
from the running instance, filtered to active indexes:

```text
count: 99
domain: equipment  doc_type: MaintenanceTicket  field: reported_by  btree  active
domain: equipment  doc_type: MaintenanceTicket  field: assignee     btree  active
domain: equipment  doc_type: MaintenanceTicket  field: status       btree  active
```

### 2. Retry failed builds

```sh
facet index:retry --domain hr --dry-run   # print the plan, run nothing
facet index:retry --domain hr             # run the retries
```

The command retries two kinds of rows:

- rows in `error` status, and
- `pending` rows stale for more than 10 minutes — the shape a dead build
  process leaves behind.

A fresh `pending` row belongs to a live build in the running server, so the
command never touches it. Each row is re-checked against the current doctype
definition: a still-wanted index is rebuilt; a field that no longer exists
drops the row. Rows are independent — one failure does not stop the others.
The command exits `0` when every attempt succeeded and `1` when at least one
failed.

## How Facet decides the indexes

The planner reads each field's declared `filters` capabilities — `equality`,
`comparison`, `text_search`, `interval`, `membership`, `currency`. One
capability maps to one index family:

| Declared capability | Index created |
| --- | --- |
| `equality` or `comparison` on a scalar field | One B-tree |
| `text_search` alone | One GIN trigram |
| `equality` / `comparison` plus `text_search` | Two indexes: B-tree and GIN trigram |
| `membership` on an `array` field | One GIN JSONB |
| `interval` on `period` / `dateperiod` | One GiST range index |

Three rules sit around the table:

- A field with `unique: true` gets a unique B-tree, with no capability
  needed.
- A `reference` field always gets one B-tree, whatever its capabilities
  declare.
- Computed, write-only, read-only, and free-form object fields take no index.

Every managed index is partial. The `WHERE` clause scopes it to one domain,
one doctype, and live rows, so each index stays small:

```sql
WHERE domain = 'hr' AND doc_type = 'Employee' AND deleted_at IS NULL
```

### Why failures are rare

Builds run as `CREATE INDEX CONCURRENTLY` in background fibres, so the
doctype save itself always succeeds. A global advisory-lock gate serializes
all managed DDL across fibres and processes, which prevents the deadlock two
concurrent builds would otherwise hit. Deadlocks that still occur retry with
backoff: 3 attempts at runtime, 5 in `index:retry`.

## Example

After a large domain import, one index failed. Recover it:

```sh
# What failed?
curl -s -g -H "Authorization: Bearer $(facet-cli apikey)" \
  "$(facet-cli host)/Api/Indexes?filters[status__eq]=error"

# Read error_message on the row, then plan the retry:
facet index:retry --domain crm --dry-run

# Run it, then confirm the row is active:
facet index:retry --domain crm
```

The row moves `pending` → `active`, and the doctype's list filters use the
index again.

## Troubleshooting

**A row stays `pending` for a long time.**

A big table builds for a while; `CONCURRENTLY` scans the whole table. Past 10
minutes of staleness, `index:retry` treats the row as dead and rebuilds it.

**An `error` row names a deadlock.**

The build retried and gave up. Run `facet index:retry` for the domain. It
drops any half-built leftover first, then rebuilds.

**A field declares `filters` but has no index row.**

The field type takes no index for that capability — for example
`membership` is valid on arrays only, and `color` takes no index. Check
[Field types](/build/model/data/field-types/) for the capability rules.

**A doctype save succeeded but a new index is missing.**

The build runs in the background after the save. Re-check the status route
before you investigate.

**A `dropped` row reappears.**

The field is back in the doctype definition, or the definition was
re-imported. The planner wants the index again, so a new build starts.

## Related

- [Field types](/build/model/data/field-types/) — where the `filters` capabilities come from.
- [Identifiers and unique constraints](/build/model/data/identifiers-uniqueness/) — the unique B-tree path.
- [Change a live domain safely](/build/model/change-a-live-domain/) — the schema changes that trigger builds.
- [First start and bootstrap](/admin/install/bootstrap/) — the CLI surface around `index:retry`.
- Internals on GitHub: [index-management.md](https://github.com/wearefacet/facet/blob/main/doc/backend/index-management.md), [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
