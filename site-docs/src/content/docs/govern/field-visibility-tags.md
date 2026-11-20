---
title: Field visibility with tags
description: Hide sensitive fields per role on reads, refuse writes into them, and redact them in the audit log.
audience: [admin, author]
features: [RBC-04, AUD-03]
sidebar:
  order: 5
verified_at: fd345fe3
---

A field can carry one or more sensitivity tags. A role declares which tags it
may see with its `visible_tags` list. Facet hides every other field on reads,
refuses writes into hidden fields, and removes their values from the audit
log. The rule fails closed: a tag that no role grants hides the field from
everyone.

## When to use this

- A field holds data that only some roles may see, for example a salary.
- You want one visibility rule that every surface applies the same way.
- You need the same hiding in the audit log, not only in live reads.

## Before you start

- **Field definitions.** You edit them — see
  [Designing doctypes](/build/designing-doctypes/).
- **Role content.** You edit it — see
  [Roles and permission lines](/govern/roles-permission-lines/).

## Steps

### 1. Tag the field

```yaml
# hr.Employee definition
fields:
  name:
    type: string
  salary:
    type: money
    currency: EUR
    tags: ["salary"]
```

A field without `tags` carries the tag `default`.

### 2. Grant the tag on a role

```json
{
  "name": "hr_partner",
  "visible_tags": ["default", "salary"]
}
```

A role that must not see the field keeps the default `visible_tags` of
`["default"]`.

### 3. Check what each role sees

| Caller | Reads `name` | Reads `salary` |
| --- | --- | --- |
| `hr_partner` (`["default", "salary"]`) | yes | yes, with its value |
| `team_lead` (`["default"]`) | yes | the field is absent from the response |

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

The mutation log stores real values. Facet removes invisible values per
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
see [Rolling back changes](/govern/rolling-back/).
:::

### Tags are not secrets

Tags hide a field per role. Two field kinds hide from everyone:

- A `secret` field never stores its value in a document or in the log.
- A `write_only` field accepts input and never comes back on reads.

See [Secret and write-only fields](/build/secret-write-only-fields/).

## Example

An employee record carries `name` and the tagged `salary` field from step 1.

1. `hr_partner` reads the employee. The response holds `name` and `salary`
   with its value.
2. `team_lead` reads the same employee. The response holds `name` only. There
   is no `salary` key, not a null.
3. `team_lead` sends a patch that sets `salary` to `null`. Facet answers `403`
   and names the path: an explicit null is a write.
4. `team_lead` opens the employee history. The salary rows show without
   values, and the `redacted` block names the paths. `hr_partner` reads the
   same history and sees the values.

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

- [Roles and permission lines](/govern/roles-permission-lines/) — where `visible_tags` lives.
- [Row scopes](/govern/row-scopes/) — narrow rows the same way tags narrow fields.
- [Auditing activity](/govern/auditing-activity/) — where the `redacted` block appears.
- [Secret and write-only fields](/build/secret-write-only-fields/) — hiding from everyone, not per role.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
