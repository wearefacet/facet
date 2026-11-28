---
title: Roll back a change
description: Roll a document back to an earlier state, restore a deleted one, and know the limits.
type: how-to
audience: [admin]
features: [AUD-04]
verified_at: eee55a2
sidebar:
  order: 1
---

Nadia saves a company record with last quarter's prices by mistake, and the
wrong value is already in the workspace. A rollback puts it right: Facet
replays the document's history to the change you name and saves the result as
a new snapshot. A restore brings back a deleted document the same way. Both
write new history rows; nothing is erased.

## When to use this

- A wrong edit changed a document.
- A document was deleted by mistake.
- You must undo one change and keep the rest.

## Before you start

- **The right.** You need `update` rights on the target document.
- **The target id.** Find it on the document history or in the global log —
  see [See who did what](/admin/history/audit/).
- **The window.** The target must sit inside the retention window — see
  [Retention: what is kept](/admin/history/retention/).

## Steps

### 1. Find the target change

Open the document history. Each entry shows its id — a 26-character ULID.
Copy the id of the change you want to return to. For example, Maison
Lumière's create row is `06H1FM1B3MWR784V64VP6QFM94`. A malformed id answers
`422` before anything runs:

```json
{"error": "mutation_id must be a ULID"}
```

### 2. Roll the document back

The document route takes the target in the body:

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" \
  -d '{"mutation_id": "06H1FM1B3MWR784V64VP6QFM94"}' \
  "$(facet-cli host)/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154/rollback"
```

The body carries `mutation_id`, the id of the target change; the URL carries
the document id. The answer is the document in its rolled-back state:

```json
{
  "data": {
    "city": "Lyon",
    "name": "Maison Lumière",
    "account_manager": "iam.Account.06H1FKYQFRDS3FBJ6HTX6FNQAE"
  },
  "meta": {
    "id": "06H1FM1B3MXBPS0JYVM3BDD154",
    "uri": "urn:facet:clients:Company:06H1FM1B3MXBPS0JYVM3BDD154",
    "mid": "06H1GDBJBWDP6SE85NVRFJ9A15",
    "domain": "clients",
    "doc_type": "Company",
    "version": 1,
    "schema_version": 1,
    "display_name": "Maison Lumière",
    "created_at": "2026-11-26T12:24:08Z",
    "updated_at": "2026-11-26T12:24:09Z"
  },
  "cascade_restored": []
}
```

`meta.mid` is the new snapshot change — the rollback itself. `cascade_restored`
lists the children a restore brought back; a plain rollback returns an empty
array. The global route `POST /Api/Audit/<mutation id>/rollback` does the same
from the global log alone. Its `404` body names the base window, because the
route does not know the target doctype.

### 3. Restore a deleted document

The restore route resolves the target by itself. The body is empty:

```sh
curl -k -X POST -H "Authorization: Bearer $(facet-cli apikey)" \
  -H "Content-Type: application/json" -d '{}' \
  "$(facet-cli host)/Api/clients/Company/06H1FM1B3MXBPS0JYVM3BDD154/restore"
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
`snapshot` change. The snapshot records your account id as the actor.
Internal callers record `system:rollback`. Its `cause_kind` is `rollback`,
and its `cause_parent` names the target change, so the audit trail links the
snapshot to the exact target. Each rollback starts a fresh causal cluster —
the snapshot's own id is its `cause_trace`.

### The limits

- **Rollback depth equals the retention window.** The daily compaction pass
  replaces older rows with one snapshot per document. A target older than the
  window answers `404`, and the body names the effective window. The
  document, child, and restore routes name the window for that doctype; the
  global route names the base window. A window of `0` means full history.
- **A rollback to a delete restores the document.** The target resolves to
  the change immediately before the delete. The snapshot clears the delete
  marker, and the document is live again.
- **A delete with no preceding change has nothing to restore.** The request
  answers `422`.

### Children come back with the document

A restore also brings back the composition children that the undone delete
removed. The preflight checks every child before any write; one denial aborts
the whole restore, and nothing changes. Each child gets its own snapshot
change. Restoring the deleted booking `BK-2026-0001` would bring back its
five booking lines, and the answer lists them in `cascade_restored`:

```json
"cascade_restored": [
  {
    "domain": "rentals",
    "doc_type": "BookingLine",
    "doc_id": "06H1FM1D68H020ZFQ3MKCWY0EE",
    "mut_id": "06H1FM1D68GR9DRWA65NZ968ZR"
  }
]
```

A child that was re-created or re-deleted after the undone delete stays
untouched — the restore reaches only children for which the cascade delete is
still the latest change.

### Who may roll back

The caller needs `update` on the document. Two transition gates can still
refuse with `403`:

- The role-authority gate refuses a rollback that would resurrect stronger
  identity state, for example an old administrator role assignment.
- The field-visibility gate refuses a rollback that would rewind a value into
  a field your role cannot see — even when the target change touched only
  visible fields.

:::caution[The document takes the full target content]
The document takes the whole content of the target state. Changes made after
the target leave the document. They stay in the history. Select a later
target and roll back again to return to them.
:::

## Troubleshooting

### The rollback answers `404` and names a window

The target is older than the retention window, unknown, or folded by
coalescing. One refused call on the Brightwater instance reads:

```json
{"error": "Mutation 01ARZ3NDEKTSV4RRFFQ69G5FAV not found. It may be unknown, older than the retention window (180 days for clients.Company), or folded by coalescing."}
```

Pick a newer target, or widen the window before the next compaction pass —
see [Retention: what is kept](/admin/history/retention/).

### The rollback answers `422` for a well-formed id

The id may name a delete with no preceding change, or a change that
coalescing folded away — see
[Retention: what is kept](/admin/history/retention/).

### The rollback answers `403`

You lack `update` on the document, or a transition gate refused the result.
Check your active role and the tags on the rewound fields.

### The restore answers `409`

The document is live. Reload it instead of retrying.

## Related

- [See who did what](/admin/history/audit/) — find the target change.
- [Retention: what is kept](/admin/history/retention/) — why depth equals the window.
- [The change log, in detail](/admin/under-the-hood/change-log/) — what a snapshot row is.
- [History and undo](/use/documents/history-undo/) — the end-user undo surface.
- Internals on GitHub: [audit.md](https://github.com/wearefacet/facet/blob/main/doc/backend/audit.md).
- [Documents: records with a memory](/discover/how-it-works/documents/)
