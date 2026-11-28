---
title: Hide a field from some roles
description: Tag sensitive fields so only the roles you choose can read them — on screens, in the API, and in the audit log.
type: how-to
audience: [admin, author]
features: [RBC-04, AUD-03]
verified_at: eee55a2
sidebar:
  order: 5
---

Lucía leads the Brightwater warehouse. She reads every item all day — she
needs names, categories, serial numbers. What she does not need is what each
item cost. The `purchase_price` field carries the `finance` tag, her
*Warehouse* role does not hold it, and the field is absent from everything she
sees. Not greyed out, not zero — absent, in the app and in the API alike.

A **field tag** is a sensitivity label on a field. A role declares which tags
it may see with its `visible_tags` list. Facet hides every other field on
reads, refuses writes into hidden fields, and removes their values from the
audit log. The rule fails closed: a tag that no role grants hides the field
from everyone.

## When to use this

- A field holds data that only some roles may see, for example a salary.
- You want one visibility rule that every surface applies the same way.
- You need the same hiding in the audit log, not only in live reads.

## Before you start

- **Field definitions.** You edit them — see
  [Designing doctypes](/build/model/data/design-doctypes/).
- **Role content.** You edit it — see
  [Roles and permissions](/admin/people/roles-and-permissions/).

## Steps

### 1. Tag the field

```yaml
# equipment.Item definition (the Brightwater example)
fields:
  purchase_price:
    type: money
    currency: EUR
    tags: ["finance"]
```

A field without `tags` carries the tag `default`.

### 2. Grant the tag on a role

```json
{
  "name": "manager",
  "visible_tags": ["default", "finance"]
}
```

A role that must not see the field keeps the default `visible_tags` of
`["default"]`. At Brightwater, `manager` lists `finance`; `sales` and
`warehouse` do not.

### 3. Check what each role sees

Nadia reads an item with the *Manager* role:

```json
{"name": "Festival tent 5x5", "purchase_price": {"value": "4800.00", "currency": "EUR"}, "status": "available"}
```

Tom reads the same item with the *Sales* role:

```json
{"name": "Festival tent 5x5", "status": "available"}
```

There is no `purchase_price` key in Tom's response, not a null.

| Caller | `visible_tags` | Reads `purchase_price` |
| --- | --- | --- |
| Nadia · manager | `["default", "finance"]` | yes, with its value |
| Tom · sales | `["default"]` | the field is absent from the response |
| Lucía · warehouse | `["default"]` | the field is absent from the response |

## Explanation

### The visibility rule

A field is visible when every one of its tags sits in the role's
`visible_tags`. The wildcard list `["*"]` sees every field. Everything else
fails closed.

### Read masking

Facet omits invisible fields at every nesting level: object properties, array
items, and dictionary values. An invisible parent hides its whole subtree.
Content keys that the definition does not know are omitted too, for every real
principal.

### Write guards

- A write into an invisible field is refused with `403`. The error names the
  content path. An explicit `null` counts as a write.
- The guard runs on the raw submitted body before format validation. A caller
  that cannot see a field never learns its type contract from a `422`.
- A transition guard compares the state before and after the write. It
  resolves members inside object values, dictionary keys, and secret markers to
  the field that owns them. A change that lands inside an invisible field is
  refused.
- Trusted lifecycle work still populates invisible fields: defaults, computed
  fields, and hooks.

### Audit redaction

The change log stores real values. Facet removes invisible values per
calling principal when it reads the log. The response lists the removed
content paths in a `redacted` metadata block. Each entry is an array of path
segments — the same shape the diff paths use.

| Row shape | What the caller sees |
| --- | --- |
| Full content row (create, snapshot, delete tombstone) | invisible values removed at every level; a visible parent keeps its visible part |
| Update diff | a `set` entry at an invisible path keeps its path but loses its value |
| Missing definition | all values removed — fail closed |

No marker enters the stored content. The `redacted` list is the only trace of
the removal.

:::tip
Rollback checks visibility on the real transition, not on the log entry. A
rollback that would rewind a value into an invisible field answers `403` —
see [Roll back a change](/admin/history/roll-back/).
:::

### Tags are not secrets

Tags hide a field per role. Two field kinds hide from everyone:

- A `secret` field never stores its value in a document or in the log.
- A `write_only` field accepts input and never comes back on reads.

See [Secret and write-only fields](/build/model/data/secret-fields/).

## Troubleshooting

### A field is missing from a response

Check the field's `tags` and the role's `visible_tags`. A tag that the role
does not list hides the field.

### A write answers `403` for a field you did not intend to touch

An explicit `null` in the body counts as a write. Omit the key instead.

### A history row shows no value

Redaction for your role. A role with the tag reads the value in the same row.

### A hook fills an invisible field and works

Lifecycle work is trusted. Only caller writes and caller-driven transitions
are guarded.

## Related

- [Roles and permissions](/admin/people/roles-and-permissions/) — where `visible_tags` lives.
- [Show each role only its rows](/admin/people/row-scopes/) — narrow rows the same way tags narrow fields.
- [See who did what](/admin/history/audit/) — where the `redacted` block appears.
- [Secret and write-only fields](/build/model/data/secret-fields/) — hiding from everyone, not per role.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Roles: who sees and does what](/discover/how-it-works/roles/)
