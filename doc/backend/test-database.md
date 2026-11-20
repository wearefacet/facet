# Test database

The backend spec suite owns a throwaway PostgreSQL instance. It runs on the
host port 5433, next to the dev instance on 5432. The suite connects to it
through `DATABASE_URL` in `.env.test`.

## Source files

- `compose.test.yml` — the instance definition (image, ports, storage).
- `.env.test` — the suite's `DATABASE_URL`.
- `spec/spec_helper.cr` — reachability preflight, template and worker
  database lifecycle, seeded-baseline snapshot.
- `spec/support/seeded_baseline_helper.cr` — the snapshot/restore helpers.
- `config.test.yml` — the suite's `database.cluster` section (the
  read/write tripwire).

## The read/write tripwire

`config.test.yml` declares a `database.cluster` whose `main` entry points at
the worker database and carries a `replica:` at the same URL. Every ro
request (`Database.with_db(:read_only)`) therefore lands on an enforced
pool — its connections run `SET default_transaction_read_only = on` — while
rw requests keep the primary pool. One physical database is enough: the
hook, not the host, refuses writes.

This is the suite-wide tripwire for the read/write segregation: any
read-path code that writes fails its own spec with a PG error, which turns
the entry-point classification sweep into a suite-verified property. The
sanctioned escape is the nested rw escalation (see
[`schema-migration.md`](schema-migration.md) and
[`workflow.md`](workflow.md) → Database quirks).

One bootstrap rule matters: the cluster URLs in the config expand `!env
DATABASE_URL` at config load, and the config singleton loads lazily. The
suite calls `Facet::Config.reset!` after provisioning the worker database,
because seeding the template runs the document pipeline whose hooks touch
`Config.instance` first — without the reset, the pools would freeze at the
template database while the per-example `TRUNCATE` (which reads `ENV`)
wipes the worker database, and state would leak across examples.

## Public API

| Target            | Purpose                                              |
| ----------------- | ---------------------------------------------------- |
| `make test_db_up`   | Start the instance (idempotent; waits for health). |
| `make test_db_down` | Stop and remove the instance.                      |
| `make test`         | Runs the suite; starts the instance first.         |

## The seeded-baseline snapshot

`Spec.before_suite` snapshots the worker database's seeded rows right after
the template clone: one `spec_baseline_<table>` copy per truncated table
(`CREATE TABLE ... AS SELECT`), inside the worker database itself. The
snapshot tables carry no foreign keys, so the per-example `TRUNCATE ...`
`CASCADE` never touches them, and they die with the worker at teardown.

`restore_seeded_baseline(db)` (`spec/support/seeded_baseline_helper.cr`)
brings the corpus back in one transaction — `TRUNCATE` + `INSERT ...`
`SELECT` per table (~13 ms, vs ~320 ms for a full `Seed.seed` pipeline
re-run). It is atomic: a caller inside an open transaction joins it, a
caller outside gets a short standalone one. On a database without a
snapshot (e.g. a scratch database a spec repointed `DATABASE_URL` at) it
falls back to the real seed.

Restored rows are byte-identical to seeded rows except the default
`core.CollectionView` projection ids — `Seed.seed` mints those fresh on
every run. Specs address seeded views by `parent_id`, never by projection
id, so the difference never matters. Fixture setup uses the restore; specs
that test `Doctype::Seed` behaviour itself call the real seed.

## Why not the dev instance

The suite truncates its tables thousands of times per run. On durable
storage each `TRUNCATE` leaves dirty files behind, and every `DROP
DATABASE` (template setup, teardown, the `db_reset` spec) forces a
checkpoint that must fsync that churn — measured stalls of 2 to 6 minutes
per checkpoint on the dev box. The test instance stores data on a tmpfs
mount and runs a non-durable profile (`fsync=off`, `synchronous_commit=off`,
`full_page_writes=off`, `wal_level=minimal`), so checkpoints and WAL are
near-free. The dev database (`facet`) is not touched by the suite.

## Quirks

- Data dies with the container (tmpfs). `spec/spec_helper.cr` rebuilds
  `facet_test_template` on every suite run, so this is not a loss.
- The schema needs Postgres 17 only; `pgcrypto` and `pg_trgm`
  come with any image, and the optional `vector` extension is skipped when
  absent. The stack keeps the pgvector image (`pgvector/pgvector:0.8.0-pg17`)
  so the suite runs the RAG-ready configuration.
- The instance sets `max_connections=200` so several spec worker processes
  can share it.
- If the instance is down, `Spec.before_suite` aborts with a pointer to
  `make test_db_up` instead of a bare connection error.
