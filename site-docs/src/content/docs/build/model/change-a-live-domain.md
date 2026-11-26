---
type: how-to
title: Change a live domain safely
description: Which doctype changes are safe on a live domain, which need a version bump, and how documents follow.
audience: [author]
features: [DOM-17, DOM-18]
sidebar:
  order: 5
verified_at: eee55a2
---

At Brightwater, the `rentals.Booking` doctype is live: fifteen bookings sit
in it. Nadia now needs a `cancellation_reason` field, and she wants the
free-text `notes` field as two structured ones. Every change to a live
doctype passes one gate: does the change alter the shape of the stored
documents? This page shows which changes pass, which need a version bump
with a migration, and how the stored documents follow.

## When to use this

- You add, rename, or remove a field on a live doctype.
- You split one field into two, or merge two into one.
- Lists or labels look stale after a definition change.

## Before you start

- **Update rights** on the doctype definition.
- **The current `schema_version`** of the doctype.
- **[Draft domains](/build/model/in-app/how-drafts-work/) skip all of this:** edit freely, publish, and start here.

## Steps

### 1. Decide what kind of change it is

A same-version edit may only add new named surface. Everything else changes
the data shape and needs a version bump with a migration:

| Safe at the same version | Needs a version bump + migration |
| --- | --- |
| Add a field | Remove a field |
| Add an enum key | Remove or reorder enum keys |
| Add a nested property | Change a field's type |
| Add a `children` entry | Tighten a constraint |
| Change label, search, or view templates | Change the reference surface, or the `children` / `member_of` links |
| Change icons, colors, defaults, tags, read/write flags | Flip a collection, or edit a nested sub-schema |

The rule behind the table: an additive edit cannot break a stored document,
because validation applies to new writes only. A shape change can, so it
must say how every stored document catches up.

### 2. Bump the version and write the migration

Raise `schema_version` by exactly one. Add a `migrations` entry whose key is
the version you migrate **from**, and write that function in the doctype's
Lua script:

```json
{
  "schema_version": 2,
  "migrations": { "1": "migrate_from_1" }
}
```

The function body lives in the doctype's script; the Example below shows a
complete one. Two checks run when you save: every version gap needs its
migration entry, and every named function must exist in the script.

:::caution
A migration rewrites documents. There is no undo for a migration that
dropped data: `ctx.root.full_name = nil` removes the value. Test the
function on a draft or a copy first.
:::

### 3. Let documents catch up

You do nothing. This is deliberate: there is no backfill job to start. The
next read or list of an older document runs the chain of steps in order and
stores the result. A document that fails its step keeps its old content and
carries an error marker; it stays visible.

A document nobody reads keeps its old shape, so a corpus catches up slowly.
To push every document to the current version at once, open the doctype's
maintenance page (`/Configure/platform/maintenance`), or post to
`POST /Api/core/DocType/:id/migrate_ahead`. Both are optional. The run
persists one `snapshot` change per migrated document — the same audit
footprint the lazy path pays per document, paid up front.

:::caution
A broken migration stops catching up, not the system. Documents below the
broken step keep their old shape until you fix the function and run
`facet doctype:migrate-retry <domain.Doctype>`.
:::

### 4. Rebuild labels and search with reproject

Label and search text of old documents do not follow a template change.
Rebuild them for a whole doctype:

```sh
facet doctype:reproject rentals.Booking
```

Useful options: `--limit 10` for a smoke test, `--workers 8` to speed up a
large doctype. The command reports processed, superseded, skipped, and
failed counts. It rebuilds the three derived columns only — label, search
text, and links. It does not migrate versions.

### 5. When the update is refused

The gate answers `422` with the reason. The common ones:

| Message | Meaning | Way out |
| --- | --- | --- |
| `schema_version must be exactly N+1` | The version jumped, or a shape change came without a bump | Bump by one and save each step in order |
| `Migration from vN to vN+1 is missing` | The map has no entry for the step you are leaving | Add the key and the function |
| `same-version edit cannot remove fields` | A shape change at the same version | Bump with a migration, or pass `$force: true` |
| `same-version edit must not include migrations` | A same-version save carried a migrations map | Save the definition without the map |
| Duplicate values named | The update adds a `unique` constraint and live rows collide | Fix the data first; the check runs before anything is written |

`$force: true` is a per-save escape hatch for the same-version shape
rejections. It is never stored: the saved definition does not carry it, and
the next save starts from the stored shape. It never relaxes the version
rules. A forced edit may drop the stored migrations map — use it on a
dev instance, where the next publish rebuilds everything.

## Example

The `hr.Employee` doctype moves from version 2 to version 3: `full_name`
becomes `first_name` and `last_name`. The update carries the map entry
`"2": "migrate_from_2"`, and the script defines:

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

A document stored with `{"full_name": "Ada Lovelace"}` and
`meta.schema_version: 2` is read, migrated, and stored as
`{"first_name": "Ada", "last_name": "Lovelace"}` with
`meta.schema_version: 3`. The history keeps the snapshot, so the change is
auditable.

One trap to know: a migration function that changes nothing still marks the
document as migrated. If your function forgets to touch `ctx.root`, every
document jumps to the new version with its old content. The migration then
never runs again for that document. Compare one document before and after
the bump to spot it.

## Troubleshooting

**The update answers: schema_version must be exactly N+1.**

The version jumped. Bump by one and publish each step in order.

**The update answers: Migration from vN to vN+1 is missing.**

The map has no entry for the step you are leaving. Add the key and the
function, then save again.

**Some documents still show the old shape.**

They failed their step and carry an error marker. Fix the function and run
`facet doctype:migrate-retry <domain.Doctype>`. The command clears the
marker and re-runs the migration; a failed attempt writes nothing, so it is
safe to re-run after each fix. `--limit 10` caps it for a smoke test.

**Labels look old after a template change.**

Derived columns follow writes, not definitions. Run
`facet doctype:reproject <domain.Doctype>`.

**The update drops my migrations map.**

A save with `$force: true` persists the definition as sent, including any
missing map. Re-add the map entries in the next save. On a live domain,
normal saves carry the stored entries forward even when the body omits
them.

## Related

- [Lua API reference](/reference/lua-api/) — the `ctx` table migration functions receive.
- [How old documents follow a new schema](/build/deeper/schema-evolution/) — the lazy migration model, in depth.
- [Drafts, editors and publishing](/build/model/in-app/drafts-and-publishing/) — rehearse the change in a draft first.
- [From dev to production](/build/model/dev-to-production/) — what the import's version gate asks of a bundle.
