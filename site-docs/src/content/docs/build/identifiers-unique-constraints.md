---
title: Identifiers and unique constraints
description: Generate readable reference numbers and keep field values unique across documents.
audience: [author]
features: [DOM-10, DOM-11]
sidebar:
  order: 5
verified_at: fd345fe3
---

By default Facet names every document with a ULID: a long, sortable, opaque id. Many records read better with a number people can say out loud, such as `INV-2026-0001`. An `identifier` block on the doctype generates such numbers. Uniqueness rules on fields keep the data clean in a second way: no two documents may carry the same value.

## When to use this

Add an identifier when users quote document numbers in speech, email, or print. Add `unique` when a duplicate value would be a data error, such as two employees with the same email address.

## Before you start

- **The identifier becomes the document id.** It is generated at create time and never changes.
- **One counter per doctype.** Facet keeps one counter per doctype, shared by every writer.

## Steps

### 1. Shape the number with a template

| Token | Meaning |
| --- | --- |
| `#` | One digit of the counter, zero-padded. Four digits count from `0001`. |
| `{year}` | The current year, for example `2026`. |
| `{month}` | The current month, for example `06`. |
| `{day}` | The current day, for example `15`. |
| other text | Literal text, copied as is: `INV-`, `-`, `TKT-`. |

The template needs at least one `#` group, and a group is at most 18 digits. When the year or month changes, the counter resets and numbering starts again at 1.

### 2. Declare the identifier block

```json
"identifier": {
  "template": "INV-{year}-####",
  "genonly": true
}
```

`genonly: true` stops callers from supplying their own id on create. Without it, the template still generates the id when the caller omits one.

### 3. Add unique fields

Set `unique: true` on any field whose value must differ between documents. Facet checks the rule on every create and update, so an empty value on one document and a missing value on another do not collide.

```json
"email": {
  "type": "string",
  "required": true,
  "unique": true,
  "filters": ["equality", "text_search"]
}
```

## Example

```json
{
  "domain": "crm",
  "doctype": "Invoice",
  "aggregate_root": true,
  "schema_version": 1,
  "identifier": { "template": "INV-{year}-####", "genonly": true },
  "fields": {
    "customer": { "type": "reference", "doctype": "crm.Company", "required": true },
    "total": { "type": "money", "currency": "EUR", "filters": ["comparison"] }
  }
}
```

The first three creates produce the ids `INV-2026-0001`, `INV-2026-0002`, and `INV-2026-0003`. On 1 January, numbering restarts at `INV-2027-0001`. The number is the document id, so pages show it and users can look a document up by it (the `id__match` filter).

:::caution
When all digit groups reach their maximum, Facet falls back to a ULID for the next id. Give a fast-moving doctype enough digits, for example `######`.
:::

## Troubleshooting

### A write answers `422` with a uniqueness error

Another document of the same doctype already holds this value. Find it by filtering the list on the field, then change the value or correct the duplicate.

### The caller cannot choose the id

The doctype declares `genonly: true`. Callers omit the id and let Facet generate it.

### A document carries a ULID instead of a number

The counter overflowed, or the document was created before the identifier block was added. Identifiers apply to documents created after the block exists.

### Two doctypes restart their counters at different times

Each template carries its own time variables. A template with `{month}` resets monthly; a template with only `{year}` resets yearly.

## Related

- [Doctype schema (reference)](/reference/doctype-schema/) — the identifier block and field constraints in full.
- [The mutation log](/concepts/mutation-log/) — where the generated id is recorded.
- [Checking a domain before publish](/build/checking-before-publish/) — run the checks on your draft before you publish.
