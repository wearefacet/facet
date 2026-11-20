---
title: Configuration files
description: Write the config file that boots the backend, and inject secrets with the !env tag.
audience: [operator]
features: [PLT-01]
sidebar:
  order: 4
verified_at: 008dd880
---

One YAML file configures the whole backend: `config.{env}.yml`. The file is
the single source of truth for boot. Database and Redis addresses exist only
in it, so the file must load before the database connects. Some keys are
hot: a runtime settings document can override them without a restart, and
the file stays the fallback.

## When to use this

Use this page when:

- You write or change `config.production.yml`.
- You keep secrets out of the YAML file.
- You need to know which keys a restart changes and which it does not.

## Before you start

- You know the value of `APP_ENV` for the deployment. The filename carries
  it: `config.production.yml` for `APP_ENV=production`.
- Three values stay in the environment, never in YAML: `DATABASE_URL`,
  `APP_ENV`, and `JWT_SIGNING_KEY`.

## Steps

### 1. Put the file where the backend looks

The backend resolves one file, in this order:

1. `FACET_CONFIG_FILE` — an explicit path. A set-but-missing path fails the
   boot. There is no fallback to another file.
2. `config.{APP_ENV}.yml` next to the binary — the default.

The boot fails loud when no file resolves. It never runs with another
environment's settings.

### 2. Inject secrets with `!env`

Tag any scalar with `!env` to expand an environment variable at load:

```yaml
artifact_grant_secret: !env ARTIFACT_GRANT_SECRET
```

Rules:

- The expanded value is always a string.
- A missing variable fails the boot. The error names the variable and the
  config file. There is no silent-empty fallback.
- The tag works anywhere in the document: top-level keys, nested sections,
  and lists.
- The tag is rejected in domain bundles and doctype definitions. Imported
  authoring content cannot read your environment.

### 3. Know the sections

| Section | Holds | Notes |
| --- | --- | --- |
| `event` | Redis URL and stream tuning | Required. The boot fails without it. |
| `artifact` | File storage backend and serving knobs | Required. `artifact.storage` fails loud when absent. |
| `mail` | Outbound email adapter and SMTP | See [Email delivery](/operate/email/). |
| `iam` | Token TTLs, MFA, auth mode, cookies | |
| `assistant` | LLM connection and turn tuning | See [Configuring the assistant](/operate/assistant-config/). |
| `database` | Statement timeout and the cluster route table | See [System requirements and topology](/operate/system-requirements/). |
| `mutations` | Edit-history retention and coalescing | |
| `tombstone` | Deleted-content payload retention | |
| `secrets` | Master key and secret-store tuning | |
| `jobs` | Background job queue tuning | Binds at boot. |
| `hooks` | Event and schedule hook scheduler | Binds at boot. |
| `lua` | Sandbox limits for doctype scripts | |
| `localization` | Instance timezone and language defaults | |
| `domains` | `included` / `excluded` domain filter | Set one, never both. |
| `logs` | Log format and level | |
| `cache` | Process-cache staleness bound | |
| `websocket` | WebSocket bridge tuning | |
| `webhook`, `import_export`, `sidecar`, `mcp` | Optional subsystem knobs | Defaults apply when absent. |
| `dev` | Development-only watcher | Not for production. |

Top-level keys sit outside the sections: `host`, `base_url`,
`artifact_base_url`, `artifact_grant_secret`, `artifact_grant_secret_previous`,
`snapshot_every`, `trusted_proxies`. `artifact_base_url` and
`artifact_grant_secret` are required. The boot fails without them.

### 4. Know which keys are hot

A hot key resolves in this order at use time: the `core.SystemSettings`
document, then the file value, then the built-in default. An administrator
can pin a hot key at runtime — see
[System settings](/operate/system-settings/).

Hot keys: the assistant connection, the `mail.*` values, the artifact serving
knobs, the retention windows, the localization defaults, and the IAM policy
values.

File-only keys bind at boot: cron schedules, `jobs.*` and `hooks.*` tuning,
the storage adapter, `retention_overrides`, and
`mail.allow_dev_adapter_in_production`.

:::tip
`trusted_proxies` names the reverse proxies that face the server. An empty
list ignores `X-Forwarded-For` on every request. Entries are bare hosts with
no port. Keep the list exact — every entry can choose the client IP the
server sees.
:::

## Example

A minimal production config. Every key is one the boot requires or reads:

```yaml
host: !env FACET_HOST
base_url: !env FACET_BASE_URL
artifact_base_url: !env FACET_ARTIFACT_BASE_URL
artifact_grant_secret: !env FACET_ARTIFACT_GRANT_SECRET

event:
  url: !env FACET_REDIS_URL

artifact:
  storage:
    type: filesystem
    directory: /data/store

mail:
  adapter: smtp
  from_address: !env FACET_MAIL_FROM_ADDRESS
  from_name: !env FACET_MAIL_FROM_NAME
  smtp:
    host: !env FACET_SMTP_HOST
    port: 587
    username: !env FACET_SMTP_USERNAME
    password: !env FACET_SMTP_PASSWORD
    use_tls: true
```

## Troubleshooting

**The boot fails and names the config path.**

No file resolved. Check `APP_ENV` and the file name, or set
`FACET_CONFIG_FILE`.

**The boot fails with an `IncludeError` that names a variable.**

A `!env` tag names a variable the environment does not define. Define it, or
remove the tag.

**`APP_ENV=production` refuses to boot with a mail error.**

The `dev` mail adapter prints emails to stdout, so production refuses it.
Set `mail.adapter: smtp` — see [Email delivery](/operate/email/).

**The boot fails on a domains error.**

`domains.included` and `domains.excluded` are mutually exclusive. Set one,
never both.

**A file change does nothing.**

A pinned runtime value wins over the file. Check the pins — see
[System settings](/operate/system-settings/).

## Related

- [System settings](/operate/system-settings/) — the runtime tier above the file.
- [System requirements and topology](/operate/system-requirements/) — the addresses the file must carry.
- [Email delivery](/operate/email/) — the `mail:` section in full.
- [File storage: filesystem or S3](/operate/file-storage/) — the `artifact:` section in full.
- [Configuring the assistant](/operate/assistant-config/) — the `assistant:` section in full.
- Internals on GitHub: [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
