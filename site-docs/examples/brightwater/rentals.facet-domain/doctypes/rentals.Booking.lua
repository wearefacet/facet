-- rentals.Booking — lifecycle script
local export = {}

-- Computed total: sum of quantity x price over the booking's lines.
-- Runs when the lines relationship changes (compute_when: lines).
function export.compute_booking_total(ctx)
    local total = 0
    for _, line in ipairs((ctx.children or {}).lines or {}) do
        local qty = line.quantity or 0
        local price = 0
        if line.price and line.price.value then
            price = tonumber(line.price.value) or 0
        end
        total = total + qty * price
    end
    return total
end

-- Named action: confirm the booking. Needs dates and at least one line.
-- The equipment hook (equipment domain) marks the items out when the
-- state lands on confirmed.
function export.confirm(ctx, args)
    if ctx.root.status == "confirmed" then
        ctx.error("Booking is already confirmed")
        return
    end
    if ctx.root.dates == nil or ctx.root.dates.start == nil then
        ctx.error("Set the dates before confirming")
        return
    end
    local ok, result = pcall(ctx.get_children, "lines")
    if not ok then
        ctx.error("Could not read the booking's lines: " .. tostring(result))
        return
    end
    if #(result or {}) == 0 then
        ctx.error("Add at least one line before confirming")
        return
    end
    ctx.root.status = "confirmed"
end

-- Named action: return the booking. Only a confirmed booking can return.
function export.mark_returned(ctx, args)
    if ctx.root.status ~= "confirmed" then
        ctx.error("Only a confirmed booking can be returned")
        return
    end
    ctx.root.status = "returned"
end

-- Lifecycle guard: a confirmed booking's dates are locked. Return the
-- booking first, then re-confirm with the new dates.
function export.update(ctx)
    if ctx.action ~= nil then
        return
    end
    if ctx.patch == nil then
        return
    end
    if ctx.patch.dates ~= nil and ctx.root.status == "confirmed" then
        ctx.error("A confirmed booking's dates are locked. Return the booking first.")
    end
end

return export
