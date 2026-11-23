---
title: System settings
description: Change platform settings at runtime from the Configure area, with the config file as fallback.
audience: [operator, admin]
features: [PLT-02, FE-14]
sidebar:
  order: 5
verified_at: 008dd880
---

Some platform knobs can change without a restart. They live on one system
document, `core.SystemSettings`. An administrator edits it in the
**Configure → Platform → Settings** page, the change reaches every running
process, and the config file stays as the fallback.

## When to use this

Edit system settings when:

- You change a knob and cannot restart the server.
- You pin a value over the config file for one environment.
- You give a value back to the file after a pin.

## Before you start

- You hold a role that can update `core.SystemSettings`. The default is
  admin-only.
- The effective value of a knob resolves in this order: the settings
  document, then `config.{env}.yml`, then the built-in default. A cleared
  field follows the file.

## Steps

### 1. Read the effective values

Open **Configure → Platform → Settings**, or call the read route:

```sh
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/SystemSettings"
```

The response carries two lists:

- `values` — the effective, non-secret values, keyed by dotted path.
- `pinned` — the paths the document currently pins.

The page shows an override badge on every pinned field, with a
reset-to-file control. The reset sends an explicit `null`, and the field
follows the file again.

### 2. Pin a value

Edit the field on the settings page and save. The page sends a sparse
update: only the fields you touched. Untouched pins stay pinned.

The write path is the standard document route, so the same save works from
an API call. The body nests one object level per path segment:

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"assistant": {"model": "gpt-4o"}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

A flat key fails shape validation. A body of
`{"assistant.model": "gpt-4o"}` answers `422`.

Secrets ride the same save. The page stages each typed plaintext first, and
the save carries a single-use handle, never the plaintext. Clearing a
secret slot returns the value to the file.

### 3. Know the registered paths

| Group | Paths |
| --- | --- |
| Assistant | `assistant.name`, `assistant.api_endpoint`, `assistant.api_key` (secret), `assistant.model`, `assistant.system_prompt`, `assistant.max_tokens`, `assistant.temperature`, `assistant.max_history`, `assistant.auto_execute_tools` |
| Mail | `mail.adapter`, `mail.from_address`, `mail.from_name`, `mail.smtp.host`, `mail.smtp.port`, `mail.smtp.username`, `mail.smtp.password` (secret), `mail.smtp.use_tls` |
| Artifacts | `artifact.grant_ttl_seconds`, `artifact.grant_ttl_media_seconds`, `artifact.prune_after_days`, `artifact.storage.type` (read-only) |
| Retention | `mutations.retention_days`, `tombstone.content_retention_days` |
| Localization | `localization.default_timezone`, `localization.default_language` |
| IAM policy | `iam.mfa.type`, `iam.mfa.enforcement`, `iam.auth.mode`, `iam.change_password_expiration` |

### 4. Know the write rules

A save passes three gates. Shape comes from the doctype definition,
singleton guards protect the one document, and a semantic write gate checks
each value:

- `temperature` between 0.0 and 2.0, `max_tokens` above 0, `max_history` 0
  or more, `port` between 1 and 65535.
- The grant TTLs and `iam.change_password_expiration` are 1 second or more.
- The retention windows are 0 or more. A window of `0` means keep forever.
- `mail.adapter: smtp` requires a non-null `mail.smtp.host`.
- `mail.adapter: dev` is refused under `APP_ENV=production`, unless the file
  sets `mail.allow_dev_adapter_in_production: true`.
- `localization.default_timezone` must be `auto` or a loadable IANA name.
- `iam.mfa.type` is `none` or `totp`; `iam.mfa.enforcement` is `preferred`
  or `always`; `iam.auth.mode` is `hybrid` or `oidc_only`. `oidc_only` is
  refused while no enabled OIDC provider document exists.
- Any value on `artifact.storage.type` is refused. The storage adapter wires
  once per process from the file. A runtime switch would strand the existing
  bytes in the old backend.

:::caution
Not every knob is hot. Cron schedules, `jobs.*`, and `hooks.*` bind at boot
and stay file-only. A settings save cannot change them.
:::

## Example

Pin a short tombstone window, see it applied at the next daily pass, then
give it back to the file:

```sh
# Pin the window to 7 days.
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": 7}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"

# Show the pin.
curl -s -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/SystemSettings"
# "pinned" now lists "tombstone.content_retention_days".

# Reset the pin — the field follows the config file again.
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tombstone": {"content_retention_days": null}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

The daily prune pass reads the window at the top of each run. The save needs
no restart.

## Troubleshooting

**A config file change does nothing.**

The path is pinned in the settings document. Clear the pin on the settings
page.

**A save answers `422` with `is not a defined field`.**

The body used a flat dotted key. Nest one object level per path segment.

**A save answers `422` on `iam.auth.mode`.**

`oidc_only` needs one enabled OIDC provider document. Register and enable a
provider first — see [Single sign-on with OIDC](/govern/sso-oidc/).

**A save of `mail.adapter: dev` is refused in production.**

The write gate mirrors the boot gate. Set the file hatch
`mail.allow_dev_adapter_in_production: true` if the install must keep stdout
delivery.

**The retention window did not shrink the log yet.**

The pass runs on its cron entry, by default once a day. Rows younger than
the window stay untouched.

## Related

- [Configuration files](/operate/configuration-files/) — the file tier under the pins.
- [Retention: what is kept and for how long](/govern/retention/) — the windows the retention pins set.
- [Governing the assistant](/govern/governing-assistant/) — the role budgets the assistant settings feed.
- [Enforcing MFA](/govern/enforcing-mfa/) — what `iam.mfa.*` drives.
- [Single sign-on with OIDC](/govern/sso-oidc/) — what `iam.auth.mode` drives.
- Internals on GitHub: [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md), [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md).
