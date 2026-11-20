# Database Migrations

**File:** `src/migrate.cr`

Read the SQL from `db/migrations/` at **compile time** and embed it in the binary (`Migrate::MIGRATION_SOURCES`) — the runner extracts the `-- UP` section from the embedded content and applies pending migrations. The directory stays the source of truth; a changed or added migration file requires a rebuild (the Makefile tracks the files as build dependencies), and a deployed binary needs no `db/` tree on disk. Already-applied migrations are tracked in a `_migrations` table and skipped on subsequent runs. `facet migrate:down` reverts applied migrations through their `-- DOWN` sections, read from the same embedded content.

| Method | Description |
|---|---|
| `Facet::Migrate.run` | Applies all pending migrations sorted by filename |
| `Facet::Migrate.down` | Reverts applied migrations through their `-- DOWN` sections (see `Migrate::DownCLI`) |
| `Facet::Migrate.db_reset` | Drops, recreates, and re-migrates the database |

Migrations use `-- UP` / `-- DOWN` markers. When applying a migration, only the content before `-- DOWN` is executed. `Migrate.up_section` / `Migrate.down_section` split a file into its two sections; a missing or whitespace-only `-- DOWN` section yields `nil`.

## Rolling back

```
facet migrate:down            # revert the most recently applied migration
facet migrate:down 0008       # revert everything applied after 0008_jobs.sql (0008 stays applied)
facet migrate:down --yes      # skip the confirmation prompt
```

- The target takes the full filename or its `NNNN` number prefix.
- Migrations revert in reverse filename order. Each revert runs the file's `-- DOWN` section and deletes its `_migrations` row in one transaction, so the schema and the applied list can never disagree about a migration's state.
- The command prints the revert plan and asks for confirmation. It refuses to prompt when stdin is not a terminal — scripted callers must pass `--yes`.
- The plan is validated before anything runs: an unknown target, a target that is not applied, or a migration missing from the build (or with a missing or empty `-- DOWN` section) aborts with no changes. A migration without a usable `-- DOWN` section cannot be reverted — write one when the file is added.
- A reverted migration re-applies normally on the next `facet migrate`.

## Release discipline

After the first release tag, `db/migrations/` is append-only. Never edit, renumber, or merge a migration that any installed database has applied — `_migrations` holds the applied filenames, and editing applied files desynchronizes every deployed database from the repository history. The append-only rule also protects the embedding: a binary built from a tree whose migration was edited carries SQL that disagrees with its own `_migrations` history.

## Deployment constraints

Every timestamp column in the schema is tz-naive and stores UTC. Two layers give every client a UTC session:

1. The application appends `-c TimeZone=UTC` to the libpq `options` parameter on every pooled connection (`Database.init` in `src/database.cr`).
2. Migration `0001_document_store.sql` set the application role's default with `ALTER ROLE CURRENT_USER SET timezone TO 'UTC'`. A role-level setting is database-independent, so it also covers test/worker databases cloned from templates.

A client that connects with a **different role** gets the server default and must set `TimeZone=UTC` itself (connection `options`, or `ALTER ROLE ... SET`). With a non-UTC session, `now()` defaults and `text::timestamp` casts store local wall-clock time into the naive columns — PostgreSQL silently drops the offset, so the write skews by the session offset. Reading the columns back is safe from any session; only writes and casts skew.

Converting the columns to `timestamptz` is not planned — tz-naive UTC storage is the accepted contract. If it is ever revisited, the conversion must pin the source zone: `ALTER COLUMN c TYPE timestamptz USING c AT TIME ZONE 'UTC'` — a bare type change reinterprets the values in the session's timezone.

## Migration files

Each file maps to one concern, so objects never get patched later via `ALTER TABLE` — every constraint, column, and index is declared in full at the table's first creation.

| File | Contents |
|---|---|
| `db/migrations/0001_document_store.sql` | The event-sourced document store. Extensions (`pgcrypto`, `pg_trgm`; `vector` enabled only when the server provides it — optional, RAG prerequisite, see [`assistant.md`](assistant.md)), `ulid()` function; the application role's UTC session default (`ALTER ROLE CURRENT_USER SET timezone TO 'UTC'` — the session-environment backstop, see [Deployment constraints](#deployment-constraints)); `projections` + `mutations` tables and all their indexes (state, search trigram, links GIN, actioner, doc_id/idx, unique idx, `updated_at` ETag index); pure helpers consumed by the projection triggers (`jsonb_ensure_path`, `jsonb_apply_text_patch`, `jsonb_apply_diff`); mutation-to-projection sub-functions (`projection_from_create/update/delete/snapshot`), dispatch trigger, `stamp_mutation_insert` trigger (per-document idx assignment + the `parent_doc_id` aggregate stamp), and `periodic_snapshot` trigger. The trigger functions carry the transaction-local GUC guards for retention compaction and write-time coalescing — `harness.explicit_mutation_idx` (keep a caller-provided idx) and `harness.bypass_projection_triggers` (skip the projection dispatch and the periodic snapshot) — and `cause_kind` includes `compaction` and `seed` (see [`mutation.md`](mutation.md) → Retention compaction / Write-time coalescing and [`doctype-system.md`](doctype-system.md) → Seeding) |
| `db/migrations/0002_indexing.sql` | Managed doctype indexes: `doctype_indexes` tracking table (CHECK constraint covers all index types including `gist_tstzrange` / `gist_daterange`); IMMUTABLE wrappers `facet_tstzrange(start_text, end_text)` and `facet_daterange(start_text, end_text)` for GiST range expression indexes (PostgreSQL marks `text::timestamptz` / `text::date` as STABLE not IMMUTABLE, so a raw range expression cannot be used in `CREATE INDEX`; the doctype validation layer guarantees well-formed ISO-8601 UTC inputs, so the IMMUTABLE marking truthfully reflects the runtime guarantee); type-extracting helpers `jsonb_as_numeric`, `jsonb_as_boolean`, `facet_money_value_as_numeric` for typed filter / sort / index |
| `db/migrations/0003_artifacts.sql` | `artifacts` table (file/large-field storage, nullable `content` + `location` for S3) + `artifact_owners`, `artifact_grants`, `artifact_references` |
| `db/migrations/0004_replication.sql` | `replication_subscriptions` table + indexes for cross-domain field replication |
| `db/migrations/0005_assistant.sql` | Assistant storage side tables: `agent_conversations` + `agent_turns` (LLM agent session/turn persistence; turns cascade with their conversation) + `assistant_usage` (per-account token usage ledger; no FK, outlives conversations — windowed by `(account_id, recorded_at)`) |
| `db/migrations/0006_sequence_identifiers.sql` | `sequence_identifiers` table (last generated sequential identifier per doctype) |
| `db/migrations/0007_account_settings.sql` | `account_settings` table (per-account, per-app preference store; not event-sourced) |
| `db/migrations/0008_jobs.sql` | `background_jobs` queue (one row = one unit of work) + `webhook_calls` (outbound webhook HTTP attempt log) |
| `db/migrations/0009_notifications.sql` | `notifications` table (in-app notification store) |
| `db/migrations/0010_api_keys.sql` | `api_keys` table |
| `db/migrations/0011_secrets.sql` | `secrets` table (generalized secret store — one row per document + slot, mode enum `hash`/`sealed`/`token`, FK-cascaded to `projections`) + `auth_state` table (volatile operational state: TOTP replay guard) + `secret_staging` (single-use stage handles) + `mfa_backup_codes` (single-use MFA recovery codes, SHA-256 digests) |
