-- core.SchematicLayout lifecycle hooks.
--
-- One layout row per target domain. The guards run on create and update:
--
-- 1. Target-domain check — the `domain` field must name a live core.Domain
--    row. A typo'd slug must fail loud (the same rule core.DomainEditor
--    applies to its own `domain` field).
-- 2. Uniqueness — a second row for the same domain is refused, so the
--    frontend's list-by-domain lookup always resolves one row. On update
--    the check excludes the row itself, so a save never trips on its own
--    document. A genuine retarget (PATCH that changes `domain`) is checked
--    against the new value.
-- 3. Domain-editor gate — a caller whose matching permission resolves
--    through the `domain_editor` named scope may only lay out domains they
--    edit (`ctx.actor.context_sets.editor_domains`). Unrestricted callers
--    (admin, blanket roles — `ctx.actor.scopes` absent) and system writers
--    (seeding — `ctx.actor.system`) pass without the check. A scoped
--    caller whose context sets did not resolve is denied (fail closed).
--    The gate runs on update too: the scope enforcer matched the row's
--    stored domain, but a PATCH could otherwise retarget the row at a
--    domain the caller does not edit.
local export = {}

local function validate_target(ctx)
    local target = ctx.root["domain"]
    if target == nil or target == "" then
        return -- required-field validation covers the absent case
    end

    -- document.get raises a Lua error when the row is missing, so the
    -- lookup runs under pcall and a failed lookup degrades to a
    -- validation error.
    local ok, proj = pcall(document.get, "Domain", target)
    if not ok or proj == nil or proj.deleted_at ~= nil then
        ctx.error("Domain '" .. target .. "' does not exist — a schematic layout must name a live core.Domain document")
    end
end

local function check_unique_domain(ctx)
    local target = ctx.root["domain"]
    if target == nil or target == "" then
        return
    end

    local result = document.list("SchematicLayout", { domain = target }, { "id" }, 1, 1000)
    if result == nil or result.items == nil then
        return
    end

    for _, layout in ipairs(result.items) do
        if ctx.doc_id == nil or layout.id ~= ctx.doc_id then
            ctx.error("Domain '" .. target ..
                "' already has a schematic layout. A domain has exactly one layout document.")
            return
        end
    end
end

-- Domain-editor gate on create and update: mirrors the core.DocumentView
-- create hook. See the file header for who passes and who is denied.
local function check_editor_domain(ctx)
    local actor = ctx.actor
    if actor == nil or actor.system then
        return
    end

    local scopes = actor.scopes
    if scopes == nil then
        return
    end

    local is_domain_editor = false
    for _, alias_name in ipairs(scopes) do
        if alias_name == "domain_editor" then
            is_domain_editor = true
        end
    end
    if not is_domain_editor then
        return
    end

    local target = ctx.root["domain"]
    if target == nil then
        return -- required-field validation covers the absent case
    end

    local sets = actor.context_sets
    local allowed = sets and sets.editor_domains
    if allowed == nil then
        ctx.error("Domain-editor scope could not resolve the editable domains — layout write denied")
        return
    end

    for _, domain_name in ipairs(allowed) do
        if domain_name == target then
            return
        end
    end
    ctx.error("Domain '" .. target .. "' is not a domain you edit")
end

function export.create(ctx)
    validate_target(ctx)
    check_unique_domain(ctx)
    check_editor_domain(ctx)
end

function export.update(ctx)
    validate_target(ctx)
    check_unique_domain(ctx)
    check_editor_domain(ctx)
end

return export
