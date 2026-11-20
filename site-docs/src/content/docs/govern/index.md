---
title: Govern access
description: Control who can see and change data — accounts, roles, scopes, audit, and rollback.
audience: [admin]
features: []
sidebar:
  order: 0
verified_at: fd345fe3
---

This section is for administrators. It covers accounts, roles and permission
lines, row scopes, field visibility, sign-in policies, machine access, the
audit trail, rollback, retention, and the rules for apps and the assistant.

Start with the identity pages, then the authorization pages, then the
assurance pages. Each page stands alone; the cross-links fill in the model.

## Identity

- [Manage accounts](/govern/accounts-lifecycle/) —
  the account document, the status lifecycle, first credentials, delete and
  restore.
- [Roles and permission lines](/govern/roles-permission-lines/) — the line
  grammar, the named actions, and the guard that bounds every role write.
- [Assigning roles and role election](/govern/assigning-roles-election/) — put
  roles on accounts, and how one role is elected per request.
- [Enforcing MFA](/govern/enforcing-mfa/) — the TOTP factor, the two
  enforcement levels, and recovery.
- [Single sign-on with OIDC](/govern/sso-oidc/) — provider documents, JIT
  provisioning, and single sign-on only mode.
- [Sessions, refresh tokens and lockouts](/govern/sessions-tokens-lockouts/) —
  token lifetimes, rotation, and the login throttle.
- [Machine access: API keys](/govern/api-keys/) — static keys pinned to one
  account and role.

## Authorization

- [Row scopes](/govern/row-scopes/) — narrow a permission line from whole
  doctypes to matching rows.
- [Field visibility with tags](/govern/field-visibility-tags/) — hide fields
  per role on reads, writes, and in the audit log.

## Assurance

- [Auditing activity](/govern/auditing-activity/) — read the mutation log and
  the login-event log.
- [Rolling back changes](/govern/rolling-back/) — undo to an earlier mutation,
  restore a delete, and the limits.
- [Retention](/govern/retention/) — what each data class keeps, and for how
  long.
- [Controlling app reach (grants)](/govern/app-grants/) — bound what an
  external app may attempt.
- [Governing the assistant](/govern/governing-assistant/) — availability,
  token budgets, instructions, and tool behaviour.

## Related

- [Security & governance overview](/start/security-governance/) — the evaluator summary of this model.
- [Roles, levels and the authority guard](/concepts/roles-levels-authority/) — the concept behind the guard.
