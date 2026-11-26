---
type: overview
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

- [Manage accounts](/admin/people/accounts/) —
  the account document, the status lifecycle, first credentials, delete and
  restore.
- [Roles and permission lines](/admin/people/roles-and-permissions/) — the line
  grammar, the named actions, and the guard that bounds every role write.
- [Assigning roles and role election](/admin/people/assign-roles/) — put
  roles on accounts, and how one role is elected per request.
- [Enforcing MFA](/admin/people/mfa/) — the TOTP factor, the two
  enforcement levels, and recovery.
- [Single sign-on with OIDC](/admin/people/sso/) — provider documents, JIT
  provisioning, and single sign-on only mode.
- [Sessions, refresh tokens and lockouts](/admin/people/sessions-lockouts/) —
  token lifetimes, rotation, and the login throttle.
- [Machine access: API keys](/admin/apps-access/api-keys/) — static keys pinned to one
  account and role.

## Authorization

- [Row scopes](/admin/people/row-scopes/) — narrow a permission line from whole
  doctypes to matching rows.
- [Field visibility with tags](/admin/people/hidden-fields/) — hide fields
  per role on reads, writes, and in the audit log.

## Assurance

- [Auditing activity](/admin/history/audit/) — read the mutation log and
  the login-event log.
- [Rolling back changes](/admin/history/roll-back/) — undo to an earlier mutation,
  restore a delete, and the limits.
- [Retention](/admin/history/retention/) — what each data class keeps, and for how
  long.
- [Controlling app reach (grants)](/admin/apps-access/app-grants/) — bound what an
  external app may attempt.
- [Governing the assistant](/admin/assistant/govern/) — availability,
  token budgets, instructions, and tool behaviour.

## Related

- [Security & governance overview](/discover/security/) — the evaluator summary of this model.
- [Roles, levels and the authority guard](/admin/people/who-can-change-roles/) — the concept behind the guard.
