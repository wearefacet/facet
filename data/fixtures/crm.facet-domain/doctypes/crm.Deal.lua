local export = {}

-- Computed field "weighted_value" (type: data, compute_when: [value, probability]).
-- Returns value x (probability / 100). The backend calls this as
-- compute_{field.compute} and stores the return value on ctx.root.weighted_value.
-- `ctx.root.value` is a money object `{value="...", currency="..."}` —
-- the numeric amount lives in its `value` member.
function export.compute_deal_weighted_value(ctx)
    local money = ctx.root.value
    local value = (money and money.value) and tonumber(money.value) or 0
    local probability = ctx.root.probability or 0
    return math.floor(value * (probability / 100))
end

-- Lifecycle hook (optional). Runs on document creation.
function export.create(ctx)
    if not ctx.root.title or ctx.root.title == "" then
        ctx.error("Deal title is required")
    end
end

-- Named actions. Each is called as export.{action_key}(ctx, args).
function export.move_stage(ctx, args)
    if ctx.root.stage_id == args.target_stage_id then
        ctx.error("Deal is already in this stage")
        return
    end
    ctx.root.stage_id = args.target_stage_id
end

function export.win(ctx, args)
    if ctx.root.status ~= "open" then
        ctx.error("Can only win open deals")
        return
    end
    ctx.root.status = "won"
    ctx.root.actual_close_date = args.actual_close_date

    -- Convert any Prospect sharing the same company_id into a Customer.
    local company_id = ctx.root.company_id
    if company_id then
        local ok, result = pcall(document.list, "Prospect", { company_id = company_id })
        if ok and result and result.items then
            for _, prospect in ipairs(result.items) do
                local prospect_content = util.json_decode(prospect.content)

                -- Build Customer content from the prospect. The Customer's
                -- `name` is a replicated field pulled from the Company via
                -- `company_id`; it must not be set here.
                local customer_content = {}
                customer_content["status"] = "active"
                customer_content["company_id"] = company_id
                if prospect_content.industry then
                    customer_content["industry"] = prospect_content.industry
                end
                if prospect_content.owner_id then
                    customer_content["owner_id"] = prospect_content.owner_id
                end

                local cok, cerr = pcall(document.create, "Customer", customer_content)
                if not cok then
                    ctx.error("Failed to create customer: " .. tostring(cerr))
                end

                local dok, derr = pcall(document.delete, "Prospect", prospect.id)
                if not dok then
                    ctx.error("Failed to delete prospect: " .. tostring(derr))
                end
            end
        end
    end
end

-- Deletes every Activity whose deal_id points at this deal.
-- Runs inside the caller's transaction (all-or-nothing: one failed
-- delete fails the action through ctx.error and rolls the batch back).
local function delete_deal_activities(ctx)
    local page = 1
    while true do
        local ok, result = pcall(document.list, "Activity", { deal_id = ctx.doc_id }, nil, page, 200)
        if not ok then
            ctx.error("Failed to list deal activities: " .. tostring(result))
            return
        end
        if not result or not result.items or #result.items == 0 then
            return
        end
        for _, activity in ipairs(result.items) do
            local dok, derr = pcall(document.delete, "Activity", activity.id)
            if not dok then
                ctx.error("Failed to delete activity: " .. tostring(derr))
                return
            end
        end
        page = page + 1
    end
end

function export.lose(ctx, args)
    if ctx.root.status ~= "open" then
        ctx.error("Can only lose open deals")
        return
    end
    ctx.root.status = "lost"
    ctx.root.lost_reason = args.reason
    ctx.root.actual_close_date = args.actual_close_date

    -- Losing a deal retires its interaction history: every activity
    -- linked to this deal is soft-deleted with it.
    delete_deal_activities(ctx)
end

return export
