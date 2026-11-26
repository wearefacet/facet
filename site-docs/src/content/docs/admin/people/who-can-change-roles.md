---
type: explanation
title: Roles, levels and the authority guard
description: Control who may edit roles and accounts, and stop callers from raising their own authority.
audience: [admin, author]
features: [RBC-01, RBC-07]
sidebar:
  order: 6
verified_at: 7a6cb462
---

A role in Facet is a normal document in the `iam.Roles` doctype. You edit it
like any other record. One guard bounds this power. It decides who may change
identities and roles, and by how much.

## Explanation

<!-- d2
caller: "Caller elects one role" {class: external}
write: "Write to iam.Account or iam.Roles"
guard: "Authority guard reads the level of the elected role" {class: decision}
denied: "Denied with 403" {class: danger}
applied: "Write applies" {class: ok}

caller -> write
write -> guard
guard -> denied: level too low
guard -> applied: all checks pass
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/c49d8076-light.svg" alt="Caller elects one role" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/c49d8076-dark.svg" alt="Caller elects one role" loading="lazy" />
</div>

A role bundles permission lines. A line on a parent doctype also covers its
child doctypes. The table shows the parts of one line.

| Part | Holds |
| --- | --- |
| `action` | `read`, `create`, `update`, `delete`, `*`, or a named action such as `promote` |
| `on` | a doctype path, such as `production.Project` |
| `scope` | optional named row scopes on the doctype, combined with OR |
| `except` | optional doctype paths subtracted from the reach |

Next to its lines, a role carries `visible_tags`. A field is visible only when
all its tags sit in that list. The role also carries a level from 0 to 100.
The level is required, and it orders roles by authority.

**Level orders roles.** A request runs under exactly one elected role. Roles
never merge. The guard reads the level of the elected role, not the highest
role the caller holds.

### What the guard covers

Every caller-controlled write on `iam.Account` and `iam.Roles` passes through
one guard. It covers document create, update, and delete, named actions, and
rollback transitions. It runs after validation. Route-level authorization
skips do not bypass it. A refused write answers `403` with details. Only
internal system calls bypass it.

| Check | Rule |
| --- | --- |
| Caller level | Read from the elected role's `level`. A missing or malformed level denies the write. |
| Account assignment | Every role in the final `roles` array must exist, be live, and sit at or below the caller level. `default_role` must be a member of `roles`. |
| Target protection | No write to an account with a higher role ceiling, or to a role with a higher level. |
| Role authoring | The resulting level must not exceed the caller level. Every resulting permission line must be implied by the previous role or the caller's role. New visible tags must sit inside the union of both. |

The containment also covers the other power fields of a role. A write may not
push the connectivity channels or the assistant budget past what one baseline
role implies. A write that adds an unknown power field is denied.

**Same level is enough for assignment.** A caller may assign an existing role
at its own level, even when that role holds permissions the caller lacks. But a
caller cannot create a role above its own level. And a caller cannot widen a
role past what the previous role or its own role implies. Those changes need
an admin at a higher level.

:::caution
A narrowing-only change is still a write. A level-90 caller cannot edit an
account whose ceiling is 100, not even to remove roles from it. Target
protection blocks the change first.
:::

**The trade-off.** The guard stops a caller from raising their own authority.
The cost is friction. Lowering a high account or widening a role needs an
admin at a higher level. Roles also do not nest or inherit. The level orders
roles; it does not cascade rights. Each role lists its own permissions in
full.

## Related

- [Govern](/admin/) — edit roles and accounts day to day.
- [Authorization enforcement](/admin/under-the-hood/how-access-is-enforced/) — how permission lines turn into checks on reads and writes.
- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — how the elected role travels with every request.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
