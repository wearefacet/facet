---
title: How access is enforced
description: "How Facet enforces access: role permissions, row scopes, and field tags checked on every request — and what each denial means."
type: explanation
audience: [developer, admin]
features: [RBC-03, RBC-06, RBC-09]
verified_at: eee55a2
sidebar:
  order: 3
---

Facet enforces authorization inside every document operation. Two components
do the work: the read enforcer and the write enforcer. Every caller passes
the same checks — a route, a migration, a background job. The sections below
name each check and what each denial answers.

*Four checks stand between the caller and the data.*

<!-- d2
direction: down
caller: Caller {class: external}
enforcer: Enforcers
permission: Permission
scopes: Row scopes
tags: Field tags
metadata: Metadata gate
denied: "Denied" {class: danger}

caller -> enforcer
enforcer -> permission
enforcer -> metadata
enforcer -> denied
permission -> scopes
scopes -> tags
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/67706c52-light.svg" alt="Denied" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/67706c52-dark.svg" alt="Denied" loading="lazy" />
</div>

The model is role-based access control (RBAC). Each request carries one
identity and one elected role. Roles never merge — see
[One role at a time](/admin/under-the-hood/one-role-at-a-time/) for how each
channel builds that pair.

## The permission line

A permission line names three things: an action, a doctype path, and an
optional row scope. The action is `read`, `create`, `update`, `delete`, or
a named action. The path can name one doctype, a whole domain, or every
doctype at once.

## Row scopes

Row scopes are named predicates that the doctype declares. The enforcer
compiles them into Structured Query Language (SQL) predicates. On a list, the
predicates join the query, so the database returns only the rows the role can
see. On a single read, the enforcer evaluates the predicate against the row
itself.

## Field tags

Field tags guard content. A role sees a field only when its `visible_tags`
hold all the field's tags. Untagged fields carry the `default` tag. On reads,
the server removes invisible fields at every nesting level. On writes, a
change into an invisible field is refused with `403`, and the error names the
field path. A filter or a sort on an invisible field is refused with `403`
too, before the query runs.

## What each denial means

Every denial belongs to one of two classes, and the answer follows the class:

- **Class denial.** The caller holds no permission for the operation on the
  doctype at all — no matching line, or the app-grant ceiling refuses. The
  read and write surfaces answer `403`. Knowing that a doctype exists is
  acceptable; document existence is not.
- **Row denial.** The caller holds a grant, but the row misses the scope, or
  the row does not exist. The answer is the non-disclosing `404`: an
  inaccessible document is indistinguishable from a missing one.

A list answer follows the same split. A caller with no read line on the
doctype answers `403`. A scoped caller answers `200` with the visible rows,
possibly none — row scoping never turns into `403`. On a nested child route,
the parent's read gate runs first. A class denial on the parent answers
`403`; a parent the caller cannot see answers `404`.

## The metadata gate

The metadata gate covers render-time metadata: the `core.DocType` definition
rows and the `core.Domain` rows. A role with no `read` line on those doctypes
still receives a row when it holds any action on what the row describes.
Otherwise the row is absent, not `403`. Field aggregates follow the same
rule: a caller with no read grant gets an empty result, `200` with zero
rows. Counts and schema stay hidden where the documents stay hidden.

:::note
Reads mask invisible fields silently. Writes into them fail loudly: `403`
with the field path. A caller whose role cannot see a field never learns
the field's type from a validation error.
:::

## The trade-offs

**Debugging takes longer.** A row denial answers `404`, the same as a missing
document, and that makes debugging harder. You cannot tell a missing document
from a denied one; check the role's permission lines before the id.

**Scopes cost a query.** Scope predicates add query cost — a context set runs
one database query per request.

**Some lists stay empty.** Metadata non-disclosure limits listing features: a
role without grants sees no schema for the hidden doctypes.

## Related

- [Security & governance overview](/discover/security/) — the access model in summary.
- [Roles and permissions](/admin/people/roles-and-permissions/) — create the lines the enforcers read.
- [Show each role only its rows](/admin/people/row-scopes/) — the row scopes in the admin's hands.
- [Hide a field from some roles](/admin/people/hidden-fields/) — the field tags in the admin's hands.
- [One role at a time](/admin/under-the-hood/one-role-at-a-time/) — how identity and role reach the enforcers.
- [Who can change roles](/admin/people/who-can-change-roles/) — who may write roles and accounts.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
