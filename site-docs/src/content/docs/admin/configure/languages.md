---
title: Languages
description: Set the instance default timezone and language, and point each user to their own settings.
type: how-to
audience: [operator, user]
features: [FE-20]
sidebar:
  order: 6
verified_at: eee55a2
---

Two people opened the same booking and read different times. Facet shows
datetimes and interface text per account. Every account sets its own
timezone and language on the in-app Settings page. The instance default
fills the gap for accounts that follow the server. You set that default in
the config file or on the platform settings page.

## When to use this

Set localization when:

- You set the default timezone or language for the whole install.
- You answer why two accounts see different times for one document.
- You point users to their own preferences.

## Before you start

- The allowed languages are `en` and `fr`.
- The default timezone must be `auto` (each account follows its browser) or
  a loadable IANA name, for example `Europe/Paris`.
- Both keys are hot: a runtime pin applies without a restart, while a
  config file change needs one.

## Steps

### 1. Set the defaults in the config file

```yaml
localization:
  default_timezone: UTC
  default_language: en
```

The section is optional. The built-in defaults are `auto` and `en` — with
no section, every account that follows the server sees times in its own
browser's zone. The shipped dev and production config examples set `UTC`
instead, so a fresh container install shows UTC until an account picks its
own zone. The load validates both: a timezone the runtime cannot load, or
a language outside the allowlist, fails the boot.

### 2. Pin the defaults at runtime

Open **Configure → Platform → Settings** and set
`localization.default_timezone` or `localization.default_language`. The
save reaches every running process, so no restart is needed. Clear the
pin to follow the file again.

The same save works through the API. The body nests one object level per
path segment:

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

### 3. Know the chain

Each account key resolves in this order:

1. The account's own row, set on the in-app Settings page.
2. The server default: the settings pin, then the config file, then the
   built-in default.
3. The static default: `auto` for the timezone, `en` for the language.

The mapping is `core.timezone` → `localization.default_timezone`, and
`core.language` → `localization.default_language`. An account row always
wins. A cleared account row follows the server.

### 4. Point users to their own settings

Users open the in-app **Settings** page:

- **Timezone** offers `Automatic ({zone})`, which follows the browser, and
  `Server default ({value})`, which clears the account row and follows
  your instance default.
- **Language** offers English and Français, with the same `Server default`
  option.

Saves are instant, one field at a time. See
[Your settings and API keys](/use/account/)
for the user's view.

### 5. Know what follows the settings

- Datetimes render in the account's display timezone, across tables,
  audit views, datetime pickers, and CSV exports.
- `date` and `dateperiod` values are calendar dates. They render as
  written and never pass through a timezone conversion.
- The interface language cookie mirrors the account language, so the
  choice holds across reloads and sign-ins.

## Example

Set the instance defaults for an office in Paris, and check the effective
values:

```yaml
localization:
  default_timezone: Europe/Paris
  default_language: en
```

Or pin the same values at runtime without a restart:

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"localization": {"default_timezone": "Europe/Paris", "default_language": "fr"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

Accounts that picked their own values keep them. Accounts on
`Server default` switch at once.

## Troubleshooting

**The boot fails and names `localization.default_timezone`.**

The value is neither `auto` nor a loadable IANA name. Use `auto`, or a name
the runtime can load, for example `Europe/Paris`.

**A save answers `422` on the language.**

The value is outside the allowlist. Use `en` or `fr`.

**A user sees times in the wrong zone.**

The account row wins over the server default. The user picks the right
zone on the Settings page, or selects `Server default` to follow you.
`Automatic` follows the browser, not the server.

**A pin change did not reach one user.**

That user holds an account row for the key. The server default only
fills an empty row.

## Related

- [Your settings and API keys](/use/account/) — the account-level preferences users change.
- [System settings](/admin/configure/system-settings/) — the runtime tier and how pins work.
- [Configuration files](/admin/configure/configuration-files/) — the file the defaults live in.
- Internals on GitHub: [settings.md](https://github.com/wearefacet/facet/blob/main/doc/frontend/settings.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
