---
type: explanation
title: Authorization enforcement
description: Every request passes the read and write enforcers, which check role permissions, row scopes, and field tags before any data moves.
audience: [evaluator, developer]
features: [RBC-03, RBC-06, RBC-09]
sidebar:
  order: 3
verified_at: 7a6cb462
---

Facet enforces authorization inside every document operation. Two
components do the work: the read enforcer and the write enforcer. Every
caller passes the same checks — a route, a migration, a background job.

## Explanation

<!-- d2
caller: Caller {class: external}
enforcer: Enforcers
permission: Permission
scopes: Row scopes
tags: Field tags
metadata: Metadata gate
denied: "Denied read: 404" {class: danger}

caller -> enforcer
enforcer -> permission
enforcer -> metadata
enforcer -> denied
permission -> scopes
scopes -> tags
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/9a3dd412-light.svg" alt="Denied read: 404" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/9a3dd412-dark.svg" alt="Denied read: 404" loading="lazy" />
</div>

The model is role-based access control (RBAC). Each request carries one
identity and one elected role. Roles never merge.

A permission line names three things: an action, a doctype path, and an
optional row scope. The action is `read`, `create`, `update`, `delete`, or
a named action. The path can name one doctype, a whole domain, or every
doctype at once.

**Row scopes.** Row scopes are named predicates that the doctype declares.
The enforcer compiles them into Structured Query Language (SQL) predicates.
On a list, the predicates join the query, so the database returns only the
rows the role can see. On a single read, the enforcer evaluates the predicate
against the row itself.

**Field tags.** Field tags guard content. A role sees a field only when its
`visible_tags` hold all the field's tags. Untagged fields carry the `default`
tag. On reads, the server removes invisible fields at every nesting level. On
writes, a change into an invisible field is refused with `403`, and the
error names the field path.

**Denial is non-disclosing.** A single read the role cannot see answers `404`
— the same answer as a missing document. A list answers `200` with the
visible rows only. On a nested child route, a denied parent read and a
missing parent give the same `404`.

**The metadata gate.** The metadata gate covers render-time metadata: the
`core.DocType` definition rows and the `core.Domain` rows. A role with no
`read` line on those doctypes still receives a row when it holds any action
on what the row describes. Otherwise the row is absent, not `403`. Field
aggregates follow the same rule: a caller with no read grant gets an empty
result, `200` with zero rows. Counts and schema stay hidden where the
documents stay hidden.

:::note
Reads mask invisible fields silently. Writes into them fail loudly: `403`
with the field path. A caller whose role cannot see a field never learns
the field's type from a validation error.
:::

### The trade-off

**Debugging takes longer.** The `404` masking makes debugging harder. You
cannot tell a missing document from a denied one; check the role's permission
lines before the id.

**Scopes cost a query.** Scope predicates add query cost — a context set runs
one database query per request.

**Some lists stay empty.** Metadata non-disclosure limits listing features: a
role without grants sees no schema for the hidden doctypes.

## Related

- [Security & governance overview](/discover/security/) — the access model in summary.
- [Govern access](/admin/) — create the roles and permission lines the enforcers read.
- [Auth contexts](/admin/under-the-hood/one-role-at-a-time/) — how identity and role reach the enforcers.
- [Roles, levels and authority](/admin/people/who-can-change-roles/) — who may write roles and accounts.
- [Domains and isolation](/discover/how-it-works/domains/) — the boundary that permissions name.
- Internals on GitHub: [rbac.md](https://github.com/wearefacet/facet/blob/main/doc/backend/rbac.md), [http-layer.md](https://github.com/wearefacet/facet/blob/main/doc/backend/http-layer.md).
