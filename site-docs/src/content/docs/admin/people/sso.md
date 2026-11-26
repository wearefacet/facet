---
type: how-to
title: Single sign-on with OIDC
description: Connect identity providers, control JIT provisioning, and switch the instance to single sign-on only.
audience: [admin, operator]
features: [IAM-08, FE-14]
sidebar:
  order: 8
verified_at: fd345fe3
---

Facet signs accounts in through external identity providers with OpenID
Connect (OIDC). The server starts an authorization-code flow, verifies the
provider's identity token, and signs the account in. You configure each
provider as a document, so every change is audited and reversible.

## When to use this

- Your organization runs an identity provider and members must sign in with
  their work accounts.
- You must decide whether unknown members get an account automatically.
- You must stop password sign-in and allow the provider only.

## Before you start

- **The right.** You need `create` and `update` rights on `iam.OIDCProvider`.
  The seeded `admin` role holds them; the `editor` role has the doctype carved
  out of its grants.
- **Provider details.** Gather from your provider: the issuer URL, the client
  id, and the client secret.
- **The redirect address.** Set it at your provider to
  `https://<your-host>/auth/oidc/<name>/callback`.

## Steps

### 1. Create the provider document

Open **Configure → Platform → OIDC** and select **New**. Fill the fields:

| Field | Holds | Rules |
| --- | --- | --- |
| `name` | The URL segment in `/auth/oidc/{name}` | Lowercase letters, digits, hyphens. Immutable after create. |
| `label` | The text on the sign-in button | Defaults to the name. |
| `issuer` | The provider's issuer URL | Must be an absolute `https` URL. Plain `http` is accepted only on a loopback host, for a development mock provider. |
| `client_id` | The OIDC client id at the provider | From your provider's client registration. |
| `client_secret` | The confidential-client secret | Stored in the secret store. The form stages it out-of-band; documents carry only a marker. Never shown again. |
| `domains` | Email-domain allowlist | Lowercase entries, for example `example.tld`. Empty means link-based sign-in only. |
| `auto_provision` | Create accounts for unknown people | When `true`, `default_role` is required. |
| `default_role` | The role for provisioned accounts | Applied at creation only. |
| `scopes` | The OIDC scopes to request | Defaults to `openid`, `email`, `profile`. |
| `enabled` | The per-provider switch | Disabled providers deny like unknown names. |

You can also create the provider through the document API:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "corp-idp",
    "label": "Company sign-in",
    "issuer": "https://idp.example.tld",
    "client_id": "facet-prod",
    "domains": ["example.tld"],
    "auto_provision": false,
    "enabled": true
  }' \
  "https://facet.localhost:3443/Api/iam/OIDCProvider"
```

The create hook validates the fields and answers `422` on a bad value. The
client secret rides a separate stage call, never the document body.

### 2. Check the sign-in page

Open the login page in a private window. Under the password form, Facet shows
one **Continue with** button per enabled provider. The button list comes from a
public read:

```sh
curl "https://facet.localhost:3443/Api/iam/oidc/providers"
```

The answer carries the authentication mode and the display names only. The
issuer, the client id, and the secret never leave the server.

### 3. Decide who gets an account

Two paths bring an unknown person in:

- **Linking.** The provider returns a verified email whose domain is in the
  allowlist, and an account with that email exists. Facet links the identity to
  that account and signs them in. The join key is the pair of provider name and
  provider-side subject, never the email, so an email change at the provider
  cannot take an account over.
- **Just-in-time provisioning (JIT).** The identity is unknown, the email is
  verified and allowlisted, and `auto_provision` is on. Facet creates the account
  with the provider's `default_role` and signs the person in. The link is stored
  on the account's `federated_identities` array.

  Service accounts never federate. A suspended or disabled account denies; the
  reason stays in the audit log.

  The local MFA check does not apply on this path. The provider is the factor of
  record; see [Enforcing MFA](/admin/people/mfa/) for the password path.

### 4. Read the audit trail

Three events land in the login-event log:

| Event | Written when |
| --- | --- |
| `oidc_provisioned` | Facet created an account through JIT. |
| `oidc_login` | An OIDC sign-in issued a session. |
| `oidc_denied` | Any denial. The details carry the machine-readable reason. |

See [Auditing activity](/admin/history/audit/) for how to read the log.
The browser always sees one generic error; the reason never reaches it.

### 5. Require single sign-on

Open **Configure → Platform → Settings**, Security chapter, and set
**Authentication mode**. The two modes:

| Mode | Behaviour |
| --- | --- |
| `hybrid` (default) | Password sign-in and provider sign-in both work. |
| `oidc_only` | The password route refuses with `403` and writes a `password_login_denied` event. The password reset and the first-credential bootstrap refuse with `422`. The login page hides the password form and the reset link. |

The write gate refuses a save that sets `oidc_only` while no enabled provider
exists, so one save cannot lock every sign-in path out.

:::caution
Under `oidc_only`, a person whose identity is not linked and whose provider is
down cannot sign in. Keep a break-glass session, or plan the recovery command
below.
:::

### 6. Recover from a lockout

When the only enabled provider is dead and no session survives, run on the
server host:

```sh
facet auth:mode hybrid
```

The command sets the mode on the settings document through the normal write
path. The policy gates read the document row directly, so every running server
applies the mode at once, without a restart.

## Troubleshooting

### The sign-in returns to the login page with a generic error

The audit log holds the reason under `oidc_denied`. Common causes: a wrong
client secret, a wrong issuer, a redirect address that does not match, or a
disabled provider.

### A person cannot sign in and no error shows

Check their account status. A suspended or disabled account denies on every
path.

### A new member gets no account

JIT needs all four conditions:

1. An unknown identity.
2. A verified email.
3. An allowlisted domain.
4. `auto_provision` on.

Check the provider document.

### The settings write refuses `oidc_only` with `422`

No enabled provider exists. Enable or create one first.

### The provider button does not show

The provider is disabled, or the login page failed to read the public provider
list. Check `GET /Api/iam/oidc/providers`.

## Related

- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — the sign-in steps from the account holder's side.
- [Manage accounts](/admin/people/accounts/) — the `federated_identities` field on the account.
- [Assigning roles and role election](/admin/people/assign-roles/) — the role a provisioned account gets.
- [Enforcing MFA](/admin/people/mfa/) — why the MFA gate does not apply on this path.
- [Auditing activity](/admin/history/audit/) — the login-event log.
- Internals on GitHub: [oidc.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oidc.md).
