---
type: tutorial
title: Run Facet in 15 minutes
description: Start the container stack, seed the first admin, and sign in.
audience: [evaluator, operator]
features: [PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24]
sidebar:
  order: 1
verified_at: e7c24a4
---

You want Facet running on your machine, an administrator account, and the
product in front of you. This tutorial gets you there with Docker Compose in
about 15 minutes. No toolchain, no source build — five containers do the work.

At the end you hold a working instance: the first admin signed in, the core
schema seeded, and the welcome tour on screen.

## What you need

- Docker with Compose. Check with `docker compose version`.
- A web browser.
- About 15 minutes and 2 GB of free disk for the images.

## Step 1 — Get the stack files

Clone the repository and copy the environment template:

```sh
git clone https://github.com/wearefacet/facet.git
cd facet
cp docker/.env.example docker/.env
```

The file `docker/.env` holds the values the stack needs: your public
hostname, an SMTP relay, and two secrets. The file comments explain every
key. Set at minimum:

- `POSTGRES_PASSWORD` — a password for the built-in PostgreSQL.
- `FACET_SECRETS_MASTER_KEY` and `FACET_ARTIFACT_GRANT_SECRET` — generate
  each with `openssl rand -base64 32`.
- `FACET_HOSTNAME` — the default `facet.localhost` works on your machine.
- `FACET_SMTP_*` — any placeholder works for this tutorial; real email
  delivery matters only when you invite people by link.

:::tip
Generate both secrets in one go:

```sh
openssl rand -base64 32 && openssl rand -base64 32
```
:::

### Checkpoint

`docker/.env` exists next to `docker/compose.prod.yml` and holds no empty
required value.

## Step 2 — Start the stack

```sh
docker compose -f docker/compose.prod.yml up -d --wait
```

The first run pulls or builds five images: PostgreSQL, Redis, the backend,
the frontend, and the Caddy edge. `--wait` returns when every service
reports healthy. On a fresh volume the backend runs its own bootstrap:
it applies all migrations and seeds the core schema (the core doctypes and
the currency registry). You never run a schema step by hand.

### Checkpoint

List the containers — all five show `healthy`:

```sh
docker compose -f docker/compose.prod.yml ps
```

```text
NAME                   IMAGE                        STATUS
facet-backend-1        facet                        Running (healthy)
facet-caddy-1          caddy:2                      Running (healthy)
facet-frontend-1       facet-frontend               Running (healthy)
facet-postgres-1       pgvector/pgvector:0.8.0-pg17 Running (healthy)
facet-redis-1          redis:7                      Running (healthy)
```

Ask the backend directly — the readiness probe answers `status: ok`:

```sh
curl -sk https://facet.localhost:3443/Healthcheck | head -c 120
```

```json
{"status":"ok","service":{"env":"production","instance_id":"01J…"},"database":{"status":"ok",…
```

The probe is `/Healthcheck` with a capital H. The edge answers the lowercase
spelling with a 404, so a typo cannot fake a green light.

## Step 3 — Create the first admin

A fresh install has no login. Create the administrator with the bootstrap
command; the entrypoint of the image runs the binary, so the argument is the
command alone:

```sh
docker compose -f docker/compose.prod.yml run --rm backend seed:admin ops@your-company.tld
```

The command prints the account and a one-time password:

```text
Admin account created.
  email:    ops@your-company.tld
  id:       06H040XW78F12FFVHGBXCXBR2H
  password: MBN8-AAWR-ZMTQ-882H

This password is shown once. It is not stored in plaintext and not logged.
The account must change the password at first login.
```

:::caution
Record the password now. The command never prints it again, and no one can
read it back — it is stored only as a bcrypt hash.
:::

### Checkpoint

The account exists and holds the admin role:

```sh
docker compose -f docker/compose.prod.yml exec -T backend sh -c './facet accounts:list'
```
```text
06H040XW78F12FFVHGBXCXBR2H	ops@your-company.tld	Administrator	active	iam.Roles.admin
```

## Step 4 — Sign in and set your password

Open `https://facet.localhost:3443`.

Your browser warns about the certificate. The edge issues it from its own
internal certificate authority — expected for a `.localhost` name. Accept the
warning to continue (or import the edge root CA into your system trust
store; see [Deploy to production](/admin/install/production/)).

Sign in with the email and the one-time password. Facet does not issue a
session yet: it first asks you to set a real password on the
**Set a new password** screen. Enter a new password of at least 8
characters and save. The one-time password stops working the moment the
change lands.

### Checkpoint

You land in the workspace, signed in as the admin.

## Step 5 — Take the welcome tour

The first sign-in as the seeded admin opens a short welcome tour: seven
steps that position the product and end with two buttons — **Create a
domain** and **Import a bundle**. Click through it, or tick **Don't show
again**; you can restart the tour later in Settings.

### Checkpoint

The tour is closed and the dashboard is in front of you. Your instance is
ready for real work.

## Result

You now run a complete Facet instance:

- five containers, all healthy, with TLS at the edge;
- the core schema seeded (19 core doctypes on a fresh boot);
- one admin account with your own password;
- a session in your browser.

## Troubleshooting

### `docker compose up` fails with a red backend

Read the boot log — it names the missing or wrong value:

```sh
docker compose -f docker/compose.prod.yml logs backend
```

The backend refuses to boot on a missing environment variable. Every `!env`
name in the shipped config must be set in `docker/.env`. Set the named
variable and start the stack again — the boot is idempotent and safe to
repeat.

### The browser cannot reach `facet.localhost`

The name resolves through your system's localhost handling. Try the address
with the explicit port `https://facet.localhost:3443`. If you changed
`HTTPS_PORT` in `docker/.env`, use that port.

### The certificate warning blocks you

The warning is the internal certificate authority at work, not a broken
setup. Accept it, or import the edge root CA — the production guide shows
the options.

### The one-time password is lost

Nobody can recover it. Two ways out:

- If mail delivery works (`FACET_SMTP_*` set to a real relay), use the
  password-reset flow on the login screen.
- Otherwise create a second admin and reset the first account from the UI:

  ```sh
  docker compose -f docker/compose.prod.yml run --rm backend seed:admin second-admin@your-company.tld
  ```

## Next steps

- [Build your first domain](/build/first-hour/first-domain/) — model an
  Inventory domain in the Builder, on the instance you just started.
- [Give your team access](/build/first-hour/team-access/) — invite a colleague,
  scope what they see.
- [Deploy to production](/admin/install/production/) — the same stack, hardened
  for a real host.
