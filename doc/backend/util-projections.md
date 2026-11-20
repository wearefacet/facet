# Util::Projections — Shared Projection Lookups

**Files:** `src/util/projections.cr`

`Facet::Util::Projections` holds small shared queries against the `projections` table that several services (doctype, domain, iam) would otherwise re-write inline.

## Public API

| Method | Returns | Description |
|---|---|---|
| `.exists?(db, domain, doc_type, id)` | `Bool` | True when a live (non-tombstoned) projection row exists. |
| `.draft_domain?(db, domain, lock)` | `Bool` | Reads the `draft` flag of a `core.Domain` projection. NULL (no `draft` key) reads as not-draft. |

## Usage

```crystal
return ServiceError.new(404, "Domain not found") unless Util::Projections.exists?(db, "core", "Domain", id)
```

With `lock: true`, `draft_domain?` reads the row `FOR UPDATE`. Keep the lock where callers had it — publish-gate and version-bump paths rely on it.

Note: `query_one?` with a block yields the first row pre-positioned. Do not call `rs.each` inside that block — it would skip the row.
