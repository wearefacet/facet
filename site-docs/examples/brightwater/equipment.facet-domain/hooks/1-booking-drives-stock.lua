-- booking-drives-stock — equipment domain hook
-- Fires when a Booking in the rentals domain is confirmed or returned. A
-- confirmed booking marks its items out; a returned booking brings them
-- back. The cross-domain read of the booking's lines needs an active grant
-- from rentals to equipment (core.DomainGrant under rentals).
local export = {}

function export.on_event(ctx)
    local ev = ctx.event
    -- Fires on the confirm and mark_returned actions' events only (the
    -- source list in domain.yml). The status check is a safety net.
    if ev.doc_type ~= "Booking" then
        return
    end
    local status = ev.content and ev.content.status
    if status ~= "confirmed" and status ~= "returned" then
        return
    end

    local target = status == "confirmed" and "out" or "available"

    -- List the booking's lines across the domain boundary. Without an
    -- active grant this raises; the pcall turns it into a collected error.
    local ok, result = pcall(document.list, "rentals.BookingLine", { parent_id__eq = ev.doc_id })
    if not ok then
        ctx.error("Could not read the booking's lines: " .. tostring(result))
        return
    end

    for _, line in ipairs(result.items or {}) do
        local content = util.json_decode(line.content or "{}")
        local ref = content.item
        if ref then
            -- The reference stores the qualified form equipment.Item.<id>;
            -- the read and the write want the bare id.
            local item_id = string.match(ref, "([^%.]+)$")
            -- Read the item's current state first. An item in repair cannot
            -- go out on a booking: collect the refusal and leave that item
            -- in repair — the rest of the booking still goes out. (The
            -- update guard cannot do this check: an update hook sees the
            -- merged document, never the state before the patch.)
            local ok_item, proj = pcall(document.get, "Item", item_id)
            if not ok_item then
                ctx.error("Item " .. tostring(ref) .. ": " .. tostring(proj))
            else
                local item = util.json_decode(proj.content or "{}")
                if target == "out" and item.status == "in_repair" then
                    ctx.error("Item " .. tostring(ref) .. " is in repair and cannot be booked out")
                else
                    local done, err = pcall(document.update, "Item", item_id, { status = target })
                    if not done then
                        ctx.error("Item " .. tostring(ref) .. ": " .. tostring(err))
                    end
                end
            end
        end
    end
end

return export
