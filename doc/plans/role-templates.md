# Plan — Role templates (a role as the sum of its concerns)

Status: **draft — feasibility study. Awaiting decisions (§8). No code
written.** Verified against the tree on 2026-11-18. This plan extends
[`../backend/rbac.md`](../backend/rbac.md) (role documents, role
authority, authoring validation) and
[`../frontend/access-roles.md`](../frontend/access-roles.md) (the roles
admin surface).

---

## 1. Summary

Setting up a role takes many manual steps. The operator builds every
permission line by hand in the grants editor. Roles that share a concern
repeat the same lines. A role that gathers many concerns holds a long
matrix that is hard to review and hard to justify in an audit.

This plan adds **role templates**. A template is a named, reusable bundle
of rights:

- permission lines (the same grammar roles use today),
- `visible_tags` (field visibility),
- `connectivity` (programmatic doors).

An operator composes a role from one or more templates. The editor merges
the templates, the operator reviews the merge and adds role-specific
lines, and the role stores the result. The role also stores
`template_refs` — the names of the templates that compose it.

The motivation is compliance. A role is often the sum of concerns. With
templates:

- A role reads as "HR officer = `hr_core` + `time_tracking` +
  `self_service`".
- Each template documents one concern and its justification.
- A drift check warns when a role no longer matches the merge of its
  declared templates.
- A template edit propagates nothing. A wider template reaches a role
  only through an explicit, audited role write.

The study finds no architectural blocker. Enforcement never sees a
template. The system keeps the key invariant — one active role per
request, roles never merge. Composition happens at authoring time only.

## 2. Current state

| Concern | Today | Where |
|---|---|---|
| Role document | `iam.Roles`, aggregate root `iam.Roles.<name>`; `name` immutable after creation | `data/seeds/iam.Roles/`, `doc/backend/rbac.md` → Role documents |
| Role content | `name`, `level` (0–100), `description`, `permissions`, `visible_tags`, `connectivity`, `assistant_token_budget` | `data/seeds/iam.Roles/definition.yml` |
| Permission grammar | `{action, on, scope[], except[]}` lines; enforcement ORs the matching lines of the one active role | `src/rbac/permission.cr` |
| Creation dialog | name, level, description; the new role starts browser-only and empty of grants | `NewRoleDialog.svelte` |
| Grants editor | permission matrix over the doctype tree; writes only `permissions`; role powers (connectivity, budget) are read-only there | `RbacEditor.svelte`, `rbacModel.ts` |
| Role authority | caller level ceiling, target protection, `implied_by?` containment per line, `KNOWN_ROLE_FIELDS` closed list | `src/rbac/role_authority.cr` |
| Authoring validation | `Validator.validate_permissions` on `iam.Roles` writes; `scoped_create_warnings` lint on `Domain::Check` (`:rbac`) | `src/rbac/validator.cr`, `src/domain/check.cr` |
| Compliance trace | the role `description` text plus the mutation log. Nothing links two roles that share a concern | — |

The pain: repetition across roles, no shared concern vocabulary, high
review cost per role, and a thin audit story for "why does this role
hold this right?".

## 3. What a template changes

A **template** is a document of a new seed doctype, `iam.RoleTemplate`.
It carries one concern, for example "read-only audit access" or "HR
records clerk". Its content holds the rights that the concern grants.

A **role** composes templates. At authoring time the editor merges the
selected templates into one permission map. The operator reviews the
merge, adds extra lines the templates do not cover, sets the level, and
saves. The stored role content holds the materialized rights plus
`template_refs`.

Life cycle:

1. An operator authors templates. One concern per template, with a
   description that states the concern and its justification.
2. An operator creates or edits a role from templates. The editor shows
   the merged matrix with the origin of each line.
3. The role stores the merged rights and the `template_refs` list.
4. A later template edit changes no role. The drift check warns on the
   next `Domain::Check` run, and the roles page shows a drift badge. An
   operator re-applies the merge in the editor and saves. That save is a
   normal, audited `iam.Roles` write.

The separation of intent and truth: `template_refs` states the intent
("this role is the sum of these concerns"). `permissions` states the
truth (what enforcement applies). Drift is the distance between them.

## 4. Design

### 4.1 Storage — `iam.RoleTemplate`

New seed folder `data/seeds/iam.RoleTemplate/` with `definition.yml` and
a `script.lua` hook. The doctype is an aggregate root: the id is
`iam.RoleTemplate.<name>`, and the Lua hook refuses a PATCH that carries
`name` — the same rule `iam.Roles` applies.

| Field | Type | Rules |
|---|---|---|
| `name` | string | required, unique, pattern `^[a-z][a-z0-9_]*$`, immutable |
| `description` | longtext | required. States the concern and its justification — the compliance text |
| `permissions` | array of object | same line shape as `iam.Roles.permissions` |
| `visible_tags` | array of string | default `["default"]` |
| `connectivity` | array of string | default `[]`, closed vocabulary `mcp` / `webhook` / `api` / `assistant` |

A template carries no `level` and no `assistant_token_budget`. The level
is a property of the role that carries the concern, not of the concern
itself. The budget pairs with the assistant channel at role level; a
merge of budgets has no clean answer. A template also carries no account
links: only `iam.Roles` documents enter an account's `roles` array, so a
template is structurally unassignable.

`display_name` is `{{ name }}`; `search` is `{{ name }} {{ description }}`.

Example template content:

```json
{
  "name": "hr_core",
  "description": "HR records clerk: read and update employee files, no delete.",
  "permissions": [
    {"action": "read",   "on": "hr.Employee"},
    {"action": "update", "on": "hr.Employee", "scope": ["$active"]}
  ],
  "visible_tags": ["default", "hr"],
  "connectivity": []
}
```

### 4.2 Merge semantics

The merge is a pure function over the selected templates:

- `permissions` — concatenate the lines of all templates, in the order
  the operator lists the templates, and remove exact duplicates (same
  `action`, `on`, `scope`, and `except`).
- `visible_tags` — set union.
- `connectivity` — set union.

No conflict resolution exists, and none is needed. Enforcement already
ORs the matching lines of one role, so two lines with the same `action`
and `on` but different scopes hold their union semantics inside one role
today. The merge produces exactly that shape. `except` exclusions
compose the same way they compose inside one role today: a blanket line
with an exclusion, next to a scoped re-grant on the excluded path, stays
meaningful.

Example — `hr_officer` = `hr_core` + `time_tracking` + `self_service`:

```json
{
  "name": "hr_officer",
  "level": 40,
  "template_refs": ["hr_core", "time_tracking", "self_service"],
  "permissions": [
    {"action": "read",   "on": "hr.Employee"},
    {"action": "update", "on": "hr.Employee", "scope": ["$active"]},
    {"action": "read",   "on": "hr.Timesheet", "scope": ["$mine"]}
  ],
  "visible_tags": ["default", "hr"],
  "connectivity": []
}
```

### 4.3 The role content change

`iam.Roles` gains one field:

| Field | Type | Rules |
|---|---|---|
| `template_refs` | array of string | default `[]`. Names of live `iam.RoleTemplate` documents |

Backend changes for the new field:

- `KNOWN_ROLE_FIELDS` in `src/rbac/role_authority.cr` gains
  `template_refs`. Without it, every role write that carries the field
  is denied ("not a recognized role field"). It does not join
  `SAFE_ROLE_FIELDS`: the origin list deserves a deliberate write, not a
  free one.
- A role create or update that carries an unknown ref answers `422`
  (`unknown_template`). A deleted template leaves the stored refs as
  they are; the drift check reports the broken reference (§4.6).
- No other change. The role write validates and stores the submitted
  `permissions` exactly as today. The server never merges.

The roles page maps the field onto its existing structure: the Details
tab (the single write surface for role powers) gains the template list;
the Grants tab keeps writing `permissions` only.

### 4.4 Where the merge runs

Two small, pure implementations, each with specs:

| Site | Role |
|---|---|
| `rbacModel.ts` — `mergeTemplateContents()` | Authoring. Fills the editor matrix with the merge, tags each line with its origin, powers the live preview and the drift badge |
| `src/rbac/template_drift.cr` — `RBAC::TemplateDrift` | Control. The `Domain::Check` drift warnings (§4.6), computed server-side from stored content |

No merge route exists. The server stores what a role write submits; the
drift check compares stored content, so an editor bug or a hand-written
API call cannot widen rights without producing a visible warning.

Rejected alternative: a server-side materialization route
(`POST .../merge`). It fights the PATCH semantics of `Document::Update`
(absent key — "no extras" or "keep current"?), adds a non-REST surface,
and duplicates the preview the editor needs anyway.

### 4.5 Authority

Template writes join the one transition API.
`RoleAuthority.authorize_transition` (`src/rbac/role_authority.cr`)
covers `iam.RoleTemplate` writes with a reduced rule set:

- **Caller level ceiling** — the caller's elected role level bounds the
  write, as for roles.
- **Per-line implication** — every permission line in the resulting
  template must be implied by a line of the caller's role
  (`Permission#implied_by?`), as for roles. A caller cannot author a
  template with rights it does not hold.
- **Containment of tags and channels** — new `visible_tags` sit inside
  the caller's tags; new connectivity channels sit inside the caller's
  channels.
- **No target protection, no assignment rules** — a template has no
  `level` and no holders. A template grants nothing by itself; only a
  role grants. Deletion of a referenced template is allowed and warned
  (§4.6).

Role writes stay exactly as today. The materialized lines of a composed
role pass the same `implied_by?` gate as hand-written lines. So
re-applying a widened template demands a caller whose role implies the
new lines — authority discipline survives composition.

The app-facing rule stays textual, as today: a role that an external app
can elect must not hold `provision_credentials`, `mfa_disable`, or the
three operator actions. A composed role obeys it like any other role.

### 4.6 Validation and drift warnings

- `Validator.validate_permissions` (`src/rbac/validator.cr`) also runs
  for `iam.RoleTemplate` writes. Same checks: path format, wildcard
  rules, named-scope aliases resolve against the leaf doctype, `except`
  parse errors.
- The role write gains the `unknown_template` ref check (§4.3).
- New module `RBAC::TemplateDrift` (`src/rbac/template_drift.cr`):
  `merge(templates)` and `diff(role_content, templates)`.
- `Domain::Check` (`src/domain/check.cr`) gains a sibling of
  `check_role_permissions`: `check_role_template_drift`. It scans the
  live `iam.Roles` documents that hold a non-empty `template_refs`, and
  emits advisory `:rbac` warnings:

| Warning | Meaning |
|---|---|
| `unknown_template` | A ref names no live template |
| `missing_template_lines` | The merge holds lines the role does not store (the template moved ahead) |
| `extra_lines` | The role stores lines the merge does not hold (hand-written extras) |
| `tags_differ` | The role `visible_tags` differ from the merge |
| `connectivity_differ` | The role `connectivity` differs from the merge |

The warnings never block a write and never change enforcement.
`extra_lines` is normal (extras are a feature); its warning keeps the
difference visible so the refs list stays an honest map.

The roles page computes the same diff in TypeScript for the drift badge
and the per-line origin display (§4.8).

### 4.7 HTTP surface

No new routes and no new services. Templates are documents of a seed
doctype: the standard REST surface applies.

| Verb | Path | Authorization |
|---|---|---|
| `GET` / `POST` / `PATCH` / `DELETE` | `/Api/iam/RoleTemplate/…` | standard `iam.RoleTemplate` grants, plus the `RoleAuthority` rules of §4.5 on writes |

### 4.8 Frontend

All changes sit in the existing admin feature
(`frontend/src/lib/components/features/admin/`):

| Surface | Change |
|---|---|
| `/Configure/access/templates` (new page) | Template list (name, description, line count, "used by N roles" computed from role contents) + create/edit through the shared editor in template mode |
| `RbacEditor.svelte` | A `mode: "role" \| "template"` prop. Template mode hides level and budget, marks `description` required, and writes `iam.RoleTemplate` |
| `NewRoleDialog.svelte` | A template picker (multi-select with name, description, line counts). The selected templates pre-fill the grants matrix through `mergeTemplateContents()`; the operator adds extras and saves — one audited create |
| Roles page — Grants tab | A template origin strip: ref chips, a drift badge (`in sync` / `+2 −1`), and a "Re-apply templates" action that re-merges into the matrix for review and save |
| Roles page — Details tab | The `template_refs` list joins the role powers form |
| `rbacModel.ts` | `mergeTemplateContents()` (union with origins), `driftDiff()` (the §4.6 table, computed client-side), specs in `rbacModel.spec.ts` |

Per-line origin: the merge tags each matrix row with the template that
contributed it (`hr_core`, or `hand` for extras). The reviewer sees the
concern behind every line.

### 4.9 What stays untouched

- Enforcement: `ReadEnforcer`, `WriteEnforcer`, the metadata gate, scope
  expansion, field visibility.
- `IAM::RoleStore` and the `fanout:iam.Roles:*` cache eviction.
- Account assignment (`RoleAssignmentEditor`, the `RoleAuthority`
  assignment rules), login, JWT claims.
- The permission grammar and the `Permission#implied_by?` arithmetic.
- Audit, rollback, replication, webhooks.

## 5. The compliance story

This feature exists for the audit narrative:

| Audit question | Answer source |
|---|---|
| Why does this role hold right X? | The line's origin template, and that template's `description` |
| What is this role made of? | `template_refs` — the named concerns |
| Who approved the composition? | The `iam.Roles` mutation that materialized it (actor, time, `reason`) |
| Who changed a concern? | The `iam.RoleTemplate` mutations |
| Is every role still the sum of its concerns? | `Domain::Check` drift warnings + the drift badge |
| What would a template edit change? | Nothing, until a role write re-applies it |

No silent path exists from a template edit to a role's effective rights.
Every widening lands as an explicit, audited role write — the property
that makes the materialized model compliance-friendly.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Template sprawl — dozens of one-line templates | Guidance: one concern per template; required `description`; the "used by" count shows dead templates |
| A dangerous action enters many roles through one template | The app-facing rule stays textual; a composed role obeys it like any role. The per-line origin makes the spread visible at review time |
| Dual merge implementations drift apart | Both are pure, small, and spec'd against the same fixtures; the server-side check compares stored truth, so a divergence surfaces as a false warning, never as a silent widening |
| Drift fatigue — teams ignore warnings | Warnings stay advisory; the badge separates "extras" (normal) from "template moved ahead" (action needed) |
| A referenced template is deleted | Allowed; roles keep their materialized rights; the `unknown_template` warning marks the broken origin; the usage count warns before deletion |

## 7. Scope

| Slice | Work |
|---|---|
| Backend | `iam.RoleTemplate` seed (definition + Lua hook), `KNOWN_ROLE_FIELDS` + ref validation, `Validator` dispatch, `RoleAuthority` extension, `RBAC::TemplateDrift` + `Domain::Check` warnings, specs |
| Frontend | Templates page, `RbacEditor` template mode, `NewRoleDialog` picker, origin strip + drift badge + re-apply, Details-tab refs, `rbacModel.ts` merge/diff + specs, stories |

## 8. Discuss-first decisions

1. **Composition model.** Materialize at save, keep `template_refs` as
   origin, warn on drift (proposal). The alternative — live references
   resolved at role load — changes enforcement, the role cache, and the
   authority baselines, and lets one template edit widen many roles in
   one step with no per-role audit event. Rejected.
2. **Storage.** A new seed doctype `iam.RoleTemplate` (proposal), not an
   `is_template` flag on `iam.Roles`. A separate doctype is structurally
   unassignable to accounts, keeps role loading free of special cases,
   and gives templates their own list and grants.
3. **Template payload.** `permissions` + `visible_tags` +
   `connectivity`, with `description` required (proposal). No `level`
   (a role property), no `assistant_token_budget` (it pairs with the
   channel at role level; a merge of budgets has no clean answer).
4. **Merge semantics.** Union of lines with exact-duplicate removal, set
   union for tags and channels, no conflict resolution (proposal) —
   enforcement ORs lines inside one role already.
5. **Authority.** `RoleAuthority` covers template writes with the
   reduced rule set of §4.5 (proposal). No target protection for
   templates in this pass — a template grants nothing by itself, and
   content changes already demand implication.
6. **Drift handling.** Warnings only: `Domain::Check` + page badge, no
   enforcement, no auto-propagation (proposal). Deleting a referenced
   template stays allowed, with the `unknown_template` warning.
7. **Merge site.** Editor-side merge for authoring,
   `RBAC::TemplateDrift` for the server-side control, no merge route
   (proposal). The alternative — one server-side merge route that the
   editor calls — keeps a single implementation but adds a non-REST
   surface and fights PATCH semantics (§4.4).

## 9. Phases

1. **Backend foundation.** `iam.RoleTemplate` seed (definition + hook),
   `KNOWN_ROLE_FIELDS` + ref validation, `Validator` dispatch, the
   `RoleAuthority` extension. Specs: `spec/rbac/validator_spec.cr`,
   `spec/rbac/role_authority_transition_spec.cr`. `make check` green.
2. **Backend drift.** `RBAC::TemplateDrift` (merge + diff) and the
   `Domain::Check` warnings. Spec: `spec/rbac/template_drift_spec.cr`.
3. **Frontend editor.** `rbacModel.ts` merge/diff + specs; `RbacEditor`
   template mode; the templates page. Stories with play functions.
4. **Frontend composition.** `NewRoleDialog` picker + merged preview;
   origin strip, drift badge, re-apply; Details-tab refs. Stories and
   `rbacModel.spec.ts` extensions.
5. **Finalize.** `make test` (test database up first), `bin/ameba`,
   `pnpm check`. Docs: a "Role templates" section in
   [`../backend/rbac.md`](../backend/rbac.md), an update to
   [`../frontend/access-roles.md`](../frontend/access-roles.md), and the
   [`../project-structure.md`](../project-structure.md) index rows. Then
   retire this plan into them.

## 10. Verification gates

- Isolated specs during development: `crystal spec spec/rbac/<file>`
  (one file or one example), Vitest for `rbacModel.spec.ts`, story play
  functions for the new surfaces.
- `make check` after each backend phase.
- `make test`, `bin/ameba`, `pnpm check` once at finalization.

## 11. What this plan will not do

- **Live propagation.** A template edit never changes a role without an
  explicit role write.
- **Template versioning.** Templates keep last-write-wins content; the
  drift check is the change detector.
- **Server-stored per-line origin.** Only role-level `template_refs` is
  stored; per-line origin is a review-time computation.
- **Starter template seeds.** The feature ships with the doctype, no
  seeded template documents.
- **Grammar or enforcement changes.** A template line is a normal
  permission line. Enforcement, assignment, and the role cache stay as
  they are.
- **Nested templates.** A template references no other template.
