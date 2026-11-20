---
title: Lua Actor (ctx.actor)
description: The ctx.actor RBAC surface in Lua hooks — identity, role, scope alias, context sets — and the force-ownership-on-create pattern.
tags: [lua, rbac, actor]
---

# Lua Actor (`ctx.actor`)

`ctx.actor` is a read-only RBAC surface available in the `create`, `update`, `delete`, and `action` contexts when an `auth_context` is threaded through (the production path always does). Migration and unit-test contexts leave it `nil` — guard with `if ctx.actor == nil then return end`.

| Field | Type | Description |
|---|---|---|
| `ctx.actor.system` | boolean | `true` for the system bypass principal (seeding, migrations, internal callers); `false` for a real principal. |
| `ctx.actor.id` | string | The caller's account id (same as `ctx.actor_id`). |
| `ctx.actor.role_id` | string? | The active role's id (real principal only). |
| `ctx.actor.scope` | string? | The **bare named-scope alias** on the permission that authorized this hook's own action (e.g. `"mine"`), or `nil` for an unrestricted permission. |
| `ctx.actor.scopes` | array? | The union of scope aliases across all matching permissions for this action (intra-role OR). |
| `ctx.actor.context_sets` | table? | The materialized dynamic value sets for the caller (e.g. `{ my_teams = { "team_1", ... } }`). |

## The alias semantics

`ctx.actor.scope` is the alias **as declared on the permission**, not the expanded `where` predicate:

- create hook → the `create` permission's alias
- update hook → the `update` permission's alias
- delete hook → the `delete` permission's alias
- action hook → the named action's permission alias

Each hook checks its **own** permission line — delete does not reuse the `update` permission.

## The canonical pattern: force ownership on scoped create

On create the row does not exist, so RBAC treats any scoped `create` permission as authorized; row-content rules belong to the Lua hook. The fixture `production.Project` forces `owner_id` to the caller when the create permission is scoped `$mine`:

```lua
-- From data/fixtures/production.Project/script.lua
function export.create(ctx)
    if ctx.actor == nil then
        -- No auth context (legacy callers / unit tests). Nothing to enforce.
        return
    end

    -- Only the `mine` scope (owner_id: $self) constrains ownership at create
    -- time. Unrestricted creators and system bypass are left alone.
    if ctx.actor.scope == "mine" and ctx.actor.system == false then
        ctx.root.owner_id = ctx.actor.id
    end
end
```

Use the same shape whenever a doctype carries an `owner_id`/`author_id` reference to `iam.Account` and the create permission is expected to be scoped `$mine`.

## Guarding on identity

For rejecting or coercing values based on who the caller is, combine `ctx.actor.system` and `ctx.actor.id`:

```lua
if ctx.actor and ctx.actor.system == false then
    -- real caller — enforce row-content rules
end
```

The `core.CollectionView` create hook (`data/seeds/core.CollectionView/script.lua`) is the richer reference: it rejects a caller-supplied `owner_id` that does not match `ctx.actor.id` when the create permission is scoped `$mine`, and its `export.update` makes `owner_id` immutable by comparing the patch-merged `ctx.root` against the persisted original from `document.get`.

## Notes

- `ctx.actor.context_sets` is only present when the domain declares context sets and they resolve; absent on resolution failure.
- The expanded `where` map of a named scope is deliberately **not** exposed — branch on the alias, not the predicate.
