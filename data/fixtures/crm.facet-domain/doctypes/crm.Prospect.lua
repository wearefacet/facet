-- crm.Prospect action functions
-- Module pattern: return a table of exported functions.
local export = {}

function export.validate(ctx)
    -- Validate prospect state
end

-- Convert: promote a Prospect to a Customer.
--
-- The Prospect references a Company; the Customer is created referencing the
-- same Company. Contacts and deals are owned by the Company (not the
-- Prospect), so nothing is transferred -- they keep their parent_id / company_id
-- links. The Prospect is then deleted.
function export.convert(ctx, args)
    if not ctx.root.company_id then
        ctx.error("Cannot convert a prospect without a company_id")
        return
    end

    -- Build Customer content from prospect fields, preserving the company link.
    -- The Customer's `name` is a replicated field pulled from the Company via
    -- `company_id`; it must not be set here. Same for any other replica field.
    local customer_content = {}
    customer_content["status"] = args.customer_status or "active"
    customer_content["company_id"] = ctx.root.company_id
    if ctx.root.industry then customer_content["industry"] = ctx.root.industry end
    if ctx.root.owner_id then customer_content["owner_id"] = ctx.root.owner_id end

    -- 1. Create the Customer record referencing the same Company.
    local ok, customer = pcall(document.create, "Customer", customer_content)
    if not ok then
        ctx.error("Failed to create customer: " .. tostring(customer))
        return
    end

    -- customer.id is the full qualified form e.g. "crm.Customer.<uuid>"
    local customer_id = customer.id

    -- 2. Delete the prospect. Contacts and deals are owned by the Company, so
    --    no child transfer is needed.
    local ok, err = pcall(document.delete, "Prospect", ctx.doc_id)
    if not ok then
        ctx.error("Failed to delete prospect: " .. tostring(err))
        return
    end

    -- 3. Store conversion result in ctx.root so the action diff captures it
    ctx.root.converted_to_customer_id = customer_id
    ctx.root.status = "converted"
end

return export
