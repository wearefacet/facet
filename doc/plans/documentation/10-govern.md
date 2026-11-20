# WP 10 — Govern access section (`/govern/`)

Phase 1 (whole-doc §7) · Depends on: WP 01 · Write scope: `site-docs/src/content/docs/govern/` only.

Source: [`whole-doc.md`](whole-doc.md) §3.6. Audience: org admins. This is the section a sceptical CTO or auditor reads (whole-doc §1 goal 2): state what is enforced, where it is enforced, and what is logged.

Split into two batches.

## Batch A — identity (7 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `govern/accounts-lifecycle.md` | Accounts: invite, suspend, delete, restore | `audience: [admin]`, `features: [IAM-06, IAM-07, FE-11]` | `doc/backend/iam.md`, `doc/frontend/access-accounts.md` |
| `govern/roles-permission-lines.md` | Roles and permission lines | `audience: [admin, author]`, `features: [RBC-01, RBC-07]` | `doc/backend/rbac.md` |
| `govern/assigning-roles-election.md` | Assigning roles and role election | `audience: [admin]`, `features: [RBC-02]` | `doc/backend/rbac.md`, `doc/frontend/access-assignments.md` |
| `govern/enforcing-mfa.md` | Enforcing MFA | `audience: [admin]`, `features: [IAM-03, PLT-02]` | `doc/backend/iam.md`, `doc/backend/system-settings.md` |
| `govern/sso-oidc.md` | Single sign-on with OIDC | `audience: [admin, operator]`, `features: [IAM-08, FE-14]` | `doc/backend/oidc.md` |
| `govern/sessions-tokens-lockouts.md` | Sessions, refresh tokens and lockouts | `audience: [admin]`, `features: [IAM-01, IAM-02, IAM-10, IAM-11]` | `doc/backend/iam.md` |
| `govern/api-keys.md` | Machine access: API keys | `audience: [admin, developer]`, `features: [IAM-09]` | `doc/backend/iam.md` |

## Batch B — authorization, audit, assistant governance (7 pages)

| File | Title | Front-matter | Sources |
|---|---|---|---|
| `govern/row-scopes.md` | Row scopes (`$self`, `$mine`, named scopes) | `audience: [admin, author]`, `features: [RBC-05, DOM-12]` | `doc/backend/rbac.md` |
| `govern/field-visibility-tags.md` | Field visibility with tags | `audience: [admin, author]`, `features: [RBC-04, AUD-03]` | `doc/backend/rbac.md`, `doc/backend/audit.md` |
| `govern/auditing-activity.md` | Auditing activity | `audience: [admin]`, `features: [AUD-02, AUD-08, IAM-13, FE-16]` | `doc/backend/audit.md`, `doc/frontend/audit.md` |
| `govern/rolling-back.md` | Rolling back changes | `audience: [admin]`, `features: [AUD-04]` | `doc/backend/audit.md`, `doc/backend/mutation.md` — include the delete-restore rule and the retention window limit |
| `govern/retention.md` | Retention: what is kept and for how long | `audience: [admin, evaluator]`, `features: [AUD-05, AUD-06, AUD-07]` | `doc/backend/audit.md`, `doc/backend/mutation.md` (compaction, coalescing), `doc/backend/event.md` |
| `govern/app-grants.md` | Controlling app reach (grants) | `audience: [admin]`, `features: [RBC-08, FE-12]` | `doc/backend/app-system.md` |
| `govern/governing-assistant.md` | Governing the assistant (availability, auto-execute, custom instructions) | `audience: [admin]`, `features: [AI-08, AI-07]` | `doc/backend/assistant.md`, `doc/backend/system-settings.md` |

`govern/index.md` (from WP 01): the batch that runs last finishes the index.

## Writing notes

- Permission-line examples: full lines, with the effect stated ("this line lets a Sales member read invoices in scope `region-eu`").
- `rolling-back.md` states the limits exactly: rollback depth equals the retention window; older mutations are `404`; a delete with no preceding mutation has nothing to restore (`422`).
- `retention.md` is an evaluator page: a table of data classes (documents, mutations, events, tombstones, sessions, files) with what is kept and for how long.
- Terminology: `account` is the identity, `user` is the human (`doc/backend/iam.md` → Terminology; repo `AGENTS.md`).

## Definition of done (per batch)

- [ ] Batch pages written, front-matter per WP 00.
- [ ] Every permission line and scope example validated against the RBAC docs (and a dev instance where possible).
- [ ] `cd site-docs && npm run build` passes.
