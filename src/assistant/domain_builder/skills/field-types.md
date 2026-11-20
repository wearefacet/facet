---
title: Field Types
description: When to use each FieldType, with examples and gotchas. Covers nested schemas, computed fields, and access control.
tags: [schema, fields]
---

# Field Types

Every entry under `fields` has a `type`. The full enumeration:

| Type | When to use | Notes |
|---|---|---|
| `string` | Short text (label, slug, foreign key string). | |
| `longtext` | Multi-line text (notes, comments). | `\r\n` is normalized to `\n` before storage. |
| `enum` | A value drawn from a fixed list. | Supply `values: [a, b, c]` or the object form `values: [{key, label, color}]`. |
| `integer` | Counters, quantities. | |
| `money` | Currency amounts. | Stored as integer cents; the doctype definition declares the currency. |
| `boolean` | True/false flags. | |
| `datetime` | ISO-8601 timestamps. | Stored as UTC RFC-3339 (`...Z`). |
| `date` | Calendar date `YYYY-MM-DD` (no time). | Used for `hire_date`, `effective_date`, `date_of_birth`. |
| `color` | CSS color values. | Parsed and normalized (hex, rgb, hsl, …). |
| `object` | A nested JSON sub-document. | Declare `properties: {...}` for sub-fields. |
| `array` | A list of nested sub-documents. | Declare `items: {...}` for the sub-document schema. |
| `dictionary` | A map of string → typed value. | Declare `values: {...}` for the value schema. |
| `child` | An embedded child-doctype reference. | Used for composition; see read_skill("children-and-composition"). |
| `reference` | A typed link to another document. | Takes optional `owned: true` (cascade delete) and `collection: bool` (multi-reference). |
| `data` | A computed field — not user-writable. | Must declare `compute: <func_name>` and `compute_when: [fields]`. |
| `period` | Datetime range `{start, end}`. | Range operators: `contains`, `overlaps`, `within`. |
| `dateperiod` | Calendar-date range `{start, end}` (`YYYY-MM-DD`). | Same range operators as `period`. |

## Presentation fields

Every field may carry `title` (human-readable label) and `description` (help text). The fixtures always set them — the UI renders `title` as the field label. Use `title` for anything the user will see.

## Constraints

| Key | Applies to | Description |
|---|---|---|
| `required` | all | Field must be present on create. |
| `unique` | string, reference, integer | Value must be unique across the doctype (e.g. `crm.Company.name`, `hr.Employee.person`). |
| `default` | all | Applied when the field is absent on create (e.g. `status: active`). |
| `min` / `max` | integer, money | Range validation (e.g. `rating` 1–5, `probability` 0–100). |
| `pattern` / `pattern_flags` | string | Regex validation. |
| `filters` | see the capability table below | Declares which filter capabilities the field serves. Each capability adds one index family and one operator family. A field without `filters` cannot be filtered — a `filters[field__op]` query answers 422. |

## Filter capabilities

A field declares its filter capabilities as a `filters:` list. Use the capability names, never raw operator names (`operators:` is not an input key).

| Capability | Operators served | Valid on |
|---|---|---|
| `equality` | `eq`, `ne`, `in` | single-value scalar, numeric, datetime, money, enum, `period`, `dateperiod`, `reference` |
| `comparison` | `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between` | scalar, numeric, datetime, money, enum — not `boolean`, not ranges, not containers |
| `text_search` | `match`, `starts_with` | string-like (`string`, `longtext`, `phone`, `url`, `enum`) |
| `interval` | `eq`, `contains`, `overlaps`, `within` | `period`, `dateperiod` |
| `membership` | `eq`, `contains`, `overlaps` | `array` |
| `currency` | `currency` | `money` |

Typical choices: a string used for search gets `[equality, text_search]`; a status enum gets `[equality]`; a boolean flag gets `[equality]`; a money amount gets `[comparison, currency]`; a numeric measure or timestamp gets `[comparison]`; a reference gets `[equality]`; an `array` gets `[membership]`.

**Declare `filters` on every field a user may filter or group by.** A field without `filters` derives no operators: the filter bar and the kanban lane editor never list it, and a `field__op` query answers 422. The flags are exactly what users filter on — a boolean like `completed` needs `[equality]`, and a money field without the `currency` capability cannot answer "which currency" filters.

## Enum values

Prefer the object form — the fixture convention — so the UI gets a readable label and a stable color:

```yaml
status:
  type: enum
  values:
    - {key: active, label: Active, color: "#b16147"}
    - {key: on_leave, label: "On Leave", color: "#008f82"}
  default: active
  filters: [equality]
completed:
  type: boolean
  default: false
  filters: [equality]
price:
  type: money
  currency: USD
  filters: [comparison, currency]
```

`key` is the stored value; `label` defaults to the humanized key; `color` defaults to a deterministic hash. The legacy string form `values: [planned, in_progress, done]` also works.

## Nested schemas

- `object.properties` — declare a sub-object's fields as `{type: object, properties: {name: {type: string}, ...}}`. Without `properties`, the object is free-form (see `identity.Person.contact`).
- `array.items` — declare the element schema as `{type: array, items: {type: object, properties: {...}}}`. A plain string array is `{type: array, items: {type: string}}` (see `hr.Candidate.tags`).
- `dictionary.values` — declare the value schema as `{type: dictionary, values: {type: string}}`.

Example (from `hr.Candidate`):

```yaml
address:
  type: object
  properties:
    street: {type: string}
    city: {type: string}
    postal_code: {type: string}
    country: {type: string}
```

## Reference fields

- A `reference` field's `doctype` may carry a domain prefix for cross-domain links (e.g. `identity.Person`). Bare names resolve to the same domain.
- References that should be owned by the parent (cascade delete) use `owned: true`.
- A collection of references uses `collection: true` (multi-valued).
- A reference may declare `filter` — a hash of conditions the referenced document must satisfy (e.g. `{status__eq: active}`).
- Reference values are stored fully qualified as `{domain}.{Doctype}.{id}` (e.g. `iam.Account.account_recruiter_kim`). See read_skill("reference-patterns").

## Computed (`data`) fields

- `data` fields MUST NOT appear in user input. `Document::Validation` rejects them on create/update.
- The script defines `export.compute_<suffix>(ctx)` where `<suffix>` matches the field's `compute` value.
- **The function must RETURN the value** — the returned value is what lands in the field. A function that only mutates `ctx.root` and returns nothing leaves the field unset:

```lua
function export.compute_total_cents(ctx)
    return (ctx.root.hours or 0) * (ctx.root.rate_cents or 0)
end
```

- A `ctx.root` write to the computed field is honoured as a fallback (when the function returns nil), but the returned value wins. A `nil` return with no write clears the field — use it for conditional compute.
- `compute_when` lists the field names whose change should trigger recompute. Use `[<field>]` after updates.
- Compute order is definition order; `ctx.root` is updated between computations so later computes see earlier results.

## Access control

- `read_only: true` — server-set but user-visible.
- `write_only: true` — set by the user, hidden on reads.
- `tags: ["tag"]` — free-form sensitivity tags on the field.

## Visibility and sharing

`tags` is the single sensitivity label set, read by two gates. **Role visibility:** a field is emitted only when the caller's role `visible_tags` cover every tag on the field; untagged fields need only `default` (every role has it unless narrowed); `"*"` on the role exposes everything. **Cross-domain grants:** a `core.DomainGrant` resource entry names tags; a field flows to the consumer when any of its tags appears in the granted list, and untagged fields resolve to `["default"]` there — a grant naming `default` reaches every untagged field.
