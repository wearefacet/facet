-- hr.Employee action functions
-- Module pattern: return a table of exported functions.
-- Called by the Facet action context with `ctx` and `args` parameters.
-- ctx.root = current document content, ctx.error(msg) = validation error,
-- ctx.actor_id = the actioner, ctx.now = ISO 8601 timestamp.
-- Children (career_events) are stored as separate documents.
-- Actions that create children should call ctx.create_child() instead
-- of inline table operations.

local export = {}

function export.validate(ctx)
    -- Reject future hire_date
    if ctx.root.hire_date and ctx.root.hire_date > ctx.now then
        ctx.error("hire_date cannot be in the future")
    end

    -- Reject manager reference set to self (the manager id portion equals
    -- the person id portion). Both values are stored as fully qualified
    -- `{domain}.{Doctype}.{id}` strings, so we compare the id segment
    -- (everything after the second dot).
    if ctx.root.manager and ctx.root.person then
        local function ref_id(v)
            local first = v:find("%.")
            if not first then return v end
            local second = v:find("%.", first + 1)
            if not second then return v end
            return v:sub(second + 1)
        end
        if ref_id(ctx.root.manager) == ref_id(ctx.root.person) then
            ctx.error("manager cannot reference self")
        end
    end
end

function export.promote(ctx, args)
    -- Must be active
    if ctx.root.status ~= "active" then
        ctx.error("Employee is not active")
        return
    end

    local new_title = args.new_title
    if not new_title then
        ctx.error("new_title is required")
        return
    end

    -- Must differ from current job_title
    if ctx.root.job_title == new_title then
        ctx.error("New title must differ from current title")
        return
    end

    -- Update job_title
    ctx.root.job_title = new_title
end

function export.change_salary(ctx, args)
    -- Must be active
    if ctx.root.status ~= "active" then
        ctx.error("Employee is not active")
        return
    end

    local new_salary = args.new_salary
    if not new_salary then
        ctx.error("new_salary is required")
        return
    end

    -- `new_salary` is a money object {value="...", currency="..."}; the
    -- numeric amount lives in its `value` member.
    local new_value = tonumber(new_salary.value)
    if not new_value then
        ctx.error("new_salary.value must be a decimal string")
        return
    end

    -- Must be positive
    if new_value <= 0 then
        ctx.error("New salary must be greater than zero")
        return
    end

    -- Must differ from current salary
    local current = ctx.root.salary
    local current_value = current and current.value and tonumber(current.value)
    if current_value and current_value == new_value then
        ctx.error("New salary must differ from current salary")
        return
    end

    -- Update salary
    ctx.root.salary = new_salary
end

-- Computed field: tenure_days = days since hire (or until termination)
function export.compute_employee_tenure_days(ctx)
    local hire_date = ctx.root.hire_date
    if not hire_date then
        return nil
    end

    local end_date = ctx.root.termination_date or ctx.now
    return date.diff(hire_date, end_date, "day")
end

-- Computed field: current_title = job_title (career events are separate docs)
function export.compute_employee_current_title(ctx)
    return ctx.root.job_title
end

function export.terminate(ctx, args)
    -- Must be active
    if ctx.root.status ~= "active" then
        ctx.error("Employee is not active")
        return
    end

    local effective_date = args.effective_date or ctx.now

    -- Update status and set termination_date
    ctx.root.status = "terminated"
    ctx.root.termination_date = effective_date
end

return export
