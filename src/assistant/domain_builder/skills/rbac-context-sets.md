---
title: RBAC Context Sets
description: context_sets on core.Domain, from/where/select, DAG resolution, $parent_id in context sets.
tags: [rbac, context-sets]
---

# RBAC Context Sets

A context set is a domain-owned dynamic value set, declared on `core.Domain.definition.content.context_sets`. Named scopes reference them via `$<name>` to resolve a set of values at request time.

## Declaration

```json
{
  "id": "hr",
  "context_sets": {
    "my_teams": {
      "from": "Team",
      "where": {"manager_id": "$self"},
      "select": "id"
    }
  }
}
```

| Field | Required | Description |
|---|---|---|
| `from` | yes | The doctype to query (same-domain only). |
| `where` | no | Predicate map. Supports `$self`, literals, `$parent_id`, and `$<other_context_set>` references. |
| `select` | yes | The field name to project. (Stored as `select_field` on the Crystal struct because `select` is a keyword.) |

## Grammar

- `$self` — the actioner's account id.
- `$parent_id` — `meta->>'parent_id'` of the current document.
- `$<other_context_set>` — the resolved value set of another declared context set (DAG resolution by `ContextResolver`).

## DAG resolution

Context sets form a directed acyclic graph. `ContextResolver` resolves them per-request with memoization. Cycles are rejected at authoring time.

## Context sets vs named scopes

- **Context sets** live on `core.Domain` — they produce a set of values.
- **Named scopes** live on the doctype definition — they're predicates over a single row.
- A named scope references a context set via `$<name>` and membership-tests the row's field value against the resolved set.

## Authoring-time validation

`validate_context_set_definitions` on `core.Domain` rejects:

- Cyclic context-set references.
- `from` referencing a doctype in another domain.
- Unknown fields in `where`.
- `$<context_set>` references to undeclared context sets in the same domain.

In draft mode, the draft `core.Domain` may have no context_sets — use `$self` and literals only while drafting.
