# First deployment — bootstrap

The runbook for the first deployment of a Facet instance: prepare an empty
database, create the first admin account, and verify the login. Topology,
images, and the edge config are the deployment guide's scope (see
[`container-images.md`](container-images.md)).

## Prerequisites

| Requirement | Check |
| --- | --- |
| PostgreSQL 14+ reachable | `DATABASE_URL` points at the empty database |
| Redis reachable | `event.url` in `config.{APP_ENV}.yml` |
| Config file for the environment | `config.{APP_ENV}.yml` exists; the mail adapter is not `dev` (the boot refuses it — see [`doc/backend/config.md`](../backend/config.md) → Mail adapter gate) |
| Binary built | `make build_release` (or the container image) |

## Steps

### 1. Create the schema and the core doctypes

Two entry points:

```bash
facet migrate && facet seed:core
```

The non-destructive chain: `migrate` applies every pending migration,
`seed:core` seeds the core doctypes and the currency registry into an
already-migrated database. Both steps are idempotent — re-running them on a
seeded database changes nothing — so the chain is safe on an existing install
too. This is the chain the release image's entrypoint runs on every boot.

Or, for a first deployment where dropping is acceptable:

```bash
facet db_reset
```

`db_reset` drops the target database, re-creates it, runs every migration,
and seeds the core doctypes in one step. It creates **no account** — run it
only against a database that may be dropped (a first deployment qualifies;
an upgrade never does — upgrades run `facet migrate` and `facet seed:core`).

### 2. Create the first admin

```bash
facet seed:admin ops@your-company.tld
```

The command prints the account id and a **one-time password**:

```
Admin account created.
  email:    ops@your-company.tld
  id:       01J…
  password: K7M4-9XQ2-WBTD-H3PN

This password is shown once. It is not stored in plaintext and not logged.
The account must change the password at first login.
```

Record the password in your password manager now. The command never prints
it again. The email may also come from the `SEED_ADMIN_EMAIL` environment
variable (`facet seed:admin` with no argument), which suits scripted
deployments that inject the value from a secret store.

Re-running the command with the same email fails with a non-zero exit code —
the bootstrap never resets an existing credential.

### 3. Verify the account

```bash
facet accounts:list
```

The account appears with the `iam.Roles.admin` role.

### 4. First login and password change

Open the application and sign in with the email and the one-time password.
The login short-circuits into the password-change bootstrap
(`must_change_pw: true` — the API returns a one-shot change token; the UI
forces the new password before any session is issued). After the change, the
one-time password no longer logs in.

Alternative without the UI (both calls need the `X-Requested-With` header —
the same CSRF rule every state-changing IAM route enforces):

```bash
# Login with the one-time password — the response carries
# {"must_change_password": true, "change_token": "…"}.
curl -s -X POST https://your-host/Api/iam/login \
  -H 'Content-Type: application/json' -H 'X-Requested-With: fetch' \
  -d '{"email": "ops@your-company.tld", "password": "<one-time password>", "cookie": false}'

# Change the password — the one-time password is the `old_password`;
# the new one needs at least 8 characters. Consumes the change token.
curl -s -X POST https://your-host/Api/iam/change-password \
  -H 'Content-Type: application/json' -H 'X-Requested-With: fetch' \
  -d '{"change_token": "<token from the login response>", "old_password": "<one-time password>", "new_password": "<new password>"}'
```

Then log in with the new password.

### 5. Post-bootstrap checks

- `GET /Healthcheck` reports `status: ok`.
- The login lands in the audit log (`iam.LoginEvent`).
- Recovery path works: a second admin can reset the first admin's password
  through the password-reset flow — this needs working mail delivery
  (`mail.adapter: smtp`), which is one more reason the dev mail adapter is
  refused in production.

## Rules

- `facet seed:dev` is refused when `APP_ENV=production` — it writes the
  known default credential (`admin@example.tld` / `admin`,
  `SEED_ADMIN_PASSWORD`) with `must_change_pw: false`. First-admin creation
  in production goes through `seed:admin` only.
- An install that skipped step 2 has **no login**. `db_reset` creates no
  account by design.
- Lost one-time password: the account exists but nobody knows the password.
  Recover with the password-reset flow (needs mail delivery), or bootstrap a
  second admin with `seed:admin` and reset the first account from the UI.
