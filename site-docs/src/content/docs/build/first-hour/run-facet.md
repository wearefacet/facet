---
type: tutorial
title: Run Facet
description: Start the container stack, seed the first admin, and sign in.
audience: [evaluator, operator]
features: [PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24]
sidebar:
  order: 1
prev: /build/first-hour/
next: /build/first-hour/first-domain/
verified_at: c34885a
---

You have the repository on your machine and you want Facet running in front
of you. Five containers give you a complete instance: PostgreSQL, Redis, the
backend, the frontend, and the Caddy edge that terminates TLS. At the end of
this tutorial the first administrator is signed in and the welcome tour has
introduced the product.

**You will build:** a running Facet instance with one admin account.
**Time:** about 15 minutes, plus the first image build.
**You need:** [Docker with Compose](https://docs.docker.com/compose/) and a
browser. Check Docker with `docker compose version`.

## 1. Set the stack values

The stack reads its values from one file. Copy the template next to the
compose file:

```sh
cd facet
cp docker/.env.example docker/.env
```

Open `docker/.env` and set the values the file comments describe. At
minimum:

- `POSTGRES_PASSWORD` — the password of the built-in PostgreSQL.
- `FACET_SECRETS_MASTER_KEY` and `FACET_ARTIFACT_GRANT_SECRET` — two
  secrets. Generate each with `openssl rand -base64 32`.
- `JWT_SIGNING_KEY` — a P-256 private key in PEM form. Generate one with
  `openssl ecparam -genkey -name prime256v1 -noout`. The backend uses it to
  sign session tokens; without it, every restart invalidates outstanding
  sessions.
- `FACET_SMTP_*` — placeholder values are fine for now. Real delivery
  matters when you invite people by link (tutorial 5).

A missing value fails the boot with a message that names the variable. Fix
the file and start again — the boot is safe to repeat.

## 2. Start the stack

From the repository root:

```sh
docker compose -f docker/compose.prod.yml up -d --wait
```

The first run pulls or builds five images, which takes a few minutes.
`--wait` returns when every service reports healthy. On a fresh volume the
backend bootstraps itself: the boot log shows `facet migrate` applying the
database migrations, then `facet seed:core` creating the core doctypes. You
never run a schema step by hand.

You should see five healthy containers:

```sh
docker compose -f docker/compose.prod.yml ps
```

```text
NAME                          IMAGE                          STATUS
facet-docs-wp14a-backend-1    facet                          Up 18 seconds (healthy)
facet-docs-wp14a-caddy-1      caddy:2                        Up 6 seconds
facet-docs-wp14a-frontend-1   facet-frontend                 Up 12 seconds (healthy)
facet-docs-wp14a-postgres-1   pgvector/pgvector:0.8.0-pg17   Up 23 seconds (healthy)
facet-docs-wp14a-redis-1      redis:7                        Up 23 seconds (healthy)
```

Ask the backend directly. The readiness probe answers `status: ok`:

```sh
curl -sk https://facet.localhost:3443/Healthcheck
```

```json
{"status":"ok","service":{"env":"production","instance_id":"06H1G35H…"},"database":{"status":"ok","error":null,"pools":[{"database":"main","role":"rw","status":"ok","error":null}]},"redis":{"status":"ok",…}
```

The probe path is `/Healthcheck`, with a capital H. The lowercase spelling
answers 404, so a typo cannot fake a green light.

## 3. Create the first admin

A fresh install has no login. Create the administrator with the bootstrap
command:

```sh
docker compose -f docker/compose.prod.yml run --rm backend seed:admin ops@your-company.tld
```

The command prints the account and a one-time password:

```text
Admin account created.
  email:    ops@your-company.tld
  id:       06H1G3A8YM80JQJ52B9VNNTFQJ
  password: BVPK-XYC2-XDNG-DGTZ

This password is shown once. It is not stored in plaintext and not logged.
The account must change the password at first login.
```

Record the password now. Nobody can read it back — Facet stores only a
bcrypt hash.

Check the account exists:

```sh
docker compose -f docker/compose.prod.yml exec -T backend sh -c './facet accounts:list'
```

```text
06H1G3A8YM80JQJ52B9VNNTFQJ	ops@your-company.tld	Administrator	active	iam.Roles.admin
```

## 4. Sign in and set your password

Open `https://facet.localhost:3443`.

Your browser warns about the certificate. The edge issues it from its own
internal certificate authority — expected for a `.localhost` name. Accept
the warning to continue.

Sign in with the email and the one-time password. Facet does not open the
workspace yet: it first asks you to set a real password on the **Set a new
password** screen. Enter the one-time password under **Current password**,
choose a new password of at least 8 characters, and click **Save password
and continue**. The one-time password stops working the moment the change
lands.

![The Set a new password screen asks for the current password and the new password twice.](/assets/screens/build/run-facet-3.png)

The next screen can ask you to set up two-factor authentication: scan the
code with an authenticator app on your phone, or choose **Skip for now**.
You can enroll later — the steps are in
[Sign in and secure your account](/use/first-day/sign-in/).

You land on the dashboard, signed in as the admin.

## 5. Take the welcome tour

The first sign-in as the seeded admin opens the welcome tour: seven steps
that present Facet — the governance layer, domains, the Builder, roles, the
audit trail, integrations — and end with two buttons, **Create a domain**
and **Import a bundle**.

![The welcome tour opens on the dashboard at its first step, A governance layer.](/assets/screens/build/run-facet-2.png)

Click **Next** through the seven steps, or tick **Don't show again**. The
final step's buttons lead straight into your first domain — which is the
next tutorial. You can restart the tour later in **Settings**.

## What you learned

- A Facet instance is five containers, started from one compose file.
- The backend bootstraps its own schema — migrations and core doctypes — on
  the first boot.
- `seed:admin` creates the first administrator with a one-time password.
- First sign-in ends with a password change and the welcome tour.

## Troubleshooting

### The backend fails to boot

Read the boot log — it names the missing or wrong value:

```sh
docker compose -f docker/compose.prod.yml logs backend
```

Every required value must be set in `docker/.env`. Set the named variable
and start the stack again.

### The browser cannot reach `facet.localhost`

Try the address with the explicit port, `https://facet.localhost:3443`. If
you changed `HTTPS_PORT` in `docker/.env`, use that port.

### The one-time password is lost

Nobody can recover it. Create a second admin and reset the first account
from the UI:

```sh
docker compose -f docker/compose.prod.yml run --rm backend seed:admin second-admin@your-company.tld
```

## Related

- [Your first hour](/build/first-hour/) — the route this tutorial starts.
- [Deploy to production](/admin/install/production/) — the same stack,
  hardened for a real host.
- [The bootstrap CLI](/reference/cli-facet/) — `seed:admin`,
  `accounts:list` and the other commands.
- [Security and governance](/discover/security/)
## Next

You have Facet running. In [Model your first domain](/build/first-hour/first-domain/)
you build the Brightwater equipment domain in the Builder.
