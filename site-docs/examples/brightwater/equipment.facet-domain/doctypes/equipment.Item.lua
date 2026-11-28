-- equipment.Item — lifecycle script
local export = {}

-- Named action: send the item to repair.
-- Only an item that is not already in repair can move there.
function export.send_to_repair(ctx, args)
    if ctx.root.status == "in_repair" then
        ctx.error("Item is already in repair")
        return
    end
    ctx.root.status = "in_repair"
end

-- Note on transition guards: an update hook sees ctx.root as the merged
-- document (current content with the patch applied), so a rule like
-- "in_repair must not move to out" cannot read the state before the patch.
-- The booking hook enforces that rule instead — it reads each item's
-- current state before it writes (see hooks/1-booking-drives-stock.lua).

return export
