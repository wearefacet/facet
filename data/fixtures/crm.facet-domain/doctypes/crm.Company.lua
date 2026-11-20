-- crm.Company action functions
-- Module pattern: return a table of exported functions.
local export = {}

function export.validate(ctx)
    -- Validate that convert/merge are only called with proper status
end

function export.convert(ctx, args)
    -- Lead -> Active conversion
    if ctx.root.status ~= "lead" then
        ctx.error("Company is not a lead; only lead companies can be converted")
        return
    end
    ctx.root.status = "active"
end

-- Computed field: search_text = name + " " + domain_name
function export.compute_company_search_text(ctx)
    local parts = {}
    if ctx.root.name then
        table.insert(parts, ctx.root.name)
    end
    if ctx.root.domain_name then
        table.insert(parts, ctx.root.domain_name)
    end
    if #parts > 0 then
        return table.concat(parts, " ")
    end
    return nil
end

-- Merge: move all contacts and deals from source to this company
function export.merge(ctx, args)
    local source_id = args.source_company_id
    if not source_id then
        ctx.error("source_company_id is required")
        return
    end
    if source_id == ctx.root._id then
        ctx.error("Cannot merge a company into itself")
        return
    end

    -- Move contacts: reassign their company_id to this company
    local contacts = ctx.get_children("contacts") or {}
    for _, contact in ipairs(contacts) do
        local contact_update = {}
        contact_update["company_id"] = ctx.root._id
        local ok, err = pcall(document.update, "Contact", contact, contact_update)
        if not ok then
            ctx.error("Failed to update contact " .. contact .. ": " .. tostring(err))
            return
        end
    end

    -- Move deals: reassign their company_id to this company
    local deals = ctx.get_children("deals") or {}
    for _, deal in ipairs(deals) do
        local deal_update = {}
        deal_update["company_id"] = ctx.root._id
        local ok, err = pcall(document.update, "Deal", deal, deal_update)
        if not ok then
            ctx.error("Failed to update deal " .. deal .. ": " .. tostring(err))
            return
        end
    end
end

return export
