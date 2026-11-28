---
type: explanation
title: Who can change roles
description: One guard bounds every write to accounts and roles. See what it checks, what it refuses, and what it costs.
audience: [admin, author]
features: [RBC-01, RBC-07]
verified_at: eee55a2
sidebar:
  order: 6
---

Nadia runs Brightwater's client work as *Manager*, level 60. Ravi manages the
whole instance as *Administrator*, level 100. When Nadia needs a colleague on a
wider role, Facet must decide whether she may. One rule decides: nobody moves
authority upward. This page shows that rule — the **authority guard** — what
it checks, and where it refuses.

## Where the guard sits

A role is a document, and an account is a document. You edit both like any
other record. One guard bounds this freedom on those two doctypes.

The guard checks every caller write on `iam.Account` and `iam.Roles`:
creates, updates, deletes, named actions, and rollback transitions. It runs
after the ordinary permission check. A caller whose role holds no write line
on the target doctype never reaches the guard — their write stops earlier,
with a plain `403 Forbidden`. A caller who passes that check meets the guard. A refusal answers `403` with
the message `Role authority refused this write`, and its `details` list names
the failed check.

A refused write changes nothing. No row enters the history, and no event
leaves. The guard runs its checks before any database change, and route-level
permission skips do not bypass it. Only Facet's internal system calls skip it.

*One check sits between the caller and every account or role write.*

<!-- d2
direction: down
caller: Caller with one elected role {class: external}
write: Write to iam.Account or iam.Roles {class: node}
gate: Authority guard {class: decision}
applied: Write applies {class: ok}
denied: 403, nothing lands {class: danger}

caller -> write: update line on iam.Account or iam.Roles
write -> gate
gate -> applied: all four checks pass
gate -> denied: any check fails
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/6c20204e-light.svg" alt="Diagram" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/6c20204e-dark.svg" alt="Diagram" loading="lazy" />
</div>

The level the guard reads comes from the caller's one elected role — never
from the highest role they hold. Roles never merge; see
[One role at a time](/admin/under-the-hood/one-role-at-a-time/) for why
Facet elects one role per request.

## The four checks

At Brightwater, *Sales* and *Warehouse* sit at level 40, *Manager* at 60, and
*Administrator* at 100. The level comes from the role document, it is
required, and it runs from 0 to 100. The guard reads it and asks four
questions:

| Check | The question it asks |
| --- | --- |
| Caller level | Does the elected role carry a usable level at all? A role without one denies every IAM write. |
| Assignment | Does every role in the final `roles` array exist, live, and sit at or below the caller's level? |
| Target protection | Does the target account or role sit at or below the caller's level? |
| Role authoring | Does the changed role stay inside what the previous role and the caller's role imply? |

The first three keep authority from flowing upward. The last keeps a role
editor from widening a role into something nobody granted. Every permission
line must be implied by the previous role's lines or the caller's own lines.
New field tags must sit inside the union of both, and the connectivity
channels and assistant budget follow the same containment. A write that adds
an unknown role-power field is denied.

## Where the guard refuses

The refusals below ran on the Brightwater instance with a level-60 test role
that held the account-write line — the same level Nadia's *Manager* carries.

**Ravi's account is out of reach, even to lower it.** A write to any account
whose highest assigned role sits above the caller is refused:

```json
{"error": "Role authority refused this write", "details": [{"message": "account's current role ceiling (100) is above the caller level (60)", "code": "forbidden"}]}
```

:::caution
A narrowing-only change is still a write. A level-60 caller cannot remove
roles from Ravi's account, not even as a favour. Only Ravi, or another
administrator, edits that account.
:::

**The Administrator role cannot be handed out.** Adding `iam.Roles.admin` to
anyone's `roles` array fails the assignment check:

```json
{"error": "Role authority refused this write", "details": [{"message": "role 'iam.Roles.admin' (level 100) is above the caller level (60)", "code": "forbidden"}]}
```

**The Administrator role document is out of reach too.** A patch on the role
document itself hits target protection before any content check:

```json
{"error": "Role authority refused this write", "details": [{"message": "existing role level (100) is above the caller level (60)", "code": "forbidden"}]}
```

**Same level is enough for assignment.** A caller may assign an existing role
at their own level, even when that role holds permissions they lack. Nadia
could put *Manager* on an account; a level-40 lead could put *Warehouse* on
one. Delegation needs this — a team lead staffs their team without holding
every team power. Creating a role above the caller's level stays refused.
Widening a role past what the previous role or the caller's role implies is
refused with a named line:

```json
{"error": "Role authority refused this write", "details": [{"message": "permissions[2] (read on clients.Company) is not implied by the previous role or the caller's role", "code": "forbidden"}]}
```

## What the guard costs

**Repair needs a higher admin.** An account whose ceiling sits above a caller
is read-only to them, so a mistake on it waits for an administrator. That is
the price of closing the lower-then-widen attack: nobody below a target can
touch it, not even to make it smaller.

**Roles do not nest.** The level orders roles; it does not cascade rights.
Each role lists its permission lines in full, and a wider role never grants
its lines to a narrower one. A role's reach stays readable in one place: the
role document itself.

The guard does not replace the other checks. The ordinary permission lines,
row scopes, and field tags still apply on every write — the guard adds the
authority bound on top. See
[How access is enforced](/admin/under-the-hood/how-access-is-enforced/) for
where each check runs.

## Related

- [Roles and permissions](/admin/people/roles-and-permissions/) — the four checks as an operator's table.
- [Assign roles](/admin/people/assign-roles/) — the assignment flow the guard bounds.
- [Require MFA](/admin/people/mfa/) — the next page in the people story.
- [One role at a time](/admin/under-the-hood/one-role-at-a-time/) — why the elected role sets your authority.
- [How access is enforced](/admin/under-the-hood/how-access-is-enforced/) — the checks the guard sits beside.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md).
