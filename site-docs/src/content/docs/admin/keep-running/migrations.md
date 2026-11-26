---
title: Database migrations
description: Apply and revert database migrations, and keep every session on UTC.
type: how-to
audience: [operator]
features: [PLT-11]
verified_at: eee55a2
sidebar:
  order: 3
---

A new release ships a new schema, and the change must land without touching
the data. Facet carries its own migrations. The binary reads every migration
file at compile time and embeds it, so a deployed binary needs no `db/` tree
on disk. The runner applies pending migrations in filename order and tracks
applied files in a `_migrations` table. A changed or added migration file
needs a rebuild.

## When to use this

- You upgrade an install to a new release.
- You must revert a migration.
- You connect a client that must not skew timestamps.

## Before you start

- `DATABASE_URL` points at the target database.
- Take a database snapshot before you revert a migration. A revert runs DDL
  that a snapshot can undo.
- Know the difference between the two bootstrap chains: `migrate` plus
  `seed:core` is safe everywhere; `db_reset` drops the database.

## Steps

### 1. Apply pending migrations

```sh
facet migrate
```

The runner sorts pending files by filename, applies the `-- UP` section of
each, and records the file in `_migrations`. Applied files are skipped, so
the command is idempotent. The container entrypoint runs
`facet migrate && facet seed:core` on every boot: three migrate attempts,
then the seed, then the server starts.

After a plain `facet migrate` on a fresh database, run the seed:

```sh
facet seed:core
```

This seeds the core doctypes and the currency registry. It is idempotent and
safe on every boot.

### 2. Revert a migration when needed

```sh
facet migrate:down            # revert the most recently applied migration
facet migrate:down 0008       # revert everything applied after 0008; 0008 stays applied
facet migrate:down --yes      # skip the confirmation prompt
```

Rules:

- The target takes the full filename or its `NNNN` number prefix.
- Migrations revert in reverse filename order. Each revert runs the file's
  `-- DOWN` section and deletes its `_migrations` row in one transaction, so
  the schema and the applied list never disagree.
- The command prints the plan and asks for confirmation. It refuses to prompt
  when stdin is not a terminal: scripted callers pass `--yes`.
- The plan is validated before anything runs. An unknown target, an unapplied
  target, or a migration without a usable `-- DOWN` section aborts with no
  changes.
- A reverted migration re-applies normally on the next `facet migrate`.

### 3. Follow the append-only rule

After the first release, `db/migrations/` is append-only. Never edit,
renumber, or merge a migration that any installed database has applied.

The reason is the tracking table. `_migrations` holds the applied filenames.
An edited file desynchronizes every deployed database from the repository
history, and a rebuilt binary then carries SQL that disagrees with its own
history. The same rule protects the embedding: the binary and the history
must always tell the same story.

### 4. Keep every session on UTC

Every timestamp column stores UTC without a timezone marker. Two layers pin
the session zone:

1. The application appends `TimeZone=UTC` to the connection options on every
   pooled connection.
2. Migration `0001_document_store.sql` set the application role's default
   with `ALTER ROLE CURRENT_USER SET timezone TO 'UTC'`.

A client that connects with a different role gets the server default. It must
set `TimeZone=UTC` itself, in the connection options or with
`ALTER ROLE ... SET`.

:::caution
A non-UTC session does not corrupt reads, but it skews writes. `now()`
defaults and `text::timestamp` casts store local wall-clock time, and
PostgreSQL drops the offset without a warning. Pin the zone on every foreign
client: `psql`, BI tools, and one-off scripts.
:::

## Example

An upgrade from one release to the next on a container install:

```sh
docker compose -f docker/compose.prod.yml pull
docker compose -f docker/compose.prod.yml up -d
```

The new backend image boots, runs its embedded migrations, re-seeds the core
doctypes, and starts. No manual schema step exists. If the boot reports a
failed migrate after three attempts, read the backend logs and fix the cause
before you retry.

The equivalent source path:

```sh
make build_release
facet migrate && facet seed:core
# then restart the server process
```

## Troubleshooting

**`migrate:down` aborts and changes nothing.**

The plan validation refused the target: unknown filename, not applied, or no
usable `-- DOWN` section. No change has run.

**A migration cannot be reverted.**

Its `-- DOWN` section is missing or empty. Restore from a snapshot instead.

**Timestamps skew by a fixed offset.**

A foreign client writes with a non-UTC session. Set `TimeZone=UTC` for that
role or connection, then correct the skewed rows from a snapshot or a
re-import.

**The container boot fails on the migrate step.**

The entrypoint tried three times. Read the backend logs: a locked migration,
a permissions problem, or an unreachable database are the usual causes.

## Related

- [Upgrade Facet](/admin/keep-running/upgrades/) — the release runbook that runs these migrations.
- [Run with containers](/admin/install/containers/) — the entrypoint chain that runs the migrations.
- [First start and bootstrap](/admin/install/bootstrap/) — `migrate`, `seed:core`, and `db_reset` in context.
- [Roll back a change](/admin/history/roll-back/) — document rollback, a different mechanism from schema rollback.
- [Change a live domain safely](/build/model/change-a-live-domain/) — the author-side flow for doctype changes.
- Internals on GitHub: [migrations.md](https://github.com/wearefacet/facet/blob/main/doc/backend/migrations.md), [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md).
- [facet CLI](/reference/cli-facet/)
