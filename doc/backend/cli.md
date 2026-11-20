# CLI & Entrypoint

**Files:** `src/main.cr` (dotenv loader, global flags, boot wiring), `src/cli/commands.cr` (command registry and dispatch), `src/cli/chain.cr` (chain validation)

The CLI loads environment variables, parses global flags, and dispatches subcommands. The command surface is a table-driven registry in `src/cli/commands.cr`: one `Entry` record per command carries the name, the help text, the `takes_options` flag, and the handler. The code derives the help banner, the usage line for unknown commands, the option check, and the dispatch from that table. `src/main.cr` holds the dotenv loader, the `--help` option parser, the boot wiring, and `Facet::CLI.run`. Before the first command runs, `CLI.parse_chain` (`src/cli/chain.cr`) validates the whole chain and splits it into (command, flags) steps.

## Dotenv loader

An inline dotenv loader (no dependency) loads `KEY=VALUE` pairs from `.env`, then additionally loads `.env.{APP_ENV}`. Unset `APP_ENV` means `dev` — the same default `Facet::Config` uses for `config.{env}.yml`, so `.env.dev` loads whenever `config.dev.yml` does. The environment-specific file overrides base values and may also introduce new keys. Values already present in the shell environment win over both files.

## Subcommands

| Command | Behaviour |
|---|---|
| `server` (default) | Registers routes from `Facet::HTTP::Server.routes` and starts Kemal |
| `migrate` | Runs pending database migrations via `Facet::Migrate.run` |
| `migrate:down` | Reverts applied migrations through their `-- DOWN` sections via `Facet::Migrate::DownCLI` — no target = the latest applied migration; a target (filename or `NNNN` prefix) = everything newer, target stays applied |
| `db_reset` | Drops, recreates, and re-migrates the database via `Facet::Migrate.db_reset` — prints the plan and asks for confirmation; `--yes` (or `-y`) skips the prompt (see below) |
| `seed:core` | Reconciles core doctypes on an existing migrated database via `Facet::Migrate.seed_core` — the `db_reset` tail without the drop; creates missing definitions, updates definitions that drifted from their seed files, seeds missing seed documents, hydrates the currency registry, and runs the index-retry pass; idempotent, safe on every boot (the container bootstrap runs `facet migrate && facet seed:core`) |
| `seed:dev` | Seeds the dev admin account (admin@example.tld / admin, no MFA) via `Facet::IAM::Seed` — refused when `APP_ENV=production`. Dev bootstrap order: `facet migrate` → `facet seed:core` → `facet seed:dev` (see below) |
| `seed:admin` | Creates the first admin account with a generated one-time password via `Facet::IAM::SeedCLI` (run standalone to pass the email) |
| `index:retry` | Retries `error` `doctype_indexes` rows and stale `pending` rows (see below) via `Facet::Index::RetryCLI` |
| `artifacts:prune` | Soft-deletes (or `--hard` deletes) artifacts with no live owner or recent reference via `Facet::Artifact::PruneCLI` |
| `artifacts:reconcile` | Deletes orphaned objects from the artifact store via `Facet::Artifact::ReconcileCLI` |
| `artifacts:revoke` | Revokes every signed URL for an artifact via `Facet::Artifact::RevokeCLI` |
| `accounts:list` | Lists every `iam.Account` (id, email, display name, status, roles) via `Facet::IAM::AccountCLI` |
| `accounts:create` | Creates an account and prints a generated one-time password via `Facet::IAM::AccountCLI` |
| `roles:list` | Lists every `iam.Roles` (id, name) via `Facet::IAM::AccountCLI` |
| `roles:add` | Assigns a role to an account via `Facet::IAM::AccountCLI` |
| `auth:mode` | Pins the authentication mode (`hybrid` \| `oidc_only`) on the `core.SystemSettings` document via `Facet::IAM::AuthModeCLI` — the full-OIDC lockout recovery (run standalone to pass the mode). The policy gates read the document row uncached, so the new mode is live on every server at once |
| `domain:export` | Builds a portable-domain bundle from a live domain via `Facet::Domain::Portable::CLI.run_export` |
| `domain:import` | Applies a portable-domain bundle to the database via `Facet::Domain::Portable::CLI.run_import` |
| `doctype:reproject` | Re-projects every live document of a doctype from its current definition via `Facet::Doctype::ReprojectCLI` |
| `doctype:migrate-retry` | Clears `meta.migration_error` and re-runs the lazy migration for every marked document of a doctype via `Facet::Doctype::MigrationRetryCLI` |
| `cron:list` | Lists the boot cron tasks (id, config key, schedule, next run) via `Facet::Cron::ListCLI` — reads config only, no database; an unparseable expression marks its row and exits 1 (see [`cron.md`](cron.md)) |

Usage: `facet [server|migrate|migrate:down|db_reset|seed:core|index:retry|artifacts:prune|artifacts:reconcile|artifacts:revoke|accounts:list|accounts:create|roles:list|roles:add|auth:mode|seed:dev|seed:admin|domain:export|domain:import|doctype:reproject|doctype:migrate-retry|cron:list]`

Multiple commands may be chained and executed in order, e.g. `facet db_reset --yes seed:dev`. The chain is validated before the first command runs: a bare token after a chainable command must be a known command — an unknown one prints `Unknown command: …` and exits non-zero before anything executes, so a typo after a destructive command can never run that command first. A dash token after a command belongs to that command as its option; it never dispatches as a further command. Fixture bundles are imported separately via `scripts/import-fixtures` (which runs `domain:import`) — see [`doc/shared/fixtures.md`](../shared/fixtures.md).

**Event publication.** After each command returns, `CLI.dispatch` publishes what the command buffered: when the fiber-local `Event::Publisher` queue is non-empty, it installs a config-built manager (`Event::Publisher.ensure_config_manager` — an already-installed manager, such as the spec suite's in-process one, is kept) and flushes it fail-loud (`flush!`). A publish failure forces exit code 1: the DB write stands, but the operator must see that no consumer received the mutation. Commands that buffer nothing (read-only, or `--help`) never touch Redis. Without this flush, a CLI mutation would reach no cache subscriber and no stream consumer — the running servers would keep stale caches until the staleness bound.

**Key type:** `Facet::CLI`

## Option-taking commands

`index:retry`, `artifacts:prune`, `artifacts:reconcile`, `artifacts:revoke`, `accounts:create`, `roles:add`, `auth:mode`, `seed:admin`, `domain:export`, and `domain:import` consume the rest of the argument list as their own options (e.g. `facet artifacts:prune --hard`). They must be the **last** command in a chain — anything after them is an option, not a further command. The CLI stops dispatching after an option-taking command, and the chain validator hands it every following token without checking them.

Chainable commands take no positionals, but they can carry their own dash options inside a chain — `facet db_reset --yes seed:dev` passes `--yes` to `db_reset` and still runs `seed:dev` after it. An unknown flag reaches the command's own option parser, which rejects it before the command executes.

### `db_reset`

```
facet db_reset [--yes]
```

Drops the database named in `DATABASE_URL`, recreates it, runs every migration, and seeds the core doctypes. Before the drop the command prints the plan (`About to drop database '…' and rebuild it from all migrations.`) and asks `Proceed? [y/N]` — the same gate `migrate:down` uses. Only `y` or `yes` proceeds. Any other answer, or an empty input, aborts with no change.

When stdin is not a terminal, the command refuses to run: scripted callers must pass `--yes` (or `-y`) to skip the prompt. The gate sits before every destructive step, so a refusal or an unknown flag changes nothing.

The command stays chainable — its dash tokens are its options, the bare tokens are the next commands:

```
facet db_reset --yes seed:dev server
```

### `seed:admin`

```
facet seed:admin <email>
```

Creates the first admin `iam.Account` for a fresh deployment. The email comes from the first argument, or from the `SEED_ADMIN_EMAIL` environment variable when no argument is given. The command takes exactly one argument: `--help` prints usage and exits 0; any other flag, or a second positional argument, exits 1. The command lowercases the email before the write — the pipeline's create hook does the same on the HTTP path, and every login lookup compares lowercase. The seed writes raw, so the command also runs the `iam.Account` email field's own validation against the live definition: a bad shape or a missing definition (run `facet seed:core` first) exits 1. The command generates a one-time password (4 dashed groups of 4 over the 30-symbol alphabet — the same generator the invite flow uses), stores its bcrypt hash on the `password` slot, and sets `must_change_pw: true`, so the first login short-circuits into the password-change bootstrap. The plaintext password prints exactly once — it is never stored in plaintext and never logged. Exits non-zero when a live account with the email already exists: the bootstrap never resets an existing credential, recover access through the password-reset flow. Bypasses RBAC (system-tier). The full bootstrap procedure lives in [`doc/ops/first-deployment.md`](../ops/first-deployment.md).

The dev counterpart `seed:dev` writes the known default credential with `must_change_pw: false`; like the mail adapter gate, it fails closed — the CLI refuses it when `APP_ENV=production`.

**Dev bootstrap order.** Run the dev bootstrap in this order: `facet migrate` → `facet seed:core` → `facet seed:dev`. The admin account the dev seed creates references the seeded roles (`roles: ["iam.Roles.admin"]`, `default_role: "iam.Roles.admin"`), and the role documents are seeded by the seed-core pass (`Doctype::Seed`, which hoists `iam.Roles` ahead of every other document seed). Run `seed:dev` alone on an empty database and login fails with `403 "Role not found or disabled"` — the role documents do not exist yet, and login resolves roles strictly by `projections.id`. `db_reset` is immune — its own tail runs the seed-core pass — and `seed:core` is idempotent and safe on every boot, so re-running the order above never destroys data.

### `index:retry`

```
facet index:retry [--domain <domain>] [--doctype <doctype>] [--dry-run]
```

The DDL recovery path — see [`index-management.md`](index-management.md) → Failure semantics. The command initialises its own database pool (options are parsed first, so `--help` works without a reachable database) and retries two kinds of `doctype_indexes` rows: rows in `error` status, and `pending` rows stale beyond 10 minutes (`PENDING_STALE_MINUTES`) — a fresh `pending` row belongs to a live DDL fiber in the running server and is never touched. A stale `pending` row is the casualty shape of a DDL fiber that died before completing its batch (pool closed, connection lost, process kill).

`--domain` and `--doctype` narrow the retryable set — they AND onto the status predicate and never qualify a row on their own, so a healthy `active` index is never rebuilt because a filter names it.

Each row is re-checked against the current doctype definition: a still-desired index is rebuilt (`DROP INDEX CONCURRENTLY` of any half-built leftover inside the DDL gate, then `CREATE INDEX CONCURRENTLY`, up to 5 attempts on PG deadlock); a field that no longer exists drops the row and marks it `dropped`. Rows are attempted independently — one failure is reported and counted, it does not stop the remaining rows. The command exits 0 when every attempt succeeded and 1 when at least one failed. `--dry-run` prints the planned actions without running any DDL.

### `artifacts:prune`

```
facet artifacts:prune [--hard]
```

Computes prune eligibility (join-derived — see [`doc/backend/artifact.md`](artifact.md) → Prune) and soft-deletes each eligible artifact by default. `--hard` additionally removes the row and its shrine object. Soft-delete is the default so a mistaken prune is recoverable; hard-delete is a separate, explicit invocation.

### `artifacts:reconcile`

```
facet artifacts:reconcile [--dry-run]
```

Lists the artifact object store and deletes every object with no `artifacts` row that is older than an hour (the age gate protects an in-flight upload whose row has not yet committed). Dry-run by default prints the resolved bucket/prefix in a header, then every candidate key one per line, without deleting.

### `artifacts:revoke`

```
facet artifacts:revoke <artifact-id>
```

Bumps the `epoch` on every `artifact_grants` row for the artifact, invalidating every signed URL minted against any of its owner rows immediately — without needing the individual grant ids. Grant rows are kept (revoking is not deleting), so a mistaken bump can only invalidate URLs, never destroy data. See [`doc/backend/artifact.md`](artifact.md) → Signed grants.

### `accounts:list`

```
facet accounts:list
```

Lists every `iam.Account` document, one per line, tab-separated: id, email, display name, status, and the comma-joined assigned role ids. Sorted by email. Bypasses RBAC (system-tier) — intended for an IT operator inspecting or repairing assignments.

### `accounts:create`

```
facet accounts:create <email> [--name <display name>] [--role <role>]
```

Creates a normal (non-admin) `iam.Account` and prints a generated one-time password — the CLI counterpart of the HTTP onboarding surface (account create plus `POST /Api/iam/accounts/:id/temporary-password`). The account document goes through the standard document pipeline, so field validation and the unique-email constraint apply exactly as over HTTP, and the create hook sets the invited-account bootstrap status `pending` — the first full login flips it to `active`. `--name` defaults to the email (the same fallback the OIDC JIT provisioning uses). `--role` resolves by id (`iam.Roles.editor`) or bare name (`editor`) and becomes the account's `default_role` — the same first-role rule `roles:add` applies.

The credential step reuses the temporary-password bootstrap (`Invite.generate_temporary_password`): a 16-character one-time password (4 dashed groups of 4 over the 30-symbol alphabet — the same generator the invite flow and `seed:admin` use) is stored as a bcrypt hash on the `password` slot, `must_change_pw` is set so the first login short-circuits into the password-change bootstrap, and a `temp_password_generated` login event lands in the audit trail. The plaintext password prints exactly once — it is never stored in plaintext and never logged. Exits non-zero when a live account with the email already exists or the role does not resolve. Bypasses RBAC (system-tier).

### `roles:list`

```
facet roles:list
```

Lists every `iam.Roles` document, one per line, tab-separated: id and name. Sorted by name. Bypasses RBAC (system-tier).

### `roles:add`

```
facet roles:add <account> <role>
```

Assigns a role to an account. `account` is resolved by id first, then by email. `role` is resolved by id (`iam.Roles.admin`) first, then by bare name (`admin`). The role is appended to the account's `roles` array when absent; when the account had no roles yet, the assigned role also becomes `default_role` (mirroring the frontend `assignRole` helper). The stored role id is always the qualified form (`iam.Roles.{name}`). Bypasses RBAC (system-tier).

### `auth:mode`

```
facet auth:mode {hybrid|oidc_only}
```

Pins the authentication mode on the `core.SystemSettings` document. The command patches the document with the system principal, so the mode is pinned at the document tier — the same save path the settings UI uses, write gate included. Switching to `oidc_only` still requires one enabled `iam.OIDCProvider` document; switching back to `hybrid` is always allowed. This is the documented recovery for a full-OIDC lockout: the only enabled IdP is dead and no session survives, so the operator restores `hybrid` from the host. See [`iam.md`](iam.md) → Configuration and [`system-settings.md`](system-settings.md) for the mode semantics.

### `domain:export`

```
facet domain:export <domain> [--output <path>]
```

Builds a portable-domain bundle from a live domain and writes it to `--output` (default `./{domain}.facet-domain`). `--output` may be a directory tree or a `.tar.gz` / `.tgz` tarball — the form is auto-detected by the path extension. The bundle is definition-only: `core.Domain`, every `core.DocType` in the domain, every owned `core.DocumentView`, and every **general** `core.CollectionView`. Personal collection views and document data are not exported. Refuses a `draft = true` domain with a non-zero exit code — publish the draft first. See [`doc/backend/portable-domains.md`](portable-domains.md).

### `domain:import`

```
facet domain:import <path> [--into <domain>] [--merge]
```

Reads a portable-domain bundle from `path` (directory or `.tar.gz` / `.tgz`) and applies it to the database. Defaults to fresh-create: refuses with a non-zero exit code if the target domain exists unless `--merge` is passed. `--merge` also creates the domain when it does not exist yet, so it is always safe to pass. `--into` renames the bundle's source domain during import — orthogonal to `--merge`. The whole import runs in one transaction; any rejection (e.g. version-decrease on `--merge`) rolls back every mutation produced so far. Cross-domain reference integrity is never enforced — a doctype may reference a target that does not yet exist on the importing instance. `Event::Publisher.flush` runs at dispatch (see Event publication above), so the imported doctypes' cache fanouts reach any running server. See [`doc/backend/portable-domains.md`](portable-domains.md).