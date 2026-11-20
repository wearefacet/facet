-- crm.Activity action functions
-- Module pattern: return a table of exported functions.
local export = {}

function export.validate(ctx)
    -- Task-type activities start uncompleted
end

-- Complete: mark a task activity as completed
function export.complete(ctx, args)
    if ctx.root.type ~= "task" then
        ctx.error("Only task activities can be completed")
        return
    end
    if ctx.root.completed then
        ctx.error("Task is already completed")
        return
    end
    ctx.root.completed = true
end

-- Computed field: first 200 chars of body
function export.compute_activity_preview(ctx)
    local body = ctx.root.body
    if not body then
        return nil
    end
    return string.sub(body, 1, 200)
end

return export
