---
title: Rolling back changes
description: Roll a document back to an earlier mutation, restore a deleted document, and know the limits.
audience: [admin]
features: [AUD-04]
sidebar:
  order: 11
verified_at: fd345fe3
---

A rollback replays a document's change history to a chosen mutation and saves
the result as a new snapshot. A restore brings back a deleted document. Both
write new history rows; nothing is erased.

## When to use this

- A wrong bulk edit changed a document.
- A document was deleted by mistake.
- You must undo one change and keep the rest.

## Before you start

- **The right.** You need `update` rights on the target document.
- **The target id.** Find it on the document history page or the global audit
  log — see [Auditing activity](/govern/auditing-activity/).
- **The window.** The target must sit inside the retention window — see
  [Retention](/govern/retention/).

## Steps

### 1. Find the target mutation

Open the document history. Each entry shows its mutation id — a 26-character
ULID. Copy the id of the change you want to return to. A malformed id answers
`422` before the service runs.

### 2. Roll the document back

The document route takes the target in the body:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"mutation_id": "01J8Z0A7G3Q5M2X9K4T6VBNR8D"}' \
  "https://facet.localhost:3443/Api/production/Project/01HXQ5M2X9K4T6VBNR8D3Q5M2X/rollback"
```

The body carries `mutation_id`, the id of the target change; the URL carries
the document id. The answer is the document in its rolled-back state:

```json
{
  "data": {
    "name": "Aurora launch",
    "status": "planned"
  },
  "meta": {
    "id": "01HXQ5M2X9K4T6VBNR8D3Q5M2X",
    "uri": "urn:facet:production:Project:01HXQ5M2X9K4T6VBNR8D3Q5M2X",
    "mid": "01CRT6VBNR8D3Q5M2X7BQ5M2XA",
    "domain": "production",
    "doc_type": "Project",
    "version": 7,
    "schema_version": 1,
    "display_name": "Aurora launch",
    "created_at": "2026-01-12T09:30:00Z",
    "updated_at": "2026-11-13T10:15:00Z"
  },
  "cascade_restored": []
}
```

`meta.mid` is the new snapshot mutation. `cascade_restored` lists the children
a restore brought back; a plain rollback returns an empty array. The global
route `POST /Api/Audit/<mutation id>/rollback` does the same from the global
log alone. Its `404` body names the base window, because the route does not
know the target doctype.

### 3. Restore a deleted document

The restore route resolves the target by itself. The body is empty:

```sh
curl -k -X POST -H "Authorization: Bearer $FACET_API_KEY" \
  -H "Content-Type: application/json" -d '{}' \
  "https://facet.localhost:3443/Api/production/Project/01HXQ5M2X9K4T6VBNR8D3Q5M2X/restore"
```

| Answer | Meaning |
| --- | --- |
| `200` | The document is live again. |
| `404` | The document has no history to restore. |
| `409` | The document is not deleted. Refresh instead of retrying. |
| `403` | Your role lacks `update` on the document. |
| `422` | Degenerate history: a delete with no change before it. |

## Explanation

### What a rollback writes

The service replays the history up to the target and persists one new
`snapshot` mutation. The snapshot records your account id as the actor.
Internal callers record `system:rollback`. Its `cause_kind` is `rollback`, and
its `cause_parent` names the target mutation, so the audit trail links the
snapshot to the exact target.

### The limits

- **Rollback depth equals the retention window.** The compaction pass replaces
  older rows with one snapshot per document. A target older than the window
  answers `404`. The body names the effective window: the document, child, and
  restore routes name the window for that doctype; the global route names the
  base window; a window of `0` means full history.
- **A rollback to a delete restores the document.** The target resolves to the
  change immediately before the delete. The snapshot clears the delete marker,
  and the document is live again.
- **A delete with no preceding change has nothing to restore.** The request
  answers `422`.

### Children come back with the document

A restore also brings back the composition children that the undone delete
removed. The preflight checks every child before any write; one denial aborts
the whole restore. Each child gets its own snapshot mutation. The answer lists
them in `cascade_restored`:

```json
"cascade_restored": [
  {
    "domain": "production",
    "doc_type": "Project.Task",
    "doc_id": "01BQ5M2X9K4T6VBNR8D3Q5M2X7",
    "mut_id": "01D3Q5M2X7BQ5M2XA9K4T6VBNR8"
  }
]
```

### Who may roll back

The caller needs `update` on the document. Two transition gates can still
refuse with `403`:

- The role-authority gate refuses a rollback that would resurrect stronger
  identity state, for example an old admin role assignment.
- The field-visibility gate refuses a rollback that would rewind a value into
  a field your role cannot see.

:::caution[The document takes the full target content]
The document takes the whole content of the target state. Changes made after
the target leave the document. They stay in the history. Select a later target
and roll back again to return to them.
:::

## Troubleshooting

### The rollback answers `404` and names a window

The target is older than the retention window. Pick a newer target, or widen
the window before the next compaction pass — see [Retention](/govern/retention/).

### The rollback answers `422` for a well-formed id

The id may name a delete with no preceding change, or a change that coalescing
folded away — see [Retention](/govern/retention/).

### The rollback answers `403`

You lack `update` on the document, or a transition gate refused the result.
Check your active role and the tags on the rewound fields.

### The restore answers `409`

The document is live. Reload it instead of retrying.

## Related

- [History and undo](/workspace/history-undo/) — the end-user undo surface.
- [Auditing activity](/govern/auditing-activity/) — find the target mutation.
- [Retention](/govern/retention/) — why depth equals the window.
- [The mutation log](/concepts/mutation-log/) — what a snapshot row is.
- Internals on GitHub: [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
