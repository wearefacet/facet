---
title: Require MFA
description: Switch MFA (multi-factor authentication) on for the instance, pick the enforcement level, and handle recovery.
type: how-to
audience: [admin]
features: [IAM-03, PLT-02]
verified_at: eee55a2
sidebar:
  order: 7
---

One stolen password should not open Brightwater's client list. Ravi asks
every account for a second factor: a six-digit code from an authenticator
app. Facet calls this multi-factor authentication (MFA). He picks whether
accounts are *asked* to enroll or *must* enroll, and he keeps the recovery
path ready for the day someone loses their phone.

The factor is time-based one-time password (TOTP) as specified by RFC 6238: a
6-digit code that changes every 30 seconds. The account holds the shared
secret in an authenticator app. Each account also holds single-use backup
codes as the self-recovery path.

## When to use this

- You must require a second factor at sign-in for every account.
- You must free an account that lost its authenticator.
- You must answer why a sign-in stops at an enrollment screen.

## Before you start

- **The right page.** Runtime settings live on **Configure → Platform →
  Settings**, in the Security chapter. You need `update` rights on
  `core.SystemSettings`. The seeded `editor` and `viewer` roles have the path
  carved out of their grants, so the default posture is administrator-only.
- **The member's side.** Read [Sign in, MFA, reset your password](/use/first-day/sign-in/)
  for the account holder's side.

## The two enforcement levels

| Level | Behaviour |
| --- | --- |
| `preferred` | Facet asks each un-enrolled account to set up MFA after sign-in. The account can decline. Facet asks again at the next sign-in. |
| `always` | Facet holds every un-enrolled sign-in at the enrollment step. No session exists until the account verifies a first code. |

Under `always`, the hold has no back and no cancel. The enrollment step offers
no exit, and token refresh needs a session that does not exist yet. An
organization that wants an exit uses `preferred`.

:::caution
Switch to `always` deliberately. Every account without MFA stops at
the enrollment screen at its next sign-in, including administrators.
:::

## The two configuration tiers

| Tier | Where | Keys |
| --- | --- | --- |
| Runtime | `core.SystemSettings` | `iam.mfa.type` (`none` or `totp`), `iam.mfa.enforcement` (`preferred` or `always`) |
| File | `config.{env}.yml` | `iam.mfa.totp.enabled` (a boolean; `true` translates to type `totp`, `false` to `none`), `iam.mfa.enforcement` |

The runtime value wins when it is set. A null runtime field means "follow the
file". Every authentication decision reads the runtime document row directly,
never a cache, so a save applies at once.

Both configuration files that the server ships with carry the same section.
From `config.dev.yml`:

```yaml
iam:
  mfa:
    totp:
      enabled: true
      window: 1
      issuer: "Facet"
```

`window: 1` accepts a code from one step before or after the current one, so
a slow typing hand still works. `issuer` is the name the authenticator app
shows — on the running instance the enrollment URI reads
`otpauth://totp/Facet:tom@brightwater.example?secret=…`.

## Steps

### 1. Set the runtime policy

Open **Configure → Platform → Settings** and go to the Security chapter. Set
**MFA factor type** to `totp`, then set **MFA enforcement**. The enforcement
select shows only while the factor type is `totp`. Select **Save**.

<!-- screenshot: configure-settings-security -->

The page sends a sparse update through the standard document route:

```sh
curl -k -X PATCH -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"iam": {"mfa": {"type": "totp", "enforcement": "always"}}}' \
  "https://facet.localhost:3443/Api/core/SystemSettings/settings"
```

The write gate accepts only `none` or `totp` for the type and only
`preferred` or `always` for the enforcement. A wrong value answers `422`. The
Lua lifecycle hook refuses every create and every delete of the settings
document; only the seeded `settings` row exists.

### 2. Read the effective values

```sh
curl -k -H "Authorization: Bearer $FACET_API_KEY" \
  "https://facet.localhost:3443/Api/SystemSettings"
```

The `values` map carries the effective, non-secret values keyed by path, for
example `"iam.mfa.enforcement": "always"`. The `pinned` list names the paths
the document currently pins; a path that is absent follows the file.

### 3. Enroll accounts

Each account enrolls at sign-in:

1. The account signs in with email and password.
2. Under `always`, sign-in stops at "Set up two-factor authentication". Under
   `preferred`, Facet shows the same setup as a dismissible prompt after
   sign-in.
3. The account scans the QR code, or pastes the manual key, into an
   authenticator app. The app setup page shows an `otpauth://` URI.
4. The account types the 6-digit code and confirms.
5. Facet flips `mfa_enabled` on the account and shows 10 backup codes.

The verify call returns the backup codes once:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"code": "123456"}' \
  "https://facet.localhost:3443/Api/iam/mfa/totp/verify"
```

The answer carries `"backup_codes": [...]` and `"mfa_enabled": true`. On the
running instance the codes arrive in this shape:

```json
{"ok": true, "mfa_enabled": true, "backup_codes": ["384f-0d34", "… nine more …"]}
```

### 4. Tell accounts about the backup codes

One set holds 10 codes of 8 hexadecimal characters, shown as `xxxx-xxxx`.
Facet shows them once and stores only their SHA-256 digests. Each code works
exactly once. The MFA challenge accepts a code with `method: "backup_code"`,
so a lost authenticator is a self-recovery path. Re-enrollment mints a fresh
set.

### 5. Recover an account

When an account loses its authenticator and its backup codes, an
administrator clears its MFA:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"account_id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D"}' \
  "https://facet.localhost:3443/Api/iam/mfa/disable"
```

The route requires the `mfa_disable` permission on `iam.Account`. The seeded
`iam.Roles.admin` role holds it through `*` on `*.*`. Do not grant
`mfa_disable` to a role that an external app can elect; see
[Roles and permissions](/admin/people/roles-and-permissions/). The call clears
the stored secret, the replay counter, and the backup codes, and sets
`mfa_enabled` to `false`. The account signs in and enrolls again.

The account page shows **Reset MFA** for this recovery; it confirms before the
call and hides for a purely federated account.

## Rate limits

| Surface | Limit | Effect |
| --- | --- | --- |
| MFA verify at enrollment | 5 wrong codes per 5 minutes | The endpoint answers `429` until the window passes. |
| MFA challenge at sign-in | 5 wrong answers | The challenge is deleted and the account locks out for 5 minutes. |
| Enroll-at-login | 5 wrong codes on the token | The token dies and the account locks out. |

A success resets the counter. See
[Sessions and lockouts](/admin/people/sessions-lockouts/) for
the lockout handling.

## Troubleshooting

### Sign-in stops at the enrollment screen with no way back

The enforcement is `always` and the account is not enrolled. Finish the
setup, or an administrator switches the enforcement to `preferred`.

### The verify answers `429`

Five wrong codes were tried within 5 minutes. Wait for the window, then try
again with a fresh code.

### The settings write answers `403`

Your role cannot read or update `core.SystemSettings`. The seeded editor and
viewer roles have the path carved out; use an administrator role, or grant the
path explicitly.

### The enforcement select is gone

The pending factor type is `none`. Set the type to `totp` first; the select
appears for the save.

### A code does not work

Codes change every 30 seconds. Wait for a fresh code and enter it at once.
Check that the server clock is correct; TOTP depends on it.

## Related

- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — the account holder's enrollment and sign-in steps.
- [Manage accounts](/admin/people/accounts/) — the `mfa_enabled` field and the reset action.
- [Sessions and lockouts](/admin/people/sessions-lockouts/) — the lockout the rate limits set.
- [Retention: what is kept](/admin/history/retention/) — the lifetime of MFA challenges.
- Internals on GitHub: [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md), [system-settings.md](https://github.com/wearefacet/facet/blob/main/doc/backend/system-settings.md).
- [Security and governance](/discover/security/)
- [System settings keys](/reference/system-settings-keys/)
