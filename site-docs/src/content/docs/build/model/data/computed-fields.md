---
type: how-to
title: Computed fields
description: Derive a field value with a Lua compute function and re-run it when its inputs change.
audience: [author]
features: [DOM-09]
sidebar:
  order: 3
verified_at: fd345fe3
---

A computed field keeps a value current without a user writing it. You declare the field, name a function, and list the inputs that trigger a re-run. Facet runs the function on create, again on every change of a listed input, and stores the result on the document.

## When to use this

Add a computed field for a value users would otherwise maintain by hand and get wrong: a total over order lines, a tenure in days, a display number assembled from parts. Never accept a computed field from user input; Facet rejects it.

## Before you start

- **Three parts.** A computed field has the type `data`, a `compute` name, and a `compute_when` list.
- **A function in the script.** The function must exist in the doctype script. Facet checks this when you save the doctype.
- **Read-only by design.** The compute may read documents but never write them. To change other documents, use an action or a domain hook.

## Steps

### 1. Declare the field

```json
"total": {
  "type": "data",
  "compute": "total",
  "compute_when": ["qty", "unit_price"]
}
```

The `compute` value names the exported function; Facet calls `compute_total`. Each entry in `compute_when` is either a field of the doctype or the name of a child relationship. Facet runs every computed field on create, and on update only those whose triggers intersect the changed fields.

### 2. Write the function

Return the value. The full module pattern applies, as in every doctype script.

```lua
local export = {}

function export.compute_total(ctx)
  return (ctx.root.qty or 0) * (ctx.root.unit_price or 0)
end

return export
```

Returning `nil` clears the field. Use that for a conditional value, for example a tenure that stays empty until the hire date exists.

### 3. Compute over children

When `compute_when` names a child relationship, Facet stages the live child rows for you in `ctx.children`, and re-runs the parent field whenever a child in that relationship changes.

```lua
local export = {}

function export.compute_order_total(ctx)
  local total = 0
  for _, line in ipairs((ctx.children or {}).lines or {}) do
    total = total + (line.qty or 0) * (line.price or 0)
  end
  return total
end

return export
```

The field declares `compute_when: ["lines"]`, where `lines` is the `children` entry of the doctype.

## Example

The definition below declares two input fields and the computed total.

```json
{
  "domain": "projects",
  "doctype": "WorkPackage",
  "aggregate_root": true,
  "schema_version": 1,
  "fields": {
    "qty": { "type": "integer", "min": 0 },
    "unit_price": { "type": "integer", "min": 0 },
    "total": { "type": "data", "compute": "total", "compute_when": ["qty", "unit_price"] }
  }
}
```

A create with `{"qty": 3, "unit_price": 250}` stores `total: 750`. An update of `qty` to `4` re-runs the function in the same write and stores `total: 1000`. When the trigger is a child relationship, the re-run writes the parent value as its own history entry.

:::note
The display name and search text of a doctype are derived too, but through Jinja2 templates, not through Lua. See [Display names and search text](/build/model/views/names-and-search/).
:::

## Troubleshooting

### The field stays empty

The function returned `nil`, or a trigger never fired. Check that every `compute_when` entry is a field name or a child relationship of the same doctype. Facet refuses the definition otherwise.

### The value is stale after a child changed

The `compute_when` list must name the child relationship, not a field of the child. With `["lines"]`, every change under `lines` re-runs the parent field.

### The write answers `422` with `Computed fields failed`

The function raised an error. Read the message, fix the function, and save the doctype. A failure rolls the whole write back, so no stale value is stored.

### A user tried to set the field

Computed fields reject user input by design. Remove the field from the form, or make it a normal field and compute nothing.

## Related

- [Lua API (reference)](/reference/lua-api/) — the compute surface and its limits.
- [The mutation log](/admin/under-the-hood/change-log/) — how a re-run lands in the history.
- [Display names and search text](/build/model/views/names-and-search/) — derive names and search text with Jinja2 templates.
