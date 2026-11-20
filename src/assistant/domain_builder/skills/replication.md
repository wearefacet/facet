---
title: Replication
description: replicate config (via, field, on_source_delete), grants on core.Domain, reference-scoped semantics, draft inertness.
tags: [replication, cross-domain]
---

# Replication

Replication copies a field value from a source document (in another domain) into a consumer document's `replicate` field. The source field is the authority; the consumer field is read-only and kept in sync.

## `replicate` declaration

On a consumer-doctype field:

```json
{
  "fields": {
    "person_name": {
      "type": "string",
      "replicate": {
        "via": "person",
        "field": "full_name",
        "on_source_delete": "keep"
      }
    }
  }
}
```

| Key | Required | Description |
|---|---|---|
| `via` | yes | The reference field on this doctype that points to the source. |
| `field` | yes | The source field name (on the source doctype) to replicate. |
| `on_source_delete` | no | `keep` (default) or `unset`. |

## Grants on `core.Domain`

The source domain must grant the consumer domain read access to the source field:

```json
{
  "id": "identity",
  "grants": [
    {"to": "hr", "doctype": "Person", "fields": ["full_name"]}
  ]
}
```

- `fields` can be `["*"]` to grant all fields.
- A grant is required; without it `Doctype::Check` flags the replicate as broken.

## Reference-scoped semantics

A consumer only receives data for source records its own documents reference. If `via: "person"`, only the `full_name` of Person records actually referenced by an Employee is pulled. No grant implies "see every source row" — the reference field is the implicit WHERE clause.

## Draft inertness

A `replicate` declaration is valid schema in a draft domain, but `Replication::Registry` filters out draft domains entirely — draft bindings never enter the runtime graph. The replicate field is inert until the draft is published (live domain → live bindings → registry rebuilds).

## `check_doctype` surfaces

- Missing `via` field on the consumer doctype.
- `via` field is not a reference type.
- Source doctype doesn't exist.
- Source field doesn't exist on the source doctype.
- Type mismatch between source field and replicate field.
- Missing grant on `core.Domain` for the consumer domain.
- Draft-source-for-live-consumer: a live domain cannot replicate from a draft domain.

## In draft

- You may declare `replicate` freely, but the values will be `null` until publish.
- `create_document` on a draft doctype with a `replicate` field will pull `null` (no source match in the draft's isolation).
- `check_doctype` will flag missing grants and missing sources — these are expected in draft; the iteration target is "no issues at publish time", not "no issues while drafting".
