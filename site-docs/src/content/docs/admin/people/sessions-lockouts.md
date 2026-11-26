---
type: how-to
title: Sessions, refresh tokens and lockouts
description: See where sessions live, how tokens rotate, and how the login throttle and lockouts work.
audience: [admin]
features: [IAM-01, IAM-02, IAM-10, IAM-11]
sidebar:
  order: 9
verified_at: f1409cdc
---

Facet splits each sign-in into two credentials. The access token is a
short-lived signed token. The refresh token is a long-lived, opaque token that
stands for a server-side session in Redis. This page explains both, the
rotation rule, and the lockout behaviour.

## When to use this

- You must answer how long a stolen token works.
- You must free an account that is locked out.
- You review the session behaviour of the deployment.

## Explanation

### Where sessions live

A session is a hash in Redis under `session:{id}`. It holds the current and
previous refresh ids, the account id, the elected role, timestamps, the
User-Agent, the client address, and the token delivery mode. Sessions also
register in one set per account and one set per app. A full Redis loss only
forces re-login; nothing durable depends on it.

### The access token

The access token is a JSON Web Token (JWT) signed with the ES256 algorithm.
The signature algorithm is pinned; the token header never selects it, which
closes the known algorithm-confusion attacks. The default lifetime is 900
seconds, set by `iam.jwt.access_token_ttl`.

The claims on every token:

| Claim | Holds |
| --- | --- |
| `sub` | The account id. |
| `sid` | The session id. |
| `role` | The elected role id. |
| `jti` | A unique token id. |
| `typ` | The token kind, `access` for browser sessions. |

The signing key comes from the `JWT_SIGNING_KEY` environment variable, a P-256
private key in PEM form. When the variable is unset, each process generates a
temporary key and logs a warning once.

:::caution
Set `JWT_SIGNING_KEY` in production and on every multi-instance deployment. A
restart with a generated key invalidates every outstanding access token, and
separate instances cannot verify each other's tokens. Generate a key with
`openssl ecparam -name prime256v1 -genkey -noout`.
:::

### The refresh token and rotation

The refresh token is an opaque pair `session_id.refresh_id`. Every use rotates
it:

1. The presented refresh id moves to `previous`.
2. A new refresh id replaces it.
3. For a grace window of 10 seconds (`iam.jwt.refresh_grace_window`), both ids
   are accepted, so two parallel requests do not kill the session.

  A presented id that matches neither is token reuse. Facet deletes the session
  at once and writes a `refresh_reuse` event to the login-event log. The access
  token already issued stays valid to its TTL, the same rule as an explicit
  revocation.

  The session lifetime is 14 days, set by `iam.jwt.refresh_token_ttl`. Each
  successful refresh restarts the clock.

### Delivery modes

Sign-in delivers tokens as HttpOnly cookies or in the JSON body. The session
remembers the mode. A refresh with the other mode answers `422` before any
state changes: nothing rotates, the session stays.

### Session management

| Route | What it does |
| --- | --- |
| `GET /Api/iam/sessions` | Lists the caller's own sessions with ids and metadata. |
| `DELETE /Api/iam/sessions/:session_id` | Revokes one own session. Idempotent: an unknown id answers `200` with `revoked: false`. |
| `DELETE /Api/iam/sessions` | Revokes every session of the caller except the current one. |
| `DELETE /Api/iam/apps/:app_id/sessions` | Revokes every session the caller holds for one app. |

After a revocation, the live access token works until its TTL expires; the
next refresh fails because the session row is gone. Account holders manage
their own sessions in the workspace — see
[Your settings, sessions and API keys](/use/account/).

### The login throttle

The throttle keeps its state in Redis. Five counters and one flag apply. The
counters and the lockout flag are separate keys, so a counter can expire while
the lockout still holds.

| Counter | Trigger | Effect |
| --- | --- | --- |
| Password attempts per account | 10 wrong passwords | The next attempt sets the lockout flag; sign-in answers `429`. |
| Password attempts per client address | 20 wrong passwords from one address | Sign-in answers `429` while the counter is at its limit. No lockout flag. |
| MFA challenge answers | 5 wrong answers | The challenge is deleted and the lockout flag is set. |
| MFA verify at enrollment | 5 wrong codes | The endpoint answers `429`. No lockout flag. |
| MFA verify after sign-in | 5 wrong codes | The endpoint answers `429` while the counter is at its limit. No lockout flag. |

Every counter expires 300 seconds after its first increment, and a later
increment does not extend it. A success resets the password counters and the
post-sign-in MFA counter.

The lockout flag is its own key, `login_lockout:<account_id>`, with its own
300-second timer. It starts when the flag is set, not when the counter that
triggered it started. The flag is set by the account password limit and by the
MFA challenge lockout. While the flag is present, every sign-in answers `429`
before any password check, even after the counter that caused it expired.

The audit trail is deliberate: only the lockout writes a row to the login-event
log. Each failed attempt goes to the backend log instead, under
`facet.iam.login` at warn level, with the account id, the client address, and
the remaining attempts. See [Auditing activity](/admin/history/audit/) for
the event log.

## Steps

### Clear a lockout

Every key expires on its own 300 seconds after it started. To free an account
at once, delete the Redis keys on the server host.

A full clear deletes four key families:

```sh
redis-cli DEL login_lockout:<account_id> \
  pwd_attempts:<account_id> \
  pwd_attempts:ip:<address> \
  mfa_verify_attempts:<account_id>
```

Replace `<account_id>` with the account id and `<address>` with the client
address. To clear every per-address counter, scan for them:

```sh
redis-cli --scan --pattern 'pwd_attempts:ip:*' | xargs redis-cli DEL
```

A password-only clear keeps the MFA limiter intact and deletes three families:

```sh
redis-cli DEL login_lockout:<account_id> pwd_attempts:<account_id>
redis-cli DEL "pwd_attempts:ip:203.0.113.7"
```

:::caution
The per-address counter counts every wrong password from one address. A shared
office address can block many accounts at once through the per-address limit.
The limit sets no lockout flag, so the block lifts when the counter expires.
Clear the address counter, not the account flags, when one network is at
fault.
:::

### Verify the result

Sign in as the account, or ask the holder to. The sign-in succeeds and the
counters start from zero.

## Example

Revoke every session of one account from the API, as the account holder or
with their credential:

```sh
curl -k -X DELETE -H "Authorization: Bearer $FACET_API_KEY" \
  -H "X-Requested-With: XMLHttpRequest" \
  "https://facet.localhost:3443/Api/iam/sessions"
```

The answer names the count: `{"ok": true, "revoked": 3}`. Each revoked session
writes a `session_revoked` event. The current session survives the call.

## Troubleshooting

### Sign-in answers `429` immediately

The account or the client address is throttled. Wait 5 minutes, or clear the
keys as shown above.

### A device signs out by itself

Another refresh of the same session reused a stale refresh id. The session was
deleted and a `refresh_reuse` event was written. Check the login-event log and
ask the holder to sign in again.

### Tokens stop verifying after a restart

`JWT_SIGNING_KEY` is unset; each process generated its own key. Set the
variable and re-deploy. Every holder must sign in again once.

### The login-event log shows no failed attempts

That is the design. Only the lockout writes a row. Read the backend log under
`facet.iam.login` for the per-attempt record.

## Related

- [Sign in, MFA, reset your password](/use/first-day/sign-in/) — the sign-in and MFA steps.
- [Your settings, sessions and API keys](/use/account/) — the self-service session list.
- [Auditing activity](/admin/history/audit/) — the login-event log.
- [Enforcing MFA](/admin/people/mfa/) — the MFA rate limits.
- [Manage accounts](/admin/people/accounts/) — the statuses the login checks.
- Internals on GitHub: [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md).
