---
title: Named Scopes
description: scopes declaration, where grammar ($self, literals, $<context_set>), $parent_id token, when scopes apply vs not.
tags: [rbac, scopes]
---

# Named Scopes

A named scope is a reusable predicate over a doctype's own fields, declared on the doctype. RBAC permissions reference them via `$<name>`.

## Declaration

```json
{
  "scopes": {
    "mine": {
      "description": "Projects owned by the actioner",
      "where": {"owner_id": "$self"}
    },
    "active": {
      "description": "Projects in the active status",
      "where": {"status": "active"}
    }
  }
}
```

## Where grammar (ScopeValue)

Each value in a `where` clause can be:

- A **literal** — compared verbatim against the field's content.
- **`$self`** — the actioner's account id. Matches **both** stored forms: the bare id (a plain `string` field holding `ctx.actor.id` — the force-ownership recipe) and the qualified `iam.Account.<id>` form (a `reference → iam.Account` field). Either field type works with a `mine` scope.
- **`$<context_set>`** — references a context set declared on `core.Domain` (resolved at request time by `ContextResolver`). Membership-tested against the field's content.
- **`$null`** — matches rows where the field is absent or its content value is JSON null. Lets a scope express `IS NULL` predicates (e.g. the `core.CollectionView` `general` scope matches views with no owner).

Field names must exist on the doctype, or be the reserved `$parent_id` token.

## `$parent_id` token

`$parent_id` reads `meta->>'parent_id'` — the system-managed parent linkage on child doctypes. Lets a scope filter children by their parent.

## When scopes apply

- `update` / `delete` / `action` — the target document must satisfy the scope's `where`.
- `create` — scopes apply only as permission-presence checks (the row doesn't exist yet). Row-content rules belong in the Lua `create(ctx)` hook via `ctx.error(msg)`.

## Authoring-time validation

A doctype create/update is rejected when:

- A scope's `where` references an unknown field.
- A scope references an unknown `$<context_set>` not declared on `core.Domain` in the same domain.
- A scope references an out-of-domain context set.

In draft mode, `core.Domain.context_sets` may be empty — `$<context_set>` references will be rejected. Use `$self` and literals only while drafting; full context-set resolution is the responsibility of the live domain the draft publishes to.
