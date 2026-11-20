-- crm.Contact action functions
-- Module pattern: return a table of exported functions.
local export = {}

-- Computed field: full_name = first_name + " " + last_name
function export.compute_contact_full_name(ctx)
    return (ctx.root.first_name or "") .. " " .. (ctx.root.last_name or "")
end

-- Lifecycle hook: delete.
--
-- Removes every crm.CompanyMembership row whose `contact` field references
-- this contact, before the contact tombstone is persisted. Membership rows
-- are owned by their parent Company (cascade-delete runs only along the
-- parent->child link), so a direct Contact delete would otherwise leave
-- dangling membership rows on the inverse side.
--
-- Uses the platform's `document.list` + `document.delete` API. The
-- membership rows store the `contact` field fully qualified as
-- `{domain}.{Doctype}.{id}` (ReferenceType#normalize), so the filter value
-- is constructed by qualifying the contact's bare doc_id.
function export.delete(ctx)
    local doc_id = ctx.doc_id
    if doc_id == nil then return end

    -- `document.list`'s filter hash uses the same `field__op` convention as
    -- the HTTP API. The stored value is qualified, so qualify the bare id.
    local qualified = "crm.Contact." .. doc_id

    local ok, result = pcall(document.list, "CompanyMembership",
        { contact__eq = qualified }, nil, 1, 500)
    if not ok then
        -- Listing failed (RBAC, doctype missing, etc). Do not block the
        -- contact delete on the inverse cleanup -- surface the failure via
        -- ctx.error so the audit trail records it.
        if ctx.error then ctx.error("contact delete: failed to list memberships: " .. tostring(result)) end
        return
    end

    if result == nil or result.items == nil then return end
    for _, item in ipairs(result.items) do
        pcall(document.delete, "CompanyMembership", item.id)
    end
end

return export
