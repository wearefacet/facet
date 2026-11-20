---
title: Lua Document Helpers
description: The document.* globals for inter-document operations from Lua scripts — create, get, update, delete, list — with pcall error handling and fixture examples.
tags: [lua, scripts, document-helpers]
---

# Lua Document Helpers

The `document.*` globals let a lifecycle hook or named action read and write other documents in the **same domain**. They are available in create, update, delete, and action contexts (not migration contexts). Each operation runs under the system auth context (full RBAC bypass) inside the parent transaction's savepoint.

## Surface

| Function | Returns | Description |
|---|---|---|
| `document.create(doc_type, content)` | projection table \| error | Creates a document of the given doctype. `content` may be a Lua table or a JSON string. |
| `document.get(doc_type, doc_id)` | projection table \| error | Fetches a document by doctype and id. Raises on not-found. |
| `document.update(doc_type, doc_id, content)` | projection table \| error | Partially updates a document (deep-merge). Raises on failure. |
| `document.delete(doc_type, doc_id)` | `true` \| error | Soft-deletes a document. Raises on failure. |
| `document.list(doc_type, [filters], [sort], [page], [per_page])` | `{items={...}, total=N}` \| error | Lists documents of the doctype. All arguments except `doc_type` are optional. |

## Error handling — always `pcall`

Every `document.*` call **raises a Lua error on failure**. Wrap every call in `pcall` and handle the failure explicitly:

```lua
-- From data/fixtures/crm.Deal/script.lua (win action)
local ok, result = pcall(document.list, "Prospect", { company_id = company_id })
if ok and result and result.items then
    for _, prospect in ipairs(result.items) do
        local prospect_content = util.json_decode(prospect.content)
        -- build customer_content from prospect_content ...
        local cok, cerr = pcall(document.create, "Customer", customer_content)
        if not cok then
            ctx.error("Failed to create customer: " .. tostring(cerr))
        end
    end
end
```

The convention: capture `(ok, result)`, and when `ok` is false, surface the error via `ctx.error("...: " .. tostring(result))` so the failure lands in the audit trail — never let a helper failure abort silently.

## Projection table shape

A returned projection is a table with `id` (qualified `{domain}.{doc_type}.{id}`), `domain`, `doc_type`, `state`, `version`, `content` (JSON string), `meta` (JSON string), `created_at`, `updated_at`, `deleted_at`. Parse `content` with `util.json_decode(...)` before reading fields.

## `document.list` filters

Filters use the same `field__op` convention as the HTTP API. The stored reference values are fully qualified (`{domain}.{Doctype}.{id}`), so when filtering a reference field, qualify the bare id first:

```lua
-- From data/fixtures/crm.Contact/script.lua (delete hook)
local qualified = "crm.Contact." .. doc_id
local ok, result = pcall(document.list, "CompanyMembership",
    { contact__eq = qualified }, nil, 1, 500)
if ok and result and result.items then
    for _, item in ipairs(result.items) do
        pcall(document.delete, "CompanyMembership", item.id)
    end
end
```

Sort is a table of field names (`"-created_at"` for descending); page and per_page are numbers.

## Use cases

- **Cleanup on delete** — `crm.Contact` removes its `CompanyMembership` rows in the `delete` hook, because cascade delete runs only along the parent→child link and would leave dangling membership rows on the inverse side.
- **Transactional state change** — `crm.Deal.win` converts every `Prospect` sharing the deal's `company_id` into a `Customer`, then deletes the prospect. Everything runs under the parent transaction.
- **Merge** — `crm.Company.merge` reassigns the source company's children (`contacts`, `deals`) via `document.update`, moving them to the target company.
- **Immutability guards** — `core.CollectionView.export.update` re-fetches the persisted original via `document.get` (because `ctx.root` on update is the patch-merged document) and rejects changes to `owner_id`.

## Parent transaction note

Child operations nest under PG savepoints of the parent transaction. A `ctx.error` in the calling script rolls the whole turn back — there is no partial commit of helper writes.
