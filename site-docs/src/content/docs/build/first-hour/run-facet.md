---
type: tutorial
title: Run Facet
description: Start Facet on your machine with one command, sign in as the admin, and take the welcome tour.
audience: [evaluator, operator]
features: [PLT-16, PLT-01, IAM-12, FE-01, FE-19, DOM-24]
sidebar:
  order: 1
verified_at: c34885a
---

You want Facet running in front of you, without cloning the repository. One
command gives you a complete instance: PostgreSQL, Redis, the backend, the
frontend, and the Caddy edge that terminates TLS — five containers, all
started for you. The two Facet images are pulled from GHCR — you do not build
them. At the end of this tutorial the administrator is signed in and the
welcome tour has introduced the product.

**You will build:** a running Facet instance with one admin account.
**Time:** about 10 minutes, plus the first image pull.
**You need:** [Docker with Compose](https://docs.docker.com/compose/), Node
20+, and a browser. Check both with `docker compose version` and
`node --version`.

## 1. Start the stack

Run the CLI command in an empty folder. It writes the stack files, starts the
containers, seeds the admin, and fetches an API key:

```sh
pnpx @facetapp/cli setup-dev
```

Three questions, each with a default — press Enter three times:

```text
Hostname [facet.localhost]:
HTTPS port [3443]:
Watch a folder for domain bundles? (Y/n):
```

The command then writes `compose.yml`, `.env` with generated secrets,
`config.dev.yml`, `Caddyfile.prod`, and `facet.config.json`, and runs
`docker compose up -d --wait`. The first run pulls five images, which takes a
few minutes. `--wait` returns when every service reports healthy.

`setup-dev` also writes `.gitignore` and runs `git init`, so the secrets stay
out of version control. To scaffold without starting, pass `--no-start`; to
take every default without a question, pass `--yes`.

## 2. Sign in

Open `https://facet.localhost:3443`.

Your browser warns about the certificate. The edge issues it from its own
internal certificate authority — expected for a `.localhost` name. Accept the
warning to continue.

Sign in with the dev admin:

- **Email**: `admin@example.tld`
- **Password**: `admin`

`setup-dev` also printed both, with the URL, in its summary. This credential
is a dev default: it skips the password-change step and the platform refuses
to seed it on a production instance.

:::note
The `setup-dev` command fetches an API key through the OAuth consent screen
in your browser. If that prompt appears, choose the admin role and click
**Allow**. The key lands in `.facet.local.json` for `facet-cli` calls; you do
not need it for this tutorial.
:::

You land on the dashboard, signed in as the admin.

## 3. Take the welcome tour

The first sign-in opens the welcome tour: seven steps that present Facet —
the governance layer, domains, the Builder, roles, the audit trail,
integrations — and end on **Your first domain** with three buttons: **Create
a domain**, **Import a bundle**, and **Done**.

![The welcome tour opens on the dashboard at its first step, A governance layer.](/screens/build/run-facet-2.png)

Click **Next** through the seven steps, or tick **Don't show again** to stop
it opening at your next sign-in. The tour leaves you on the dashboard, where
the sidebar offers **Builder** and **Configure**. To see the tour again, turn
**Show the welcome tour** back on in **Settings → Welcome tour**.

## What you learned

- One command, `facet-cli setup-dev`, starts a complete Facet instance — five
  containers, no repository clone, no build.
- The backend bootstraps its own schema — migrations and core doctypes — on
  the first boot.
- The dev admin is `admin@example.tld` / `admin`; a production instance uses
  `seed:admin` and a one-time password instead.
- The welcome tour introduces the product on the first sign-in.

## Troubleshooting

### The command stops before the stack starts

`setup-dev` fails when Docker is missing or when the folder already holds a
stack. Check Docker with `docker compose version`. For an existing folder,
re-run with `--force` to overwrite the stack files, or pass `--dir` to pick
another folder.

### The backend fails to boot

Read the boot log — it names the missing or wrong value:

```sh
docker compose logs backend
```

### The browser cannot reach `facet.localhost`

Try the address with the explicit port, `https://facet.localhost:3443`. If
you answered a different HTTPS port at the first question, use that port.

### Sign-in is refused

The dev credential is `admin@example.tld` / `admin`. If you reset the
database (`docker compose run --rm backend db_reset --yes seed:dev`), the
same credential works again.

## Related

- [Your first hour](/build/first-hour/) — the route this tutorial starts.
- [Deploy to production](/admin/install/production/) — a real host, a real
  hostname, and `seed:admin` instead of the dev credential.
- [Run with containers](/admin/install/containers/) — the images, the config
  mount, and the TLS edge in detail.
- [The `facet-cli` developer CLI](/reference/cli-npm/) — `setup-dev` and the
  other commands, with their options.
- [Config file keys](/reference/config-keys/) — every key the generated
  `config.dev.yml` sets, with its type and default.
- [Security and governance](/discover/security/)

## Next

You have Facet running. In [Model your first domain](/build/first-hour/first-domain/)
you build the Brightwater equipment domain in the Builder.
