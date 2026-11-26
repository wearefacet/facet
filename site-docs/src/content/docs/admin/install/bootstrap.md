---
type: how-to
title: Bootstrap and CLI tasks
description: Run the facet CLI to bootstrap an install, manage accounts, recover access, and do maintenance.
audience: [operator]
features: [IAM-12, DOM-24]
sidebar:
  order: 3
verified_at: 008dd880
---

The backend binary doubles as the operator CLI. One command, `facet`, runs
the server and every bootstrap and maintenance task. The same binary sits
inside the backend container image, so a one-off container runs any CLI task
against the live stack.

## When to use this

Run a CLI task when:

- You deploy a fresh install and need the schema, the core doctypes, and the
  first admin.
- You create accounts or assign roles from a script.
- You must recover an install that locked itself out.
- You run maintenance: index retries, artifact pruning, domain moves.

## Before you start

- `DATABASE_URL` points at the target database.
- The CLI loads `.env`, then `.env.{APP_ENV}`, then keeps values already set
  in the shell. Unset `APP_ENV` means `dev`.
- A command that mutates data publishes its events to Redis at exit. A
  publish failure forces exit code 1: the database write stands, but no
  consumer received the change.

## Steps

### 1. Bootstrap a fresh install

The safe chain works on an empty database and on an existing one:

```sh
facet migrate && facet seed:core
```

`migrate` applies every pending migration. `seed:core` seeds the core
doctypes and the currency registry. Both steps are idempotent, so re-running
them changes nothing. The container entrypoint runs this chain on every
boot.

Then create the first administrator:

```sh
facet seed:admin ops@your-company.tld
```

The command prints a one-time password. It shows once, stores only a hash,
and forces a password change at first login. Re-running the command with the
same email exits non-zero: the bootstrap never resets an existing
credential.

`facet db_reset` is the destructive alternative. It drops the database,
re-creates it, migrates, and seeds the core doctypes. It creates no account.
Use it only where a drop is acceptable, and pass `--yes` in scripts:

```sh
facet db_reset --yes
```

:::caution
`facet seed:dev` writes the known dev credential and is refused when
`APP_ENV=production`. First-admin creation in production goes through
`seed:admin` only. Also run `seed:dev` after `seed:core`, never alone: login
needs the role documents the core seed creates.
:::

### 2. Manage accounts and roles

```sh
facet accounts:list                      # every account, one per line
facet accounts:create pat@example.tld --name "Pat Lee" --role editor
facet roles:list                         # every role, id and name
facet roles:add pat@example.tld admin    # account by id or email, role by id or name
```

`accounts:create` prints a generated one-time password, exactly like
`seed:admin`. Both commands bypass RBAC, so run them from a trusted host.

### 3. Recover an authentication lockout

`facet auth:mode {hybrid|oidc_only}` pins the authentication mode on the
settings document. This is the recovery for a full-OIDC lockout: the only
enabled identity provider is dead and no session survives. Run it on the
host, and the new mode is live on every server at once:

```sh
facet auth:mode hybrid
```

### 4. Run maintenance tasks

| Command | Task |
| --- | --- |
| `facet index:retry [--domain D] [--doctype T] [--dry-run]` | Retry failed or stale managed index builds. |
| `facet artifacts:prune [--hard]` | Soft-delete ownerless artifacts. `--hard` removes rows and bytes. |
| `facet artifacts:reconcile [--dry-run]` | Delete store objects with no artifact row, older than an hour. |
| `facet artifacts:revoke <artifact-id>` | Invalidate every signed URL for one artifact. |
| `facet doctype:reproject <doctype>` | Re-project every live document of a doctype. |
| `facet doctype:migrate-retry <doctype>` | Clear a migration error and re-run the lazy migration. |
| `facet cron:list` | Print the cron task table: id, schedule key, expression, next run (UTC). |

See [Managed indexes](/admin/keep-running/indexes/) for `index:retry` and
[File storage: filesystem or S3](/admin/configure/file-storage/) for the artifact
commands.

### 5. Move a domain between installs

```sh
facet domain:export hr --output hr.facet-domain
facet domain:import hr.facet-domain --merge
```

The export is definition-only: the domain, its doctypes, and its views. No
document data travels. `--merge` updates an existing domain and creates a
missing one, so it is always safe to pass. `--into` renames the domain
during import.

### 6. Chain commands

Commands run left to right in one invocation:

```sh
facet db_reset --yes seed:dev
```

Two rules keep chains safe:

- A command that takes options must be the last in the chain. Everything
  after it belongs to that command.
- The chain is validated before the first command runs. An unknown command
  after a destructive one exits non-zero before anything executes.

## Example

A full first bootstrap on a fresh database, with verification:

```sh
facet migrate && facet seed:core
facet seed:admin ops@your-company.tld
facet accounts:list
```

`accounts:list` prints the new account with the `iam.Roles.admin` role. Sign
in with the one-time password and set a real password when prompted.

## Troubleshooting

**Login answers `403 "Role not found or disabled"` after `seed:dev`.**

`seed:dev` ran before `seed:core`, so the role documents do not exist. Run
`facet seed:core`, then try again.

**`db_reset` refuses to run in a script.**

Stdin is not a terminal. Pass `--yes`.

**`seed:admin` exits non-zero.**

A live account with that email already exists. Recover access through the
password-reset flow instead — it needs working email delivery.

**A CLI mutation reaches no running server cache.**

The command exits 1 when the event publish fails. Check the Redis URL and
re-check the state; the database write itself succeeded.

## Related

- [Database migrations](/admin/keep-running/migrations/) — what `migrate` and `db_reset` run.
- [Deploy to production](/admin/install/production/) — the bootstrap inside the container path.
- [Managed indexes](/admin/keep-running/indexes/) — the `index:retry` command in full.
- [File storage: filesystem or S3](/admin/configure/file-storage/) — the artifact commands in full.
- [Account lifecycle](/admin/people/accounts/) — the account states the CLI creates.
- Internals on GitHub: [cli.md](https://github.com/wearefacet/facet/blob/main/doc/backend/cli.md), [first-deployment.md](https://github.com/wearefacet/facet/blob/main/doc/ops/first-deployment.md).
