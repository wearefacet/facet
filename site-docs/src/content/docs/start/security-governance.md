---
title: Security & governance overview
description: See how Facet protects identity, access, audit, secrets, and where your data lives.
audience: [evaluator]
features: [IAM-*, RBC-*, AUD-*, DOC-09]
sidebar:
  order: 4
verified_at: f1409cdc
---

Use this page for a security review or an audit. It summarizes the governance
model: identity, permissions, non-disclosing reads, audit, secrets, and data
location.

## Identity

- **Accounts are documents.** An account is an `iam.Account` document, and
  account changes are audited like every other change.
- **Sign-in options:** password, TOTP MFA (time-based one-time passwords, with
  single-use backup codes), SSO through OIDC, and static API keys.
- **Lockout on repeated failure.** Repeated failed sign-ins lock the account.
  The throttle counts password, per-IP, and MFA attempts.
- **Server-side sessions.** Sessions live server-side in Redis. Refresh tokens
  rotate on every use. Reuse of an old token kills the session and lands in
  the login-event log.
- **Signed tokens.** Access tokens are signed JWTs with a pinned signature
  algorithm (ES256).
- **A login log.** Every authentication event — sign-in, sign-out, denial,
  refresh — lands in an append-only login-event log.

## Permissions

Roles are documents (`iam.Roles`). Each role carries a level from 0 to 100 and
a list of permission lines. A permission line has this shape:

```json
{
  "action": "read",
  "on": "production.Project",
  "scope": ["$mine", "$global"]
}
```

- `action` — `read`, `create`, `update`, `delete`, `*`, or a named action.
- `on` — a doctype path such as `production.Project`. Wildcards exist for
  admin roles.
- `scope` — named row predicates that the doctype declares (`$mine`,
  `$global`, or one of your own). A list grants rows that match any of them.
- `except` — paths subtracted from the line. Optional: a line without it
  reaches every path its `on` matches.

The enforcers apply these rules in the data layer — in PostgreSQL, not in
your app:

- **One role per request.** One elected role per request. Roles never merge.
- **Scopes become SQL.** Row scopes compile to SQL. A list returns only the
  rows the role can see.
- **Field tags.** Field tags hide invisible fields on reads and refuse writes
  into them.
- **No power above your own.** Role authority rules: a caller cannot assign a
  role above its own level, cannot edit an account above its own level, and
  cannot widen a role beyond its own powers.
- **Apps fail closed.** Apps act under their grant and the elected role at the
  same time. The check fails closed.
- **Anonymous fails closed.** Requests with no credential run under one
  editable role, `anonymous`. Its read grants are the whole public surface.
  Delete the role, and such requests answer `401` — fail closed.

## Non-disclosing reads

Access control must not leak which documents exist:

- A denied single read answers the same `404` as a missing document.
- A denied list runs with an always-false predicate. The caller gets `200`
  with zero rows.
- A child read first checks the parent's read gate. A denial is the same
  non-disclosing `404`.

## Audit

- **Every write is recorded.** The mutation log records every create, update,
  delete, and snapshot: the actor, the channel (session, OAuth app, API key,
  MCP), the app, the change, the time, and the cause chain.
- **History per document, or across the organization.** Read history per
  document. With wildcard read rights, list changes across the whole
  organization in one call.
- **Redaction.** Audit responses mark the content paths they removed for the
  calling principal in a `redacted` metadata block. Sensitive arguments stay
  hidden from callers without the rights to see them.
- **Rollback.** Roll a document back to any prior state. A rollback to a
  delete restores the document. Deleted documents can also be restored
  directly.
- **A bounded log.** The log compacts after the retention window (180 days by
  default). Rollback depth equals that window.

## Secrets and write-only fields

- **Secrets stay out of documents.** A `secret` field keeps values out of
  documents and out of the mutation log. The client stages a value with a
  one-time handle. The write stores a marker. The value is hashed (bcrypt for
  passwords) or encrypted (AES-256-GCM) in a separate table.
- **No read path returns a secret.** No read path — HTTP, MCP, Lua scripts,
  export, copy — can return a secret value. Consumers verify or reveal it
  server-side only.
- **Write-only fields.** A `write_only` field accepts input and lets scripts
  read it. Facet strips it before it stores the document. It never appears in
  reads or in history.

## Where your data lives

- **On your servers.** Facet is self-hosted software. You run the servers. The
  data stays in your PostgreSQL, your Redis, and your object storage (files
  and attachments).
- **One config file per environment.** Configuration is one YAML file per
  environment. Secret values can come from environment variables instead of
  the file.
- **UTC timestamps.** Timestamps are stored in UTC.

:::tip
Bring this page to the security review. Each section maps to a concern
document in the repository, so your auditor can read the implementation
contract, not a summary.
:::

## Related

- [Architecture at a glance](/start/architecture/) — where enforcement sits in the request path.
- [Govern access](/govern/) — admin how-tos for accounts, roles, and SSO.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md), [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md), [secrets.md](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md).
