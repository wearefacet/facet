---
title: Configure Facet
description: Pick the configure job — the config file, runtime settings, email, file storage, currencies, or languages.
type: overview
audience: [admin, operator]
features: []
sidebar:
  order: 0
verified_at: eee55a2
---

Facet needs its knobs set before the team arrives: where files go, how
email leaves, which currencies the money fields accept. Configuration
splits in two tiers. One YAML file configures the whole backend and binds
at boot. A runtime settings document sits on top of it and changes the hot
keys — mail, retention, the assistant connection — without a restart.

## What do you want to do?

- **Write or change the config file** →
  [Configuration files](/admin/configure/configuration-files/). How the
  file resolves, how `!env` keeps secrets out of it, and which keys are
  hot.
- **Change a knob without a restart** →
  [System settings](/admin/configure/system-settings/). Pin, read, and
  reset the runtime tier over the file.
- **Make password resets arrive** →
  [Email](/admin/configure/email/). The SMTP relay, the production gate,
  and the built-in test probe.
- **Decide where uploads live** →
  [File storage](/admin/configure/file-storage/). A local directory or an
  S3 bucket, the 50 MiB cap, and the store care tasks.
- **Control the money fields** →
  [Currencies](/admin/configure/currencies/). The seeded registry, the
  active rule on every write, and money filters.
- **Set the defaults everyone sees** →
  [Languages](/admin/configure/languages/). The instance timezone and
  language, and how each account's own choice wins.

## All pages in this section

1. [Configuration files](/admin/configure/configuration-files/)
2. [System settings](/admin/configure/system-settings/)
3. [Email](/admin/configure/email/)
4. [File storage](/admin/configure/file-storage/)
5. [Currencies](/admin/configure/currencies/)
6. [Languages](/admin/configure/languages/)

## Related

- [Go to production](/admin/install/production/) — the deploy checklist that ends in configuration.
- [The big picture](/discover/how-it-works/) — the concepts behind the tiers.
