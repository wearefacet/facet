---
title: Schema evolution and lazy migration
description: Change a doctype without a backfill; stored documents migrate on their next read.
audience: [author, developer]
features: [DOM-17]
sidebar:
  order: 10
verified_at: 7a6cb462
---

In Facet, a doctype change never rewrites the stored documents. The definition
moves to a new schema version, and each document catches up the next time a
read touches it. This is lazy migration: no backfill job, and the migration
work happens on read.

## Explanation

<!-- d2
direction: right
read: "Read request" {class: external}
fetchDef: "Fetch doctype definition"
fetchDoc: "Fetch document projection"
current: "Stored version is current?" {class: decision}
return: "Return the document" {class: ok}
migrate: "Run the migration functions in order"
snapshot: "Write a snapshot mutation" {class: store}

read -> fetchDef
fetchDef -> fetchDoc
fetchDoc -> current
current -> return: yes
current -> migrate: no
migrate -> snapshot
snapshot -> return
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9bdb23d4-light.svg" alt="Read request" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9bdb23d4-dark.svg" alt="Read request" loading="lazy" />
</div>

Every doctype carries a `schema_version` integer, starting at 1. Every document
stores its own `meta.schema_version`: the version active when it was last
written. A read compares the two numbers. When the stored number is lower, the
read runs the migration functions for each version gap in order. It then
persists the result as a snapshot mutation and returns the migrated document.
The next read skips the work, because the stored version now matches.

**Reads and lists both migrate.** Single reads and lists both migrate. A list
migrates each stale row before it applies the read mask. The migration runs on
a write connection under a row lock. Concurrent reads therefore cannot migrate
the same document twice.

### The version bump

A doctype update must raise `schema_version` by exactly one — you cannot skip
a version. Every gap between the old and the new version needs a migration
entry. Every named function must exist in the doctype's Lua script. The
migrations map on the definition names them:

```json
{
  "schema_version": 3,
  "migrations": {
    "1": "migrate_from_1",
    "2": "migrate_from_2"
  }
}
```

A migration function is ordinary Lua, in the same script as the lifecycle
hooks. It edits the document content in place, and the lifecycle hooks do not
re-run during migration. Nothing about a field change is automatic — the
function is where each change happens:

| Change | The migration function | Example |
| --- | --- | --- |
| Add a field with a default | Set the key on the old content | `ctx.root.department = "Engineering"` |
| Remove a field | Delete the key from the old content | `ctx.root.full_name = nil` |
| Change a field type | Read the old value, write the new shape | Split `full_name` into `first_name` and `last_name` |

### When migration fails

A migration function signals failure with `ctx.error`. Facet writes a
`migration_error` marker into the document's meta and returns the stale
content. Later reads and lists skip the marked document instead of failing.
The marker states why the migration failed, so you can read the cause without
re-running it.

**Retry from the CLI.** Recovery is a CLI command.
`facet doctype:migrate-retry hr.Employee` clears the marker and re-runs the
migration. A failed attempt writes nothing, so the command is safe to re-run
after you fix the definition.

:::caution
The first read after a version bump pays the migration cost. The read path
opens a write connection and takes a row lock on the document. A hot document
with a wide version gap adds that latency to a read request.
:::

**The trade-off is coexistence.** A document that is never read keeps its old
shape forever. A feature that needs the new field finds it absent on those
documents. The migration cost lands on reads, not on the version bump. In
exchange, a schema change ships without a backfill over the whole table.

## Related

- [Evolving a schema](/build/evolving-schema/) — declare fields and the migrations map on a doctype.
- [Draft → publish](/concepts/draft-publish/) — rehearse a schema change in a draft domain first.
- [Documents, doctypes and projections](/concepts/documents-doctypes-projections/) — where document content and meta live.
- Internals on GitHub: [schema-migration.md](https://github.com/wearefacet/facet/blob/main/doc/backend/schema-migration.md).
