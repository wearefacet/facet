---
title: Email
description: Set up outbound email over SMTP, pass the production gate, and test delivery with the built-in probe.
type: how-to
audience: [operator]
features: [AUT-07]
sidebar:
  order: 3
verified_at: eee55a2
---

A new hire did not receive the invite link, and the password reset also
went nowhere. Facet sends email for the credential flows: invite links for
first credentials, and password resets. Delivery goes through one mail
adapter. The default adapter prints email to stdout. Production requires
real delivery over SMTP. In-app notifications are a separate system that
never uses email.

## When to use this

Configure email when:

- You set up SMTP for a new install.
- You move an install from stdout delivery to a relay.
- You change the sender address without a restart.

## Before you start

- You have an SMTP relay account: host, port, username, password.
- You know the `APP_ENV` of the deployment.
- The `mail:` keys are hot keys. A settings save overrides the file without
  a restart — see [System settings](/admin/configure/system-settings/).

## Steps

### 1. Set the mail section

Put the SMTP values in `config.{env}.yml`:

```yaml
mail:
  adapter: smtp
  from_address: no-reply@your-company.tld
  from_name: Facet
  smtp:
    host: smtp.example.tld
    port: 587
    username: relay-user
    password: !env FACET_SMTP_PASSWORD
    use_tls: true
```

The keys and their defaults:

| Key | Default | Meaning |
| --- | --- | --- |
| `mail.adapter` | `dev` | `dev` prints to stdout. `smtp` delivers. |
| `mail.from_address` | `no-reply@facet.local` | The sender address. |
| `mail.from_name` | `Facet` | The sender display name. |
| `mail.smtp.host` | `localhost` | The relay host. |
| `mail.smtp.port` | `587` | The relay port. |
| `mail.smtp.username` | none | The relay user, when the relay asks for one. |
| `mail.smtp.password` | none | The relay password. Use `!env` to keep it out of the file. |
| `mail.smtp.use_tls` | `true` | Upgrade the connection with STARTTLS. |

### 2. Pass the production gate

The boot refuses `adapter: dev` when `APP_ENV=production` and the file does
not set the escape hatch. The error names the exact keys for both paths:

- Set `mail.adapter: smtp` with the `mail.smtp.*` keys — the normal path.
- Or set `mail.allow_dev_adapter_in_production: true` — the air-gapped path.
  Email stays on stdout.

:::caution
Every environment that boots with the `dev` adapter logs one warning. Email
that only prints to stdout never reaches users. A lost password-reset mail
means a locked-out account. Test delivery before you open the install to
users.
:::

The same gate runs at write time. A runtime save that switches the effective
adapter to `dev` under `APP_ENV=production` is refused, unless the file sets
the same hatch. The hatch itself stays file-only.

### 3. Change values without a restart

The `mail.*` keys are hot. Pin them on the
**Configure → Platform → Settings** page, or save the settings document:

```sh
curl -k -X PATCH -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"mail": {"from_address": "no-reply@your-company.tld"}}' \
  "$(facet-cli host)/Api/core/SystemSettings/settings"
```

A settings save rebuilds the adapter, so the next email uses the new values.
The write gate checks the merged state: `mail.adapter: smtp` needs a
non-null `mail.smtp.host`.

### 4. Test delivery

The settings page has a probe for exactly this. Open
**Configure → Platform → Settings**, find **Send a test email**, type the
recipient, and select **Send test email**. One email travels through the
saved connector — the same path password resets and invites take. Save any
pending change first; the test uses the saved settings, not the form.

The possible answers:

| Answer | Meaning |
| --- | --- |
| `200 {adapter, from_address, to}` | Delivered. The response names the transport and the sender it used. |
| `422` | Facet refused before the wire: the connector is still `dev`, or the address is malformed. |
| `502` | The transport failed. The message carries the relay's own error — "connection refused" or a 535 authentication failure is the diagnostic you pressed the button for. |

On an install that still runs the `dev` adapter, the probe refuses with:

```json
{"error": "The email connector is off: the 'dev' adapter prints to stdout and delivers nothing. Set mail.adapter to smtp and save before testing"}
```

As a second check, drive a password reset from the sign-in page. The reset
link arrives by email only, so a delivered email proves the whole path:
adapter, relay, sender address, and link TTL. The link TTL is
`iam.change_password_expiration`, 24 hours by default.

## Example

An air-gapped install that must keep stdout delivery, with the hatch set:

```yaml
mail:
  adapter: dev
  allow_dev_adapter_in_production: true
  from_address: no-reply@your-company.tld
  from_name: Facet
```

Every email prints to stdout. The probe refuses to report success here — it
would prove nothing, because no inbox received anything. Pair this posture
with an operator flow that watches the backend logs, because
password-reset and invite links never reach an inbox.

## Troubleshooting

**The boot fails with a mail adapter error.**

Production refuses the `dev` adapter without the hatch. Follow the two
paths in the error message, or see step 2.

**The test email answers `502`.**

Read the message: it is the relay's own error. Wrong port, `use_tls: false`
against a TLS-only relay, and relay authentication failures are the common
causes. Fix the value, save, and send the probe again.

**Email does not arrive.**

Check the backend logs for the send attempt, then run the probe — it turns
the silent failure into a named error. Drive a password reset to re-test
the link flow.

**A runtime save of the adapter is refused.**

The write gate needs a non-null `mail.smtp.host` when the adapter is
`smtp`, and refuses `dev` in production without the file hatch.

**The new sender address does not apply.**

A pinned value wins over the file. Check the pins on the settings page, or
save the new value through the settings document.

**The reset link is expired.**

The link TTL is `iam.change_password_expiration`, 86,400 seconds by
default. Request a fresh link.

## Related

- [Configuration files](/admin/configure/configuration-files/) — where the `mail:` section lives.
- [System settings](/admin/configure/system-settings/) — the runtime tier that overrides the file.
- [In-app notifications](/use/notifications/) — the separate notification system.
- [Sessions and lockouts](/admin/people/sessions-lockouts/) — the link TTLs and the lockout rules.
- [First start and bootstrap](/admin/install/bootstrap/) — `seed:admin`, which prints its password instead of emailing it.
- Internals on GitHub: [config.md](https://github.com/wearefacet/facet/blob/main/doc/backend/config.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
