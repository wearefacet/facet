-- core.DomainEditor lifecycle hooks.
--
-- Guards the domain-editor list itself: a DomainEditor row must point at a
-- real, live, non-system core.Domain document. A typo'd slug must fail loud
-- (a grant that silently matches nothing would look like a revocation), and
-- the bootstrap domains must never be re-scoped.
--
-- Runs on create and on every update (the merged state is re-checked), so
-- a PATCH cannot retarget a grant at a system domain or a dead slug.
-- Seeding and internal writers pass through the same hook — they only ever
-- target existing, non-system domains.
local export = {}

-- Mirrors Domain::Drop's PROTECTED_DOMAINS. Lua cannot reach Crystal
-- constants; keep the two lists in step.
local SYSTEM_DOMAINS = { core = true, iam = true, app = true }

local function validate_target(ctx)
    local target = ctx.root["domain"]
    if target == nil or target == "" then
        return -- required-field validation covers the absent case
    end

    if SYSTEM_DOMAINS[target] then
        ctx.error("Domain '" .. target .. "' is a system domain and cannot be assigned a domain editor")
        return
    end

    -- The target must exist as a live core.Domain row. document.get raises
    -- a Lua error when the row is missing, so the lookup runs under pcall
    -- and a failed lookup degrades to a validation error.
    local ok, proj = pcall(document.get, "Domain", target)
    if not ok or proj == nil or proj.deleted_at ~= nil then
        ctx.error("Domain '" .. target .. "' does not exist — a domain editor must name a live core.Domain document")
    end
end

function export.create(ctx)
    validate_target(ctx)
end

function export.update(ctx)
    validate_target(ctx)
end

return export
