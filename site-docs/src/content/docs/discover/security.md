---
title: Security and governance
description: How Facet protects identity, access, history, secrets, and where your data lives.
type: explanation
audience: [evaluator, admin]
features: [IAM-*, RBC-*, AUD-*, DOC-09]
verified_at: eee55a2
sidebar:
  order: 5
---

You are the person who has to answer the security questionnaire. This page
gives you Facet's answers as short claims: identity, access, history,
secrets, and where the data lives. Each claim links the page that shows it in
practice. One thing to know up front: Facet holds no security certifications,
and this page makes no compliance promises. What you can verify is what the
product does.

## Identity

- **One account per person.** Administrators create accounts or invite people
  by email. There is no public sign-up. See [Manage
  accounts](/admin/people/accounts/).
- **Sign-in options:** password, MFA with an authenticator app and single-use
  backup codes, single sign-on through OIDC, and API keys for programs. See
  [Require MFA](/admin/people/mfa/) and [Single sign-on
  (OIDC)](/admin/people/sso/).
- **You can require MFA** for the accounts you choose.
- **Lockouts are automatic.** Ten failed password attempts from one account
  lock it, twenty from one address do the same, and MFA attempts count
  separately. See [Sessions and lockouts](/admin/people/sessions-lockouts/).
- **Sessions live server-side, in Redis.** A refresh token works once; reusing
  an old one kills the session and is recorded.
- **Access tokens are signed JWTs** with one pinned signing algorithm
  (ES256).
- **A login-event log** records sign-ins, sign-outs, lockouts, and security
  changes such as password and key changes. Denials by apps and by SSO are
  recorded too.

## Access

- **Rules attach to roles.** Each role carries permission lines. A line names
  an action, a record type, and which rows:

  ```json
  {
    "action": "read",
    "on": "clients.Company",
    "scope": ["$my_clients"]
  }
  ```

  See [Roles and permissions](/admin/people/roles-and-permissions/).
- **Rows:** a scope filters which records a role reaches — in lists, search,
  the API, apps, and what the assistant can touch. See [Show each role only
  its own rows](/admin/people/row-scopes/).
- **Fields:** a tag hides a field on read and refuses writes into it. See
  [Hide a field from some roles](/admin/people/hidden-fields/).
- **One role at a time.** Every request acts under exactly one role; roles
  never merge. This keeps the history exact: it shows who did it, and as
  which role. See [Assign roles](/admin/people/assign-roles/).
- **No power above your own.** Nobody can assign a role above their own
  level, edit an account above it, or widen a role beyond their own powers.
  See [Who can change roles](/admin/people/who-can-change-roles/).
- **Apps fail closed.** An app's reach is the overlap of what the signed-in
  user and the app are each allowed. Either side says no, the answer is no.
  See [Control what apps can reach](/admin/apps-access/app-grants/).
- **Unauthenticated calls are near-powerless.** They run under one editable
  `anonymous` role with almost no rights by default. Delete the role, and
  unauthenticated calls answer `401`.

## History

- **Every change is recorded**: who made it, when, through which app. This
  covers normal edits, automation, and the assistant's changes. See [See who
  did what](/admin/history/audit/).
- **Redaction.** Audit answers mark what they hid from the caller; sensitive
  values stay hidden from anyone without the rights to see them.
- **Rollback.** A document can go back to an earlier state. A rollback can
  also restore a deleted document. See [Roll back a
  change](/admin/history/roll-back/).
- **The log is bounded, by your choice.** You set how long the full history
  is kept — 180 days by default. Older history folds into snapshots, and
  rollback reaches as far back as the window goes. See [Retention: what is
  kept](/admin/history/retention/).

## Secrets

- **A field marked secret never sits in the document or in the history.** The
  client stages the value once; Facet stores it separately, hashed (bcrypt
  for passwords) or encrypted (AES-256-GCM). See [Secret and write-only
  fields](/build/model/data/secret-fields/).
- **No read path returns a secret value** — not HTTP, not scripts, not
  exports, not copies. Consumers verify or reveal it server-side only.
- **Write-only fields** accept input and are never stored with the document,
  so they never appear in reads or in history.

## Where your data lives

- **In your PostgreSQL and your file store, wherever you run Facet.** Nothing
  leaves unless you send it. Files sit on local disk or S3-compatible storage
  that you configure. See [File storage](/admin/configure/file-storage/).
- **One config file per environment.** Secret values can come from
  environment variables instead of the file. See [Configuration
  files](/admin/configure/configuration-files/).
- **Timestamps are stored in UTC.**

## Running it yourself

Facet is self-hosted software: you run the servers. The shipped container
stack is five services — PostgreSQL, Redis, the backend, the frontend, and a
TLS edge — and a source deployment works too. See [Run with
containers](/admin/install/containers/) and [Deploy to
production](/admin/install/production/).

:::tip
Bring this page to the security review. Each claim links the page that shows
the practice, and the engineering contracts behind them live in the
repository under `doc/backend/` — your auditor can read
[rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md),
[iam.md](https://github.com/wearefacet/facet/blob/main/doc/backend/iam.md),
[audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md),
and
[secrets.md](https://github.com/wearefacet/facet/blob/main/doc/backend/secrets.md).
:::

## Related

- [The big picture](/discover/how-it-works/) — where the checks sit in the
  request path.
- [Roles and permissions](/admin/people/roles-and-permissions/) — the access
  model in practice.
- [See who did what](/admin/history/audit/) — the audit trail day to day.
- [Licensing and services](/discover/licensing-and-services/) — the licence
  behind the source links above.
