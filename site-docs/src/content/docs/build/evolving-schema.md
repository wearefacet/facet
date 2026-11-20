---
title: Evolve a schema
description: Change a live doctype safely with version bumps, Lua migrations, and reproject.
audience: [author]
features: [DOM-17, DOM-18]
sidebar:
  order: 19
verified_at: f1409cdc
---

Documents store the schema version they were written with. When you change a doctype, older documents catch up on read: Facet runs a small Lua function per version step and stores the result. You write the steps; Facet applies them without a backfill job.

## When to use this

- You add, rename, or remove a field on a live doctype.
- You split one field into two, or merge two into one.
- Lists or labels look stale after a definition change.

## Before you start

- **Update rights** on the doctype definition.
- **The current `schema_version`** of the doctype.
- **Draft domains skip all of this:** edit freely, publish, and start here.

## Steps

### 1. Decide what kind of change it is

A same-version edit may only add new named surface: a new field, a new enum key, a new nested property, or a new child entry. Everything else is a data-shape change and needs a version bump with a migration:

| Change | How |
| --- | --- |
| Add a field | Same version. Old rows read the field as absent. |
| Remove or retype a field | Version bump with a migration that rewrites the rows. |
| Rename a field | Version bump: add the new field, copy the value in the migration, remove the old one. |
| Tighten a constraint or change an enum | Version bump with a migration that repairs stored values. |

### 2. Bump the version and write the migration

Raise `schema_version` by exactly one. Add a `migrations` entry whose key is the version you migrate **from**, and write that function in the doctype's Lua script. The definition carries the map:

```json
{
  "schema_version": 2,
  "migrations": { "1": "migrate_from_1" }
}
```

The function body lives in the doctype's script; the Example below shows a complete one.

:::caution
A migration rewrites documents. There is no undo for a migration that dropped data: `ctx.root.full_name = nil` removes the value. Test the function on a draft or a copy first.
:::

### 3. Let documents catch up

You do nothing. This is deliberate: there is no backfill job to start. The
next read or list of an older document runs the chain of steps in order and
stores the result. A document that fails its step keeps its old content and
carries an error marker; it stays visible.

A document nobody reads keeps its old shape, so a corpus catches up slowly.
To push every document to the current version at once, use the doctype's
maintenance page (`/Configure/platform/maintenance`), or post to
`POST /Api/core/DocType/:id/migrate_ahead`. Both are optional. The run
persists one `snapshot` mutation per migrated document — the same audit
footprint the lazy path pays per document, paid up front.

:::caution
A broken migration stops catching up, not the system. Documents below the broken step keep their old shape until you fix the function and run `facet doctype:migrate-retry <domain.Doctype>`.
:::

### 4. Rebuild derived columns with reproject

Label and search text of old documents do not follow a template change. Rebuild them for a whole doctype:

```sh
facet doctype:reproject crm.Company
```

Useful options: `--limit 10` for a smoke test, `--workers 8` to speed up a large doctype. The command reports processed, superseded, skipped, and failed counts.

## Example

The `hr.Employee` doctype moves from version 2 to version 3: `full_name` becomes `first_name` and `last_name`. The update carries the map entry `"2": "migrate_from_2"`, and the script defines:

```lua
local export = {}

function export.migrate_from_2(ctx)
  local full = ctx.root.full_name
  if full then
    local space = string.find(full, " ")
    if space then
      ctx.root.first_name = string.sub(full, 1, space - 1)
      ctx.root.last_name = string.sub(full, space + 1)
    end
    ctx.root.full_name = nil
  end
end

return export
```

A document stored with `{"full_name": "Ada Lovelace"}` and `meta.schema_version: 2` is read, migrated, and stored as `{"first_name": "Ada", "last_name": "Lovelace"}` with `meta.schema_version: 3`. The history keeps the snapshot, so the change is auditable.

## Troubleshooting

**The update answers: schema_version must be exactly N+1.**

The version jumped. Bump by one and publish each step in order.

**The update answers: Migration from vN to vN+1 is missing.**

The map has no entry for the step you are leaving. Add the key and the function, then save again.

**Some documents still show the old shape.**

They failed their step and carry an error marker. Fix the function and run `facet doctype:migrate-retry <domain.Doctype>`.

**Labels look old after a template change.**

Derived columns follow writes, not definitions. Run `facet doctype:reproject <domain.Doctype>`.

## Related

- [Lua API reference](/reference/lua-api/) — the `ctx` table migration functions receive.
- [Schema evolution](/concepts/schema-evolution/) — the lazy migration model.
- [Checking a domain before publish](/build/checking-before-publish/) — verify the changed doctype in a draft first.
